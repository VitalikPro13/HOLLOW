use serde::{Deserialize, Serialize};

use super::hlc::HlcTimestamp;

/// A Last-Writer-Wins register: pure deterministic LWW on the HLC total order.
///
/// "Latest authorized write wins." WHO may write is enforced by `op_allowed`
/// at every ingest plus the author-side gates — the merge's only job is
/// convergence. It must NOT consult the author's role: role-priority
/// dominance made every value sticky to the highest role that ever wrote it
/// (an Admin with MANAGE_SERVER could never overwrite an Owner-written server
/// setting), and the priority was derived from the ROLE MAP AT APPLY TIME,
/// which differs across mid-sync replicas — a permanent divergence source.
/// HLC-first merge is a pure function of the op: commutative, idempotent,
/// convergent. `HlcTimestamp`'s ordering (physical_ms, counter, actor) is
/// total, so distinct writes never tie.
///
/// `priority` is retained as inert metadata purely for serde compat: it is a
/// required field in persisted SQLCipher state JSON AND the
/// `ServerStateSnapshot` wire format consumed by older clients.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AdminLwwReg<V: Clone> {
    value: V,
    priority: u8,
    hlc: HlcTimestamp,
}

impl<V: Clone> AdminLwwReg<V> {
    /// Create a new register with an initial value.
    pub fn new(value: V, hlc: HlcTimestamp, priority: u8) -> Self {
        Self {
            value,
            priority,
            hlc,
        }
    }

    /// Update the register. The write succeeds locally — conflict resolution
    /// happens in `merge()`.
    pub fn update(&mut self, value: V, hlc: HlcTimestamp, priority: u8) {
        self.value = value;
        self.priority = priority;
        self.hlc = hlc;
    }

    /// Read the current value.
    pub fn read(&self) -> &V {
        &self.value
    }

    /// Read the current priority.
    pub fn priority(&self) -> u8 {
        self.priority
    }

    /// Read the current HLC timestamp.
    pub fn hlc(&self) -> &HlcTimestamp {
        &self.hlc
    }

    /// Pull a register's timestamp back to `max_ms` if it sits beyond it.
    ///
    /// A `ServerStateSnapshot` is adopted wholesale during a join, so a
    /// hostile responder could hand us registers stamped in the far future
    /// that no later honest write could ever overtake. Clamping on adoption
    /// bounds them without discarding the value. Returns true if it changed.
    pub fn clamp_hlc(&mut self, max_ms: u64) -> bool {
        if self.hlc.physical_ms > max_ms {
            self.hlc.physical_ms = max_ms;
            return true;
        }
        false
    }

    /// Merge with a remote register: later HLC wins, unconditionally.
    /// Priority is deliberately NOT consulted (see the struct doc); the HLC
    /// order is total, so an equal timestamp means the identical write.
    pub fn merge(&mut self, other: &Self) {
        if other.hlc > self.hlc {
            self.value = other.value.clone();
            self.priority = other.priority;
            self.hlc = other.hlc.clone();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ts(ms: u64, counter: u32, actor: &str) -> HlcTimestamp {
        HlcTimestamp {
            physical_ms: ms,
            counter,
            actor: actor.to_string(),
        }
    }

    #[test]
    fn older_write_loses_even_with_higher_priority() {
        let mut member_reg = AdminLwwReg::new(
            "member_value".to_string(),
            ts(2000, 0, "member"),
            0,
        );

        let admin_reg = AdminLwwReg::new(
            "admin_value".to_string(),
            ts(1000, 0, "admin"), // Earlier timestamp — loses despite priority 1.
            1,
        );

        member_reg.merge(&admin_reg);
        assert_eq!(member_reg.read(), "member_value");
    }

    #[test]
    fn later_hlc_wins() {
        let mut reg_a = AdminLwwReg::new("old".to_string(), ts(1000, 0, "a"), 0);
        let reg_b = AdminLwwReg::new("new".to_string(), ts(2000, 0, "b"), 0);

        reg_a.merge(&reg_b);
        assert_eq!(reg_a.read(), "new");
    }

    #[test]
    fn later_admin_write_overrides_older_owner_write() {
        // The live bug this rewrite fixes: an Owner-written value could never
        // be overwritten by an authorized Admin. Latest write wins now.
        let mut admin_reg =
            AdminLwwReg::new("admin".to_string(), ts(5000, 0, "admin"), 2);
        let owner_reg =
            AdminLwwReg::new("owner".to_string(), ts(1000, 0, "owner"), 3);

        admin_reg.merge(&owner_reg);
        assert_eq!(admin_reg.read(), "admin");
    }

    #[test]
    fn later_write_wins_regardless_of_priority() {
        let mut admin_reg =
            AdminLwwReg::new("admin".to_string(), ts(1000, 0, "admin"), 2);
        let member_reg = AdminLwwReg::new(
            "member".to_string(),
            ts(9999, 0, "member"),
            0,
        );

        admin_reg.merge(&member_reg);
        assert_eq!(admin_reg.read(), "member");
    }

    #[test]
    fn merge_commutes_regardless_of_order() {
        let a = AdminLwwReg::new("a_value".to_string(), ts(1000, 0, "a"), 3);
        let b = AdminLwwReg::new("b_value".to_string(), ts(2000, 0, "b"), 0);

        let mut ab = a.clone();
        ab.merge(&b);
        let mut ba = b.clone();
        ba.merge(&a);

        assert_eq!(ab.read(), ba.read());
        assert_eq!(ab.hlc(), ba.hlc());
        assert_eq!(ab.read(), "b_value");
    }

    #[test]
    fn merge_idempotent_on_equal_hlc() {
        let mut reg = AdminLwwReg::new("value".to_string(), ts(1000, 0, "a"), 2);
        let twin = reg.clone();
        reg.merge(&twin);
        assert_eq!(reg.read(), "value");
        assert_eq!(reg.priority(), 2);
        assert_eq!(reg.hlc(), &ts(1000, 0, "a"));
    }

    #[test]
    fn legacy_serialized_register_still_deserializes() {
        // `priority` must stay a required serialized field: it appears in old
        // persisted SQLCipher state JSON and in ServerStateSnapshot frames
        // from/to older clients.
        let legacy = r#"{"value":"x","priority":3,"hlc":{"physical_ms":1000,"counter":0,"actor":"owner"}}"#;
        let reg: AdminLwwReg<String> = serde_json::from_str(legacy).unwrap();
        assert_eq!(reg.read(), "x");
        assert_eq!(reg.priority(), 3);

        let out = serde_json::to_string(&reg).unwrap();
        assert!(out.contains("\"priority\":3"), "priority must round-trip: {out}");
    }
}
