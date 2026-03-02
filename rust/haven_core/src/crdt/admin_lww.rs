use serde::{Deserialize, Serialize};

use super::hlc::HlcTimestamp;

/// A Last-Writer-Wins register with role-priority override.
///
/// Priority levels: Owner (2) > Admin (1) > Member (0).
/// Higher priority always wins, regardless of timestamp.
/// Same priority falls back to HLC ordering.
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

    /// Merge with a remote register. Higher priority wins; same priority uses
    /// HLC ordering (later timestamp wins).
    pub fn merge(&mut self, other: &Self) {
        if other.priority > self.priority {
            self.value = other.value.clone();
            self.priority = other.priority;
            self.hlc = other.hlc.clone();
        } else if other.priority == self.priority && other.hlc > self.hlc {
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
    fn admin_overrides_member_even_with_older_timestamp() {
        let mut member_reg = AdminLwwReg::new(
            "member_value".to_string(),
            ts(2000, 0, "member"),
            0, // Member priority
        );

        let admin_reg = AdminLwwReg::new(
            "admin_value".to_string(),
            ts(1000, 0, "admin"), // Earlier timestamp
            1, // Admin priority
        );

        member_reg.merge(&admin_reg);
        assert_eq!(member_reg.read(), "admin_value");
    }

    #[test]
    fn same_priority_uses_hlc() {
        let mut reg_a = AdminLwwReg::new("old".to_string(), ts(1000, 0, "a"), 0);
        let reg_b = AdminLwwReg::new("new".to_string(), ts(2000, 0, "b"), 0);

        reg_a.merge(&reg_b);
        assert_eq!(reg_a.read(), "new");
    }

    #[test]
    fn owner_always_wins() {
        let mut admin_reg =
            AdminLwwReg::new("admin".to_string(), ts(5000, 0, "admin"), 1);
        let owner_reg =
            AdminLwwReg::new("owner".to_string(), ts(1000, 0, "owner"), 2);

        admin_reg.merge(&owner_reg);
        assert_eq!(admin_reg.read(), "owner");
    }

    #[test]
    fn lower_priority_does_not_override() {
        let mut admin_reg =
            AdminLwwReg::new("admin".to_string(), ts(1000, 0, "admin"), 1);
        let member_reg = AdminLwwReg::new(
            "member".to_string(),
            ts(9999, 0, "member"), // Much later timestamp
            0,
        );

        admin_reg.merge(&member_reg);
        assert_eq!(admin_reg.read(), "admin");
    }
}
