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
use super::server_state::{fold_order, is_self_leave, Anchor, MemberSpan, ServerState};
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
                    spans.insert(0, MemberSpan { from_ms: 0, until_ms, ..MemberSpan::default() });
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
    /// follows in the ops and rebases the joiner. Until then it is one member's word,
    /// so it decides who belongs and what exists, never who may decide (D2).
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
        snap.roles.retain(|id, _| *id == owner);
        snap.role_permissions.clear();
        snap.banned_members.clear();
        snap.muted_members.clear();
        snap.label_assignments.clear();
        snap.channel_grants.clear();
        snap.retain_well_formed_channels();
        for channel in snap.channels.values_mut() {
            channel.is_public = false;
        }
        snap.owner_pin = Some(owner);
        snap.checkpoint_hlc = None;
        Ok(snap)
    }

    /// The one entry point for remotely authored ops, live frames and sync batches
    /// alike: the stateless checks, dedup, then the fold. Only what it admits moves our
    /// clock, so a refused op cannot date our next writes.
    pub fn ingest_remote(&mut self, ops: &[CrdtOp]) -> Ingested {
        let mut out = self.fold_remote(ops);
        // Storing a checkpoint drops every row it covers and stores again the self-leaves
        // below it the batch carries: exactly the late leaves the new checkpoint keeps.
        if out.admitted.iter().any(|o| matches!(o.payload, CrdtPayload::ServerCheckpoint { .. }))
            && let Some(base) = self.checkpoint_hlc.clone()
        {
            let genesis = super::anchor::is_genesis_id(&self.server_id);
            out.admitted.retain(|o| !is_self_leave(o) || self.retains(o, &base, genesis));
            for (author, hlc) in &self.late_leaves {
                if !out.admitted.iter().any(|o| o.author == *author && o.hlc == *hlc)
                    && let Some(op) = self.op_log.iter().find(|o| o.author == *author && o.hlc == *hlc)
                {
                    out.admitted.push(op.clone());
                }
            }
        }
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

    /// Refold an anchored log once on a state persisted before 0.13, whose spans lack the
    /// admitters `node::standing` reads; true when the caller must persist the state. A
    /// log that did not load leaves the mark unset, so the next start refolds.
    pub fn refold_for_standing(&mut self) -> bool {
        if self.standing_folded || self.anchor() == Anchor::Legacy || self.op_log.is_empty() {
            return false;
        }
        self.refold();
        self.standing_folded = true;
        true
    }

    /// Rebuild the materialized state from the log as it stands.
    pub(super) fn refold(&mut self) {
        let _ = self.fold_in(Vec::new(), Ingested::default());
    }

    /// Server id, author signature and clock bound: everything that does not depend on
    /// the state.
    pub(super) fn stateless_check(&self, op: &CrdtOp, now_ms: u64) -> Result<(), OpReject> {
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
                if matches!(op.payload, CrdtPayload::ServerCheckpoint { .. }) {
                    // A member's own leave refused at its place (the admission it rests on
                    // is history this checkpoint overwrote) is judged against it too.
                    let late = self.apply_checkpoint(&op, &refused);
                    if !late.is_empty() {
                        let keys: HashSet<(&str, &HlcTimestamp)> = late.iter().map(|o| (o.author.as_str(), &o.hlc)).collect();
                        refused.retain(|r| !keys.contains(&(r.author.as_str(), &r.hlc)));
                    }
                    for op in late {
                        self.log_admitted(op);
                    }
                } else {
                    self.apply_payload(&op);
                }
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

    /// `tag` admitted to `sid` on its own ask.
    fn add(sid: &str, tag: u8) -> P {
        let ask = crate::crdt::operations::JoinAsk::sign(sid, 1, &keys(tag).0);
        P::MemberAdded { peer_id: id(tag), display_name: "m".into(), follow: None, ask: Some(ask) }
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
            op_at(1, &sid, t + 1, add(&sid, 2)),
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
        r.ingest_remote(&[founding, op_at(1, &sid, t + 1, add(&sid, 2))]);
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
        let admitted = op_at(1, &sid, t + 1, add(&sid, 2));
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
        r.ingest_remote(&[founding, forged, op_at(5, &sid, t + 1, add(&sid, 5))]);
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
        legacy.author_checked(add(&legacy.server_id, 2)).unwrap();
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
            op_at(1, &sid, t + 1, add(&sid, 2)),
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

    /// D2: a member's snapshot decides who belongs and what exists, never who may
    /// decide: only the owner keeps its role, and permissions, bans, mutes, label
    /// assignments, grants and public channels wait for the owner's ops or checkpoint.
    #[test]
    fn authz_a_join_snapshot_carries_no_authority() {
        use crate::crdt::admin_lww::AdminLwwReg;
        use crate::crdt::operations::Permission;
        let (mut legacy, o) = crate::crdt::testkeys::owned_state("s-legacy", "Old", 1);
        let hlc = legacy.name.hlc().clone();
        legacy.members.insert(id(2), crate::crdt::server_state::MemberInfo { peer_id: id(2), display_name: "m".into() });
        legacy.roles.insert(id(2), AdminLwwReg::new(MemberRole::Admin, hlc.clone(), 3));
        legacy.banned_members.insert(id(3), AdminLwwReg::new(true, hlc.clone(), 3));
        legacy.muted_members.insert(id(4), AdminLwwReg::new(u64::MAX, hlc.clone(), 3));
        legacy.role_permissions.insert("member".into(), AdminLwwReg::new(Permission::ALL, hlc.clone(), 3));
        legacy.label_assignments.insert(id(2), vec!["vip".into()]);
        legacy.channel_grants.insert("c".into(), [(id(2), AdminLwwReg::new(u64::MAX, hlc, 3))].into());
        for ch in legacy.channels.values_mut() {
            ch.is_public = true;
        }

        let snap = ServerState::accept_join_snapshot(legacy.lean_snapshot(), "s-legacy", Some(&o)).unwrap();
        assert_eq!(snap.get_role(&o), MemberRole::Owner);
        assert!(snap.is_member(&id(2)), "who belongs stands");
        assert_eq!(snap.get_role(&id(2)), MemberRole::Member, "a role on the member's word");
        assert!(!snap.is_banned(&id(3)), "a ban");
        assert!(!snap.is_muted(&id(4), 0), "a mute");
        assert!(!snap.has_permission(&id(2), Permission::KICK_MEMBERS), "a permission");
        assert!(snap.label_assignments.is_empty(), "a label");
        assert!(snap.channel_grants.is_empty(), "a grant");
        assert!(snap.channels.values().all(|c| !c.is_public), "a public channel");
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
            op_at(1, &sid, t + hour, add(&sid, 2)),
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

    /// R4 (design g13w2-f): a state 0.12.2 persisted has spans without the admitters
    /// standing reads; the first 0.13 load refolds it once into exactly what a replica
    /// that folded under 0.13 holds.
    #[test]
    fn a_state_persisted_before_0_13_refolds_once_into_its_admitters() {
        let t = crate::crdt::hlc::wall_clock_ms() - 3_600_000;
        let sid = crate::crdt::anchor::derive_server_id(&id(1), "n");
        let history = vec![
            op_at(1, &sid, t, P::ServerCreated { name: "S".into(), owner_peer_id: id(1), nonce: "n".into() }),
            op_at(1, &sid, t + 1, add(&sid, 2)),
            op_at(1, &sid, t + 2, add(&sid, 3)),
        ];
        let mut live = joiner(&sid, 4);
        live.ingest_remote(&history);
        let want = live.member_record.clone();
        assert!(want[&id(3)].last().is_some_and(|s| s.admitted.len() == 1 && s.from_hlc.is_some()), "control: a 0.13 fold records them");

        let mut old = live.clone();
        for spans in old.member_record.values_mut() {
            for span in spans {
                span.from_hlc = None;
                span.admitted.clear();
            }
        }
        let log = std::mem::take(&mut old.op_log);
        assert!(!old.refold_for_standing() && !old.standing_folded, "a log that did not load leaves the mark unset");
        old.op_log = log;
        assert!(old.refold_for_standing(), "a state never refolded is refolded and saved");
        assert_eq!(old.member_record, want);
        assert!(!old.refold_for_standing(), "only once");
        let restored: ServerState = serde_json::from_str(&serde_json::to_string(&old).unwrap()).unwrap();
        assert!(restored.standing_folded, "the mark persists");
    }

    /// M1: after a restart the store hands the log in clock order, where a checkpoint
    /// sits at its own clock. A late op of an admin, stamped before its demotion but
    /// after what the checkpoint covers, is judged at its point on a replica that
    /// restarted exactly as on one that did not.
    #[test]
    fn a_restarted_log_with_a_checkpoint_folds_a_late_op_at_its_point() {
        let hour = 3_600_000;
        let t = crate::crdt::hlc::wall_clock_ms() - 3 * hour;
        let sid = crate::crdt::anchor::derive_server_id(&id(1), "n");
        let ch = format!("{}-general", &sid[..8]);
        let history = vec![
            op_at(1, &sid, t, P::ServerCreated { name: "S".into(), owner_peer_id: id(1), nonce: "n".into() }),
            op_at(1, &sid, t + 1, add(&sid, 2)),
            op_at(1, &sid, t + 2, P::RoleChanged { peer_id: id(2), role: MemberRole::Admin, priority: 3 }),
        ];
        let mut owner = joiner(&sid, 1);
        owner.ingest_remote(&history);
        let covers = owner.horizon();
        let json = owner.checkpoint_json(&id(1), &[], covers.physical_ms).unwrap();
        let checkpoint = owner.author_checked(P::ServerCheckpoint { state: json, covers }).unwrap();
        let demoted = op_at(1, &sid, t + hour, P::RoleChanged { peer_id: id(2), role: MemberRole::Member, priority: 4 });
        let mut live = joiner(&sid, 3);
        live.ingest_remote(&history);
        live.ingest_remote(&[checkpoint, demoted]);
        assert_eq!(live.anchor(), Anchor::Checkpoint);

        let mut restarted = live.clone();
        let mut stored = restarted.op_log.clone();
        stored.sort_by(|a, b| (a.hlc.physical_ms, a.hlc.counter, &a.author).cmp(&(b.hlc.physical_ms, b.hlc.counter, &b.author)));
        assert!(matches!(stored.last().unwrap().payload, P::ServerCheckpoint { .. }), "control: the checkpoint is the store's newest op");
        restarted.restore_op_log(stored);
        assert!(restarted.op_log.is_sorted_by(|a, b| fold_order(a, b) != std::cmp::Ordering::Greater), "a restored log is not in fold order");

        let late = op_at(2, &sid, t + hour / 2, P::ChannelRenamed { channel_id: ch.clone(), new_name: "while an admin".into() });
        for s in [&mut live, &mut restarted] {
            s.ingest_remote(std::slice::from_ref(&late));
        }
        assert_eq!(live.channels[&ch].name, "while an admin", "control: the op is judged at its point");
        assert_eq!(restarted.channels[&ch].name, live.channels[&ch].name, "a restarted replica judged a late op against its newest state");
        let keys_of = |s: &ServerState| s.op_log.iter().map(|o| (o.author.clone(), o.hlc.clone())).collect::<Vec<_>>();
        assert_eq!(keys_of(&restarted), keys_of(&live), "the logs differ after the late op");
    }

    // g13-h: siblings share the master as HLC actor, and op identity is (author, hlc).

    /// The owner's two devices, both holding `owner`'s replica, each with its own clock
    /// last stepped at `at`, and a member's replica that has `founding`.
    fn siblings_and_member(at: u64) -> (ServerState, ServerState, ServerState) {
        let (owner, founding) = founded(1);
        let mut member = joiner(&owner.server_id, 2);
        member.ingest_remote(&[founding]);
        let (mut desktop, mut phone) = (owner.clone(), owner);
        desktop.set_hlc(Hlc::for_device_at(id(1), "desktop", at));
        phone.set_hlc(Hlc::for_device_at(id(1), "phone", at));
        (desktop, phone, member)
    }

    /// What a replica converged to: the name, the settings and every op it holds.
    type Converged = (String, Vec<(String, String)>, Vec<(String, HlcTimestamp)>);

    fn converged(s: &ServerState) -> Converged {
        let mut settings: Vec<_> = s.settings.iter().map(|(k, v)| (k.clone(), v.read().clone())).collect();
        settings.sort();
        let ops = s.op_log.iter().map(|o| (o.author.clone(), o.hlc.clone())).collect();
        (s.name().to_string(), settings, ops)
    }

    /// Both orders at the member and the exchange between the siblings end in one state
    /// that holds both ops.
    fn assert_both_survive(desktop: &mut ServerState, phone: &mut ServerState, member: &ServerState, a: CrdtOp, b: CrdtOp) {
        assert_ne!(a.hlc, b.hlc, "two siblings minted one stamp");
        let (mut forward, mut reverse) = (member.clone(), member.clone());
        assert_eq!(forward.ingest_remote(std::slice::from_ref(&a)).admitted.len(), 1);
        assert_eq!(forward.ingest_remote(std::slice::from_ref(&b)).admitted.len(), 1, "the second sibling's op was taken for the first's");
        assert_eq!(reverse.ingest_remote(std::slice::from_ref(&b)).admitted.len(), 1);
        assert_eq!(reverse.ingest_remote(std::slice::from_ref(&a)).admitted.len(), 1);
        desktop.apply_op(&a).unwrap();
        desktop.ingest_remote(std::slice::from_ref(&b));
        phone.apply_op(&b).unwrap();
        phone.ingest_remote(&[a]);
        let want = converged(&forward);
        assert_eq!(converged(&reverse), want, "arrival order changed the member's state");
        assert_eq!(converged(desktop), want, "the desktop diverged");
        assert_eq!(converged(phone), want, "the phone diverged");
    }

    #[test]
    fn two_siblings_same_ms_ops_both_survive() {
        let at = crate::crdt::hlc::wall_clock_ms() + 60_000;
        let (mut desktop, mut phone, member) = siblings_and_member(at);
        let a = desktop.create_op(P::ServerRenamed { new_name: "desk".into() });
        let b = phone.create_op(P::ServerSettingChanged { key: "twitch_verification_enabled".into(), value: "true".into() });
        assert_eq!(a.hlc.physical_ms, b.hlc.physical_ms, "fixture: one millisecond");
        assert_both_survive(&mut desktop, &mut phone, &member, a, b);
    }

    /// The reviewer's probe: both devices last witnessed one op from a member whose
    /// clock runs ahead, then each writes the same register.
    #[test]
    fn two_siblings_after_a_peer_ahead_both_survive() {
        let wall = crate::crdt::hlc::wall_clock_ms();
        let (mut desktop, mut phone, mut member) = siblings_and_member(wall);
        let sid = member.server_id.clone();
        let admit = desktop.create_op(add(&sid, 2));
        let ahead = op_at(2, &sid, wall + 120_000, P::NicknameChanged { peer_id: id(2), nickname: "n".into() });
        for replica in [&mut desktop, &mut phone, &mut member] {
            replica.ingest_remote(std::slice::from_ref(&admit));
            assert_eq!(replica.ingest_remote(std::slice::from_ref(&ahead)).admitted.len(), 1);
        }
        let a = desktop.create_op(P::ServerRenamed { new_name: "desk".into() });
        let b = phone.create_op(P::ServerRenamed { new_name: "phone".into() });
        assert!(a.hlc > ahead.hlc && b.hlc > ahead.hlc);
        assert_both_survive(&mut desktop, &mut phone, &member, a, b);
    }

    /// A sibling still on the lane-less clock and one on a lane, after the same peer ahead.
    #[test]
    fn a_legacy_sibling_and_a_laned_sibling_both_survive() {
        let wall = crate::crdt::hlc::wall_clock_ms();
        let (mut legacy, mut phone, mut member) = siblings_and_member(wall);
        legacy.set_hlc(Hlc::new(id(1)));
        assert!(phone.hlc.as_ref().unwrap().lane().unwrap() > 2, "fixture lane must not meet the legacy counters");
        let sid = member.server_id.clone();
        let admit = legacy.create_op(add(&sid, 2));
        let ahead = op_at(2, &sid, wall + 120_000, P::NicknameChanged { peer_id: id(2), nickname: "n".into() });
        for replica in [&mut legacy, &mut phone, &mut member] {
            replica.ingest_remote(std::slice::from_ref(&admit));
            replica.ingest_remote(std::slice::from_ref(&ahead));
        }
        let a = legacy.create_op(P::ServerRenamed { new_name: "old".into() });
        let b = phone.create_op(P::ServerRenamed { new_name: "new".into() });
        assert_both_survive(&mut legacy, &mut phone, &member, a, b);
    }

    /// A restart reseeds the clock from the wall: whichever order the node installs the
    /// clock and the stored log in, the next op sits above every op we already hold.
    #[test]
    fn a_restarted_clock_sits_above_its_own_log() {
        let ahead = crate::crdt::hlc::wall_clock_ms() + 120_000;
        let (mut live, _, _) = siblings_and_member(ahead);
        for name in ["a", "b", "c"] {
            let op = live.create_op(P::ServerRenamed { new_name: name.into() });
            live.apply_op(&op).unwrap();
        }
        let newest = live.op_log.iter().map(|o| o.hlc.clone()).max().unwrap();

        let mut clock_first = live.clone();
        clock_first.op_log.clear();
        clock_first.op_log_dedup.clear();
        clock_first.set_hlc(Hlc::for_device(id(1), "desktop"));
        clock_first.restore_op_log(live.op_log.clone());
        assert!(clock_first.create_op(P::ServerRenamed { new_name: "d".into() }).hlc > newest, "clock then log");

        let mut log_first = live.clone();
        log_first.set_hlc(Hlc::for_device(id(1), "desktop"));
        assert!(log_first.create_op(P::ServerRenamed { new_name: "d".into() }).hlc > newest, "log then clock");
    }

    /// A wall stepped back past the drift bound: our clock may not adopt our own newer
    /// ops, and must still never mint a stamp one of them holds.
    #[test]
    fn a_stamp_we_already_hold_is_never_minted_again() {
        let far = crate::crdt::hlc::wall_clock_ms() + crate::crdt::hlc::MAX_DRIFT_MS + 600_000;
        let (mut live, _, _) = siblings_and_member(far);
        let mut held = Vec::new();
        for name in ["a", "b", "c"] {
            let op = live.create_op(P::ServerRenamed { new_name: name.into() });
            live.apply_op(&op).unwrap();
            held.push(op.hlc);
        }
        live.set_hlc(Hlc::for_device_at(id(1), "desktop", far));
        let next = live.create_op(P::ServerRenamed { new_name: "d".into() });
        assert!(!held.contains(&next.hlc), "re-minted {:?}", next.hlc);
    }

    /// A restart witnesses the newest stamp the drift bound lets in, once: an own op
    /// past the bound (a wall that stepped back) does not hide the ones inside it.
    #[test]
    fn a_restart_witnesses_the_newest_stamp_inside_the_bound() {
        let wall = crate::crdt::hlc::wall_clock_ms();
        let (mut live, _, _) = siblings_and_member(wall + 60_000);
        let near = live.create_op(P::ServerRenamed { new_name: "near".into() });
        live.apply_op(&near).unwrap();
        live.set_hlc(Hlc::for_device_at(id(1), "desktop", wall + crate::crdt::hlc::MAX_DRIFT_MS + 600_000));
        let far = live.create_op(P::ServerRenamed { new_name: "far".into() });
        live.apply_op(&far).unwrap();

        live.set_hlc(Hlc::for_device(id(1), "desktop"));
        assert!(live.create_op(P::ServerRenamed { new_name: "next".into() }).hlc > near.hlc, "the op inside the bound was not witnessed");
    }

    /// Only admitted ops move our clock: a held op, refused for now, does not date the
    /// next write after a restart either.
    #[test]
    fn a_held_op_does_not_date_our_clock_after_a_restart() {
        let (owner, founding) = founded(1);
        let sid = owner.server_id.clone();
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&[founding]);
        let wall = crate::crdt::hlc::wall_clock_ms();
        let early = op_at(2, &sid, wall + 120_000, P::NicknameChanged { peer_id: id(2), nickname: "n".into() });
        assert!(r.ingest_remote(&[early]).admitted.is_empty());
        assert!(!r.held.is_empty(), "fixture: the op of a member not yet admitted is held");
        r.set_hlc(Hlc::for_device(id(9), "device"));
        assert!(r.create_op(P::ServerRenamed { new_name: "x".into() }).hlc.physical_ms < wall + 60_000, "a held op moved our clock");
    }

    /// A rejoin's admission, on a fresh ask of its own.
    fn readd(sid: &str, tag: u8, at: i64) -> P {
        let ask = crate::crdt::operations::JoinAsk::sign(sid, at, &keys(tag).0);
        P::MemberAdded { peer_id: id(tag), display_name: "m".into(), follow: None, ask: Some(ask) }
    }

    /// Owner 1 founds S at `t`; 2 joins at t+1 and 3 at t+2; the owner renames at t+10
    /// and checkpoints there, never having seen 2's own leave at t+5. Returns S, the ops
    /// a replica needs (founding, checkpoint), the owner, the leave and `t`.
    fn behind_a_checkpoint() -> (String, Vec<CrdtOp>, ServerState, CrdtOp, u64) {
        let (sid, _, anchor, owner, leave, t) = behind_a_checkpoint_with_history();
        (sid, anchor, owner, leave, t)
    }

    /// [`behind_a_checkpoint`], with the history the checkpoint covers.
    fn behind_a_checkpoint_with_history() -> (String, Vec<CrdtOp>, Vec<CrdtOp>, ServerState, CrdtOp, u64) {
        let t = crate::crdt::hlc::wall_clock_ms() - 3 * 3_600_000;
        let sid = crate::crdt::anchor::derive_server_id(&id(1), "n");
        let created = op_at(1, &sid, t, P::ServerCreated { name: "S".into(), owner_peer_id: id(1), nonce: "n".into() });
        let history = vec![
            created.clone(),
            op_at(1, &sid, t + 1, add(&sid, 2)),
            op_at(1, &sid, t + 2, add(&sid, 3)),
            op_at(1, &sid, t + 10, P::ServerRenamed { new_name: "moved on".into() }),
        ];
        let mut owner = joiner(&sid, 1);
        owner.ingest_remote(&history);
        let covers = owner.horizon();
        let json = owner.checkpoint_json(&id(1), &[], covers.physical_ms).unwrap();
        let checkpoint = owner.author_checked(P::ServerCheckpoint { state: json, covers }).unwrap();
        let leave = op_at(2, &sid, t + 5, P::MemberRemoved { peer_id: id(2) });
        (sid, history, vec![created, checkpoint], owner, leave, t)
    }

    fn holds(s: &ServerState, op: &CrdtOp) -> bool {
        s.op_log.iter().any(|o| o.author == op.author && o.hlc == op.hlc)
    }

    /// t14 item 2b: a member's own leave that reaches the owner behind the owner's
    /// checkpoint ends its span there at the leave's own clock, stays in the log across
    /// a restart, and a later checkpoint that already reflects it lets it go.
    #[test]
    fn a_members_own_leave_behind_a_checkpoint_still_ends_its_span() {
        let (sid, history, anchor, mut owner, leave, t) = behind_a_checkpoint_with_history();
        assert!(owner.is_member(&id(2)) && owner.checkpoint_hlc.as_ref().is_some_and(|c| *c > leave.hlc), "fixture");
        let out = owner.ingest_remote(std::slice::from_ref(&leave));
        assert!(!owner.is_member(&id(2)), "the owner still counts a member whose own leave came behind its checkpoint");
        assert!(owner.is_member(&id(3)), "another member is untouched");
        assert_eq!(owner.member_record[&id(2)].last().unwrap().until_ms, t + 5, "the span ends at the leave's own clock");
        assert!(holds(&owner, &leave) && out.admitted.iter().any(|o| o.hlc == leave.hlc), "the leave is kept and stored");

        // A replica handed the checkpoint and the leave together folds the same.
        let mut replica = joiner(&sid, 9);
        replica.ingest_remote(&[anchor.clone(), vec![leave.clone()]].concat());
        assert!(!replica.is_member(&id(2)) && holds(&replica, &leave));
        let base = replica.checkpoint_hlc.clone().unwrap();
        let entries = crate::crdt::digest::entries(&replica, &[], Some(&base));
        assert_eq!(entries.len(), crate::crdt::digest::entries(&owner, &[], Some(&base)).len(), "both replicas fingerprint the same ops");
        assert!(
            entries.iter().any(|e| matches!(e.item, crate::crdt::digest::Item::Op(o) if o.hlc == leave.hlc)),
            "the digest leaves out the late leave, so a replica without it never asks",
        );

        // A replica that took the leave in its place, then the owner's checkpoint that
        // never saw it, keeps 2 out.
        let mut early = joiner(&sid, 8);
        early.ingest_remote(&history);
        early.ingest_remote(std::slice::from_ref(&leave));
        assert!(!early.is_member(&id(2)), "fixture");
        let out = early.ingest_remote(&anchor[1..]);
        assert!(!early.is_member(&id(2)) && holds(&early, &leave), "a checkpoint that never saw the leave undid it");
        assert!(out.admitted.iter().any(|o| o.hlc == leave.hlc), "storing the checkpoint would drop the late leave");

        // A restart restores the log from the store and the state from its snapshot.
        let mut restarted: ServerState = serde_json::from_str(&serde_json::to_string(&owner).unwrap()).unwrap();
        restarted.restore_op_log(owner.op_log.clone());
        assert!(holds(&restarted, &leave), "a restart drops the late leave from the log");
        assert!(restarted.retains(&leave, &base, true));

        // The owner's next checkpoint lists 2 as gone: the leave is history now.
        owner.author_checked(P::ServerRenamed { new_name: "again".into() }).unwrap();
        let covers = owner.horizon();
        let json = owner.checkpoint_json(&id(1), &[], crate::crdt::hlc::wall_clock_ms()).unwrap();
        owner.author_checked(P::ServerCheckpoint { state: json, covers }).unwrap();
        assert!(!holds(&owner, &leave) && owner.late_leaves.is_empty(), "a checkpoint that reflects the leave still keeps it");
        assert!(!owner.is_member(&id(2)));
    }

    /// A rejoin admitted after the leave still wins after the checkpoint or recorded in
    /// the span the checkpoint lists; one before the checkpoint that it never folded
    /// loses, as everything a checkpoint's author never saw.
    #[test]
    fn a_rejoin_after_the_late_leave_still_wins() {
        let (sid, anchor, owner, leave, t) = behind_a_checkpoint();
        // After the checkpoint.
        let mut after = owner.clone();
        after.ingest_remote(&[op_at(1, &sid, t + 20, readd(&sid, 2, (t + 20) as i64))]);
        after.ingest_remote(std::slice::from_ref(&leave));
        assert!(after.is_member(&id(2)), "a rejoin after the checkpoint lost to an older leave");

        // Before the checkpoint, in the batch that brings the leave: the checkpoint never
        // folded it, so it is history the checkpoint overwrote.
        let mut replica = joiner(&sid, 9);
        replica.ingest_remote(&anchor);
        replica.ingest_remote(&[leave.clone(), op_at(1, &sid, t + 7, readd(&sid, 2, (t + 7) as i64))]);
        assert!(!replica.is_member(&id(2)), "a rejoin the checkpoint never folded beat the late leave");
        assert!(holds(&replica, &leave));

        // Recorded in the span: another admitter took 2 in again after the leave.
        let t2 = t;
        let created = anchor[0].clone();
        let history = vec![
            created,
            op_at(1, &sid, t2 + 1, add(&sid, 2)),
            op_at(1, &sid, t2 + 2, add(&sid, 3)),
            op_at(1, &sid, t2 + 3, P::RoleChanged { peer_id: id(3), role: MemberRole::Admin, priority: 3 }),
            op_at(3, &sid, t2 + 7, readd(&sid, 2, (t2 + 7) as i64)),
            op_at(1, &sid, t2 + 10, P::ServerRenamed { new_name: "moved on".into() }),
        ];
        let mut owner2 = joiner(&sid, 1);
        owner2.ingest_remote(&history);
        assert!(owner2.member_record[&id(2)].last().unwrap().admitted.iter().any(|(a, _)| *a == id(3)), "fixture");
        let covers = owner2.horizon();
        let json = owner2.checkpoint_json(&id(1), &[], covers.physical_ms).unwrap();
        owner2.author_checked(P::ServerCheckpoint { state: json, covers }).unwrap();
        owner2.ingest_remote(std::slice::from_ref(&leave));
        assert!(owner2.is_member(&id(2)), "a span re-admitted after the leave was closed by it");

        // The checkpoint already folded the leave and a rejoin by the same admitter: the
        // span it lists opened after the leave.
        let history = vec![
            anchor[0].clone(),
            op_at(1, &sid, t + 1, add(&sid, 2)),
            leave.clone(),
            op_at(1, &sid, t + 7, readd(&sid, 2, (t + 7) as i64)),
            op_at(1, &sid, t + 10, P::ServerRenamed { new_name: "moved on".into() }),
        ];
        let mut owner3 = joiner(&sid, 1);
        owner3.ingest_remote(&history);
        assert!(owner3.is_member(&id(2)), "fixture");
        let covers = owner3.horizon();
        let json = owner3.checkpoint_json(&id(1), &[], covers.physical_ms).unwrap();
        let checkpoint = owner3.author_checked(P::ServerCheckpoint { state: json, covers }).unwrap();
        let mut late = joiner(&sid, 9);
        late.ingest_remote(&[anchor[0].clone(), checkpoint]);
        late.ingest_remote(std::slice::from_ref(&leave));
        assert!(late.is_member(&id(2)), "a leave from before the span the checkpoint lists closed it");
    }

    /// Only a member's own leave, from a member the checkpoint lists, changes anything:
    /// a stranger's leave and one member removing another stay as they were.
    #[test]
    fn only_a_listed_members_own_leave_outlives_a_checkpoint() {
        let (sid, _, owner, _, t) = behind_a_checkpoint();
        let mut s = owner.clone();
        let stranger = op_at(4, &sid, t + 5, P::MemberRemoved { peer_id: id(4) });
        let other = op_at(3, &sid, t + 5, P::MemberRemoved { peer_id: id(2) });
        let owners = op_at(1, &sid, t + 6, P::MemberRemoved { peer_id: id(1) });
        s.ingest_remote(&[stranger.clone(), other.clone(), owners.clone()]);
        assert!(s.is_member(&id(2)) && s.is_member(&id(3)) && s.is_member(&id(1)), "a removal that is no listed member's own leave took effect");
        assert!(!holds(&s, &stranger) && !holds(&s, &other) && !holds(&s, &owners) && s.late_leaves.is_empty());

        // A span with no exact opening clock (seeded, or older than 0.13) proves nothing
        // about when it opened.
        let (_, history, _, mut seeded, leave, _) = behind_a_checkpoint_with_history();
        seeded.ingest_remote(&history);
        let mut base: ServerState = serde_json::from_str(&seeded.checkpoint_json(&id(1), &[], t + 11).unwrap()).unwrap();
        let span = base.member_record.get_mut(&id(2)).unwrap().last_mut().unwrap();
        span.from_hlc = None;
        span.admitted.clear();
        seeded.author_checked(P::ServerRenamed { new_name: "again".into() }).unwrap();
        let covers = seeded.horizon();
        let checkpoint = op_at(1, &sid, covers.physical_ms + 1, P::ServerCheckpoint { state: serde_json::to_string(&base).unwrap(), covers });
        let mut replica = joiner(&sid, 9);
        replica.ingest_remote(&[history[0].clone(), checkpoint]);
        assert!(replica.is_member(&id(2)), "fixture");
        replica.ingest_remote(std::slice::from_ref(&leave));
        assert!(replica.is_member(&id(2)), "a leave closed a span with no exact opening clock");
    }

    /// Replicas holding the same ops agree, whatever order they arrived in.
    #[test]
    fn a_late_leave_folds_the_same_in_any_arrival_order() {
        let (sid, anchor, _, leave, t) = behind_a_checkpoint();
        let later = op_at(1, &sid, t + 30, P::ServerRenamed { new_name: "later".into() });
        let leave3 = op_at(3, &sid, t + 6, P::MemberRemoved { peer_id: id(3) });
        let rejoin = op_at(1, &sid, t + 40, readd(&sid, 3, (t + 40) as i64));
        let ops = [anchor.clone(), vec![leave.clone(), later, leave3, rejoin]].concat();
        let view = |s: &ServerState| {
            let mut log: Vec<(String, HlcTimestamp)> = s.op_log.iter().map(|o| (o.author.clone(), o.hlc.clone())).collect();
            log.sort();
            let mut members: Vec<String> = s.members.keys().cloned().collect();
            members.sort();
            let spans: Vec<(u64, u64)> = [id(2), id(3)].iter().flat_map(|m| s.member_record[m].iter().map(|sp| (sp.from_ms, sp.until_ms))).collect();
            (log, members, spans)
        };
        let mut together = joiner(&sid, 9);
        together.ingest_remote(&ops);
        let expected = view(&together);
        assert!(!expected.1.contains(&id(2)) && expected.1.contains(&id(3)));
        for order in [vec![0, 1, 2, 3, 4, 5], vec![0, 1, 5, 4, 3, 2], vec![0, 1, 3, 2, 5, 4], vec![2, 4, 0, 1, 5, 3]] {
            let mut s = joiner(&sid, 9);
            for i in &order {
                s.ingest_remote(std::slice::from_ref(&ops[*i]));
            }
            assert_eq!(view(&s), expected, "arrival order {order:?} folded differently");
        }
    }

    /// The log keeps at most one late leave per member the checkpoint lists: a second
    /// leave of the same member, or a flood of them, keeps nothing more.
    #[test]
    fn late_leaves_are_bounded_by_the_members_a_checkpoint_lists() {
        let (sid, _, owner, leave, t) = behind_a_checkpoint();
        let mut s = owner.clone();
        let mut flood = vec![leave.clone()];
        for i in 0..50 {
            flood.push(op_at(2, &sid, t + 6 + i, P::MemberRemoved { peer_id: id(2) }));
            flood.push(op_at(3, &sid, t + 3 + (i % 5), P::MemberRemoved { peer_id: id(3) }));
        }
        s.ingest_remote(&flood);
        let base = s.checkpoint_hlc.clone().unwrap();
        let below: Vec<&CrdtOp> = s.op_log.iter().filter(|o| o.hlc < base && !matches!(o.payload, P::ServerCreated { .. })).collect();
        assert_eq!(below.len(), 2, "one late leave per listed member, got {}", below.len());
        assert!(s.late_leaves.len() <= s.member_record.len());
        assert!(!s.is_member(&id(2)) && !s.is_member(&id(3)));
    }

    /// Production saves `lean_snapshot()`, which carries no `late_leaves`: a restart
    /// judges the stored late leave again, so the next rebuild keeps the leaver out.
    #[test]
    fn late_leave_survives_a_lean_snapshot_restart() {
        let (sid, _, _, mut owner, leave, t) = behind_a_checkpoint_with_history();
        owner.ingest_remote(&[op_at(1, &sid, t + 40, P::ServerRenamed { new_name: "tail".into() })]);
        owner.ingest_remote(std::slice::from_ref(&leave));
        assert!(!owner.is_member(&id(2)) && holds(&owner, &leave), "fixture");
        // What CrdtStore writes, and the rows the DB hands back on start.
        let json = serde_json::to_string(&owner.lean_snapshot()).unwrap();
        let mut restarted: ServerState = serde_json::from_str(&json).unwrap();
        restarted.restore_op_log(owner.op_log.clone());
        let base = restarted.checkpoint_hlc.clone().unwrap();
        let ours = crate::crdt::digest::entries(&restarted, &[], Some(&base)).len();
        let theirs = crate::crdt::digest::entries(&owner, &[], Some(&base)).len();
        // Any op older than the tail rebuilds from the checkpoint.
        restarted.ingest_remote(&[op_at(1, &sid, t + 20, P::ServerRenamed { new_name: "mid".into() })]);
        assert!(!restarted.is_member(&id(2)), "a rebuild after a restart counts the leaver again");
        assert!(holds(&restarted, &leave), "a restart dropped the late leave from the log");
        assert_eq!(ours, theirs, "a restarted replica fingerprints a different op set");
    }

    /// The verdict on a late leave never depends on which batch a rejoin the checkpoint
    /// never saw rode in.
    #[test]
    fn late_leave_and_unseen_rejoin_fold_the_same_in_either_order() {
        let (sid, anchor, _, leave, t) = behind_a_checkpoint();
        let rejoin = op_at(3, &sid, t + 7, readd(&sid, 2, (t + 7) as i64));
        let mut leave_first = joiner(&sid, 9);
        leave_first.ingest_remote(&anchor);
        leave_first.ingest_remote(std::slice::from_ref(&leave));
        leave_first.ingest_remote(std::slice::from_ref(&rejoin));
        let mut rejoin_first = joiner(&sid, 8);
        rejoin_first.ingest_remote(&anchor);
        rejoin_first.ingest_remote(std::slice::from_ref(&rejoin));
        rejoin_first.ingest_remote(std::slice::from_ref(&leave));
        assert_eq!(
            (leave_first.is_member(&id(2)), holds(&leave_first, &leave)),
            (rejoin_first.is_member(&id(2)), holds(&rejoin_first, &leave)),
            "two replicas holding the same ops disagree on 2's membership",
        );
    }

    /// A signed `MemberAdded` naming the leaver that the fold refuses (a stranger's, with
    /// no ask) does not stop a late leave from landing.
    #[test]
    fn a_refused_admission_does_not_cancel_a_late_leave() {
        let (sid, anchor, _, leave, t) = behind_a_checkpoint();
        let junk = op_at(4, &sid, t + 6, P::MemberAdded { peer_id: id(2), display_name: "m".into(), follow: None, ask: None });
        let mut s = joiner(&sid, 9);
        s.ingest_remote(&anchor);
        s.ingest_remote(&[leave.clone(), junk]);
        assert!(!s.is_member(&id(2)), "a stranger's refused admission kept the leaver a member");
    }

    /// A batch carrying history plus the checkpoint reports as admitted only the
    /// self-leaves below the base the log keeps, so the store re-inserts only those.
    #[test]
    fn store_reinserts_only_leaves_the_fold_kept() {
        let t = crate::crdt::hlc::wall_clock_ms() - 3 * 3_600_000;
        let sid = crate::crdt::anchor::derive_server_id(&id(1), "n");
        let created = op_at(1, &sid, t, P::ServerCreated { name: "S".into(), owner_peer_id: id(1), nonce: "n".into() });
        let gone = op_at(3, &sid, t + 5, P::MemberRemoved { peer_id: id(3) });
        let history = vec![
            created,
            op_at(1, &sid, t + 1, add(&sid, 2)),
            op_at(1, &sid, t + 2, add(&sid, 3)),
            gone.clone(),
            op_at(1, &sid, t + 10, P::ServerRenamed { new_name: "moved on".into() }),
        ];
        let mut owner = joiner(&sid, 1);
        owner.ingest_remote(&history);
        let covers = owner.horizon();
        let json = owner.checkpoint_json(&id(1), &[], covers.physical_ms).unwrap();
        let checkpoint = owner.author_checked(P::ServerCheckpoint { state: json, covers }).unwrap();
        let mut late = joiner(&sid, 9);
        let out = late.ingest_remote(&[history, vec![checkpoint]].concat());
        assert!(!holds(&late, &gone), "fixture: the checkpoint reflects 3's leave");
        let store = crate::storage::MessageStore::open(":memory:", &"ab".repeat(32)).unwrap();
        store.persist_admitted_ops(&out.admitted, late.checkpoint_hlc.as_ref());
        let stored = store.load_ops_for_server(&sid, None).unwrap();
        assert!(
            !stored.iter().any(|o| o.author == gone.author && o.hlc == gone.hlc),
            "the store kept a leave the fold dropped",
        );
    }

    /// A batch of junk a checkpoint covers costs about what the same junk above it does,
    /// never quadratic time on the event loop.
    #[test]
    fn refused_junk_below_a_checkpoint_costs_linear_time() {
        let (sid, anchor, _, _, t) = behind_a_checkpoint();
        let junk = |base: u64| -> Vec<CrdtOp> {
            (0..20_000u64).map(|i| {
                let (kp, id, pk) = keys(4);
                let mut op = CrdtOp {
                    server_id: sid.clone(),
                    hlc: HlcTimestamp { physical_ms: base, counter: i as u32, actor: id.clone() },
                    author: id,
                    payload: P::ServerRenamed { new_name: "x".into() },
                    auth: None,
                };
                op.sign(&kp, &pk);
                op
            }).collect()
        };
        let time = |ops: &[CrdtOp]| {
            let mut s = joiner(&sid, 9);
            s.ingest_remote(&anchor);
            let at = std::time::Instant::now();
            s.ingest_remote(ops);
            at.elapsed()
        };
        let below = time(&junk(t + 6));
        let above = time(&junk(t + 60));
        assert!(below < above * 3, "junk below a checkpoint costs {below:?}, above it {above:?}");
    }

    /// What a restart restores: the lean snapshot production saves, the rows the store
    /// keeps of every batch persisted as the node persists it.
    fn restart_from(s: &ServerState, store: &crate::storage::MessageStore) -> ServerState {
        let mut r: ServerState = serde_json::from_str(&serde_json::to_string(&s.lean_snapshot()).unwrap()).unwrap();
        r.restore_op_log(store.load_ops_for_server(&s.server_id, None).unwrap());
        r
    }

    fn ingest_and_store(s: &mut ServerState, store: &crate::storage::MessageStore, ops: &[CrdtOp]) {
        let out = s.ingest_remote(ops);
        store.persist_admitted_ops(&out.admitted, s.checkpoint_hlc.as_ref());
    }

    type FoldView = (Vec<String>, Vec<(u64, u64)>, Vec<(String, HlcTimestamp)>, Vec<(String, HlcTimestamp)>);

    /// Membership, spans, the log and the digest a replica's peers see.
    fn fold_view(s: &ServerState) -> FoldView {
        let mut members: Vec<String> = s.members.keys().cloned().collect();
        members.sort();
        let spans = [id(2), id(3)].iter().flat_map(|m| s.member_record[m].iter().map(|sp| (sp.from_ms, sp.until_ms))).collect();
        let mut log: Vec<(String, HlcTimestamp)> = s.op_log.iter().map(|o| (o.author.clone(), o.hlc.clone())).collect();
        log.sort();
        let digest = crate::crdt::digest::entries(s, &[], s.checkpoint_hlc.as_ref())
            .iter()
            .filter_map(|e| match e.item {
                crate::crdt::digest::Item::Op(o) => Some((o.author.clone(), o.hlc.clone())),
                crate::crdt::digest::Item::Raw(_) => None,
            })
            .collect();
        (members, spans, log, digest)
    }

    /// A late leave survives the real save path (lean snapshot + `persist_admitted_ops` +
    /// `restore_op_log`), whether it came after the checkpoint or before it, and a
    /// rebuild after the restart still keeps the leaver out.
    #[test]
    fn a_late_leave_survives_the_production_save_path() {
        let (sid, history, anchor, _, leave, t) = behind_a_checkpoint_with_history();
        let mid = op_at(1, &sid, t + 20, P::ServerRenamed { new_name: "mid".into() });
        let tail = op_at(1, &sid, t + 40, P::ServerRenamed { new_name: "tail".into() });
        // The leave after the checkpoint, and the leave first with the checkpoint after.
        for batches in [vec![anchor.clone(), vec![tail.clone()], vec![leave.clone()]], vec![history.clone(), vec![leave.clone()], anchor[1..].to_vec(), vec![tail.clone()]]] {
            let store = crate::storage::MessageStore::open(":memory:", &"ab".repeat(32)).unwrap();
            let mut live = joiner(&sid, 9);
            for batch in &batches {
                ingest_and_store(&mut live, &store, batch);
            }
            assert!(!live.is_member(&id(2)) && holds(&live, &leave), "fixture");
            let mut restarted = restart_from(&live, &store);
            assert_eq!(fold_view(&restarted), fold_view(&live), "a restart folds a different state or digest");
            ingest_and_store(&mut live, &store, std::slice::from_ref(&mid));
            ingest_and_store(&mut restarted, &store, std::slice::from_ref(&mid));
            assert!(!restarted.is_member(&id(2)) && holds(&restarted, &leave), "a rebuild after a restart counts the leaver again");
            assert_eq!(fold_view(&restarted), fold_view(&live));
            assert_eq!(fold_view(&restart_from(&restarted, &store)), fold_view(&live), "a second restart drifted");
        }
    }

    /// Late leaves count in the digest only under the checkpoint that judged them: a
    /// replica still on an older checkpoint never offers one to a peer whose newer
    /// checkpoint reflects it (the peer would drop it and be offered it again), and once
    /// it takes the newer checkpoint the two stop asking.
    #[test]
    fn replicas_on_different_checkpoints_do_not_trade_a_late_leave() {
        use crate::crdt::digest::{answer, entries, first_ask, new_salt, Item};
        let (sid, anchor, mut owner, leave, _) = behind_a_checkpoint();
        let mut behind = joiner(&sid, 9);
        behind.ingest_remote(&[anchor.clone(), vec![leave.clone()]].concat());
        owner.ingest_remote(std::slice::from_ref(&leave));
        owner.author_checked(P::ServerRenamed { new_name: "again".into() }).unwrap();
        let covers = owner.horizon();
        let json = owner.checkpoint_json(&id(1), &[], crate::crdt::hlc::wall_clock_ms()).unwrap();
        owner.author_checked(P::ServerCheckpoint { state: json, covers }).unwrap();
        assert!(holds(&behind, &leave) && !holds(&owner, &leave), "fixture");
        let exchange = |asker: &mut ServerState, answerer: &ServerState| -> Vec<CrdtOp> {
            let base = asker.checkpoint_hlc.clone();
            let ask = first_ask(&entries(asker, &[], base.as_ref()), 1, new_salt(), base.clone());
            let (items, _) = answer(&entries(answerer, &[], base.as_ref()), &ask).unwrap();
            let ops: Vec<CrdtOp> = items.iter().filter_map(|i| match i { Item::Op(o) => Some((*o).clone()), Item::Raw(_) => None }).collect();
            asker.ingest_remote(&ops);
            ops
        };
        for _ in 0..2 {
            let sent = exchange(&mut owner, &behind);
            assert!(sent.iter().all(|o| holds(&owner, o)), "a replica on an older checkpoint offered an op the asker drops");
        }
        exchange(&mut behind, &owner);
        assert_eq!(behind.checkpoint_hlc, owner.checkpoint_hlc, "fixture: the replica takes the newer checkpoint");
        let salt = new_salt();
        let base = owner.checkpoint_hlc.clone();
        let print = |s: &ServerState| first_ask(&entries(s, &[], base.as_ref()), 1, salt.clone(), base.clone()).ranges;
        assert_eq!(print(&behind), print(&owner), "two replicas holding the same ops keep asking");
    }

    /// Two leaves of one member that the checkpoint both covers: the earlier one ends the
    /// span, whether the replica admitted the later one at its place (it held the history
    /// of a kick and a rejoin the owner never saw) or started from the anchor.
    #[test]
    fn two_late_leaves_of_one_member_fold_the_same_from_history_or_anchor() {
        let t = crate::crdt::hlc::wall_clock_ms() - 3 * 3_600_000;
        let sid = crate::crdt::anchor::derive_server_id(&id(1), "n");
        let created = op_at(1, &sid, t, P::ServerCreated { name: "S".into(), owner_peer_id: id(1), nonce: "n".into() });
        let seen = vec![
            created.clone(),
            op_at(1, &sid, t + 1, add(&sid, 2)),
            op_at(1, &sid, t + 2, add(&sid, 3)),
            op_at(1, &sid, t + 3, P::RoleChanged { peer_id: id(3), role: MemberRole::Admin, priority: 3 }),
            op_at(1, &sid, t + 20, P::ServerRenamed { new_name: "moved on".into() }),
        ];
        let mut owner = joiner(&sid, 1);
        owner.ingest_remote(&seen);
        let covers = owner.horizon();
        let json = owner.checkpoint_json(&id(1), &[], covers.physical_ms).unwrap();
        let checkpoint = owner.author_checked(P::ServerCheckpoint { state: json, covers }).unwrap();
        let first = op_at(2, &sid, t + 6, P::MemberRemoved { peer_id: id(2) });
        let unseen = vec![
            op_at(3, &sid, t + 4, P::MemberRemoved { peer_id: id(2) }),
            first.clone(),
            op_at(3, &sid, t + 7, readd(&sid, 2, (t + 7) as i64)),
            op_at(2, &sid, t + 8, P::MemberRemoved { peer_id: id(2) }),
        ];
        let late_nick = op_at(1, &sid, t + 5, P::NicknameChanged { peer_id: id(1), nickname: "o".into() });

        let mut history = joiner(&sid, 9);
        for op in seen[..4].iter().chain(&unseen) {
            history.ingest_remote(std::slice::from_ref(op));
        }
        assert!(holds(&history, &unseen[3]) && !holds(&history, &first), "fixture: the later leave was admitted, the earlier refused");
        history.ingest_remote(&[late_nick.clone(), checkpoint.clone()]);

        let mut anchored = joiner(&sid, 8);
        anchored.ingest_remote(&[created, checkpoint]);
        anchored.ingest_remote(&[unseen.clone(), vec![late_nick]].concat());

        for s in [&history, &anchored] {
            assert!(!s.is_member(&id(2)) && holds(s, &first), "the earlier late leave does not end the span");
            assert_eq!(s.member_record[&id(2)].last().unwrap().until_ms, t + 6);
        }
        assert_eq!(fold_view(&history), fold_view(&anchored), "the history a replica held decided the verdict");
    }

    /// `late_leaves` is derived by the fold alone: never written into a saved or sent
    /// state, and a peer's JSON naming one is not believed.
    #[test]
    fn late_leaves_are_never_stored_or_read_from_a_peer() {
        let (_, _, mut owner, leave, _) = behind_a_checkpoint();
        owner.ingest_remote(std::slice::from_ref(&leave));
        assert!(!owner.late_leaves.is_empty(), "fixture");
        let mut json: serde_json::Value = serde_json::to_value(&owner).unwrap();
        assert!(json.get("late_leaves").is_none(), "a saved state carries late leaves");
        json["late_leaves"] = serde_json::to_value(vec![(id(4), leave.hlc.clone())]).unwrap();
        let read: ServerState = serde_json::from_value(json).unwrap();
        assert!(read.late_leaves.is_empty(), "a peer's state named a late leave and was believed");
    }
}
