//! A kick or ban voids the grants of its target that its author never saw (AR-11).
//!
//! A member removed at T still holds its key and can sign ops dated before T, when it was
//! a member: an admission of a puppet, a promotion, a grant. The removal names every
//! power-granting op of the target it had seen in the span it closes; a granting op of
//! the target dated inside that span, named nowhere and not decided by the remover's
//! base, is void at its own point in the fold. Ordinary acts (nicknames, a leave) still
//! fold, and a joiner whose admission is void asks again (the silent re-ask). Every 0.14
//! kick or ban carries its list (`with_seen`); one without (from before 0.14) voids nothing
//! while its op is retained.
//!
//! Residuals (design section 6, AR-11): a demotion closes no span, so a demoted admin can
//! still backdate a promotion to before its demotion; a leave carries no list, so grants
//! backdated into a span the member's own leave closed stand.

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

use super::fold::OpKey;
use super::hlc::HlcTimestamp;
use super::members::MemberEvent;
use super::operations::{CrdtOp, CrdtPayload as P, SeenGrants};
use super::server_state::ServerState;

/// The most ops one removal names (16 bytes, 32 hex each: about 36 KB), far inside
/// `fold::MAX_OP_BYTES`. Past it the removal names the newest and marks the rest by clock.
#[cfg(not(test))]
pub(crate) const SEEN_CAP: usize = 1024;
#[cfg(test)]
pub(crate) const SEEN_CAP: usize = 64;

/// An op of a kind that hands someone a power: an admission, a role change, a permission
/// or channel grant, a label given to someone else, a join lock move, a lifted ban.
pub(crate) fn grants_power(op: &CrdtOp) -> bool {
    match &op.payload {
        P::MemberAdded { .. }
        | P::RoleChanged { .. }
        | P::RolePermissionsChanged { .. }
        | P::ChannelGrantSet { .. }
        | P::JoinLock { .. }
        | P::MemberUnbanned { .. } => true,
        P::LabelAssigned { peer_id, .. } => *peer_id != op.author,
        _ => false,
    }
}

fn short(hash: &[u8; 32]) -> String {
    hex::encode(&hash[..16])
}

/// A removal of someone else: its target and what it names as seen.
fn removal(op: &CrdtOp) -> Option<(&str, Option<&SeenGrants>)> {
    match &op.payload {
        P::MemberRemoved { peer_id, seen } if *peer_id != op.author => Some((peer_id, seen.as_deref())),
        P::MemberBanned { peer_id, seen } => Some((peer_id, seen.as_deref())),
        _ => None,
    }
}

/// Whether a removal's list is one an honest remover writes.
pub(crate) fn seen_well_formed(seen: &SeenGrants) -> bool {
    let hex_of = |s: &str, n: usize| s.len() == n && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b));
    seen.ops.len() <= SEEN_CAP
        && seen.ops.iter().all(|h| hex_of(h, 32))
        && seen.base.as_ref().is_none_or(|(_, h)| hex_of(h, 64))
}

#[derive(Debug)]
struct Removal {
    at: HlcTimestamp,
    author: String,
    ban: bool,
    seen: Option<SeenGrants>,
}

/// The kicks, bans and admissions of a whole op set, by target: what a rebuild looks
/// ahead to, since a removal folds after the ops it voids.
#[derive(Debug, Default)]
pub struct Ahead {
    removals: HashMap<String, Vec<Removal>>,
    admits: HashMap<String, Vec<HlcTimestamp>>,
    leaves: HashMap<String, Vec<HlcTimestamp>>,
    /// The removals that voided an op in this pass: the rebuild keeps them only if they
    /// fold at their own point.
    voided_by: Mutex<HashSet<OpKey>>,
}

impl Ahead {
    /// The set's removals but those in `refused`, which failed at their own point.
    pub(crate) fn of<'a>(ops: impl Iterator<Item = &'a CrdtOp>, refused: &HashSet<OpKey>) -> Self {
        let mut a = Self::default();
        for op in ops {
            if let Some((target, seen)) = removal(op)
                && !refused.contains(&(op.author.clone(), op.hlc.clone()))
            {
                a.removals.entry(target.to_string()).or_default().push(Removal {
                    at: op.hlc.clone(),
                    author: op.author.clone(),
                    ban: matches!(op.payload, P::MemberBanned { .. }),
                    seen: seen.cloned(),
                });
            }
            match &op.payload {
                P::MemberAdded { peer_id, .. } => a.admits.entry(peer_id.clone()).or_default().push(op.hlc.clone()),
                P::MemberRemoved { peer_id, .. } if *peer_id == op.author => {
                    a.leaves.entry(peer_id.clone()).or_default().push(op.hlc.clone())
                }
                _ => {}
            }
        }
        a.removals.values_mut().for_each(|v| v.sort_by(|x, y| x.at.cmp(&y.at)));
        a
    }

    /// The removals that voided something in this pass.
    pub(crate) fn voided_by(&self) -> HashSet<OpKey> {
        self.voided_by.lock().map(|v| v.clone()).unwrap_or_default()
    }
}

/// One change to a member's record after an op, from the record or ahead in the set.
enum Step<'a> {
    Admit,
    Leave,
    /// A removal the record holds (decided by the base, its list gone with its op).
    Recorded,
    Ahead(&'a Removal),
}

impl ServerState {
    /// The `seen` a kick or ban of `target` carries: the target's power-granting ops this
    /// replica folded inside the target's last span, and the base that decides the rest.
    pub(crate) fn seen_grants(&self, target: &str) -> Box<SeenGrants> {
        let span = self.member_record.get(target).and_then(|s| s.last());
        let mut ops: Vec<&CrdtOp> = self
            .op_log
            .iter()
            .filter(|o| o.author == target && grants_power(o))
            .filter(|o| span.is_none_or(|s| super::members::span_contains(s, &o.hlc)))
            .collect();
        let base = self.base.as_ref().map(|b| (b.generation, b.hash_hex()));
        ops.sort_by(|a, b| b.hlc.cmp(&a.hlc));
        let before = (ops.len() > SEEN_CAP).then(|| ops[SEEN_CAP - 1].hlc.clone());
        ops.truncate(SEEN_CAP);
        Box::new(SeenGrants { base, ops: ops.iter().map(|o| short(&self.content_of(o))).collect(), before })
    }

    /// A kick or ban we author names what we saw of its target's grants.
    pub(crate) fn with_seen(&self, payload: P, me: &str) -> P {
        match payload {
            P::MemberRemoved { peer_id, seen: None } if peer_id != me => {
                let seen = Some(self.seen_grants(&peer_id));
                P::MemberRemoved { peer_id, seen }
            }
            P::MemberBanned { peer_id, seen: None } => {
                let seen = Some(self.seen_grants(&peer_id));
                P::MemberBanned { peer_id, seen }
            }
            other => other,
        }
    }

    /// A removal naming a base this replica cannot judge by (newer than ours, or a rival
    /// we lack): it waits until that base arrives rather than void what it may decide.
    pub(super) fn removal_unresolved(&self, op: &CrdtOp) -> bool {
        let Some((_, Some(seen))) = removal(op) else { return false };
        let Some((generation, hash)) = &seen.base else { return false };
        if self.base_by_hash(hash).is_some() {
            return false;
        }
        // An older generation is an ancestor of ours: it decides no more than ours does.
        self.base.as_ref().is_none_or(|b| *generation >= b.generation)
    }

    /// Whether a removal names `o` as seen: listed, before its cut, or decided by its base.
    /// A removal from before 0.14 carries no list and voids nothing: the kicks already in
    /// a server's history were honest, and voiding by them would unseat whom they admitted.
    fn seen_by(&self, seen: Option<&SeenGrants>, o: &CrdtOp) -> bool {
        let Some(seen) = seen else { return true };
        if seen.before.as_ref().is_some_and(|b| o.hlc < *b) || seen.ops.contains(&short(&self.content_of(o))) {
            return true;
        }
        let genesis = super::anchor::is_genesis_id(&self.server_id);
        seen.base.as_ref().and_then(|(_, h)| self.base_by_hash(h)).is_some_and(|b| b.judge().dominates(o, genesis))
    }

    /// Whether a removal ahead counts at `o`'s point: by someone who could kick the target
    /// then, and judged by a base we hold or an older one.
    fn counts(&self, r: &Removal, target: &str) -> bool {
        if r.author == target {
            return false;
        }
        if let Some((generation, hash)) = r.seen.as_ref().and_then(|s| s.base.as_ref())
            && self.base_by_hash(hash).is_none()
            && self.base.as_ref().is_none_or(|b| *generation >= b.generation)
        {
            return false;
        }
        self.can_kick_now(&r.author, target)
    }

    /// Whether `o` is a power-granting op of a member whose span a removal ends after it,
    /// and that removal did not see it. Read at `o`'s own point in the fold.
    pub(super) fn void_at_its_point(&self, o: &CrdtOp) -> bool {
        // A legacy anchor folds in arrival order, so "after" means nothing there.
        if !grants_power(o) || self.anchor() == super::server_state::Anchor::Legacy {
            return false;
        }
        let target = o.author.as_str();
        let events = self.events_of(target);
        let ahead = self.ahead.as_deref();
        let mut steps: Vec<(&HlcTimestamp, Step)> = events
            .iter()
            .filter(|e| e.at() > &o.hlc)
            .map(|e| {
                let step = match e {
                    MemberEvent::Admit { .. } => Step::Admit,
                    MemberEvent::Leave { .. } => Step::Leave,
                    MemberEvent::Remove { .. } => Step::Recorded,
                };
                (e.at(), step)
            })
            .collect();
        if let Some(a) = ahead {
            let after = |at: &&HlcTimestamp| **at > o.hlc;
            steps.extend(a.admits.get(target).into_iter().flatten().filter(after).map(|at| (at, Step::Admit)));
            steps.extend(a.leaves.get(target).into_iter().flatten().filter(after).map(|at| (at, Step::Leave)));
            steps.extend(
                a.removals.get(target).into_iter().flatten().filter(|r| r.at > o.hlc && self.counts(r, target)).map(|r| (&r.at, Step::Ahead(r))),
            );
        }
        steps.sort_by(|a, b| a.0.cmp(b.0));
        // The first leave or removal after the op ends its span; after the member's own
        // leave, a ban with no admission between closes that span too.
        let mut left = false;
        for (_, step) in steps {
            match step {
                Step::Admit if left => return false,
                Step::Admit => {}
                Step::Leave if left => return false,
                Step::Leave => left = true,
                Step::Recorded => return true,
                Step::Ahead(r) if left && !r.ban => return false,
                Step::Ahead(r) => {
                    let void = !self.seen_by(r.seen.as_ref(), o);
                    if void && let Some(Ok(mut by)) = ahead.map(|a| a.voided_by.lock()) {
                        by.insert((r.author.clone(), r.at.clone()));
                    }
                    return void;
                }
            }
        }
        false
    }

    /// A kick or ban at the tail: whether it voids an op already folded, so the caller
    /// rebuilds with it in view.
    pub(super) fn voids_folded(&self, r: &CrdtOp) -> bool {
        let Some((target, seen)) = removal(r) else { return false };
        self.op_log.iter().any(|o| o.author == target && o.hlc < r.hlc && grants_power(o) && !self.seen_by(seen, o))
    }
}
