//! A server in recovery at this replica (DEVICE_PROOF_DESIGN 8.8): what it held when it
//! heard of the recovery, and the hold that keeps every member's seat and server until
//! the recovery ends. The hold grants no authority: `op_allowed` reads the fold as it is.

use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use super::authority::Verdict;
use super::fold::OpKey;
use super::operations::{CrdtOp, CrdtPayload};
use super::server_state::ServerState;

/// What a member's seat or server may keep during a recovery, per group.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum Hold {
    Out,
    /// An existing seat stays; nothing removes the server.
    Keep,
    /// Also accepts a new seat (implies `Keep`).
    Seat,
}

/// The `floor_pending` row: recorded at the trigger and never moved (R33-1).
#[derive(Debug, Clone)]
pub(crate) struct Recovery {
    pub(crate) trigger_ms: u64,
    /// The pre-trigger base, content id hex (None: the founding op).
    pub(crate) base: Option<String>,
    pub(crate) base_op: Option<CrdtOp>,
    /// The whole fold at the trigger.
    pub(crate) pre: Arc<ServerState>,
    /// The kicks, bans and leaves the fold held at the trigger: any other is later.
    pub(crate) removals: BTreeSet<OpKey>,
    /// Per group (`""` = the server group, else the channel id): the certified masters
    /// holding a bound leaf there at the trigger. None until the node recorded them.
    pub(crate) leaves: Option<BTreeMap<String, BTreeSet<String>>>,
    /// A kick or ban this replica would not tear down for (R33-11): who removed us.
    pub(crate) shell: Option<String>,
    /// The floor round under the previous view (8.8 item 1, H4). RAM only: after a
    /// restart mid-round the mark names the pre-trigger base.
    pub(crate) round: Option<Round>,
    /// B, the checkpoint our mark names (`floor_b`): for the mark, the pin and KEEP only.
    pub(crate) floor_b: Option<CrdtOp>,
    /// Part A (HOL-SEC-230, -231): the (master, device) pairs whose folded ops the view
    /// stopped counting at the trigger. Empty for a base step-back (8.8 item 1).
    pub(crate) dropped: Vec<(String, String)>,
    /// The ops those devices proved that the fold held at the trigger, by (author, ms,
    /// counter) to content id: they keep counting here until the recovery decides them.
    pub(crate) kept: BTreeMap<(String, u64, u32), [u8; 32]>,
}

/// The owner as the previous view judged it, while the round runs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Round {
    pub(crate) owner: String,
    /// Owner devices that wrote the pre-trigger base or its held ancestors and that the
    /// new view no longer counts: counted again until the round ends.
    pub(crate) recount: Vec<String>,
    /// Content ids of every checkpoint held at the trigger (RC32-2).
    pub(crate) held_at_trigger: BTreeSet<[u8; 32]>,
    /// The owner's entry in the new view, put back when the round ends.
    pub(crate) unpinned: super::authority::ViewEntry,
}

#[derive(Serialize, Deserialize)]
struct Row {
    trigger_ms: u64,
    #[serde(default)]
    base: Option<String>,
    #[serde(default)]
    base_op: Option<CrdtOp>,
    pre: ServerState,
    #[serde(default)]
    removals: Vec<OpKey>,
    #[serde(default)]
    leaves: Option<BTreeMap<String, BTreeSet<String>>>,
    #[serde(default)]
    shell: Option<String>,
    #[serde(default)]
    floor_b: Option<CrdtOp>,
    #[serde(default)]
    dropped: Vec<(String, String)>,
    #[serde(default)]
    kept: Vec<(String, u64, u32, String)>,
}

impl Recovery {
    pub(crate) fn to_json(&self) -> Option<String> {
        let row = Row {
            trigger_ms: self.trigger_ms,
            base: self.base.clone(),
            base_op: self.base_op.clone(),
            pre: self.pre.lean_snapshot(),
            removals: self.removals.iter().cloned().collect(),
            leaves: self.leaves.clone(),
            shell: self.shell.clone(),
            floor_b: self.floor_b.clone(),
            dropped: self.dropped.clone(),
            kept: self.kept.iter().map(|((a, ms, c), h)| (a.clone(), *ms, *c, hex::encode(h))).collect(),
        };
        // The row carries a whole state: serde's frames for it take a few hundred KB in a
        // Windows debug build, more than a node task has left (as `parse_state`).
        std::thread::scope(|scope| std::thread::Builder::new().stack_size(8 << 20).spawn_scoped(scope, || serde_json::to_string(&row).ok()).ok()?.join().ok().flatten())
    }

    pub(crate) fn from_json(json: &str) -> Option<Self> {
        let row: Row = std::thread::scope(|scope| std::thread::Builder::new().stack_size(8 << 20).spawn_scoped(scope, || serde_json::from_str::<Row>(json).ok()).ok()?.join().ok().flatten())?;
        let removals = row.removals.into_iter().collect();
        let mut kept = BTreeMap::new();
        for (a, ms, c, h) in row.kept {
            let h: [u8; 32] = hex::decode(&h).ok()?.try_into().ok()?;
            kept.insert((a, ms, c), h);
        }
        Some(Self {
            trigger_ms: row.trigger_ms,
            base: row.base,
            base_op: row.base_op,
            pre: Arc::new(row.pre),
            removals,
            leaves: row.leaves,
            shell: row.shell,
            round: None,
            floor_b: row.floor_b,
            dropped: row.dropped,
            kept,
        })
    }

    /// A part A hold: the fold keeps what it held, no base was stepped back.
    pub(crate) fn keeps_fold(&self) -> bool {
        !self.dropped.is_empty()
    }

    /// Whether this hold keeps `op` counted: one of the ops it recorded, proved by a
    /// device it recorded, judged by the op's own content id (never the one held at its
    /// key, HOL-SEC-224).
    pub(crate) fn keeps(&self, op: &CrdtOp) -> bool {
        let Some(dev) = op.dev.as_deref() else { return false };
        self.kept.get(&(op.author.clone(), op.hlc.physical_ms, op.hlc.counter)).is_some_and(|h| *h == op.content_hash())
            && self.dropped.iter().any(|(m, d)| *m == op.author && *d == dev.device)
    }

    /// Whether `master` held a bound leaf in `group` at the trigger.
    fn had_leaf(&self, group: &str, master: &str) -> bool {
        self.leaves.as_ref().and_then(|l| l.get(group)).is_some_and(|s| s.contains(master))
    }
}

/// What part A's trigger weighs across a rebuild (`ServerState::kept_candidates`).
pub(crate) struct KeptCandidates {
    ops: Vec<(OpKey, String, [u8; 32])>,
    pre: Arc<ServerState>,
    removals: BTreeSet<OpKey>,
}

/// The master a kick, ban or leave takes out.
pub(crate) fn removal_target(op: &CrdtOp) -> Option<&str> {
    match &op.payload {
        CrdtPayload::MemberRemoved { peer_id, .. } | CrdtPayload::MemberBanned { peer_id, .. } => Some(peer_id),
        _ => None,
    }
}

/// What a removal of us during a recovery does here (R33-11).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Teardown {
    /// Not in recovery, or our own leave, or the owner's counted device removed us.
    Go,
    /// The hold keeps the server.
    Keep,
    /// Kept as a shell until the recovery ends: removed by this master.
    Shell(String),
}

impl ServerState {
    pub(crate) fn in_recovery(&self) -> bool {
        self.recovery.is_some()
    }

    /// Whether this replica signs its own ops (the node set the signer and the clock).
    pub(super) fn can_author(&self) -> bool {
        self.hlc.is_some() && self.signer_set()
    }

    /// A floor holds this server's base (rule 4): members see no step-back banner.
    pub(crate) fn floor_holds(&self) -> bool {
        self.floor_base
    }

    /// The one predicate every hold site asks (8.8): `channel` None = the server group.
    pub(crate) fn recovery_hold(&self, channel: Option<&str>, master: &str) -> Hold {
        let Some(r) = &self.recovery else { return Hold::Out };
        let m = super::resolve_identity(master);
        if self.is_banned(&m) || self.removed_after_trigger(r, &m).is_some() {
            return Hold::Out;
        }
        let in_pre = r.pre.is_member(&m);
        if !in_pre {
            return Hold::Out;
        }
        match channel {
            None => {
                if r.had_leaf("", &m) || self.counted_admission(&m) { Hold::Seat } else { Hold::Keep }
            }
            Some(ch) => {
                let sees = if self.is_member(&m) && self.channels.contains_key(ch) { self.can_see_channel(&m, ch) } else { r.pre.can_see_channel(&m, ch) };
                match (sees, r.had_leaf(ch, &m)) {
                    (false, _) => Hold::Out,
                    (true, true) => Hold::Seat,
                    (true, false) => Hold::Keep,
                }
            }
        }
    }

    /// 8.8 class 3, our side: the fold counts us, the hold keeps us, or we are a shell.
    pub(crate) fn held_as_member(&self, us: &str) -> bool {
        self.is_member(us) || self.recovery_hold(None, us) != Hold::Out || self.recovery.as_ref().is_some_and(|r| r.shell.is_some())
    }

    /// 8.8 class 3, a peer's side: the fold counts it or KEEP holds it (a shell is never
    /// answered: it is out of KEEP once removed).
    pub(crate) fn keeps_peer(&self, peer: &str) -> bool {
        self.is_member(peer) || self.recovery_hold(None, peer) != Hold::Out
    }

    /// 8.8 class 3, where a peer is placed or answered as a co-member: the fold or SEAT.
    pub(crate) fn seats_peer(&self, peer: &str) -> bool {
        self.is_member(peer) || self.recovery_hold(None, peer) == Hold::Seat
    }

    /// The state that judges channels for our liveness reads: the pre-trigger state while
    /// the hold keeps us and the fold no longer holds us.
    pub(crate) fn liveness_state(&self, us: &str) -> &ServerState {
        match self.recovery.as_deref() {
            Some(r) if !self.is_member(us) && self.held_as_member(us) => &r.pre,
            _ => self,
        }
    }

    /// The state that judges `master`'s channels: the fold while it counts the master,
    /// else the pre-trigger state while the hold gives it at least `level`.
    pub(crate) fn judged_for(&self, master: &str, level: Hold) -> Option<&ServerState> {
        if self.is_member(master) {
            return Some(self);
        }
        let r = self.recovery.as_deref()?;
        (level > Hold::Out && self.recovery_hold(None, master) >= level).then_some(&*r.pre)
    }

    /// A kick, ban or leave of `master` the current fold admits that the fold did not
    /// hold at the trigger.
    fn removed_after_trigger<'a>(&'a self, r: &Recovery, master: &str) -> Option<&'a CrdtOp> {
        self.op_log
            .iter()
            .filter(|o| removal_target(o) == Some(master))
            .filter(|o| !r.removals.contains(&(o.author.clone(), o.hlc.clone())))
            .max_by(|a, b| a.hlc.cmp(&b.hlc))
    }

    /// D34-1: `master`'s current span opens with an admission the NEW view counts.
    fn counted_admission(&self, master: &str) -> bool {
        self.op_log
            .iter()
            .rev()
            .find(|o| matches!(&o.payload, CrdtPayload::MemberAdded { peer_id, .. } if peer_id == master))
            .is_some_and(|o| self.verdict(o) == Verdict::Counted)
    }

    /// The silent re-ask (M2) of a refused admission of ours: never during a recovery,
    /// where it would seal a join ask to a door the stolen owner device holds (R34-11).
    pub(crate) fn may_reask_admission(&self, us: &str) -> bool {
        !self.in_recovery() && self.refused_own_admission(us)
    }

    /// A member of the base, its parent or the pre-trigger state: who may send a floor
    /// mark the plan then judges against the checkpoint it names.
    pub(super) fn floor_author_known(&self, author: &str) -> bool {
        [&self.base, &self.parent].into_iter().flatten().any(|b| b.state.is_member(author))
            || self.recovery.as_ref().is_some_and(|r| r.pre.is_member(author))
    }

    /// What a removal of `us` does while this server is in recovery here.
    pub(crate) fn recovery_teardown(&self, us: &str) -> Teardown {
        let Some(r) = &self.recovery else { return Teardown::Go };
        let us = super::resolve_identity(us);
        if r.shell.is_some() {
            return Teardown::Keep;
        }
        let Some(op) = self.removed_after_trigger(r, &us) else {
            return if self.is_banned(&us) { Teardown::Go } else { Teardown::Keep };
        };
        let owner_counted = self.anchor_owner().as_deref() == Some(op.author.as_str()) && self.verdict(op) == Verdict::Counted;
        if op.author == us || owner_counted { Teardown::Go } else { Teardown::Shell(op.author.clone()) }
    }

    /// The trigger of 8.8 item 1, judged on a plan about to be installed: a member
    /// identity other than the owner whose current base the new plan no longer finds
    /// eligible, with no counted settle mark deciding it.
    pub(super) fn recovery_trigger(&self, new_base: Option<&str>, still_eligible: bool, settled: bool, owner: Option<&str>) -> Option<Recovery> {
        if self.recovery.is_some() || settled || still_eligible {
            return None;
        }
        let old = self.base.as_ref()?;
        let me = self.hlc.as_ref().map(|h| h.actor().to_string())?;
        if new_base == Some(old.hash_hex().as_str()) || owner == Some(me.as_str()) || !self.is_member(&me) {
            return None;
        }
        let base_op = self.op_log.iter().find(|o| self.op_log_dedup.get(&(o.author.clone(), o.hlc.clone())) == Some(&old.hash)).cloned();
        let removals = self
            .op_log
            .iter()
            .chain(self.stored.iter().map(|(o, _)| o))
            .filter(|o| removal_target(o).is_some())
            .map(|o| (o.author.clone(), o.hlc.clone()))
            .collect();
        Some(Recovery {
            trigger_ms: super::hlc::wall_clock_ms(),
            base: Some(old.hash_hex()),
            base_op,
            pre: Arc::new(self.lean_snapshot()),
            removals,
            leaves: None,
            shell: None,
            round: None,
            floor_b: None,
            dropped: Vec::new(),
            kept: BTreeMap::new(),
        })
    }

    /// Part A (HOL-SEC-230, -231), before a rebuild: the folded ops it may drop, proved
    /// by a device the view now judges Uncounted (never Missing: a roster not held yet
    /// decides nothing) for an identity other than ours (ours settles through our own
    /// settling). Empty under a base step-back, which 8.8 item 1 holds, or when we are no
    /// member. With them, the fold as it stands (`pre`).
    /// Whether `kept_candidates` would find any (no snapshot): the common rebuild skips it.
    pub(super) fn may_keep(&self) -> bool {
        let Some(me) = self.hlc.as_ref().map(|h| h.actor()) else { return false };
        self.recovery.as_ref().is_none_or(|r| r.keeps_fold())
            && self.op_log.iter().any(|o| o.author != me && o.dev.is_some() && self.verdict(o) == Verdict::Uncounted)
    }

    #[inline(never)]
    pub(super) fn kept_candidates(&self) -> Option<KeptCandidates> {
        if self.recovery.as_ref().is_some_and(|r| !r.keeps_fold()) {
            return None;
        }
        let me = self.hlc.as_ref().map(|h| h.actor().to_string())?;
        if !self.is_member(&me) {
            return None;
        }
        let ops: Vec<(OpKey, String, [u8; 32])> = self
            .op_log
            .iter()
            // The full verdict: an op a retire endorses or this hold keeps folds anyway, so
            // only a view change since the last fold makes one (and the snapshot) here.
            .filter(|o| o.author != me && self.verdict(o) == Verdict::Uncounted)
            .filter_map(|o| Some(((o.author.clone(), o.hlc.clone()), o.proven_device()?.to_string(), o.content_hash())))
            .collect();
        if ops.is_empty() {
            return None;
        }
        let removals = self
            .op_log
            .iter()
            .chain(self.stored.iter().map(|(o, _)| o))
            .filter(|o| removal_target(o).is_some())
            .map(|o| (o.author.clone(), o.hlc.clone()))
            .collect();
        Some(KeptCandidates { ops, pre: Arc::new(self.lean_snapshot()), removals })
    }

    /// Part A's trigger, after the rebuild: the candidates it no longer folds, for
    /// devices nothing decides (`device_decided`). A new hold, or the current part A hold
    /// grown by the new losses.
    pub(super) fn kept_trigger(&self, c: KeptCandidates) -> Option<Recovery> {
        let all = || self.op_log.iter().chain(self.stored.iter().map(|(o, _)| o));
        let deciders = Self::deciders(all());
        let owner = self.anchor_owner();
        let lost: Vec<(OpKey, String, [u8; 32])> = c
            .ops
            .into_iter()
            .filter(|(k, _, _)| !self.op_log.iter().any(|o| o.author == k.0 && o.hlc == k.1))
            .filter(|(k, d, _)| !self.device_decided(&deciders, self.base.as_deref(), owner.as_deref(), &k.0, d))
            .collect();
        if lost.is_empty() {
            return None;
        }
        let mut r = match self.recovery.as_deref() {
            Some(r) => r.clone(),
            None => Recovery {
                trigger_ms: super::hlc::wall_clock_ms(),
                base: None,
                base_op: None,
                pre: c.pre,
                removals: c.removals,
                leaves: None,
                shell: None,
                round: None,
                floor_b: None,
                dropped: Vec::new(),
                kept: BTreeMap::new(),
            },
        };
        for ((author, hlc), dev, h) in lost {
            let pair = (author.clone(), dev);
            if !r.dropped.contains(&pair) {
                r.dropped.push(pair);
            }
            r.kept.insert((author, hlc.physical_ms, hlc.counter), h);
        }
        r.dropped.sort();
        Some(r)
    }

    /// The ops that can decide a dropped device: retires and settle signs.
    pub(super) fn deciders<'a>(ops: impl Iterator<Item = &'a CrdtOp>) -> Vec<&'a CrdtOp> {
        ops.filter(|o| matches!(o.payload, CrdtPayload::DeviceRetired { .. } | CrdtPayload::SettleSign { .. })).collect()
    }

    /// Whether `device` of `master` needs no hold: the view counts it again, a counted
    /// retire of `master` names it (it decides what the device's ops count for), or, for
    /// the owner, a settling on `base`'s line drops it. Never a base alone: the settler's
    /// first checkpoint names no device.
    pub(super) fn device_decided(&self, deciders: &[&CrdtOp], base: Option<&super::fold::Base>, owner: Option<&str>, master: &str, device: &str) -> bool {
        if self.authority.counts(master, device) {
            return true;
        }
        if deciders.iter().any(|o| {
            o.author == master
                && matches!(&o.payload, CrdtPayload::DeviceRetired { device: d, .. } if d == device)
                && self.direct_verdict(o) == Verdict::Counted
        }) {
            return true;
        }
        if owner != Some(master) {
            return false;
        }
        let Some(b) = base else { return false };
        if b.state.cp_settles.as_ref().is_some_and(|st| st.devices.iter().any(|d| d == device)) {
            return true;
        }
        let Some(id) = b.state.cp_settled.as_deref() else { return false };
        deciders.iter().any(|o| {
            o.author == master && matches!(&o.payload, CrdtPayload::SettleSign { stamp } if stamp.id() == id && stamp.devices.iter().any(|d| d == device))
        })
    }

    /// Whether `op` folds without part A's hold: counted by the view or a retire.
    fn counts_unheld(&self, op: &CrdtOp) -> bool {
        matches!(self.direct_verdict(op), Verdict::Counted) || self.is_endorsed(op)
    }

    /// The end of a part A hold: every dropped device is decided (`device_decided`), or
    /// another identity's every kept op is decided by the owner's base, or every kept op
    /// folds without the hold. Never by a clock; a kept op no longer held decides
    /// nothing (compaction is no decision).
    fn kept_hold_ends(&self, r: &Recovery) -> bool {
        let all = || self.op_log.iter().chain(self.stored.iter().map(|(o, _)| o));
        let held = |k: &(String, u64, u32), h: &[u8; 32]| all().find(|o| o.author == k.0 && o.hlc.physical_ms == k.1 && o.hlc.counter == k.2 && o.content_hash() == *h);
        let folded: HashSet<(&str, u64, u32)> = self.op_log.iter().map(|o| (o.author.as_str(), o.hlc.physical_ms, o.hlc.counter)).collect();
        let unheld = |k: &(String, u64, u32), h: &[u8; 32]| held(k, h).is_some_and(|o| folded.contains(&(k.0.as_str(), k.1, k.2)) && self.counts_unheld(o));
        if r.kept.iter().all(|(k, h)| unheld(k, h)) {
            return true;
        }
        let deciders = Self::deciders(all());
        let owner = self.anchor_owner();
        // Another identity's op the owner's newer base no longer folds on top and holds
        // unparked (or no more): the owner's checkpoint decided it (part C's mitigation).
        let base_at = self.base.as_ref().map(|b| b.hlc.clone());
        let parked = |k: &(String, u64, u32)| {
            self.stored.iter().any(|(o, kind)| o.author == k.0 && o.hlc.physical_ms == k.1 && o.hlc.counter == k.2 && matches!(kind, super::fold::RowKind::Parked(_)))
        };
        let by_base = |k: &(String, u64, u32)| {
            base_at.as_ref().is_some_and(|b| (k.1, k.2) < (b.physical_ms, b.counter)) && !folded.contains(&(k.0.as_str(), k.1, k.2)) && !parked(k)
        };
        r.dropped.iter().all(|(m, d)| {
            if self.device_decided(&deciders, self.base.as_deref(), owner.as_deref(), m, d) {
                return true;
            }
            owner.as_deref() != Some(m.as_str())
                && r.kept
                    .iter()
                    .filter(|(k, h)| k.0 == *m && held(k, h).is_none_or(|o| o.proven_device() == Some(d.as_str())))
                    .all(|(k, h)| by_base(k) || unheld(k, h))
        })
    }

    /// The round a trigger opens (8.8 item 1): the owner devices that wrote the
    /// pre-trigger base or a held ancestor and that the new view no longer counts. None
    /// when there are none to count again (then the mark goes out at once).
    pub(super) fn open_round(&self, owner: Option<&str>) -> Option<Round> {
        let owner = owner?;
        let base = self.base.as_ref()?;
        let line: BTreeSet<String> = std::iter::once(base.hash_hex()).chain(base.state.cp_lineage.iter().cloned()).collect();
        let checkpoints = || self.op_log.iter().chain(self.stored.iter().map(|(o, _)| o)).filter(|o| matches!(o.payload, CrdtPayload::ServerCheckpoint { .. }));
        let mut recount: Vec<String> = checkpoints()
            .filter(|o| o.author == owner && line.contains(&hex::encode(self.content_of(o))))
            .filter_map(|o| o.proven_device().map(str::to_string))
            .filter(|d| !self.authority.counts(owner, d))
            .collect();
        recount.sort();
        recount.dedup();
        if recount.is_empty() {
            return None;
        }
        let held_at_trigger = checkpoints().map(|o| self.content_of(o)).collect();
        let unpinned = self.authority.entry(owner).cloned()?;
        Some(Round { owner: owner.to_string(), recount, held_at_trigger, unpinned })
    }

    /// Whether a floor round runs here (the node asks and ends it).
    pub(crate) fn floor_round_open(&self) -> bool {
        self.recovery.as_ref().is_some_and(|r| r.round.is_some())
    }

    /// `entry` for `master` as the round judges it: the owner's dropped writers counted.
    pub(super) fn round_entry(&self, master: &str, mut entry: super::authority::ViewEntry) -> super::authority::ViewEntry {
        let Some(round) = self.recovery.as_ref().and_then(|r| r.round.as_ref()).filter(|r| r.owner == master) else { return entry };
        if let Some(auth) = entry.auth.as_mut() {
            for d in &round.recount {
                auth.removed.remove(d);
                auth.counted.insert(d.clone());
            }
        }
        entry
    }

    /// Put the round's judgment of the owner into the view, where it is missing.
    pub(super) fn pin_round_view(&mut self) {
        let Some(owner) = self.recovery.as_ref().and_then(|r| r.round.as_ref()).map(|r| r.owner.clone()) else { return };
        let Some(entry) = self.authority.entry(&owner).cloned() else { return };
        let pinned = self.round_entry(&owner, entry.clone());
        if pinned != entry {
            Arc::make_mut(&mut self.authority).insert(owner, pinned);
        }
    }

    /// End the round without a mark; true when one ran.
    pub(super) fn close_round(&mut self) -> bool {
        let Some(mut r) = self.recovery.as_deref().cloned() else { return false };
        let Some(round) = r.round.take() else { return false };
        self.recovery = Some(Arc::new(r));
        Arc::make_mut(&mut self.authority).insert(round.owner, round.unpinned);
        self.refresh_view();
        true
    }

    /// End the floor round with the `floor_base`s the answers carried: pick B under the
    /// previous view, then judge under the new one and mark B unless the base holds
    /// again. None when no round runs.
    pub(crate) fn end_floor_round(&mut self, answered: &[CrdtOp]) -> Option<super::fold::Ingested> {
        let mut r = self.recovery.as_deref()?.clone();
        let round = r.round.take()?;
        let now_ms = super::hlc::wall_clock_ms();
        let answered: Vec<CrdtOp> = answered
            .iter()
            .filter(|o| o.author == round.owner && matches!(o.payload, CrdtPayload::ServerCheckpoint { .. }))
            .filter(|o| o.verify_author().is_ok() && self.base_of_content(o).is_some())
            .cloned()
            .map(|mut o| {
                o.strip_bad_proof();
                o
            })
            .collect();
        let b = self.floor_pick(&round, &answered, now_ms).or_else(|| r.base_op.clone());
        self.close_round();
        r.round = None;
        let mut fresh = Vec::new();
        if let Some(b) = b.filter(|_| self.can_author() && !self.base_holds_again(now_ms)) {
            // B's own id: B may be an answer or a base no longer held, with a variant
            // held at its key (HOL-SEC-225).
            let cp = hex::encode(b.content_hash());
            fresh.push(self.create_op(CrdtPayload::FloorMark { cp: cp.clone() }));
            if super::authority::base_content_for(self, &cp).is_none() {
                fresh.push(b.clone());
            }
            r.floor_b = Some(b);
            self.recovery = Some(Arc::new(r));
        }
        let mut out = self.fold_all(fresh, super::fold::Ingested::default());
        if out.recovery.is_none() {
            out.recovery = Some(self.recovery.as_ref().and_then(|r| r.to_json()));
        }
        Some(out)
    }

    /// A recovery loaded after a restart that lost its round, or one triggered while
    /// this replica could not sign: mark the pre-trigger base now (8.8 item 1).
    pub(crate) fn mark_after_restart(&mut self) -> Option<super::fold::Ingested> {
        let mut r = self.recovery.as_deref()?.clone();
        if r.round.is_some() || r.floor_b.is_some() || r.shell.is_some() || !self.can_author() || self.base_holds_again(super::hlc::wall_clock_ms()) {
            return None;
        }
        let b = r.base_op.clone()?;
        let cp = hex::encode(b.content_hash());
        let mut fresh = vec![self.create_op(CrdtPayload::FloorMark { cp: cp.clone() })];
        if super::authority::base_content_for(self, &cp).is_none() {
            fresh.push(b.clone());
        }
        r.floor_b = Some(b);
        self.recovery = Some(Arc::new(r));
        let mut out = self.fold_all(fresh, super::fold::Ingested::default());
        if out.recovery.is_none() {
            out.recovery = Some(self.recovery.as_ref().and_then(|r| r.to_json()));
        }
        Some(out)
    }

    /// The end of a recovery (8.8): a counted settle mark's line holds the base, or the
    /// base is eligible by rule 1 or 2 (a counted writer, or endorsed). Never while the
    /// round judges under the previous view.
    pub(super) fn recovery_ends(&self, on_settle_line: bool) -> bool {
        if self.recovery.is_none() || self.floor_round_open() {
            return false;
        }
        if let Some(r) = self.recovery.as_deref().filter(|r| r.keeps_fold()) {
            return self.kept_hold_ends(r);
        }
        if on_settle_line {
            return true;
        }
        let Some(b) = &self.base else { return false };
        self.op_log
            .iter()
            .find(|o| self.op_log_dedup.get(&(o.author.clone(), o.hlc.clone())) == Some(&b.hash))
            .is_some_and(|o| self.verdict(o) == Verdict::Counted)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::super::authority::{self, AuthorityView, KeyRule};
    use super::super::fold::RowKind;
    use super::super::operations::{CrdtOp, CrdtPayload as P, MemberRole};
    use super::super::server_state::{Founder, ServerState};
    use super::super::testkeys::keys;
    use super::*;
    use crate::identity::roster::{r_pub_of, sign_consent, sign_recovery, sign_removal, sign_vouch, Roster};

    const OWNER: u8 = 1;
    const PHONE: u8 = 2;
    const RECOVERY: u8 = 3;
    const LAPTOP: u8 = 4;
    const MEMBER: u8 = 5;
    const MEMBER_PHONE: u8 = 6;
    const MEMBER_RECOVERY: u8 = 7;
    const MOD: u8 = 8;
    const MOD_PHONE: u8 = 9;
    const MOD_RECOVERY: u8 = 10;
    const STRANGER: u8 = 11;
    const MEMBER_OLD: u8 = 12;
    const LATE: u8 = 13;
    const LATE_PHONE: u8 = 14;
    const LATE_RECOVERY: u8 = 15;

    /// The owner's roster before and after its PHONE (every checkpoint's writer) is dropped.
    fn owner_rosters() -> (Roster, Roster) {
        let (master, m_id, _) = keys(OWNER);
        let mut before = Roster::genesis(&master, &keys(RECOVERY).0, &keys(PHONE).0, 1_000);
        before.add_vouch(sign_vouch(&keys(PHONE).0, &m_id, &before.base(), &keys(LAPTOP).1));
        before.add_consent(sign_consent(&keys(LAPTOP).0, &m_id));
        let mut after = before.clone();
        let recovery = sign_recovery(&master, &keys(RECOVERY).0, 2_000, std::slice::from_ref(&keys(LAPTOP).1), false);
        after.add_phrase_statement(&r_pub_of(&keys(RECOVERY).0), Some(recovery), None).expect("the phrase drops the phone");
        (before, after)
    }

    fn view(owner: &Roster) -> Arc<AuthorityView> {
        let mut v = AuthorityView::judging();
        v.insert(keys(OWNER).1, authority::judge(&keys(OWNER).1, &KeyRule::FirstHeld, &[owner]));
        for (tag, phone, rec) in [(MEMBER, MEMBER_PHONE, MEMBER_RECOVERY), (MOD, MOD_PHONE, MOD_RECOVERY), (LATE, LATE_PHONE, LATE_RECOVERY)] {
            let r = Roster::genesis(&keys(tag).0, &keys(rec).0, &keys(phone).0, 1_000);
            v.insert(keys(tag).1, authority::judge(&keys(tag).1, &KeyRule::FirstHeld, &[&r]));
        }
        Arc::new(v)
    }

    fn replica(sid: &str, tag: u8, device: u8, signs: bool) -> ServerState {
        let (kp, id, pk) = keys(tag);
        let (dkp, did, _) = keys(device);
        let mut s = ServerState::skeleton(sid.into());
        s.set_hlc(super::super::hlc::Hlc::for_device(id, &did));
        if signs {
            s.set_signer(kp, pk);
            s.set_device_signer(dkp);
        }
        s
    }

    fn admit(owner: &mut ServerState, tag: u8) -> CrdtOp {
        let ask = super::super::operations::JoinAsk::sign(&owner.server_id, 1, &keys(tag).0);
        owner.author_checked(P::MemberAdded { peer_id: keys(tag).1, display_name: "m".into(), follow: None, ask: Some(ask) }).unwrap()
    }

    fn checkpoint(s: &mut ServerState) -> CrdtOp {
        let covers = s.checkpoint_covers();
        let json = s.checkpoint_json(&keys(OWNER).1, &[], super::super::hlc::wall_clock_ms()).unwrap();
        s.author_checkpoint(P::ServerCheckpoint { state: json, covers }).expect("the checkpoint becomes the base").0
    }

    struct World {
        owner: ServerState,
        log: Vec<CrdtOp>,
        cp0: CrdtOp,
        cp1: CrdtOp,
        /// A sibling of cp1 on cp0, by the same phone: off cp1's line.
        fork: CrdtOp,
    }

    /// The owner's phone founds (committing to its recovery key), admits MEMBER and MOD
    /// (a moderator), writes cp0, admits LATE, and writes cp1: every checkpoint is the
    /// phone's.
    fn world() -> World {
        let (before, _) = owner_rosters();
        let (master, m_id, pk) = keys(OWNER);
        let (phone, phone_id, _) = keys(PHONE);
        let r_pub = before.r_pub.clone();
        let (mut owner, _) = ServerState::found_on("s".into(), m_id, Founder { device_peer_id: &phone_id, device: Some(&phone), r_pub: Some(&r_pub) }, master, pk);
        owner.authority = view(&before);
        admit(&mut owner, MEMBER);
        admit(&mut owner, MOD);
        owner.author_checked(P::RoleChanged { peer_id: keys(MOD).1, role: MemberRole::Moderator, priority: 0 }).unwrap();
        let cp0 = checkpoint(&mut owner);
        admit(&mut owner, LATE);
        let mut other = owner.clone();
        let cp1 = checkpoint(&mut owner);
        other.author_checked(P::ServerRenamed { new_name: "fork".into() }).unwrap();
        let fork = checkpoint(&mut other);
        let log = owner.op_log.iter().chain(owner.stored.iter().map(|(o, _)| o)).cloned().collect();
        World { owner, log, cp0, cp1, fork }
    }

    /// `tag`'s replica holding the world, judged by the owner roster from before.
    fn member_of(w: &World, tag: u8, device: u8, signs: bool) -> ServerState {
        let (before, _) = owner_rosters();
        let mut s = replica(&w.owner.server_id, tag, device, signs);
        s.authority = view(&before);
        s.ingest_remote(&w.log);
        assert_eq!(s.base.as_ref().map(|b| b.hash), Some(w.cp1.content_hash()), "precondition: cp1 is the base");
        s
    }

    /// The recovery reaches the replica: the owner's view drops the phone, and the floor
    /// round ends with no answer.
    fn hears_of_recovery(s: &mut ServerState) {
        hears_of_recovery_in_round(s);
        let _ = s.end_floor_round(&[]);
    }

    /// As `hears_of_recovery`, the round still open.
    fn hears_of_recovery_in_round(s: &mut ServerState) {
        let (_, after) = owner_rosters();
        s.authority = view(&after);
        let _ = s.rebuild_now();
    }

    fn marks_of(s: &ServerState) -> Vec<&CrdtOp> {
        s.stored.iter().filter(|(_, k)| *k == RowKind::FloorMark).map(|(o, _)| o).collect()
    }

    #[test]
    fn a_floor_keeps_the_members_base_when_the_only_writer_is_dropped() {
        let w = world();
        let mut m = member_of(&w, MEMBER, MEMBER_PHONE, true);
        hears_of_recovery(&mut m);
        assert!(m.in_recovery(), "the step back is a trigger");
        assert_eq!(m.base.as_ref().map(|b| b.hash), Some(w.cp1.content_hash()), "the member's own mark keeps cp1 as the base");
        assert!(m.floor_holds(), "eligible by rule 4 alone");
        let marks = marks_of(&m);
        assert_eq!(marks.len(), 1, "one mark of ours, stored");
        assert!(matches!(&marks[0].payload, P::FloorMark { cp } if *cp == hex::encode(w.cp1.content_hash())));
        assert!(m.is_member(&keys(MEMBER).1), "nothing vanished");
        let row = m.recovery.as_ref().and_then(|r| r.to_json()).expect("the floor_pending row");
        let back = Recovery::from_json(&row).expect("the row reads back");
        assert_eq!(back.base, Some(hex::encode(w.cp1.content_hash())));
        assert!(back.pre.is_member(&keys(MEMBER).1));
    }

    #[test]
    fn without_a_floor_the_hold_keeps_seats_and_seats_no_new_identity() {
        let w = world();
        let mut m = member_of(&w, MEMBER, MEMBER_PHONE, false);
        hears_of_recovery(&mut m);
        assert!(m.in_recovery());
        assert!(!m.floor_holds() && !m.is_member(&keys(MEMBER).1), "precondition: a step back with no mark");
        assert_eq!(m.recovery_teardown(&keys(MEMBER).1), Teardown::Keep, "nothing tears the server down");
        let ours = w.log.iter().find(|o| matches!(&o.payload, P::MemberAdded { peer_id, .. } if *peer_id == keys(MEMBER).1)).cloned().unwrap();
        let mut parked = m.clone();
        parked.stored.push((ours, RowKind::Parked(u64::MAX)));
        assert!(parked.refused_own_admission(&keys(MEMBER).1), "precondition: our admission waits to be asked again");
        assert!(!parked.may_reask_admission(&keys(MEMBER).1), "no silent re-ask during a recovery (R34-11)");
        parked.recovery = None;
        assert!(parked.may_reask_admission(&keys(MEMBER).1), "outside a recovery the re-ask goes as before");
        assert_eq!(m.recovery_hold(None, &keys(MOD).1), Hold::Keep, "a pre-trigger member's seat is kept");
        assert_eq!(m.recovery_hold(None, &keys(STRANGER).1), Hold::Out);
        let rules = crate::node::mls_authority::GroupRules::Server { state: &m, channel: None };
        assert_eq!(rules.keeps(&keys(MOD).1, ""), crate::crypto::Verdict::Accept, "an existing leaf is never unseated");
        assert!(matches!(rules.membership(&keys(MOD).1, ""), crate::crypto::Verdict::Hold(_)), "no leaf at the trigger and an uncounted admission: no new seat");
        assert!(matches!(rules.membership(&keys(STRANGER).1, ""), crate::crypto::Verdict::Hold(_)));
        let mut r = (**m.recovery.as_ref().unwrap()).clone();
        r.leaves = Some([(String::new(), [keys(MOD).1].into_iter().collect())].into_iter().collect());
        m.recovery = Some(Arc::new(r));
        assert_eq!(rules_seat(&m, &keys(MOD).1), crate::crypto::Verdict::Accept, "a leaf held at the trigger may be seated again");
        assert!(matches!(rules_seat(&m, &keys(STRANGER).1), crate::crypto::Verdict::Hold(_)), "never an identity the replica held no leaf for");
    }

    /// Section 9: an answerer in recovery offers its PRE-TRIGGER base whatever the ask,
    /// never where it stepped back to; others offer their base to a floor round only.
    #[test]
    fn a_member_in_recovery_offers_its_pre_trigger_base_to_every_ask() {
        let w = world();
        let calm = member_of(&w, MOD, MOD_PHONE, false);
        assert!(authority::floor_base_offer(&calm, false).is_none(), "no recovery, no floor round: nothing offered");
        assert_eq!(authority::floor_base_offer(&calm, true).map(|o| o.content_hash()), Some(w.cp1.content_hash()));
        let mut m = member_of(&w, MEMBER, MEMBER_PHONE, false);
        hears_of_recovery(&mut m);
        assert_ne!(m.base.as_ref().map(|b| b.hash), Some(w.cp1.content_hash()), "precondition: stepped back");
        for round in [false, true] {
            assert_eq!(authority::floor_base_offer(&m, round).map(|o| o.content_hash()), Some(w.cp1.content_hash()), "the pre-trigger base (round {round})");
        }
    }

    fn base_of(s: &ServerState) -> Option<[u8; 32]> {
        s.base.as_ref().map(|b| b.hash)
    }

    fn named_by_marks(s: &ServerState) -> Vec<String> {
        marks_of(s).iter().filter_map(|o| if let P::FloorMark { cp } = &o.payload { Some(cp.clone()) } else { None }).collect()
    }

    /// H4: the trigger keeps judging under the previous view until the round ends, and a
    /// member back from away marks the newest base an answer carried, not its stale one.
    #[test]
    fn a_floor_mark_waits_for_the_round_and_names_the_newest_base() {
        let w = world();
        let (before, _) = owner_rosters();
        let cp1 = w.cp1.content_hash();
        let stale_log: Vec<CrdtOp> = w
            .log
            .iter()
            .filter(|o| o.content_hash() != cp1 && !matches!(&o.payload, P::MemberAdded { peer_id, .. } if *peer_id == keys(LATE).1))
            .cloned()
            .collect();
        let mut m = replica(&w.owner.server_id, MEMBER, MEMBER_PHONE, true);
        m.authority = view(&before);
        m.ingest_remote(&stale_log);
        assert_eq!(base_of(&m), Some(w.cp0.content_hash()), "precondition: the stale member stands on cp0");
        hears_of_recovery_in_round(&mut m);
        assert!(m.in_recovery() && m.floor_round_open(), "the trigger opens the round");
        assert!(marks_of(&m).is_empty(), "no mark before the round ends");
        assert_eq!(base_of(&m), Some(w.cp0.content_hash()), "judged under the previous view meanwhile");
        let _ = m.rebuild_now();
        assert_eq!(base_of(&m), Some(w.cp0.content_hash()), "a rebuild during the round keeps the previous view");
        m.end_floor_round(std::slice::from_ref(&w.cp1)).expect("the round ends");
        assert!(!m.floor_round_open());
        assert_eq!(named_by_marks(&m), vec![hex::encode(cp1)], "the newest base an answer carried");
        assert_eq!(m.recovery.as_ref().and_then(|r| r.floor_b.as_ref()).map(|b| b.content_hash()), Some(cp1), "B recorded in floor_b");
        assert_eq!(m.recovery.as_ref().and_then(|r| r.base.clone()), Some(hex::encode(w.cp0.content_hash())), "the pre-trigger base never moves");
        assert!(m.floor_holds() && base_of(&m) == Some(cp1), "our own counted mark holds the floor on B");
        let back = Recovery::from_json(&m.recovery.as_ref().and_then(|r| r.to_json()).unwrap()).unwrap();
        assert_eq!(back.floor_b.map(|b| b.content_hash()), Some(cp1), "floor_b survives a restart");
        assert!(back.round.is_none(), "a round never survives a restart");
    }

    /// 8.8 class 3: the liveness reads hold us and KEEP during a step back, SEAT places a
    /// co-member, a shell still asks but is never answered, and nothing outlives the end.
    #[test]
    fn the_liveness_reads_hold_keep_during_a_recovery_and_a_shell_only_asks() {
        let w = world();
        let mut m = member_of(&w, MEMBER, MEMBER_PHONE, false);
        hears_of_recovery(&mut m);
        assert!(!m.is_member(&keys(MEMBER).1) && !m.is_member(&keys(MOD).1), "precondition: stepped back");
        assert!(m.held_as_member(&keys(MEMBER).1), "we still ask and announce");
        assert!(m.keeps_peer(&keys(MOD).1) && !m.keeps_peer(&keys(STRANGER).1), "KEEP is heard and served, a stranger never");
        assert!(!m.seats_peer(&keys(MOD).1), "no leaf at the trigger: not placed");
        assert!(std::ptr::eq(m.liveness_state(&keys(MEMBER).1), &*m.recovery.as_ref().unwrap().pre), "channels judged in the pre-trigger state");
        let mut r = (**m.recovery.as_ref().unwrap()).clone();
        r.leaves = Some([(String::new(), [keys(MOD).1].into_iter().collect())].into_iter().collect());
        m.recovery = Some(Arc::new(r));
        assert!(m.seats_peer(&keys(MOD).1), "a leaf at the trigger places it");
        let mut shell = m.clone();
        let mut r = (**shell.recovery.as_ref().unwrap()).clone();
        r.shell = Some(keys(MOD).1);
        shell.recovery = Some(Arc::new(r));
        assert!(shell.held_as_member(&keys(MEMBER).1), "a shell keeps asking for the settling");
        let mut kicked = member_of(&w, MEMBER, MEMBER_PHONE, true);
        hears_of_recovery(&mut kicked);
        let mut moderator = member_of(&w, MOD, MOD_PHONE, true);
        hears_of_recovery(&mut moderator);
        let kick = moderator.author_checked(P::MemberRemoved { peer_id: keys(MEMBER).1, seen: None }).expect("a moderator kicks");
        kicked.ingest_remote(&[kick]);
        assert!(kicked.floor_holds() && !kicked.keeps_peer(&keys(MEMBER).1), "kicked after the trigger on the floor: never served");
        let mut done = m.clone();
        done.recovery = None;
        assert!(!done.held_as_member(&keys(MEMBER).1) && !done.keeps_peer(&keys(MOD).1), "outside a recovery the fold alone decides");
        assert!(!kicked.held_as_member(&keys(MEMBER).1), "precondition: neither the fold nor the hold keeps a member kicked after the trigger");
        let mut r = (**kicked.recovery.as_ref().unwrap()).clone();
        r.shell = Some(keys(MOD).1);
        kicked.recovery = Some(Arc::new(r));
        assert!(kicked.held_as_member(&keys(MEMBER).1), "only the shell keeps it asking");
    }

    /// A view read again from the source inside a floor round keeps the round's judgment
    /// of the owner: its dropped writers still count until the round ends.
    #[test]
    fn a_view_refresh_inside_a_floor_round_keeps_the_owners_dropped_writers_counted() {
        let w = world();
        let (before, after) = owner_rosters();
        let mut m = replica(&w.owner.server_id, MEMBER, MEMBER_PHONE, true);
        m.authority = view(&before);
        m.ingest_remote(&w.log);
        hears_of_recovery_in_round(&mut m);
        assert!(m.floor_round_open(), "precondition: the trigger opens a round");
        let source = view(&after);
        m.set_view_source(super::super::verdict::ViewSource(Arc::new(move |_: &ServerState, x: &str| source.entry(x).cloned())));
        m.refresh_view();
        assert!(m.authority.counts(&keys(OWNER).1, &keys(PHONE).1), "the round still counts the dropped phone after a refresh");
        assert!(m.close_round());
        assert!(!m.authority.counts(&keys(OWNER).1, &keys(PHONE).1), "and the new view judges once the round ends");
    }

    /// RC32-8: a pre-trigger member the server group did not seat ranks after every seated
    /// one, however high its pre-trigger role.
    #[test]
    fn an_unseated_pre_trigger_moderator_ranks_after_every_seated_member() {
        let w = world();
        let mut m = member_of(&w, MEMBER, MEMBER_PHONE, false);
        hears_of_recovery(&mut m);
        assert!(m.in_recovery() && !m.floor_holds(), "precondition: a step back with no floor");
        let mut r = (**m.recovery.as_ref().unwrap()).clone();
        r.leaves = Some([(String::new(), [keys(MEMBER).1, keys(LATE).1].into_iter().collect())].into_iter().collect());
        m.recovery = Some(Arc::new(r));
        assert_ne!(m.recovery_hold(None, &keys(MOD).1), Hold::Seat, "precondition: no leaf seats the moderator");
        let ranked = crate::node::standing::rank_masters(&m, [keys(MOD).1, keys(MEMBER).1, keys(LATE).1]);
        assert_eq!(ranked.last(), Some(&keys(MOD).1), "the unseated moderator ranks last");
    }

    /// Item 4: a counted mark naming a checkpoint rules 1 to 3 make eligible is no floor
    /// mark, so it never ends a floor that lies on another line.
    #[test]
    fn a_counted_mark_naming_an_eligible_checkpoint_never_kills_the_floor() {
        let w = world();
        let (before, _) = owner_rosters();
        // The laptop, counted after the recovery, writes E on cp1 first; the phone's cp2,
        // its sibling, comes later and so ranks above it in the base order.
        let mut laptop = replica(&w.owner.server_id, OWNER, LAPTOP, true);
        laptop.authority = view(&before);
        laptop.ingest_remote(&w.log);
        laptop.author_checked(P::ServerRenamed { new_name: "laptop".into() }).unwrap();
        let e = checkpoint(&mut laptop);
        assert_eq!(laptop.base.as_ref().and_then(|b| b.parent), Some(w.cp1.content_hash()), "precondition: E is a child of cp1");
        std::thread::sleep(std::time::Duration::from_millis(3));
        let mut thief = w.owner.clone();
        thief.author_checked(P::ServerRenamed { new_name: "thief".into() }).unwrap();
        let cp2 = checkpoint(&mut thief);
        let mut m = replica(&w.owner.server_id, MEMBER, MEMBER_PHONE, true);
        m.authority = view(&before);
        m.ingest_remote(&w.log);
        m.ingest_remote(std::slice::from_ref(&cp2));
        assert_eq!(base_of(&m), Some(cp2.content_hash()), "precondition: the phone's newest checkpoint is the base");
        hears_of_recovery(&mut m);
        assert!(m.floor_holds() && base_of(&m) == Some(cp2.content_hash()), "precondition: our mark floors cp2");
        let marks_e = replica(&w.owner.server_id, MOD, MOD_PHONE, true).create_op(P::FloorMark { cp: hex::encode(e.content_hash()) });
        m.ingest_remote(&[e.clone(), marks_e]);
        assert!(m.base_by_hash(&hex::encode(e.content_hash())).is_some() && named_by_marks(&m).len() == 2, "precondition: E and its mark are held");
        assert!(m.floor_holds(), "the eligible checkpoint's mark does not count toward the floor");
        assert_eq!(base_of(&m), Some(cp2.content_hash()), "the floor keeps cp2 above E");
    }

    /// RC32-8, R33-1: standing during a recovery with no floor reads the pre-trigger
    /// state over the server group's SEAT; a master outside it ranks after every seated one.
    #[test]
    fn standing_during_a_recovery_reads_the_pre_trigger_state() {
        let w = world();
        let mut m = member_of(&w, MEMBER, MEMBER_PHONE, false);
        hears_of_recovery(&mut m);
        assert!(m.in_recovery() && !m.floor_holds(), "precondition: a step back with no floor");
        let mut r = (**m.recovery.as_ref().unwrap()).clone();
        r.leaves = Some([(String::new(), [keys(MOD).1, keys(MEMBER).1, keys(LATE).1].into_iter().collect())].into_iter().collect());
        m.recovery = Some(Arc::new(r));
        let all = [keys(STRANGER).1, keys(LATE).1, keys(MEMBER).1, keys(MOD).1];
        let ranked = crate::node::standing::rank_masters(&m, all.iter().cloned());
        assert_eq!(ranked[0], keys(MOD).1, "the pre-trigger moderator leads, as the pre-trigger state ranks it");
        assert_eq!(ranked.last(), Some(&keys(STRANGER).1), "an unseated master ranks after every seated one, whatever its id");
        let pre_order = crate::node::standing::rank_masters(&m.recovery.as_ref().unwrap().pre, [keys(LATE).1, keys(MEMBER).1]);
        assert_eq!(ranked[1..3].to_vec(), pre_order, "seated members keep their pre-trigger order");
    }

    /// RC32-2: a checkpoint the dropped writer signs after the trigger counts under the
    /// previous view, but is never B unless an answerer carried it.
    #[test]
    fn a_checkpoint_the_dropped_device_writes_after_notice_is_never_the_floor() {
        let w = world();
        let mut thief = w.owner.clone();
        thief.author_checked(P::ServerRenamed { new_name: "thief".into() }).unwrap();
        let x_t = checkpoint(&mut thief);
        let mut m = member_of(&w, MEMBER, MEMBER_PHONE, true);
        hears_of_recovery_in_round(&mut m);
        m.ingest_remote(std::slice::from_ref(&x_t));
        assert_eq!(base_of(&m), Some(x_t.content_hash()), "precondition: the previous view counts the phone during the round");
        let mut carried = m.clone();
        m.end_floor_round(&[]).expect("the round ends");
        assert_eq!(named_by_marks(&m), vec![hex::encode(w.cp1.content_hash())], "the thief's post-notice checkpoint is never B");
        assert_ne!(base_of(&m), Some(x_t.content_hash()));
        carried.end_floor_round(std::slice::from_ref(&x_t)).expect("the round ends");
        assert_eq!(named_by_marks(&carried), vec![hex::encode(x_t.content_hash())], "an answer that carried it makes it a candidate");
    }

    fn rules_seat(s: &ServerState, master: &str) -> crate::crypto::Verdict {
        crate::node::mls_authority::GroupRules::Server { state: s, channel: None }.membership(master, "")
    }

    #[test]
    fn a_floor_mark_from_a_non_member_of_its_checkpoint_or_without_its_pin_is_not_stored() {
        let w = world();
        let mut m = member_of(&w, MEMBER, MEMBER_PHONE, false);
        hears_of_recovery(&mut m);
        let stranger = replica(&w.owner.server_id, STRANGER, STRANGER, true).create_op(P::FloorMark { cp: hex::encode(w.cp1.content_hash()) });
        let unpinned = replica(&w.owner.server_id, MOD, MOD_PHONE, true).create_op(P::FloorMark { cp: hex::encode([7u8; 32]) });
        let not_in_it = replica(&w.owner.server_id, LATE, LATE_PHONE, true).create_op(P::FloorMark { cp: hex::encode(w.cp0.content_hash()) });
        let by_owner = replica(&w.owner.server_id, OWNER, LAPTOP, true).create_op(P::FloorMark { cp: hex::encode(w.cp1.content_hash()) });
        m.ingest_remote(&[stranger, unpinned, not_in_it, by_owner]);
        assert!(marks_of(&m).is_empty(), "neither mark is stored");
        assert!(!m.floor_holds());
    }

    #[test]
    fn a_counted_members_mark_holds_the_floor_and_a_removed_sibling_cannot_displace_it() {
        let w = world();
        let mut m = member_of(&w, MEMBER, MEMBER_PHONE, false);
        hears_of_recovery(&mut m);
        let honest = replica(&w.owner.server_id, MOD, MOD_PHONE, true).create_op(P::FloorMark { cp: hex::encode(w.cp1.content_hash()) });
        let older = replica(&w.owner.server_id, MOD, MEMBER_OLD, true).create_op(P::FloorMark { cp: hex::encode(w.cp0.content_hash()) });
        m.ingest_remote(std::slice::from_ref(&older));
        assert!(!m.floor_holds(), "an uncounted mark alone makes no floor");
        m.ingest_remote(&[older, honest]);
        assert!(m.floor_holds(), "MOD's counted mark makes the floor");
        assert_eq!(m.base.as_ref().map(|b| b.hash), Some(w.cp1.content_hash()), "the counted mark decides, never the uncounted older one");
    }

    #[test]
    fn a_counted_checkpoint_on_the_floor_ends_the_recovery_and_drops_the_marks() {
        let w = world();
        let mut m = member_of(&w, MEMBER, MEMBER_PHONE, true);
        hears_of_recovery(&mut m);
        assert!(m.floor_holds());
        let mut laptop = member_of(&w, OWNER, LAPTOP, true);
        hears_of_recovery(&mut laptop);
        laptop.ingest_remote(&marks_of(&m).into_iter().cloned().collect::<Vec<_>>());
        assert!(laptop.floor_holds(), "precondition: the owner's new device folds on the floor");
        assert!(!laptop.in_recovery(), "an owner device is never in recovery: it settles");
        let next = checkpoint(&mut laptop);
        m.ingest_remote(std::slice::from_ref(&next));
        assert_eq!(m.base.as_ref().map(|b| b.hash), Some(next.content_hash()));
        assert!(!m.in_recovery(), "a base the view counts ends the recovery");
        assert!(marks_of(&m).is_empty() && !m.floor_holds(), "every mark drops once a counted checkpoint descends from it");
    }

    #[test]
    fn a_kick_during_a_recovery_leaves_a_shell_unless_the_owner_or_we_did_it() {
        let w = world();
        let mut m = member_of(&w, MEMBER, MEMBER_PHONE, true);
        hears_of_recovery(&mut m);
        let mut moderator = member_of(&w, MOD, MOD_PHONE, true);
        hears_of_recovery(&mut moderator);
        let kick = moderator.author_checked(P::MemberRemoved { peer_id: keys(MEMBER).1, seen: None }).expect("a moderator of the floor's state kicks");
        let mut shell = m.clone();
        shell.ingest_remote(&[kick]);
        assert!(!shell.is_member(&keys(MEMBER).1), "precondition: the kick folds");
        assert_eq!(shell.recovery_hold(None, &keys(MEMBER).1), Hold::Out, "a kick first held after the trigger takes us out");
        assert_eq!(shell.recovery_teardown(&keys(MEMBER).1), Teardown::Shell(keys(MOD).1));
        let (_, after) = owner_rosters();
        let mut laptop = replica(&w.owner.server_id, OWNER, LAPTOP, true);
        laptop.authority = view(&after);
        laptop.ingest_remote(&w.log);
        laptop.ingest_remote(&marks_of(&m).into_iter().cloned().collect::<Vec<_>>());
        let by_owner = laptop.author_checked(P::MemberRemoved { peer_id: keys(MEMBER).1, seen: None }).expect("the owner's counted device kicks");
        let mut gone = m.clone();
        gone.ingest_remote(&[by_owner]);
        assert_eq!(gone.recovery_teardown(&keys(MEMBER).1), Teardown::Go, "the owner's counted device tears down as today");
        let leave = m.author_checked(P::MemberRemoved { peer_id: keys(MEMBER).1, seen: None }).expect("we may leave");
        let _ = leave;
        assert_eq!(m.recovery_teardown(&keys(MEMBER).1), Teardown::Go, "our own leave tears down as today");
    }

    #[test]
    fn a_mark_flood_never_pushes_out_a_members_counted_mark() {
        let w = world();
        let mut m = member_of(&w, MEMBER, MEMBER_PHONE, false);
        hears_of_recovery(&mut m);
        let mut ground = replica(&w.owner.server_id, MOD, MEMBER_OLD, true);
        let flood: Vec<CrdtOp> = (0..6).map(|_| ground.create_op(P::FloorMark { cp: hex::encode(w.cp0.content_hash()) })).collect();
        let honest = replica(&w.owner.server_id, MOD, MOD_PHONE, true).create_op(P::FloorMark { cp: hex::encode(w.cp1.content_hash()) });
        let mut all = flood;
        all.push(honest);
        m.ingest_remote(&all);
        assert!(m.floor_holds(), "the counted mark ranks first among the author's four");
        assert_eq!(m.base.as_ref().map(|b| b.hash), Some(w.cp1.content_hash()));
        assert!(marks_of(&m).len() <= super::super::fold::MAX_FLOOR_MARKS_PER_AUTHOR, "at most four per author");
    }

    #[test]
    fn a_puppet_mark_on_a_fork_falls_back_to_the_step_back() {
        let w = world();
        let mut m = member_of(&w, MEMBER, MEMBER_PHONE, false);
        hears_of_recovery(&mut m);
        let honest = replica(&w.owner.server_id, MOD, MOD_PHONE, true).create_op(P::FloorMark { cp: hex::encode(w.cp1.content_hash()) });
        m.ingest_remote(&[w.fork.clone(), honest]);
        assert!(m.floor_holds(), "precondition: one counted mark makes the floor");
        let puppet = replica(&w.owner.server_id, LATE, LATE_PHONE, true).create_op(P::FloorMark { cp: hex::encode(w.fork.content_hash()) });
        m.ingest_remote(&[puppet]);
        assert!(!m.floor_holds(), "two counted marks off one line make no floor");
        assert_ne!(m.base.as_ref().map(|b| b.hash), Some(w.fork.content_hash()), "the puppet's checkpoint is never adopted");
        assert!(m.in_recovery() && m.recovery_hold(None, &keys(MOD).1) >= Hold::Keep, "the step back runs under the hold");
    }

    /// 8.8 class 3 (voice): through a step back a held co-member keeps its voice seat
    /// (KEEP) in a channel only the pre-trigger state has, and only SEAT may join anew.
    #[test]
    fn a_held_members_voice_seat_stays_and_only_seat_joins() {
        use crate::node::voice_handler::{unqualified_seats, voice_join_refusal};
        let w = world();
        let mut m = member_of(&w, MEMBER, MEMBER_PHONE, false);
        hears_of_recovery(&mut m);
        assert!(!m.is_member(&keys(MOD).1) && !m.floor_holds(), "precondition: stepped back with no floor");
        let mut owner = w.owner.clone();
        owner.author_checked(P::ChannelAdded { channel_id: "vc".into(), name: "Voice".into(), category: None, channel_type: "voice".into() }).unwrap();
        let mut r = (**m.recovery.as_ref().unwrap()).clone();
        let mut pre = (*r.pre).clone();
        pre.channels.insert("vc".into(), owner.channels["vc"].clone());
        r.pre = Arc::new(pre);
        m.recovery = Some(Arc::new(r));
        let states: std::collections::HashMap<String, ServerState> = [(m.server_id.clone(), m.clone())].into_iter().collect();
        let seats: std::collections::HashMap<String, std::collections::HashSet<String>> =
            [(format!("{}:vc", m.server_id), [keys(MOD).1, keys(STRANGER).1].into_iter().collect())].into_iter().collect();
        let gone: Vec<String> = unqualified_seats(&states, &seats, &keys(MEMBER).1, &keys(MEMBER_PHONE).1).into_iter().map(|g| g.2).collect();
        assert_eq!(gone, vec![keys(STRANGER).1], "KEEP's seat stays, a stranger's goes");
        assert!(voice_join_refusal(Some(&m), &keys(MOD).1, "vc").is_some(), "no leaf at the trigger: no new seat");
        let mut r = (**m.recovery.as_ref().unwrap()).clone();
        r.leaves = Some([(String::new(), [keys(MOD).1].into_iter().collect())].into_iter().collect());
        m.recovery = Some(Arc::new(r));
        assert_eq!(voice_join_refusal(Some(&m), &keys(MOD).1, "vc"), None, "SEAT joins, judged in the pre-trigger state");
        m.recovery = None;
        assert!(voice_join_refusal(Some(&m), &keys(MOD).1, "vc").is_some(), "outside a recovery the fold alone decides");
    }

    /// The order marks arrive in never decides the floor: a member whose own lowest mark
    /// names a fork, then a co-member's honest mark naming cp1, holds no floor.
    #[test]
    fn a_later_honest_mark_off_the_line_still_ends_a_floor_on_a_fork() {
        let w = world();
        let mut m = member_of(&w, MEMBER, MEMBER_PHONE, true);
        hears_of_recovery(&mut m);
        assert!(m.floor_holds(), "precondition: our own mark makes the floor on cp1");
        let (fork_c, cp1_c) = (m.content_of(&w.fork), m.content_of(&w.cp1));
        let ours = replica(&w.owner.server_id, MEMBER, MEMBER_PHONE, true).create_op(P::FloorMark { cp: hex::encode(fork_c) });
        m.ingest_remote(&[w.fork.clone(), ours]);
        if fork_c < cp1_c {
            assert_eq!(m.base.as_ref().map(|b| b.hash), Some(w.fork.content_hash()), "precondition: our lowest mark names the fork");
        }
        let honest = replica(&w.owner.server_id, MOD, MOD_PHONE, true).create_op(P::FloorMark { cp: hex::encode(cp1_c) });
        m.ingest_remote(&[honest]);
        assert_eq!(marks_of(&m).iter().filter(|o| o.author == keys(MOD).1).count(), 1, "the co-member's mark is stored");
        assert_eq!(m.floor_holds(), fork_c > cp1_c, "two chosen marks off one line make no floor");
    }

    /// R34-2: the settler hands its door to every member the settled state counts that
    /// the pre-settling base and fold did not both count, never to itself.
    #[test]
    fn settled_newcomers_are_the_members_the_step_back_lost() {
        use crate::node::floor::{counted_members, settled_newcomers};
        let w = world();
        let mut m = member_of(&w, MOD, MOD_PHONE, false);
        let before = counted_members(&m);
        assert!(before.contains(&keys(MEMBER).1), "precondition: cp1 and the fold count the member");
        assert!(settled_newcomers(&before, &w.owner, &keys(OWNER).1).is_empty(), "nobody the pre-settling state counted");
        hears_of_recovery(&mut m);
        let stepped = counted_members(&m);
        assert!(!stepped.contains(&keys(MEMBER).1), "precondition: the step back lost the member");
        let back = settled_newcomers(&stepped, &w.owner, &keys(OWNER).1);
        assert!(back.contains(&keys(MEMBER).1) && back.contains(&keys(LATE).1), "the members the step back lost");
        assert!(!settled_newcomers(&stepped, &w.owner, &keys(MEMBER).1).contains(&keys(MEMBER).1), "never ourselves");
        let mut on_cp0 = w.owner.clone();
        on_cp0.base = w.owner.base_by_hash(&hex::encode(w.cp0.content_hash())).map(Box::new);
        assert!(on_cp0.base.is_some() && on_cp0.is_member(&keys(LATE).1), "precondition: LATE in the fold, admitted after cp0");
        assert!(!counted_members(&on_cp0).contains(&keys(LATE).1), "a member the fold alone counts is not counted");
    }
    /// REVIEW (part A): the author cap (`MAX_FLOOR_AUTHORS`) ranks authors by the
    /// generation their mark names, before the one-line test. Free identities the thief
    /// seats in fabricated low-generation checkpoints fill every slot, the honest member's
    /// mark falls out, and the fabricated line becomes the floor (8.8 "never its own
    /// version"). The second, larger checkpoint only fills author slots (the test-build pin
    /// budget is 64 KiB; production's 64 MiB keeps one checkpoint naming all 512).
    #[test]
    fn review_a_puppet_flood_on_a_fabricated_low_checkpoint_never_becomes_the_floor() {
        use super::super::testkeys::keys_n;
        let w = world();
        let sid = w.owner.server_id.clone();
        let (before, _) = owner_rosters();
        // An honest server past generation 1: the owner's phone writes cp2 on cp1.
        let mut owner = w.owner.clone();
        owner.author_checked(P::ServerRenamed { new_name: "two".into() }).unwrap();
        let cp2 = checkpoint(&mut owner);
        let mut m = replica(&sid, MEMBER, MEMBER_PHONE, true);
        m.authority = view(&before);
        m.ingest_remote(&w.log);
        m.ingest_remote(&owner.op_log.iter().chain(owner.stored.iter().map(|(o, _)| o)).cloned().collect::<Vec<_>>());
        assert_eq!(base_of(&m).map(|_| m.base.as_ref().unwrap().generation), Some(2), "precondition: the member stands on cp2");
        hears_of_recovery(&mut m);
        assert!(m.floor_holds() && base_of(&m) == Some(cp2.content_hash()), "precondition: the honest floor is cp2");

        // The thief holds the owner master key and the dropped phone: a fabricated line
        // F0 (generation 0, a few puppets) <- F1 (generation 1, the rest).
        let founding = w.log.iter().find(|o| matches!(o.payload, P::ServerCreated { .. })).cloned().unwrap();
        let mut fab = replica(&sid, OWNER, PHONE, true);
        fab.ingest_remote(std::slice::from_ref(&founding));
        let n = super::super::fold::MAX_FLOOR_AUTHORS as u32;
        let small = 8u32;
        let seat = |fab: &mut ServerState, i: u32| {
            let ask = super::super::operations::JoinAsk::sign(&sid, 1, &keys_n(i).0);
            fab.author_checked(P::MemberAdded { peer_id: keys_n(i).1, display_name: "p".into(), follow: None, ask: Some(ask) })
                .expect("the thief seats a puppet");
        };
        for i in 0..small {
            seat(&mut fab, i);
        }
        let f0 = checkpoint(&mut fab);
        for i in small..n {
            seat(&mut fab, i);
        }
        let f1 = checkpoint(&mut fab);
        assert_eq!(fab.base.as_ref().map(|b| b.generation), Some(1), "precondition: F1 is a child of F0");

        let (_, after) = owner_rosters();
        let mut v = (*view(&after)).clone();
        let mut ops = vec![f0.clone(), f1.clone()];
        for i in 0..n {
            let (pkp, pid, ppk) = keys_n(i);
            let (dkp, did, _) = keys_n(100_000 + i);
            let r = Roster::genesis(&pkp, &keys_n(200_000 + i).0, &dkp, 1_000);
            v.insert(pid.clone(), authority::judge(&pid, &KeyRule::FirstHeld, &[&r]));
            let mut p = ServerState::skeleton(sid.clone());
            p.set_hlc(super::super::hlc::Hlc::for_device(pid, &did));
            p.set_signer(pkp, ppk);
            p.set_device_signer(dkp);
            let named = if i < small { &f0 } else { &f1 };
            ops.push(p.create_op(P::FloorMark { cp: hex::encode(named.content_hash()) }));
        }
        m.authority = Arc::new(v);
        m.ingest_remote(&ops);
        let honest_kept = marks_of(&m).iter().any(|o| o.author == keys(MEMBER).1);
        let base_is_f0 = base_of(&m) == Some(f0.content_hash());
        assert!(
            honest_kept && !base_is_f0,
            "honest mark kept: {honest_kept}; the thief's fabricated F0 is the floor-held base: {base_is_f0} (floor holds: {})",
            m.floor_holds()
        );
    }

    /// Puppet `i` of a flood: master `keys_n(i)`, device `keys_n(100_000 + i)`.
    fn puppet(i: u32) -> (crate::identity::native_identity::NativeKeypair, String) {
        use super::super::testkeys::keys_n;
        (keys_n(i).0, keys_n(i).1)
    }

    /// Seat puppet `i` in `s` (a replica holding the owner key).
    fn seat_puppet(s: &mut ServerState, i: u32) {
        let ask = super::super::operations::JoinAsk::sign(&s.server_id.clone(), 1, &puppet(i).0);
        s.author_checked(P::MemberAdded { peer_id: puppet(i).1, display_name: "p".into(), follow: None, ask: Some(ask) })
            .expect("the thief seats a puppet");
    }

    /// `count` puppet indexes whose master ids sort below every id of `below`: with
    /// nothing else to rank them, they would win every author slot.
    fn puppets_below(below: &[String], count: usize) -> Vec<u32> {
        (0u32..).filter(|i| below.iter().all(|b| puppet(*i).1 < *b)).take(count).collect()
    }

    /// Puppet `i`'s view entry (counting its device) and its mark naming `cp`, signed by
    /// its counted device or, with `counted` false, by a device its roster lacks.
    fn puppet_mark(sid: &str, i: u32, cp: &CrdtOp, counted: bool, v: &mut AuthorityView) -> CrdtOp {
        use super::super::testkeys::keys_n;
        let (pkp, pid, ppk) = keys_n(i);
        let (dkp, did, _) = keys_n(100_000 + i);
        let r = Roster::genesis(&pkp, &keys_n(200_000 + i).0, &dkp, 1_000);
        v.insert(pid.clone(), authority::judge(&pid, &KeyRule::FirstHeld, &[&r]));
        let mut p = ServerState::skeleton(sid.to_string());
        let signer = if counted { dkp } else { keys_n(300_000 + i).0 };
        let device = if counted { did } else { keys_n(300_000 + i).1 };
        p.set_hlc(super::super::hlc::Hlc::for_device(pid, &device));
        p.set_signer(pkp, ppk);
        p.set_device_signer(signer);
        p.create_op(P::FloorMark { cp: hex::encode(cp.content_hash()) })
    }

    /// The honest server past generation 1 (the phone's cp2 on cp1, `seated` puppets
    /// admitted before notice), and MEMBER's replica holding it, in recovery with its
    /// own mark on cp2.
    fn member_on_cp2(seated: &[u32]) -> (World, ServerState, CrdtOp, ServerState) {
        let w = world();
        let (before, _) = owner_rosters();
        let mut owner = w.owner.clone();
        for i in seated {
            seat_puppet(&mut owner, *i);
        }
        owner.author_checked(P::ServerRenamed { new_name: "two".into() }).unwrap();
        let cp2 = checkpoint(&mut owner);
        let mut m = replica(&w.owner.server_id, MEMBER, MEMBER_PHONE, true);
        m.authority = view(&before);
        m.ingest_remote(&owner.op_log.iter().chain(owner.stored.iter().map(|(o, _)| o)).cloned().collect::<Vec<_>>());
        hears_of_recovery(&mut m);
        assert!(m.floor_holds() && base_of(&m) == Some(cp2.content_hash()), "precondition: the honest floor is cp2");
        (w, owner, cp2, m)
    }

    /// The thief's fabricated generation 0 (off every honest line), seating `seated`.
    fn fabricated_root(w: &World, seated: &[u32]) -> (ServerState, CrdtOp) {
        let founding = w.log.iter().find(|o| matches!(o.payload, P::ServerCreated { .. })).cloned().unwrap();
        let mut fab = replica(&w.owner.server_id, OWNER, PHONE, true);
        fab.ingest_remote(std::slice::from_ref(&founding));
        for i in seated {
            seat_puppet(&mut fab, *i);
        }
        let f0 = checkpoint(&mut fab);
        (fab, f0)
    }

    /// 8.8 item 3: the author bound keeps a witness of the evidence first. Puppets the
    /// thief seated BEFORE notice are members this replica knows; named in a fabricated
    /// checkpoint, their counted marks outnumber the slots and their ids sort first, yet
    /// the one honest mark that ends that floor stays, so a rebuild from what is kept
    /// decides as the full set did.
    #[test]
    fn known_puppets_never_push_out_the_honest_mark_that_ends_a_fabricated_floor() {
        let n = super::super::fold::MAX_FLOOR_AUTHORS + 8;
        let puppets = puppets_below(&[keys(MEMBER).1], n);
        let (w, _, _cp2, mut m) = member_on_cp2(&puppets);
        assert!(m.floor_author_known(&puppet(puppets[0]).1), "precondition: the puppets are members this replica knows");
        let (_, f0) = fabricated_root(&w, &puppets);
        let (_, after) = owner_rosters();
        let mut v = (*view(&after)).clone();
        let mut ops = vec![f0.clone()];
        ops.extend(puppets.iter().map(|i| puppet_mark(&w.owner.server_id, *i, &f0, true, &mut v)));
        m.authority = Arc::new(v);
        m.ingest_remote(&ops);
        let judged = |m: &ServerState| (marks_of(m).iter().any(|o| o.author == keys(MEMBER).1), base_of(m) == Some(f0.content_hash()));
        assert_eq!(judged(&m), (true, false), "(honest mark kept, the fabricated F0 is the base)");
        assert!(marks_of(&m).iter().map(|o| &o.author).collect::<std::collections::HashSet<_>>().len() <= super::super::fold::MAX_FLOOR_AUTHORS);
        let _ = m.rebuild_now();
        assert_eq!(judged(&m), (true, false), "a rebuild from the kept marks decides the same");
    }

    /// 8.8 item 3: past the evidence, the authors this replica knows rank before free
    /// identities, never by the generation a mark names: unknown puppets marking a
    /// descendant of the floor never push out an honest co-member's mark (the next one to
    /// hold the floor should the first lose its count).
    #[test]
    fn free_identities_never_push_out_a_known_members_mark() {
        let (w, owner, cp2, mut m) = member_on_cp2(&[]);
        let n = super::super::fold::MAX_FLOOR_AUTHORS + 8;
        let puppets = puppets_below(&[keys(MEMBER).1, keys(MOD).1], n);
        // The thief's child of cp2 names the puppets: on the floor's line.
        let mut thief = owner;
        for i in &puppets {
            seat_puppet(&mut thief, *i);
        }
        let f3 = checkpoint(&mut thief);
        let (_, after) = owner_rosters();
        let mut v = (*view(&after)).clone();
        let mut ops = vec![f3.clone(), replica(&w.owner.server_id, MOD, MOD_PHONE, true).create_op(P::FloorMark { cp: hex::encode(cp2.content_hash()) })];
        ops.extend(puppets.iter().map(|i| puppet_mark(&w.owner.server_id, *i, &f3, true, &mut v)));
        m.authority = Arc::new(v);
        m.ingest_remote(&ops);
        let honest: Vec<&String> = marks_of(&m).iter().map(|o| &o.author).filter(|a| **a == keys(MEMBER).1 || **a == keys(MOD).1).collect();
        assert_eq!(honest.len(), 2, "both honest members' marks stay");
        assert!(m.floor_holds() && base_of(&m) == Some(cp2.content_hash()), "the floor stays cp2");
    }

    /// 8.8 item 7: the checkpoint bound keeps the evidence first. The thief fills it with
    /// low-generation siblings named by uncounted marks; the honest checkpoint and the
    /// fabricated root the counted puppets name stay, so the honest mark keeps ending the
    /// fabricated floor after a rebuild.
    #[test]
    fn low_generation_siblings_never_evict_the_honest_checkpoint_that_ends_a_fabricated_floor() {
        let (w, _, _cp2, mut m) = member_on_cp2(&[]);
        let n = super::super::fold::MAX_FLOOR_CPS as u32 + 2;
        let puppets: Vec<u32> = (0..n).collect();
        let (fab, f0) = fabricated_root(&w, &puppets);
        // Siblings on F0: generation 1, off one line with each other, below cp2.
        let siblings: Vec<CrdtOp> = (0..n)
            .map(|i| {
                let mut s = fab.clone();
                s.author_checked(P::ServerRenamed { new_name: format!("g{i}") }).unwrap();
                checkpoint(&mut s)
            })
            .collect();
        let (_, after) = owner_rosters();
        let mut v = (*view(&after)).clone();
        let mut ops = vec![f0.clone()];
        ops.extend(siblings.iter().cloned());
        for (i, g) in puppets.iter().zip(&siblings) {
            ops.push(puppet_mark(&w.owner.server_id, *i, &f0, true, &mut v));
            ops.push(puppet_mark(&w.owner.server_id, *i, g, false, &mut v));
        }
        m.authority = Arc::new(v);
        m.ingest_remote(&ops);
        let judged = |m: &ServerState| (marks_of(m).iter().any(|o| o.author == keys(MEMBER).1), base_of(m) == Some(f0.content_hash()));
        assert_eq!(judged(&m), (true, false), "(honest mark kept, the fabricated F0 is the base)");
        let _ = m.rebuild_now();
        assert_eq!(judged(&m), (true, false), "a rebuild from the kept marks and pins decides the same");
    }

    /// A rename the owner's phone signs at `cp`'s clock (its lane, so the proof verifies),
    /// the first of a few for which `pick` holds. Wide enough that a `cp` whose content id
    /// sorts near the top still finds one (64 tries failed about one run in 65).
    fn variant_at(cp: &CrdtOp, pick: impl Fn(&CrdtOp) -> bool) -> CrdtOp {
        (0..4096)
            .map(|i| {
                let mut v = cp.clone();
                v.payload = P::ServerRenamed { new_name: format!("v{i}") };
                v.sign(&keys(OWNER).0, &keys(OWNER).2);
                v.sign_device(&keys(PHONE).0);
                v
            })
            .find(|v| pick(v))
            .expect("a variant")
    }

    /// HOL-SEC-225: B is the answered checkpoint itself, found by its own content id, even
    /// where this replica holds a variant at its key.
    #[test]
    fn a_floor_pick_matches_an_answered_checkpoint_by_its_own_content() {
        let w = world();
        let (before, _) = owner_rosters();
        let cp1 = w.cp1.content_hash();
        let variant = variant_at(&w.cp1, |v| v.content_hash() > cp1);
        assert_eq!(variant.proven_device(), Some(keys(PHONE).1.as_str()), "precondition: the phone's proof verifies");
        let stale_log: Vec<CrdtOp> = w
            .log
            .iter()
            .filter(|o| o.content_hash() != cp1 && !matches!(&o.payload, P::MemberAdded { peer_id, .. } if *peer_id == keys(LATE).1))
            .cloned()
            .chain(std::iter::once(variant.clone()))
            .collect();
        let mut m = replica(&w.owner.server_id, MEMBER, MEMBER_PHONE, true);
        m.authority = view(&before);
        m.ingest_remote(&stale_log);
        assert_eq!(base_of(&m), Some(w.cp0.content_hash()), "precondition: the stale member stands on cp0");
        assert_eq!(m.content_of(&w.cp1), variant.content_hash(), "precondition: the variant is held at cp1's key");
        hears_of_recovery_in_round(&mut m);
        assert!(m.floor_round_open(), "precondition: the trigger opens the round");
        m.end_floor_round(std::slice::from_ref(&w.cp1)).expect("the round ends");
        assert_eq!(named_by_marks(&m), vec![hex::encode(cp1)], "the mark names the answered cp1, not the step back nor the variant");
        assert_eq!(m.recovery.as_ref().and_then(|r| r.floor_b.as_ref()).map(|b| b.content_hash()), Some(cp1), "B recorded in floor_b");
    }

    /// HOL-SEC-225: a mark made after a restart names the recorded pre-trigger base by its
    /// own content id, never a variant now held at its key.
    #[test]
    fn a_floor_mark_after_restart_names_the_recorded_base_by_its_own_content() {
        let w = world();
        let cp1 = w.cp1.content_hash();
        let mut m = member_of(&w, MEMBER, MEMBER_PHONE, false);
        hears_of_recovery(&mut m);
        let recorded = m.recovery.as_ref().and_then(|r| r.base_op.as_ref()).map(|b| b.content_hash());
        assert!(marks_of(&m).is_empty() && recorded == Some(cp1), "precondition: unsigned, cp1 recorded, no mark");
        let at = |m: &ServerState| {
            let is = |o: &CrdtOp| o.content_hash() == cp1;
            (m.op_log.iter().any(is), m.stored.iter().any(|(o, _)| is(o)), m.held.iter().any(|(o, _)| is(o)))
        };
        assert_eq!(at(&m), (false, false, true), "precondition: the step back holds cp1 in RAM only");
        // A restart keeps the stored rows and the recovery row, never what was held in RAM.
        let rows: Vec<(CrdtOp, Option<u64>)> = m
            .op_log
            .iter()
            .map(|o| (o.clone(), None))
            .chain(m.stored.iter().map(|(o, k)| (o.clone(), if let RowKind::Parked(u) = k { Some(*u) } else { None })))
            .collect();
        let mut back = m.clone();
        back.restore_op_log(rows);
        assert_eq!(at(&back), (false, false, false), "precondition: the restart lost cp1");
        let variant = variant_at(&w.cp1, |v| v.content_hash() > cp1);
        back.ingest_remote(std::slice::from_ref(&variant));
        assert_eq!(back.content_of(&w.cp1), variant.content_hash(), "precondition: the variant is held at cp1's key");
        let (kp, _, pk) = keys(MEMBER);
        back.set_signer(kp, pk);
        back.set_device_signer(keys(MEMBER_PHONE).0);
        back.mark_after_restart().expect("the mark goes out");
        assert_eq!(named_by_marks(&back), vec![hex::encode(cp1)], "the recorded base, by its own content id");
    }

    // Part A (HOL-SEC-230, -231): the hold without a base.

    const MOD_LAPTOP: u8 = 16;

    /// The owner's phone founds and admits MEMBER, MOD (a moderator) and LATE, and MOD's
    /// phone bans STRANGER after admitting it: no checkpoint anywhere.
    fn baseless_world() -> (ServerState, Vec<CrdtOp>) {
        let (before, _) = owner_rosters();
        let (master, m_id, pk) = keys(OWNER);
        let (phone, phone_id, _) = keys(PHONE);
        let r_pub = before.r_pub.clone();
        let (mut owner, _) = ServerState::found_on("s0".into(), m_id, Founder { device_peer_id: &phone_id, device: Some(&phone), r_pub: Some(&r_pub) }, master, pk);
        owner.authority = view(&before);
        admit(&mut owner, MEMBER);
        admit(&mut owner, MOD);
        owner.author_checked(P::RoleChanged { peer_id: keys(MOD).1, role: MemberRole::Moderator, priority: 0 }).unwrap();
        admit(&mut owner, LATE);
        admit(&mut owner, STRANGER);
        let mut moderator = replica(&owner.server_id, MOD, MOD_PHONE, true);
        moderator.authority = view(&before);
        moderator.ingest_remote(&owner.op_log);
        moderator.author_checked(P::MemberBanned { peer_id: keys(STRANGER).1, seen: None }).expect("the moderator bans");
        owner.ingest_remote(&moderator.op_log);
        assert!(owner.is_banned(&keys(STRANGER).1) && owner.base.is_none(), "precondition: the ban folds, no checkpoint");
        let log = owner.op_log.iter().chain(owner.stored.iter().map(|(o, _)| o)).cloned().collect();
        (owner, log)
    }

    fn baseless_replica(log: &[CrdtOp], tag: u8, device: u8, signs: bool) -> ServerState {
        let (before, _) = owner_rosters();
        let sid = log.iter().find_map(|o| matches!(o.payload, P::ServerCreated { .. }).then(|| o.server_id.clone())).expect("the founding op");
        let mut s = replica(&sid, tag, device, signs);
        s.authority = view(&before);
        s.ingest_remote(log);
        s
    }

    /// The view after the owner's phrase dropped its phone, and with `mod_dropped` the
    /// moderator's phrase dropping MOD_PHONE for MOD_LAPTOP too.
    fn view_after(mod_dropped: bool) -> Arc<AuthorityView> {
        let (_, after) = owner_rosters();
        let mut v = (*view(&after)).clone();
        if mod_dropped {
            let mut r = Roster::genesis(&keys(MOD).0, &keys(MOD_RECOVERY).0, &keys(MOD_PHONE).0, 1_000);
            r.add_vouch(sign_vouch(&keys(MOD_PHONE).0, &keys(MOD).1, &r.base(), &keys(MOD_LAPTOP).1));
            r.add_consent(sign_consent(&keys(MOD_LAPTOP).0, &keys(MOD).1));
            let rec = sign_recovery(&keys(MOD).0, &keys(MOD_RECOVERY).0, 2_000, std::slice::from_ref(&keys(MOD_LAPTOP).1), false);
            r.add_phrase_statement(&r_pub_of(&keys(MOD_RECOVERY).0), Some(rec), None).expect("the phrase drops the moderator's phone");
            v.insert(keys(MOD).1, authority::judge(&keys(MOD).1, &KeyRule::FirstHeld, &[&r]));
        }
        Arc::new(v)
    }

    #[test]
    fn a_server_without_a_base_holds_its_members_when_the_owner_device_is_dropped() {
        let (mut owner, log) = baseless_world();
        let mut m = baseless_replica(&log, MEMBER, MEMBER_PHONE, true);
        m.authority = view_after(false);
        let _ = m.rebuild_now();
        let r = m.recovery.clone().expect("HOL-SEC-230: the drop of the founding device opens a hold");
        assert!(r.keeps_fold() && r.base.is_none() && r.dropped == vec![(keys(OWNER).1, keys(PHONE).1)], "a part A hold: {:?}", r.dropped);
        for who in [MEMBER, MOD, LATE] {
            assert!(m.is_member(&keys(who).1), "the fold keeps {who}");
        }
        assert_eq!(m.get_role(&keys(MOD).1), MemberRole::Moderator, "and the phone's role grant");
        assert!(!m.floor_holds(), "no floor: nothing to name");
        let back = Recovery::from_json(&r.to_json().unwrap()).expect("the row parses");
        assert_eq!((back.dropped, back.kept), (r.dropped.clone(), r.kept.clone()), "the row keeps what it holds");
        // The phone after the notice: nothing it writes counts.
        let late = owner.author_checked(P::ServerRenamed { new_name: "thief".into() }).unwrap();
        m.ingest_remote(std::slice::from_ref(&late));
        assert_ne!(m.name.read(), "thief", "an op the hold never recorded stays refused");
        assert!(m.in_recovery(), "still held");
    }

    #[test]
    fn a_baseless_hold_never_forms_for_us_a_non_member_a_missing_roster_or_a_counted_device() {
        let (_, log) = baseless_world();
        // Our own identity: our settling decides.
        let mut ours = baseless_replica(&log, OWNER, LAPTOP, true);
        ours.authority = view_after(false);
        let _ = ours.rebuild_now();
        assert!(!ours.in_recovery(), "our own recovery opens no hold here");
        // A view with no roster for the owner (Missing) decides nothing.
        let mut m = baseless_replica(&log, MEMBER, MEMBER_PHONE, true);
        let mut missing = (*view_after(false)).clone();
        missing.insert(keys(OWNER).1, authority::ViewEntry::default());
        m.authority = Arc::new(missing);
        let _ = m.rebuild_now();
        assert!(!m.in_recovery(), "a Missing roster is no trigger");
        // A member whose roster is not held yet (Missing): its op parks, no hold forms.
        let mut parked = baseless_replica(&log, MEMBER, MEMBER_PHONE, true);
        let mut no_mod = (*view_after(false)).clone();
        let (before, _) = owner_rosters();
        no_mod.insert(keys(OWNER).1, authority::judge(&keys(OWNER).1, &KeyRule::FirstHeld, &[&before]));
        no_mod.insert(keys(MOD).1, authority::ViewEntry::default());
        parked.authority = Arc::new(no_mod);
        let _ = parked.rebuild_now();
        assert!(!parked.is_banned(&keys(STRANGER).1), "precondition: the moderator's ban no longer folds");
        assert!(!parked.in_recovery(), "an op whose author's roster is Missing opens no hold");
        // A view that still counts every device: nothing lost.
        let mut same = baseless_replica(&log, MEMBER, MEMBER_PHONE, true);
        let _ = same.rebuild_now();
        assert!(!same.in_recovery(), "nothing dropped, no hold");
        // A replica that is no member.
        let mut stranger = baseless_replica(&log, 17, 18, true);
        stranger.authority = view_after(false);
        let _ = stranger.rebuild_now();
        assert!(!stranger.in_recovery(), "a non-member holds nothing");
    }

    /// The owner's laptop removes the phone the ordinary way (a retire, no phrase).
    fn view_removed() -> Arc<AuthorityView> {
        let (mut r, _) = owner_rosters();
        let base = r.base();
        r.add_removal(sign_removal(&keys(LAPTOP).0, &keys(OWNER).1, &base, &keys(PHONE).1, &[keys(LAPTOP).1]));
        let mut v = (*view(&r)).clone();
        v.insert(keys(OWNER).1, authority::judge(&keys(OWNER).1, &KeyRule::FirstHeld, &[&r]));
        Arc::new(v)
    }

    #[test]
    fn a_baseless_hold_ends_on_a_counted_retire_of_the_dropped_device() {
        let (_, log) = baseless_world();
        let mut m = baseless_replica(&log, MEMBER, MEMBER_PHONE, true);
        m.authority = view_removed();
        let _ = m.rebuild_now();
        assert!(m.in_recovery(), "precondition: held");
        // The owner's laptop retires the phone, naming the ops it folded but LATE's.
        let mut laptop = baseless_replica(&log, OWNER, LAPTOP, true);
        let named: Vec<CrdtOp> = log.iter().filter(|o| o.proven_device() == Some(keys(PHONE).1.as_str())).filter(|o| !matches!(&o.payload, P::MemberAdded { peer_id, .. } if *peer_id == keys(LATE).1)).cloned().collect();
        laptop.authority = view_removed();
        let mut refs: Vec<super::super::operations::OpRef> = named.iter().map(super::super::operations::OpRef::of).collect();
        refs.sort();
        let dr = laptop.create_op(P::DeviceRetired { device: keys(PHONE).1, ops: refs, posts_until_ms: None, restore: None });
        m.ingest_remote(std::slice::from_ref(&dr));
        assert!(!m.in_recovery(), "the retire decides the phone's ops: the hold ends");
        assert!(m.is_member(&keys(MEMBER).1) && !m.is_member(&keys(LATE).1), "what it named counts, the rest does not");
    }

    #[test]
    fn a_baseless_hold_survives_the_settlers_first_checkpoint() {
        let (_, log) = baseless_world();
        let mut m = baseless_replica(&log, MEMBER, MEMBER_PHONE, true);
        m.authority = view_after(false);
        let _ = m.rebuild_now();
        assert!(m.in_recovery(), "precondition: held");
        let mut laptop = baseless_replica(&log, OWNER, LAPTOP, true);
        laptop.authority = view_after(false);
        let _ = laptop.rebuild_now();
        assert!(!laptop.is_member(&keys(LATE).1), "precondition: the laptop's fold lacks what the phone wrote");
        let cp = checkpoint(&mut laptop);
        m.ingest_remote(std::slice::from_ref(&cp));
        assert!(m.in_recovery(), "a checkpoint naming no dropped device never ends the hold");
        assert!(m.recovery_hold(None, &keys(LATE).1) >= Hold::Keep, "the seats stay held");
    }

    #[test]
    fn a_moderators_dropped_device_keeps_its_ban_in_the_owners_fold() {
        let (mut owner, _) = baseless_world();
        owner.authority = view_after(true);
        // The owner's own phone stays counted here: only the moderator's view changed.
        let mut v = (*owner.authority).clone();
        let (before, _) = owner_rosters();
        v.insert(keys(OWNER).1, authority::judge(&keys(OWNER).1, &KeyRule::FirstHeld, &[&before]));
        owner.authority = Arc::new(v);
        let _ = owner.rebuild_now();
        assert!(owner.is_banned(&keys(STRANGER).1) && !owner.is_member(&keys(STRANGER).1), "HOL-SEC-231: the ban stays in the owner's fold");
        let r = owner.recovery.clone().expect("a hold for the moderator's dropped phone");
        assert_eq!(r.dropped, vec![(keys(MOD).1, keys(MOD_PHONE).1)]);
        // The moderator's phone after the notice: a new ban never counts.
        let mut moderator = baseless_replica(&owner.op_log.clone(), MOD, MOD_PHONE, true);
        let late = moderator.author_checked(P::MemberRemoved { peer_id: keys(MEMBER).1, seen: None });
        if let Some(late) = late {
            owner.ingest_remote(std::slice::from_ref(&late));
            assert!(owner.is_member(&keys(MEMBER).1), "a kick the hold never recorded stays refused");
        }
    }

    #[test]
    fn a_recovery_stored_while_the_node_was_down_opens_the_hold_at_restart() {
        let (_, log) = baseless_world();
        let m = baseless_replica(&log, MEMBER, MEMBER_PHONE, true);
        let rows: Vec<(CrdtOp, Option<u64>)> = m
            .op_log
            .iter()
            .map(|o| (o.clone(), None))
            .chain(m.stored.iter().map(|(o, k)| (o.clone(), if let RowKind::Parked(u) = k { Some(*u) } else { None })))
            .collect();
        let mut back: ServerState = serde_json::from_str(&serde_json::to_string(&m).unwrap()).unwrap();
        let (kp, id, pk) = keys(MEMBER);
        back.set_hlc(super::super::hlc::Hlc::for_device(id, &keys(MEMBER_PHONE).1));
        back.set_signer(kp, pk);
        back.set_device_signer(keys(MEMBER_PHONE).0);
        back.authority = view_after(false);
        let restored = back.restore_op_log(rows);
        assert!(back.in_recovery(), "HOL-SEC-232: the restart judges the trigger against the saved rows");
        assert!(restored.recovery.is_some(), "and hands the row to save");
        assert!(back.is_member(&keys(LATE).1), "the fold keeps what it held");
    }

    // Part C (HOL-SEC-230): early owner checkpoints, and none of a stepped-back fold.

    #[test]
    fn an_owner_checkpoints_a_cut_server_soon_after_its_first_admission() {
        let (before, _) = owner_rosters();
        let (master, m_id, pk) = keys(OWNER);
        let (phone, phone_id, _) = keys(PHONE);
        let r_pub = before.r_pub.clone();
        let (mut owner, _) = ServerState::found_on("c".into(), m_id.clone(), Founder { device_peer_id: &phone_id, device: Some(&phone), r_pub: Some(&r_pub) }, master, pk);
        owner.authority = view(&before);
        let _ = owner.rebuild_now();
        let now = super::super::hlc::wall_clock_ms();
        assert!(owner.cut, "precondition: a phrase-rooted server is cut from its founding op");
        assert!(!owner.checkpoint_due(&m_id, now), "the founding op alone owes nothing");
        admit(&mut owner, MEMBER);
        assert!(owner.checkpoint_due(&m_id, now), "the first admission is due a checkpoint");
        checkpoint(&mut owner);
        assert!(owner.base.is_some(), "precondition: the checkpoint is the base");
        let hour = super::super::fold::CHECKPOINT_MIN_GAP_MS + 60_000;
        let mut idle = owner.clone();
        admit(&mut owner, MOD);
        assert!(!owner.checkpoint_due(&m_id, now), "at most hourly");
        assert!(owner.checkpoint_due(&m_id, now + hour), "an hour on, an admission past the base is due");
        idle.author_checked(P::MessagePinned { channel_id: "general".into(), message_id: "m".into() });
        assert!(!idle.checkpoint_due(&m_id, now + hour), "a pin alone never checkpoints an idle server");
    }

    #[test]
    fn no_early_checkpoint_while_an_owned_server_awaits_its_settling() {
        let (_, log) = baseless_world();
        let mut laptop = baseless_replica(&log, OWNER, LAPTOP, true);
        let now = super::super::hlc::wall_clock_ms();
        assert!(laptop.checkpoint_due(&keys(OWNER).1, now), "precondition: before the recovery the first checkpoint is due");
        laptop.authority = view_after(false);
        let _ = laptop.rebuild_now();
        assert!(laptop.settle_owed(&keys(OWNER).1), "the phone proved ops of ours nothing settled");
        laptop.author_checked(P::ServerRenamed { new_name: "after".into() }).expect("the laptop still writes");
        assert!(!laptop.checkpoint_due(&keys(OWNER).1, now + 10 * super::super::fold::CHECKPOINT_MIN_GAP_MS), "no checkpoint of the stepped-back fold");
        // The writer rule never takes a fold listing only us as witnessed.
        let mut alone = laptop.clone();
        alone.members.retain(|m, _| *m == keys(OWNER).1);
        assert!(!alone.checkpoint_witnessed(&keys(OWNER).1, &Default::default()), "no other identity, no witness");
    }

    #[test]
    fn a_restart_judges_the_base_trigger_against_the_saved_base() {
        let w = world();
        let m = member_of(&w, MEMBER, MEMBER_PHONE, true);
        let rows: Vec<(CrdtOp, Option<u64>)> = m
            .op_log
            .iter()
            .map(|o| (o.clone(), None))
            .chain(m.stored.iter().map(|(o, k)| (o.clone(), if let RowKind::Parked(u) = k { Some(*u) } else { None })))
            .collect();
        let mut back: ServerState = serde_json::from_str(&serde_json::to_string(&m).unwrap()).unwrap();
        let (kp, id, pk) = keys(MEMBER);
        back.set_hlc(super::super::hlc::Hlc::for_device(id, &keys(MEMBER_PHONE).1));
        back.set_signer(kp, pk);
        back.set_device_signer(keys(MEMBER_PHONE).0);
        let (_, after) = owner_rosters();
        back.authority = view(&after);
        let restored = back.restore_op_log(rows);
        let r = back.recovery.clone().expect("HOL-SEC-232: the restart opens the 8.8 hold");
        assert_eq!(r.base.as_deref(), Some(hex::encode(w.cp1.content_hash()).as_str()), "the step back records the saved base");
        assert!(!r.keeps_fold() && restored.recovery.is_some(), "a base step-back, saved");
    }
}
