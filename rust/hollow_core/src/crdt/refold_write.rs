//! The owner re-fold's writer (DEVICE_PROOF_DESIGN section 8.3): which (member, dropped
//! device) pairs this owner device re-folds, from which R, and what its next checkpoint
//! carries for them: the AUTO and Unpublish reverts, the `cp_refolded` entries with their
//! listing, timeouts and the owner's answers.

use std::collections::BTreeSet;

use super::fold::Base;
use super::hlc::{lane_of, HlcTimestamp};
use super::operations::{CrdtOp, CrdtPayload, MemberRole};
use super::refold::{
    apply_revert, classify, item_current, lane_writes, ElementKey, Judge, Lane, RefoldClass, RefoldItem, Refolded, ChannelField,
    LISTED_TIMEOUT_MS, MAX_LISTED, MAX_UNANSWERED, R_REACH_MS,
};
use super::server_state::{ChannelPosting, ChannelVisibility, ServerState};
use super::authority::Verdict;
use crate::identity::native_identity::NativeKeypair;

/// One pair whose re-fold this owner device owes (section 8.3, "Trigger" 1-4).
#[derive(Debug, Clone)]
pub(crate) struct RefoldTrigger {
    pub member: String,
    pub device: String,
    pub dr: CrdtOp,
    pub dr_id: String,
    pub restore: String,
}

/// The `server_blobs` key of this device's answers the base does not carry yet: local,
/// never served, deleted with the server.
pub(crate) const ANSWERS_BLOB: &str = "refold_answers";

/// An owner's answer this device took and the base does not carry yet ("Confirm").
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub(crate) struct LocalAnswer {
    pub member: String,
    pub device: String,
    pub dr: String,
    pub below: Option<HlcTimestamp>,
    /// The items the owner saw, with the stamps they were listed with.
    pub shown: Vec<RefoldItem>,
    pub chosen: Vec<String>,
    pub put_back: Vec<super::refold::Unpublished>,
}

/// What one held op writes, for folding held ops back onto a reverted element.
fn op_keys(p: &CrdtPayload) -> Vec<ElementKey> {
    use CrdtPayload as P;
    use ElementKey as K;
    let m = |id: &str| super::resolve_identity(id);
    let field = |c: &str, f: ChannelField| K::ChannelField(c.to_string(), f);
    if super::refold::payload_kind(p) == super::refold::PayloadKind::Excluded {
        return Vec::new();
    }
    match p {
        P::ServerRenamed { .. } => vec![K::Name],
        P::ServerSettingChanged { key, .. } => vec![K::Setting(key.clone())],
        P::RoleChanged { peer_id, .. } => vec![K::Role(m(peer_id))],
        P::RolePermissionsChanged { role, .. } => vec![K::RolePerms(role.clone())],
        P::NicknameChanged { peer_id, .. } => vec![K::Nickname(m(peer_id))],
        P::TwitchUsernameChanged { peer_id, .. } => vec![K::Twitch(m(peer_id))],
        P::StoragePledgeChanged { peer_id, .. } => vec![K::Pledge(m(peer_id))],
        P::MemberBanned { peer_id, .. } | P::MemberUnbanned { peer_id } => vec![K::Ban(m(peer_id))],
        P::MemberMuted { peer_id, .. } | P::MemberUnmuted { peer_id } => vec![K::Mute(m(peer_id))],
        P::ChannelGrantSet { channel_id, peer_id, .. } | P::ChannelGrantRevoked { channel_id, peer_id } => {
            vec![K::Grant(channel_id.clone(), m(peer_id))]
        }
        P::ChannelRenamed { channel_id, .. } => vec![field(channel_id, ChannelField::Name)],
        P::ChannelSlowModeChanged { channel_id, .. } => vec![field(channel_id, ChannelField::Slow)],
        P::ChannelMediaOnlyChanged { channel_id, .. } => vec![field(channel_id, ChannelField::Media)],
        P::ChannelVoiceChatChanged { channel_id, .. } => vec![field(channel_id, ChannelField::Voice)],
        P::ChannelPostingChanged { channel_id, .. } => vec![field(channel_id, ChannelField::Posting)],
        P::ChannelPostingLabelsChanged { channel_id, .. } => vec![field(channel_id, ChannelField::PostLabels)],
        // Both visibility arms date `public` too (HOL-SEC-094).
        P::ChannelVisibilityChanged { channel_id, .. } => {
            vec![field(channel_id, ChannelField::Visibility), K::ChannelPublic(channel_id.clone())]
        }
        P::ChannelVisibilityLabelsChanged { channel_id, .. } => {
            vec![field(channel_id, ChannelField::VisLabels), K::ChannelPublic(channel_id.clone())]
        }
        P::ChannelPublicChanged { channel_id, .. } => vec![K::ChannelPublic(channel_id.clone())],
        P::MessagePinned { channel_id, message_id } | P::MessageUnpinned { channel_id, message_id } => {
            vec![K::Pin(channel_id.clone(), message_id.clone())]
        }
        P::ChannelLayoutUpdated { .. } => vec![K::Layout],
        P::LabelAssigned { label_id, peer_id } | P::LabelUnassigned { label_id, peer_id } => vec![K::Assigned(m(peer_id), label_id.clone())],
        P::LabelUpdated { label_id, .. } => vec![K::LabelFields(label_id.clone())],
        _ => Vec::new(),
    }
}

/// Fold every held op on `keys` back on top of a revert, the dropped lane's own excepted.
fn fold_held_onto(snap: &mut ServerState, keys: &[ElementKey], lane: &Lane<'_>, held: &[CrdtOp]) {
    let mut ops: Vec<&CrdtOp> =
        held.iter().filter(|o| !lane.holds(&o.hlc) && op_keys(&o.payload).iter().any(|k| keys.contains(k))).collect();
    ops.sort_by(|a, b| a.hlc.cmp(&b.hlc));
    for o in ops {
        snap.apply_payload(o);
    }
}

impl ServerState {
    pub(crate) fn every_held(&self) -> impl Iterator<Item = &CrdtOp> {
        self.op_log.iter().chain(self.stored.iter().map(|(o, _)| o)).chain(self.held.iter().map(|(o, _)| o))
    }

    fn held_by_id(&self, id: &str) -> Option<&CrdtOp> {
        self.every_held().find(|o| hex::encode(self.content_of(o)) == id)
    }

    /// `dr` is a lost-or-stolen DR of `member` for `device`, counted here, naming a restore.
    fn counted_dr_for(&self, dr: &CrdtOp, member: &str, device: &str) -> bool {
        matches!(&dr.payload, CrdtPayload::DeviceRetired { device: d, restore: Some(_), .. } if d == device)
            && dr.author == member
            && self.direct_verdict(dr) == Verdict::Counted
    }

    /// Trigger clause 3 (R34-4): a device this view counts for `member` shares `device`'s lane.
    fn lane_shared(&self, member: &str, device: &str) -> bool {
        let lane = lane_of(device);
        self.authority
            .entry(member)
            .and_then(|e| e.auth.as_ref())
            .is_some_and(|a| a.counted.iter().any(|d| d != device && lane_of(d) == lane))
    }

    /// Trigger clauses 2 and 3, which an entry's show/apply check re-runs (R34-1).
    fn dropped_alone(&self, member: &str, device: &str) -> bool {
        !self.authority.counts(member, device) && !self.lane_shared(member, device)
    }

    /// Whether an entry's DR, if held here, is a counted DR for the entry's own pair.
    fn entry_dr_fits(&self, e: &Refolded) -> bool {
        self.held_by_id(&e.dr).is_none_or(|dr| self.counted_dr_for(dr, &e.member, &e.device))
    }

    /// Every pair whose trigger holds at this owner device (section 8.3, "Trigger").
    pub(crate) fn refold_triggers(&self) -> Vec<RefoldTrigger> {
        let (Some(owner), Some(base)) = (self.anchor_owner(), self.base.as_ref()) else { return Vec::new() };
        if !self.authority.is_set() {
            return Vec::new();
        }
        let base_hex = base.hash_hex();
        let mut drs: Vec<&CrdtOp> = self.every_held().filter(|o| matches!(o.payload, CrdtPayload::DeviceRetired { .. })).collect();
        drs.sort_by(|a, b| a.hlc.cmp(&b.hlc));
        let mut out: Vec<RefoldTrigger> = Vec::new();
        for dr in drs {
            let CrdtPayload::DeviceRetired { device, restore: Some(restore), .. } = &dr.payload else { continue };
            if dr.author == owner || out.iter().any(|t| t.member == dr.author && t.device == *device) {
                continue;
            }
            let on_line = *restore == base_hex || base.state.cp_lineage.contains(restore);
            if !on_line || !self.counted_dr_for(dr, &dr.author, device) || !self.dropped_alone(&dr.author, device) {
                continue;
            }
            if self.refold_suppressed(&dr.author, device, &|e| self.entry_dr_fits(e)) {
                continue;
            }
            out.push(RefoldTrigger {
                member: dr.author.clone(),
                device: device.clone(),
                dr: dr.clone(),
                dr_id: hex::encode(self.content_of(dr)),
                restore: restore.clone(),
            });
        }
        out
    }

    /// R (section 8.3): the restore point when its content is held, else the nearest older
    /// one on the base's line that is, never past the oldest checkpoint of the line this
    /// device first folded within `R_REACH_MS`.
    pub(crate) fn refold_point(&self, restore: &str, now_ms: u64) -> Option<Base> {
        let base = self.base.as_ref()?;
        let line: Vec<String> = std::iter::once(base.hash_hex()).chain(base.state.cp_lineage.iter().cloned()).collect();
        let at = line.iter().position(|h| h == restore)?;
        let recent = |h: &str| self.first_folds.get(h).is_some_and(|f| now_ms.saturating_sub(*f) <= R_REACH_MS);
        let reach = line.iter().rposition(|h| recent(h)).unwrap_or(0);
        (at.min(reach)..=reach).find_map(|i| self.base_by_hash(&line[i]))
    }

    /// Whether this owner device owes a checkpoint for the re-fold: a pair to re-fold from a
    /// held R (at most once per `CHECKPOINT_MIN_GAP_MS` after the base's newest entry, since
    /// members' DRs cause it), an answer the base does not carry, or a listed entry past its
    /// 30 days.
    pub(crate) fn refold_due(&self, now_ms: u64) -> bool {
        if self.device_signer().is_none() {
            return false;
        }
        let sid = self.server_id.as_str();
        let entries = self.base.iter().flat_map(|b| b.state.cp_refolded.iter());
        let open = |e: &Refolded| e.valid_answer(sid).is_none_or(|a| a.timeout);
        let recent = entries
            .clone()
            .any(|e| self.entry_suppresses(e, &|_| true) && now_ms.saturating_sub(e.at.physical_ms) < super::fold::CHECKPOINT_MIN_GAP_MS);
        (!recent && self.refold_triggers().iter().any(|t| self.refold_point(&t.restore, now_ms).is_some()))
            || self.refold_answers.iter().any(|a| entries.clone().any(|e| e.pair() == (&a.member, &a.device) && e.dr == a.dr && open(e)))
            || entries.clone().any(|e| {
                e.answered.is_none()
                    && e.opened.as_ref().is_some_and(|o| now_ms.saturating_sub(o.physical_ms) >= LISTED_TIMEOUT_MS)
            })
    }

    /// Section 8.3, "What every owner device checks before it shows or applies an entry".
    pub(crate) fn refold_entry_valid(&self, e: &Refolded) -> bool {
        let Some(owner) = self.anchor_owner() else { return false };
        let sid = self.server_id.as_str();
        let dr_ok = self.held_by_id(&e.dr).is_some_and(|dr| self.counted_dr_for(dr, &e.member, &e.device));
        e.sig_verifies(sid) && self.authority.counts(&owner, &e.by) && dr_ok && self.dropped_alone(&e.member, &e.device)
    }

    /// An item of a valid entry that may still be shown or applied (R34-1).
    pub(crate) fn refold_item_valid(&self, e: &Refolded, item: &RefoldItem) -> Option<ElementKey> {
        let key = ElementKey::from_key(&item.key)?;
        let dr = self.held_by_id(&e.dr)?;
        let CrdtPayload::DeviceRetired { ops, .. } = &dr.payload else { return None };
        let lane = Lane::new(&e.member, &e.device, ops);
        (lane.holds(&item.stamp) && item_current(self, &key, &item.stamp)).then_some(key)
    }

    /// Section 8.3: the re-fold's part of the checkpoint `snap` (a lean copy of this state
    /// with the carried `cp_refolded`), written by this owner device at `now_ms`.
    pub(crate) fn write_refolds(&self, snap: &mut ServerState, now_ms: u64) {
        let Some(device) = self.device_signer().cloned() else { return };
        let Some(owner) = self.anchor_owner() else { return };
        if self.hlc.as_ref().map(|h| h.actor()) != Some(owner.as_str()) || self.base.is_none() {
            return;
        }
        let at = HlcTimestamp { physical_ms: now_ms, counter: 0, actor: owner.clone() };
        let held: Vec<CrdtOp> = self.every_held().cloned().collect();
        self.keep_retired_signers(snap, &owner, &device);
        self.apply_answers(snap, &device, &at, &held);
        for t in self.refold_triggers() {
            let pair = (t.member.as_str(), t.device.as_str());
            if snap.cp_refolded.iter().any(|e| e.pair() == pair && self.entry_suppresses(e, &|e| self.entry_dr_fits(e))) {
                continue;
            }
            // An entry that suppresses nothing (its DR no longer counts here) gives way.
            snap.cp_refolded.retain(|e| e.pair() != pair);
            let Some(r) = self.refold_point(&t.restore, now_ms) else { continue };
            let CrdtPayload::DeviceRetired { ops: named, posts_until_ms, .. } = &t.dr.payload else { continue };
            let lane = Lane::new(&t.member, &t.device, named);
            let writes = lane_writes(self, &r.state, &r.covers, &lane);
            let judge = Judge { base: self, r: &r.state, t_ms: *posts_until_ms, at: at.clone(), held: &held, lane: &lane };
            let (classed, review, unpublished) = classify(&judge, &writes);
            for (w, class) in &classed {
                if matches!(class, RefoldClass::Auto | RefoldClass::Unpublish) && apply_revert(snap, &r.state, &w.key, &w.stamp) {
                    fold_held_onto(snap, std::slice::from_ref(&w.key), &lane, &held);
                }
            }
            let mut e = Refolded {
                member: t.member.clone(),
                device: t.device.clone(),
                dr: t.dr_id.clone(),
                r: r.hash_hex(),
                at: at.clone(),
                opened: Some(at.clone()),
                below: None,
                review,
                unpublished,
                by: String::new(),
                sig: String::new(),
                answered: None,
            };
            e.sign(&self.server_id, &device);
            if e.review.is_empty() && e.unpublished.is_empty() {
                e.answer(&self.server_id, &device, Vec::new(), Vec::new(), Vec::new(), false);
            }
            snap.cp_refolded.push(e);
        }
        self.list_entries(snap, &device, &at, &held);
        snap.cp_refolded.sort_by(|a, b| a.pair().cmp(&b.pair()));
    }

    /// Section 8.5: entries and answers an owner device signed before an honest retire of
    /// it (a counted owner DR with no restore point) are signed again by this device, so
    /// rule 3 never re-opens a review the owner answered.
    fn keep_retired_signers(&self, snap: &mut ServerState, owner: &str, device: &NativeKeypair) {
        let sid = self.server_id.as_str();
        let retired = |d: &str| {
            self.every_held().any(|o| {
                o.author == owner
                    && matches!(&o.payload, CrdtPayload::DeviceRetired { device: x, restore: None, .. } if x == d)
                    && self.direct_verdict(o) == Verdict::Counted
            })
        };
        for e in self.base.iter().flat_map(|b| b.state.cp_refolded.iter()).filter(|e| e.sig_verifies(sid)) {
            let mut kept = match snap.cp_refolded.iter().find(|x| x.pair() == e.pair()) {
                Some(x) if x.dr == e.dr => x.clone(),
                Some(_) => continue,
                None if retired(&e.by) => {
                    let mut x = e.clone();
                    x.answered = None;
                    x.sign(sid, device);
                    x
                }
                None => continue,
            };
            if kept.answered.is_none()
                && let Some(a) = e.valid_answer(sid).filter(|a| retired(&a.by)).cloned()
            {
                kept.answer(sid, device, a.undone, a.kept, a.put_back, a.timeout);
            }
            snap.cp_refolded.retain(|x| x.pair() != e.pair());
            snap.cp_refolded.push(kept);
        }
    }

    /// Section 8.3 "Listed or waiting": rank the unanswered entries by their author's
    /// standing, then DR clock; the first `MAX_LISTED` (one per author) list, the rest wait,
    /// past `MAX_UNANSWERED` the lowest go; a listed entry closes after 30 days.
    fn list_entries(&self, snap: &mut ServerState, device: &NativeKeypair, at: &HlcTimestamp, held: &[CrdtOp]) {
        let sid = self.server_id.clone();
        let open: Vec<usize> = (0..snap.cp_refolded.len()).filter(|i| snap.cp_refolded[*i].answered.is_none()).collect();
        let masters: BTreeSet<String> = open.iter().map(|i| snap.cp_refolded[*i].member.clone()).collect();
        let ranked = crate::node::standing::rank_masters(self, masters);
        let dr_clock = |e: &Refolded| self.held_by_id(&e.dr).map(|o| o.hlc.clone()).unwrap_or_else(|| e.at.clone());
        let mut order: Vec<(usize, usize, HlcTimestamp)> = open
            .iter()
            .map(|&i| {
                let e = &snap.cp_refolded[i];
                (ranked.iter().position(|m| *m == e.member).unwrap_or(usize::MAX), i, dr_clock(e))
            })
            .collect();
        order.sort_by(|a, b| (a.0, &a.2).cmp(&(b.0, &b.2)));
        let gone: BTreeSet<usize> = order.iter().skip(MAX_UNANSWERED).map(|o| o.1).collect();
        let mut listed_authors: BTreeSet<String> = BTreeSet::new();
        for (_, i, _) in order.iter().take(MAX_UNANSWERED) {
            let member = snap.cp_refolded[*i].member.clone();
            let listed = listed_authors.len() < MAX_LISTED && listed_authors.insert(member);
            let mut e = snap.cp_refolded[*i].clone();
            match (listed, e.opened.clone()) {
                (true, None) => {
                    let Some(review) = self.walk_review(&e, at, held) else { continue };
                    e.review = review;
                    e.opened = Some(at.clone());
                    e.sign(&sid, device);
                    if e.review.is_empty() && e.unpublished.is_empty() {
                        e.answer(&sid, device, Vec::new(), Vec::new(), Vec::new(), false);
                    }
                }
                (true, Some(opened)) if at.physical_ms.saturating_sub(opened.physical_ms) >= LISTED_TIMEOUT_MS => {
                    e.review.clear();
                    e.unpublished.clear();
                    e.sign(&sid, device);
                    e.answer(&sid, device, Vec::new(), Vec::new(), Vec::new(), true);
                }
                (false, Some(_)) => {
                    e.review.clear();
                    e.opened = None;
                    e.sign(&sid, device);
                }
                _ => continue,
            }
            snap.cp_refolded[*i] = e;
        }
        let mut i = 0;
        snap.cp_refolded.retain(|_| {
            i += 1;
            !gone.contains(&(i - 1))
        });
    }

    /// A waiting entry's REVIEW items when it ranks in: the dropped lane walked again from
    /// its pinned R and DR, only what still carries the lane's stamp. `None` while either
    /// is not held here.
    fn walk_review(&self, e: &Refolded, at: &HlcTimestamp, held: &[CrdtOp]) -> Option<Vec<RefoldItem>> {
        let r = self.base_by_hash(&e.r)?;
        let dr = self.held_by_id(&e.dr)?;
        let CrdtPayload::DeviceRetired { ops: named, posts_until_ms, .. } = &dr.payload else { return None };
        let lane = Lane::new(&e.member, &e.device, named);
        let writes = lane_writes(self, &r.state, &r.covers, &lane);
        let judge = Judge { base: self, r: &r.state, t_ms: *posts_until_ms, at: at.clone(), held, lane: &lane };
        let (classed, ..) = classify(&judge, &writes);
        Some(
            classed
                .into_iter()
                .filter(|(_, c)| *c == RefoldClass::Review)
                .map(|(w, _)| RefoldItem { key: w.key.to_key(), stamp: w.stamp })
                .take(super::refold::MAX_REVIEW)
                .collect(),
        )
    }

    /// Section 8.3 "Confirm": apply each answer this device took to its entry, whether
    /// listed or waiting, each item re-checked; a person's answer replaces a timeout once.
    fn apply_answers(&self, snap: &mut ServerState, device: &NativeKeypair, at: &HlcTimestamp, held: &[CrdtOp]) {
        let sid = self.server_id.clone();
        for a in &self.refold_answers {
            let Some(idx) = snap.cp_refolded.iter().position(|e| e.pair() == (&a.member, &a.device) && e.dr == a.dr) else { continue };
            let e = snap.cp_refolded[idx].clone();
            if e.valid_answer(&sid).is_some_and(|x| !x.timeout) || e.below != a.below || !self.refold_entry_valid(&e) {
                continue;
            }
            let (undone, kept, put_back) = self.apply_answer(snap, &e, a, at, held);
            let mut e = e;
            e.review.clear();
            e.unpublished.clear();
            e.sign(&sid, device);
            e.answer(&sid, device, undone, kept, put_back, false);
            snap.cp_refolded[idx] = e;
        }
    }

    /// Apply one answer on `snap`: (undone, kept, put back).
    fn apply_answer(&self, snap: &mut ServerState, e: &Refolded, a: &LocalAnswer, at: &HlcTimestamp, held: &[CrdtOp]) -> (Vec<String>, Vec<String>, Vec<String>) {
        let (mut undone, mut kept, mut put_back) = (Vec::new(), Vec::new(), Vec::new());
        let r = self.base_by_hash(&e.r);
        let named = match self.held_by_id(&e.dr).map(|o| &o.payload) {
            Some(CrdtPayload::DeviceRetired { ops, .. }) => ops.clone(),
            _ => Vec::new(),
        };
        let lane = Lane::new(&e.member, &e.device, &named);
        for item in &a.shown {
            let applied = a.chosen.contains(&item.key)
                && r.as_ref().is_some_and(|r| {
                    self.refold_item_valid(e, item).is_some_and(|key| revert_reviewed(snap, &r.state, &key, &item.stamp, &lane, held))
                });
            if applied { undone.push(item.key.clone()) } else { kept.push(item.key.clone()) }
        }
        for u in &a.put_back {
            if !lane.holds(&u.stamp) {
                continue;
            }
            let restricted = snap.channels.get(&u.channel).is_none_or(|c| c.restricted());
            let moved = super::refold::winning_stamp(snap, &ElementKey::ChannelPublic(u.channel.clone())) != r_public_stamp(r.as_ref(), &u.channel);
            if restricted || moved {
                continue;
            }
            let op = CrdtOp {
                server_id: self.server_id.clone(),
                hlc: at.clone(),
                author: at.actor.clone(),
                payload: CrdtPayload::ChannelPublicChanged { channel_id: u.channel.clone(), is_public: true },
                auth: None,
                dev: None,
            };
            snap.apply_payload(&op);
            put_back.push(u.channel.clone());
            undone.push(u.channel.clone());
        }
        (undone, kept, put_back)
    }
}

/// Per chosen item and per put-back channel: (key or channel id, still stands).
pub(crate) type Outcomes = (Vec<(String, bool)>, Vec<(String, bool)>);

/// One item as the owner's list shows it (appendix A), with what its undo opens.
#[derive(Debug, Clone)]
pub(crate) struct ShownItem {
    pub key: ElementKey,
    pub raw: String,
    /// R's role for a role item: what an undo gives back.
    pub r_role: Option<MemberRole>,
    pub opens: bool,
    pub channel_name: Option<String>,
    pub label_name: Option<String>,
}

/// One entry as every owner device shows it ("What every owner device checks").
#[derive(Debug, Clone)]
pub(crate) struct ShownEntry {
    pub entry: Refolded,
    pub items: Vec<ShownItem>,
    /// Channel ids of the Unpublish records still as the revert left them.
    pub unpublished: Vec<String>,
}

impl ServerState {
    /// The valid entries of the base, each with only its items that still stand. Empty for
    /// anyone but the owner.
    pub(crate) fn refold_shown(&self, me: &str) -> Vec<ShownEntry> {
        if self.anchor_owner().as_deref() != Some(me) {
            return Vec::new();
        }
        let Some(base) = self.base.as_ref() else { return Vec::new() };
        let mut out = Vec::new();
        for e in base.state.cp_refolded.iter().filter(|e| self.refold_entry_valid(e)) {
            let r = self.base_by_hash(&e.r);
            let items = e
                .review
                .iter()
                .filter_map(|i| self.refold_item_valid(e, i).map(|k| self.shown_item(k, i.key.clone(), r.as_ref().map(|b| &*b.state))))
                .collect();
            let unpublished = e
                .unpublished
                .iter()
                .filter(|u| super::refold::winning_stamp(self, &ElementKey::ChannelPublic(u.channel.clone())) == r_public_stamp(r.as_ref(), &u.channel))
                .map(|u| u.channel.clone())
                .collect();
            out.push(ShownEntry { entry: e.clone(), items, unpublished });
        }
        out
    }

    fn shown_item(&self, key: ElementKey, raw: String, r: Option<&ServerState>) -> ShownItem {
        use ElementKey as K;
        let chan = |c: &str| self.channels.get(c).or_else(|| r.and_then(|r| r.channels.get(c)));
        let label = |l: &str| self.labels.get(l).or_else(|| r.and_then(|r| r.labels.get(l)));
        let (mut channel_name, mut label_name) = (None, None);
        let mut r_role = None;
        let opens = match &key {
            K::Role(m) => {
                r_role = r.map(|r| r.get_role(m));
                r_role.as_ref().is_some_and(|x| x.priority() > MemberRole::Member.priority())
            }
            K::Ban(_) | K::Remove(_) | K::Leave(_) => true,
            K::Grant(c, m) => {
                channel_name = chan(c).map(|x| x.name.clone());
                !self.channel_grants.get(c).is_some_and(|p| p.contains_key(m))
            }
            K::Assigned(m, l) => {
                label_name = label(l).map(|x| x.name.clone());
                label(l).is_some_and(|x| x.access) && !self.label_assignments.get(m).is_some_and(|v| v.contains(l))
            }
            K::ChannelField(c, _) | K::ChannelPublic(c) | K::ChannelExist(c) => {
                channel_name = chan(c).map(|x| x.name.clone());
                let now = self.channels.get(c);
                let was = r.and_then(|r| r.channels.get(c));
                match (&key, now, was) {
                    (K::ChannelPublic(_), Some(n), Some(w)) => !n.effective_public() && w.effective_public(),
                    (K::ChannelField(..), Some(n), Some(w)) => (n.restricted() && !w.restricted()) || posting_rank(&w.posting) < posting_rank(&n.posting),
                    _ => false,
                }
            }
            K::LabelFields(l) | K::LabelExist(l) => {
                label_name = label(l).map(|x| x.name.clone());
                false
            }
            K::Setting(k) => k == "is_private" || k == "max_members" || k.starts_with("twitch_"),
            K::JoinSecret => true,
            _ => false,
        };
        ShownItem { key, raw, r_role, opens, channel_name, label_name }
    }

    /// Take the owner's answer for one entry ("Confirm"): stored here until a checkpoint
    /// carries it, applied at the next turn. Per chosen item and put-back channel, whether
    /// it still stands now (`true`) or someone changed it since.
    pub(crate) fn take_refold_answer(
        &mut self,
        me: &str,
        member: &str,
        device: &str,
        below: Option<HlcTimestamp>,
        chosen: &[String],
        put_back: &[String],
    ) -> Result<Outcomes, String> {
        let shown = self.refold_shown(me).into_iter().find(|s| s.entry.pair() == (member, device) && s.entry.below == below);
        let Some(shown) = shown else { return Err("This report is no longer open.".to_string()) };
        let e = shown.entry;
        let items: Vec<RefoldItem> = e.review.iter().filter(|i| shown.items.iter().any(|x| x.raw == i.key)).cloned().collect();
        let outcome = chosen.iter().map(|k| (k.clone(), items.iter().any(|i| i.key == *k))).collect();
        let records: Vec<super::refold::Unpublished> = e.unpublished.iter().filter(|u| put_back.contains(&u.channel)).cloned().collect();
        let restricted = |c: &str| self.channels.get(c).is_none_or(|x| x.restricted());
        let backs = put_back.iter().map(|c| (c.clone(), shown.unpublished.contains(c) && !restricted(c))).collect();
        let answer = LocalAnswer {
            member: member.to_string(),
            device: device.to_string(),
            dr: e.dr.clone(),
            below,
            shown: items,
            chosen: chosen.to_vec(),
            put_back: records,
        };
        self.refold_answers.retain(|a| (a.member.as_str(), a.device.as_str()) != (member, device));
        self.refold_answers.push(answer);
        self.cp_retry_at_ms = 0;
        Ok((outcome, backs))
    }

    /// The answers to keep under `ANSWERS_BLOB` until a checkpoint carries them; `None`
    /// when there are none (the blob goes).
    pub(crate) fn refold_answers_json(&self) -> Option<String> {
        (!self.refold_answers.is_empty()).then(|| serde_json::to_string(&self.refold_answers).ok()).flatten()
    }

    /// The answers a restart finds under `ANSWERS_BLOB`; an unreadable blob restores none.
    pub(crate) fn restore_refold_answers(&mut self, json: &str) {
        self.refold_answers = serde_json::from_str(json).unwrap_or_default();
    }

    /// Drop the answers the base now carries a person's answer for ("One answer for every
    /// owner device").
    pub(crate) fn settle_refold_answers(&mut self) -> bool {
        let sid = self.server_id.clone();
        let Some(base) = self.base.as_ref() else { return false };
        let done = |a: &LocalAnswer| {
            base.state.cp_refolded.iter().any(|e| e.pair() == (&a.member, &a.device) && e.valid_answer(&sid).is_some_and(|x| !x.timeout))
        };
        let keep: Vec<LocalAnswer> = self.refold_answers.iter().filter(|a| !done(a)).cloned().collect();
        let changed = keep.len() != self.refold_answers.len();
        self.refold_answers = keep;
        changed
    }
}

fn posting_rank(p: &ChannelPosting) -> u8 {
    match p {
        ChannelPosting::Everyone => 0,
        ChannelPosting::ModeratorPlus => 1,
        ChannelPosting::AdminPlus => 2,
    }
}

/// The `public` stamp an Unpublish revert left: R's.
fn r_public_stamp(r: Option<&Base>, channel: &str) -> Option<HlcTimestamp> {
    r.and_then(|r| r.state.stamps.channels.get(channel).and_then(|s| s.public.clone()))
}

/// A REVIEW item the owner chose: put back to R, then the held ops on it folded on top.
/// Existence restores R's whole entry (R33-10); undoing a channel's deletion brings it back
/// for admins only with the access sub-stamps left at the base's (R34-7).
fn revert_reviewed(snap: &mut ServerState, r: &ServerState, key: &ElementKey, stamp: &HlcTimestamp, lane: &Lane<'_>, held: &[CrdtOp]) -> bool {
    use ElementKey as K;
    match key {
        K::ChannelExist(c) => revert_channel_existence(snap, r, c, lane, held),
        K::LabelExist(l) | K::LabelFields(l) => {
            match r.labels.get(l) {
                Some(was) => {
                    let gone = !snap.labels.contains_key(l);
                    snap.labels.insert(l.clone(), was.clone());
                    snap.stamps.labels.insert(l.clone(), r.stamps.labels.get(l).cloned().unwrap_or_default());
                    if gone && !was.access && matches!(key, K::LabelExist(_)) {
                        for (m, ls) in &r.label_assignments {
                            if ls.contains(l) {
                                let list = snap.label_assignments.entry(m.clone()).or_default();
                                if !list.contains(l) {
                                    list.push(l.clone());
                                }
                                if let Some(s) = r.stamps.assigned.get(m).and_then(|x| x.get(l)) {
                                    snap.stamps.assigned.entry(m.clone()).or_default().insert(l.clone(), s.clone());
                                }
                            }
                        }
                    }
                    fold_held_onto(snap, &[K::LabelFields(l.clone())], lane, held);
                }
                None => {
                    snap.labels.remove(l);
                    snap.stamps.labels.remove(l);
                }
            }
            true
        }
        K::Emote(name) => {
            match r.emotes.get(name) {
                Some(v) => snap.emotes.insert(name.clone(), v.clone()),
                None => snap.emotes.remove(name),
            };
            match r.stamps.emotes.get(name) {
                Some(s) => snap.stamps.emotes.insert(name.clone(), s.clone()),
                None => snap.stamps.emotes.remove(name),
            };
            true
        }
        K::Sticker(h) => {
            match r.stickers.get(h) {
                Some(v) => snap.stickers.insert(h.clone(), v.clone()),
                None => snap.stickers.remove(h),
            };
            match r.stamps.stickers.get(h) {
                Some(s) => snap.stamps.stickers.insert(h.clone(), s.clone()),
                None => snap.stamps.stickers.remove(h),
            };
            true
        }
        K::JoinSecret => {
            snap.join_secret = r.join_secret.clone();
            true
        }
        K::Remove(m) | K::Ban(m) => {
            let was_member = snap.members.contains_key(m);
            if !apply_revert(snap, r, key, stamp) {
                return false;
            }
            if !was_member {
                reopen_registers(snap, r, m);
            }
            fold_held_onto(snap, std::slice::from_ref(key), lane, held);
            true
        }
        _ => {
            if !apply_revert(snap, r, key, stamp) {
                return false;
            }
            fold_held_onto(snap, std::slice::from_ref(key), lane, held);
            true
        }
    }
}

/// R34-8: a span an undone removal re-opens takes R's role above `Member` and R's other
/// per-member registers where R dates them inside that span.
fn reopen_registers(snap: &mut ServerState, r: &ServerState, m: &str) {
    let Some(from) = snap.member_record.get(m).and_then(|s| s.last()).filter(|s| s.until_ms == u64::MAX).map(|s| s.from_hlc.clone()) else { return };
    let inside = |h: &HlcTimestamp| from.as_ref().is_none_or(|f| h >= f);
    if let Some(role) = r.roles.get(m).filter(|x| *x.read() != MemberRole::Member && *x.read() != MemberRole::Owner && inside(x.hlc())) {
        snap.roles.insert(m.to_string(), role.clone());
    }
    for (now, was) in [(&mut snap.nicknames, &r.nicknames), (&mut snap.twitch_usernames, &r.twitch_usernames)] {
        if let Some(v) = was.get(m).filter(|x| inside(x.hlc())) {
            now.insert(m.to_string(), v.clone());
        }
    }
    if let Some(v) = r.storage_pledges.get(m).filter(|x| inside(x.hlc())) {
        snap.storage_pledges.insert(m.to_string(), v.clone());
    }
}

/// R33-10 / R34-7 for one channel.
fn revert_channel_existence(snap: &mut ServerState, r: &ServerState, c: &str, lane: &Lane<'_>, held: &[CrdtOp]) -> bool {
    let Some(was) = r.channels.get(c) else {
        snap.channels.remove(c);
        snap.stamps.channels.remove(c);
        snap.pinned_messages.remove(c);
        return true;
    };
    let deleted = !snap.channels.contains_key(c);
    let mut ch = was.clone();
    let mut st = r.stamps.channels.get(c).cloned().unwrap_or_default();
    if deleted {
        ch.visibility = ChannelVisibility::AdminPlus;
        ch.posting = ChannelPosting::AdminPlus;
        ch.visibility_labels.clear();
        ch.posting_labels.clear();
        ch.is_public = false;
        let now = snap.stamps.channels.get(c).cloned().unwrap_or_default();
        (st.visibility, st.vis_labels, st.posting, st.post_labels) = (now.visibility, now.vis_labels, now.posting, now.post_labels);
        (st.public, st.set, st.set_vis, st.set_labels) = (now.public, now.set, now.set_vis, now.set_labels);
    }
    snap.channels.insert(c.to_string(), ch);
    snap.stamps.channels.insert(c.to_string(), st);
    let mut keys: Vec<ElementKey> =
        [ChannelField::Name, ChannelField::Slow, ChannelField::Media, ChannelField::Voice].into_iter().map(|f| ElementKey::ChannelField(c.to_string(), f)).collect();
    if !deleted {
        keys.extend(
            [ChannelField::Posting, ChannelField::Visibility, ChannelField::VisLabels, ChannelField::PostLabels]
                .into_iter()
                .map(|f| ElementKey::ChannelField(c.to_string(), f)),
        );
        keys.push(ElementKey::ChannelPublic(c.to_string()));
    }
    fold_held_onto(snap, &keys, lane, held);
    true
}

/// D35-1: a settling carries R's entries; those a device it drops signed are signed again
/// by the settler (they predate T), and what no counted owner device signed goes.
pub(crate) fn resign_for_settling(entries: &mut Vec<Refolded>, server: &str, dropped: &[String], device: &NativeKeypair, counts: &dyn Fn(&str) -> bool) {
    for e in entries.iter_mut() {
        let answer = e.valid_answer(server).cloned();
        if dropped.contains(&e.by) && e.sig_verifies(server) {
            e.sign(server, device);
        }
        match answer {
            Some(a) if dropped.contains(&a.by) => e.answer(server, device, a.undone, a.kept, a.put_back, a.timeout),
            Some(a) if counts(&a.by) => {}
            _ => e.answered = None,
        }
    }
    entries.retain(|e| e.sig_verifies(server) && counts(&e.by));
}

#[cfg(test)]
#[path = "refold_write_tests.rs"]
mod tests;
