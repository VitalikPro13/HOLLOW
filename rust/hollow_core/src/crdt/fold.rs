//! The fold: a server's state as a pure function of the signed ops it holds.
//!
//! Every retained op is applied in HLC order and judged against the state just before
//! it, so arrival order, the relay's timing and whichever member answered change
//! nothing: two replicas holding the same ops hold the same state. Live ops newer than
//! the log's tail apply at the tail (the common case); anything older rebuilds the
//! state from its anchor. Design E, `reports/planned/security/audit/design_E_crdt_authority.md`.

use std::collections::HashSet;
use std::time::{Duration, Instant};

use super::hlc::HlcTimestamp;
use super::operations::{CrdtOp, CrdtPayload, OpReject};
use super::server_state::{fold_order, Anchor, MemberSpan, ServerState};
use super::sync::payload_name;

/// Ops refused only for authority wait here for the admission or role grant they may
/// have raced ahead of. Bounded both ways, since anyone holding a key can send one.
const HELD_CAP: usize = 256;
const HELD_TTL: Duration = Duration::from_secs(600);

/// An anchored log this long gets a compaction checkpoint from its owner.
const CHECKPOINT_AFTER_OPS: usize = 2000;
const CHECKPOINT_MIN_GAP_MS: u64 = 3600 * 1000;

/// What an ingest did.
#[derive(Debug, Default)]
pub struct Ingested {
    /// Ops that entered the log for the first time: the ones to persist, emit and
    /// pass on.
    pub admitted: Vec<CrdtOp>,
    /// Ops refused (forged, foreign, future-dated, or not allowed at their point).
    pub rejected: usize,
    /// The state was rebuilt from its anchor, so anything may have changed.
    pub rebuilt: bool,
}

impl ServerState {
    /// Author an op on our own replica, judged by the SAME predicate every receiver
    /// runs, so we never apply or send an op honest peers refuse. `None` = refused.
    pub fn author_checked(&mut self, payload: CrdtPayload) -> Option<CrdtOp> {
        let op = self.create_op(payload);
        if !self.op_allowed(&op) {
            crate::hollow_log!(
                "[HOLLOW-CRDT] Not authoring {} in {}: our own rules refuse it",
                payload_name(&op.payload), self.server_id,
            );
            return None;
        }
        let _ = self.apply_op(&op);
        Some(op)
    }

    /// Whether the owner (`me`) owes this server a checkpoint now: once to move it off
    /// the legacy anchor, then whenever its log has grown past `CHECKPOINT_AFTER_OPS`,
    /// at most once an hour.
    pub fn checkpoint_due(&self, me: &str, now_ms: u64) -> bool {
        if self.deleted || self.current_owner().as_deref() != Some(me) {
            return false;
        }
        match self.anchor() {
            Anchor::Legacy => true,
            _ => {
                self.op_log.len() > CHECKPOINT_AFTER_OPS
                    && self
                        .checkpoint_hlc
                        .as_ref()
                        .is_none_or(|c| now_ms.saturating_sub(c.physical_ms) > CHECKPOINT_MIN_GAP_MS)
            }
        }
    }

    /// The newest clock this state reflects: its log's tail, or a register written
    /// later than that (a legacy log is capped). What an owner's checkpoint covers, so
    /// an owner that was away never overwrites what happened meanwhile.
    pub fn horizon(&self) -> HlcTimestamp {
        fn newest<V: Clone>(
            m: &std::collections::HashMap<String, super::admin_lww::AdminLwwReg<V>>,
        ) -> Option<&HlcTimestamp> {
            m.values().map(|r| r.hlc()).max()
        }
        let tail = self.op_log.last().map(|o| match &o.payload {
            CrdtPayload::ServerCheckpoint { covers, .. } => covers,
            _ => &o.hlc,
        });
        [
            tail,
            Some(self.name.hlc()),
            newest(&self.roles),
            newest(&self.settings),
            newest(&self.nicknames),
            newest(&self.banned_members),
            newest(&self.muted_members),
        ]
        .into_iter()
        .flatten()
        .max()
        .cloned()
        .unwrap_or_else(|| HlcTimestamp::zero(""))
    }

    /// The owner's checkpoint of this state. The first one of an existing server also
    /// seeds the membership record from what the owner vouches for: every current
    /// member from the start, and every author of a channel post it holds up to now.
    pub fn checkpoint_json(&self, me: &str, past_authors: &[String], now_ms: u64) -> Option<String> {
        let mut base = self.lean_snapshot();
        base.owner_pin = None;
        base.checkpoint_hlc = None;
        // The owner is fixed: a co-owner an older client minted is an admin here.
        for (id, reg) in base.roles.iter_mut() {
            if id != me && *reg.read() == super::operations::MemberRole::Owner {
                let (hlc, priority) = (reg.hlc().clone(), reg.priority());
                *reg = super::admin_lww::AdminLwwReg::new(super::operations::MemberRole::Admin, hlc, priority);
            }
        }
        if self.anchor() == Anchor::Legacy {
            let current: Vec<(String, u64)> =
                base.members.keys().map(|m| (m.clone(), u64::MAX)).collect();
            let past = past_authors.iter().map(|a| (a.clone(), now_ms));
            for (who, until_ms) in current.into_iter().chain(past) {
                let spans = base.member_record.entry(who).or_default();
                if spans.first().is_none_or(|s| s.from_ms > 0) {
                    spans.insert(0, MemberSpan { from_ms: 0, until_ms });
                }
            }
        }
        serde_json::to_string(&base).ok()
    }

    /// Whether a joiner may adopt a snapshot a member handed it, and anchored to whom.
    ///
    /// Never for a self-certifying id (built from its signed ops alone, E1). With an
    /// invite pin the snapshot's owner must be it; without one this is trust on first
    /// use (residual R1), and the owner it names becomes the anchor from then on. A
    /// snapshot is only ever a legacy state: a checkpointed server's own checkpoint op
    /// follows in the ops and rebases the joiner.
    pub fn accept_join_snapshot(
        mut snap: ServerState,
        server_id: &str,
        pin: Option<&str>,
    ) -> Result<ServerState, &'static str> {
        if super::anchor::is_genesis_id(server_id) {
            return Err("a self-certifying server is built from its ops");
        }
        if snap.server_id != server_id {
            return Err("server id mismatch");
        }
        let owner = snap.current_owner();
        if pin.is_some_and(|p| owner.as_deref() != Some(p)) {
            return Err("its owner is not the one the invite named");
        }
        let Some(owner) = owner else { return Err("no owner") };
        snap.owner_pin = Some(owner);
        snap.checkpoint_hlc = None;
        Ok(snap)
    }

    /// The one entry point for remotely authored ops, live frames and sync batches
    /// alike: the stateless checks, dedup, then the fold. Only what it admits moves our
    /// clock, so a refused op cannot date our next writes.
    pub fn ingest_remote(&mut self, ops: &[CrdtOp]) -> Ingested {
        let out = self.fold_remote(ops);
        if let Some(hlc) = &mut self.hlc {
            for op in &out.admitted {
                hlc.witness(&op.hlc);
            }
        }
        out
    }

    fn fold_remote(&mut self, ops: &[CrdtOp]) -> Ingested {
        let mut out = Ingested::default();
        self.ensure_dedup();
        self.held.retain(|(_, at)| at.elapsed() < HELD_TTL);
        let now = super::hlc::wall_clock_ms();
        let mut seen: HashSet<(String, HlcTimestamp)> = HashSet::new();
        let mut fresh = Vec::new();
        for op in ops {
            if let Err(reason) = self.stateless_check(op, now) {
                out.rejected += 1;
                log_refusal(op, &reason);
                continue;
            }
            let key = (op.author.clone(), op.hlc.clone());
            if self.op_log_dedup.contains(&key)
                || self.held.iter().any(|(h, _)| h.author == op.author && h.hlc == op.hlc)
                || !seen.insert(key)
            {
                continue;
            }
            fresh.push(op.clone());
        }
        if fresh.is_empty() {
            return out;
        }
        fresh.sort_by(fold_order);

        if self.anchor() == Anchor::Legacy {
            // The owner's checkpoint moves a legacy replica onto the fold. It is judged
            // against the legacy state it replaces, which also pins its owner.
            let checkpoint = fresh.iter().find(|op| {
                matches!(op.payload, CrdtPayload::ServerCheckpoint { .. }) && self.op_allowed(op)
            });
            if let Some(cp) = checkpoint {
                self.owner_pin = Some(cp.author.clone());
                return self.fold_in(fresh, out);
            }
            return self.apply_in_arrival(fresh, out);
        }

        let in_order = self
            .op_log
            .last()
            .is_none_or(|tail| fold_order(&fresh[0], tail) == std::cmp::Ordering::Greater);
        if !in_order {
            return self.fold_in(fresh, out);
        }
        let mut enabling = false;
        for op in fresh {
            if self.op_allowed(&op) {
                enabling |= enables_others(&op.payload);
                self.apply_payload(&op);
                self.log_admitted(op.clone());
                out.admitted.push(op);
            } else {
                self.hold(op, &mut out);
            }
        }
        if enabling && !self.held.is_empty() {
            return self.fold_in(Vec::new(), out);
        }
        out
    }

    /// Server id, author signature and clock bound: everything that does not depend on
    /// the state.
    fn stateless_check(&self, op: &CrdtOp, now_ms: u64) -> Result<(), OpReject> {
        if op.server_id != self.server_id {
            return Err(OpReject::WrongServer);
        }
        op.verify_author()?;
        if op.hlc.physical_ms > now_ms + super::hlc::MAX_DRIFT_MS {
            return Err(OpReject::FutureHlc);
        }
        Ok(())
    }

    /// A legacy replica has no anchor to rebuild from: judge each op against the state
    /// as it stands, and retry held ops for as long as admissions make progress.
    fn apply_in_arrival(&mut self, fresh: Vec<CrdtOp>, mut out: Ingested) -> Ingested {
        let mut progressed = false;
        for op in fresh {
            if self.op_allowed(&op) {
                if let Ok(true) = self.apply_op(&op) {
                    out.admitted.push(op);
                }
                progressed = true;
            } else {
                self.hold(op, &mut out);
            }
        }
        while progressed && !self.held.is_empty() {
            progressed = false;
            let mut held = std::mem::take(&mut self.held);
            held.sort_by(|a, b| a.0.hlc.cmp(&b.0.hlc));
            for (op, at) in held {
                if self.op_allowed(&op) {
                    if let Ok(true) = self.apply_op(&op) {
                        out.admitted.push(op);
                    }
                    progressed = true;
                } else {
                    self.held.push((op, at));
                }
            }
        }
        out
    }

    /// Rebuild the state from its anchor: every retained, held and fresh op folded in
    /// HLC order, each judged against the state just before it.
    fn fold_in(&mut self, fresh: Vec<CrdtOp>, mut out: Ingested) -> Ingested {
        let before = std::mem::take(&mut self.op_log_dedup);
        let mut candidates = std::mem::take(&mut self.op_log);
        candidates.extend(self.held.drain(..).map(|(op, _)| op));
        candidates.extend(fresh);
        candidates.sort_by(fold_order);
        candidates.dedup_by(|a, b| a.author == b.author && a.hlc == b.hlc);

        self.reset_materialized();
        let now = Instant::now();
        let mut refused = Vec::new();
        for op in candidates {
            if self.op_allowed(&op) {
                self.apply_payload(&op);
                self.log_admitted(op);
            } else {
                refused.push(op);
            }
        }
        // What a checkpoint overwrote can never become valid again.
        let base = self.checkpoint_hlc.clone();
        for op in refused {
            if base.as_ref().is_none_or(|b| op.hlc > *b) {
                self.held.push((op, now));
            }
        }
        let overflow = self.held.len().saturating_sub(HELD_CAP);
        self.held.drain(..overflow);

        // Admitted = in the log now and not before this ingest began. Ops the tail
        // pass already admitted are in `before`, so they are carried over by key.
        let tail_admitted: HashSet<(String, HlcTimestamp)> = out
            .admitted
            .iter()
            .map(|o| (o.author.clone(), o.hlc.clone()))
            .collect();
        out.admitted = self
            .op_log
            .iter()
            .filter(|o| {
                let key = (o.author.clone(), o.hlc.clone());
                !before.contains(&key) || tail_admitted.contains(&key)
            })
            .cloned()
            .collect();
        out.rebuilt = true;
        out
    }

    fn hold(&mut self, op: CrdtOp, out: &mut Ingested) {
        out.rejected += 1;
        log_refusal(&op, &OpReject::NotAllowed);
        if self.held.len() >= HELD_CAP {
            self.held.remove(0);
        }
        self.held.push((op, Instant::now()));
    }
}

/// Ops that can make a held op valid: an admission, a grant, or the anchor itself.
fn enables_others(payload: &CrdtPayload) -> bool {
    matches!(
        payload,
        CrdtPayload::MemberAdded { .. }
            | CrdtPayload::RoleChanged { .. }
            | CrdtPayload::RolePermissionsChanged { .. }
            | CrdtPayload::MemberUnbanned { .. }
            | CrdtPayload::LabelCreated { .. }
            | CrdtPayload::LabelUpdated { .. }
            | CrdtPayload::ChannelAdded { .. }
            | CrdtPayload::ServerSettingChanged { .. }
            | CrdtPayload::ServerCreated { .. }
            | CrdtPayload::ServerCheckpoint { .. }
    )
}

/// Variant name only, never the payload: an op can carry a nickname or a channel name.
fn log_refusal(op: &CrdtOp, reason: &OpReject) {
    crate::hollow_log!(
        "[HOLLOW-SECURITY] REJECTED CrdtOp {} for {} by {}: {reason}",
        payload_name(&op.payload), op.server_id, op.author,
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crdt::hlc::Hlc;
    use crate::crdt::operations::{CrdtPayload as P, MemberRole};
    use crate::crdt::server_state::Anchor;
    use crate::crdt::testkeys::keys;

    /// An op by `tag`'s identity at an exact clock, signed like any real one.
    fn op_at(tag: u8, sid: &str, ms: u64, payload: P) -> CrdtOp {
        let (kp, id, pk) = keys(tag);
        let mut op = CrdtOp {
            server_id: sid.into(),
            hlc: HlcTimestamp { physical_ms: ms, counter: 0, actor: id.clone() },
            author: id,
            payload,
            auth: None,
        };
        op.sign(&kp, &pk);
        op
    }

    fn founded(tag: u8) -> (ServerState, CrdtOp) {
        let (kp, id, pk) = keys(tag);
        ServerState::found("S".into(), id, kp, pk)
    }

    /// A joiner's replica of `sid`: the ownerless skeleton, able to author as `tag`.
    fn joiner(sid: &str, tag: u8) -> ServerState {
        let (kp, id, pk) = keys(tag);
        let mut s = ServerState::skeleton(sid.into());
        s.set_hlc(Hlc::new(id));
        s.set_signer(kp, pk);
        s
    }

    fn id(tag: u8) -> String {
        keys(tag).1
    }

    fn add(tag: u8) -> P {
        P::MemberAdded { peer_id: id(tag), display_name: "m".into(), follow: None }
    }

    fn general(s: &ServerState) -> String {
        format!("{}-general", &s.server_id[..8])
    }

    fn founding_hlc(s: &ServerState) -> HlcTimestamp {
        s.name.hlc().clone()
    }

    /// E5: two replicas holding the same ops hold the same state, whatever order the
    /// relay delivered them in, including who was allowed to write what: an admin's op
    /// stamped before its demotion lands everywhere, one after it nowhere.
    #[test]
    fn authz_fold_state_does_not_depend_on_arrival_order() {
        let (owner, founding) = founded(1);
        let sid = owner.server_id.clone();
        let ch = general(&owner);
        let t = founding.hlc.physical_ms;
        let ops = vec![
            founding.clone(),
            op_at(1, &sid, t + 1, add(2)),
            op_at(1, &sid, t + 2, P::RoleChanged { peer_id: id(2), role: MemberRole::Admin, priority: 2 }),
            op_at(2, &sid, t + 3, P::ChannelPublicChanged { channel_id: ch.clone(), is_public: true }),
            op_at(1, &sid, t + 4, P::ChannelPublicChanged { channel_id: ch.clone(), is_public: false }),
            op_at(2, &sid, t + 5, P::ChannelRenamed { channel_id: ch.clone(), new_name: "before".into() }),
            op_at(1, &sid, t + 6, P::RoleChanged { peer_id: id(2), role: MemberRole::Member, priority: 3 }),
            op_at(2, &sid, t + 7, P::ChannelRenamed { channel_id: ch.clone(), new_name: "after".into() }),
        ];
        let mut in_order = joiner(&sid, 9);
        for op in &ops {
            in_order.ingest_remote(std::slice::from_ref(op));
        }
        // The relay's choice: founding and admission first (nothing lands without
        // them), the rest in reverse.
        let mut shuffled = joiner(&sid, 9);
        let (head, tail) = ops.split_at(2);
        for op in head.iter().chain(tail.iter().rev()) {
            shuffled.ingest_remote(std::slice::from_ref(op));
        }
        for s in [&in_order, &shuffled] {
            let c = &s.channels[&ch];
            assert!(!c.is_public, "the owner's later write wins");
            assert_eq!(c.name, "before", "the admin's pre-demotion rename stands, the later one never");
            assert_eq!(s.get_role(&id(2)), MemberRole::Member);
        }
        assert_eq!(in_order.op_log.len(), shuffled.op_log.len());
    }

    /// D7: only an op the fold admits moves our clock. A stranger's correctly signed op,
    /// dated just inside the drift bound, is refused and leaves the clock where it was;
    /// a member's op dated the same moves it.
    #[test]
    fn authz_only_an_admitted_op_moves_our_clock() {
        let (owner, founding) = founded(1);
        let sid = owner.server_id.clone();
        let t = founding.hlc.physical_ms;
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&[founding, op_at(1, &sid, t + 1, add(2))]);
        let wall = crate::crdt::hlc::wall_clock_ms();
        let ahead = wall + crate::crdt::hlc::MAX_DRIFT_MS - 30_000;

        let stranger = r.ingest_remote(&[op_at(7, &sid, ahead, P::ServerRenamed { new_name: "x".into() })]);
        assert!(stranger.admitted.is_empty());
        assert!(r.hlc.as_ref().unwrap().physical_ms() < wall + 60_000, "a refused op moved our clock");

        let member = r.ingest_remote(&[op_at(2, &sid, ahead, P::NicknameChanged { peer_id: id(2), nickname: "n".into() })]);
        assert_eq!(member.admitted.len(), 1);
        assert!(r.hlc.as_ref().unwrap().physical_ms() >= ahead, "an admitted op is witnessed");
    }

    /// E3, E15: an old op replayed after far more than the old 1000-op window changes
    /// nothing: a kicked member is not re-admitted, a closed channel does not reopen,
    /// and the founding op does not reset the name.
    #[test]
    fn authz_a_replayed_old_op_never_undoes_a_later_one() {
        let (owner, founding) = founded(1);
        let sid = owner.server_id.clone();
        let ch = general(&owner);
        let t = founding.hlc.physical_ms;
        let opened = op_at(1, &sid, t + 2, P::ChannelPublicChanged { channel_id: ch.clone(), is_public: true });
        let admitted = op_at(1, &sid, t + 1, add(2));
        let mut ops = vec![
            founding.clone(),
            admitted.clone(),
            opened.clone(),
            op_at(1, &sid, t + 3, P::ChannelPublicChanged { channel_id: ch.clone(), is_public: false }),
            op_at(1, &sid, t + 4, P::MemberRemoved { peer_id: id(2) }),
            op_at(1, &sid, t + 5, P::ServerRenamed { new_name: "Renamed".into() }),
        ];
        for i in 0..1100u64 {
            ops.push(op_at(1, &sid, t + 10 + i, P::NicknameChanged { peer_id: id(1), nickname: format!("n{i}") }));
        }
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&ops);
        let replay = r.ingest_remote(&[admitted, opened, founding]);
        assert!(replay.admitted.is_empty() && !replay.rebuilt, "a replay is a duplicate, however old");
        assert!(!r.is_member(&id(2)), "the kicked member stays out");
        assert!(!r.channels[&ch].is_public, "the closed channel stays closed");
        assert_eq!(r.name(), "Renamed", "the founding op does not reset the name");
    }

    /// E1, E2: a self-certifying id is founded only by the key that hashes to it, so a
    /// founding op anyone else signs, backdated or not, never takes the server.
    #[test]
    fn authz_a_self_certifying_server_is_founded_only_by_its_key() {
        let (owner, founding) = founded(1);
        let sid = owner.server_id.clone();
        let t = founding.hlc.physical_ms;
        let forged = op_at(5, &sid, t - 1000, P::ServerCreated {
            name: "Mine".into(), owner_peer_id: id(5), nonce: "00".into(),
        });
        let mut r = joiner(&sid, 9);
        assert_eq!(r.anchor(), Anchor::Genesis);
        r.ingest_remote(std::slice::from_ref(&forged));
        assert!(r.current_owner().is_none(), "the forged founding op takes nothing");
        r.ingest_remote(&[founding, forged, op_at(5, &sid, t + 1, add(5))]);
        assert_eq!(r.current_owner(), Some(id(1)));
        assert_eq!(r.name(), "S");
        assert!(!r.is_member(&id(5)), "and its author cannot admit itself");
    }

    /// A checkpoint comes only from the anchor owner. It replaces the state, ops older
    /// than it are ignored even when they arrive later, and newer ones fold on top.
    #[test]
    fn authz_a_checkpoint_comes_only_from_the_anchor_owner() {
        let (mut legacy, o) = crate::crdt::testkeys::owned_state("s-legacy", "Old", 1);
        let ch = general(&legacy);
        legacy.author_checked(add(2)).unwrap();
        legacy.author_checked(P::RoleChanged { peer_id: id(2), role: MemberRole::Admin, priority: 3 }).unwrap();
        let mut member = legacy.clone();
        member.set_hlc(Hlc::new(id(3)));
        assert_eq!(member.anchor(), Anchor::Legacy);

        let now = crate::crdt::hlc::wall_clock_ms();
        let covers = legacy.horizon();
        let json = legacy.checkpoint_json(&o, &[], now).unwrap();
        // The admin's own state, naming itself the one Owner: well formed, wrong author.
        let mut usurped = legacy.lean_snapshot();
        usurped.roles.insert(o.clone(), crate::crdt::admin_lww::AdminLwwReg::new(MemberRole::Admin, founding_hlc(&legacy), 3));
        usurped.roles.insert(id(2), crate::crdt::admin_lww::AdminLwwReg::new(MemberRole::Owner, founding_hlc(&legacy), 3));
        let by_admin = op_at(2, &legacy.server_id, now, P::ServerCheckpoint {
            state: serde_json::to_string(&usurped).unwrap(), covers: covers.clone(),
        });
        member.ingest_remote(std::slice::from_ref(&by_admin));
        assert_eq!(member.anchor(), Anchor::Legacy, "an admin's checkpoint is refused");
        assert_eq!(member.current_owner(), Some(o.clone()));

        let late_old = op_at(1, &legacy.server_id, covers.physical_ms - 1, P::ChannelRenamed { channel_id: ch.clone(), new_name: "stale".into() });
        let checkpoint = legacy.author_checked(P::ServerCheckpoint { state: json, covers: covers.clone() }).unwrap();
        member.ingest_remote(std::slice::from_ref(&checkpoint));
        assert_eq!(member.anchor(), Anchor::Checkpoint);
        assert_eq!(member.owner_pin.as_deref(), Some(o.as_str()));
        assert_eq!(member.op_log.len(), 1, "everything the checkpoint overwrote is dropped");

        member.ingest_remote(std::slice::from_ref(&late_old));
        assert_eq!(member.channels[&ch].name, "general", "an op older than the checkpoint is ignored");
        let newer = op_at(1, &legacy.server_id, checkpoint.hlc.physical_ms + 1, P::ChannelRenamed { channel_id: ch.clone(), new_name: "new".into() });
        member.ingest_remote(std::slice::from_ref(&newer));
        assert_eq!(member.channels[&ch].name, "new");

        let again = op_at(2, &legacy.server_id, newer.hlc.physical_ms + 1, P::ServerCheckpoint {
            state: member.checkpoint_json(&id(2), &[], now).unwrap(), covers: member.horizon(),
        });
        member.ingest_remote(std::slice::from_ref(&again));
        assert_eq!(member.owner_pin.as_deref(), Some(o.as_str()), "the owner is fixed");
        assert_eq!(member.channels[&ch].name, "new");
    }

    /// A checkpoint covers only what its owner had seen: an owner back from days away
    /// signs its old view, and what members did meanwhile folds on top instead of
    /// being overwritten.
    #[test]
    fn a_checkpoint_keeps_what_its_owner_had_not_seen() {
        let hour = 3_600_000;
        let t = crate::crdt::hlc::wall_clock_ms() - 3 * hour;
        let sid = crate::crdt::anchor::derive_server_id(&id(1), "n");
        let ch = format!("{}-general", &sid[..8]);
        let history = vec![
            op_at(1, &sid, t, P::ServerCreated { name: "S".into(), owner_peer_id: id(1), nonce: "n".into() }),
            op_at(1, &sid, t + 1, add(2)),
            op_at(1, &sid, t + 2, P::RoleChanged { peer_id: id(2), role: MemberRole::Admin, priority: 3 }),
        ];
        // The owner saw nothing after that; the admin renamed the channel an hour later.
        let mut away = joiner(&sid, 1);
        away.ingest_remote(&history);
        let mut member = joiner(&sid, 3);
        member.ingest_remote(&history);
        let meanwhile = op_at(2, &sid, t + hour, P::ChannelRenamed { channel_id: ch.clone(), new_name: "renamed while away".into() });
        member.ingest_remote(std::slice::from_ref(&meanwhile));

        let covers = away.horizon();
        assert!(covers.physical_ms < t + hour, "the owner's state is hours old");
        let json = away.checkpoint_json(&id(1), &[], covers.physical_ms).unwrap();
        let checkpoint = away.author_checked(P::ServerCheckpoint { state: json, covers }).unwrap();
        member.ingest_remote(std::slice::from_ref(&checkpoint));
        assert_eq!(member.anchor(), Anchor::Checkpoint);
        assert_eq!(member.channels[&ch].name, "renamed while away", "the member's newer op survives");
        away.ingest_remote(std::slice::from_ref(&meanwhile));
        assert_eq!(away.channels[&ch].name, "renamed while away", "and reaches the owner on top of its own checkpoint");
    }

    /// E1: a joiner takes a snapshot only for an existing server, and with an invite
    /// pin only one whose owner is the pin; the owner it accepts becomes the anchor.
    #[test]
    fn authz_a_join_snapshot_needs_the_pinned_owner() {
        let (legacy, o) = crate::crdt::testkeys::owned_state("s-legacy", "Old", 1);
        let snap = || legacy.lean_snapshot();
        assert!(ServerState::accept_join_snapshot(snap(), "s-legacy", Some(&id(7))).is_err());
        assert!(ServerState::accept_join_snapshot(snap(), "s-other", None).is_err());
        let pinned = ServerState::accept_join_snapshot(snap(), "s-legacy", Some(&o)).unwrap();
        assert_eq!(pinned.owner_pin.as_deref(), Some(o.as_str()));
        let tofu = ServerState::accept_join_snapshot(snap(), "s-legacy", None).unwrap();
        assert_eq!(tofu.owner_pin.as_deref(), Some(o.as_str()), "trust on first use pins what it saw");

        let (genesis, _) = founded(1);
        let sid = genesis.server_id.clone();
        assert!(ServerState::accept_join_snapshot(genesis, &sid, None).is_err(),
            "no snapshot for a self-certifying id");
    }

    /// E4: the membership record spans admission to removal, with slack for clocks,
    /// and an existing server's first checkpoint seeds it from what the owner holds.
    #[test]
    fn the_membership_record_spans_admission_to_removal() {
        let hour = 3_600_000;
        let t = crate::crdt::hlc::wall_clock_ms() - 3 * hour;
        let sid = crate::crdt::anchor::derive_server_id(&id(1), "n");
        let founding = op_at(1, &sid, t, P::ServerCreated {
            name: "S".into(), owner_peer_id: id(1), nonce: "n".into(),
        });
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&[
            founding,
            op_at(1, &sid, t + hour, add(2)),
            op_at(1, &sid, t + 2 * hour, P::MemberRemoved { peer_id: id(2) }),
        ]);
        assert!(r.was_member_at(&id(1), t + 1));
        assert!(r.was_member_at(&id(2), t + hour + 1));
        assert!(!r.was_member_at(&id(2), t + 3 * hour), "after removal");
        assert!(!r.was_member_at(&id(2), t), "before admission");
        assert!(!r.was_member_at(&id(3), t + hour), "never a member");

        let (legacy, o) = crate::crdt::testkeys::owned_state("s-legacy", "Old", 1);
        let json = legacy.checkpoint_json(&o, &[id(4)], 5_000).unwrap();
        let base: ServerState = serde_json::from_str(&json).unwrap();
        assert!(base.was_member_at(&o, 1), "a current member from the start");
        assert!(base.was_member_at(&id(4), 4_000), "an author the owner holds posts by");
        assert!(!base.was_member_at(&id(4), 5_000 + 2 * hour), "only up to the checkpoint");
    }
}
