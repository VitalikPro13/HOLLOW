//! The settling an owner device writes when one of its devices was lost or stolen
//! (DEVICE_PROOF_DESIGN 8.3 step 4): the state of a restore point R first folded here
//! before T, plus every op held that counted then, the dropped devices' only if this
//! replica stored them before T; shaped as a child of the current base, carrying the
//! stamp whose `SettleSign` marks confine eligibility to its line (section 7).

use std::collections::HashMap;
use std::sync::Arc;

use super::authority::AuthorityView;
use super::operations::{CrdtOp, CrdtPayload, SettleStamp};
use super::server_state::ServerState;
use crate::identity::native_identity::NativeKeypair;
use crate::identity::roster::Roster;

/// When this replica first stored each op, by (author, clock ms, counter)
/// (`MessageStore::op_seen_ms`).
pub(crate) type SeenAt = HashMap<(String, u64, u32), u64>;

/// What a settling needs from the person and the store.
pub(crate) struct Settling<'a> {
    /// The view from before the removal: what counted while the devices were ours.
    pub(crate) before: Arc<AuthorityView>,
    pub(crate) dropped: &'a [String],
    pub(crate) t_ms: u64,
    pub(crate) seen: &'a SeenAt,
    /// Our compacted roster, holding the removal.
    pub(crate) roster: Roster,
}

/// Where a settling stands and which checkpoint's state it folds.
#[derive(Debug, Clone)]
pub(crate) enum SettleOn {
    /// A child of our base folding our restore point for T (section 8.3).
    Restore,
    /// A child of the witnessed checkpoint X folding X (section 8.4).
    Witnessed(Box<CrdtOp>),
    /// "I don't know" (section 8.4): a child of our base folding the newest checkpoint a
    /// device we still count wrote, else the oldest generation-0 one, else the founding op.
    Rollback,
}

fn is_checkpoint(op: &CrdtOp) -> bool {
    matches!(op.payload, CrdtPayload::ServerCheckpoint { .. })
}

impl ServerState {
    /// R (section 8.3): of the checkpoints whose content this replica holds, the one it
    /// first folded last before `t_ms`; `None` folds from the founding op.
    pub(crate) fn restore_for(&self, t_ms: u64) -> Option<CrdtOp> {
        self.op_log
            .iter()
            .chain(self.stored.iter().map(|(o, _)| o))
            .filter(|o| is_checkpoint(o))
            .filter_map(|o| self.first_folds.get(&hex::encode(self.content_of(o))).filter(|f| **f < t_ms).map(|f| (o, *f)))
            .max_by(|a, b| a.1.cmp(&b.1).then_with(|| a.0.hlc.cmp(&b.0.hlc)))
            .map(|(o, _)| o.clone())
    }

    /// T for this server (section 8.1): `t_ms`, or for "not sure" (0) the first fold of
    /// the oldest restore point held here.
    pub(crate) fn lost_t(&self, t_ms: u64) -> u64 {
        if t_ms > 0 {
            return t_ms;
        }
        self.first_folds.values().copied().min().unwrap_or(0)
    }

    /// The checkpoint a rollback settling folds, for its fetch round.
    pub(crate) fn rollback_base(&self, me: &str) -> Option<CrdtOp> {
        self.rollback_point(me)
    }

    /// R of a rollback settling (`SettleOn::Rollback`).
    fn rollback_point(&self, me: &str) -> Option<CrdtOp> {
        let held = || self.op_log.iter().chain(self.stored.iter().map(|(o, _)| o)).filter(|o| is_checkpoint(o) && o.author == me);
        let kept = held()
            .filter(|o| o.proven_device().is_some_and(|d| self.authority.counts(me, d)))
            .filter_map(|o| self.base_of_content(o).map(|b| (b.generation, o)))
            .max_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.hlc.cmp(&b.1.hlc)));
        if let Some((_, o)) = kept {
            return Some(o.clone());
        }
        held()
            .filter(|o| self.base_of_content(o).is_some_and(|b| b.generation == 0))
            .min_by(|a, b| a.hlc.cmp(&b.hlc))
            .cloned()
    }

    /// HOL-SEC-221: the founding op a settling keeps even when a dropped device wrote it
    /// and this device first stored it at or after T: it is R when no checkpoint precedes
    /// T, and names the owner a checkpoint R must come from. Of the held ops founding this
    /// self-certifying id, only the one first stored here; another one a lost device
    /// minted with the master key passes only the dropped devices' rule.
    fn founding_stand(&self, seen: &SeenAt) -> Option<[u8; 32]> {
        let founds = |o: &CrdtOp| {
            matches!(&o.payload, CrdtPayload::ServerCreated { owner_peer_id, nonce, .. }
                if o.author == *owner_peer_id && super::anchor::derive_server_id(owner_peer_id, nonce) == self.server_id)
        };
        let first_seen = |o: &CrdtOp| seen.get(&(o.author.clone(), o.hlc.physical_ms, o.hlc.counter)).copied().unwrap_or(u64::MAX);
        self.op_log
            .iter()
            .chain(self.stored.iter().map(|(o, _)| o))
            .filter(|o| founds(o))
            .min_by(|a, b| first_seen(a).cmp(&first_seen(b)).then_with(|| super::server_state::fold_order(a, b)))
            .map(CrdtOp::content_hash)
    }

    /// The ops a settling folds on R: what counted before the removal, a dropped device's
    /// only when stored here before T (its founding op aside); no checkpoint but R.
    fn settling_input(&mut self, r: Option<&CrdtOp>, s: &Settling<'_>) -> Vec<CrdtOp> {
        let stand = self.founding_stand(s.seen);
        let now_view = std::mem::replace(&mut self.authority, s.before.clone());
        let before_t = |o: &CrdtOp| s.seen.get(&(o.author.clone(), o.hlc.physical_ms, o.hlc.counter)).is_some_and(|ms| *ms < s.t_ms);
        let dropped = |o: &CrdtOp| o.dev.as_deref().is_some_and(|d| s.dropped.contains(&d.device));
        let mut ops: Vec<CrdtOp> = self
            .op_log
            .iter()
            .chain(self.stored.iter().map(|(o, _)| o))
            .chain(self.held.iter().map(|(o, _)| o))
            .filter(|o| !is_checkpoint(o) && !matches!(o.payload, CrdtPayload::SettleSign { .. }))
            .filter(|o| self.device_counts_here(o) && (!dropped(o) || before_t(o) || stand == Some(o.content_hash())))
            .cloned()
            .collect();
        self.authority = now_view;
        ops.extend(r.cloned());
        ops
    }

    /// The settling checkpoint's state and its stamp (section 8.3 step 4, and rule 4 of
    /// section 8.2 for the carried sets), standing where `on` says (sections 8.3, 8.4).
    pub(crate) fn settling_json_on(&mut self, me: &str, by: &str, s: &Settling<'_>, now_ms: u64, on: &SettleOn) -> Option<(String, SettleStamp)> {
        let (current, r) = match on {
            SettleOn::Restore => (self.base.as_ref().map(|b| Box::new(super::fold::Base::clone(b)))?, self.restore_for(s.t_ms)),
            SettleOn::Witnessed(x) => (Box::new(self.base_of_content(x)?), Some(CrdtOp::clone(x))),
            SettleOn::Rollback => (self.base.as_ref().map(|b| Box::new(super::fold::Base::clone(b)))?, self.rollback_point(me)),
        };
        if r.is_none() && !super::anchor::is_genesis_id(&self.server_id) {
            return None;
        }
        let mut scratch = ServerState::skeleton(self.server_id.clone());
        scratch.owner_pin = self.owner_pin.clone();
        scratch.settle_base = r.as_ref().map(|o| self.content_of(o));
        scratch.ingest_remote(&self.settling_input(r.as_ref(), s));
        if scratch.base.as_ref().map(|b| b.hash) != scratch.settle_base {
            return None;
        }
        let mut state: ServerState = serde_json::from_str(&scratch.checkpoint_json(me, &[], now_ms)?).ok()?;
        let mut devices = s.dropped.to_vec();
        devices.sort();
        devices.dedup();
        let stamp = SettleStamp {
            server: self.server_id.clone(),
            parent: current.hash_hex(),
            generation: current.generation.checked_add(1)?,
            devices,
            t_ms: i64::try_from(s.t_ms).ok()?,
            sigs: Vec::new(),
        };
        state.cp_generation = stamp.generation;
        state.cp_parent = Some(current.hash_hex());
        state.cp_lineage = super::fold::lineage_after(&current);
        state.cp_cut = super::fold::cut_after(&current);
        state.cp_settled = Some(stamp.id());
        state.cp_settles = Some(stamp.clone());
        state.cp_roster = Some(s.roster.clone());
        let seen_before = |author: &str, ms: u64, c: u32| s.seen.get(&(author.to_string(), ms, c)).is_some_and(|at| *at < s.t_ms);
        state.cp_endorsed.retain(|e| !stamp.devices.contains(&e.by));
        for e in &mut state.cp_endorsed {
            if stamp.devices.contains(&e.device) {
                e.refs.retain(|r| seen_before(&e.author, r.ms, r.c));
            }
        }
        state.cp_endorsed.retain(|e| !e.refs.is_empty());
        // Rule 4 for post windows: none signed by a dropped device, and T for each one.
        state.cp_posts_until.retain(|p| !stamp.devices.contains(&p.by) && !(p.author == me && stamp.devices.contains(&p.device)));
        let settle_id = stamp.id();
        for d in &stamp.devices {
            state.cp_posts_until.push(super::operations::PostsUntil { author: me.to_string(), device: d.clone(), until_ms: stamp.t_ms, dr: settle_id.clone(), by: by.to_string() });
        }
        state.cp_posts_until.sort_by(|a, b| (&a.author, &a.device).cmp(&(&b.author, &b.device)));
        if let Some(device) = self.device_signer().filter(|d| d.peer_id() == by) {
            let counts = |d: &str| d == by || self.authority.counts(me, d);
            super::refold_write::resign_for_settling(&mut state.cp_refolded, &self.server_id, &stamp.devices, device, &counts);
        } else {
            state.cp_refolded.clear();
        }
        let json = serde_json::to_string(&state).ok()?;
        super::fold::checkpoint_fits(&json).then_some((json, stamp))
    }

    /// Write the settling as our new base and sign its stamp with `device` (the device
    /// our ops are proven by). A server with no checkpoint yet first gets an ordinary one
    /// from the view after the removal, so the settling has a parent its mark can pin.
    /// Returns the ops to publish in order and what each ingest changed (to persist).
    pub(crate) fn author_settling(&mut self, me: &str, s: &Settling<'_>, device: &NativeKeypair) -> Option<(Vec<CrdtOp>, Vec<super::fold::Ingested>)> {
        self.author_settling_on(me, s, device, &SettleOn::Restore)
    }

    /// [`Self::author_settling`] standing where `on` says. A witnessed checkpoint we do
    /// not hold is ingested first, so the settling's parent is held here too.
    pub(crate) fn author_settling_on(
        &mut self,
        me: &str,
        s: &Settling<'_>,
        device: &NativeKeypair,
        on: &SettleOn,
    ) -> Option<(Vec<CrdtOp>, Vec<super::fold::Ingested>)> {
        let mut ops = Vec::new();
        let mut changed = Vec::new();
        self.refresh_view();
        let now = super::hlc::wall_clock_ms();
        if let SettleOn::Witnessed(x) = on {
            if x.author != me || x.verify_author().is_err() {
                return None;
            }
            if self.base_by_hash(&hex::encode(x.content_hash())).is_none() {
                changed.push(self.ingest_remote(std::slice::from_ref(&**x)));
            }
        } else if self.base.is_none() {
            changed.push(self.rebuild_now());
            let state = self.checkpoint_json(me, &[], now)?;
            let covers = self.checkpoint_covers();
            let (first, ingested) = self.author_checkpoint(CrdtPayload::ServerCheckpoint { state, covers })?;
            ops.push(first);
            changed.push(ingested);
        }
        let (state, stamp) = self.settling_json_on(me, &device.peer_id(), s, now, on)?;
        let covers = self.checkpoint_covers();
        // The mark first: a held mark keeps every settling but its line's ineligible.
        let (sign, ingested) = self.author_settle_sign(&stamp, device)?;
        changed.push(ingested);
        let (settling, ingested) = self.author_checkpoint(CrdtPayload::ServerCheckpoint { state, covers })?;
        changed.push(ingested);
        ops.extend([sign, settling]);
        Some((ops, changed))
    }

    /// Section 8.3, two settlings at once: what the settling a child of the winner
    /// drops (both device sets) and its T (the earlier one), when a rival names a device
    /// our base's settling does not.
    pub(crate) fn merged_settling(&self) -> Option<(Vec<String>, u64)> {
        let rivals = self.rival_settles.as_slice();
        if rivals.is_empty() {
            return None;
        }
        let own = self.base.as_ref().and_then(|b| b.state.cp_settles.clone());
        let stamps = || own.iter().chain(rivals.iter());
        let owner = self.anchor_owner()?;
        let mut devices: Vec<String> = stamps().flat_map(|st| st.devices.iter().cloned()).filter(|d| !self.authority.counts(&owner, d)).collect();
        devices.sort();
        devices.dedup();
        let t = stamps().map(|st| st.t_ms).min().and_then(|t| u64::try_from(t).ok())?;
        Some((devices, t))
    }

    /// The view from before `dropped` were removed: `before` with them counted again for
    /// `me`, to judge a merged settling's inputs as each first settling did.
    pub(crate) fn view_counting(&self, me: &str, dropped: &[String]) -> Arc<AuthorityView> {
        let mut view = (*self.authority).clone();
        if let Some(mut entry) = view.entry(me).cloned() {
            if let Some(auth) = entry.auth.as_mut() {
                for d in dropped {
                    auth.removed.remove(d);
                    auth.counted.insert(d.clone());
                }
            }
            view.insert(me.to_string(), entry);
        }
        Arc::new(view)
    }

    /// Sign `stamp` with `device` as our own `SettleSign`, stored as a mark row.
    pub(crate) fn author_settle_sign(&mut self, stamp: &SettleStamp, device: &NativeKeypair) -> Option<(CrdtOp, super::fold::Ingested)> {
        let sign = self.create_op(CrdtPayload::SettleSign { stamp: stamp.signed_by(device) });
        let ingested = self.ingest_remote(std::slice::from_ref(&sign));
        let kept = self.stored.iter().any(|(o, k)| *k == super::fold::RowKind::SettleSign && o.hlc == sign.hlc);
        kept.then_some((sign, ingested))
    }

    /// Section 8.5 (R31-5): the stamps of held marks `removed` signed that `ours` has not:
    /// every one on a retire, on a lost-or-stolen removal only those stored here before
    /// `before.0`. The settling ids stay, so descendants' `cp_settled` still name them.
    pub(crate) fn co_sign_stamps(&self, removed: &str, ours: &str, before: Option<(u64, &SeenAt)>) -> Vec<SettleStamp> {
        let marks = || self.stored.iter().filter(|(_, k)| *k == super::fold::RowKind::SettleSign).map(|(o, _)| o);
        let signed_by = |dev: &str| -> std::collections::HashSet<String> {
            marks()
                .filter_map(|o| match &o.payload {
                    CrdtPayload::SettleSign { stamp } if stamp.sigs.iter().any(|s| s.device == dev) => Some(stamp.id()),
                    _ => None,
                })
                .collect()
        };
        let ours_already = signed_by(ours);
        let mut out: Vec<SettleStamp> = Vec::new();
        for o in marks() {
            let CrdtPayload::SettleSign { stamp } = &o.payload else { continue };
            let seen_ok = before.is_none_or(|(t, seen)| seen.get(&(o.author.clone(), o.hlc.physical_ms, o.hlc.counter)).is_some_and(|ms| *ms < t));
            let id = stamp.id();
            if stamp.sigs.iter().any(|s| s.device == removed) && seen_ok && !ours_already.contains(&id) && !out.iter().any(|s| s.id() == id) {
                out.push(SettleStamp { sigs: Vec::new(), ..stamp.clone() });
            }
        }
        out
    }

    /// A member's retires after losing `device` (section 8.3): the ops of ours it proved
    /// that we folded and first stored before T, naming our restore point R; posts later
    /// (section 13).
    pub(crate) fn lost_retire_payloads(&self, me: &str, device: &str, t_ms: u64, seen: &SeenAt) -> Vec<CrdtPayload> {
        let restore = self.restore_for(t_ms).map(|r| hex::encode(self.content_of(&r)));
        let mut refs: Vec<super::operations::OpRef> = self
            .op_log
            .iter()
            .filter(|o| o.author == me && o.dev.as_deref().is_some_and(|d| d.device == device))
            .filter(|o| !matches!(o.payload, CrdtPayload::DeviceRetired { .. } | CrdtPayload::ServerCheckpoint { .. }))
            .filter(|o| seen.get(&(o.author.clone(), o.hlc.physical_ms, o.hlc.counter)).is_some_and(|ms| *ms < t_ms))
            .map(|o| super::operations::OpRef { ms: o.hlc.physical_ms, c: o.hlc.counter, h: hex::encode(self.content_of(o)) })
            .collect();
        refs.sort();
        refs.dedup();
        let chunks: Vec<Vec<super::operations::OpRef>> =
            if refs.is_empty() { vec![Vec::new()] } else { refs.chunks(super::operations::MAX_RETIRED_REFS).map(<[_]>::to_vec).collect() };
        chunks
            .into_iter()
            .map(|ops| CrdtPayload::DeviceRetired { device: device.to_string(), ops, posts_until_ms: i64::try_from(t_ms).ok(), restore: restore.clone() })
            .collect()
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::crdt::authority::{self, KeyRule};
    use crate::crdt::fold::RowKind;
    use crate::crdt::hlc::Hlc;
    use crate::crdt::server_state::Founder;
    use crate::crdt::testkeys::keys;
    use crate::crdt::verdict::ViewSource;
    use crate::identity::roster::{sign_consent, sign_removal, sign_vouch};
    use CrdtPayload as P;

    const OWNER: u8 = 1;
    const PHONE: u8 = 2;
    const RECOVERY: u8 = 3;
    const LAPTOP: u8 = 4;
    const OTHER: u8 = 8;

    fn rosters() -> (Roster, Roster) {
        let (master, m_id, _) = keys(OWNER);
        let mut before = Roster::genesis(&master, &keys(RECOVERY).0, &keys(PHONE).0, 1_000);
        before.add_vouch(sign_vouch(&keys(PHONE).0, &m_id, &before.base(), &keys(LAPTOP).1));
        before.add_consent(sign_consent(&keys(LAPTOP).0, &m_id));
        let mut after = before.clone();
        after.add_removal(sign_removal(&keys(PHONE).0, &m_id, &before.base(), &keys(LAPTOP).1, &[]));
        (before, after)
    }

    fn view_of(rosters: &[&Roster]) -> Arc<AuthorityView> {
        let mut v = AuthorityView::judging();
        v.insert(keys(OWNER).1, authority::judge(&keys(OWNER).1, &KeyRule::FirstHeld, rosters));
        Arc::new(v)
    }

    /// A replica whose view of the owner is `book` plus every held `cp_roster`.
    fn judged_by(s: &mut ServerState, book: Roster) {
        s.set_view_source(ViewSource(Arc::new(move |state: &ServerState, m: &str| {
            let held = authority::held_cp_rosters(state);
            let mut all: Vec<&Roster> = vec![&book];
            all.extend(held.iter().filter(|r| r.master == m));
            (m == keys(OWNER).1).then(|| authority::judge(m, &KeyRule::FirstHeld, &all))
        })));
        s.refresh_view();
    }

    fn device_replica(sid: &str, device: u8) -> ServerState {
        let (kp, id, pk) = keys(OWNER);
        let (dkp, did, _) = keys(device);
        let mut s = ServerState::skeleton(sid.into());
        s.set_hlc(Hlc::for_device(id, &did));
        s.set_signer(kp, pk);
        s.set_device_signer(dkp);
        s
    }

    fn checkpoint(s: &mut ServerState) -> CrdtOp {
        let covers = s.checkpoint_covers();
        let json = s.checkpoint_json(&keys(OWNER).1, &[], crate::crdt::hlc::wall_clock_ms()).unwrap();
        s.author_checkpoint(P::ServerCheckpoint { state: json, covers }).expect("the checkpoint becomes the base").0
    }

    fn rename(s: &mut ServerState, to: &str) -> CrdtOp {
        s.author_checked(P::ServerRenamed { new_name: to.into() }).expect("a counted device renames")
    }

    struct World {
        owner: ServerState,
        laptop: ServerState,
        log: Vec<CrdtOp>,
        cp1: CrdtOp,
        before_t: CrdtOp,
        after_t: CrdtOp,
        thief_cp: CrdtOp,
        seen: SeenAt,
    }

    /// The phone founds and checkpoints (cp1, first folded at 1,000); the laptop renames
    /// before T (seen 2,000) and after it (seen 4,000) and checkpoints on top (first
    /// folded at 5,000); T = 3,000.
    fn world() -> World {
        let (before, _) = rosters();
        let r_pub = before.r_pub.clone();
        let (master, m_id, pk) = keys(OWNER);
        let (phone, phone_id, _) = keys(PHONE);
        let (mut owner, _) = ServerState::found_on("s".into(), m_id, Founder { device_peer_id: &phone_id, device: Some(&phone), r_pub: Some(&r_pub) }, master, pk);
        judged_by(&mut owner, before.clone());
        let mut log: Vec<CrdtOp> = owner.op_log.clone();
        let cp1 = checkpoint(&mut owner);
        log.push(cp1.clone());
        let mut laptop = device_replica(&owner.server_id, LAPTOP);
        judged_by(&mut laptop, before.clone());
        laptop.ingest_remote(&log);
        let before_t = rename(&mut laptop, "before T");
        let after_t = rename(&mut laptop, "after T");
        let thief_cp = checkpoint(&mut laptop);
        let laptop_ops = [before_t.clone(), after_t.clone(), thief_cp.clone()];
        owner.ingest_remote(&laptop_ops);
        log.extend(laptop_ops);
        assert_eq!(owner.base.as_ref().map(|b| b.hlc.clone()), Some(thief_cp.hlc.clone()), "precondition: the laptop's checkpoint is the base");
        let folds = Arc::make_mut(&mut owner.first_folds);
        folds.insert(hex::encode(cp1.content_hash()), 1_000);
        folds.insert(hex::encode(thief_cp.content_hash()), 5_000);
        let key = |o: &CrdtOp| (o.author.clone(), o.hlc.physical_ms, o.hlc.counter);
        let seen: SeenAt = [(key(&before_t), 2_000), (key(&after_t), 4_000)].into_iter().collect();
        World { owner, laptop, log, cp1, before_t, after_t, thief_cp, seen }
    }

    /// The owner's replica of `world()` (cp1 first folded at 1,000, the laptop's
    /// checkpoint at 5,000), its view counting the phone and the laptop, cp1, the laptop's
    /// checkpoint, the phone's keys and the owner's master (the witness tests).
    pub(crate) fn witness_world() -> (ServerState, Arc<AuthorityView>, CrdtOp, CrdtOp, crate::identity::native_identity::NativeKeypair, String) {
        let w = world();
        let (before, _) = rosters();
        (w.owner, view_of(&[&before]), w.cp1, w.thief_cp, keys(PHONE).0, keys(OWNER).1)
    }

    fn settle(w: &mut World) -> (CrdtOp, CrdtOp) {
        let (before, after) = rosters();
        let s = Settling { before: view_of(&[&before]), dropped: &[keys(LAPTOP).1], t_ms: 3_000, seen: &w.seen, roster: after.clone() };
        judged_by(&mut w.owner, after);
        let (mut ops, _) = w.owner.author_settling(&keys(OWNER).1, &s, &keys(PHONE).0).expect("the settling is written");
        let settling = ops.pop().unwrap();
        (settling, ops.pop().unwrap())
    }

    /// Section 8.3, two settlings at once: two siblings settle two lost devices on one
    /// base; the owner device holding both writes one child of the winner dropping both,
    /// T the earlier one, and the rivalry ends there.
    /// The phone's replica of the rivalry below, first folded at 1,000, with a sibling's
    /// settling (T 2,000) rival to its own (T 3,000): `merged_settling` is due.
    pub(crate) fn rival_world() -> ServerState {
        rival_parts().0
    }

    #[test]
    fn two_settlings_at_once_end_in_one_child_of_the_winner_dropping_both() {
        let (mut phone, _, after, seen) = rival_parts();
        let (m_id, phone_kp) = (keys(OWNER).1, keys(PHONE).0);
        let (devices, t_ms) = phone.merged_settling().expect("the rival drops a device the line does not");
        let mut both = vec![keys(LAPTOP).1, keys(DESK).1];
        both.sort();
        assert_eq!((devices.clone(), t_ms), (both.clone(), 2_000));

        let generation = phone.base.as_ref().map(|b| b.generation).unwrap();
        let st = Settling { before: phone.view_counting(&m_id, &devices), dropped: &devices, t_ms, seen: &seen, roster: after.clone() };
        phone.author_settling(&m_id, &st, &phone_kp).expect("the merged settling");
        let base = phone.base.as_ref().expect("a base");
        assert_eq!(base.generation, generation + 1, "a child of the winner");
        assert_eq!(base.state.cp_settles.as_ref().map(|st| st.devices.clone()), Some(both), "dropping both");
        assert!(phone.merged_settling().is_none(), "and the rivalry ends");
        assert_eq!(phone.name.read().as_str(), "laptop before T", "what a dropped device did before the earlier T stays");
    }

    const TABLET: u8 = 5;
    const DESK: u8 = 6;

    /// Section 8.3, two settlings at once: two siblings settle two lost devices on one
    /// base; the phone holds both. Returns the phone, the rosters and the first sights.
    fn rival_parts() -> (ServerState, Roster, Roster, SeenAt) {
        let (master, m_id, pk) = keys(OWNER);
        let mut before = Roster::genesis(&master, &keys(RECOVERY).0, &keys(PHONE).0, 1_000);
        for d in [LAPTOP, TABLET, DESK] {
            before.add_vouch(sign_vouch(&keys(PHONE).0, &m_id, &before.base(), &keys(d).1));
            before.add_consent(sign_consent(&keys(d).0, &m_id));
        }
        let mut after = before.clone();
        after.add_removal(sign_removal(&keys(PHONE).0, &m_id, &before.base(), &keys(LAPTOP).1, &[]));
        after.add_removal(sign_removal(&keys(TABLET).0, &m_id, &before.base(), &keys(DESK).1, &[]));
        let (phone_kp, phone_id, _) = keys(PHONE);
        let r_pub = before.r_pub.clone();
        let (mut phone, _) = ServerState::found_on("s".into(), m_id.clone(), Founder { device_peer_id: &phone_id, device: Some(&phone_kp), r_pub: Some(&r_pub) }, master, pk);
        judged_by(&mut phone, before.clone());
        let mut log = phone.op_log.clone();
        let cp = checkpoint(&mut phone);
        log.push(cp.clone());
        let mut tablet = device_replica(&phone.server_id, TABLET);
        judged_by(&mut tablet, before.clone());
        tablet.ingest_remote(&log);
        for s in [&mut phone, &mut tablet] {
            Arc::make_mut(&mut s.first_folds).insert(hex::encode(cp.content_hash()), 1_000);
        }
        let mut laptop = device_replica(&phone.server_id, LAPTOP);
        judged_by(&mut laptop, before.clone());
        laptop.ingest_remote(&log);
        let early = rename(&mut laptop, "laptop before T");
        for s in [&mut phone, &mut tablet] {
            s.ingest_remote(std::slice::from_ref(&early));
        }
        let seen: SeenAt = [((early.author.clone(), early.hlc.physical_ms, early.hlc.counter), 1_500)].into_iter().collect();
        let lost = |s: &mut ServerState, gone: u8, t_ms: u64, signer: u8| {
            let dropped = [keys(gone).1];
            let st = Settling { before: view_of(&[&before]), dropped: &dropped, t_ms, seen: &seen, roster: after.clone() };
            judged_by(s, after.clone());
            s.author_settling(&m_id, &st, &keys(signer).0).expect("a settling").0
        };
        let _mine = lost(&mut phone, LAPTOP, 3_000, PHONE);
        assert!(phone.merged_settling().is_none(), "one settling has no rival");
        let theirs = lost(&mut tablet, DESK, 2_000, TABLET);
        phone.ingest_remote(&theirs);
        (phone, before, after, seen)
    }

    fn stamp_of(op: &CrdtOp) -> SettleStamp {
        match &op.payload {
            P::SettleSign { stamp } => stamp.clone(),
            _ => panic!("not a settle sign"),
        }
    }

    fn sign_row(s: &ServerState, id: &str, device: &str) -> bool {
        s.stored.iter().any(|(o, k)| *k == RowKind::SettleSign && matches!(&o.payload, P::SettleSign { stamp } if stamp.id() == id && stamp.sigs[0].device == device))
    }

    /// A mark counts only from the owner (section 7): a member's well-formed
    /// `SettleSign` of the owner's settling is no row anywhere.
    #[test]
    fn a_members_settle_sign_is_no_mark() {
        let mut w = world();
        let (_, sign) = settle(&mut w);
        let stamp = SettleStamp { sigs: Vec::new(), ..stamp_of(&sign) };
        let (mkp, m_id, mpk) = keys(OTHER);
        let mut member = ServerState::skeleton(w.owner.server_id.clone());
        member.set_hlc(Hlc::for_device(m_id, &keys(9).1));
        member.set_signer(mkp, mpk);
        member.set_device_signer(keys(9).0);
        let forged = member.create_op(P::SettleSign { stamp: stamp.signed_by(&keys(9).0) });
        w.owner.ingest_remote(std::slice::from_ref(&forged));
        assert!(!sign_row(&w.owner, &stamp.id(), &keys(9).1), "a member's signature marks nothing");
        // The plan's own owner check, alone: a stored row the door never judged.
        let rows: Vec<(CrdtOp, Option<u64>)> = w
            .owner
            .op_log
            .iter()
            .map(|o| (o.clone(), None))
            .chain(w.owner.stored.iter().map(|(o, k)| (o.clone(), k.parked_until())))
            .chain(std::iter::once((forged, None)))
            .collect();
        let mut back = device_replica(&w.owner.server_id, PHONE);
        back.first_folds = w.owner.first_folds.clone();
        judged_by(&mut back, rosters().1);
        back.restore_op_log(rows);
        assert!(!sign_row(&back, &stamp.id(), &keys(9).1), "nor from a restored row");
    }

    /// A stamp's own signature is checked (section 7): an owner op carrying a stamp whose
    /// signature was made over other fields is no mark.
    #[test]
    fn a_settle_sign_whose_stamp_signature_fails_is_no_mark() {
        let mut w = world();
        let (_, sign) = settle(&mut w);
        let mut altered = stamp_of(&sign);
        altered.t_ms += 1;
        let mut phone = device_replica(&w.owner.server_id, PHONE);
        let forged = phone.create_op(P::SettleSign { stamp: altered.clone() });
        w.owner.ingest_remote(std::slice::from_ref(&forged));
        assert!(!sign_row(&w.owner, &altered.id(), &keys(PHONE).1), "a signature over other fields marks nothing");
    }

    /// A mark is a line only one generation past the parent it pins (section 7): a stamp
    /// that skips a generation never confines eligibility.
    #[test]
    fn a_mark_that_skips_a_generation_confines_nothing() {
        let mut w = world();
        let (settling, sign) = settle(&mut w);
        let base = w.owner.base.as_ref().map(|b| (b.hash_hex(), b.generation)).unwrap();
        assert_eq!(base.0, hex::encode(settling.content_hash()));
        let skipped = SettleStamp { parent: base.0, generation: base.1 + 2, sigs: Vec::new(), ..stamp_of(&sign) };
        let mut phone = device_replica(&w.owner.server_id, PHONE);
        let odd = phone.create_op(P::SettleSign { stamp: skipped.signed_by(&keys(PHONE).0) });
        w.owner.ingest_remote(std::slice::from_ref(&odd));
        let next = checkpoint(&mut w.owner);
        assert_eq!(w.owner.base.as_ref().map(|b| b.hlc.clone()), Some(next.hlc), "an ordinary child of the settling stays the base");
    }

    /// A mark keeps its counted signers first (section 14): eight signatures by devices
    /// the owner's view does not count never push out the one it does.
    #[test]
    fn junk_signatures_never_push_a_counted_signer_out_of_a_mark() {
        let mut w = world();
        let (_, sign) = settle(&mut w);
        let stamp = SettleStamp { sigs: Vec::new(), ..stamp_of(&sign) };
        let phone_id = keys(PHONE).1;
        let junk: Vec<u8> = (20..=120u8).filter(|t| keys(*t).1 < phone_id).take(crate::crdt::fold::MAX_SETTLE_SIGS).collect();
        assert_eq!(junk.len(), crate::crdt::fold::MAX_SETTLE_SIGS, "precondition: enough devices sort before the phone");
        let ops: Vec<CrdtOp> = junk
            .iter()
            .map(|t| device_replica(&w.owner.server_id, *t).create_op(P::SettleSign { stamp: stamp.signed_by(&keys(*t).0) }))
            .collect();
        w.owner.ingest_remote(&ops);
        assert!(sign_row(&w.owner, &stamp.id(), &phone_id), "the counted signature stays in the mark");
    }

    /// Rule 4 of section 8.2 for post windows: a settling sets T for each dropped device
    /// and carries no window its dropped device signed; a member's lost retire names T.
    #[test]
    fn a_settling_sets_t_as_the_dropped_devices_post_window() {
        let mut w = world();
        let theirs = w.laptop.create_op(P::DeviceRetired { device: keys(PHONE).1, ops: Vec::new(), posts_until_ms: Some(2_500), restore: None });
        w.owner.ingest_remote(std::slice::from_ref(&theirs));
        w.seen.insert((theirs.author.clone(), theirs.hlc.physical_ms, theirs.hlc.counter), 2_500);
        let (settling, _) = settle(&mut w);
        let P::ServerCheckpoint { state, .. } = &settling.payload else { panic!("a checkpoint") };
        let st: ServerState = serde_json::from_str(state).unwrap();
        let laptop = keys(LAPTOP).1;
        let windows: Vec<(String, i64, String)> = st.cp_posts_until.iter().map(|p| (p.device.clone(), p.until_ms, p.by.clone())).collect();
        assert_eq!(windows, vec![(laptop.clone(), 3_000, keys(PHONE).1)], "T for the laptop, signed by the settling's device");
        let payloads = w.owner.lost_retire_payloads(&keys(OWNER).1, &laptop, 3_000, &w.seen);
        assert!(payloads.iter().all(|p| matches!(p, P::DeviceRetired { posts_until_ms: Some(3_000), .. })), "a member's lost retire names T");
    }

    /// A rival never drops a device our view still counts: a counted sibling's settling
    /// naming the phone, with no removal of it, merges nothing.
    #[test]
    fn a_rival_naming_a_device_we_count_merges_nothing() {
        const TABLET: u8 = 5;
        const DESK: u8 = 6;
        let (master, m_id, pk) = keys(OWNER);
        let mut before = Roster::genesis(&master, &keys(RECOVERY).0, &keys(PHONE).0, 1_000);
        for d in [LAPTOP, TABLET, DESK] {
            before.add_vouch(sign_vouch(&keys(PHONE).0, &m_id, &before.base(), &keys(d).1));
            before.add_consent(sign_consent(&keys(d).0, &m_id));
        }
        let mut after = before.clone();
        after.add_removal(sign_removal(&keys(PHONE).0, &m_id, &before.base(), &keys(LAPTOP).1, &[]));
        after.add_removal(sign_removal(&keys(PHONE).0, &m_id, &before.base(), &keys(DESK).1, &[]));
        let (phone_kp, phone_id, _) = keys(PHONE);
        let r_pub = before.r_pub.clone();
        let (mut phone, _) = ServerState::found_on("s".into(), m_id.clone(), Founder { device_peer_id: &phone_id, device: Some(&phone_kp), r_pub: Some(&r_pub) }, master, pk);
        judged_by(&mut phone, before.clone());
        let mut log = phone.op_log.clone();
        let cp = checkpoint(&mut phone);
        log.push(cp.clone());
        let mut tablet = device_replica(&phone.server_id, TABLET);
        judged_by(&mut tablet, before.clone());
        tablet.ingest_remote(&log);
        for s in [&mut phone, &mut tablet] {
            Arc::make_mut(&mut s.first_folds).insert(hex::encode(cp.content_hash()), 1_000);
        }
        let seen = SeenAt::default();
        let lost = |s: &mut ServerState, gone: &[String], signer: u8, roster: &Roster| {
            let st = Settling { before: view_of(&[&before]), dropped: gone, t_ms: 2_000, seen: &seen, roster: roster.clone() };
            judged_by(s, roster.clone());
            s.author_settling(&m_id, &st, &keys(signer).0).expect("a settling").0
        };
        lost(&mut phone, &[keys(LAPTOP).1], PHONE, &after);
        lost(&mut phone, &[keys(DESK).1], PHONE, &after);
        let theirs = lost(&mut tablet, &[phone_id.clone(), keys(LAPTOP).1], TABLET, &before);
        phone.ingest_remote(&theirs);
        assert!(phone.authority.counts(&m_id, &phone_id), "precondition: the phone still counts");
        assert!(phone.base.as_ref().is_some_and(|b| b.state.cp_settles.as_ref().is_some_and(|st| st.devices == vec![keys(DESK).1])), "precondition: our line");
        assert!(phone.rival_settles.iter().all(|st| !st.devices.contains(&phone_id)), "the plan keeps no counted device in a rival");
        assert!(phone.merged_settling().is_none_or(|(d, _)| !d.contains(&phone_id)), "a merge never drops a device we count");
    }

    /// Section 7 (N6): a step back loses nothing our own identity did; our op two later
    /// checkpoints decided folds again in a settling on an older restore point.
    #[test]
    fn a_settling_on_an_older_restore_point_folds_our_own_kept_op_again() {
        let mut w = world();
        let me = keys(OWNER).1;
        let mine = w.owner.author_checked(P::NicknameChanged { peer_id: me.clone(), nickname: "mine".into() }).expect("our own op");
        checkpoint(&mut w.owner);
        checkpoint(&mut w.owner);
        assert!(
            w.owner.stored.iter().any(|(o, k)| *k == RowKind::Own && o.hlc == mine.hlc),
            "precondition: two checkpoints decided it and we keep it",
        );
        let _ = settle(&mut w);
        assert_eq!(w.owner.get_nickname(&me), "mine", "the settling folds it again");
    }

    #[test]
    fn not_sure_reads_t_as_the_oldest_restore_points_first_fold() {
        let w = world();
        assert_eq!(w.owner.lost_t(3_000), 3_000, "an answered T stands");
        assert_eq!(w.owner.lost_t(0), 1_000, "\"not sure\" = cp1's first fold, the oldest held");
        assert_eq!(ServerState::skeleton("s".into()).lost_t(0), 0, "no restore point: 0");
    }

    /// HOL-SEC-221: the laptop founds, checkpoints (cp1) and renames twice; the phone first
    /// stores all of it at 3,000 (cp1's first fold, so "not sure" reads T = 3,000), the
    /// second rename at 4,000. With `forged`, the laptop also mints a second founding op
    /// of the same id, clocked before the first and named "stolen", first stored here at
    /// the time it names (none: no record of it), as a build before HOL-SEC-222 kept it.
    fn founded_by_the_laptop(forged: Option<Option<u64>>) -> (ServerState, SeenAt) {
        let (before, _) = rosters();
        let r_pub = before.r_pub.clone();
        let (master, m_id, pk) = keys(OWNER);
        let (laptop_kp, laptop_id, _) = keys(LAPTOP);
        let (mut laptop, founding) =
            ServerState::found_on("s".into(), m_id, Founder { device_peer_id: &laptop_id, device: Some(&laptop_kp), r_pub: Some(&r_pub) }, master.clone(), pk.clone());
        judged_by(&mut laptop, before.clone());
        let cp1 = checkpoint(&mut laptop);
        let at_t = rename(&mut laptop, "at T");
        let after_t = rename(&mut laptop, "after T");
        let mut phone = device_replica(&laptop.server_id, PHONE);
        judged_by(&mut phone, before);
        phone.ingest_remote(&[founding.clone(), cp1.clone(), at_t.clone(), after_t.clone()]);
        Arc::make_mut(&mut phone.first_folds).insert(hex::encode(cp1.content_hash()), 3_000);
        let key = |o: &CrdtOp| (o.author.clone(), o.hlc.physical_ms, o.hlc.counter);
        let mut seen: SeenAt = [(key(&founding), 3_000), (key(&at_t), 3_000), (key(&after_t), 4_000)].into_iter().collect();
        if let Some(stored_at) = forged {
            let mut second = founding.clone();
            let P::ServerCreated { name, .. } = &mut second.payload else { unreachable!() };
            *name = "stolen".into();
            second.hlc.physical_ms -= 10;
            second.sign(&master, &pk);
            second.sign_device(&laptop_kp);
            phone.ingest_remote(std::slice::from_ref(&second));
            let holds = |s: &ServerState| s.op_log.iter().chain(s.stored.iter().map(|(o, _)| o)).any(|o| o.hlc == second.hlc);
            assert!(!holds(&phone), "HOL-SEC-222: the door refuses a second founding op");
            // As a replica that stored it before HOL-SEC-222 still holds it.
            phone.stored.push((second.clone(), RowKind::Dormant));
            if let Some(at) = stored_at {
                seen.insert(key(&second), at);
            }
            // One naming another nonce founds no server of this id, whenever stored.
            let mut other = founding.clone();
            let P::ServerCreated { nonce, .. } = &mut other.payload else { unreachable!() };
            nonce.push('0');
            other.hlc.physical_ms -= 20;
            other.sign(&master, &pk);
            other.sign_device(&laptop_kp);
            phone.ingest_remote(std::slice::from_ref(&other));
            seen.insert(key(&other), 1_000);
            // So `founding_stand`'s own id check is a second layer, never reached from here.
            assert!(!phone.op_log.iter().chain(phone.stored.iter().map(|(o, _)| o)).any(|o| o.hlc == other.hlc), "the door keeps a founding op of another id");
        }
        (phone, seen)
    }

    fn settle_the_laptops_server(phone: &mut ServerState, seen: &SeenAt) -> Option<CrdtOp> {
        let (before, after) = rosters();
        let t_ms = phone.lost_t(0);
        assert_eq!(t_ms, 3_000, "precondition: \"not sure\" reads T as the first fold of the phone's oldest restore point");
        let s = Settling { before: view_of(&[&before]), dropped: &[keys(LAPTOP).1], t_ms, seen, roster: after.clone() };
        judged_by(phone, after);
        phone.author_settling(&keys(OWNER).1, &s, &keys(PHONE).0).map(|(mut ops, _)| ops.pop().unwrap())
    }

    /// HOL-SEC-221: a "not sure" settling of a server the lost device founded, on a device
    /// that first stored the founding op no earlier than its oldest restore point, stands
    /// on that founding op; the lost founder's ops stored here at T or after still drop.
    #[test]
    fn a_not_sure_settling_stands_on_the_founding_op_the_lost_device_wrote() {
        let (mut phone, seen) = founded_by_the_laptop(None);
        assert!(settle_the_laptops_server(&mut phone, &seen).is_some(), "the settling is written");
        let base = phone.base.as_ref().expect("a base");
        assert_eq!(base.state.cp_settles.as_ref().map(|st| st.devices.clone()), Some(vec![keys(LAPTOP).1]), "dropping the laptop");
        assert_eq!(phone.name.read().as_str(), "s", "the founder's renames stored here at T and after drop");
    }

    /// HOL-SEC-221: of two founding ops of one id, the settling keeps only the one first
    /// stored here; the other, by the lost device and stored after T (or with no record of
    /// when), drops.
    #[test]
    fn a_founding_op_the_lost_device_minted_later_never_founds_the_settling() {
        for stored_at in [Some(4_500), None] {
            let (mut phone, seen) = founded_by_the_laptop(Some(stored_at));
            assert!(settle_the_laptops_server(&mut phone, &seen).is_some(), "the settling is written ({stored_at:?})");
            assert_eq!(phone.name.read().as_str(), "s", "the later founding op stayed out ({stored_at:?})");
        }
    }

    /// HOL-SEC-222: the laptop, removed, still holds the master key and mints a second
    /// founding op of the server the phone founded (clocked before the first, so a fold
    /// from genesis would take it first, or at the first's own clock). No replica stores
    /// it: not the founder's, not one folding the log again from genesis, not a fresh one
    /// handed both in one batch; each stays founded on the first.
    #[test]
    fn a_second_founding_op_from_a_removed_device_founds_nothing() {
        let (before, after) = rosters();
        let (master, m_id, pk) = keys(OWNER);
        let (phone, phone_id, _) = keys(PHONE);
        let (mut owner, founding) =
            ServerState::found_on("s".into(), m_id, Founder { device_peer_id: &phone_id, device: Some(&phone), r_pub: Some(&before.r_pub) }, master.clone(), pk.clone());
        judged_by(&mut owner, after.clone());
        let second = |ms_back: u64| {
            let mut op = founding.clone();
            let P::ServerCreated { name, .. } = &mut op.payload else { unreachable!() };
            *name = "stolen".into();
            op.hlc.physical_ms -= ms_back;
            op.sign(&master, &pk);
            op.sign_device(&keys(LAPTOP).0);
            op
        };
        let holds = |s: &ServerState, op: &CrdtOp| {
            s.op_log.iter().chain(s.stored.iter().map(|(o, _)| o)).chain(s.held.iter().map(|(o, _)| o)).any(|o| o.content_hash() == op.content_hash())
        };
        let founded_on_the_first = |s: &ServerState, what: &str| {
            assert_eq!(authority::founding_op(s).map(CrdtOp::content_hash), Some(founding.content_hash()), "{what}: founded on another op");
            assert_eq!(s.name.read().as_str(), "s", "{what}: named by the second founding op");
        };
        for ms_back in [10, 0] {
            let forged = second(ms_back);
            let out = owner.ingest_remote(std::slice::from_ref(&forged));
            assert!(!holds(&owner, &forged) && out.rows.is_empty(), "the founder's replica kept a second founding op ({ms_back} ms back)");
            founded_on_the_first(&owner, "the founder's replica");
        }
        let mut replica = device_replica(&owner.server_id, OTHER);
        judged_by(&mut replica, after.clone());
        replica.ingest_remote(std::slice::from_ref(&founding));
        let forged = second(10);
        replica.ingest_remote(std::slice::from_ref(&forged));
        assert!(!holds(&replica, &forged), "a replica folding from genesis kept a second founding op");
        founded_on_the_first(&replica, "a replica folding from genesis");
        let mut fresh = device_replica(&owner.server_id, OTHER);
        judged_by(&mut fresh, after);
        fresh.ingest_remote(&[forged.clone(), founding.clone()]);
        assert!(!holds(&fresh, &forged), "a fresh replica handed both kept the removed device's");
        founded_on_the_first(&fresh, "a fresh replica handed both");
    }

    #[test]
    fn the_restore_point_is_the_checkpoint_first_folded_last_before_t() {
        let w = world();
        assert_eq!(w.owner.restore_for(3_000).map(|o| o.hlc), Some(w.cp1.hlc.clone()));
        assert_eq!(w.owner.restore_for(6_000).map(|o| o.hlc), Some(w.thief_cp.hlc.clone()));
        assert!(w.owner.restore_for(500).is_none(), "nothing before T: the founding op");
    }

    /// Section 8.3: the settling keeps what the dropped device did before T as this
    /// replica stored it, drops what it did after, and is a child of the current base
    /// carrying its stamp and our roster with the removal.
    #[test]
    fn a_settling_keeps_what_the_dropped_device_did_before_t_and_nothing_after() {
        let mut w = world();
        let (settling, sign) = settle(&mut w);
        let base = w.owner.base.as_ref().expect("a base");
        assert_eq!(base.hlc, settling.hlc, "the settling is the base");
        assert_eq!(base.parent, Some(w.thief_cp.content_hash()), "a child of the current base");
        assert_eq!(w.owner.name.read().as_str(), "before T", "the rename stored before T stays, the later one goes");
        let stamp = base.state.cp_settles.clone().expect("the stamp");
        assert_eq!(base.state.cp_settled.as_deref(), Some(stamp.id().as_str()));
        assert_eq!(stamp.devices, vec![keys(LAPTOP).1]);
        assert!(base.state.cp_roster.is_some(), "carries the roster with the removal");
        assert!(w.owner.stored.iter().any(|(o, k)| o.hlc == sign.hlc && *k == RowKind::SettleSign), "our signature is a mark row");
        let _ = (&w.before_t, &w.after_t);
    }

    /// Section 7 (C27): a replica holding the settling's mark keeps only its line
    /// eligible, even after the settling itself is dropped: an honest sibling's chain on
    /// the old line, longer and by a counted device, never becomes the base again.
    #[test]
    fn a_settle_mark_confines_eligibility_after_the_settling_is_dropped() {
        let mut w = world();
        let mut sibling = w.owner.clone();
        let (settling, sign) = settle(&mut w);
        let (before, _) = rosters();
        let mut m = device_replica(&w.owner.server_id, OTHER);
        judged_by(&mut m, before.clone());
        m.ingest_remote(&w.log);
        let old_line: Vec<CrdtOp> = (0..6).map(|k| {
            rename(&mut sibling, &format!("old line {k}"));
            checkpoint(&mut sibling)
        }).collect();
        m.ingest_remote(&[settling.clone(), sign.clone()]);
        assert_eq!(m.base.as_ref().map(|b| b.hlc.clone()), Some(settling.hlc.clone()), "the member takes the settling");
        let later: Vec<CrdtOp> = (0..3).map(|_| checkpoint(&mut w.owner)).collect();
        m.ingest_remote(&later);
        assert_eq!(m.base.as_ref().map(|b| b.hlc.clone()), Some(later[2].hlc.clone()));
        let compared = |s: &ServerState| {
            s.op_log.iter().any(|o| o.hlc == settling.hlc)
                || s.stored.iter().any(|(o, k)| o.hlc == settling.hlc && matches!(k, RowKind::Parent | RowKind::Dormant))
        };
        assert!(!compared(&m), "precondition: the core dropped the settling itself");
        m.ingest_remote(&old_line);
        assert_eq!(m.base.as_ref().map(|b| b.hlc.clone()), Some(later[2].hlc.clone()), "the old line is off the mark's line");
        assert!(m.stored.iter().any(|(o, k)| o.hlc == sign.hlc && *k == RowKind::SettleSign), "the mark stays");
        assert!(m.stored.iter().any(|(o, k)| o.hlc == w.thief_cp.hlc && *k == RowKind::SettlePin), "with its pinned parent");

        // A replica that never held the settling at all: the mark and its pin alone.
        let mut fresh = device_replica(&w.owner.server_id, OTHER);
        judged_by(&mut fresh, before);
        fresh.ingest_remote(&w.log);
        fresh.ingest_remote(std::slice::from_ref(&sign));
        fresh.ingest_remote(&later[1..]);
        fresh.ingest_remote(&old_line);
        assert_eq!(fresh.base.as_ref().map(|b| b.hlc.clone()), Some(later[2].hlc.clone()), "the mark alone confines");
        let _ = &w.laptop;
    }

    /// Section 8.3: a replica that learns the removal only from the settling's
    /// `cp_roster` refuses the child the stolen laptop races onto the settling.
    #[test]
    fn the_settlings_roster_uncounts_the_thief_racing_a_child_onto_it() {
        let mut w = world();
        let (settling, sign) = settle(&mut w);
        let (before, _) = rosters();
        let mut m = device_replica(&w.owner.server_id, OTHER);
        judged_by(&mut m, before);
        m.ingest_remote(&w.log);
        w.laptop.view_source = None;
        w.laptop.authority = Arc::default();
        w.laptop.ingest_remote(&[settling.clone(), sign.clone()]);
        let raced = checkpoint(&mut w.laptop);
        m.ingest_remote(&[settling.clone(), sign, raced.clone()]);
        assert_eq!(m.base.as_ref().map(|b| b.hlc.clone()), Some(settling.hlc.clone()), "the thief's child is no base");
        assert_eq!(
            m.authority.device_verdict(&keys(OWNER).1, &keys(LAPTOP).1),
            crate::crdt::authority::DeviceVerdict::Uncounted,
            "the removal came with the settling",
        );
    }

    /// Section 14 (RC32-9, R33-6): past 32 marks, each is charged to its lightest counted
    /// signer and the heaviest-charged device loses first, so a counted device that
    /// floods marks and co-signs the honest one never pushes the honest one out.
    #[test]
    fn a_mark_flood_never_pushes_out_a_mark_an_honest_device_signed() {
        let mut w = world();
        let (_, honest) = settle(&mut w);
        let CrdtPayload::SettleSign { stamp } = &honest.payload else { unreachable!() };
        let (before, _) = rosters();
        let mut m = device_replica(&w.owner.server_id, OTHER);
        judged_by(&mut m, before);
        m.ingest_remote(&w.log);
        let co_sign = w.laptop.create_op(P::SettleSign { stamp: stamp.signed_by(&keys(LAPTOP).0) });
        let flood: Vec<CrdtOp> = (0..40)
            .map(|k| w.laptop.create_op(P::SettleSign { stamp: SettleStamp { t_ms: 10 + k, generation: stamp.generation + 1, ..stamp.clone() }.signed_by(&keys(LAPTOP).0) }))
            .collect();
        m.ingest_remote(&flood);
        m.ingest_remote(&[co_sign.clone(), honest.clone()]);
        let marks: std::collections::HashSet<String> = m
            .stored
            .iter()
            .filter(|(_, k)| *k == RowKind::SettleSign)
            .filter_map(|(o, _)| match &o.payload { P::SettleSign { stamp } => Some(stamp.id()), _ => None })
            .collect();
        assert_eq!(marks.len(), crate::crdt::fold::MAX_SETTLE_MARKS, "bounded");
        assert!(marks.contains(&stamp.id()), "the honest mark stays");
        assert!(m.stored.iter().any(|(o, _)| o.hlc == honest.hlc) && m.stored.iter().any(|(o, _)| o.hlc == co_sign.hlc), "with both its signatures");
    }

    /// Section 8.5: removing a device that signed a mark co-signs it: always on a retire,
    /// on a lost-or-stolen removal only when the mark was stored before T; never twice.
    #[test]
    fn a_removal_co_signs_the_marks_the_removed_device_signed() {
        let mut w = world();
        let (_, sign) = settle(&mut w);
        let CrdtPayload::SettleSign { stamp } = &sign.payload else { unreachable!() };
        let other = keys(9).1;
        let want = vec![SettleStamp { sigs: Vec::new(), ..stamp.clone() }];
        assert_eq!(w.owner.co_sign_stamps(&keys(PHONE).1, &other, None), want, "a retire co-signs every mark");
        assert!(w.owner.co_sign_stamps(&keys(LAPTOP).1, &other, None).is_empty(), "nothing the removed device did not sign");
        assert!(w.owner.co_sign_stamps(&keys(PHONE).1, &keys(PHONE).1, None).is_empty(), "nothing we signed already");
        let key = (sign.author.clone(), sign.hlc.physical_ms, sign.hlc.counter);
        let late: SeenAt = [(key.clone(), 9_000)].into_iter().collect();
        let early: SeenAt = [(key, 1_000)].into_iter().collect();
        assert!(w.owner.co_sign_stamps(&keys(PHONE).1, &other, Some((3_000, &late))).is_empty(), "lost: a mark first stored after T");
        assert_eq!(w.owner.co_sign_stamps(&keys(PHONE).1, &other, Some((3_000, &early))), want, "lost: one stored before T");
    }

    /// Section 7: a `SettleSign` is kept only from the owner, with its one signature by
    /// the op's proving device, over a held parent.
    #[test]
    fn a_settle_sign_is_kept_only_from_the_owner_with_its_own_device_signature() {
        let mut w = world();
        let (_, sign) = settle(&mut w);
        let CrdtPayload::SettleSign { stamp } = &sign.payload else { unreachable!() };
        let mut m = device_replica(&w.owner.server_id, OTHER);
        m.ingest_remote(&w.log);
        let mut phone = device_replica(&w.owner.server_id, PHONE);
        phone.ingest_remote(&w.log);
        let by_laptop_key = phone.create_op(P::SettleSign { stamp: stamp.signed_by(&keys(LAPTOP).0) });
        let unknown_parent = phone.create_op(P::SettleSign { stamp: SettleStamp { parent: "ab".repeat(32), ..stamp.clone() }.signed_by(&keys(PHONE).0) });
        let mut two = stamp.clone();
        two.sign(&keys(PHONE).0);
        let two_sigs = phone.create_op(P::SettleSign { stamp: two });
        m.ingest_remote(&[by_laptop_key.clone(), unknown_parent.clone(), two_sigs.clone()]);
        let kept = |m: &ServerState, o: &CrdtOp| m.stored.iter().any(|(x, k)| x.hlc == o.hlc && *k == RowKind::SettleSign);
        assert!(!kept(&m, &by_laptop_key), "a signature by another device than the proof's");
        assert!(!kept(&m, &unknown_parent), "a parent nobody holds");
        assert!(!kept(&m, &two_sigs), "more than one signature");
        let mut stranger = ServerState::skeleton(w.owner.server_id.clone());
        let (skp, sid_, spk) = keys(OTHER);
        stranger.set_hlc(Hlc::for_device(sid_, &keys(OTHER).1));
        stranger.set_signer(skp, spk);
        stranger.set_device_signer(keys(OTHER).0);
        let foreign = stranger.create_op(P::SettleSign { stamp: SettleStamp { sigs: Vec::new(), ..stamp.clone() }.signed_by(&keys(OTHER).0) });
        m.ingest_remote(std::slice::from_ref(&foreign));
        assert!(!kept(&m, &foreign), "a member is not the owner");
        m.ingest_remote(std::slice::from_ref(&sign));
        assert!(kept(&m, &sign), "control: the settler's own signature is kept");
    }

    fn settled_state(op: &CrdtOp) -> ServerState {
        let P::ServerCheckpoint { state, .. } = &op.payload else { panic!("a checkpoint") };
        crate::crdt::server_state::parse_state(state).expect("a state")
    }

    /// Section 8.4: a fresh install's settling on the witnessed X is a child of X folding
    /// X and only what counts, and becomes the base above the thief's checkpoint.
    #[test]
    fn a_witnessed_settling_is_a_child_of_x_folding_only_what_counts() {
        let mut w = world();
        let (_, after) = rosters();
        judged_by(&mut w.owner, after.clone());
        let seen = SeenAt::new();
        let dropped = [keys(LAPTOP).1];
        let s = Settling { before: w.owner.authority.clone(), dropped: &dropped, t_ms: 3_000, seen: &seen, roster: after };
        let on = SettleOn::Witnessed(Box::new(w.cp1.clone()));
        let (ops, _) = w.owner.author_settling_on(&keys(OWNER).1, &s, &keys(PHONE).0, &on).expect("the settling is written");
        let settling = ops.last().unwrap();
        let state = settled_state(settling);
        assert_eq!(state.cp_parent.as_deref(), Some(hex::encode(w.cp1.content_hash()).as_str()), "a child of X");
        assert!(!["before T", "after T"].contains(&state.name.read().as_str()), "the dropped device's rename survived: {}", state.name.read());
        assert_eq!(w.owner.base.as_ref().map(|b| b.hash), Some(settling.content_hash()), "the settling is the base");
        let mut forged = w.thief_cp.clone();
        forged.author = keys(OTHER).1;
        assert!(w.owner.author_settling_on(&keys(OWNER).1, &s, &keys(PHONE).0, &SettleOn::Witnessed(Box::new(forged))).is_none(), "an X not signed by the owner");
        // A well-signed X by another identity: the author check alone refuses it.
        let (okp, oid, opk) = keys(OTHER);
        let mut other = ServerState::skeleton(w.owner.server_id.clone());
        other.set_hlc(super::super::hlc::Hlc::for_device(oid.clone(), &oid));
        other.set_signer(okp, opk);
        let theirs = other.create_op(w.cp1.payload.clone());
        assert!(theirs.verify_author().is_ok(), "precondition: signed by its author");
        assert!(w.owner.author_settling_on(&keys(OWNER).1, &s, &keys(PHONE).0, &SettleOn::Witnessed(Box::new(theirs))).is_none(), "an X another identity signed");
    }

    /// "I don't know": a child of our base folding the newest checkpoint a device we still
    /// count wrote.
    #[test]
    fn a_rollback_settling_folds_the_newest_checkpoint_a_kept_device_wrote() {
        let mut w = world();
        let (_, after) = rosters();
        judged_by(&mut w.owner, after.clone());
        let seen = SeenAt::new();
        let dropped = [keys(LAPTOP).1];
        let s = Settling { before: w.owner.authority.clone(), dropped: &dropped, t_ms: 0, seen: &seen, roster: after };
        assert_eq!(w.owner.rollback_point(&keys(OWNER).1).map(|o| o.hlc), Some(w.cp1.hlc.clone()), "R is the phone's checkpoint");
        let parent = w.owner.base.as_ref().map(|b| b.hash_hex());
        let (ops, _) = w.owner.author_settling_on(&keys(OWNER).1, &s, &keys(PHONE).0, &SettleOn::Rollback).expect("the rollback is written");
        let state = settled_state(ops.last().unwrap());
        assert_eq!(state.cp_parent, parent, "a child of our base");
        assert!(!["before T", "after T"].contains(&state.name.read().as_str()), "the dropped device's rename survived: {}", state.name.read());
    }
}
