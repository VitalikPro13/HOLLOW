//! The fold: a server's state as a pure function of the signed ops it holds.
//!
//! The base is the greatest checkpoint held; it is folded first (after a self-certifying
//! id's founding op), then every op the base does not dominate, in HLC order, each judged
//! by `op_allowed` against the state just before it (today's authority). An op the base
//! dominates drops at the door, or stays stored but unfolded when only the base and not
//! its parent decides it, so a step to a rival base loses nothing. Design E plus
//! checkpoint coverage, `reports/shipped/security/CHECKPOINT_COVERAGE_DESIGN.md`.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::{Duration, Instant};

use super::dominance::Judge;
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
pub(super) const CHECKPOINT_MIN_GAP_MS: u64 = 3600 * 1000;

/// How long a row a rebuild refuses stays stored, judged again at every rebuild.
pub(crate) const PARK_MS: u64 = 30 * 24 * 3600 * 1000;

/// HOL-SEC-222: founding ops of one id a replica holds at most: the one it founds on and
/// the best of each other device the view lists, so a view change can choose again.
pub(crate) const MAX_FOUNDING_KEPT: usize = 4;

/// The bytes of ops a base leaves undecided that one server folds (H3). Shared max-min
/// over the members of the anchor (the base, else the founding state), each with the tree
/// of authors its admissions rooted, plus one pool for authors rooted in nobody; within a
/// tree max-min again between a member's own ops and each subtree it admitted.
#[cfg(not(test))]
pub(crate) const QUOTA_BYTES: usize = 128 << 20;
#[cfg(test)]
pub(crate) const QUOTA_BYTES: usize = 192 << 10;
/// What every group keeps whatever the others want: 512 members at the floor leave
/// half the budget.
#[cfg(not(test))]
pub(crate) const QUOTA_FLOOR_BYTES: usize = 128 << 10;
#[cfg(test)]
pub(crate) const QUOTA_FLOOR_BYTES: usize = 8 << 10;
/// The pool of authors rooted in no member of the anchor.
#[cfg(not(test))]
pub(crate) const QUOTA_DEPARTED_BYTES: usize = 8 << 20;
#[cfg(test)]
pub(crate) const QUOTA_DEPARTED_BYTES: usize = 16 << 10;
/// Admissions, lock moves and sanctions by the anchor's moderators and above come first,
/// up to this in all, oldest first: joins and moderation never stop on a flood. With the
/// owner away it lasts as long as the staff's own acts fit (design section 8).
#[cfg(not(test))]
pub(crate) const QUOTA_LEADER_BYTES: usize = 64 << 20;
#[cfg(test)]
pub(crate) const QUOTA_LEADER_BYTES: usize = 64 << 10;
/// The signed bytes of one op, and of a checkpoint (whose state grows with the server:
/// about 0.75 MB for 512 identities): bigger ones are refused at the door, whoever signs
/// them. Every honest op but a checkpoint is a few KB (a 64-grant lock move about 12 KB, a
/// kick naming 1,024 grants about 36 KB).
pub(crate) const MAX_OP_BYTES: usize = 1 << 20;
pub(crate) const MAX_CHECKPOINT_BYTES: usize = 16 << 20;
/// Undominated `DeviceRetired` ops one author keeps (section 14).
pub(crate) const MAX_UNDOMINATED_RETIRES: usize = 64;
/// Tail retires one author may rebuild the state with per window; the rest wait in
/// `held` for the node's coalesced rebuild (section 14).
pub(crate) const RETIRE_REBUILDS_PER_AUTHOR: u32 = 4;
const RETIRE_REBUILD_WINDOW_MS: u64 = 60_000;

#[derive(Debug, Clone, Default)]
pub(crate) struct RetireRebuilds {
    window_ms: u64,
    spent: HashMap<String, u32>,
    due: bool,
}

impl RetireRebuilds {
    /// Whether a tail retire by `author` may rebuild now (charged when it may).
    fn charge(&mut self, author: &str, now_ms: u64) -> bool {
        if now_ms.saturating_sub(self.window_ms) >= RETIRE_REBUILD_WINDOW_MS {
            self.window_ms = now_ms;
            self.spent.clear();
        }
        let spent = self.spent.entry(author.to_string()).or_default();
        if *spent >= RETIRE_REBUILDS_PER_AUTHOR {
            self.due = true;
            return false;
        }
        *spent += 1;
        true
    }
}

/// Settle marks a server keeps, and signatures per mark (section 14).
pub(crate) const MAX_SETTLE_MARKS: usize = 32;
pub(crate) const MAX_SETTLE_SIGS: usize = 8;
/// Bytes of the checkpoints held only as the marks' pinned parents, per server.
#[cfg(not(test))]
pub(crate) const SETTLE_PIN_BYTES: usize = 32 << 20;
#[cfg(test)]
pub(crate) const SETTLE_PIN_BYTES: usize = 32 << 10;

/// The settle marks of one plan (section 7).
#[derive(Debug, Default)]
struct Marks {
    /// `SettleSign` entries stored as rows.
    kept: HashSet<usize>,
    /// Parent checkpoints the kept marks pin.
    pins: HashSet<[u8; 32]>,
    /// The greatest counted mark: its id, its parent, and the parent's lineage.
    line: Option<(String, [u8; 32], HashSet<String>)>,
}

/// Floor marks one author keeps, distinct checkpoints they may name, authors per server
/// (section 8.8 items 3 and 7).
pub(crate) const MAX_FLOOR_MARKS_PER_AUTHOR: usize = 4;
pub(crate) const MAX_FLOOR_CPS: usize = 32;
#[cfg(not(test))]
pub(crate) const MAX_FLOOR_AUTHORS: usize = 512;
#[cfg(test)]
pub(crate) const MAX_FLOOR_AUTHORS: usize = 16;
#[cfg(not(test))]
pub(crate) const FLOOR_PIN_BYTES: usize = 64 << 20;
#[cfg(test)]
pub(crate) const FLOOR_PIN_BYTES: usize = 64 << 10;

/// One floor mark in a plan: its index, the checkpoint it names, whether it counts.
type FloorEntry<'a> = (usize, &'a Base, bool);

/// The floor marks of one plan (section 8.8).
#[derive(Debug, Default)]
struct Floor {
    /// `FloorMark` entries stored as rows.
    kept: HashSet<usize>,
    /// Checkpoints the kept marks name.
    pins: HashSet<[u8; 32]>,
    /// The floor F0 and its held ancestors: eligible by rule 4 alone.
    eligible: HashSet<[u8; 32]>,
}

#[derive(Debug)]
struct Mark {
    id: String,
    generation: u64,
    parent: String,
    /// (entry index, signing device), counted signers first, then by device.
    sigs: Vec<(usize, String)>,
    counted: Vec<String>,
    pin_bytes: usize,
}

/// Rebuild passes that drop removals refused at their own point (`install`).
const VOID_PASSES: usize = 4;

/// Parked rows one group keeps, oldest first; past it a row is deleted.
#[cfg(not(test))]
pub(crate) const PARK_GROUP_BYTES: usize = 128 << 10;
#[cfg(test)]
pub(crate) const PARK_GROUP_BYTES: usize = 8 << 10;
/// Admission chains deeper than this charge the pool.
const MAX_DEPTH: usize = 64;
/// The charge parent of authors no member of the anchor roots. Never a peer id.
const POOL: &str = "";

/// An op's dedup key.
pub type OpKey = (String, HlcTimestamp);
/// An own row's key as the store keeps it: (author, clock ms, counter).
pub type OwnKey = (String, u64, u32);

/// Own rows a server keeps at most (section 14, decision 2, revision 3.1).
pub(crate) const OWN_MAX_OPS: usize = 16_384;
pub(crate) const OWN_MAX_BYTES: usize = 64 << 20;
/// How long an own row outlives its first domination.
pub(crate) const OWN_KEEP_MS: u64 = 30 * 86_400_000;

/// Of own rows `(first dominated ms, bytes)`, the indexes that go so at most `max_ops`
/// and `max_bytes` stay: the earliest dominated first.
/// Two checkpoints on one line by `cp_lineage` (section 8.8 item 5).
fn one_line(a: &Base, b: &Base) -> bool {
    a.hash == b.hash || a.state.cp_lineage.contains(&b.hash_hex()) || b.state.cp_lineage.contains(&a.hash_hex())
}

/// The lowest pair, in `sorted`'s order, of checkpoints not on one line.
fn lowest_off_line(sorted: &[&Base]) -> Option<(usize, usize)> {
    (1..sorted.len()).find_map(|j| (0..j).find(|&i| !one_line(sorted[i], sorted[j])).map(|i| (i, j)))
}

pub(crate) fn own_over_bound(rows: &[(u64, usize)], max_ops: usize, max_bytes: usize) -> Vec<usize> {
    let mut order: Vec<usize> = (0..rows.len()).collect();
    order.sort_by_key(|&i| (rows[i].0, i));
    let (mut n, mut bytes) = (rows.len(), rows.iter().map(|r| r.1).sum::<usize>());
    let mut out = Vec::new();
    for i in order {
        if n <= max_ops && bytes <= max_bytes {
            break;
        }
        n -= 1;
        bytes -= rows[i].1;
        out.push(i);
    }
    out.sort_unstable();
    out
}

/// What a stored row is written with: content hash, parked mark, proving device.
type RowMark = ([u8; 32], Option<u64>, Option<String>);

/// A stored row the fold does not apply.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RowKind {
    /// The base's parent checkpoint: what tells dormant ops from decided ones.
    Parent,
    /// Decided by the base but not by its parent, or a rival checkpoint above the parent.
    Dormant,
    /// Once admitted and refused now, until this epoch ms: judged again at every rebuild.
    Parked(u64),
    /// The lowest owner-signed stamped checkpoint the base order would drop: what keeps
    /// the cut a fact of held rows (DEVICE_PROOF_DESIGN section 7). Compared, never folded.
    CutMark,
    /// A checkpoint this replica once folded as its base, kept as a restore point
    /// (section 7): local, never folded, never in the digest or a page.
    Restore,
    /// One device's signature of a settling (`CrdtPayload::SettleSign`): with the others
    /// of its settling id, the settle mark (section 7). Never folded.
    SettleSign,
    /// The parent checkpoint a held settle mark names, kept while the mark is.
    SettlePin,
    /// A member's floor mark (`CrdtPayload::FloorMark`, section 8.8). Never folded.
    FloorMark,
    /// The checkpoint a held floor mark names, kept while the mark is.
    FloorPin,
    /// R or the DR an unanswered `cp_refolded` entry of the base names (section 8.3); the
    /// DR also for 30 days after its entry's `at`.
    RefoldPin,
    /// Our own identity's op both the base and its parent decide, kept on our own
    /// devices for 30 days from its first domination (section 7, N6): what folds again
    /// after a step back. Never folded or served.
    Own,
}

impl RowKind {
    /// The `parked_until` a row of this kind is stored with.
    pub fn parked_until(&self) -> Option<u64> {
        match self {
            Self::Parked(until) => Some(*until),
            _ => None,
        }
    }

    /// Whether the digest and whole-log pages compare and serve the row.
    pub fn served(&self) -> bool {
        !matches!(self, Self::Parked(_) | Self::Restore | Self::Own)
    }
}

const DAY_MS: u64 = 86_400_000;

/// Section 7: of the checkpoints a replica folded as its base, `(index, first_fold_ms)`,
/// the newest and the oldest first folded in each window of age: the last day, 1 to 7
/// days, 7 to 30 days, older.
pub(crate) fn restore_picks(candidates: &[(usize, u64)], now_ms: u64) -> Vec<usize> {
    let window = |first: u64| match now_ms.saturating_sub(first) {
        a if a < DAY_MS => 0,
        a if a < 7 * DAY_MS => 1,
        a if a < 30 * DAY_MS => 2,
        _ => 3,
    };
    let mut picks = Vec::new();
    for w in 0..4 {
        let mut inside: Vec<&(usize, u64)> = candidates.iter().filter(|(_, f)| window(*f) == w).collect();
        inside.sort_by_key(|(i, f)| (*f, *i));
        picks.extend(inside.first().map(|(i, _)| *i));
        picks.extend(inside.last().map(|(i, _)| *i));
    }
    picks.sort_unstable();
    picks.dedup();
    picks
}

/// A checkpoint as a fold base, its state parsed once.
#[derive(Debug, Clone)]
pub struct Base {
    pub hash: [u8; 32],
    pub hlc: HlcTimestamp,
    pub covers: HlcTimestamp,
    pub generation: u64,
    pub parent: Option<[u8; 32]>,
    pub state: Arc<ServerState>,
}

impl Base {
    /// The base order: generation, the op's clock, then its content hash.
    fn key(&self) -> (u64, &HlcTimestamp, &[u8; 32]) {
        (self.generation, &self.hlc, &self.hash)
    }

    pub(crate) fn judge(&self) -> Judge<'_> {
        Judge {
            state: &self.state,
            covers: (!self.state.cp_stamped).then_some(&self.covers),
            floor: self.state.cp_floor.as_ref(),
            parent_retired: &[],
        }
    }

    /// `judge` for this base standing on `parent`, which decides the retires it lists too.
    pub(crate) fn judge_over<'a>(&'a self, parent: Option<&'a Base>) -> Judge<'a> {
        Judge { parent_retired: parent.map_or(&[][..], |p| p.state.cp_retired.as_slice()), ..self.judge() }
    }

    pub fn hash_hex(&self) -> String {
        hex::encode(self.hash)
    }
}

/// The store rows an ingest changes: written (new or changed, with their parked mark)
/// and deleted. Applied in one transaction (`MessageStore::persist_op_delta`).
#[derive(Debug, Clone, Default)]
pub struct OpDelta {
    pub server_id: String,
    pub rows: Vec<(CrdtOp, Option<u64>)>,
    pub dropped: Vec<OpKey>,
    /// The base after a rebuild (content id hex): its first fold is noted once (`cp_seen`).
    pub base: Option<String>,
    /// The first folds still kept after a rebuild; every other `cp_seen` row goes.
    pub seen_keep: Option<Vec<String>>,
    /// Own rows' first domination (`own_kept`): set, or cleared with `None`.
    pub own_since: Vec<(OwnKey, Option<u64>)>,
    /// The `floor_pending` row (section 8.8): written, or cleared with `None`.
    pub recovery: Option<Option<String>>,
}

impl OpDelta {
    pub fn is_empty(&self) -> bool {
        self.rows.is_empty() && self.dropped.is_empty() && self.base.is_none() && self.recovery.is_none()
    }
}

/// What a restart did with the stored rows.
#[derive(Debug, Default)]
pub struct Restored {
    /// The rows folded into another set than the saved state names: save the state.
    pub refolded: bool,
    /// Rows to delete: parked past their time, or over their group's bound.
    pub dropped: Vec<OpKey>,
    /// A recovery the restart itself opened (HOL-SEC-232): the `floor_pending` row to save.
    pub recovery: Option<String>,
}

/// What an ingest did.
#[derive(Debug, Default)]
pub struct Ingested {
    /// Ops that folded for the first time: the ones to emit and pass on.
    pub admitted: Vec<CrdtOp>,
    /// Every row to write: the admitted ops and the rows that are kept unfolded.
    pub rows: Vec<(CrdtOp, Option<u64>)>,
    /// Rows to delete: decided by the base and its parent alike.
    pub dropped: Vec<OpKey>,
    /// Ops refused (forged, foreign, future-dated, or not allowed at their point).
    pub rejected: usize,
    /// The state was rebuilt from its anchor, so anything may have changed.
    pub rebuilt: bool,
    /// Authors whose ops the device clause refused as `Missing` or `Uncounted`: whose
    /// rosters to ask for (section 9).
    pub wanted: std::collections::BTreeSet<String>,
    /// A rebuild's base (content id hex).
    pub base: Option<String>,
    /// The first folds a rebuild keeps (section 14: the base's lineage and the restore points).
    pub seen_keep: Option<Vec<String>>,
    /// What the rebuild changed in our own rows' first domination.
    pub own_since: Vec<(OwnKey, Option<u64>)>,
    /// A recovery began here (the row) or ended (`Some(None)`), section 8.8.
    pub recovery: Option<Option<String>>,
}

impl Ingested {
    /// The store rows to change, `None` when nothing does.
    pub fn delta(&self, server_id: &str) -> Option<OpDelta> {
        let d = OpDelta {
            server_id: server_id.to_string(),
            rows: self.rows.clone(),
            dropped: self.dropped.clone(),
            base: self.base.clone(),
            seen_keep: self.seen_keep.clone(),
            own_since: self.own_since.clone(),
            recovery: self.recovery.clone(),
        };
        (!d.is_empty()).then_some(d)
    }
}

/// Where one op goes in a rebuild.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Class {
    Founding,
    Base,
    Fold,
    Row(RowKind),
    /// Over its group's quota: a row stays parked until then, unjudged.
    Over(u64),
    Held,
    Drop,
}

/// A rebuild's input, classified against the base it picked.
struct Plan {
    ops: Vec<(CrdtOp, [u8; 32], Class, bool)>,
    base: Option<Base>,
    parent: Option<Base>,
    quota: Quota,
    cut: bool,
    /// The `cp_roster` of every held checkpoint that verifies as a base.
    rosters: Vec<crate::identity::roster::Roster>,
    /// Counted settlings off the base's line naming devices it does not drop.
    rivals: Vec<super::operations::SettleStamp>,
    /// Own rows first dominated in this plan, dated.
    own_new: Vec<(OwnKey, u64)>,
    /// The base before this plan is still eligible in it (section 8.8's trigger).
    old_eligible: bool,
    /// A counted settle mark decides eligibility.
    settled: bool,
    /// The base is eligible by rule 4 alone (section 8.8 item 6).
    floor_base: bool,
}

/// A tail op's quota verdict, the one a rebuild of the same set gives.
enum Tail {
    Within,
    Over,
    Rebuild,
}

/// The quota allocation of an op set, kept so a tail op is judged without a rebuild.
/// A pure function of the set; `tail` keeps it so (see there).
#[derive(Debug, Clone, Default)]
pub(crate) struct Quota {
    computed: bool,
    /// The anchor's members: each tops a charge tree.
    roots: HashSet<String>,
    /// Each other author's charge parent: who signed its earliest undecided admission
    /// (`POOL` for a chain that reaches no root).
    up: HashMap<String, String>,
    /// The anchor's owner, whose ops no quota charges: it compacts its own log.
    owner: Option<String>,
    /// The anchor's moderators and above, with their rank there, as the owner's own role
    /// changes in the set leave them.
    staff: HashMap<String, u8>,
    /// Bytes per author of every undecided op not exempt, and of those within its share:
    /// the oldest first, up to the first that does not fit.
    demand: HashMap<String, usize>,
    used: HashMap<String, usize>,
    lead_used: usize,
    /// Ops in `held` because they were over their author's share.
    over_held: HashSet<OpKey>,
}

impl Quota {
    fn avail(&self) -> usize {
        QUOTA_BYTES.saturating_sub(self.lead_used)
    }

    fn total(&self) -> usize {
        self.demand.values().sum()
    }

    /// Whether `author` already has an op over its share: every newer one is too.
    fn over(&self, author: &str) -> bool {
        self.used.get(author).copied().unwrap_or(0) < self.demand.get(author).copied().unwrap_or(0)
    }

    /// An owner's role change moves who is staff.
    fn restaff(&mut self, op: &CrdtOp) -> bool {
        let CrdtPayload::RoleChanged { peer_id, role, .. } = &op.payload else { return false };
        if self.owner.as_deref() != Some(op.author.as_str()) {
            return false;
        }
        let was = self.staff.get(peer_id).copied();
        if role.priority() >= super::operations::MemberRole::Moderator.priority() {
            self.staff.insert(peer_id.clone(), role.priority());
        } else {
            self.staff.remove(peer_id);
        }
        was != self.staff.get(peer_id).copied()
    }

    /// Whether `op` goes ahead of every share: a staff admission, lock move, kick, ban,
    /// mute or demotion.
    fn first(&self, op: &CrdtOp) -> bool {
        if !self.staff.contains_key(&op.author) {
            return false;
        }
        match &op.payload {
            CrdtPayload::MemberAdded { .. }
            | CrdtPayload::JoinLock { .. }
            | CrdtPayload::MemberBanned { .. }
            | CrdtPayload::MemberMuted { .. } => true,
            CrdtPayload::MemberRemoved { peer_id, .. } => *peer_id != op.author,
            CrdtPayload::RoleChanged { peer_id, role, .. } => {
                role.priority() < self.staff.get(peer_id).copied().unwrap_or(super::operations::MemberRole::Member.priority())
            }
            _ => false,
        }
    }

    /// The tree top `author` charges: a root, or the pool.
    fn top(&self, author: &str) -> String {
        let mut at = author;
        for _ in 0..=MAX_DEPTH {
            if self.roots.contains(at) || at == POOL {
                return at.to_string();
            }
            match self.up.get(at) {
                Some(p) => at = p,
                None => break,
            }
        }
        POOL.to_string()
    }

    /// Point every chain at a root or the pool: one that ends short of a root, runs too
    /// deep or loops charges the pool from where it broke.
    fn resolve(&mut self) {
        let mut authors: Vec<String> = self.demand.keys().chain(self.up.keys()).cloned().collect();
        authors.sort();
        authors.dedup();
        for a in authors {
            let mut at = a.clone();
            let mut steps = 0;
            while !self.roots.contains(&at) && at != POOL {
                match self.up.get(&at) {
                    Some(p) if steps < MAX_DEPTH => {
                        at = p.clone();
                        steps += 1;
                    }
                    Some(_) => {
                        self.up.insert(a.clone(), POOL.to_string());
                        break;
                    }
                    None => {
                        self.up.insert(at.clone(), POOL.to_string());
                        break;
                    }
                }
            }
        }
    }

    /// A new author's place in the tree, as `resolve` would give it.
    fn place(&mut self, author: &str) {
        if !self.roots.contains(author) && !self.up.contains_key(author) {
            self.up.insert(author.to_string(), POOL.to_string());
        }
    }

    /// Every author's share: max-min with the floor over the roots and the capped pool,
    /// then within each node max-min (no floor) between its own ops and each subtree.
    fn shares(&self) -> HashMap<String, usize> {
        let mut kids: HashMap<&str, Vec<&str>> = HashMap::new();
        for (a, p) in &self.up {
            kids.entry(p.as_str()).or_default().push(a.as_str());
        }
        let mut sub: HashMap<&str, usize> = HashMap::new();
        for (a, d) in &self.demand {
            let mut at = a.as_str();
            for _ in 0..=MAX_DEPTH + 1 {
                *sub.entry(at).or_default() += d;
                if self.roots.contains(at) || at == POOL {
                    break;
                }
                match self.up.get(at) {
                    Some(p) => at = p,
                    None => break,
                }
            }
        }
        let mut tops: Vec<(&str, usize)> =
            self.roots.iter().map(|r| (r.as_str(), sub.get(r.as_str()).copied().unwrap_or(0))).filter(|t| t.1 > 0).collect();
        if let Some(d) = sub.get(POOL) {
            tops.push((POOL, (*d).min(QUOTA_DEPARTED_BYTES)));
        }
        tops.sort();
        let got = fill(&tops, self.avail(), QUOTA_FLOOR_BYTES);
        let mut out = HashMap::new();
        let mut stack: Vec<(&str, usize)> = tops.iter().map(|t| t.0).zip(got).collect();
        while let Some((node, share)) = stack.pop() {
            let mut children: Vec<&str> = kids.get(node).cloned().unwrap_or_default();
            children.sort();
            let own = if node == POOL { 0 } else { self.demand.get(node).copied().unwrap_or(0) };
            let items: Vec<(&str, usize)> =
                std::iter::once((node, own)).chain(children.iter().map(|c| (*c, sub.get(c).copied().unwrap_or(0)))).collect();
            let got = fill(&items, share, 0);
            out.insert(node.to_string(), got[0]);
            stack.extend(children.into_iter().zip(got.into_iter().skip(1)));
        }
        out
    }

    /// Whether every author's within bytes still fit its share.
    fn fits(&self, shares: &HashMap<String, usize>) -> bool {
        self.used.iter().all(|(a, u)| *u <= shares.get(a).copied().unwrap_or(0))
    }

    /// Charge a tail op: the newest of the set, so it comes last in every order the
    /// allocation uses. It changes nobody's within ops unless the shares move below one
    /// (then the caller rebuilds); an author already over its share stays over (a demand
    /// at or above the level moves no level), so a flood costs no rebuild.
    fn tail(&mut self, op: &CrdtOp) -> Tail {
        // The founding op of a book computed before it held one: the anchor is its owner.
        if let CrdtPayload::ServerCreated { owner_peer_id, .. } = &op.payload {
            if self.owner.is_none() && self.roots.is_empty() && op.author == *owner_peer_id {
                self.owner = Some(owner_peer_id.clone());
                self.roots.insert(owner_peer_id.clone());
                self.staff.insert(owner_peer_id.clone(), super::operations::MemberRole::Owner.priority());
                return Tail::Within;
            }
            return Tail::Rebuild;
        }
        let size = op_size(op);
        if let CrdtPayload::MemberAdded { peer_id, .. } = &op.payload
            && *peer_id != op.author
            && !self.roots.contains(peer_id)
        {
            match self.up.get(peer_id) {
                Some(p) if p == POOL => return Tail::Rebuild,
                Some(_) => {}
                None if self.demand.get(peer_id).is_some_and(|d| *d > 0) => return Tail::Rebuild,
                None => {
                    self.place(&op.author);
                    self.up.insert(peer_id.clone(), op.author.clone());
                }
            }
        }
        if self.owner.as_deref() == Some(op.author.as_str()) {
            return if self.restaff(op) { Tail::Rebuild } else { Tail::Within };
        }
        if self.first(op) && self.lead_used + size <= QUOTA_LEADER_BYTES {
            self.lead_used += size;
            if self.total() > self.avail() && !self.fits(&self.shares()) {
                return Tail::Rebuild;
            }
            return Tail::Within;
        }
        self.place(&op.author);
        let author = op.author.clone();
        if self.over(&author) {
            *self.demand.entry(author).or_default() += size;
            return Tail::Over;
        }
        *self.demand.entry(author.clone()).or_default() += size;
        if self.total() <= self.avail() {
            *self.used.entry(author).or_default() += size;
            return Tail::Within;
        }
        let shares = self.shares();
        if !self.fits(&shares) {
            return Tail::Rebuild;
        }
        let used = self.used.entry(author.clone()).or_default();
        if *used + size <= shares.get(&author).copied().unwrap_or(0) {
            *used += size;
            Tail::Within
        } else {
            Tail::Over
        }
    }

    /// An op left `held`: an over op of an author still over changes no share; any other
    /// leaves the book to be judged again.
    fn forget(&mut self, op: &CrdtOp) {
        let key = (op.author.clone(), op.hlc.clone());
        if self.over_held.remove(&key) {
            if let Some(d) = self.demand.get_mut(&op.author) {
                *d = d.saturating_sub(op_size(op));
            }
            if self.over(&op.author) {
                return;
            }
        }
        self.computed = false;
    }
}

/// Max-min shares of `avail` for `items`, each at least the least of its demand and
/// `floor` (when the floors fit). Every item over the level gets exactly the level, so
/// raising such an item's demand moves nothing: what `Quota::tail` relies on.
fn fill(items: &[(&str, usize)], avail: usize, floor: usize) -> Vec<usize> {
    let mut out: Vec<usize> = items.iter().map(|t| t.1.min(floor)).collect();
    let floors: usize = out.iter().sum();
    let mut left = if floors <= avail {
        avail - floors
    } else {
        out.iter_mut().for_each(|o| *o = 0);
        avail
    };
    let rest: Vec<usize> = items.iter().zip(&out).map(|(t, o)| t.1 - o).collect();
    let mut idx: Vec<usize> = (0..items.len()).collect();
    idx.sort_by_key(|&i| (rest[i], i));
    for (k, &i) in idx.iter().enumerate() {
        let level = left / (idx.len() - k);
        if rest[i] <= level {
            out[i] += rest[i];
            left -= rest[i];
        } else {
            for &j in &idx[k..] {
                out[j] += level;
            }
            break;
        }
    }
    out
}

/// What an op weighs against the quota.
/// Whether a checkpoint carrying `state` signs within `MAX_CHECKPOINT_BYTES`: the state
/// rides as a JSON string (each quote and backslash escaped once more) next to the
/// server id, clock, author and covers, far inside the margin.
pub(super) fn checkpoint_fits(state: &str) -> bool {
    const MARGIN: usize = 16 << 10;
    let escapes = state.bytes().filter(|b| matches!(b, b'"' | b'\\')).count();
    state.len() + escapes + MARGIN <= MAX_CHECKPOINT_BYTES
}

fn op_size(op: &CrdtOp) -> usize {
    serde_json::to_string(op).map_or(0, |j| j.len())
}

impl ServerState {
    /// Author an op on our own replica, judged by the SAME predicate every receiver
    /// runs, so we never apply or send an op honest peers refuse. `None` = refused.
    pub fn author_checked(&mut self, payload: CrdtPayload) -> Option<CrdtOp> {
        let me = self.hlc.as_ref().map(|h| h.actor().to_string()).unwrap_or_default();
        let payload = self.with_seen(payload, &me);
        let op = self.create_op(payload);
        let probe = op.clone();
        self.fill_view(std::iter::once(&probe));
        if !self.op_allowed(&op) {
            crate::hollow_log!(
                "[HOLLOW-CRDT] Not authoring {} in {}: our own rules refuse it",
                payload_name(&op.payload), self.server_id,
            );
            return None;
        }
        if matches!(op.payload, CrdtPayload::ServerCheckpoint { .. }) {
            return self.author_checkpoint_op(op).map(|(op, _)| op);
        }
        // Our own op is charged like anyone's: past our share it would be folded here and
        // held everywhere else.
        // A retire ranks first in our group (section 14): the next ingest's rebuild places it.
        if matches!(op.payload, CrdtPayload::DeviceRetired { .. }) {
            self.quota.computed = false;
        } else if self.anchor() != Anchor::Legacy {
            match if self.quota_ready() { self.quota.tail(&op) } else { Tail::Rebuild } {
                Tail::Over => {
                    crate::hollow_log!("[HOLLOW-CRDT] Not authoring {} in {}: over our share", payload_name(&op.payload), self.server_id);
                    return None;
                }
                // The next ingest rebuilds against the set this op joins.
                Tail::Rebuild => self.quota.computed = false,
                Tail::Within => {}
            }
        }
        let _ = self.apply_op(&op);
        Some(op)
    }

    /// Author our checkpoint: through the fold, since a new base rebuilds the state and
    /// changes which rows the store keeps. `None` when it did not become the base.
    pub fn author_checkpoint(&mut self, payload: CrdtPayload) -> Option<(CrdtOp, Ingested)> {
        let op = self.create_op(payload);
        if !self.op_allowed(&op) {
            return None;
        }
        self.author_checkpoint_op(op)
    }

    fn author_checkpoint_op(&mut self, op: CrdtOp) -> Option<(CrdtOp, Ingested)> {
        let ingested = self.fold_remote(std::slice::from_ref(&op));
        let ours = self.base.as_ref().is_some_and(|b| b.hlc == op.hlc && b.hash == op.content_hash());
        ours.then_some((op, ingested))
    }

    /// Author the checkpoint `checkpoint_due` says we owe. A state whose checkpoint would
    /// pass `MAX_CHECKPOINT_BYTES` (every receiver refuses it) is measured before it is
    /// signed, and a try that is not kept waits `CHECKPOINT_MIN_GAP_MS` for the next.
    pub fn author_due_checkpoint(&mut self, me: &str, past_authors: &[String], now_ms: u64) -> Option<(CrdtOp, Ingested)> {
        let kept = self
            .checkpoint_json(me, past_authors, now_ms)
            .filter(|json| checkpoint_fits(json))
            .and_then(|state| {
                let covers = self.checkpoint_covers();
                self.author_checkpoint(CrdtPayload::ServerCheckpoint { state, covers })
            });
        if kept.is_none() {
            self.cp_retry_at_ms = now_ms.saturating_add(CHECKPOINT_MIN_GAP_MS);
        }
        kept
    }

    /// Whether the owner (`me`) owes this server a checkpoint now: once to move it off
    /// the legacy anchor or off a base from before 0.14, then whenever its log has grown
    /// past `CHECKPOINT_AFTER_OPS`, at most once an hour after the base's own clock. On a
    /// cut server also soon after its first change (part C: members then hold a base the
    /// 8.8 hold and floor protect), then hourly while authority changes arrive. Never
    /// while a device of ours that proved a held op of ours waits for its settling: a
    /// checkpoint then would bake the step back in (`settle_owed`).
    pub fn checkpoint_due(&self, me: &str, now_ms: u64) -> bool {
        if self.deleted || now_ms < self.cp_retry_at_ms || self.current_owner().as_deref() != Some(me) || self.settle_owed(me) {
            return false;
        }
        match self.anchor() {
            Anchor::Legacy => true,
            _ if self.base.as_ref().is_some_and(|b| !b.state.cp_stamped) => true,
            _ => {
                (self.op_log.len() > CHECKPOINT_AFTER_OPS
                    && self.base.as_ref().is_none_or(|b| now_ms.saturating_sub(b.hlc.physical_ms) > CHECKPOINT_MIN_GAP_MS))
                    || self.refold_due(now_ms)
                    || self.early_checkpoint_due(now_ms)
            }
        }
    }

    /// Part C (HOL-SEC-230): with the cut in force, the first checkpoint follows the
    /// first change past the founding op, a later one an authority change past the base
    /// once the base is an hour old. Only `cadence_op`s count: posts' pins, lock moves
    /// and marks never checkpoint an idle server, so the 64-generation lineage spans the
    /// server's authority history rather than its traffic.
    fn early_checkpoint_due(&self, now_ms: u64) -> bool {
        #[cfg(test)]
        if self.anchor_owner().is_some_and(|o| EARLY_OFF_OWNERS.lock().unwrap_or_else(|e| e.into_inner()).contains(&o)) {
            return false;
        }
        if !self.cut {
            return false;
        }
        match &self.base {
            None => self.op_log.iter().any(|o| cadence_op(&o.payload)),
            Some(b) => now_ms.saturating_sub(b.hlc.physical_ms) > CHECKPOINT_MIN_GAP_MS && self.op_log.iter().any(|o| o.hlc > b.hlc && cadence_op(&o.payload)),
        }
    }

    /// A device of `me` that proved a held op of ours is uncounted and nothing decides it
    /// (no counted retire of ours, no settling on the base's line drops it): our own
    /// recovery still owes its settling here.
    pub(crate) fn settle_owed(&self, me: &str) -> bool {
        let all = || self.op_log.iter().chain(self.stored.iter().map(|(o, _)| o));
        let deciders = Self::deciders(all());
        let mut seen: HashSet<&str> = HashSet::new();
        all().filter(|o| o.author == me).filter_map(|o| o.proven_device()).any(|d| {
            d != me && seen.insert(d) && !self.device_decided(&deciders, self.base.as_deref(), Some(me), me, d)
        })
    }

    /// Writer rule (F1 mitigation a, M1): the owner checkpoints only once completed digest
    /// rounds since its last connect came from two other identities, one of them a
    /// moderator or above, or two whose admissions root in different members of the base
    /// other than the owner: the owner answers anyone's join, so an identity it admitted
    /// is free, and one withholding member with puppets it admitted decides nothing. Or
    /// from every other member (a small server). A legacy anchor syncs by state vector
    /// and is exempt.
    pub fn checkpoint_witnessed(&self, me: &str, witnesses: &HashSet<String>) -> bool {
        if self.anchor() == Anchor::Legacy {
            return true;
        }
        let others: Vec<&String> = self.members.keys().filter(|m| m.as_str() != me).collect();
        // A fold that lists only us witnesses nothing: a stepped-back fold looks like it.
        if others.is_empty() {
            return false;
        }
        if others.iter().all(|m| witnesses.contains(m.as_str())) {
            return true;
        }
        let heard: Vec<&String> = others.into_iter().filter(|m| witnesses.contains(m.as_str())).collect();
        if heard.len() < 2 {
            return false;
        }
        let staff = |m: &str| self.get_role(m).priority() >= super::operations::MemberRole::Moderator.priority();
        let roots: HashSet<String> = heard.iter().filter_map(|m| self.lineage_root(m, me)).collect();
        heard.iter().any(|m| staff(m)) || roots.len() >= 2
    }

    /// The member of the base whose admissions `member`'s own rest on, through the
    /// earliest admitter of each span; `None` when the chain reaches the owner (`me`).
    fn lineage_root(&self, member: &str, me: &str) -> Option<String> {
        let base = self.base.as_ref()?;
        let mut at = member.to_string();
        for _ in 0..=MAX_DEPTH {
            if at == me {
                return None;
            }
            if base.state.members.contains_key(&at) {
                return Some(at);
            }
            let span = self.member_record.get(&at).and_then(|s| s.last())?;
            at = span.admitted.iter().min_by(|a, b| a.1.cmp(&b.1))?.0.clone();
        }
        None
    }

    /// M2: a rebuild refused our own admission and nothing removed us after it (a removal
    /// or ban of us closes a span at its own clock, so it is never mistaken for this): we
    /// hold that admission parked and are no member now. The node asks to join again.
    pub fn refused_own_admission(&self, us: &str) -> bool {
        if self.deleted || self.is_member(us) || self.is_banned(us) {
            return false;
        }
        let removed_after = |at: &HlcTimestamp| {
            self.events_of(us).iter().any(|e| matches!(e, super::members::MemberEvent::Leave { at: r } | super::members::MemberEvent::Remove { at: r } if r > at))
        };
        self.stored.iter().any(|(op, kind)| {
            matches!(kind, RowKind::Parked(_))
                && matches!(&op.payload, CrdtPayload::MemberAdded { peer_id, .. } if peer_id == us)
                && !removed_after(&op.hlc)
        })
    }

    /// The `covers` a new checkpoint carries: one step past its parent's, so a 0.13
    /// replica, which prunes everything at or below it, keeps what it can.
    pub fn checkpoint_covers(&self) -> HlcTimestamp {
        if self.base.is_none() && self.anchor() == Anchor::Legacy {
            return self.legacy_horizon();
        }
        let mut at = match &self.base {
            Some(b) => b.covers.clone(),
            None => self.op_log.first().map(|o| o.hlc.clone()).unwrap_or_else(|| HlcTimestamp::zero("")),
        };
        at.counter = at.counter.saturating_add(1);
        at
    }

    /// What a legacy server's first checkpoint covers, as 0.13's did: everything its owner
    /// had witnessed. A legacy state holds no provable history (a capped log, a joiner's
    /// snapshot without stamps), so its stamps cannot say what it decided.
    fn legacy_horizon(&self) -> HlcTimestamp {
        let tail = self.op_log.iter().map(|o| &o.hlc).max();
        match (self.hlc.as_ref().map(|h| h.latest()), tail) {
            (Some(h), Some(t)) => h.max(t).clone(),
            (Some(h), None) => h.clone(),
            (None, Some(t)) => t.clone(),
            (None, None) => HlcTimestamp::zero(""),
        }
    }

    /// The owner's checkpoint of this state, a child of the base it stands on. The first
    /// one of an existing server also seeds the membership record from what the owner
    /// vouches for: every current member from the start, and every author of a channel
    /// post it holds up to now.
    pub fn checkpoint_json(&self, me: &str, past_authors: &[String], now_ms: u64) -> Option<String> {
        let mut base = self.lean_snapshot();
        base.owner_pin = None;
        base.checkpoint_hlc = None;
        base.retained_print = None;
        base.cp_stamped = true;
        match &self.base {
            Some(b) => {
                base.cp_generation = b.generation.checked_add(1)?;
                base.cp_parent = Some(b.hash_hex());
                base.cp_lineage = lineage_after(b);
                base.cp_cut = cut_after(b);
                base.cp_settled = b.state.cp_settled.clone();
            }
            None => {
                base.cp_generation = 0;
                base.cp_parent = None;
                base.cp_lineage = Vec::new();
                base.cp_cut = None;
                base.cp_settled = None;
            }
        }
        (base.cp_retired, base.cp_endorsed) = self.carried_retires();
        base.cp_posts_until = self.carried_posts_until();
        base.cp_refolded = self.carried_refolded();
        self.write_refolds(&mut base, now_ms);
        // The owner is fixed: a co-owner an older client minted is an admin here.
        for (id, reg) in base.roles.iter_mut() {
            if id != me && *reg.read() == super::operations::MemberRole::Owner {
                let (hlc, priority) = (reg.hlc().clone(), reg.priority());
                *reg = super::admin_lww::AdminLwwReg::new(super::operations::MemberRole::Admin, hlc, priority);
            }
        }
        if self.anchor() == Anchor::Legacy {
            base.cp_floor = Some(self.checkpoint_covers());
            let current: Vec<(String, u64)> =
                base.members.keys().map(|m| (m.clone(), u64::MAX)).collect();
            let past = past_authors.iter().map(|a| (a.clone(), now_ms));
            for (who, until_ms) in current.into_iter().chain(past) {
                let spans = base.member_record.entry(who.clone()).or_default();
                if spans.first().is_none_or(|s| s.from_ms > 0) {
                    spans.insert(0, MemberSpan { from_ms: 0, until_ms, ..MemberSpan::default() });
                    base.member_events.remove(&who);
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
    /// so it decides who belongs and what exists, never who may decide (D2), and it
    /// dates nothing: its stamps and checkpoint fields go.
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
        // A legacy joiner folds no reset, so the list is all that tells it one was made;
        // capped, as each key costs every later join box an open.
        let current = snap.join_secret.as_ref().map(|reg| reg.read().clone());
        snap.join_secrets_retired = super::server_state::cap_retired(std::mem::take(&mut snap.join_secrets_retired));
        snap.join_secrets_retired.retain(|(_, s)| Some(s) != current.as_ref());
        snap.owner_pin = Some(owner);
        snap.checkpoint_hlc = None;
        *snap.stamps = Default::default();
        snap.member_events.clear();
        snap.cp_generation = 0;
        snap.cp_parent = None;
        snap.cp_stamped = false;
        snap.cp_floor = None;
        snap.retained_print = None;
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
        self.expire_held();
        let now = super::hlc::wall_clock_ms();
        let mut passed: Vec<CrdtOp> = Vec::with_capacity(ops.len());
        for op in ops {
            if let Err(reason) = self.stateless_check(op, now) {
                out.rejected += 1;
                log_refusal(op, &reason);
                continue;
            }
            let mut op = op.clone();
            op.strip_bad_proof();
            passed.push(op);
        }
        // The view is read only for authors an op of this replica or this batch admits:
        // a stranger's op costs no store read and no entry (section 14).
        let judged = self.judged_authors(&passed);
        self.fill_view(judged.iter().map(|&i| &passed[i]));
        let (passed, mut refold) = self.founded_once(passed, &mut out);
        let mut batch: HashMap<OpKey, (CrdtOp, [u8; 32])> = HashMap::new();
        let mut rival = false;
        for op in passed {
            let key = (op.author.clone(), op.hlc.clone());
            let hash = op.content_hash();
            let held = self.op_log_dedup.get(&key).copied().or_else(|| {
                self.held.iter().find(|(h, _)| h.author == op.author && h.hlc == op.hlc).map(|(h, _)| h.content_hash())
            });
            if let Some(h) = held {
                if h == hash {
                    refold |= self.take_better_proof(&op, hash, &mut out);
                    continue;
                }
                log_equivocation(&op);
                if self.held_copy_mut(&op).map(|o| o.clone()).is_some_and(|o| self.copy_rank(&op, hash) > self.copy_rank(&o, h)) {
                    continue;
                }
                rival = true;
            }
            if batch.get(&key).is_some_and(|(o, h)| self.copy_rank(o, *h) <= self.copy_rank(&op, hash)) {
                continue;
            }
            batch.insert(key, (op, hash));
        }
        if batch.is_empty() {
            return if refold { self.fold_all(Vec::new(), out) } else { out };
        }
        let mut fresh: Vec<CrdtOp> = batch.into_values().map(|(op, _)| op).collect();
        fresh.sort_by(fold_order);
        if rival || refold {
            return self.fold_all(fresh, out);
        }

        if self.anchor() == Anchor::Legacy {
            // The owner's checkpoint moves a legacy replica onto the fold. It is judged
            // against the legacy state it replaces, which also pins its owner.
            let checkpoint = fresh.iter().find(|op| {
                matches!(op.payload, CrdtPayload::ServerCheckpoint { .. }) && self.op_allowed(op)
            });
            if let Some(cp) = checkpoint {
                self.owner_pin = Some(cp.author.clone());
                return self.fold_all(fresh, out);
            }
            return self.apply_in_arrival(fresh, out);
        }

        let genesis = super::anchor::is_genesis_id(&self.server_id);
        let mut keep = Vec::with_capacity(fresh.len());
        for op in fresh {
            // A floor mark is judged by the plan before the door (8.8, RC32-6).
            if matches!(op.payload, CrdtPayload::ServerCheckpoint { .. } | CrdtPayload::FloorMark { .. }) {
                keep.push(op);
                continue;
            }
            match self.door(&op, genesis) {
                Class::Row(kind) => {
                    let hash = op.content_hash();
                    out.rows.push((op.clone(), None));
                    self.op_log_dedup.insert((op.author.clone(), op.hlc.clone()), hash);
                    self.stored.push((op, kind));
                }
                Class::Drop => {}
                _ => keep.push(op),
            }
        }
        if keep.is_empty() {
            return out;
        }
        let in_order = !keep.iter().any(|o| matches!(o.payload, CrdtPayload::ServerCheckpoint { .. }))
            && self.op_log.last().is_none_or(|tail| fold_order(&keep[0], tail) == std::cmp::Ordering::Greater);
        if !in_order {
            return self.fold_all(keep, out);
        }
        // The tail: each op newer than everything folded, judged exactly as a rebuild of
        // the same set would judge it, or the rest of the batch rebuilds.
        let mut enabling = false;
        for (i, op) in keep.iter().enumerate() {
            if !self.known_author(op) {
                out.rejected += 1;
                log_refusal(op, &OpReject::NotAllowed);
                continue;
            }
            // What a retire endorses can move ops already held, and it ranks first in its
            // author's group: the rebuild judges it, coalesced past the author's budget.
            if matches!(op.payload, CrdtPayload::DeviceRetired { .. } | CrdtPayload::SettleSign { .. } | CrdtPayload::FloorMark { .. }) {
                if self.retire_rebuilds.charge(&op.author, super::hlc::wall_clock_ms()) {
                    return self.fold_all(keep[i..].to_vec(), out);
                }
                self.held.push((op.clone(), Instant::now()));
                self.trim_held();
                continue;
            }
            let verdict = if self.quota_ready() { self.quota.tail(op) } else { Tail::Rebuild };
            match verdict {
                Tail::Rebuild => return self.fold_all(keep[i..].to_vec(), out),
                Tail::Over => self.hold_over(op.clone(), &mut out),
                Tail::Within if self.op_allowed(op) => {
                    if self.voids_folded(op) {
                        return self.fold_all(keep[i..].to_vec(), out);
                    }
                    enabling |= enables_others(&op.payload);
                    self.cut |= genesis && commits_to_a_key(op, &self.server_id);
                    self.apply_payload(op);
                    self.log_admitted(op.clone());
                    out.rows.push((op.clone(), None));
                    out.admitted.push(op.clone());
                }
                Tail::Within => match self.device_refusal(op) {
                    Some(parkable) => self.park_refused(op, parkable, &mut out),
                    None => self.hold(op.clone(), &mut out),
                },
            }
        }
        if enabling && !self.held.is_empty() {
            return self.fold_all(Vec::new(), out);
        }
        out
    }

    /// Whether the quota book is the allocation of the set held now. Never computed, or
    /// left stale by an op that left `held`: computed again, and when it binds the
    /// caller rebuilds (a binding allocation may move what is folded).
    fn quota_ready(&mut self) -> bool {
        if self.quota.computed {
            return true;
        }
        let plan = self.plan(Vec::new(), super::hlc::wall_clock_ms());
        if plan.quota.total() > plan.quota.avail() {
            return false;
        }
        *self.quota = plan.quota;
        true
    }

    /// F8: an op waits in `held` (or counts at all at the tail) only from an author the
    /// state knows: one with a record, or one an admission we hold names. Identities are
    /// free, so fairness per author alone would not bound strangers.
    /// What every held retire (any row kind, held, or `fresh`) endorses: fixed before the
    /// plan, so eligibility and the fold read one set (section 10, step 3).
    fn refresh_endorsed(&mut self, fresh: &[CrdtOp]) {
        let retire = |o: &&CrdtOp| matches!(o.payload, CrdtPayload::DeviceRetired { .. });
        let held = self.op_log.iter().chain(self.stored.iter().map(|(o, _)| o)).chain(self.held.iter().map(|(o, _)| o));
        let all: Vec<&CrdtOp> = held.chain(fresh.iter()).filter(retire).collect();
        let endorsed = self.endorsements(all);
        if *self.endorsed != endorsed {
            self.endorsed = Arc::new(endorsed);
        }
    }

    /// The owner, when the cut is in force, a checkpoint waits and the view holds none of
    /// the owner's statements: whose roster ends the wait.
    fn owner_missing(&self, plan: &Plan) -> Option<String> {
        let waits = plan.ops.iter().any(|(op, _, class, _)| matches!(op.payload, CrdtPayload::ServerCheckpoint { .. }) && matches!(class, Class::Held));
        let owner = self.fold_owner(&plan.ops)?;
        (plan.cut && waits && self.authority.is_set() && self.authority.entry(&owner).and_then(|e| e.auth.as_ref()).is_none()).then_some(owner)
    }

    /// The ops of `ops` whose author is known here or admitted by a known author's op in
    /// the same batch.
    fn judged_authors(&self, ops: &[CrdtOp]) -> Vec<usize> {
        let admitted: HashSet<&str> = ops
            .iter()
            .filter(|o| self.known_author(o))
            .filter_map(|o| match &o.payload {
                CrdtPayload::MemberAdded { peer_id, .. } => Some(peer_id.as_str()),
                _ => None,
            })
            .collect();
        (0..ops.len()).filter(|&i| admitted.contains(ops[i].author.as_str()) || self.known_author(&ops[i])).collect()
    }

    /// HOL-SEC-222, the door of [`Self::founding_kept`]: a founding op it would not keep
    /// drops unstored. True when the batch changes what is kept (a better founding op,
    /// or an op refuting the one held), so the caller folds again.
    fn founded_once(&self, ops: Vec<CrdtOp>, out: &mut Ingested) -> (Vec<CrdtOp>, bool) {
        if !super::anchor::is_genesis_id(&self.server_id) {
            return (ops, false);
        }
        let founding = ops.iter().any(|o| matches!(o.payload, CrdtPayload::ServerCreated { .. }));
        // An op older than the founding op may refute it, which matters only with a
        // runner-up to found on instead.
        let refutes = || {
            let floor = super::authority::founding_op(self).map(|f| &f.hlc);
            floor.is_some_and(|f| ops.iter().any(|o| o.hlc < *f)) && self.stored.iter().any(|(o, _)| self.founds(o))
        };
        if !founding && !refutes() {
            return (ops, false);
        }
        let held: Vec<&CrdtOp> = self.op_log.iter().chain(self.stored.iter().map(|(o, _)| o)).chain(self.held.iter().map(|(o, _)| o)).collect();
        let before: Vec<[u8; 32]> = self.founding_kept(&held).into_iter().map(CrdtOp::content_hash).collect();
        let mut all = held;
        all.extend(ops.iter());
        let after: Vec<[u8; 32]> = self.founding_kept(&all).into_iter().map(CrdtOp::content_hash).collect();
        let refold = before != after;
        let ops = ops
            .into_iter()
            .filter(|o| {
                let passes = !matches!(o.payload, CrdtPayload::ServerCreated { .. }) || after.contains(&o.content_hash());
                if !passes {
                    out.rejected += 1;
                    log_refusal(o, &OpReject::NotAllowed);
                }
                passes
            })
            .collect();
        (ops, refold)
    }

    /// An op founding this self-certifying id: its owner's, naming its nonce.
    pub(crate) fn founds(&self, op: &CrdtOp) -> bool {
        matches!(&op.payload, CrdtPayload::ServerCreated { owner_peer_id, nonce, .. }
            if op.author == *owner_peer_id && super::anchor::derive_server_id(owner_peer_id, nonce) == self.server_id)
    }

    /// HOL-SEC-222: the founding ops of this id kept among `ops` (everything held and
    /// arriving, which the owner's counted ops judge too), best first: the first founds
    /// the server. Chosen by content and the view alone, never by arrival: a counted
    /// device's first, then one the view lists, then the earliest clock, then the content
    /// id. One clocked after a counted op of the owner's is refuted, since no honest op
    /// predates its founding op. Besides the first, the best of each other listed device,
    /// never a refuted one, up to `MAX_FOUNDING_KEPT`.
    pub(crate) fn founding_kept<'a>(&self, ops: &[&'a CrdtOp]) -> Vec<&'a CrdtOp> {
        if !super::anchor::is_genesis_id(&self.server_id) {
            return Vec::new();
        }
        // One copy per key, the one the dedup keeps.
        let mut by_key: HashMap<(&str, &HlcTimestamp), &'a CrdtOp> = HashMap::new();
        for &o in ops.iter().filter(|o| self.founds(o)) {
            let held = by_key.entry((o.author.as_str(), &o.hlc)).or_insert(o);
            if self.copy_rank(o, o.content_hash()) < self.copy_rank(held, held.content_hash()) {
                *held = o;
            }
        }
        let mut found: Vec<&'a CrdtOp> = by_key.into_values().collect();
        if found.len() < 2 {
            return found;
        }
        let owner = found[0].author.as_str();
        let counted = |o: &CrdtOp| self.verdict(o) == super::authority::Verdict::Counted;
        let evidence = ops
            .iter()
            .filter(|o| o.author == owner && !matches!(o.payload, CrdtPayload::ServerCreated { .. } | CrdtPayload::ServerCheckpoint { .. }))
            .filter(|o| counted(o))
            .map(|o| &o.hlc)
            .min();
        let refuted = |o: &CrdtOp| evidence.is_some_and(|e| *e < o.hlc);
        found.sort_by_cached_key(|o| (refuted(o), !counted(o), !self.lists_device(o), o.hlc.clone(), o.content_hash()));
        let mut slots: HashSet<&str> = HashSet::new();
        let mut kept = Vec::new();
        for (i, o) in found.into_iter().enumerate() {
            if kept.len() == MAX_FOUNDING_KEPT {
                break;
            }
            let slot = o.dev.as_deref().map_or("~", |d| d.device.as_str());
            if (i > 0 && (refuted(o) || !self.lists_device(o))) || !slots.insert(slot) {
                continue;
            }
            kept.push(o);
        }
        kept
    }

    /// Whether the view lists the device `op`'s proof names for its author (counted or
    /// removed); a proofless op, or an author the view holds no statements for, passes.
    fn lists_device(&self, op: &CrdtOp) -> bool {
        let Some(dev) = op.dev.as_deref() else { return true };
        self.authority
            .entry(&op.author)
            .and_then(|e| e.auth.as_ref())
            .is_none_or(|a| a.counts(&dev.device) || a.removed.contains_key(&dev.device))
    }

    pub(super) fn known_author(&self, op: &CrdtOp) -> bool {
        matches!(op.payload, CrdtPayload::ServerCreated { .. } | CrdtPayload::ServerCheckpoint { .. })
            || self.member_record.contains_key(&op.author)
            // A floor mark's author is usually no member of a stepped-back state (8.8).
            || (matches!(op.payload, CrdtPayload::FloorMark { .. }) && self.floor_author_known(&op.author))
            || self.held.iter().map(|(o, _)| o).chain(self.stored.iter().map(|(o, _)| o)).any(|o| {
                matches!(&o.payload, CrdtPayload::MemberAdded { peer_id, .. } if *peer_id == op.author)
            })
    }

    /// Where the base sends a live op that is not a checkpoint: to the fold, stored
    /// unfolded (decided by the base, not by its parent), or nowhere.
    fn door(&self, op: &CrdtOp, genesis: bool) -> Class {
        let Some(base) = &self.base else { return Class::Fold };
        if !base.judge_over(self.parent.as_deref()).dominates(op, genesis) {
            return Class::Fold;
        }
        match &self.parent {
            Some(parent) if parent.judge().dominates(op, genesis) => Class::Drop,
            _ => Class::Row(RowKind::Dormant),
        }
    }

    /// Rebuild the materialized state from the log as it stands.
    /// Server id, author signature and clock bound: everything that does not depend on
    /// the state.
    pub(super) fn stateless_check(&self, op: &CrdtOp, now_ms: u64) -> Result<(), OpReject> {
        if op.server_id != self.server_id {
            return Err(OpReject::WrongServer);
        }
        let bound = if matches!(op.payload, CrdtPayload::ServerCheckpoint { .. }) { MAX_CHECKPOINT_BYTES } else { MAX_OP_BYTES };
        let signed = op.signing_payload();
        if signed.len() > bound {
            return Err(OpReject::TooLarge);
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
                    out.rows.push((op.clone(), None));
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
                // A checkpoint moves the replica onto the fold (`fold_remote`), never here.
                if !matches!(op.payload, CrdtPayload::ServerCheckpoint { .. }) && self.op_allowed(&op) {
                    if let Ok(true) = self.apply_op(&op) {
                        out.rows.push((op.clone(), None));
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

    /// The owner every checkpoint must come from: the pin, else the founder a
    /// self-certifying id names among `ops`, else the current owner.
    fn fold_owner(&self, ops: &[(CrdtOp, [u8; 32], Class, bool)]) -> Option<String> {
        if let Some(pin) = &self.owner_pin {
            return Some(pin.clone());
        }
        if super::anchor::is_genesis_id(&self.server_id) {
            return ops.iter().find_map(|(op, ..)| match &op.payload {
                CrdtPayload::ServerCreated { owner_peer_id, nonce, .. }
                    if op.author == *owner_peer_id
                        && super::anchor::derive_server_id(owner_peer_id, nonce) == self.server_id =>
                {
                    Some(owner_peer_id.clone())
                }
                _ => None,
            });
        }
        self.current_owner()
    }

    /// `op` as a base, when it is a well-formed checkpoint of this server by `owner`.
    fn base_of(&self, op: &CrdtOp, hash: [u8; 32], owner: Option<&str>) -> Option<Base> {
        let CrdtPayload::ServerCheckpoint { state, covers } = &op.payload else { return None };
        if owner.is_some_and(|o| o != op.author) || (owner.is_none() && super::anchor::is_genesis_id(&self.server_id)) {
            return None;
        }
        if *covers > op.hlc {
            return None;
        }
        let known = [&self.base, &self.parent].into_iter().flatten().find(|b| b.hash == hash);
        let parsed = match known {
            Some(b) => b.state.clone(),
            None => Arc::new(super::server_state::parse_state(state)?),
        };
        let owners: Vec<&String> = parsed
            .roles
            .iter()
            .filter(|(_, reg)| *reg.read() == super::operations::MemberRole::Owner)
            .map(|(id, _)| id)
            .collect();
        if parsed.server_id != self.server_id || parsed.deleted || owners != [&op.author] || parsed.cp_floor.as_ref().is_some_and(|f| f > covers) {
            return None;
        }
        let parent = match &parsed.cp_parent {
            None => None,
            Some(text) => Some(<[u8; 32]>::try_from(hex::decode(text).ok()?).ok()?),
        };
        Some(Base { hash, hlc: op.hlc.clone(), covers: covers.clone(), generation: parsed.cp_generation, parent, state: parsed })
    }

    /// An op the device clause refused at the tail: parked as a row when the rules admit it
    /// and its author has a span, held when a roster may still end the rules' refusal
    /// (`refusal_may_end`), else dropped; its author's roster is wanted unless the refusal
    /// is for a missing proof.
    fn park_refused(&mut self, op: &CrdtOp, parkable: bool, out: &mut Ingested) {
        if self.wants_roster(op, self.cut) {
            out.wanted.insert(op.author.clone());
        }
        if !parkable {
            if self.refusal_may_end(op, self.holds_skipped()) {
                self.hold(op.clone(), out);
            }
            return;
        }
        if !self.park_fits(op) {
            return;
        }
        let until = super::hlc::wall_clock_ms().saturating_add(PARK_MS);
        self.op_log_dedup.insert((op.author.clone(), op.hlc.clone()), op.content_hash());
        self.stored.push((op.clone(), RowKind::Parked(until)));
        out.rows.push((op.clone(), Some(until)));
    }

    /// Section 7's eligibility over the held checkpoints, never the base: the core's
    /// parent rule, and after the cut a writer device the owner's view counts (rule 1) or
    /// a place in an eligible checkpoint's `cp_lineage` (rule 3, a least fixed point).
    /// While the owner's statements count no device, the device rule takes nothing away
    /// (the freeze, N2). While the view holds no owner statements at all (`Missing`), the
    /// state stays where it folded: only the current base and its lineage stay eligible,
    /// until the owner's roster arrives.
    /// The settle marks `all` holds (section 7, RC32-4, RC32-9, R33-6): each owner
    /// `SettleSign` whose one signature verifies and whose parent checkpoint is held,
    /// the lower (ms, counter, content id) per (settling id, device), at most 8 per mark
    /// and 32 marks; past that, marks no counted signer signed go first, then each mark is
    /// charged to its lightest counted signer and the device charged the most loses its
    /// smallest (generation, id). A mark counts with a counted signer and a parent that
    /// verifies as a base one generation below.
    fn settle_marks(&self, all: &[(CrdtOp, [u8; 32], Class, bool)], bases: &[(usize, Base)], owner: Option<&str>) -> Marks {
        let held: HashMap<String, usize> = all
            .iter()
            .filter(|e| matches!(e.0.payload, CrdtPayload::ServerCheckpoint { .. }))
            .map(|e| (hex::encode(e.1), e.0.signing_payload().len()))
            .collect();
        let mut best: HashMap<(String, String), usize> = HashMap::new();
        for (i, (op, h, ..)) in all.iter().enumerate() {
            let CrdtPayload::SettleSign { stamp } = &op.payload else { continue };
            if owner != Some(op.author.as_str()) || !self.settle_sign_shape(op, stamp) || !held.contains_key(&stamp.parent) {
                continue;
            }
            let key = (stamp.id(), stamp.sigs[0].device.clone());
            let rank = |j: usize| (all[j].0.hlc.physical_ms, all[j].0.hlc.counter, all[j].1);
            match best.get(&key) {
                Some(&j) if rank(j) <= (op.hlc.physical_ms, op.hlc.counter, *h) => {}
                _ => {
                    best.insert(key, i);
                }
            }
        }
        let counts = |d: &str| owner.is_some_and(|o| self.authority.counts(o, d));
        let mut by_id: HashMap<String, Mark> = HashMap::new();
        for ((id, device), i) in best {
            let CrdtPayload::SettleSign { stamp } = &all[i].0.payload else { continue };
            let mark = by_id.entry(id.clone()).or_insert_with(|| Mark {
                id,
                generation: stamp.generation,
                parent: stamp.parent.clone(),
                sigs: Vec::new(),
                counted: Vec::new(),
                pin_bytes: held.get(&stamp.parent).copied().unwrap_or(0),
            });
            mark.sigs.push((i, device));
        }
        let mut marks: Vec<Mark> = by_id.into_values().collect();
        for m in &mut marks {
            m.sigs.sort_by(|a, b| (!counts(&a.1), &a.1).cmp(&(!counts(&b.1), &b.1)));
            m.sigs.truncate(MAX_SETTLE_SIGS);
            m.counted = m.sigs.iter().map(|(_, d)| d.clone()).filter(|d| counts(d)).collect();
        }
        let pinned = |marks: &[Mark]| -> usize {
            let parents: HashMap<&str, usize> = marks.iter().map(|m| (m.parent.as_str(), m.pin_bytes)).collect();
            parents.values().sum()
        };
        while marks.len() > MAX_SETTLE_MARKS || (marks.len() > 1 && pinned(&marks) > SETTLE_PIN_BYTES) {
            let order = |m: &Mark| (m.generation, m.id.clone());
            let gone = if let Some(i) = (0..marks.len()).filter(|&i| marks[i].counted.is_empty()).min_by_key(|&i| order(&marks[i])) {
                i
            } else {
                let mut signed: HashMap<&str, usize> = HashMap::new();
                for m in &marks {
                    for d in &m.counted {
                        *signed.entry(d.as_str()).or_default() += 1;
                    }
                }
                let lightest = |m: &Mark| m.counted.iter().min_by_key(|d| (signed[d.as_str()], (*d).clone())).cloned().unwrap_or_default();
                let mut charged: HashMap<String, Vec<usize>> = HashMap::new();
                for (i, m) in marks.iter().enumerate() {
                    charged.entry(lightest(m)).or_default().push(i);
                }
                let heaviest = charged.iter().max_by(|a, b| a.1.len().cmp(&b.1.len()).then_with(|| b.0.cmp(a.0))).map(|(_, v)| v.clone()).unwrap_or_default();
                heaviest.into_iter().min_by_key(|&i| order(&marks[i])).unwrap_or(0)
            };
            marks.swap_remove(gone);
        }
        let mut out = Marks::default();
        for m in &marks {
            out.kept.extend(m.sigs.iter().map(|(i, _)| *i));
            if let Ok(p) = <[u8; 32]>::try_from(hex::decode(&m.parent).unwrap_or_default().as_slice()) {
                out.pins.insert(p);
            }
        }
        out.line = marks
            .iter()
            .filter(|m| !m.counted.is_empty())
            .filter_map(|m| {
                let (_, p) = bases.iter().find(|(_, b)| b.hash_hex() == m.parent)?;
                (p.generation.checked_add(1) == Some(m.generation)).then_some((m, p))
            })
            .max_by(|a, b| (a.0.generation, &a.0.id).cmp(&(b.0.generation, &b.0.id)))
            .map(|(m, p)| (m.id.clone(), p.hash, p.state.cp_lineage.iter().cloned().collect()));
        out
    }

    /// The floor marks `all` holds and the floor they make (section 8.8 items 2 to 7):
    /// marks by a member of the checkpoint they name, that checkpoint held as a base; at
    /// most `MAX_FLOOR_MARKS_PER_AUTHOR` per author, counted first, then the lowest named.
    /// Each author's first counted mark is its chosen one. The floor is decided over EVERY
    /// author's chosen mark naming a checkpoint rules 1 to 3 do not make eligible, before
    /// any bound: on one line, the oldest with its ancestors; off one line, none. The bounds
    /// (`MAX_FLOOR_CPS` checkpoints, `MAX_FLOOR_AUTHORS` authors) then keep that evidence
    /// first, so the kept set decides the same: free identities that fill every slot never
    /// push out the mark that ends a fabricated floor. Nothing is kept once a counted settle
    /// mark is held, or an eligible checkpoint is or descends from every named one.
    fn floor_marks(&self, all: &[(CrdtOp, [u8; 32], Class, bool)], bases: &[(usize, Base)], eligible: &HashSet<[u8; 32]>, settled: bool, owner: Option<&str>) -> Floor {
        if settled {
            return Floor::default();
        }
        let named_base = |cp: &str| bases.iter().find(|(_, b)| b.hash_hex() == cp).map(|(_, b)| b);
        let mut by_author: HashMap<&str, Vec<FloorEntry<'_>>> = HashMap::new();
        for (i, (op, ..)) in all.iter().enumerate() {
            let CrdtPayload::FloorMark { cp } = &op.payload else { continue };
            if owner == Some(op.author.as_str()) {
                continue;
            }
            let Some(b) = named_base(cp).filter(|b| b.state.is_member(&op.author)) else { continue };
            let counted = self.verdict(op) == super::authority::Verdict::Counted;
            by_author.entry(op.author.as_str()).or_default().push((i, b, counted));
        }
        let rank = |m: &(usize, &Base, bool)| (!m.2, m.1.generation, m.1.hash, all[m.0].1);
        let mut authors: Vec<(&str, Vec<FloorEntry<'_>>)> = by_author.into_iter().collect();
        for (_, marks) in authors.iter_mut() {
            marks.sort_by_key(|m| rank(m));
            marks.truncate(MAX_FLOOR_MARKS_PER_AUTHOR);
        }
        let head = |marks: &[FloorEntry<'_>]| marks.iter().find(|m| m.2).map(|m| m.1.hash);
        let chosen = |marks: &[FloorEntry<'_>]| head(marks).filter(|h| !eligible.contains(h));
        // The evidence, before any bound: the lowest counted pair off one line, else the
        // oldest counted checkpoint (the floor).
        let mut counted: Vec<&Base> = Vec::new();
        for (_, marks) in &authors {
            if let Some(h) = chosen(marks)
                && !counted.iter().any(|b| b.hash == h)
                && let Some(b) = marks.iter().find(|m| m.1.hash == h)
            {
                counted.push(b.1);
            }
        }
        counted.sort_by_key(|b| (b.generation, b.hash));
        let counted_fork = lowest_off_line(&counted);
        let evidence: Vec<&Base> = match counted_fork {
            Some((i, j)) => vec![counted[i], counted[j]],
            None => counted.first().copied().into_iter().collect(),
        };
        // `keep(held)` over the distinct named checkpoints, the evidence first.
        let mut named: Vec<&Base> = Vec::new();
        for m in authors.iter().flat_map(|(_, ms)| ms.iter()) {
            if !named.iter().any(|b| b.hash == m.1.hash) {
                named.push(m.1);
            }
        }
        named.sort_by_key(|b| (b.generation, b.hash));
        let mut keep: Vec<&Base> = evidence.clone();
        if let Some((i, j)) = lowest_off_line(&named) {
            for b in [named[i], named[j]] {
                if !keep.iter().any(|k| k.hash == b.hash) {
                    keep.push(b);
                }
            }
        }
        let pin_bytes = |b: &Base| all.iter().find(|e| e.1 == b.hash).map(|e| e.0.signing_payload().len()).unwrap_or(0);
        let mut bytes: usize = keep.iter().map(|b| pin_bytes(b)).sum();
        for b in &named {
            if keep.len() >= MAX_FLOOR_CPS {
                break;
            }
            if keep.iter().any(|k| k.hash == b.hash) || bytes.saturating_add(pin_bytes(b)) > FLOOR_PIN_BYTES {
                continue;
            }
            bytes += pin_bytes(b);
            keep.push(b);
        }
        let kept_cps: HashSet<[u8; 32]> = keep.iter().map(|b| b.hash).collect();
        // The author bound: a witness of the evidence first, then the authors this replica
        // already knows, never the generation a mark names (a thief writes low ones).
        let known = |a: &str| self.floor_author_known(a);
        let witnesses: HashSet<&str> = evidence
            .iter()
            .filter_map(|e| {
                authors.iter().filter(|(_, ms)| chosen(ms) == Some(e.hash)).map(|(a, _)| *a).min_by_key(|a| (!known(a), *a))
            })
            .collect();
        authors.sort_by_cached_key(|(a, ms)| {
            (!witnesses.contains(a), !known(a), head(ms).is_none(), !ms.iter().any(|m| kept_cps.contains(&m.1.hash)), *a)
        });
        authors.truncate(MAX_FLOOR_AUTHORS);
        let descends_from_all =
            bases.iter().any(|(_, e)| eligible.contains(&e.hash) && keep.iter().all(|n| n.hash == e.hash || e.state.cp_lineage.contains(&n.hash_hex())));
        if keep.is_empty() || descends_from_all {
            return Floor::default();
        }
        let mut out = Floor::default();
        for (_, marks) in &authors {
            for m in marks.iter().filter(|m| kept_cps.contains(&m.1.hash)) {
                out.kept.insert(m.0);
                out.pins.insert(m.1.hash);
            }
        }
        if let Some(f0) = evidence.first().filter(|_| counted_fork.is_none()) {
            out.eligible.insert(f0.hash);
            out.eligible.extend(bases.iter().filter(|(_, b)| f0.state.cp_lineage.contains(&b.hash_hex())).map(|(_, b)| b.hash));
        }
        out
    }

    /// Own rows (section 7, N6): each dated by its first domination (the parent's first
    /// fold, the base that decided it before), dropped 30 days after it, then the bound
    /// (section 14), earliest dominated first. Returns the newly dated.
    fn date_own_rows(&self, all: &mut [(CrdtOp, [u8; 32], Class, bool)], parent: Option<&Base>, now_ms: u64) -> Vec<(OwnKey, u64)> {
        let dominated_at = parent.and_then(|p| self.first_folds.get(&p.hash_hex()).copied()).unwrap_or(now_ms);
        let mut own_new = Vec::new();
        let mut kept: Vec<(usize, u64, usize)> = Vec::new();
        for (i, e) in all.iter_mut().enumerate() {
            if e.2 != Class::Row(RowKind::Own) {
                continue;
            }
            let key = (e.0.author.clone(), e.0.hlc.physical_ms, e.0.hlc.counter);
            let since = self.own_since.get(&key).copied().unwrap_or(dominated_at);
            if now_ms.saturating_sub(since) >= OWN_KEEP_MS {
                e.2 = Class::Drop;
                continue;
            }
            if !self.own_since.contains_key(&key) {
                own_new.push((key, since));
            }
            kept.push((i, since, e.0.signing_payload().len()));
        }
        let rows: Vec<(u64, usize)> = kept.iter().map(|k| (k.1, k.2)).collect();
        for j in own_over_bound(&rows, OWN_MAX_OPS, OWN_MAX_BYTES) {
            all[kept[j].0].2 = Class::Drop;
        }
        let gone: HashSet<OwnKey> = kept
            .iter()
            .filter(|k| all[k.0].2 == Class::Drop)
            .map(|k| (all[k.0].0.author.clone(), all[k.0].0.hlc.physical_ms, all[k.0].0.hlc.counter))
            .collect();
        own_new.retain(|(k, _)| !gone.contains(k));
        own_new
    }

    /// The installed plan's own rows replace the dates held: new ones added, the rest gone.
    fn keep_own_since(&mut self, ops: &[(CrdtOp, [u8; 32], Class, bool)], own_new: Vec<(OwnKey, u64)>) -> Vec<(OwnKey, Option<u64>)> {
        let own: HashSet<OwnKey> =
            ops.iter().filter(|e| e.2 == Class::Row(RowKind::Own)).map(|e| (e.0.author.clone(), e.0.hlc.physical_ms, e.0.hlc.counter)).collect();
        let mut changes: Vec<(OwnKey, Option<u64>)> = self.own_since.keys().filter(|k| !own.contains(*k)).map(|k| (k.clone(), None)).collect();
        changes.extend(own_new.iter().map(|(k, v)| (k.clone(), Some(*v))));
        if !changes.is_empty() {
            let map = Arc::make_mut(&mut self.own_since);
            map.retain(|k, _| own.contains(k));
            map.extend(own_new);
        }
        changes
    }

    /// Section 8.3, two settlings at once: every settling a counted device of the owner
    /// wrote off `base`'s line, keeping only the devices our view no longer counts that
    /// the base's own settling does not drop (a rival never drops a device we count).
    fn rival_settlings(
        &self,
        all: &[(CrdtOp, [u8; 32], Class, bool)],
        bases: &[(usize, Base)],
        base: Option<&Base>,
        owner: Option<&str>,
    ) -> Vec<super::operations::SettleStamp> {
        let (Some(base), Some(owner)) = (base, owner) else { return Vec::new() };
        let line: HashSet<String> = std::iter::once(base.hash_hex()).chain(base.state.cp_lineage.iter().cloned()).collect();
        let dropped: HashSet<&String> = base.state.cp_settles.iter().flat_map(|st| st.devices.iter()).collect();
        let mut out: Vec<super::operations::SettleStamp> = bases
            .iter()
            .filter(|(i, b)| !line.contains(&b.hash_hex()) && self.verdict(&all[*i].0) == super::authority::Verdict::Counted)
            .filter_map(|(_, b)| b.state.cp_settles.clone())
            .filter_map(|mut st| {
                st.devices.retain(|d| !dropped.contains(d) && !self.authority.counts(owner, d));
                (!st.devices.is_empty()).then_some(st)
            })
            .collect();
        out.sort_by_key(|st| st.id());
        out.dedup_by_key(|st| st.id());
        out
    }

    fn eligible_bases(&self, all: &[(CrdtOp, [u8; 32], Class, bool)], bases: &[(usize, Base)], cut: bool, owner: Option<&str>) -> HashSet<[u8; 32]> {
        let parent_ok = |b: &Base| match b.parent {
            None => b.generation == 0,
            Some(p) => bases.iter().any(|(_, q)| q.hash == p && q.generation.checked_add(1) == Some(b.generation)),
        };
        let judged = cut && self.authority.is_set();
        let statements = owner.and_then(|o| self.authority.entry(o)).and_then(|e| e.auth.as_ref());
        let mut ok: HashSet<[u8; 32]> = if judged && statements.is_none() {
            let standing: HashSet<String> =
                self.base.iter().flat_map(|b| std::iter::once(b.hash_hex()).chain(b.state.cp_lineage.iter().cloned())).collect();
            bases.iter().filter(|(_, b)| parent_ok(b) && standing.contains(&b.hash_hex())).map(|(_, b)| b.hash).collect()
        } else {
            let frozen = !judged || statements.is_some_and(|a| a.counted.is_empty());
            bases
                .iter()
                .filter(|(i, b)| parent_ok(b) && (frozen || self.verdict(&all[*i].0) == super::authority::Verdict::Counted))
                .map(|(_, b)| b.hash)
                .collect()
        };
        loop {
            let named: HashSet<&str> =
                bases.iter().filter(|(_, b)| ok.contains(&b.hash)).flat_map(|(_, b)| b.state.cp_lineage.iter().map(String::as_str)).collect();
            // Rule 2's carried half: an eligible checkpoint's endorsement by a counted signer.
            let endorsed: Vec<&super::operations::Endorsement> = bases
                .iter()
                .filter(|(_, b)| ok.contains(&b.hash))
                .flat_map(|(_, b)| b.state.cp_endorsed.iter())
                .filter(|e| owner == Some(e.author.as_str()) && self.authority.counts(&e.author, &e.by))
                .collect();
            let carried = |i: usize, b: &Base| {
                let dev = all[i].0.dev.as_deref().map(|d| d.device.as_str());
                endorsed.iter().any(|e| dev == Some(e.device.as_str()) && e.refs.iter().any(|r| r.names(&all[i].0, &b.hash)))
            };
            let more: Vec<[u8; 32]> = bases
                .iter()
                .filter(|(i, b)| !ok.contains(&b.hash) && parent_ok(b) && (named.contains(b.hash_hex().as_str()) || carried(*i, b)))
                .map(|(_, b)| b.hash)
                .collect();
            if more.is_empty() {
                return ok;
            }
            ok.extend(more);
        }
    }

    /// Fold everything held again from the anchor: after a change of the view.
    pub(crate) fn rebuild_now(&mut self) -> Ingested {
        self.refresh_view();
        self.fold_all(Vec::new(), Ingested::default())
    }

    /// Keep the plan's `cp_roster`s (section 10 step 2: statements are facts once held);
    /// true when they changed, so the view is judged again before the plan is used.
    fn took_cp_rosters(&mut self, plan: &Plan) -> bool {
        if *self.cp_rosters == plan.rosters {
            return false;
        }
        self.cp_rosters = Arc::new(plan.rosters.clone());
        self.view_source.is_some()
    }

    /// Whether a retire waits in `held` for the coalesced rebuild; any rebuild clears it.
    pub(crate) fn retire_rebuild_due(&self) -> bool {
        self.retire_rebuilds.due
    }

    #[cfg(test)]
    pub(crate) fn hold_retire_for_test(&mut self) {
        self.retire_rebuilds.due = true;
    }

    /// A copy of an op we hold whose proof ranks higher replaces the held proof, in RAM
    /// and in the row (section 6: the best proof wins).
    /// True when the copy was kept unfolded and its verdict rose: the rebuild judges it again.
    fn take_better_proof(&mut self, op: &CrdtOp, hash: [u8; 32], out: &mut Ingested) -> bool {
        if op.dev.is_none() {
            return false;
        }
        let new_rank = { let r = self.copy_rank(op, hash); (r.0, r.2.to_string()) };
        let Some(held) = self.held_copy_mut(op).map(|o| o.clone()) else { return false };
        let old_rank = { let r = self.copy_rank(&held, hash); (r.0, r.2.to_string()) };
        if new_rank >= old_rank {
            return false;
        }
        let rose = new_rank.0 < old_rank.0;
        let parked = self.stored.iter().find(|(o, _)| o.author == op.author && o.hlc == op.hlc).map(|(_, k)| *k);
        let is_held = self.held.iter().any(|(o, _)| o.author == op.author && o.hlc == op.hlc)
            && parked.is_none()
            && !self.op_log.iter().any(|o| o.author == op.author && o.hlc == op.hlc);
        if let Some(copy) = self.held_copy_mut(op) {
            copy.dev = op.dev.clone();
        }
        if !is_held {
            out.rows.retain(|(o, _)| !(o.author == op.author && o.hlc == op.hlc));
            out.rows.push((op.clone(), parked.and_then(|k| k.parked_until())));
        }
        rose && (is_held || matches!(parked, Some(RowKind::Parked(_))))
    }

    /// Every op this replica holds, the best copy per key (verdict, then the lowest
    /// content hash, then the lower proving device), classified against
    /// the greatest checkpoint whose parent it holds.
    fn plan(&self, fresh: Vec<CrdtOp>, now_ms: u64) -> Plan {
        let genesis = super::anchor::is_genesis_id(&self.server_id);
        let mut all: Vec<(CrdtOp, [u8; 32], Class, bool)> = Vec::new();
        for op in &self.op_log {
            let h = self.op_log_dedup.get(&(op.author.clone(), op.hlc.clone())).copied().unwrap_or_else(|| op.content_hash());
            all.push((op.clone(), h, Class::Fold, true));
        }
        for (op, kind) in &self.stored {
            if matches!(kind, RowKind::Parked(until) if *until <= now_ms) {
                continue;
            }
            let h = self.op_log_dedup.get(&(op.author.clone(), op.hlc.clone())).copied().unwrap_or_else(|| op.content_hash());
            all.push((op.clone(), h, Class::Row(*kind), true));
        }
        for (op, _) in &self.held {
            all.push((op.clone(), op.content_hash(), Class::Held, false));
        }
        for op in fresh {
            let h = op.content_hash();
            all.push((op, h, Class::Fold, false));
        }
        all.sort_by(|a, b| {
            a.0.author.cmp(&b.0.author).then_with(|| a.0.hlc.cmp(&b.0.hlc)).then_with(|| self.copy_rank(&a.0, a.1).cmp(&self.copy_rank(&b.0, b.1)))
        });
        all.dedup_by(|later, first| {
            let same = later.0.author == first.0.author && later.0.hlc == first.0.hlc;
            if same {
                first.3 |= later.3;
                if let Class::Row(RowKind::Parked(until)) = later.2 {
                    first.2 = Class::Row(RowKind::Parked(until));
                }
            }
            same
        });

        let owner = self.fold_owner(&all);
        let mut bases: Vec<(usize, Base)> = all
            .iter()
            .enumerate()
            .filter_map(|(i, (op, h, ..))| self.base_of(op, *h, owner.as_deref()).map(|b| (i, b)))
            .collect();
        let stamped: HashSet<usize> = bases.iter().filter(|(_, b)| b.state.cp_stamped).map(|(i, _)| *i).collect();
        let cut = !stamped.is_empty() || all.iter().any(|(op, ..)| genesis && commits_to_a_key(op, &self.server_id));
        // A stamped checkpoint whose held parent says otherwise about what it copies is no base.
        let disagree: HashSet<[u8; 32]> = bases
            .iter()
            .filter(|(_, b)| b.parent.is_some_and(|p| bases.iter().any(|(_, q)| q.hash == p && !agrees_with_parent(b, q))))
            .map(|(_, b)| b.hash)
            .collect();
        bases.retain(|(_, b)| !disagree.contains(&b.hash));
        let mut rosters: Vec<crate::identity::roster::Roster> = Vec::new();
        for r in bases.iter().filter_map(|(_, b)| b.state.cp_roster.as_ref()) {
            if !rosters.contains(r) {
                rosters.push(r.clone());
            }
        }
        let marks = self.settle_marks(&all, &bases, owner.as_deref());
        let mut eligible = self.eligible_bases(&all, &bases, cut, owner.as_deref());
        if let Some(r) = self.settle_base {
            eligible = bases.iter().filter(|(_, b)| b.hash == r).map(|(_, b)| b.hash).collect();
        }
        let old_eligible = self.base.as_ref().is_some_and(|b| eligible.contains(&b.hash));
        // Rule 4 (section 8.8): the floor, which a counted settle mark overrides below.
        let floor = self.floor_marks(&all, &bases, &eligible, marks.line.is_some(), owner.as_deref());
        let floor_only: HashSet<[u8; 32]> = floor.eligible.difference(&eligible).copied().collect();
        eligible.extend(floor_only.iter().copied());
        // Section 7: with a counted settle mark held, only its line stays eligible.
        if let Some((id, parent, lineage)) = &marks.line {
            eligible.retain(|h| {
                *h == *parent
                    || lineage.contains(&hex::encode(h))
                    || bases.iter().any(|(_, b)| b.hash == *h && b.state.cp_settled.as_deref() == Some(id.as_str()))
            });
        }
        let base = bases.iter().filter(|(_, b)| eligible.contains(&b.hash)).max_by(|a, b| a.1.key().cmp(&b.1.key())).cloned();
        let parent = base.as_ref().and_then(|(_, b)| b.parent).and_then(|p| bases.iter().find(|(_, q)| q.hash == p).cloned());

        let refold_pins = base.as_ref().map(|(_, b)| refold_pins(&b.state, now_ms)).unwrap_or_default();
        let rivals = self.rival_settlings(&all, &bases, base.as_ref().map(|(_, b)| b), owner.as_deref());
        let me: Option<String> = self.hlc.as_ref().map(|h| h.actor().to_string());
        let founding: Vec<(String, HlcTimestamp)> =
            self.founding_kept(&all.iter().map(|e| &e.0).collect::<Vec<_>>()).into_iter().map(|o| (o.author.clone(), o.hlc.clone())).collect();
        let base_at = base.as_ref().map(|(i, _)| *i);
        let parent_at = parent.as_ref().map(|(i, _)| *i);
        for (i, entry) in all.iter_mut().enumerate() {
            let parked = matches!(entry.2, Class::Row(RowKind::Parked(_)));
            let op = &entry.0;
            let class = if Some(i) == base_at {
                Class::Base
            } else if Some(i) == parent_at {
                Class::Row(RowKind::Parent)
            } else if let CrdtPayload::ServerCheckpoint { .. } = op.payload {
                match (bases.iter().find(|(j, _)| *j == i), &base) {
                    (None, _) => Class::Drop,
                    (Some(_), None) => Class::Held,
                    (Some((_, c)), Some((_, b))) if c.key() > b.key() => Class::Held,
                    (Some((_, c)), Some(_)) => match &parent {
                        Some((_, p)) if c.key() <= p.key() => Class::Drop,
                        _ => Class::Row(RowKind::Dormant),
                    },
                }
            } else if genesis && matches!(op.payload, CrdtPayload::ServerCreated { .. }) {
                match founding.iter().position(|(a, h)| *a == op.author && *h == op.hlc) {
                    Some(0) => Class::Founding,
                    Some(_) => Class::Row(RowKind::Dormant),
                    None => Class::Drop,
                }
            } else if matches!(op.payload, CrdtPayload::SettleSign { .. }) {
                if marks.kept.contains(&i) { Class::Row(RowKind::SettleSign) } else { Class::Drop }
            } else if matches!(op.payload, CrdtPayload::FloorMark { .. }) {
                if floor.kept.contains(&i) { Class::Row(RowKind::FloorMark) } else { Class::Drop }
            } else {
                match &base {
                    Some((_, b)) if b.judge_over(parent.as_ref().map(|(_, p)| p)).dominates(op, genesis) => match &parent {
                        Some((_, p)) if p.judge().dominates(op, genesis) => {
                            if me.as_deref() == Some(op.author.as_str()) { Class::Row(RowKind::Own) } else { Class::Drop }
                        }
                        _ => Class::Row(RowKind::Dormant),
                    },
                    _ if parked => entry.2,
                    _ => Class::Fold,
                }
            };
            entry.2 = class;
        }
        for entry in all.iter_mut() {
            if matches!(entry.2, Class::Drop | Class::Held) && marks.pins.contains(&entry.1) && matches!(entry.0.payload, CrdtPayload::ServerCheckpoint { .. }) {
                entry.2 = Class::Row(RowKind::SettlePin);
            } else if matches!(entry.2, Class::Drop | Class::Held) && floor.pins.contains(&entry.1) && matches!(entry.0.payload, CrdtPayload::ServerCheckpoint { .. }) {
                entry.2 = Class::Row(RowKind::FloorPin);
            } else if matches!(entry.2, Class::Drop | Class::Held | Class::Row(RowKind::Dormant)) && refold_pins.contains(&hex::encode(entry.1)) {
                entry.2 = Class::Row(RowKind::RefoldPin);
            }
        }
        // F8: what is not a row waits only for an author the set knows.
        let mut known: HashSet<&str> = HashSet::new();
        if let Some((_, b)) = &base {
            known.extend(b.state.member_record.keys().map(String::as_str));
        }
        for (op, ..) in &all {
            match &op.payload {
                CrdtPayload::MemberAdded { peer_id, .. } => {
                    known.insert(peer_id.as_str());
                }
                CrdtPayload::ServerCreated { owner_peer_id, .. } => {
                    known.insert(owner_peer_id.as_str());
                }
                _ => {}
            }
        }
        let unknown: Vec<usize> = all
            .iter()
            .enumerate()
            .filter(|(_, e)| !e.3 && matches!(e.2, Class::Fold) && !known.contains(e.0.author.as_str()))
            .map(|(i, _)| i)
            .collect();
        for i in unknown {
            all[i].2 = Class::Drop;
        }
        // Of the stamped checkpoints this plan stores nowhere (dropped by the base order or
        // as disagreeing, or only held), the lowest stays as the cut's mark.
        let cut_mark = all
            .iter()
            .enumerate()
            .filter(|(i, e)| matches!(e.2, Class::Drop | Class::Held) && stamped.contains(i))
            .min_by(|a, b| (&a.1 .0.hlc, a.1 .1).cmp(&(&b.1 .0.hlc, b.1 .1)))
            .map(|(i, _)| i);
        if let Some(i) = cut_mark {
            all[i].2 = Class::Row(RowKind::CutMark);
        }
        let folded_once: Vec<(usize, u64)> = all
            .iter()
            .enumerate()
            .filter(|(_, e)| matches!(e.2, Class::Drop) && matches!(e.0.payload, CrdtPayload::ServerCheckpoint { .. }))
            .filter_map(|(i, e)| self.first_folds.get(&hex::encode(e.1)).map(|f| (i, *f)))
            .collect();
        for i in restore_picks(&folded_once, now_ms) {
            all[i].2 = Class::Row(RowKind::Restore);
        }
        let own_new = self.date_own_rows(&mut all, parent.as_ref().map(|(_, p)| p), now_ms);
        let settled = marks.line.is_some();
        let floor_base = base.as_ref().is_some_and(|(_, b)| floor_only.contains(&b.hash));
        let mut plan = Plan {
            ops: all,
            base: base.map(|(_, b)| b),
            parent: parent.map(|(_, b)| b),
            quota: Quota::default(),
            cut,
            rosters,
            rivals,
            own_new,
            old_eligible,
            settled,
            floor_base,
        };
        self.allocate(&mut plan, now_ms);
        plan
    }

    /// H3: allocate `QUOTA_BYTES` over the undecided ops before any authority (so a
    /// quota never changes who may author what). Charge trees are rooted in the anchor's
    /// members (the base, else the founding state), so an author with no base still has
    /// a bound. An op over its author's share is parked when it is a row and waits in
    /// `held` otherwise; staff admissions, lock moves and sanctions come first.
    fn allocate(&self, plan: &mut Plan, now_ms: u64) {
        use super::operations::MemberRole;
        let mut q = Quota { computed: true, ..Quota::default() };
        match &plan.base {
            Some(b) => {
                q.owner = b.state.current_owner();
                q.roots = b.state.members.keys().cloned().collect();
                for m in b.state.members.keys() {
                    let p = b.state.get_role(m).priority();
                    if p >= MemberRole::Moderator.priority() {
                        q.staff.insert(m.clone(), p);
                    }
                }
            }
            None => {
                for (op, _, class, _) in &plan.ops {
                    if let (CrdtPayload::ServerCreated { owner_peer_id, .. }, Class::Founding) = (&op.payload, class) {
                        q.owner = Some(owner_peer_id.clone());
                        q.roots.insert(owner_peer_id.clone());
                        q.staff.insert(owner_peer_id.clone(), MemberRole::Owner.priority());
                    }
                }
            }
        }
        let mut undecided: Vec<usize> = plan
            .ops
            .iter()
            .enumerate()
            .filter(|(_, e)| matches!(e.2, Class::Fold | Class::Row(RowKind::Parked(_))))
            .map(|(i, _)| i)
            .collect();
        undecided.sort_by(|&a, &b| fold_order(&plan.ops[a].0, &plan.ops[b].0).then(plan.ops[a].1.cmp(&plan.ops[b].1)));
        // Section 14: an author's newest `MAX_UNDOMINATED_RETIRES` retires stay, the rest
        // drop; those that stay rank first in the author's group.
        let retire = |i: &usize| matches!(plan.ops[*i].0.payload, CrdtPayload::DeviceRetired { .. });
        let mut retires: HashMap<&str, usize> = HashMap::new();
        let mut gone: HashSet<usize> = HashSet::new();
        for &i in undecided.iter().rev().filter(|i| retire(i)) {
            let n = retires.entry(plan.ops[i].0.author.as_str()).or_default();
            *n += 1;
            if *n > MAX_UNDOMINATED_RETIRES {
                gone.insert(i);
            }
        }
        undecided.retain(|i| !gone.contains(i));
        undecided.sort_by_key(|i| !retire(i));
        for i in gone {
            plan.ops[i].2 = Class::Drop;
        }
        let sizes: HashMap<usize, usize> = undecided.iter().map(|&i| (i, op_size(&plan.ops[i].0))).collect();
        for &i in &undecided {
            q.restaff(&plan.ops[i].0);
        }
        let mut exempt: HashSet<usize> = HashSet::new();
        for &i in &undecided {
            let op = &plan.ops[i].0;
            if q.owner.as_ref() == Some(&op.author) {
                exempt.insert(i);
            } else if q.first(op) && q.lead_used + sizes[&i] <= QUOTA_LEADER_BYTES {
                q.lead_used += sizes[&i];
                exempt.insert(i);
            }
            if let CrdtPayload::MemberAdded { peer_id, .. } = &op.payload
                && *peer_id != op.author
                && !q.roots.contains(peer_id)
                && !q.up.contains_key(peer_id)
            {
                q.up.insert(peer_id.clone(), op.author.clone());
            }
        }
        for &i in undecided.iter().filter(|i| !exempt.contains(i)) {
            *q.demand.entry(plan.ops[i].0.author.clone()).or_default() += sizes[&i];
        }
        q.resolve();
        if q.total() <= q.avail() {
            q.used = q.demand.clone();
            plan.quota = q;
            return;
        }
        let shares = q.shares();
        let mut used: HashMap<String, usize> = HashMap::new();
        let mut broken: HashSet<String> = HashSet::new();
        for &i in undecided.iter().filter(|i| !exempt.contains(i)) {
            let author = plan.ops[i].0.author.clone();
            let size = sizes[&i];
            let have = used.entry(author.clone()).or_default();
            if !broken.contains(&author) && *have + size <= shares.get(&author).copied().unwrap_or(0) {
                *have += size;
                continue;
            }
            broken.insert(author);
            let entry = &mut plan.ops[i];
            entry.2 = match entry.2 {
                Class::Row(RowKind::Parked(until)) => Class::Over(until),
                _ if entry.3 => Class::Over(now_ms.saturating_add(PARK_MS)),
                _ => {
                    q.over_held.insert((entry.0.author.clone(), entry.0.hlc.clone()));
                    Class::Held
                }
            };
        }
        q.used = used;
        plan.quota = q;
    }

    /// Rebuild the state from its anchor: the founding op, the base, then every op the
    /// base does not decide, in HLC order, each judged against the state just before it.
    /// A row it now refuses is parked, never deleted; a refused op never stored waits in
    /// `held`.
    pub(super) fn fold_all(&mut self, fresh: Vec<CrdtOp>, mut out: Ingested) -> Ingested {
        self.retire_rebuilds.due = false;
        let now_ms = super::hlc::wall_clock_ms();
        let before: HashMap<OpKey, RowMark> = self
            .op_log
            .iter()
            .map(|o| (o, None))
            .chain(self.stored.iter().map(|(o, k)| (o, k.parked_until())))
            .map(|(o, parked)| {
                let key = (o.author.clone(), o.hlc.clone());
                let h = self.op_log_dedup.get(&key).copied().unwrap_or_else(|| o.content_hash());
                (key, (h, parked, proof_device(o)))
            })
            .collect();
        let was_folded: HashSet<OpKey> = self.op_log.iter().map(|o| (o.author.clone(), o.hlc.clone())).collect();
        self.refresh_endorsed(&fresh);
        let mut plan = self.plan(fresh.clone(), now_ms);
        if self.took_cp_rosters(&plan) {
            self.refresh_view();
            plan = self.plan(fresh.clone(), now_ms);
        }
        // A counted settle mark decides: the round under the previous view has no more
        // to do, and nothing the settling drops may fold meanwhile.
        if plan.settled && self.close_round() {
            plan = self.plan(fresh.clone(), now_ms);
        }
        // Section 8.8: a member that hears of a recovery dropping the only checkpoint
        // writer marks the base it held, before the step back drops what it folded.
        let owner = self.fold_owner(&plan.ops);
        let new_base = plan.base.as_ref().map(Base::hash_hex);
        let mut trigger = self.recovery_trigger(new_base.as_deref(), plan.old_eligible, plan.settled, owner.as_deref());
        if let Some(r) = trigger.as_mut().filter(|_| self.can_author()) {
            // The round keeps judging under the previous view (H4) and marks once it ends.
            let unpinned = self.authority.clone();
            if let Some(round) = self.open_round(owner.as_deref()) {
                r.round = Some(round);
                self.recovery = Some(Arc::new(r.clone()));
                self.pin_round_view();
                let held = self.plan(fresh.clone(), now_ms);
                if held.old_eligible {
                    plan = held;
                } else {
                    r.round = None;
                    self.recovery = None;
                    self.authority = unpinned;
                }
            }
            if r.round.is_none()
                && let Some(cp) = r.base.clone()
            {
                r.floor_b = r.base_op.clone();
                let mark = self.create_op(CrdtPayload::FloorMark { cp });
                let mut fresh = fresh.clone();
                fresh.push(mark);
                plan = self.plan(fresh, now_ms);
            }
        }
        let candidates = if trigger.is_none() && self.may_keep() { on_big_stack(|| self.kept_candidates()) } else { None };
        // The view never changes inside a rebuild, so an op it refuses now stays refused
        // (dropped or parked) until a roster arrives.
        for (op, _, class, _) in &plan.ops {
            if matches!(class, Class::Fold | Class::Row(RowKind::Parked(_)) | Class::Held) && self.wants_roster(op, plan.cut) {
                out.wanted.insert(op.author.clone());
            }
        }
        if let Some(owner) = self.owner_missing(&plan) {
            out.wanted.insert(owner);
        }
        let settled = plan.settled && plan.base.is_some();
        out.own_since = self.install(plan, now_ms);
        if let Some(r) = trigger {
            out.recovery = r.to_json().map(Some);
            self.recovery = Some(Arc::new(r));
        } else if let Some(c) = candidates {
            on_big_stack(|| self.kept_after_install(c, settled, now_ms, &mut out));
        } else if self.recovery_ends(settled) {
            on_big_stack(|| self.end_recovery(now_ms, &mut out));
        }

        // What changed in the store, against what it held when this rebuild began.
        let mut after: HashMap<OpKey, RowMark> = HashMap::new();
        for op in &self.op_log {
            let key = (op.author.clone(), op.hlc.clone());
            let h = self.op_log_dedup[&key];
            let now = (h, None, proof_device(op));
            if !was_folded.contains(&key) && !out.admitted.iter().any(|o| o.author == key.0 && o.hlc == key.1) {
                out.admitted.push(op.clone());
            }
            if before.get(&key) != Some(&now) {
                out.rows.push((op.clone(), None));
            }
            after.insert(key, now);
        }
        for (op, kind) in &self.stored {
            let key = (op.author.clone(), op.hlc.clone());
            let h = self.op_log_dedup[&key];
            let parked = kind.parked_until();
            let now = (h, parked, proof_device(op));
            if before.get(&key) != Some(&now) {
                out.rows.push((op.clone(), parked));
            }
            after.insert(key, now);
        }
        for key in before.keys() {
            if !after.contains_key(key) {
                out.dropped.push(key.clone());
            }
        }
        out.rows.retain(|(o, _)| after.contains_key(&(o.author.clone(), o.hlc.clone())));
        out.admitted.retain(|o| self.op_log_dedup.contains_key(&(o.author.clone(), o.hlc.clone())));
        out.rebuilt = true;
        out.base = self.base.as_ref().map(|b| b.hash_hex());
        out.seen_keep = Some(self.first_folds.keys().cloned().collect());
        out
    }

    /// Part A after a rebuild that may have dropped `c`: open (or grow) the hold and fold
    /// again with what the fold held still counted, else end a recovery that ends. Its
    /// own frame: `fold_all` runs on 2 MiB debug workers.
    #[inline(never)]
    fn kept_after_install(&mut self, c: super::hold::KeptCandidates, settled: bool, now_ms: u64, out: &mut Ingested) {
        match self.kept_trigger(c) {
            Some(r) => {
                out.recovery = r.to_json().map(Some);
                self.recovery = Some(Arc::new(r));
                let again = self.plan(Vec::new(), now_ms);
                let more = self.install(again, now_ms);
                out.own_since.extend(more);
            }
            None if self.recovery_ends(settled) => self.end_recovery(now_ms, out),
            None => {}
        }
    }

    /// End the recovery; what only a part A hold still counted is judged again without it.
    #[inline(never)]
    fn end_recovery(&mut self, now_ms: u64, out: &mut Ingested) {
        let kept = self.recovery.as_ref().is_some_and(|r| r.keeps_fold());
        self.recovery = None;
        out.recovery = Some(None);
        if kept {
            let again = self.plan(Vec::new(), now_ms);
            let more = self.install(again, now_ms);
            out.own_since.extend(more);
        }
    }

    /// Fold a plan into this state: what `fold_all` and a restart that cannot trust its
    /// saved state run.
    fn install(&mut self, plan: Plan, now_ms: u64) -> Vec<(OwnKey, Option<u64>)> {
        let Plan { mut ops, base, parent, quota, cut, rivals, own_new, floor_base, .. } = plan;
        self.floor_base = floor_base;
        let own_changes = self.keep_own_since(&ops, own_new);
        if *self.rival_settles != rivals {
            self.rival_settles = Arc::new(rivals);
        }
        ops.sort_by(|a, b| fold_order(&a.0, &b.0).then(a.1.cmp(&b.1)));
        *self.quota = quota;
        self.cut = cut;
        let held_since: HashMap<OpKey, Instant> =
            std::mem::take(&mut self.held).into_iter().map(|(o, at)| ((o.author, o.hlc), at)).collect();
        self.base = base.map(Box::new);
        self.parent = parent.map(Box::new);
        if let Some(b) = &self.base {
            let id = b.hash_hex();
            if !self.first_folds.contains_key(&id) {
                Arc::make_mut(&mut self.first_folds).insert(id, now_ms);
            }
        }
        let mut keep: HashSet<String> = ops.iter().filter(|e| e.2 == Class::Row(RowKind::Restore)).map(|e| hex::encode(e.1)).collect();
        for b in [&self.base, &self.parent].into_iter().flatten() {
            keep.insert(b.hash_hex());
            keep.extend(b.state.cp_lineage.iter().cloned());
        }
        if self.first_folds.keys().any(|k| !keep.contains(k)) {
            Arc::make_mut(&mut self.first_folds).retain(|k, _| keep.contains(k));
        }
        self.endorse_from_base();
        // A removal voids only what it ends if it folds at its own point, which a pass
        // learns only on reaching it: a pass whose voiding removal was refused runs again
        // without it (fewer voids can seat whom a later removal needs, so a few passes).
        let mut refused: HashSet<OpKey> = HashSet::new();
        for _ in 0..VOID_PASSES {
            let ahead = super::voids::Ahead::of(
                ops.iter().filter(|e| matches!(e.2, Class::Fold | Class::Row(RowKind::Parked(_)))).map(|e| &e.0),
                &refused,
            );
            self.install_pass(&ops, &held_since, ahead, now_ms);
            let voided_by = self.ahead.take().map(|a| a.voided_by()).unwrap_or_default();
            let unfolded: Vec<OpKey> = voided_by
                .into_iter()
                .filter(|k| !self.op_log_dedup.contains_key(k) || self.stored.iter().any(|(o, _)| o.author == k.0 && o.hlc == k.1))
                .collect();
            if unfolded.is_empty() {
                break;
            }
            refused.extend(unfolded);
        }
        self.cap_parked();
        self.trim_held();
        own_changes
    }

    /// One fold of the sorted plan from the anchor, removals ahead judged by `ahead`.
    fn install_pass(
        &mut self,
        ops: &[(CrdtOp, [u8; 32], Class, bool)],
        held_since: &HashMap<OpKey, Instant>,
        ahead: super::voids::Ahead,
        now_ms: u64,
    ) {
        self.reset_materialized();
        self.ahead = Some(Arc::new(ahead));
        self.op_log.clear();
        self.stored.clear();
        self.op_log_dedup.clear();
        self.held.clear();
        let now = Instant::now();
        // H3's carve-out: whether an op a roster could still seat, and that could admit
        // others, was skipped so far; whether our own admission holds a parked row.
        let mut skipped = false;
        let mut own_row = ops.iter().any(|e| matches!(e.2, Class::Row(RowKind::Parked(_))) && self.names_our_admission(&e.0));
        for (op, hash, class, was_row) in ops {
            let (op, hash) = (op.clone(), *hash);
            let key = (op.author.clone(), op.hlc.clone());
            match *class {
                Class::Base => {
                    if let Some(b) = self.base.take() {
                        self.apply_base(&b, &op.author);
                        self.base = Some(b);
                    }
                    self.op_log_dedup.insert(key, hash);
                    self.op_log.push(op);
                }
                Class::Founding | Class::Fold => {
                    if self.op_allowed(&op) {
                        self.apply_payload(&op);
                        self.op_log_dedup.insert(key, hash);
                        self.op_log.push(op);
                    } else if let Some(parkable) = self.device_refusal(&op) {
                        let ends = !parkable && self.refusal_may_end(&op, skipped);
                        skipped |= self.skipped_for_a_roster(&op);
                        let own = self.names_our_admission(&op);
                        if parkable || (ends && *was_row && !(own && own_row)) {
                            own_row |= own;
                            self.op_log_dedup.insert(key, hash);
                            self.stored.push((op, RowKind::Parked(now_ms.saturating_add(PARK_MS))));
                        } else if ends {
                            let at = held_since.get(&key).copied().unwrap_or(now);
                            self.held.push((op, at));
                        }
                    } else if *was_row {
                        self.op_log_dedup.insert(key, hash);
                        self.stored.push((op, RowKind::Parked(now_ms.saturating_add(PARK_MS))));
                    } else {
                        let at = held_since.get(&key).copied().unwrap_or(now);
                        self.held.push((op, at));
                    }
                }
                Class::Row(RowKind::Parked(until)) => {
                    if self.op_allowed(&op) {
                        self.apply_payload(&op);
                        self.op_log_dedup.insert(key, hash);
                        self.op_log.push(op);
                    } else {
                        skipped |= self.skipped_for_a_roster(&op);
                        self.op_log_dedup.insert(key, hash);
                        self.stored.push((op, RowKind::Parked(until)));
                    }
                }
                Class::Row(kind) => {
                    self.op_log_dedup.insert(key, hash);
                    self.stored.push((op, kind));
                }
                Class::Over(until) => {
                    self.op_log_dedup.insert(key, hash);
                    self.stored.push((op, RowKind::Parked(until)));
                }
                Class::Held => {
                    let at = held_since.get(&key).copied().unwrap_or(now);
                    self.held.push((op, at));
                }
                Class::Drop => {}
            }
        }
    }

    /// Keep each charge group's parked rows within `PARK_GROUP_BYTES`, the oldest first:
    /// what a quota or a refusal parks stays bounded whatever a group sends.
    fn cap_parked(&mut self) {
        let mut parked: Vec<usize> =
            (0..self.stored.len()).filter(|&i| matches!(self.stored[i].1, RowKind::Parked(_))).collect();
        parked.sort_by(|&a, &b| fold_order(&self.stored[a].0, &self.stored[b].0));
        let mut per: HashMap<String, usize> = HashMap::new();
        let mut gone: HashSet<usize> = HashSet::new();
        for i in parked {
            let op = &self.stored[i].0;
            let Some((group, cap)) = self.park_group(op) else { continue };
            let used = per.entry(group).or_default();
            let size = op_size(op);
            if *used + size > cap {
                gone.insert(i);
            } else {
                *used += size;
            }
        }
        if gone.is_empty() {
            return;
        }
        let stored = std::mem::take(&mut self.stored);
        for (i, (op, kind)) in stored.into_iter().enumerate() {
            if gone.contains(&i) {
                self.op_log_dedup.remove(&(op.author, op.hlc));
            } else {
                self.stored.push((op, kind));
            }
        }
    }

    /// The charge group an op parks against and that group's budget; `None` = never
    /// evicted (our own admission, which the silent re-ask reads).
    fn park_group(&self, op: &CrdtOp) -> Option<(String, usize)> {
        if self.names_our_admission(op) {
            return None;
        }
        // Staff acts park against the staff budget, so a flood never deletes them.
        Some(if self.quota.first(op) {
            (POOL.to_string() + "staff", QUOTA_LEADER_BYTES)
        } else {
            (self.quota.top(&op.author), PARK_GROUP_BYTES)
        })
    }

    /// `op` admits this replica's own identity.
    pub(super) fn names_our_admission(&self, op: &CrdtOp) -> bool {
        let us = self.hlc.as_ref().map(|h| h.actor());
        matches!(&op.payload, CrdtPayload::MemberAdded { peer_id, .. } if Some(peer_id.as_str()) == us)
    }

    /// Whether `op` still fits its group's parked budget, as `cap_parked` would keep it
    /// (it is newer than every parked row: the tail).
    fn park_fits(&self, op: &CrdtOp) -> bool {
        let Some((group, cap)) = self.park_group(op) else { return true };
        let used: usize = self
            .stored
            .iter()
            .filter(|(o, k)| matches!(k, RowKind::Parked(_)) && self.park_group(o).is_some_and(|(g, _)| g == group))
            .map(|(o, _)| op_size(o))
            .sum();
        used + op_size(op) <= cap
    }

    /// See [`ServerState::restore_op_log`].
    pub(super) fn restore_rows(&mut self, rows: Vec<(CrdtOp, Option<u64>)>) -> Restored {
        let now_ms = super::hlc::wall_clock_ms();
        let had: Vec<OpKey> = rows.iter().map(|(o, _)| (o.author.clone(), o.hlc.clone())).collect();
        let had_recovery = self.recovery.clone();
        let refolded = self.restore_classified(rows, now_ms);
        let dropped = had.into_iter().filter(|k| !self.op_log_dedup.contains_key(k)).collect();
        let opened = match (&had_recovery, &self.recovery) {
            (None, Some(_)) => true,
            (Some(a), Some(b)) => !Arc::ptr_eq(a, b) && b.keeps_fold(),
            _ => false,
        };
        let recovery = opened.then(|| self.recovery.as_ref().and_then(|r| r.to_json())).flatten();
        Restored { refolded, dropped, recovery }
    }

    fn restore_classified(&mut self, rows: Vec<(CrdtOp, Option<u64>)>, now_ms: u64) -> bool {
        self.fill_view(rows.iter().map(|(o, _)| o));
        self.op_log.clear();
        self.stored.clear();
        self.op_log_dedup.clear();
        self.held.clear();
        for (op, parked) in rows {
            self.op_log_dedup.insert((op.author.clone(), op.hlc.clone()), op.content_hash());
            match parked {
                Some(until) => self.stored.push((op, RowKind::Parked(until))),
                None => self.op_log.push(op),
            }
        }
        let checkpointed = self.op_log.iter().any(|o| matches!(o.payload, CrdtPayload::ServerCheckpoint { .. }));
        if self.anchor() == Anchor::Legacy && !checkpointed {
            self.op_log.sort_by(fold_order);
            let excess = self.op_log.len().saturating_sub(super::server_state::LEGACY_OP_LOG_CAP);
            for gone in self.op_log.drain(..excess) {
                self.op_log_dedup.remove(&(gone.author, gone.hlc));
            }
            return false;
        }
        if checkpointed && self.owner_pin.is_none() {
            self.owner_pin = self.op_log.iter().find(|o| matches!(o.payload, CrdtPayload::ServerCheckpoint { .. })).map(|o| o.author.clone());
        }
        self.refresh_endorsed(&[]);
        let mut plan = self.plan(Vec::new(), now_ms);
        if self.took_cp_rosters(&plan) {
            self.refresh_view();
            plan = self.plan(Vec::new(), now_ms);
        }
        let folds = |c: &Class| matches!(c, Class::Founding | Class::Base | Class::Fold);
        let print = print_of(plan.ops.iter().filter(|e| folds(&e.2)).map(|e| &e.1))
            + &self.view_print(plan.ops.iter().filter(|e| folds(&e.2)).map(|e| e.0.author.as_str()));
        if self.retained_print.as_deref() == Some(print.as_str()) && plan.base.is_some() == self.checkpoint_hlc.is_some() {
            let Plan { mut ops, base, parent, quota, cut, rivals, .. } = plan;
            self.rival_settles = Arc::new(rivals);
            *self.quota = quota;
            self.cut = cut;
            ops.sort_by(|a, b| fold_order(&a.0, &b.0).then(a.1.cmp(&b.1)));
            self.op_log.clear();
            self.stored.clear();
            self.op_log_dedup.clear();
            self.base = base.map(Box::new);
            self.parent = parent.map(Box::new);
            self.endorse_from_base();
            for (op, hash, class, _) in ops {
                let key = (op.author.clone(), op.hlc.clone());
                match class {
                    Class::Founding | Class::Base | Class::Fold => {
                        self.op_log_dedup.insert(key, hash);
                        self.op_log.push(op);
                    }
                    Class::Row(kind) => {
                        self.op_log_dedup.insert(key, hash);
                        self.stored.push((op, kind));
                    }
                    Class::Over(until) => {
                        self.op_log_dedup.insert(key, hash);
                        self.stored.push((op, RowKind::Parked(until)));
                    }
                    Class::Held | Class::Drop => {}
                }
            }
            self.cap_parked();
            return false;
        }
        // HOL-SEC-232: a roster stored while the node was down (the push fetch keeps
        // removals, or a crash between the roster save and the rebuild) meets the saved
        // rows here, never in `fold_all`: judge both triggers against what they folded.
        if let Some(r) = self.restore_trigger(&mut plan, now_ms) {
            let _ = self.install(plan, now_ms);
            self.recovery = Some(Arc::new(r));
            return true;
        }
        let candidates = self.kept_candidates();
        let _ = self.install(plan, now_ms);
        if let Some(r) = candidates.and_then(|c| self.kept_trigger(c)) {
            self.recovery = Some(Arc::new(r));
            let again = self.plan(Vec::new(), now_ms);
            let _ = self.install(again, now_ms);
        }
        true
    }

    /// The 8.8 trigger at a restart that refolds: the base the saved rows folded on
    /// (the folded checkpoint the saved state's `checkpoint_hlc` names) stands for the
    /// base before the view changed. On a trigger `plan` becomes the plan that judged it.
    fn restore_trigger(&mut self, plan: &mut Plan, now_ms: u64) -> Option<super::hold::Recovery> {
        if self.recovery.is_some() {
            return None;
        }
        let covers = self.checkpoint_hlc.clone()?;
        let old = self
            .op_log
            .iter()
            .filter(|o| matches!(&o.payload, CrdtPayload::ServerCheckpoint { covers: c, .. } if *c == covers))
            .filter_map(|o| self.base_of_content(o))
            .max_by(|a, b| a.hlc.cmp(&b.hlc))?;
        self.base = Some(Box::new(old));
        let judged = self.plan(Vec::new(), now_ms);
        let owner = self.fold_owner(&judged.ops);
        let new_base = judged.base.as_ref().map(Base::hash_hex);
        let trigger = self.recovery_trigger(new_base.as_deref(), judged.old_eligible, judged.settled, owner.as_deref());
        self.base = None;
        if trigger.is_some() {
            *plan = judged;
        }
        trigger
    }

    /// Every row a whole-log page serves, in fold order: the folded log and the rows
    /// kept unfolded but compared (the base's parent and the dormant ones).
    pub(crate) fn served_log(&self) -> Vec<&CrdtOp> {
        let mut all: Vec<&CrdtOp> = self
            .op_log
            .iter()
            .chain(self.stored.iter().filter(|(_, k)| k.served()).map(|(o, _)| o))
            .collect();
        all.sort_by(|a, b| fold_order(a, b));
        all
    }

    /// What a joiner gets at once (M4): the founding op, the base and its parent, the
    /// authority closure of the joiner's admission (every admission its admitters' spans
    /// rest on back to the base, and the role changes of those members), then the newest
    /// other ops while they fit in `budget` bytes; the base and the closure are outside the
    /// budget. The joiner's paced digest catch-up pulls the rest. Fold order.
    pub fn join_answer(&self, joiner: &str, budget: usize) -> Vec<&CrdtOp> {
        let mut pick: Vec<&CrdtOp> = Vec::new();
        let mut taken: HashSet<OpKey> = HashSet::new();
        fn take<'a>(op: &'a CrdtOp, pick: &mut Vec<&'a CrdtOp>, taken: &mut HashSet<OpKey>) {
            if taken.insert((op.author.clone(), op.hlc.clone())) {
                pick.push(op);
            }
        }
        for op in &self.op_log {
            if matches!(op.payload, CrdtPayload::ServerCreated { .. } | CrdtPayload::ServerCheckpoint { .. }) {
                take(op, &mut pick, &mut taken);
            }
        }
        for (op, kind) in &self.stored {
            if *kind == RowKind::Parent {
                take(op, &mut pick, &mut taken);
            }
        }
        let mut queue = vec![joiner.to_string()];
        let mut seen: HashSet<String> = HashSet::new();
        while let Some(member) = queue.pop() {
            if !seen.insert(member.clone()) {
                continue;
            }
            let opened = self.member_record.get(&member).and_then(|s| s.last()).and_then(|s| s.from_hlc.clone());
            for op in &self.op_log {
                match &op.payload {
                    CrdtPayload::MemberAdded { peer_id, .. } if *peer_id == member && Some(&op.hlc) == opened.as_ref() => {
                        take(op, &mut pick, &mut taken);
                        queue.push(op.author.clone());
                    }
                    CrdtPayload::RoleChanged { peer_id, .. } if *peer_id == member => take(op, &mut pick, &mut taken),
                    _ => {}
                }
            }
        }
        let mut bytes = 0usize;
        for op in self.op_log.iter().rev() {
            if bytes >= budget {
                break;
            }
            if taken.contains(&(op.author.clone(), op.hlc.clone())) {
                continue;
            }
            bytes += serde_json::to_string(op).map_or(0, |j| j.len());
            take(op, &mut pick, &mut taken);
        }
        pick.sort_by(|a, b| fold_order(a, b));
        pick
    }

    /// The fingerprint of the folded log, saved with the state (`lean_snapshot`).
    pub(crate) fn current_print(&self) -> String {
        let hashes: Vec<[u8; 32]> = self.op_log.iter().map(|o| self.content_of(o)).collect();
        print_of(hashes.iter()) + &self.view_print(self.op_log.iter().map(|o| o.author.as_str()))
    }

    /// What the view said about the authors of the folded set (section 10): a restart
    /// under another view of them folds again; entries cached for anyone else do not.
    fn view_print<'a>(&self, authors: impl Iterator<Item = &'a str>) -> String {
        if !self.authority.is_set() {
            return String::new();
        }
        format!(":{}", self.authority.digest_for(authors))
    }

    /// B of a floor round (8.8 item 1): the previous view's pick by the base order over
    /// what this replica held at the trigger and the answered `floor_base`s. A
    /// checkpoint first held after the trigger by a writer the new view does not count
    /// is no candidate unless an answer carried it (RC32-2). Every op is matched by its
    /// own content id: an answered one may share its key with a variant held here
    /// (HOL-SEC-225).
    pub(super) fn floor_pick(&self, round: &super::hold::Round, answered: &[CrdtOp], now_ms: u64) -> Option<CrdtOp> {
        let carried: HashSet<[u8; 32]> = answered.iter().map(CrdtOp::content_hash).collect();
        let late = |o: &CrdtOp| {
            let h = o.content_hash();
            matches!(o.payload, CrdtPayload::ServerCheckpoint { .. })
                && !round.held_at_trigger.contains(&h)
                && !carried.contains(&h)
                && o.proven_device().is_none_or(|d| round.recount.iter().any(|x| x == d))
        };
        let mut scratch = self.clone();
        scratch.op_log.retain(|o| !late(o));
        scratch.stored.retain(|(o, _)| !late(o));
        let b = scratch.plan(answered.to_vec(), now_ms).base?;
        self.op_log
            .iter()
            .chain(self.stored.iter().map(|(o, _)| o))
            .filter(|o| !late(o))
            .chain(answered.iter())
            .find(|o| matches!(o.payload, CrdtPayload::ServerCheckpoint { .. }) && o.content_hash() == b.hash)
            .cloned()
    }

    /// After a floor round: the base is eligible again, or a counted settle mark decides.
    pub(super) fn base_holds_again(&self, now_ms: u64) -> bool {
        let plan = self.plan(Vec::new(), now_ms);
        plan.old_eligible || plan.settled
    }

    /// An op's content hash, from the dedup map when we hold it.
    pub(crate) fn content_of(&self, op: &CrdtOp) -> [u8; 32] {
        self.op_log_dedup.get(&(op.author.clone(), op.hlc.clone())).copied().unwrap_or_else(|| op.content_hash())
    }

    /// A checkpoint we hold (the base, its parent or a stored rival), by content hash.
    pub(crate) fn base_by_hash(&self, hex_hash: &str) -> Option<Base> {
        if let Some(b) = [&self.base, &self.parent].into_iter().flatten().find(|b| b.hash_hex() == hex_hash) {
            return Some(Base::clone(b));
        }
        let owner = self.anchor_owner();
        self.stored.iter().find_map(|(op, _)| {
            let h = self.content_of(op);
            (hex::encode(h) == hex_hash).then(|| self.base_of(op, h, owner.as_deref())).flatten()
        })
    }

    /// A checkpoint op checked as a base of this server, held or not (`base_content`).
    pub(crate) fn base_of_content(&self, op: &CrdtOp) -> Option<Base> {
        self.base_of(op, op.content_hash(), self.anchor_owner().as_deref())
    }

    /// Rebase on `base`: replace everything materialized with its state.
    fn apply_base(&mut self, base: &Base, author: &str) {
        self.rebase_on((*base.state).clone(), author, &base.covers);
    }

    /// Drop held ops past their time.
    fn expire_held(&mut self) {
        let (keep, gone): (Vec<_>, Vec<_>) = std::mem::take(&mut self.held).into_iter().partition(|(_, at)| at.elapsed() < HELD_TTL);
        self.held = keep;
        for (op, _) in gone {
            self.quota.forget(&op);
        }
    }

    /// Keep `held` within its bound, giving up the newest ops of whoever holds the most.
    fn trim_held(&mut self) {
        while self.held.len() > HELD_CAP {
            let mut per: HashMap<&str, usize> = HashMap::new();
            for (op, _) in &self.held {
                *per.entry(op.author.as_str()).or_default() += 1;
            }
            let heaviest = per.iter().max_by(|a, b| a.1.cmp(b.1).then(b.0.cmp(a.0))).map(|(a, _)| a.to_string());
            let Some(heaviest) = heaviest else { break };
            let at = self
                .held
                .iter()
                .enumerate()
                .filter(|(_, (op, _))| op.author == heaviest)
                .max_by(|a, b| a.1 .0.hlc.cmp(&b.1 .0.hlc))
                .map(|(i, _)| i);
            match at {
                Some(i) => {
                    let (op, _) = self.held.remove(i);
                    self.quota.forget(&op);
                }
                None => break,
            }
        }
    }

    fn hold(&mut self, op: CrdtOp, out: &mut Ingested) {
        out.rejected += 1;
        log_refusal(&op, &OpReject::NotAllowed);
        self.held.push((op, Instant::now()));
        self.trim_held();
    }

    /// A tail op over its author's share waits in `held`, never as a row.
    fn hold_over(&mut self, op: CrdtOp, out: &mut Ingested) {
        out.rejected += 1;
        self.quota.over_held.insert((op.author.clone(), op.hlc.clone()));
        self.held.push((op, Instant::now()));
        self.trim_held();
    }
}

/// A set's fingerprint: its count and the wrapping sum of its hashes, order-free.
/// Ancestors a stamped checkpoint carries (section 7).
pub(crate) const LINEAGE: usize = 64;

/// Part A's extra rebuild and snapshot run here: a whole state's clone and a second plan
/// on a node task's 2 MiB debug stack overflow it (as `parse_state`). Inline when the
/// thread cannot start.
fn on_big_stack<T: Send>(f: impl FnOnce() -> T + Send) -> T {
    let slot = std::sync::Mutex::new(Some(f));
    let ran = std::thread::scope(|scope| {
        let job = || slot.lock().ok().and_then(|mut g| g.take()).map(|j| j());
        std::thread::Builder::new().stack_size(8 << 20).spawn_scoped(scope, job).ok().and_then(|h| h.join().ok()).flatten()
    });
    match ran {
        Some(v) => v,
        None => match slot.into_inner().ok().flatten() {
            Some(j) => j(),
            None => std::panic::resume_unwind(Box::new("part A's rebuild panicked")),
        },
    }
}

/// Harness switch, per owner: an owner without part C (0.14.2, or one that has not
/// checkpointed yet), for tests of what members do on a server with no checkpoint.
#[cfg(test)]
pub(crate) static EARLY_OFF_OWNERS: std::sync::LazyLock<std::sync::Mutex<HashSet<String>>> = std::sync::LazyLock::new(Default::default);

/// An op that moves part C's cadence: an authority change, never a pin, mark, lock move,
/// checkpoint or the founding op.
fn cadence_op(p: &CrdtPayload) -> bool {
    match p {
        CrdtPayload::MessagePinned { .. } | CrdtPayload::MessageUnpinned { .. } => false,
        CrdtPayload::JoinKeySet { .. } | CrdtPayload::DeviceRetired { .. } => true,
        _ => super::refold::payload_kind(p) == super::refold::PayloadKind::Writes,
    }
}

/// The `cp_lineage` of a child of `parent`: the parent, then its own lineage.
pub(super) fn lineage_after(parent: &Base) -> Vec<String> {
    std::iter::once(parent.hash_hex()).chain(parent.state.cp_lineage.iter().take(LINEAGE - 1).cloned()).collect()
}

/// The content ids a base's `cp_refolded` pins (section 8.3, "Pins"): R and the DR of
/// every unanswered entry, and the DR of an answered one for 30 days after its `at`.
fn refold_pins(base: &ServerState, now_ms: u64) -> HashSet<String> {
    let mut out = HashSet::new();
    for e in &base.cp_refolded {
        if e.answered.is_none() {
            out.insert(e.r.clone());
        }
        if e.answered.is_none() || now_ms.saturating_sub(e.at.physical_ms) < super::refold::R_REACH_MS {
            out.insert(e.dr.clone());
        }
    }
    out
}

/// The `cp_cut` of a child of `parent`: the parent's lineage clock, or none (its own
/// clock) when the parent is not stamped.
pub(super) fn cut_after(parent: &Base) -> Option<HlcTimestamp> {
    parent.state.cp_stamped.then(|| parent.state.cp_cut.clone().unwrap_or_else(|| parent.hlc.clone()))
}

/// Whether stamped `child` agrees with its held `parent` on what it copies (section 7):
/// else it is no base.
fn agrees_with_parent(child: &Base, parent: &Base) -> bool {
    // A settling names itself; any other checkpoint copies its parent's.
    let settles_here = child.state.cp_settles.as_ref().is_some_and(|s| {
        child.state.cp_settled.as_deref() == Some(s.id().as_str()) && s.parent == parent.hash_hex() && s.generation == child.generation
    });
    !child.state.cp_stamped
        || (child.state.cp_lineage == lineage_after(parent)
            && child.state.cp_cut == cut_after(parent)
            && (child.state.cp_settled == parent.state.cp_settled || settles_here))
}

/// A founding op whose nonce commits to the founder's recovery key: the cut is in force
/// from it (section 7).
fn commits_to_a_key(op: &CrdtOp, server_id: &str) -> bool {
    match &op.payload {
        CrdtPayload::ServerCreated { owner_peer_id, nonce, .. } => {
            op.author == *owner_peer_id
                && super::authority::nonce_commitment(nonce).is_some()
                && super::anchor::derive_server_id(owner_peer_id, nonce) == server_id
        }
        _ => false,
    }
}

fn proof_device(op: &CrdtOp) -> Option<String> {
    op.dev.as_deref().map(|d| d.device.clone())
}

fn print_of<'a>(hashes: impl Iterator<Item = &'a [u8; 32]>) -> String {
    let (n, sum) = hashes.fold((0u64, 0u128), |(n, sum), h| {
        (n + 1, sum.wrapping_add(u128::from_be_bytes(h[..16].try_into().expect("16 bytes"))))
    });
    format!("{n}:{sum:032x}")
}

/// Ops that can make a held op valid: an admission, a grant, a lock link the next one
/// extends, the join key an ask names, or the anchor itself.
pub(super) fn enables_others(payload: &CrdtPayload) -> bool {
    matches!(
        payload,
        CrdtPayload::MemberAdded { .. }
            | CrdtPayload::JoinLock { .. }
            | CrdtPayload::RoleChanged { .. }
            | CrdtPayload::RolePermissionsChanged { .. }
            | CrdtPayload::MemberUnbanned { .. }
            | CrdtPayload::LabelCreated { .. }
            | CrdtPayload::LabelUpdated { .. }
            | CrdtPayload::ChannelAdded { .. }
            | CrdtPayload::ServerSettingChanged { .. }
            | CrdtPayload::JoinKeySet { .. }
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

fn log_equivocation(op: &CrdtOp) {
    crate::hollow_log!(
        "[HOLLOW-SECURITY] Two different CrdtOps at one clock in {} by {}: keeping the lower hash",
        op.server_id, op.author,
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crdt::hlc::Hlc;
    use crate::crdt::operations::{CrdtPayload as P, MemberRole, SeenGrants};
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
            dev: None,
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

    /// Invite reset: an admission on an ask made with the link the owner's reset retired
    /// counts nowhere the reset is held, whichever order the two arrive in, while one made
    /// with the new link lands either way.
    #[test]
    fn an_old_link_admission_after_an_invite_reset_is_void_in_any_order() {
        let (s, founding) = founded(1);
        let sid = s.server_id.clone();
        let t = super::super::hlc::wall_clock_ms();
        let secret = |b: u8| crate::crdt::operations::JoinSecret(hex::encode([b; 32]));
        let link = |b: u8| crate::node::sealed_box::key_to_text(&crate::node::sealed_box::public_of(&[b; 32]));
        let admit = |tag: u8, key: &str| {
            let ask = crate::crdt::operations::JoinAsk::sign_for_invite(&sid, 1, key, &keys(tag).0).unwrap();
            P::MemberAdded { peer_id: id(tag), display_name: "m".into(), follow: None, ask: Some(ask) }
        };
        let first_key = op_at(1, &sid, t + 1, P::JoinKeySet { secret: secret(1) });
        let reset = op_at(1, &sid, t + 2, P::JoinKeySet { secret: secret(2) });
        let old_link = op_at(1, &sid, t + 3, admit(2, &link(1)));
        let new_link = op_at(1, &sid, t + 4, admit(3, &link(2)));

        let mut in_order = joiner(&sid, 9);
        let _ = in_order.ingest_remote(&[founding.clone(), first_key.clone(), reset.clone(), old_link.clone(), new_link.clone()]);
        let mut reset_last = joiner(&sid, 9);
        let _ = reset_last.ingest_remote(&[founding, first_key, old_link, new_link]);
        assert!(reset_last.is_member(&id(2)), "precondition: before the reset lands, the old link still holds");
        let _ = reset_last.ingest_remote(&[reset]);
        for s in [&in_order, &reset_last] {
            assert!(!s.is_member(&id(2)), "an old-link admission after the reset counts for nothing");
            assert!(s.is_member(&id(3)), "a new-link admission lands");
        }
    }

    /// Invite reset: a keyless ask (an older client) folds before any reset and opens
    /// no span after one, in order and when the reset arrives last and the log refolds.
    #[test]
    fn a_keyless_admission_counts_before_a_reset_and_not_after() {
        let (s, founding) = founded(1);
        let sid = s.server_id.clone();
        let t = founding.hlc.physical_ms;
        let keyless = |tag: u8| P::MemberAdded {
            peer_id: id(tag), display_name: "m".into(), follow: None,
            ask: Some(crate::crdt::operations::JoinAsk::sign(&sid, 1, &keys(tag).0)),
        };
        let first_key = op_at(1, &sid, t + 1, P::JoinKeySet { secret: crate::crdt::operations::JoinSecret(hex::encode([1u8; 32])) });
        let add2 = op_at(1, &sid, t + 2, add(&sid, 2));
        let before = op_at(2, &sid, t + 3, keyless(4));
        let reset = op_at(1, &sid, t + 4, P::JoinKeySet { secret: crate::crdt::operations::JoinSecret(hex::encode([2u8; 32])) });
        let after = op_at(2, &sid, t + 5, keyless(3));

        let mut in_order = joiner(&sid, 9);
        let _ = in_order.ingest_remote(&[founding.clone(), first_key.clone(), add2.clone(), before.clone(), reset.clone(), after.clone()]);
        let mut reset_last = joiner(&sid, 9);
        let _ = reset_last.ingest_remote(&[founding, first_key, add2, before, after]);
        assert!(reset_last.is_member(&id(3)), "precondition: with no reset held, a keyless ask still opens a span");
        let _ = reset_last.ingest_remote(&[reset]);
        for s in [&in_order, &reset_last] {
            assert!(s.is_member(&id(4)), "a keyless admission before the reset stays");
            assert!(!s.is_member(&id(3)), "a keyless admission after the reset counts for nothing");
        }
    }

    /// A member's legacy join snapshot brings the newest eight retired keys and never the
    /// current one: a joiner folds no reset, and each key costs every later join box an open.
    #[test]
    fn a_join_snapshot_brings_the_newest_eight_retired_keys() {
        let (legacy, _) = crate::crdt::testkeys::owned_state("s-legacy", "Old", 1);
        let mut snap = legacy.lean_snapshot();
        for i in 0..200u32 {
            let at = HlcTimestamp { physical_ms: u64::from(i), counter: 0, actor: "x".into() };
            snap.join_secrets_retired.push((at, crate::crdt::operations::JoinSecret(format!("{:064x}", i + 1))));
        }
        let got = ServerState::accept_join_snapshot(snap.clone(), "s-legacy", None).unwrap();
        assert_eq!(got.join_secrets_retired.len(), 8, "kept {} retired keys from a member's snapshot", got.join_secrets_retired.len());
        assert_eq!(got.join_secrets_retired[0].0.physical_ms, 199, "the newest");
        let mut current = snap.clone();
        let key = crate::crdt::operations::JoinSecret(format!("{:064x}", 200));
        current.join_secret = Some(crate::crdt::admin_lww::AdminLwwReg::new(key.clone(), HlcTimestamp { physical_ms: 300, counter: 0, actor: "x".into() }, 4));
        let got = ServerState::accept_join_snapshot(current, "s-legacy", None).unwrap();
        assert!(!got.join_secrets_retired.iter().any(|(_, s)| *s == key), "the key in force is never retired");
        let stored: ServerState = serde_json::from_str(&serde_json::to_string(&snap).unwrap()).unwrap();
        assert_eq!(stored.join_secrets_retired.len(), 8, "a stored state keeps the newest eight");
        assert_eq!(stored.join_secrets_retired[0].0.physical_ms, 199, "newest first");
        let mut rebased = ServerState::skeleton("s-legacy".into());
        rebased.rebase_on(snap, "owner", &HlcTimestamp { physical_ms: 500, counter: 0, actor: "x".into() });
        assert_eq!(rebased.join_secrets_retired.len(), 8, "and so does a checkpoint");
    }

    /// Invite reset: a request with no ask is refused for its link before any gate that
    /// names the server.
    #[test]
    fn an_askless_request_meets_the_link_gate_first() {
        let (s0, founding) = founded(1);
        let sid = s0.server_id.clone();
        let t = founding.hlc.physical_ms;
        let mut s = joiner(&sid, 9);
        let _ = s.ingest_remote(&[
            founding,
            op_at(1, &sid, t + 1, P::JoinKeySet { secret: crate::crdt::operations::JoinSecret(hex::encode([1u8; 32])) }),
            op_at(1, &sid, t + 2, P::JoinKeySet { secret: crate::crdt::operations::JoinSecret(hex::encode([2u8; 32])) }),
            op_at(1, &sid, t + 3, P::ServerSettingChanged { key: "is_private".into(), value: "true".into() }),
        ]);
        assert_eq!(s.retired_join_secrets().len(), 1);
        let judge = |old_link: bool| crate::node::join_verdict::verdict(&s, &id(5), false, false, None, old_link, None, false, &id(1), |_| false);
        let refused = |reason: &str| crate::node::join_verdict::Verdict::Refuse { reason: reason.into(), settles: true };
        assert_eq!(judge(true), refused(crate::node::join_verdict::INVITE_RESET), "a retired key opened its box");
        assert_eq!(judge(false), refused(crate::node::sync_handler::INVITE_OUTDATED), "it names no key");
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
            op_at(1, &sid, t + 4, P::MemberRemoved { peer_id: id(2), seen: None }),
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

    /// HOL-SEC-222's one founding op per id judges self-certifying ids only: a legacy id's
    /// founding op, which no id proves, still founds a fresh replica.
    #[test]
    fn a_legacy_founding_op_still_founds_a_fresh_replica() {
        let sid = "s-legacy";
        let founding = op_at(1, sid, super::super::hlc::wall_clock_ms(), P::ServerCreated { name: "Old".into(), owner_peer_id: id(1), nonce: String::new() });
        let mut r = joiner(sid, 9);
        r.ingest_remote(std::slice::from_ref(&founding));
        assert_eq!(r.current_owner(), Some(id(1)), "the legacy founding op founded nothing");
        assert_eq!(r.name(), "Old");
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
        let witnessed = op_at(2, &legacy.server_id, now + 60_000, P::NicknameChanged { peer_id: id(2), nickname: "seen".into() });
        legacy.ingest_remote(std::slice::from_ref(&witnessed));
        let covers = legacy.checkpoint_covers();
        assert!(covers >= witnessed.hlc, "a legacy checkpoint covers everything its owner witnessed");
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

        let late_old = op_at(1, &legacy.server_id, now + 30_000, P::ChannelRenamed { channel_id: ch.clone(), new_name: "stale".into() });
        let checkpoint = legacy.author_checked(P::ServerCheckpoint { state: json, covers: covers.clone() }).unwrap();
        member.ingest_remote(std::slice::from_ref(&checkpoint));
        assert_eq!(member.anchor(), Anchor::Checkpoint);
        assert_eq!(member.owner_pin.as_deref(), Some(o.as_str()));
        assert_eq!(member.op_log.len(), 1, "everything the checkpoint decided leaves the fold");

        member.ingest_remote(std::slice::from_ref(&late_old));
        assert_eq!(member.channels[&ch].name, "general", "a legacy server's first checkpoint decides everything its owner had witnessed");
        let newer = op_at(1, &legacy.server_id, checkpoint.hlc.physical_ms + 1, P::ChannelRenamed { channel_id: ch.clone(), new_name: "new".into() });
        member.ingest_remote(std::slice::from_ref(&newer));
        assert_eq!(member.channels[&ch].name, "new");

        let again = op_at(2, &legacy.server_id, newer.hlc.physical_ms + 1, P::ServerCheckpoint {
            state: member.checkpoint_json(&id(2), &[], now).unwrap(), covers: member.checkpoint_covers(),
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

        let covers = away.checkpoint_covers();
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
            op_at(1, &sid, t + 2 * hour, P::MemberRemoved { peer_id: id(2), seen: None }),
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
        let covers = owner.checkpoint_covers();
        let json = owner.checkpoint_json(&id(1), &[], covers.physical_ms).unwrap();
        let checkpoint = owner.author_checked(P::ServerCheckpoint { state: json, covers }).unwrap();
        let demoted = op_at(1, &sid, t + hour, P::RoleChanged { peer_id: id(2), role: MemberRole::Member, priority: 4 });
        let mut live = joiner(&sid, 3);
        live.ingest_remote(&history);
        live.ingest_remote(&[checkpoint, demoted]);
        assert_eq!(live.anchor(), Anchor::Checkpoint);

        let mut restarted = live.clone();
        let mut stored: Vec<(CrdtOp, Option<u64>)> = restarted.served_log().into_iter().map(|o| (o.clone(), None)).collect();
        stored.sort_by(|a, b| (a.0.hlc.physical_ms, a.0.hlc.counter, &a.0.author).cmp(&(b.0.hlc.physical_ms, b.0.hlc.counter, &b.0.author)));
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
        clock_first.restore_op_log(live.op_log.iter().map(|o| (o.clone(), None)).collect());
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
        r.ingest_remote(&[founding.clone(), op_at(1, &sid, founding.hlc.physical_ms + 1, add(&sid, 2))]);
        let wall = crate::crdt::hlc::wall_clock_ms();
        let early = op_at(2, &sid, wall + 120_000, P::ServerRenamed { new_name: "n".into() });
        assert!(r.ingest_remote(&[early]).admitted.is_empty());
        assert!(!r.held.is_empty(), "fixture: a member's op its role does not allow yet is held");
        r.set_hlc(Hlc::for_device(id(9), "device"));
        assert!(r.create_op(P::ServerRenamed { new_name: "x".into() }).hlc.physical_ms < wall + 60_000, "a held op moved our clock");
    }

    // ---- t14-cover: checkpoint coverage (design rev 2 + review rev 2) ----

    /// A rejoin's admission, on a fresh ask of its own.
    fn readd(sid: &str, tag: u8, at: i64) -> P {
        let ask = crate::crdt::operations::JoinAsk::sign(sid, at, &keys(tag).0);
        P::MemberAdded { peer_id: id(tag), display_name: "m".into(), follow: None, ask: Some(ask) }
    }

    /// The owner's checkpoint of what `owner` holds now, already its base.
    fn checkpoint(owner: &mut ServerState) -> CrdtOp {
        let covers = owner.checkpoint_covers();
        let json = owner.checkpoint_json(&id(1), &[], crate::crdt::hlc::wall_clock_ms()).unwrap();
        owner.author_checkpoint(P::ServerCheckpoint { state: json, covers }).expect("the owner's checkpoint becomes its base").0
    }

    /// Everything a replica's fold decided, with what only says how it got there (stamps,
    /// events, anchors, inert register priorities) left out.
    fn view(s: &ServerState) -> serde_json::Value {
        fn strip(v: &mut serde_json::Value) {
            match v {
                serde_json::Value::Object(m) => {
                    m.remove("priority");
                    m.values_mut().for_each(strip);
                }
                serde_json::Value::Array(a) => a.iter_mut().for_each(strip),
                _ => {}
            }
        }
        let mut v = serde_json::to_value(s.lean_snapshot()).unwrap();
        let o = v.as_object_mut().unwrap();
        for k in ["stamps", "member_events", "checkpoint_hlc", "owner_pin", "retained_print", "cp_generation", "cp_parent", "cp_stamped"] {
            o.remove(k);
        }
        strip(&mut v);
        v
    }

    fn keys_of(s: &ServerState) -> Vec<OpKey> {
        s.served_log().iter().map(|o| (o.author.clone(), o.hlc.clone())).collect()
    }

    /// A founded server with 2 an admin, 3 a moderator and 4 a member, all owner-admitted.
    fn staffed() -> (ServerState, Vec<CrdtOp>, u64) {
        let (mut owner, founding) = founded(1);
        let sid = owner.server_id.clone();
        let t = founding.hlc.physical_ms;
        let ops = vec![
            founding,
            op_at(1, &sid, t + 1, add(&sid, 2)),
            op_at(1, &sid, t + 2, add(&sid, 3)),
            op_at(1, &sid, t + 3, add(&sid, 4)),
            op_at(1, &sid, t + 4, P::RoleChanged { peer_id: id(2), role: MemberRole::Admin, priority: 3 }),
            op_at(1, &sid, t + 5, P::RoleChanged { peer_id: id(3), role: MemberRole::Moderator, priority: 3 }),
        ];
        owner.ingest_remote(&ops[1..]);
        (owner, ops, t)
    }

    /// U2: whatever the owner never folded survives its checkpoint, on a replica that got
    /// it before the checkpoint, one that got it after, and the owner itself.
    #[test]
    fn a_checkpoint_never_drops_an_op_its_owner_did_not_fold() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let ch = general(&owner);
        let mut sibling = owner.clone();
        sibling.set_hlc(Hlc::for_device(id(1), "owner-laptop"));
        let unseen = vec![
            op_at(4, &sid, t + 10, P::MemberRemoved { peer_id: id(4), seen: None }),
            op_at(2, &sid, t + 11, readd(&sid, 5, (t + 11) as i64)),
            op_at(2, &sid, t + 12, P::RoleChanged { peer_id: id(5), role: MemberRole::Moderator, priority: 2 }),
            op_at(2, &sid, t + 13, readd(&sid, 6, (t + 13) as i64)),
            op_at(3, &sid, t + 14, P::MemberBanned { peer_id: id(6), seen: None }),
            op_at(2, &sid, t + 15, P::ChannelRenamed { channel_id: ch.clone(), new_name: "by-admin".into() }),
            sibling.author_checked(P::NicknameChanged { peer_id: id(1), nickname: "from-the-laptop".into() }).unwrap(),
        ];
        let cp = checkpoint(&mut owner);
        let mut before = joiner(&sid, 9);
        before.ingest_remote(&history);
        before.ingest_remote(&unseen);
        before.ingest_remote(std::slice::from_ref(&cp));
        let mut after = joiner(&sid, 8);
        after.ingest_remote(&history);
        after.ingest_remote(std::slice::from_ref(&cp));
        after.ingest_remote(&unseen);
        owner.ingest_remote(&unseen);
        let mut oracle = joiner(&sid, 7);
        oracle.ingest_remote(&history);
        oracle.ingest_remote(&unseen);
        for s in [&before, &after, &owner] {
            assert!(!s.is_member(&id(4)), "the late leave lands");
            assert!(s.is_member(&id(5)) && s.get_role(&id(5)) == MemberRole::Moderator, "the member-admitted join and its promotion land");
            assert!(!s.is_member(&id(6)) && s.is_banned(&id(6)), "the moderator's ban lands");
            assert_eq!(s.channels[&ch].name, "by-admin");
            assert_eq!(s.get_nickname(&id(1)), "from-the-laptop", "the owner sibling's op lands");
            assert_eq!(view(s), view(&oracle), "the rebase equals the fold from history");
        }
        assert_eq!(keys_of(&before), keys_of(&after));
    }

    /// U3: the uncovered ops fold the same in every arrival order and batching.
    #[test]
    fn uncovered_ops_fold_the_same_in_every_order() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let unban = op_at(1, &sid, t + 40, P::MemberUnbanned { peer_id: id(3) });
        let ban = op_at(1, &sid, t + 30, P::MemberBanned { peer_id: id(3), seen: None });
        owner.ingest_remote(std::slice::from_ref(&unban));
        let cp = checkpoint(&mut owner);
        let uncovered = vec![
            op_at(4, &sid, t + 20, P::MemberRemoved { peer_id: id(4), seen: None }),
            op_at(2, &sid, t + 25, readd(&sid, 4, (t + 24) as i64)),
            ban,
            op_at(2, &sid, t + 50, readd(&sid, 4, (t + 24) as i64)),
            op_at(1, &sid, t + 60, readd(&sid, 3, (t + 59) as i64)),
        ];
        let mut all = uncovered.clone();
        all.push(cp);
        let mut views = Vec::new();
        let n = all.len();
        let mut perm: Vec<usize> = (0..n).collect();
        // Heap's algorithm over every order of the six ops.
        let mut c = vec![0usize; n];
        let mut fold = |order: &[usize]| {
            let mut r = joiner(&sid, 9);
            r.ingest_remote(&history);
            for i in order {
                r.ingest_remote(std::slice::from_ref(&all[*i]));
            }
            let mut batched = joiner(&sid, 8);
            batched.ingest_remote(&history);
            let ops: Vec<CrdtOp> = order.iter().map(|i| all[*i].clone()).collect();
            batched.ingest_remote(&ops);
            assert_eq!(view(&r), view(&batched), "one batch and one op at a time differ");
            views.push((view(&r), keys_of(&r)));
        };
        fold(&perm);
        let mut i = 0;
        while i < n {
            if c[i] < i {
                if i % 2 == 0 { perm.swap(0, i) } else { perm.swap(c[i], i) }
                fold(&perm);
                c[i] += 1;
                i = 0;
            } else {
                c[i] = 0;
                i += 1;
            }
        }
        assert!(views.windows(2).all(|w| w[0] == w[1]), "an arrival order changed the state");
        let r = &views[0].0;
        assert!(r["members"].get(id(4)).is_some(), "the rejoin on a newer ask stands after the late leave");
        assert!(r["members"].get(id(3)).is_some(), "the covered unban lets the re-admission in");
    }

    /// U5: an owner device back after months writes a child of the base it held; what
    /// members did meanwhile is newer than its stamps and folds on top.
    #[test]
    fn a_stale_checkpoint_undoes_nothing_members_did() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let ch = general(&owner);
        let _ = checkpoint(&mut owner);
        let mut stale = owner.clone();
        stale.set_hlc(Hlc::for_device(id(1), "old-laptop"));
        let meanwhile = vec![
            op_at(2, &sid, t + 100, readd(&sid, 5, (t + 100) as i64)),
            op_at(2, &sid, t + 101, P::ChannelRenamed { channel_id: ch.clone(), new_name: "meanwhile".into() }),
            op_at(4, &sid, t + 102, P::MemberRemoved { peer_id: id(4), seen: None }),
        ];
        owner.ingest_remote(&meanwhile);
        let fresh = checkpoint(&mut owner);
        let old = checkpoint(&mut stale);
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(&meanwhile);
        r.ingest_remote(&[old.clone(), fresh.clone()]);
        let mut s = joiner(&sid, 8);
        s.ingest_remote(&history);
        s.ingest_remote(&[fresh, old]);
        s.ingest_remote(&meanwhile);
        for x in [&r, &s] {
            assert!(x.is_member(&id(5)) && !x.is_member(&id(4)));
            assert_eq!(x.channels[&ch].name, "meanwhile");
        }
        assert_eq!(view(&r), view(&s));
        assert_eq!(keys_of(&r), keys_of(&s));
    }

    /// U7: a replay of an op the base decided drops at the door: no rebuild, no row.
    #[test]
    fn a_dominated_replay_is_dropped_without_a_rebuild() {
        let (mut owner, history, _) = staffed();
        let cp = checkpoint(&mut owner);
        let mut r = joiner(&owner.server_id, 9);
        r.ingest_remote(&history);
        r.ingest_remote(std::slice::from_ref(&cp));
        let out = r.ingest_remote(&history[1..]);
        assert!(!out.rebuilt && out.admitted.is_empty(), "a decided replay rebuilt or folded");
        let _ = &out.rows;
    }

    /// U8 and the review's F4 path: three owner devices checkpoint from one parent; each
    /// replica takes another path, and all converge on one base with nothing lost.
    #[test]
    fn rival_owner_checkpoints_converge_without_loss() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let c1 = checkpoint(&mut owner);
        let devices: Vec<ServerState> = ["a", "b", "c"]
            .iter()
            .map(|d| {
                let mut s = owner.clone();
                s.set_hlc(Hlc::for_device(id(1), d));
                s
            })
            .collect();
        let mut cps = Vec::new();
        let mut seen = Vec::new();
        for (i, mut dev) in devices.into_iter().enumerate() {
            let op = op_at(2, &sid, t + 200 + i as u64, P::NicknameChanged { peer_id: id(2), nickname: format!("seen-by-{i}") });
            let mine = op_at(4, &sid, t + 210 + i as u64, P::NicknameChanged { peer_id: id(4), nickname: format!("{i}") });
            dev.ingest_remote(&[op.clone(), mine.clone()]);
            seen.push(op);
            seen.push(mine);
            std::thread::sleep(std::time::Duration::from_millis(2));
            cps.push(checkpoint(&mut dev));
        }
        let paths: [&[usize]; 4] = [&[0, 1, 2], &[1, 2], &[2, 0, 1], &[2, 1, 0]];
        let mut results = Vec::new();
        for path in paths {
            let mut r = joiner(&sid, 9);
            r.ingest_remote(&history);
            r.ingest_remote(std::slice::from_ref(&c1));
            for i in path {
                r.ingest_remote(&seen[2 * i..2 * i + 2]);
                r.ingest_remote(std::slice::from_ref(&cps[*i]));
            }
            // Whatever the path missed reaches it by sync from a replica on another.
            for i in 0..3 {
                r.ingest_remote(&seen[2 * i..2 * i + 2]);
                r.ingest_remote(std::slice::from_ref(&cps[i]));
            }
            assert_eq!(r.get_nickname(&id(4)), "2", "the newest write wins");
            assert_eq!(r.get_nickname(&id(2)), "seen-by-2");
            results.push((view(&r), keys_of(&r)));
        }
        assert!(results.windows(2).all(|w| w[0] == w[1]), "replicas on different paths diverge");
    }

    /// The review's probe: two owner devices checkpoint at once; the later never saw an op
    /// the earlier folded. Today the op is wiped on every replica holding both.
    #[test]
    fn probe_concurrent_owner_checkpoints_lose_an_op_today() {
        let (kp, owner_id, pk) = keys(1);
        let (mut dev_a, founding) = founded(1);
        let sid = dev_a.server_id.clone();
        let t = founding.hlc.physical_ms;
        let admit2 = dev_a.author_checked(add(&sid, 2)).expect("owner admits");
        let mut dev_b = dev_a.clone();
        dev_b.set_hlc(crate::crdt::hlc::Hlc::for_device(owner_id.clone(), "owner-device-b"));
        dev_b.set_signer(kp, pk);
        std::thread::sleep(std::time::Duration::from_millis(5));
        let x = op_at(2, &sid, t + 10, P::NicknameChanged { peer_id: id(2), nickname: "seen-by-a".into() });
        assert_eq!(dev_a.ingest_remote(std::slice::from_ref(&x)).admitted.len(), 1);
        let cp_a = checkpoint(&mut dev_a);
        std::thread::sleep(std::time::Duration::from_millis(5));
        let y = dev_b.author_checked(P::ServerRenamed { new_name: "by-b".into() }).expect("y");
        let cp_b = checkpoint(&mut dev_b);
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&[founding, admit2, x, cp_a, y, cp_b]);
        assert_eq!(r.name(), "by-b");
        assert_eq!(r.get_nickname(&id(2)), "seen-by-a", "an op owner device A folded and checkpointed is wiped by device B's checkpoint");
    }

    /// U9: a member can make no checkpoint, so nothing it sends makes the base decide,
    /// and so drop, another author's op.
    #[test]
    fn nothing_a_member_sends_makes_the_base_drop_another_authors_op() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let ch = general(&owner);
        let cp = checkpoint(&mut owner);
        let mut forged = owner.lean_snapshot();
        forged.cp_generation = 99;
        forged.cp_stamped = true;
        let theirs = op_at(4, &sid, t + 300, P::ServerCheckpoint { state: serde_json::to_string(&forged).unwrap(), covers: cp.hlc.clone() });
        let rename = op_at(2, &sid, t + 290, P::ChannelRenamed { channel_id: ch.clone(), new_name: "x".into() });
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(&[cp.clone(), theirs]);
        assert_eq!(r.base.as_ref().map(|b| b.hash), Some(cp.content_hash()), "a member's checkpoint is no base");
        let _ = r.ingest_remote(std::slice::from_ref(&rename));
        assert!(r.op_log.iter().any(|o| o.hlc == rename.hlc), "another author's op folds");
    }

    /// U11: an op the base does not decide is judged by today's authority: a demoted
    /// admin's backdated act, a kicked member's backdated admission, an author not yet a
    /// member, a spent ask inside a gap (H2), an ask older than the asker's own leave (F9).
    #[test]
    fn a_late_op_is_judged_by_todays_authority() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let ch = general(&owner);
        owner.ingest_remote(&[op_at(1, &sid, t + 20, P::RoleChanged { peer_id: id(2), role: MemberRole::Member, priority: 3 })]);
        let cp = checkpoint(&mut owner);
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(std::slice::from_ref(&cp));
        let demoted = op_at(2, &sid, t + 10, P::ChannelRenamed { channel_id: ch.clone(), new_name: "late".into() });
        r.ingest_remote(std::slice::from_ref(&demoted));
        assert_eq!(r.channels[&ch].name, "general", "a since-demoted admin's backdated act is refused");
        let stranger = op_at(7, &sid, t + 30, P::NicknameChanged { peer_id: id(7), nickname: "x".into() });
        assert!(r.ingest_remote(std::slice::from_ref(&stranger)).admitted.is_empty(), "an author not yet a member");
    }

    /// The review's probe: a kicked member signs an admission dated before its kick. Once
    /// the owner's base holds the kick, the admission is judged by today's authority.
    /// Residual: before the base holds it, both fold in clock order (design section 6).
    #[test]
    fn probe_a_kicked_member_backdates_an_admission_today() {
        let (mut owner, founding) = founded(1);
        let sid = owner.server_id.clone();
        let t = founding.hlc.physical_ms;
        let history = vec![
            founding.clone(),
            op_at(1, &sid, t + 1, add(&sid, 2)),
            op_at(1, &sid, t + 10, P::MemberRemoved { peer_id: id(2), seen: None }),
        ];
        owner.ingest_remote(&history[1..]);
        let cp = checkpoint(&mut owner);
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(std::slice::from_ref(&cp));
        assert!(!r.is_member(&id(2)));
        let backdated = op_at(2, &sid, t + 9, add(&sid, 5));
        r.ingest_remote(std::slice::from_ref(&backdated));
        assert!(!r.is_member(&id(5)), "a kicked member's backdated admission seated a newcomer");
    }

    /// The review's F9 probe: an ask signed before the asker's own leave never re-admits it.
    #[test]
    fn probe_an_ask_older_than_the_askers_own_leave_readmits_it() {
        let (owner, founding) = founded(1);
        let sid = owner.server_id.clone();
        let t = founding.hlc.physical_ms;
        let early = crate::crdt::operations::JoinAsk::sign(&sid, (t + 5) as i64, &keys(2).0);
        let again = P::MemberAdded { peer_id: id(2), display_name: "m".into(), follow: None, ask: Some(early) };
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&[
            founding.clone(),
            op_at(1, &sid, t + 1, add(&sid, 2)),
            op_at(1, &sid, t + 2, add(&sid, 3)),
            op_at(2, &sid, t + 10, P::MemberRemoved { peer_id: id(2), seen: None }),
            op_at(3, &sid, t + 20, again),
        ]);
        assert!(!r.is_member(&id(2)), "an ask signed before the asker's own leave brought it back");
    }

    /// HOL-SEC-207 (w2-d follow-up): J leaves inside a clock lead, rejoins on an ask
    /// stamped past that leave and naming it, and leaves again inside the same lead. A
    /// spare ask of that rejoin (a re-ask, stamped past the second leave too) handed to a
    /// member after it re-admits nobody, whoever authors the admission. An ask naming the
    /// second leave, or signed after it, still does.
    #[test]
    fn a_spare_reask_folds_out_after_a_second_leave() {
        let (owner, founding) = founded(1);
        let sid = owner.server_id.clone();
        let t = founding.hlc.physical_ms;
        let ask = |at: u64, leave: &CrdtOp, made: u64| {
            let ask = crate::crdt::operations::JoinAsk::sign_rejoin(&sid, at as i64, None, Some(&leave.hlc), made as i64, &keys(2).0).unwrap();
            assert!(ask.follows.is_some(), "an ask stamped past its signing names the leave");
            ask
        };
        let admit = |ask| P::MemberAdded { peer_id: id(2), display_name: "m".into(), follow: None, ask: Some(ask) };
        // The lead: J's clock sits 100 ms past the wall (`t + 1`).
        let first_leave = op_at(2, &sid, t + 100, P::MemberRemoved { peer_id: id(2), seen: None });
        let second_leave = op_at(2, &sid, t + 103, P::MemberRemoved { peer_id: id(2), seen: None });
        let history = vec![
            founding.clone(),
            op_at(1, &sid, t + 1, add(&sid, 2)),
            op_at(1, &sid, t + 2, add(&sid, 3)),
            first_leave.clone(),
            op_at(3, &sid, t + 102, admit(ask(t + 101, &first_leave, t + 1))),
            second_leave.clone(),
        ];
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        assert!(!r.is_member(&id(2)), "precondition: J left twice");
        let spare = op_at(3, &sid, t + 105, admit(ask(t + 104, &first_leave, t + 2)));
        assert!(!r.op_allowed(&spare), "a spare ask from before the second leave re-admitted J");
        r.ingest_remote(std::slice::from_ref(&spare));
        assert!(!r.is_member(&id(2)), "a spare ask from before the second leave re-admitted J");
        let at_the_leave = op_at(3, &sid, t + 105, admit(ask(t + 104, &first_leave, t + 103)));
        assert!(!r.op_allowed(&at_the_leave), "an ask signed at the second leave's own millisecond counts as before it");
        let unheard = op_at(3, &sid, t + 106, admit(ask(t + 105, &first_leave, t + 104)));
        assert!(r.op_allowed(&unheard), "an ask signed after the second leave, naming the first, counts by when it was signed");
        let fresh = op_at(3, &sid, t + 106, admit(ask(t + 104, &second_leave, t + 3)));
        r.ingest_remote(std::slice::from_ref(&fresh));
        assert!(r.is_member(&id(2)), "J's own ask naming its second leave re-admits it");
        // The owner kicks J inside the lead: an ask J made before the kick, naming its own
        // last leave, brings it back no more than one from before a leave would.
        r.ingest_remote(&[op_at(1, &sid, t + 108, P::MemberRemoved { peer_id: id(2), seen: None })]);
        assert!(!r.is_member(&id(2)), "precondition: J was kicked");
        let pre_kick = op_at(3, &sid, t + 110, admit(ask(t + 109, &second_leave, t + 4)));
        assert!(!r.op_allowed(&pre_kick), "an ask made before the kick re-admitted J");
        let after_kick = op_at(3, &sid, t + 111, admit(ask(t + 110, &second_leave, t + 109)));
        assert!(r.op_allowed(&after_kick), "an ask J signed after the kick is judged as any rejoin");
        // Judged at its own point: an earlier admission on the rejoin's own ask moves that
        // span back, though leaves and a kick came after it.
        let earlier = op_at(3, &sid, t + 101, admit(ask(t + 101, &first_leave, t + 1)));
        assert!(r.op_allowed(&earlier), "the later leaves judged an admission dated before them");
    }

    /// HOL-SEC-207: the verdict does not hang on arrival order. A hears the second leave
    /// before the spare admission; B hears the spare first (J still in on its rejoin, so it
    /// only repeats) and the second leave late; C takes them in one batch.
    #[test]
    fn a_spare_reask_folds_out_whichever_arrives_first() {
        let (_owner, founding) = founded(1);
        let sid = founding.server_id.clone();
        let t = founding.hlc.physical_ms;
        let ask = |at: u64, leave: &CrdtOp, made: u64| {
            crate::crdt::operations::JoinAsk::sign_rejoin(&sid, at as i64, None, Some(&leave.hlc), made as i64, &keys(2).0).unwrap()
        };
        let admit = |ask| P::MemberAdded { peer_id: id(2), display_name: "m".into(), follow: None, ask: Some(ask) };
        let first_leave = op_at(2, &sid, t + 100, P::MemberRemoved { peer_id: id(2), seen: None });
        let second_leave = op_at(2, &sid, t + 103, P::MemberRemoved { peer_id: id(2), seen: None });
        let base = vec![
            founding.clone(),
            op_at(1, &sid, t + 1, add(&sid, 2)),
            op_at(1, &sid, t + 2, add(&sid, 3)),
            first_leave.clone(),
            op_at(3, &sid, t + 102, admit(ask(t + 101, &first_leave, t + 1))),
        ];
        let spare = op_at(3, &sid, t + 105, admit(ask(t + 104, &first_leave, t + 2)));

        let mut a = joiner(&sid, 9);
        a.ingest_remote(&base);
        a.ingest_remote(std::slice::from_ref(&second_leave));
        a.ingest_remote(std::slice::from_ref(&spare));

        let mut b = joiner(&sid, 8);
        b.ingest_remote(&base);
        b.ingest_remote(std::slice::from_ref(&spare));
        b.ingest_remote(std::slice::from_ref(&second_leave));

        let mut c = joiner(&sid, 7);
        let mut all = base.clone();
        all.push(spare.clone());
        all.push(second_leave.clone());
        c.ingest_remote(&all);

        assert!(!a.is_member(&id(2)), "A: leave first, spare refused");
        assert_eq!(a.is_member(&id(2)), c.is_member(&id(2)), "one batch disagrees with leave-first");
        assert_eq!(a.is_member(&id(2)), b.is_member(&id(2)), "spare-first then late leave disagrees with leave-first");
    }

    /// HOL-SEC-207 on an owner checkpoint base: the leave that closed J's span before the
    /// spare is read from the base's record, not only from ops the replica folded.
    #[test]
    fn a_spare_reask_folds_out_on_a_checkpoint_base() {
        let (mut owner, founding) = founded(1);
        let sid = owner.server_id.clone();
        let t = founding.hlc.physical_ms;
        let ask = |at: u64, leave: &CrdtOp, made: u64| {
            crate::crdt::operations::JoinAsk::sign_rejoin(&sid, at as i64, None, Some(&leave.hlc), made as i64, &keys(2).0).unwrap()
        };
        let admit = |ask| P::MemberAdded { peer_id: id(2), display_name: "m".into(), follow: None, ask: Some(ask) };
        let first_leave = op_at(2, &sid, t + 100, P::MemberRemoved { peer_id: id(2), seen: None });
        let second_leave = op_at(2, &sid, t + 103, P::MemberRemoved { peer_id: id(2), seen: None });
        let base = vec![
            op_at(1, &sid, t + 1, add(&sid, 2)),
            op_at(1, &sid, t + 2, add(&sid, 3)),
            first_leave.clone(),
            op_at(3, &sid, t + 102, admit(ask(t + 101, &first_leave, t + 1))),
            second_leave.clone(),
        ];
        owner.ingest_remote(&base);
        assert!(!owner.is_member(&id(2)));
        let cp = checkpoint(&mut owner);
        let spare = op_at(3, &sid, t + 105, admit(ask(t + 104, &first_leave, t + 2)));
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&[founding.clone(), cp.clone()]);
        assert!(!r.is_member(&id(2)), "precondition on the base");
        r.ingest_remote(std::slice::from_ref(&spare));
        assert!(!r.is_member(&id(2)), "a checkpoint base let the spare re-admit J");
        owner.ingest_remote(std::slice::from_ref(&spare));
        assert!(!owner.is_member(&id(2)), "owner re-admitted on the spare");
    }

    /// HOL-SEC-207: a second leave in the same millisecond as the rejoin's admission (a
    /// later counter) still closes the span the spare would reopen.
    #[test]
    fn a_spare_reask_folds_out_after_a_leave_in_the_admissions_millisecond() {
        let (_owner, founding) = founded(1);
        let sid = founding.server_id.clone();
        let t = founding.hlc.physical_ms;
        let ask = |at: u64, leave: &CrdtOp, made: u64| {
            crate::crdt::operations::JoinAsk::sign_rejoin(&sid, at as i64, None, Some(&leave.hlc), made as i64, &keys(2).0).unwrap()
        };
        let admit = |ask| P::MemberAdded { peer_id: id(2), display_name: "m".into(), follow: None, ask: Some(ask) };
        let first_leave = op_at(2, &sid, t + 100, P::MemberRemoved { peer_id: id(2), seen: None });
        let mut second_leave = op_at(2, &sid, t + 102, P::MemberRemoved { peer_id: id(2), seen: None });
        second_leave.hlc.counter = 5;
        second_leave.auth = None;
        second_leave.sign(&keys(2).0, &keys(2).2);
        let history = vec![
            founding.clone(),
            op_at(1, &sid, t + 1, add(&sid, 2)),
            op_at(1, &sid, t + 2, add(&sid, 3)),
            first_leave.clone(),
            op_at(3, &sid, t + 102, admit(ask(t + 101, &first_leave, t + 1))),
            second_leave.clone(),
        ];
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        assert!(!r.is_member(&id(2)), "precondition: J left twice");
        let spare = op_at(3, &sid, t + 105, admit(ask(t + 104, &first_leave, t + 2)));
        assert!(!r.op_allowed(&spare), "same-ms second leave: the spare re-admitted J");
    }

    /// A signed `follows` binds: a member cannot move a rejoin's ask onto another leave,
    /// another signing time, or strip it to the older shape.
    #[test]
    fn a_rejoin_ask_binds_the_leave_it_follows() {
        let sid = "ab".repeat(20);
        let (kp, me, _) = keys(2);
        let leave = HlcTimestamp { physical_ms: 100, counter: 2, actor: me.clone() };
        let ask = crate::crdt::operations::JoinAsk::sign_rejoin(&sid, 101, None, Some(&leave), 50, &kp).unwrap();
        assert!(ask.verifies(&sid, &me));
        let mut moved = ask.clone();
        moved.follows.as_mut().unwrap().leave.counter = 3;
        assert!(!moved.verifies(&sid, &me), "moved to another leave");
        let mut later = ask.clone();
        later.follows.as_mut().unwrap().made = 500;
        assert!(!later.verifies(&sid, &me), "signed later than it was");
        let stripped = crate::crdt::operations::JoinAsk { follows: None, ..ask.clone() };
        assert!(!stripped.verifies(&sid, &me), "the leave stripped");
        let mut junk = ask.clone();
        junk.follows.as_mut().unwrap().leave.actor = format!("{me}\0x");
        assert!(!junk.verifies(&sid, &me), "an actor carrying a separator");
        let plain = crate::crdt::operations::JoinAsk::sign_rejoin(&sid, 101, None, None, 50, &kp).unwrap();
        assert_eq!(plain, crate::crdt::operations::JoinAsk::sign(&sid, 101, &kp), "no leave named = the ask as it always was");
    }

    /// The rev 2 probe (H2): a late admission of a current member, inside the gap a kick
    /// left, on the ask that admitted it before.
    #[test]
    fn probe2_a_late_admission_of_a_current_member_skips_ask_once() {
        let (owner, founding) = founded(1);
        let sid = owner.server_id.clone();
        let t = founding.hlc.physical_ms;
        let spent = crate::crdt::operations::JoinAsk::sign(&sid, (t + 1) as i64, &keys(2).0);
        let fresh = crate::crdt::operations::JoinAsk::sign(&sid, (t + 8) as i64, &keys(2).0);
        let admit = |ask| P::MemberAdded { peer_id: id(2), display_name: "m".into(), follow: None, ask: Some(ask) };
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&[
            founding.clone(),
            op_at(1, &sid, t + 1, admit(spent.clone())),
            op_at(1, &sid, t + 2, add(&sid, 3)),
            op_at(1, &sid, t + 5, P::MemberRemoved { peer_id: id(2), seen: None }),
            op_at(1, &sid, t + 10, admit(fresh.clone())),
        ]);
        assert!(r.is_member(&id(2)));
        let late = op_at(3, &sid, t + 7, admit(spent));
        assert!(!r.op_allowed(&late), "an admission inside the kicked gap, on the ask that admitted the member before, passes today's gate");
        let same_ask = op_at(3, &sid, t + 7, admit(fresh.clone()));
        assert!(r.op_allowed(&same_ask), "the next span's own ask may move it back");
        let early_ask = op_at(3, &sid, t + 7, admit(crate::crdt::operations::JoinAsk::sign(&sid, (t + 7) as i64 + crate::crdt::hlc::MAX_DRIFT_MS as i64 + 10, &keys(2).0)));
        assert!(!r.op_allowed(&early_ask), "no admission dated before its own ask");
        let other_ask = op_at(3, &sid, t + 7, admit(crate::crdt::operations::JoinAsk::sign(&sid, (t + 7) as i64, &keys(2).0)));
        assert!(!r.op_allowed(&other_ask), "a span opened inside history on another ask");
        r.ingest_remote(std::slice::from_ref(&same_ask));
        let spans = &r.member_record[&id(2)];
        assert_eq!((spans.len(), spans[0].until_ms, spans[1].from_ms), (2, t + 5, t + 7), "only the next span moved back");
    }

    /// U12 and the review's probe: two different ops at one clock keep the lowest content
    /// hash at the door, in the rebuild and in the digest.
    #[test]
    fn equivocation_keeps_the_lowest_hash_everywhere() {
        let (owner, founding) = founded(1);
        let sid = owner.server_id.clone();
        let t = founding.hlc.physical_ms;
        let base = vec![
            founding.clone(),
            op_at(1, &sid, t + 1, add(&sid, 2)),
            op_at(1, &sid, t + 2, P::RoleChanged { peer_id: id(2), role: MemberRole::Admin, priority: 2 }),
            op_at(1, &sid, t + 3, add(&sid, 3)),
        ];
        let o1 = op_at(2, &sid, t + 10, P::RoleChanged { peer_id: id(3), role: MemberRole::Moderator, priority: 1 });
        let o2 = op_at(2, &sid, t + 10, P::NicknameChanged { peer_id: id(2), nickname: "n".into() });
        let low = if o1.content_hash() < o2.content_hash() { &o1 } else { &o2 };
        let first_ranges = |s: &ServerState| {
            let e = crate::crdt::digest::entries(s, &[], None);
            crate::crdt::digest::first_ask(&e, 1, "AAAAAAAAAAAAAAAAAAAAAA".into(), None, None).ranges
        };
        let mut x = joiner(&sid, 9);
        x.ingest_remote(&base);
        x.ingest_remote(std::slice::from_ref(&o1));
        x.ingest_remote(std::slice::from_ref(&o2));
        let mut y = joiner(&sid, 8);
        y.ingest_remote(&base);
        y.ingest_remote(std::slice::from_ref(&o2));
        y.ingest_remote(std::slice::from_ref(&o1));
        let mut z = joiner(&sid, 7);
        let mut both = base.clone();
        both.push(o2.clone());
        both.push(o1.clone());
        z.ingest_remote(&both);
        assert_eq!(x.get_role(&id(3)), y.get_role(&id(3)));
        assert_eq!(view(&x), view(&y));
        assert_eq!(view(&x), view(&z), "one batch keeps the same one");
        assert!(x.op_log.iter().any(|o| o.hlc == low.hlc && o.content_hash() == low.content_hash()), "the lower hash wins");
        assert_eq!(first_ranges(&x), first_ranges(&y));
        let mut w = joiner(&sid, 6);
        w.ingest_remote(&base);
        let other = if std::ptr::eq(low, &o1) { &o2 } else { &o1 };
        w.ingest_remote(std::slice::from_ref(other));
        assert_ne!(first_ranges(&x), first_ranges(&w), "the digest tells the two ops at one key apart");
    }

    /// U14 and the review's probe: a stranger's flood cannot push a member's op out of
    /// `held`; the heaviest author gives way.
    #[test]
    fn held_admits_only_known_authors_and_evicts_the_heaviest() {
        let (owner, founding) = founded(1);
        let sid = owner.server_id.clone();
        let t = founding.hlc.physical_ms;
        let admit3 = op_at(1, &sid, t + 1, add(&sid, 3));
        let promote3 = op_at(1, &sid, t + 2, P::RoleChanged { peer_id: id(3), role: MemberRole::Admin, priority: 3 });
        let rename3 = op_at(3, &sid, t + 5, P::ServerRenamed { new_name: "kept".into() });
        let junk: Vec<CrdtOp> = (0..300u64)
            .map(|i| op_at(7, &sid, t + 100 + i, P::NicknameChanged { peer_id: id(7), nickname: format!("j{i}") }))
            .collect();
        let mut a = joiner(&sid, 9);
        a.ingest_remote(&[founding.clone(), admit3.clone()]);
        a.ingest_remote(std::slice::from_ref(&rename3));
        assert_eq!(a.held.len(), 1, "fixture: the member's op waits for its role");
        for j in &junk {
            a.ingest_remote(std::slice::from_ref(j));
        }
        assert_eq!(a.held.len(), 1, "a stranger's ops never wait in held");
        a.ingest_remote(std::slice::from_ref(&promote3));
        let mut b = joiner(&sid, 8);
        b.ingest_remote(&[founding.clone(), admit3.clone(), promote3.clone(), rename3.clone()]);
        assert_eq!(b.name(), "kept");
        assert_eq!(a.name(), b.name(), "a stranger's flood evicted a member's held op");
    }

    /// U21: member at its clock spares a legacy anchor and an author with no record, and
    /// refuses a member's op dated before its admission.
    #[test]
    fn member_at_its_clock_spares_legacy_and_unrecorded_authors() {
        let (owner, founding) = founded(1);
        let sid = owner.server_id.clone();
        let t = founding.hlc.physical_ms;
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&[founding, op_at(1, &sid, t + 10, add(&sid, 2))]);
        assert!(!r.op_allowed(&op_at(2, &sid, t + 5, P::NicknameChanged { peer_id: id(2), nickname: "early".into() })), "dated before its admission");
        assert!(r.op_allowed(&op_at(2, &sid, t + 15, P::NicknameChanged { peer_id: id(2), nickname: "in".into() })));
        let (mut legacy, _) = crate::crdt::testkeys::owned_state("s-legacy", "Old", 1);
        legacy.author_checked(add("s-legacy", 2)).unwrap();
        legacy.member_record.clear();
        assert_eq!(legacy.anchor(), Anchor::Legacy);
        let at = legacy.op_log.last().unwrap().hlc.physical_ms;
        assert!(legacy.op_allowed(&op_at(2, "s-legacy", at.saturating_sub(10_000), P::NicknameChanged { peer_id: id(2), nickname: "n".into() })), "a legacy anchor is not judged at the op's clock");
        let mut genesis = joiner(&sid, 9);
        let (_, f2) = founded(1);
        let _ = (&mut genesis, f2);
        let mut unrecorded = r.clone();
        unrecorded.member_record.remove(&id(2));
        assert!(unrecorded.op_allowed(&op_at(2, &sid, t + 5, P::NicknameChanged { peer_id: id(2), nickname: "x".into() })), "no record passes (F12)");
    }

    /// Both arrival orders of a late leave and an unseen rejoin, and a leave missed with
    /// the re-admission in the base on a newer ask (M3: the leave is decided) or an older
    /// one (it applies, F9).
    #[test]
    fn late_leave_rejoin_and_readmission_fold_by_clock() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let readmit_newer = op_at(1, &sid, t + 30, readd(&sid, 4, (t + 25) as i64));
        owner.ingest_remote(std::slice::from_ref(&readmit_newer));
        let cp = checkpoint(&mut owner);
        let leave = op_at(4, &sid, t + 20, P::MemberRemoved { peer_id: id(4), seen: None });
        for order in [[0, 1], [1, 0]] {
            let ops = [cp.clone(), leave.clone()];
            let mut r = joiner(&sid, 9);
            r.ingest_remote(&history);
            for i in order {
                r.ingest_remote(std::slice::from_ref(&ops[i]));
            }
            assert!(r.is_member(&id(4)), "M3: a re-admission on an ask after the leave keeps it");
        }
        let (mut owner, history, t) = staffed();
        let readmit_older = op_at(1, &sid_of(&owner), t + 30, readd(&sid_of(&owner), 4, (t + 15) as i64));
        owner.ingest_remote(std::slice::from_ref(&readmit_older));
        assert!(owner.is_member(&id(4)), "fixture: a repeat for the owner");
        let cp = checkpoint(&mut owner);
        let leave = op_at(4, &sid_of(&owner), t + 20, P::MemberRemoved { peer_id: id(4), seen: None });
        let mut r = joiner(&sid_of(&owner), 9);
        r.ingest_remote(&history);
        r.ingest_remote(&[cp, leave]);
        assert!(!r.is_member(&id(4)), "F9: an ask older than the leave never re-admits");
    }

    fn sid_of(s: &ServerState) -> String {
        s.server_id.clone()
    }

    /// U4: a restart through the production save path (state JSON from `lean_snapshot`,
    /// rows written as deltas to a store, base taken from the rows) matches the live
    /// replica; a stale fingerprint refolds once.
    #[test]
    fn a_restart_through_the_store_matches_a_live_replica() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let store = crate::storage::MessageStore::open(":memory:", &"ab".repeat(32)).unwrap();
        let mut live = joiner(&sid, 9);
        let feed = |s: &mut ServerState, ops: &[CrdtOp]| {
            let out = s.ingest_remote(ops);
            if let Some(d) = out.delta(&sid) {
                store.persist_op_delta(&d).unwrap();
            }
        };
        feed(&mut live, &history);
        let late = op_at(4, &sid, t + 20, P::MemberRemoved { peer_id: id(4), seen: None });
        let cp = checkpoint(&mut owner);
        feed(&mut live, std::slice::from_ref(&cp));
        feed(&mut live, std::slice::from_ref(&late));
        feed(&mut live, &[op_at(2, &sid, t + 40, readd(&sid, 5, (t + 40) as i64))]);
        let json = serde_json::to_string(&live.lean_snapshot()).unwrap();
        let restart = |json: &str| {
            let mut s: ServerState = serde_json::from_str(json).unwrap();
            s.set_hlc(Hlc::new(id(9)));
            let refolded = s.restore_op_log(store.load_op_rows(&sid).unwrap()).refolded;
            (s, refolded)
        };
        let (back, refolded) = restart(&json);
        assert!(!refolded, "a matching fingerprint skips the refold");
        assert_eq!(view(&back), view(&live));
        assert_eq!(keys_of(&back), keys_of(&live));
        assert!(!back.is_member(&id(4)), "the late leave survives the restart");
        let mut stale: serde_json::Value = serde_json::from_str(&json).unwrap();
        stale["retained_print"] = serde_json::json!("0:0");
        stale["name"]["value"] = serde_json::json!("not what the rows say");
        let (back, refolded) = restart(&stale.to_string());
        assert!(refolded, "a stale fingerprint refolds");
        assert_eq!(view(&back), view(&live));
    }

    /// U10: the rebase equals a fold of the whole history (the oracle) for random op sets
    /// over every payload kind, random owner-seen subsets and checkpoint points. Ops whose
    /// verdict differs between their clock and the base are left out one by one, never
    /// the whole set.
    #[test]
    fn rebase_equals_a_clone_and_apply_oracle() {
        // Device tests map these same keys in the process-global resolver.
        let _g = crate::node::resolver::test_lock();
        crate::node::resolver::clear_all();
        let mut rng = 0x9e37_79b9_7f4a_7c15u64;
        let mut next = move |n: u64| {
            rng ^= rng << 13;
            rng ^= rng >> 7;
            rng ^= rng << 17;
            rng % n
        };
        let mut compared = 0;
        for _case in 0..160 {
            let (owner0, history, t) = staffed();
            let sid = owner0.server_id.clone();
            let ch = general(&owner0);
            let mut ops = Vec::new();
            let len = 8 + next(18);
            for i in 0..len {
                let at = t + 20 + i * 3;
                let author = [1u8, 2, 3, 4, 5][next(5) as usize];
                let target = [2u8, 3, 4, 5, 6][next(5) as usize];
                ops.push(op_at(author, &sid, at, gen_payload(&mut next, &sid, &ch, target, at)));
            }
            let cut = next(len) as usize;
            // Each op with whether the owner folded it before its checkpoint.
            let mut kept: Vec<(CrdtOp, bool)> = ops.into_iter().enumerate().map(|(i, o)| (o, i < cut && next(10) < 6)).collect();
            for _round in 0..12 {
                let mut owner = owner0.clone();
                owner.ingest_remote(&kept.iter().filter(|(_, s)| *s).map(|(o, _)| o.clone()).collect::<Vec<_>>());
                let owner_folded: Vec<OpKey> = owner.op_log.iter().map(|o| (o.author.clone(), o.hlc.clone())).collect();
                let cp = checkpoint(&mut owner);
                let all: Vec<CrdtOp> = kept.iter().map(|(o, _)| o.clone()).collect();
                let mut r = joiner(&sid, 9);
                r.ingest_remote(&history);
                r.ingest_remote(std::slice::from_ref(&cp));
                r.ingest_remote(&all);
                let mut fresh = joiner(&sid, 7);
                fresh.ingest_remote(&[history[0].clone(), cp.clone()]);
                fresh.ingest_remote(&all);
                let mut oracle = joiner(&sid, 8);
                oracle.ingest_remote(&history);
                oracle.ingest_remote(&all);
                let judge = r.base.clone().unwrap();
                let in_log = |s: &ServerState, o: &CrdtOp| s.op_log.iter().any(|x| x.author == o.author && x.hlc == o.hlc);
                // The verdict an op got where it was decided (the owner's fold for what the
                // base holds, the rebase for the rest) against the one history gives it.
                let differ = kept.iter().position(|(o, seen)| {
                    let decided = if judge.judge().dominates(o, true) || *seen {
                        owner_folded.contains(&(o.author.clone(), o.hlc.clone()))
                    } else {
                        in_log(&r, o)
                    };
                    decided != in_log(&oracle, o)
                });
                match differ {
                    Some(i) => {
                        kept.remove(i);
                    }
                    None => {
                        let (rv, ov) = (view(&r), view(&oracle));
                        let diff: Vec<String> = rv
                            .as_object()
                            .unwrap()
                            .iter()
                            .filter(|(k, v)| ov.get(k.as_str()) != Some(v))
                            .map(|(k, v)| format!("{k}: rebase {v} / history {}", ov.get(k.as_str()).unwrap_or(&serde_json::Value::Null)))
                            .collect();
                        let names: Vec<String> = kept
                            .iter()
                            .map(|(o, seen)| format!("{}@{} by {}{}", payload_name(&o.payload), o.hlc.physical_ms - t, &o.author[o.author.len() - 4..], if *seen { " (owner saw)" } else { "" }))
                            .collect();
                        assert!(diff.is_empty(), "rebase and history differ: {diff:#?}\nops {names:#?}");
                        assert_eq!(view(&fresh), rv, "a joiner holding only the base and the late ops differs\nops {names:#?}");
                        compared += 1;
                        break;
                    }
                }
            }
        }
        assert!(compared > 100, "too few cases compared: {compared}");
    }

    /// One random payload of U10's generator: every kind the fold can take on top of a base.
    fn gen_payload(next: &mut impl FnMut(u64) -> u64, sid: &str, ch: &str, target: u8, at: u64) -> P {
        let chans = [ch.to_string(), format!("{}-c1", &sid[..8])];
        let c = chans[next(2) as usize].clone();
        let label = ["l1", "l2"][next(2) as usize].to_string();
        let roles = [MemberRole::Admin, MemberRole::Moderator, MemberRole::Member];
        match next(36) {
            0 => P::ServerRenamed { new_name: format!("n{}", next(4)) },
            1 => P::ServerSettingChanged { key: "is_private".into(), value: ["true", "false"][next(2) as usize].into() },
            2 => P::RolePermissionsChanged { role: "member".into(), permissions: crate::crdt::operations::Permission::MANAGE_CHANNELS * next(2) as u32 },
            3 => P::MemberMuted { peer_id: id(target), expires_at: u64::MAX },
            4 => P::MemberUnmuted { peer_id: id(target) },
            5 => P::ChannelGrantSet { channel_id: c, peer_id: id(target), expires_at: u64::MAX },
            6 => P::ChannelGrantRevoked { channel_id: c, peer_id: id(target) },
            7 => P::MemberBanned { peer_id: id(target), seen: None },
            8 => P::MemberUnbanned { peer_id: id(target) },
            9 => P::RoleChanged { peer_id: id(target), role: roles[next(3) as usize].clone(), priority: 1 },
            10 => P::NicknameChanged { peer_id: id(target), nickname: format!("k{}", next(4)) },
            11 => P::TwitchUsernameChanged { peer_id: id(target), twitch_username: format!("tw{}", next(4)) },
            12 => P::StoragePledgeChanged { peer_id: id(target), pledge_bytes: next(4) },
            13 => P::MemberAdded {
                peer_id: id(target),
                display_name: "m".into(),
                follow: None,
                ask: Some(crate::crdt::operations::JoinAsk::sign(sid, at as i64 - next(3) as i64 * 5, &keys(target).0)),
            },
            14 => P::MemberRemoved { peer_id: id(target), seen: None },
            15 => P::ChannelAdded { channel_id: chans[1].clone(), name: "c1".into(), category: None, channel_type: "text".into() },
            16 => P::ChannelRemoved { channel_id: c },
            17 => P::ChannelRenamed { channel_id: c, new_name: format!("r{}", next(4)) },
            18 => P::ChannelPostingChanged { channel_id: c, posting: ["moderator", "everyone"][next(2) as usize].into() },
            19 => P::ChannelSlowModeChanged { channel_id: c, seconds: next(3) as u32 },
            20 => P::ChannelMediaOnlyChanged { channel_id: c, media_only: next(2) == 0 },
            21 => P::ChannelPostingLabelsChanged { channel_id: c, labels: vec![label] },
            22 => P::ChannelPublicChanged { channel_id: c, is_public: next(2) == 0 },
            23 => P::ChannelVisibilityChanged { channel_id: c, visibility: ["moderator", "everyone"][next(2) as usize].into() },
            24 => P::ChannelVisibilityLabelsChanged { channel_id: c, labels: if next(2) == 0 { vec![] } else { vec![label] } },
            25 => P::ChannelLayoutUpdated { layout_json: format!("[{{\"type\":\"separator\"}}{}]", ",{\"type\":\"separator\"}".repeat(next(2) as usize)) },
            26 => P::MessagePinned { channel_id: c, message_id: format!("m{}", next(3)) },
            27 => P::MessageUnpinned { channel_id: c, message_id: format!("m{}", next(3)) },
            28 => P::LabelCreated { label_id: label, name: "L".into(), color: "#fff".into(), access: false },
            29 => P::LabelUpdated { label_id: label, name: format!("L{}", next(3)), color: "#000".into(), access: None },
            30 => P::LabelDeleted { label_id: label },
            31 => P::LabelAssigned { label_id: label, peer_id: id(target) },
            32 => P::LabelUnassigned { label_id: label, peer_id: id(target) },
            33 => P::EmojiAdded { name: format!("e{}", next(3)), hash: format!("{:064x}", next(3)), animated: false },
            34 => P::EmojiRemoved { name: format!("e{}", next(3)) },
            _ => match next(7) {
                6 => P::FloorMark { cp: format!("{:064x}", next(3)) },
                5 => P::SettleSign {
                    stamp: crate::crdt::operations::SettleStamp {
                        server: sid.to_string(),
                        parent: format!("{:064x}", next(3)),
                        generation: next(3),
                        devices: vec![id(target)],
                        t_ms: 0,
                        sigs: Vec::new(),
                    },
                },
                4 => P::DeviceRetired { device: id(target), ops: Vec::new(), posts_until_ms: None, restore: None },
                3 => P::JoinKeySet { secret: crate::crdt::operations::JoinSecret(format!("{:064x}", next(3) + 1)) },
                0 => P::StickerAdded { hash: format!("{:064x}", next(3)), name: "s".into(), pack: "p".into(), animated: false, w: 1, h: 1 },
                1 => P::StickerRemoved { hash: format!("{:064x}", next(3)) },
                _ => P::ChannelVoiceChatChanged { channel_id: c, mode: crate::crdt::server_state::VoiceChat::Server },
            },
        }
    }

    /// U10's generator covers every payload kind but the four judged on their own: the
    /// founding op, checkpoints, deletion and the join lock (`a_join_lock_op_*`).
    #[test]
    fn the_oracle_generates_every_payload_kind() {
        let src = include_str!("fold.rs");
        let ops = include_str!("operations.rs");
        let start = ops.find("pub enum CrdtPayload").unwrap();
        let body = &ops[start..start + ops[start..].find("\n}\n").unwrap()];
        let variants: Vec<&str> = body
            .lines()
            .filter_map(|l| {
                let l = l.trim();
                let name = l.split(|c: char| !c.is_alphanumeric()).next()?;
                (name.chars().next()?.is_uppercase() && (l.ends_with('{') || l.ends_with(',') && !l.contains(':'))).then_some(name)
            })
            .collect();
        assert!(variants.len() > 40, "parsed {variants:?}");
        let gen_at = src.find("fn gen_payload").unwrap();
        let generator = &src[gen_at..gen_at + src[gen_at..].find("\n    }\n").unwrap()];
        for v in variants {
            if ["ServerCreated", "ServerCheckpoint", "ServerDeleted", "JoinLock"].contains(&v) {
                continue;
            }
            assert!(generator.contains(&format!("P::{v} ")), "U10 never generates {v}");
        }
    }

    /// U13: past the budget, shares are max-min over charge groups (a puppet tree charges
    /// the member who started it), the same in every order; the leader's admissions and an
    /// honest admin's ops stay folded; a flood row once admitted is parked, never deleted.
    #[test]
    fn quota_shares_are_order_independent_and_park_never_delete() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let cp = checkpoint(&mut owner);
        let mut flood = Vec::new();
        for p in 0..20u8 {
            let tag = 40 + p;
            flood.push(op_at(4, &sid, t + 1000 + p as u64, readd(&sid, tag, (t + 1000) as i64)));
            for k in 0..40u64 {
                let at = t + 2000 + p as u64 * 100 + k;
                flood.push(op_at(tag, &sid, at, P::NicknameChanged { peer_id: id(tag), nickname: "x".repeat(400) + &k.to_string() }));
            }
        }
        let honest = vec![
            op_at(2, &sid, t + 9000, P::ServerRenamed { new_name: "honest".into() }),
            op_at(1, &sid, t + 9001, readd(&sid, 7, (t + 9001) as i64)),
        ];
        let mut a = joiner(&sid, 9);
        a.ingest_remote(&history);
        a.ingest_remote(std::slice::from_ref(&cp));
        a.ingest_remote(&flood[..200]);
        let early_rows = a.served_log().len();
        a.ingest_remote(&flood[200..]);
        a.ingest_remote(&honest);
        let mut b = joiner(&sid, 8);
        b.ingest_remote(&history);
        b.ingest_remote(&honest);
        let mut rev = flood.clone();
        rev.reverse();
        b.ingest_remote(&rev);
        b.ingest_remote(std::slice::from_ref(&cp));
        for s in [&a, &b] {
            assert_eq!(s.name(), "honest", "an honest admin's op stays folded");
            assert!(s.is_member(&id(7)), "the leader's admission stays folded: joins go on");
            let folded = s.op_log.iter().filter(|o| matches!(o.payload, P::NicknameChanged { .. })).count();
            assert!(folded < 20 * 40, "the flood is bounded: {folded}");
        }
        assert_eq!(view(&a), view(&b), "the shares depend on the set, never the order");
        assert_eq!(keys_of(&a), keys_of(&b));
        let parked: Vec<&CrdtOp> = a.stored.iter().filter(|(_, k)| matches!(k, RowKind::Parked(_))).map(|(o, _)| o).collect();
        let bytes: usize = parked.iter().map(|o| op_size(o)).sum();
        assert!(!parked.is_empty() && bytes <= PARK_GROUP_BYTES, "a once-admitted row over the share is parked, within its group's bound ({bytes})");
        assert!(a.served_log().len() + parked.len() < early_rows + flood.len(), "the rest of the flood is no row at all");
    }

    /// U6: junk stays bounded: a stranger's and a non-member's ops never become rows, and
    /// a member's backdated own-leave flood lands once.
    #[test]
    fn junk_below_a_checkpoint_stays_bounded() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let cp = checkpoint(&mut owner);
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(std::slice::from_ref(&cp));
        let rows = r.served_log().len();
        let junk: Vec<CrdtOp> = (0..400u64)
            .map(|i| op_at(70 + (i % 3) as u8, &sid, t + 10 + i, P::ServerRenamed { new_name: format!("j{i}") }))
            .collect();
        let out = r.ingest_remote(&junk);
        assert!(out.rows.is_empty() && r.held.len() <= HELD_CAP);
        let leaves: Vec<CrdtOp> = (0..300u64).map(|i| op_at(4, &sid, t + 6 + i, P::MemberRemoved { peer_id: id(4), seen: None })).collect();
        r.ingest_remote(&leaves);
        assert!(!r.is_member(&id(4)));
        assert_eq!(r.served_log().len(), rows + 1, "one leave lands, the rest are refused and stored nowhere");
        assert!(r.held.len() <= HELD_CAP);
    }


    /// U16: a 0.13 log loads: its checkpoint (no stamps) is a generation-0 base whose
    /// `covers` decides everything at or below it, exactly 0.13's rule once; ops after it
    /// fold on top; the owner owes a stamped child; 0.13 state fields load.
    #[test]
    fn a_0_13_log_and_checkpoint_load_and_seed_stamps() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let ch = general(&owner);
        let mut old = owner.lean_snapshot();
        *old.stamps = Default::default();
        old.member_events.clear();
        old.cp_stamped = false;
        let covers = HlcTimestamp { physical_ms: t + 50, counter: 0, actor: id(1) };
        let mut json: serde_json::Value = serde_json::to_value(&old).unwrap();
        json["standing_folded"] = serde_json::json!(true);
        json["late_leaves"] = serde_json::json!([["x", covers]]);
        let cp = owner.author_checked(P::ServerCheckpoint { state: json.to_string(), covers: covers.clone() });
        let cp = cp.unwrap_or_else(|| op_at(1, &sid, t + 60, P::ServerCheckpoint { state: json.to_string(), covers: covers.clone() }));
        let below = op_at(2, &sid, t + 40, P::ChannelRenamed { channel_id: ch.clone(), new_name: "below".into() });
        let above = op_at(2, &sid, t + 70, P::ChannelRenamed { channel_id: ch.clone(), new_name: "above".into() });
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(&[cp.clone(), below.clone()]);
        assert_eq!(r.base.as_ref().map(|b| b.generation), Some(0));
        assert_eq!(r.channels[&ch].name, "general", "at or below covers is decided, as 0.13 did");
        r.ingest_remote(std::slice::from_ref(&above));
        assert_eq!(r.channels[&ch].name, "above");
        assert!(r.checkpoint_due(&id(1), crate::crdt::hlc::wall_clock_ms()) || r.current_owner().as_deref() != Some(id(1).as_str()));
        let mut back: ServerState = serde_json::from_value(json).expect("a 0.13 state with retired fields loads");
        back.set_hlc(Hlc::new(id(9)));
        let mut child = owner.clone();
        child.ingest_remote(std::slice::from_ref(&cp));
        assert!(child.checkpoint_due(&id(1), crate::crdt::hlc::wall_clock_ms()), "a 0.13 base is due a stamped child");
        let c1 = checkpoint(&mut child);
        let mut s = joiner(&sid, 8);
        s.ingest_remote(&history);
        s.ingest_remote(&[cp, c1, below, above]);
        assert_eq!(s.base.as_ref().map(|b| (b.generation, b.state.cp_stamped)), Some((1, true)));
        assert_eq!(s.channels[&ch].name, "above");
    }

    /// U17: the checkpoint of a 512-identity server stays small.
    #[test]
    fn a_checkpoint_of_512_identities_stays_small() {
        let (mut owner, _, t) = staffed();
        let sid = owner.server_id.clone();
        let mut ops = Vec::new();
        for i in 0..512u32 {
            let (kp, who, _) = crate::crdt::testkeys::keys_n(i + 1000);
            let at = t + 100 + i as u64 * 4;
            let ask = crate::crdt::operations::JoinAsk::sign(&sid, at as i64, &kp);
            ops.push(op_at(1, &sid, at, P::MemberAdded { peer_id: who.clone(), display_name: format!("member {i}"), follow: None, ask: Some(ask) }));
            ops.push(op_at(1, &sid, at + 1, P::NicknameChanged { peer_id: who.clone(), nickname: format!("nick {i}") }));
            ops.push(op_at(1, &sid, at + 2, P::StoragePledgeChanged { peer_id: who, pledge_bytes: 1 << 30 }));
        }
        owner.ingest_remote(&ops);
        assert!(owner.members.len() >= 512);
        let size = owner.checkpoint_json(&id(1), &[], crate::crdt::hlc::wall_clock_ms()).unwrap().len();
        // Measured 2026-11-01: 749,830 bytes (members, roles, nicknames, pledges, spans, events).
        assert!(size < 1_000_000, "a 512-identity checkpoint is {size} bytes");
    }


    /// M2: the F1 cascade (B admits C, B's leave reaches the owner, the owner's checkpoint
    /// never saw the admission): C's replica parks its own admission and asks again; a
    /// real removal of C after it never triggers that, nor a member.
    #[test]
    fn a_refused_own_admission_triggers_the_silent_reask_and_a_removal_does_not() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let admit_c = op_at(4, &sid, t + 10, readd(&sid, 8, (t + 10) as i64));
        let leave_b = op_at(4, &sid, t + 20, P::MemberRemoved { peer_id: id(4), seen: None });
        let mut c = joiner(&sid, 8);
        c.ingest_remote(&history);
        c.ingest_remote(std::slice::from_ref(&admit_c));
        assert!(c.is_member(&id(8)) && !c.refused_own_admission(&id(8)));
        owner.ingest_remote(std::slice::from_ref(&leave_b));
        let cp = checkpoint(&mut owner);
        c.ingest_remote(&[leave_b, cp.clone()]);
        assert!(!c.is_member(&id(8)), "today's authority refuses an admission by someone gone");
        assert!(c.refused_own_admission(&id(8)), "C asks again");
        let mut kicked = c.clone();
        kicked.ingest_remote(&[op_at(1, &sid, t + 30, readd(&sid, 8, (t + 30) as i64)), op_at(1, &sid, t + 40, P::MemberRemoved { peer_id: id(8), seen: None })]);
        assert!(!kicked.refused_own_admission(&id(8)), "a real removal after it never triggers a re-ask");
    }


    /// M5: a checkpoint is a base only with its generation its parent's plus one, the
    /// parent held; one naming a parent we lack waits in `held`.
    #[test]
    fn a_checkpoint_with_a_wrong_generation_or_a_missing_parent_is_no_base() {
        let (mut owner, history, _) = staffed();
        let sid = owner.server_id.clone();
        let c1 = checkpoint(&mut owner);
        let forge = |owner: &mut ServerState, generation: u64, parent: Option<String>| {
            let mut st: ServerState = serde_json::from_str(&owner.checkpoint_json(&id(1), &[], 0).unwrap()).unwrap();
            st.cp_generation = generation;
            st.cp_parent = parent;
            let covers = owner.checkpoint_covers();
            owner.create_op(P::ServerCheckpoint { state: serde_json::to_string(&st).unwrap(), covers })
        };
        let wrong = forge(&mut owner, 7, Some(hex::encode(c1.content_hash())));
        let orphan = forge(&mut owner, 2, Some(hex::encode([9u8; 32])));
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(&[c1.clone(), wrong, orphan]);
        assert_eq!(r.base.as_ref().map(|b| b.hash), Some(c1.content_hash()), "only the well-formed child of a held parent is a base");
        assert!(r.held.iter().any(|(o, _)| matches!(o.payload, P::ServerCheckpoint { .. })), "an orphan waits for its parent");
    }

    /// M1: the writer rule wants two other identities' finished digest rounds, one a
    /// moderator or above or owner-admitted; or every other member of a small server.
    #[test]
    fn the_owner_checkpoints_only_after_two_witnesses_one_vouched() {
        let (owner, _, _) = staffed();
        let mut s = owner.clone();
        let sid = s.server_id.clone();
        let t = s.op_log.last().unwrap().hlc.physical_ms;
        s.ingest_remote(&[op_at(4, &sid, t + 10, readd(&sid, 9, (t + 10) as i64)), op_at(9, &sid, t + 11, readd(&sid, 10, (t + 11) as i64))]);
        let w = |ids: &[u8]| ids.iter().map(|i| id(*i)).collect::<HashSet<String>>();
        assert!(!s.checkpoint_witnessed(&id(1), &w(&[4])), "one identity");
        assert!(!s.checkpoint_witnessed(&id(1), &w(&[9, 10])), "a puppet and the puppet it admitted");
        assert!(s.checkpoint_witnessed(&id(1), &w(&[4, 3])), "one of them a moderator");
        assert!(s.checkpoint_witnessed(&id(1), &w(&[2, 3, 4, 9, 10])), "every other member");
        let (small, _) = founded(1);
        let mut small = small;
        let sid = small.server_id.clone();
        let t = small.op_log[0].hlc.physical_ms;
        small.ingest_remote(&[op_at(1, &sid, t + 1, add(&sid, 2))]);
        assert!(small.checkpoint_witnessed(&id(1), &w(&[2])), "a two-member server can checkpoint");
    }

    /// U2 for every element kind the base dates with its own stamp: channels, the public
    /// flag, pins, emotes and label assignments. An admin's ops the owner never saw land
    /// on every replica as history folds them; an assignment older than the label's
    /// deletion stays gone after the label is made again, and a restriction older than a
    /// later visibility write still takes the channel off the public list (HOL-SEC-094),
    /// also when it held its field across the owner's later `public` write, and not when
    /// the owner's own visibility write ended it before that.
    #[test]
    fn a_checkpoint_keeps_late_writes_to_every_stamped_element() {
        let (mut owner, mut history, t) = staffed();
        let sid = owner.server_id.clone();
        let ch = general(&owner);
        let [c2, c3, c4, c5] = ["c2", "c3", "c4", "c5"].map(|c| format!("{}-{c}", &sid[..8]));
        let text = |c: &str| P::ChannelAdded { channel_id: c.into(), name: "c".into(), category: None, channel_type: "text".into() };
        let vis = |c: &str, v: &str| P::ChannelVisibilityChanged { channel_id: c.into(), visibility: v.into() };
        let public = |c: &str| P::ChannelPublicChanged { channel_id: c.into(), is_public: true };
        let seen = vec![
            op_at(1, &sid, t + 6, text(&c2)),
            op_at(1, &sid, t + 7, text(&c3)),
            op_at(1, &sid, t + 8, text(&c4)),
            op_at(1, &sid, t + 9, vis(&c4, "everyone")),
            op_at(1, &sid, t + 10, text(&c5)),
            op_at(1, &sid, t + 27, public(&c5)),
            op_at(1, &sid, t + 36, P::ChannelVisibilityLabelsChanged { channel_id: c5.clone(), labels: vec![] }),
            op_at(1, &sid, t + 35, vis(&c3, "everyone")),
            op_at(1, &sid, t + 40, public(&c3)),
            op_at(1, &sid, t + 41, public(&c4)),
            op_at(1, &sid, t + 50, vis(&c4, "everyone")),
            op_at(1, &sid, t + 20, P::LabelCreated { label_id: "l1".into(), name: "L".into(), color: "#fff".into(), access: false }),
            op_at(1, &sid, t + 24, P::LabelDeleted { label_id: "l1".into() }),
            op_at(1, &sid, t + 26, P::LabelCreated { label_id: "l1".into(), name: "L".into(), color: "#fff".into(), access: false }),
            op_at(1, &sid, t + 30, P::ChannelPublicChanged { channel_id: c2.clone(), is_public: true }),
            op_at(1, &sid, t + 32, P::ChannelVisibilityChanged { channel_id: c2.clone(), visibility: "everyone".into() }),
        ];
        owner.ingest_remote(&seen);
        history.extend(seen);
        let c1 = format!("{}-c1", &sid[..8]);
        let unseen = vec![
            op_at(2, &sid, t + 11, P::ChannelAdded { channel_id: c1.clone(), name: "c1".into(), category: None, channel_type: "text".into() }),
            op_at(2, &sid, t + 12, P::ChannelPublicChanged { channel_id: ch.clone(), is_public: true }),
            op_at(2, &sid, t + 13, P::MessagePinned { channel_id: ch.clone(), message_id: "m1".into() }),
            op_at(2, &sid, t + 14, P::EmojiAdded { name: "e1".into(), hash: format!("{:064x}", 7), animated: false }),
            op_at(2, &sid, t + 22, P::LabelAssigned { label_id: "l1".into(), peer_id: id(4) }),
            op_at(2, &sid, t + 31, P::ChannelVisibilityChanged { channel_id: c2.clone(), visibility: "moderator".into() }),
            op_at(2, &sid, t + 33, vis(&c3, "moderator")),
            op_at(2, &sid, t + 34, vis(&c4, "moderator")),
            op_at(2, &sid, t + 29, P::ChannelVisibilityLabelsChanged { channel_id: c5.clone(), labels: vec!["l1".into()] }),
        ];
        let cp = checkpoint(&mut owner);
        let mut before = joiner(&sid, 9);
        before.ingest_remote(&history);
        before.ingest_remote(&unseen);
        before.ingest_remote(std::slice::from_ref(&cp));
        let mut after = joiner(&sid, 8);
        after.ingest_remote(&history);
        after.ingest_remote(std::slice::from_ref(&cp));
        after.ingest_remote(&unseen);
        owner.ingest_remote(&unseen);
        let mut fresh = joiner(&sid, 6);
        fresh.ingest_remote(&[history[0].clone(), cp.clone()]);
        fresh.ingest_remote(&unseen);
        let late_assignment = &unseen[4];
        assert!(after.base.as_ref().unwrap().judge().dominates(late_assignment, true), "the label's deletion decides the late assignment");
        assert!(!after.op_log.iter().any(|o| o.hlc == late_assignment.hlc), "a decided assignment never folds");
        let mut oracle = joiner(&sid, 7);
        oracle.ingest_remote(&history);
        oracle.ingest_remote(&unseen);
        for (who, s) in [("history", &oracle), ("before", &before), ("after", &after), ("owner", &owner), ("fresh", &fresh)] {
            assert!(s.channels.contains_key(&c1), "{who}: the admin's channel lands");
            assert!(s.channels[&ch].is_public, "{who}: the admin's public flag lands");
            assert_eq!(s.pinned_messages.get(&ch).map(Vec::as_slice), Some(&["m1".to_string()][..]), "{who}: the admin's pin lands");
            assert!(s.emotes.contains_key("e1"), "{who}: the admin's emote lands");
            assert!(s.label_assignments.get(&id(4)).is_none_or(|l| l.is_empty()), "{who}: the deletion took the label back");
            assert!(!s.channels[&c2].is_public, "{who}: the restriction closed the channel for good");
            assert!(s.channels[&c3].is_public, "{who}: a restriction ended before the public write closes nothing");
            assert!(!s.channels[&c4].is_public, "{who}: a restriction held across the public write closed it");
            assert!(!s.channels[&c5].is_public, "{who}: a label gate closes it like a visibility tier");
            assert_eq!(view(s), view(&oracle), "{who}: the rebase equals the fold from history");
        }
    }

    /// A field write older than its channel's re-creation is decided by the base: it
    /// drops at the door instead of taking a row (the apply arm refuses it too).
    #[test]
    fn a_field_write_before_a_channel_was_made_again_drops_at_the_door() {
        let (mut owner, mut history, t) = staffed();
        let sid = owner.server_id.clone();
        let ch = general(&owner);
        let seen = vec![
            op_at(1, &sid, t + 20, P::ChannelRemoved { channel_id: ch.clone() }),
            op_at(1, &sid, t + 21, P::ChannelAdded { channel_id: ch.clone(), name: "again".into(), category: None, channel_type: "text".into() }),
        ];
        owner.ingest_remote(&seen);
        history.extend(seen);
        let late = op_at(2, &sid, t + 15, P::ChannelRenamed { channel_id: ch.clone(), new_name: "late".into() });
        let cp = checkpoint(&mut owner);
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(std::slice::from_ref(&cp));
        assert!(r.base.as_ref().unwrap().judge().dominates(&late, true), "the re-creation decides it");
        r.ingest_remote(std::slice::from_ref(&late));
        assert!(!r.op_log.iter().any(|o| o.hlc == late.hlc), "a decided op never folds");
        let mut oracle = joiner(&sid, 7);
        oracle.ingest_remote(&history);
        oracle.ingest_remote(std::slice::from_ref(&late));
        assert_eq!(r.channels[&ch].name, "again");
        assert_eq!(view(&r), view(&oracle));
    }

    /// Whatever the base calls decided changes nothing when folded on top of it anyway,
    /// for every payload kind the generator makes; and the public flag's stamp is never
    /// older than either visibility field's (both arms date it).
    #[test]
    fn an_op_the_base_decides_changes_nothing_on_top_of_it() {
        let mut rng = 0x2545_f491_4f6c_dd1du64;
        let mut next = move |n: u64| {
            rng ^= rng << 13;
            rng ^= rng >> 7;
            rng ^= rng << 17;
            rng % n
        };
        let mut decided = 0;
        let mut kinds = HashSet::new();
        let mut bad = std::collections::BTreeSet::new();
        for _case in 0..120 {
            let (owner0, _, t) = staffed();
            let sid = owner0.server_id.clone();
            let ch = general(&owner0);
            let mut owner = owner0.clone();
            let len = 10 + next(30);
            let seen: Vec<CrdtOp> = (0..len)
                .map(|i| {
                    let at = t + 20 + i * 4;
                    let author = [1u8, 1, 2, 3, 4][next(5) as usize];
                    let target = [2u8, 3, 4, 5, 6][next(5) as usize];
                    op_at(author, &sid, at, gen_payload(&mut next, &sid, &ch, target, at))
                })
                .collect();
            owner.ingest_remote(&seen);
            checkpoint(&mut owner);
            let base = owner.base.clone().unwrap();
            for c in base.state.stamps.channels.values() {
                for f in [&c.visibility, &c.vis_labels] {
                    assert!(c.public >= *f, "is_public dated before a visibility write: {c:?}");
                }
            }
            for _probe in 0..40 {
                let at = t + 18 + next(len * 4 + 4);
                let author = [1u8, 2, 3, 4][next(4) as usize];
                let target = [2u8, 3, 4, 5, 6][next(5) as usize];
                let mut o = op_at(author, &sid, at, gen_payload(&mut next, &sid, &ch, target, at));
                o.hlc.counter = 1 + next(2) as u32;
                let (kp, _, pk) = keys(author);
                o.sign(&kp, &pk);
                if !base.judge().dominates(&o, true) {
                    continue;
                }
                let mut s = (*base.state).clone();
                if s.op_allowed(&o) {
                    s.apply_payload(&o);
                }
                if view(&s) != view(&base.state) {
                    bad.insert(payload_name(&o.payload));
                }
                decided += 1;
                kinds.insert(payload_name(&o.payload));
            }
        }
        assert!(bad.is_empty(), "decided ops that changed the base: {bad:?}");
        assert!(decided > 500 && kinds.len() > 25, "too few decided probes: {decided} over {} kinds", kinds.len());
    }

    /// U13, owner away: the admin answering joins is not the base's first position, yet
    /// its admissions keep folding while twenty members flood their own shares, the same
    /// on replicas that got the ops in opposite orders.
    #[test]
    fn an_admin_answering_joins_while_the_owner_is_away_keeps_them_going_through_a_flood() {
        let (mut owner, mut history, t) = staffed();
        let sid = owner.server_id.clone();
        let flooders: Vec<u8> = (40..60).collect();
        let admitted: Vec<CrdtOp> = flooders.iter().map(|&f| op_at(1, &sid, t + 10 + f as u64, add(&sid, f))).collect();
        owner.ingest_remote(&admitted);
        history.extend(admitted);
        let cp = checkpoint(&mut owner);
        let mut flood = Vec::new();
        for &f in &flooders {
            for k in 0..20u64 {
                flood.push(op_at(f, &sid, t + 1000 + f as u64 * 100 + k, P::NicknameChanged { peer_id: id(f), nickname: "x".repeat(500) + &k.to_string() }));
            }
        }
        let joins: Vec<CrdtOp> = (100..140u8).map(|j| op_at(2, &sid, t + 5000 + j as u64, readd(&sid, j, (t + 5000 + j as u64) as i64))).collect();
        let mut a = joiner(&sid, 9);
        a.ingest_remote(&history);
        a.ingest_remote(std::slice::from_ref(&cp));
        a.ingest_remote(&flood);
        a.ingest_remote(&joins);
        let mut b = joiner(&sid, 8);
        b.ingest_remote(&history);
        let mut rev: Vec<CrdtOp> = joins.iter().chain(&flood).cloned().collect();
        rev.reverse();
        b.ingest_remote(&rev);
        b.ingest_remote(std::slice::from_ref(&cp));
        for (who, s) in [("tail", &a), ("reversed", &b)] {
            let kept = (100..140u8).filter(|&j| s.is_member(&id(j))).count();
            let held = s.held.iter().filter(|(o, _)| matches!(o.payload, P::MemberAdded { .. })).count();
            assert_eq!(kept, 40, "{who}: every admission by the acting leader folds ({held} held)");
            let folded = s.op_log.iter().filter(|o| matches!(o.payload, P::NicknameChanged { .. })).count();
            assert!(folded < flooders.len() * 20, "the flood is bounded: {folded}");
            let bytes: usize = s.op_log.iter().filter(|o| o.hlc.physical_ms > t + 900).map(|o| serde_json::to_string(o).unwrap().len()).sum();
            assert!(bytes <= QUOTA_BYTES, "the staff budget comes out of the whole budget: {bytes}");
        }
        assert_eq!(view(&a), view(&b));
    }

    /// Decision 4's measurement: three months of a busy 512-identity server with the owner
    /// away and one admin answering every join (60 admissions and 60 lock moves a day,
    /// each move sealed to 16 staff devices; 40 joiner renames, 20 leaves, 20 moderator acts
    /// a day), sized from real signed ops against the shipping budget. The admin's
    /// admissions and moves fit the staff budget, for two months with 64 grants a move; the rest fits
    /// the budget with no flood, and keeps above the floor beside 512 members flooding.
    #[test]
    fn three_months_of_an_honest_admin_fit_the_shipping_budget() {
        const BUDGET: usize = 128 << 20;
        const FLOOR: usize = 128 << 10;
        const LEAD: usize = 64 << 20;
        let src = include_str!("fold.rs");
        for line in ["QUOTA_BYTES: usize = 128 << 20;", "QUOTA_FLOOR_BYTES: usize = 128 << 10;", "QUOTA_LEADER_BYTES: usize = 64 << 20;"] {
            assert!(src.contains(&format!("pub(crate) const {line}")), "the shipping constant moved: {line}");
        }
        let (owner, _, t) = staffed();
        let sid = owner.server_id.clone();
        let size = |op: &CrdtOp| serde_json::to_string(op).unwrap().len();
        let lock_move = |n: u64, staff: usize| {
            let link = crate::node::join_lock::LockLink {
                n,
                door: "d".repeat(43),
                change: "c".repeat(48),
                sig: "s".repeat(88),
                owner: None,
                nonce: None,
                dev: Some(Box::new(crate::node::join_lock::LockDev { device: id(2), master: id(2), sig: "s".repeat(88) })),
            };
            let grants = (0..staff)
                .map(|k| {
                    let m = id(100 + k as u8);
                    crate::node::join_lock::seal_grant(&sid, &link.change, &m, &m, &[7u8; 32]).unwrap()
                })
                .collect();
            op_at(2, &sid, t + 100 + n, P::JoinLock { link, door: None, grants })
        };
        let admission = size(&op_at(2, &sid, t + 50, readd(&sid, 7, (t + 50) as i64)));
        let (lock16, lock64) = (size(&lock_move(1, 16)), size(&lock_move(2, 64)));
        let rename = size(&op_at(7, &sid, t + 60, P::NicknameChanged { peer_id: id(7), nickname: "n".repeat(32) }));
        let leave = size(&op_at(7, &sid, t + 61, P::MemberRemoved { peer_id: id(7), seen: None }));
        let moderation = size(&op_at(3, &sid, t + 62, P::MemberBanned { peer_id: id(7), seen: None }));
        let days = 90;
        let first16 = days * 60 * (admission + lock16);
        let first64 = days * 60 * (admission + lock64);
        let joiners = days * (40 * rename + 20 * leave);
        let staff_acts = days * 20 * moderation;
        let numbers = format!(
            "op bytes: admission {admission}, lock move 16/64 grants {lock16}/{lock64}, rename {rename}, leave {leave}, ban {moderation}; \
             90 days: staff-first {:.1}/{:.1} MiB, joiners' own ops {:.2} MiB, moderator acts {:.2} MiB",
            first16 as f64 / 1048576.0,
            first64 as f64 / 1048576.0,
            joiners as f64 / 1048576.0,
            staff_acts as f64 / 1048576.0
        );
        // At 64 grants a move the accepted claim is two months (no budget raise): what the
        // staff wrote by then.
        let two_months64 = first64 * 60 / days;
        assert!(first16 <= LEAD && two_months64 <= LEAD, "an honest admin's admissions and moves outgrow the staff budget: {numbers}");
        let quiet = fill(&[("admin", joiners), ("moderator", staff_acts)], BUDGET - first16, FLOOR);
        assert_eq!((quiet[0], quiet[1]), (joiners, staff_acts), "no flood parks an honest op: {numbers}");
        let names: Vec<String> = (0..512).map(|k| format!("sybil{k}")).collect();
        let mut flood: Vec<(&str, usize)> = names.iter().map(|n| (n.as_str(), 1usize << 30)).collect();
        flood.push(("moderator", staff_acts));
        let squeezed = fill(&flood, BUDGET - two_months64, FLOOR);
        assert!(squeezed[512] >= FLOOR.min(staff_acts), "beside 512 floods the moderator keeps its floor: {numbers}");
    }

    /// At the bound a flood costs no rebuild: an author already over its share stays over
    /// whatever it adds (its demand moves no level), so its ops wait in `held` at once;
    /// an honest author's live ops fold, and the tail ends where a whole rebuild ends.
    #[test]
    fn at_the_bound_a_capped_flood_costs_no_rebuild() {
        let (mut owner, mut history, t) = staffed();
        let sid = owner.server_id.clone();
        let ch = general(&owner);
        let flooders: Vec<u8> = (40..60).collect();
        let admitted: Vec<CrdtOp> = flooders.iter().map(|&f| op_at(1, &sid, t + 10 + f as u64, add(&sid, f))).collect();
        owner.ingest_remote(&admitted);
        history.extend(admitted);
        let cp = checkpoint(&mut owner);
        let nick = |f: u8, at: u64, k: u64| op_at(f, &sid, at, P::NicknameChanged { peer_id: id(f), nickname: "x".repeat(500) + &k.to_string() });
        let flood: Vec<CrdtOp> = flooders.iter().flat_map(|&f| (0..20u64).map(move |k| (f, k))).map(|(f, k)| nick(f, t + 1000 + f as u64 * 100 + k, k)).collect();
        let more: Vec<CrdtOp> = (0..20u64).flat_map(|k| flooders.iter().map(move |&f| (f, k))).map(|(f, k)| nick(f, t + 50_000 + k * 100 + f as u64, k)).collect();
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(std::slice::from_ref(&cp));
        r.ingest_remote(&flood);
        let parked = |r: &ServerState| r.stored.iter().filter(|(_, k)| matches!(k, RowKind::Parked(_))).count();
        let rows = (r.op_log.len(), parked(&r));
        let rebuilds = more.iter().filter(|o| r.ingest_remote(std::slice::from_ref(*o)).rebuilt).count();
        assert_eq!(rebuilds, 0, "a capped author's op at the bound rebuilt the server");
        assert!(!r.held.is_empty() && (r.op_log.len(), parked(&r)) == rows, "over its share it waits in held, never as a row");
        let live: Vec<CrdtOp> = (0..12u64)
            .map(|k| op_at(2, &sid, t + 90_000 + k, P::ChannelRenamed { channel_id: ch.clone(), new_name: format!("{k}") }))
            .collect();
        for op in &live {
            r.ingest_remote(std::slice::from_ref(op));
        }
        assert_eq!(r.channels[&ch].name, "11", "an author under the level folds every live op");
        let mut whole = joiner(&sid, 8);
        whole.ingest_remote(&history);
        whole.ingest_remote(&[cp.clone()].into_iter().chain(flood).chain(more).chain(live).collect::<Vec<_>>());
        assert_eq!(view(&r), view(&whole), "the tail and a whole rebuild of the same set");
    }

    /// The base order puts generation before clock: a deeper chain of the owner's
    /// checkpoints is the base though a rival of its parent's generation is later, and
    /// that rival stays a dormant row (served, not folded), in every arrival order.
    #[test]
    fn a_deeper_checkpoint_chain_is_the_base_whatever_its_clock() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let c1 = checkpoint(&mut owner);
        let covers = owner.checkpoint_covers();
        let forge = |owner: &ServerState, generation: u64, parent: &CrdtOp, ms: u64| {
            let mut st: ServerState = serde_json::from_str(&owner.checkpoint_json(&id(1), &[], 0).unwrap()).unwrap();
            st.cp_generation = generation;
            st.cp_parent = Some(hex::encode(parent.content_hash()));
            let P::ServerCheckpoint { state, .. } = &parent.payload else { unreachable!() };
            let up: ServerState = serde_json::from_str(state).unwrap();
            st.cp_lineage = std::iter::once(hex::encode(parent.content_hash())).chain(up.cp_lineage).collect();
            op_at(1, &sid, ms, P::ServerCheckpoint { state: serde_json::to_string(&st).unwrap(), covers: covers.clone() })
        };
        let c2a = forge(&owner, 1, &c1, t + 2000);
        let c2b = forge(&owner, 1, &c1, t + 1500);
        let c3b = forge(&owner, 2, &c2b, t + 1600);
        for order in [[&c1, &c2a, &c2b, &c3b], [&c3b, &c2b, &c2a, &c1], [&c2b, &c3b, &c1, &c2a]] {
            let mut r = joiner(&sid, 9);
            r.ingest_remote(&history);
            for cp in order {
                r.ingest_remote(std::slice::from_ref(cp));
            }
            assert_eq!(r.base.as_ref().map(|b| b.hash), Some(c3b.content_hash()), "the deeper chain is the base");
            assert!(keys_of(&r).contains(&(c2a.author.clone(), c2a.hlc.clone())), "the later rival of the parent stays a dormant row");
        }
    }

    /// The other half of U2 for every stamped element: an admin's write older than the
    /// owner's newer one, which the owner never saw, changes nothing on any replica: a
    /// rename, a removal before a channel was added, an add before it was removed, an
    /// unpin, an unassignment, a label made before its deletion, an emote removal, a
    /// layout, a grant before its revocation, and a nickname from before a re-admission.
    #[test]
    fn a_late_older_write_never_undoes_a_newer_one_on_any_element() {
        let (mut owner, mut history, t) = staffed();
        let sid = owner.server_id.clone();
        let ch = general(&owner);
        let [c3, c4] = ["c3", "c4"].map(|c| format!("{}-{c}", &sid[..8]));
        let text = |c: &str| P::ChannelAdded { channel_id: c.into(), name: "c".into(), category: None, channel_type: "text".into() };
        let label = |l: &str| P::LabelCreated { label_id: l.into(), name: "L".into(), color: "#fff".into(), access: false };
        let layout = |n: usize| P::ChannelLayoutUpdated { layout_json: format!("[{}]", vec!["{\"type\":\"separator\"}"; n].join(",")) };
        let seen = vec![
            op_at(1, &sid, t + 6, text(&c4)),
            op_at(1, &sid, t + 7, label("l3")),
            op_at(1, &sid, t + 8, label("l4")),
            op_at(1, &sid, t + 30, P::ChannelRenamed { channel_id: ch.clone(), new_name: "new".into() }),
            op_at(1, &sid, t + 31, text(&c3)),
            op_at(1, &sid, t + 32, P::ChannelRemoved { channel_id: c4.clone() }),
            op_at(1, &sid, t + 33, P::MessagePinned { channel_id: ch.clone(), message_id: "m2".into() }),
            op_at(1, &sid, t + 34, P::LabelAssigned { label_id: "l3".into(), peer_id: id(4) }),
            op_at(1, &sid, t + 35, P::LabelDeleted { label_id: "l4".into() }),
            op_at(1, &sid, t + 36, P::EmojiAdded { name: "e2".into(), hash: format!("{:064x}", 9), animated: false }),
            op_at(1, &sid, t + 37, layout(2)),
            op_at(1, &sid, t + 38, P::ChannelGrantRevoked { channel_id: ch.clone(), peer_id: id(4) }),
            op_at(1, &sid, t + 39, P::MemberRemoved { peer_id: id(4), seen: None }),
            op_at(1, &sid, t + 40, readd(&sid, 4, (t + 40) as i64)),
        ];
        owner.ingest_remote(&seen);
        history.extend(seen);
        let unseen = vec![
            op_at(4, &sid, t + 19, P::NicknameChanged { peer_id: id(4), nickname: "old".into() }),
            op_at(2, &sid, t + 20, P::ChannelRenamed { channel_id: ch.clone(), new_name: "old".into() }),
            op_at(2, &sid, t + 21, P::ChannelRemoved { channel_id: c3.clone() }),
            op_at(2, &sid, t + 22, text(&c4)),
            op_at(2, &sid, t + 23, P::MessageUnpinned { channel_id: ch.clone(), message_id: "m2".into() }),
            op_at(2, &sid, t + 24, P::LabelUnassigned { label_id: "l3".into(), peer_id: id(4) }),
            op_at(2, &sid, t + 25, label("l4")),
            op_at(2, &sid, t + 26, P::EmojiRemoved { name: "e2".into() }),
            op_at(2, &sid, t + 27, layout(1)),
            op_at(2, &sid, t + 29, P::ChannelGrantSet { channel_id: ch.clone(), peer_id: id(4), expires_at: u64::MAX }),
        ];
        let cp = checkpoint(&mut owner);
        let mut before = joiner(&sid, 9);
        before.ingest_remote(&history);
        before.ingest_remote(&unseen);
        before.ingest_remote(std::slice::from_ref(&cp));
        let mut after = joiner(&sid, 8);
        after.ingest_remote(&history);
        after.ingest_remote(std::slice::from_ref(&cp));
        after.ingest_remote(&unseen);
        owner.ingest_remote(&unseen);
        let mut fresh = joiner(&sid, 6);
        fresh.ingest_remote(&[history[0].clone(), cp.clone()]);
        fresh.ingest_remote(&unseen);
        let mut oracle = joiner(&sid, 7);
        oracle.ingest_remote(&history);
        oracle.ingest_remote(&unseen);
        for (who, s) in [("history", &oracle), ("before", &before), ("after", &after), ("owner", &owner), ("fresh", &fresh)] {
            assert_eq!(s.channels[&ch].name, "new", "{who}: rename");
            assert!(s.channels.contains_key(&c3) && !s.channels.contains_key(&c4), "{who}: channel existence");
            assert!(s.pinned_messages.get(&ch).is_some_and(|p| p.contains(&"m2".to_string())), "{who}: pin");
            assert!(s.label_assignments.get(&id(4)).is_some_and(|l| l.contains(&"l3".to_string())), "{who}: assignment");
            assert!(!s.labels.contains_key("l4") && s.emotes.contains_key("e2"), "{who}: label and emote");
            assert_eq!(s.get_nickname(&id(4)), "", "{who}: a nickname from before the re-admission");
            assert_eq!(view(s), view(&oracle), "{who}: the rebase equals the fold from history");
        }
    }

    /// H2's drift rule: an admission dated before its own ask (past the clock bound) is
    /// refused, whoever signs it.
    #[test]
    fn an_admission_dated_before_its_own_ask_is_refused() {
        let (mut owner, _, t) = staffed();
        let sid = owner.server_id.clone();
        let ahead = (t + 50 + crate::crdt::hlc::MAX_DRIFT_MS + 1_000) as i64;
        let early = op_at(1, &sid, t + 50, readd(&sid, 7, ahead));
        owner.ingest_remote(std::slice::from_ref(&early));
        assert!(!owner.is_member(&id(7)), "an ask from after the admission seated someone");
        let fine = op_at(1, &sid, t + 51, readd(&sid, 7, (t + 51) as i64));
        owner.ingest_remote(std::slice::from_ref(&fine));
        assert!(owner.is_member(&id(7)), "control: the same ask in time admits");
    }

    /// H3's charge groups: a member's puppet tree charges that member, so a heavy honest
    /// moderator keeps every op beside twenty puppets flooding.
    #[test]
    fn a_puppet_tree_charges_the_member_who_started_it() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let cp = checkpoint(&mut owner);
        let mut ops = Vec::new();
        for p in 0..20u8 {
            let tag = 40 + p;
            ops.push(op_at(4, &sid, t + 1000 + p as u64, readd(&sid, tag, (t + 1000) as i64)));
            for k in 0..40u64 {
                ops.push(op_at(tag, &sid, t + 2000 + p as u64 * 100 + k, P::NicknameChanged { peer_id: id(tag), nickname: "x".repeat(500) + &k.to_string() }));
            }
        }
        let honest: Vec<CrdtOp> = (0..60u64)
            .map(|k| op_at(3, &sid, t + 9000 + k, P::NicknameChanged { peer_id: id(3), nickname: format!("{k}{}", "h".repeat(500)) }))
            .collect();
        ops.extend(honest.iter().cloned());
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(std::slice::from_ref(&cp));
        r.ingest_remote(&ops);
        let kept = honest.iter().filter(|o| r.op_log.iter().any(|x| x.hlc == o.hlc)).count();
        assert_eq!(kept, honest.len(), "the honest moderator's ops all fold");
    }

    /// The staff budget is part of the whole: past it, an admin's admissions count against
    /// its own share, and nothing folded passes the budget.
    #[test]
    fn staff_admissions_past_their_budget_stay_inside_the_whole() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let cp = checkpoint(&mut owner);
        let joins: Vec<CrdtOp> = (0..320u32)
            .map(|j| {
                let (kp, jid, _) = crate::crdt::testkeys::keys_n(1000 + j);
                let ask = crate::crdt::operations::JoinAsk::sign(&sid, (t + 5000) as i64, &kp);
                op_at(2, &sid, t + 5000 + j as u64, P::MemberAdded { peer_id: jid, display_name: "m".repeat(200), follow: None, ask: Some(ask) })
            })
            .collect();
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(std::slice::from_ref(&cp));
        r.ingest_remote(&joins);
        let bytes: usize = r.op_log.iter().filter(|o| o.hlc.physical_ms >= t + 5000).map(|o| serde_json::to_string(o).unwrap().len()).sum();
        let total: usize = joins.iter().map(|o| serde_json::to_string(o).unwrap().len()).sum();
        assert!(total > QUOTA_BYTES && bytes <= QUOTA_BYTES, "folded {bytes} of {total}");
    }


    // ---- t14-cover fix round (review rev 3) ----

    /// A 0.14 kick or ban that names no grant as seen.
    fn kick(tag: u8) -> P {
        P::MemberRemoved { peer_id: id(tag), seen: Some(Box::default()) }
    }

    fn ban(tag: u8) -> P {
        P::MemberBanned { peer_id: id(tag), seen: Some(Box::default()) }
    }

    /// An unstamped (0.13) checkpoint of `owner` covering `covers`, as 0.13 wrote it.
    fn checkpoint_0_13(owner: &ServerState, sid: &str, covers_ms: u64, at_ms: u64) -> CrdtOp {
        let mut old = owner.lean_snapshot();
        *old.stamps = Default::default();
        old.member_events.clear();
        old.cp_stamped = false;
        old.retained_print = None;
        let covers = HlcTimestamp { physical_ms: covers_ms, counter: 0, actor: id(1) };
        op_at(1, sid, at_ms, P::ServerCheckpoint { state: serde_json::to_string(&old).unwrap(), covers })
    }

    /// Finding 1, the re-creation variants: what a 0.13 checkpoint decided by its `covers`
    /// (a channel, a label and an emote removed and made again) stays decided on its
    /// stamped child and grandchild, at the door and in the apply arm alike.
    #[test]
    fn a_stamped_child_of_a_0_13_base_keeps_what_it_made_again() {
        let (mut owner, founding) = founded(1);
        let sid = owner.server_id.clone();
        let t = founding.hlc.physical_ms;
        let x = format!("{}-cx", &sid[..8]);
        let chan = P::ChannelAdded { channel_id: x.clone(), name: "x".into(), category: None, channel_type: "text".into() };
        let label = P::LabelCreated { label_id: "l1".into(), name: "L".into(), color: "#fff".into(), access: false };
        let emote = P::EmojiAdded { name: "e1".into(), hash: format!("{:064x}", 3), animated: false };
        owner.ingest_remote(&[
            op_at(1, &sid, t + 1, add(&sid, 2)),
            op_at(1, &sid, t + 2, P::RoleChanged { peer_id: id(2), role: MemberRole::Admin, priority: 3 }),
            op_at(1, &sid, t + 5, chan.clone()),
            op_at(1, &sid, t + 6, label.clone()),
            op_at(1, &sid, t + 7, emote.clone()),
            op_at(1, &sid, t + 10, P::ChannelRemoved { channel_id: x.clone() }),
            op_at(1, &sid, t + 11, P::LabelDeleted { label_id: "l1".into() }),
            op_at(1, &sid, t + 12, P::EmojiRemoved { name: "e1".into() }),
            op_at(1, &sid, t + 30, chan),
            op_at(1, &sid, t + 31, label),
            op_at(1, &sid, t + 32, emote),
        ]);
        let cp0 = checkpoint_0_13(&owner, &sid, t + 50, t + 60);
        let stale = vec![
            op_at(2, &sid, t + 20, P::ChannelRemoved { channel_id: x.clone() }),
            op_at(2, &sid, t + 21, P::LabelDeleted { label_id: "l1".into() }),
            op_at(2, &sid, t + 22, P::EmojiRemoved { name: "e1".into() }),
        ];
        let mut child = owner.clone();
        child.ingest_remote(std::slice::from_ref(&cp0));
        let c1 = checkpoint(&mut child);
        child.ingest_remote(&[op_at(2, &sid, t + 70, P::ServerRenamed { new_name: "later".into() })]);
        let c2 = checkpoint(&mut child);
        for (generation, chain) in [(1u64, vec![cp0.clone(), c1.clone()]), (2, vec![cp0.clone(), c1.clone(), c2.clone()])] {
            let mut r = joiner(&sid, 8);
            r.ingest_remote(std::slice::from_ref(&founding));
            r.ingest_remote(&chain);
            assert_eq!(r.base.as_ref().map(|b| b.generation), Some(generation));
            let before = view(&r);
            let mut applied = r.clone();
            for op in &stale {
                applied.apply_payload(op);
            }
            assert_eq!(view(&applied), before, "gen {generation}: the apply arm changed what the 0.13 covers decided");
            r.ingest_remote(&stale);
            assert!(r.channels.contains_key(&x) && r.labels.contains_key("l1") && r.emotes.contains_key("e1"), "gen {generation}: a stale removal undid a re-creation");
            assert!(!stale.iter().any(|o| r.op_log.iter().any(|x| x.hlc == o.hlc)), "gen {generation}: the door folded an op the floor decides");
            assert_eq!(view(&r), before, "gen {generation}");
        }
    }

    /// Finding 2, the tree layer alone: a member's own later op is not parked by the flood
    /// of a puppet it admitted (the puppet is a subtree of its own inside the member's tree).
    #[test]
    fn a_puppets_flood_never_parks_its_admitters_own_ops() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let cp = checkpoint(&mut owner);
        let mut ops = vec![op_at(4, &sid, t + 100, readd(&sid, 60, (t + 100) as i64))];
        ops.extend((0..30u64).map(|k| op_at(60, &sid, t + 200 + k, P::NicknameChanged { peer_id: id(60), nickname: "x".repeat(10_000) + &k.to_string() })));
        ops.push(op_at(4, &sid, t + 400, P::NicknameChanged { peer_id: id(4), nickname: "mine".into() }));
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(std::slice::from_ref(&cp));
        r.ingest_remote(&ops);
        assert_eq!(r.get_nickname(&id(4)), "mine", "the puppet's flood parked its admitter's own op");
        assert!(r.get_nickname(&id(60)).len() < 20_000 || r.held.iter().any(|(o, _)| o.author == id(60)), "control: the puppet is over its share");
    }

    /// Finding 2, the staff layer alone: a moderator over its own share still bans, kicks
    /// and mutes; those come before every share.
    #[test]
    fn a_staff_member_over_its_share_still_bans_and_kicks() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let cp = checkpoint(&mut owner);
        let mut ops: Vec<CrdtOp> = (0..30u64)
            .map(|k| op_at(3, &sid, t + 100 + k, P::NicknameChanged { peer_id: id(3), nickname: "x".repeat(10_000) + &k.to_string() }))
            .collect();
        ops.push(op_at(3, &sid, t + 500, P::MemberMuted { peer_id: id(4), expires_at: u64::MAX }));
        ops.push(op_at(3, &sid, t + 501, ban(4)));
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(std::slice::from_ref(&cp));
        r.ingest_remote(&ops);
        assert!(r.op_log.iter().any(|o| o.hlc.physical_ms == t + 500), "the moderator's mute was parked");
        assert!(r.is_banned(&id(4)), "the moderator's ban was parked");
    }

    /// A floor above the checkpoint's own `covers` would decide ops it never covered: such a
    /// checkpoint is no base.
    #[test]
    fn a_checkpoint_whose_floor_passes_its_covers_is_no_base() {
        let (mut owner, history, _) = staffed();
        let sid = owner.server_id.clone();
        let c1 = checkpoint(&mut owner);
        let mut st: ServerState = serde_json::from_str(&owner.checkpoint_json(&id(1), &[], 0).unwrap()).unwrap();
        let covers = owner.checkpoint_covers();
        st.cp_floor = Some(HlcTimestamp { physical_ms: covers.physical_ms + 1, counter: 0, actor: String::new() });
        let forged = owner.create_op(P::ServerCheckpoint { state: serde_json::to_string(&st).unwrap(), covers });
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(&[c1.clone(), forged]);
        assert_eq!(r.base.as_ref().map(|b| b.hash), Some(c1.content_hash()), "a floor past its covers made a base");
    }

    /// The owner's own role change at the bound moves who acts first: the tail rebuilds, so
    /// a member it promotes has its earlier admissions counted as staff acts there as a
    /// whole rebuild counts them.
    #[test]
    fn an_owner_promotion_at_the_bound_folds_as_a_whole_rebuild_does() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let cp = checkpoint(&mut owner);
        let mut ops: Vec<CrdtOp> = (0..14u64)
            .map(|k| op_at(4, &sid, t + 100 + k, P::NicknameChanged { peer_id: id(4), nickname: "x".repeat(15_000) + &k.to_string() }))
            .collect();
        ops.extend((0..6u8).map(|j| op_at(4, &sid, t + 200 + j as u64, readd(&sid, 70 + j, (t + 200 + j as u64) as i64))));
        let promote = op_at(1, &sid, t + 300, P::RoleChanged { peer_id: id(4), role: MemberRole::Moderator, priority: 3 });
        let mut tail = joiner(&sid, 9);
        tail.ingest_remote(&history);
        tail.ingest_remote(std::slice::from_ref(&cp));
        tail.ingest_remote(&ops);
        assert!(!tail.is_member(&id(75)), "control: past its share the member's admissions wait");
        tail.ingest_remote(std::slice::from_ref(&promote));
        let mut whole = joiner(&sid, 8);
        whole.ingest_remote(&history);
        whole.ingest_remote(&[cp.clone()].into_iter().chain(ops.iter().cloned()).chain([promote]).collect::<Vec<_>>());
        assert!(whole.is_member(&id(75)), "control: a moderator's admissions come first");
        assert_eq!(view(&tail), view(&whole), "the tail and a whole rebuild of the same set");
    }

    /// A removal its author could not make voids nothing: a member's forged kick of an
    /// admin leaves the admin's grants standing.
    #[test]
    fn a_kick_its_author_could_not_make_voids_nothing() {
        let (owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(&[op_at(2, &sid, t + 10, add(&sid, 5)), op_at(4, &sid, t + 20, kick(2))]);
        assert!(r.is_member(&id(2)), "control: the kick is refused");
        r.ingest_remote(&[op_at(1, &sid, t + 15, P::ServerRenamed { new_name: "rebuild".into() })]);
        assert!(r.is_member(&id(5)), "a refused kick voided the admin's admission");
    }

    /// A legacy server folds in arrival order: nothing is "after" there, so nothing voids.
    #[test]
    fn a_legacy_server_voids_nothing() {
        let (mut legacy, _) = crate::crdt::testkeys::owned_state("s-legacy", "Old", 1);
        let sid = legacy.server_id.clone();
        let t = crate::crdt::hlc::wall_clock_ms() - 10_000;
        legacy.ingest_remote(&[op_at(1, &sid, t + 1, add(&sid, 2)), op_at(1, &sid, t + 10, kick(2)), op_at(1, &sid, t + 20, readd(&sid, 2, (t + 20) as i64))]);
        assert!(legacy.is_member(&id(2)));
        assert_eq!(legacy.anchor(), Anchor::Legacy);
        legacy.ingest_remote(&[op_at(2, &sid, t + 5, add(&sid, 5))]);
        assert!(legacy.is_member(&id(5)), "a legacy replica voided an op it took in arrival order");
    }

    /// An op bigger than any honest one is refused at the door, signature or not; a
    /// checkpoint has a bound of its own, far above a 512-identity state.
    #[test]
    fn an_op_past_its_byte_bound_is_refused() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        let fat = op_at(1, &sid, t + 50, P::ServerRenamed { new_name: "x".repeat(MAX_OP_BYTES) });
        let got = r.ingest_remote(std::slice::from_ref(&fat));
        assert!(got.admitted.is_empty() && got.rejected == 1 && r.held.is_empty(), "a 1 MiB op was taken");
        let fine = op_at(1, &sid, t + 51, P::ServerRenamed { new_name: "x".repeat(MAX_OP_BYTES - 4096) });
        let got = r.ingest_remote(std::slice::from_ref(&fine));
        assert_eq!(got.admitted.len(), 1, "control: under the bound ({} rejected, {} held)", got.rejected, r.held.len());
        let covers = owner.checkpoint_covers();
        let mut st: ServerState = serde_json::from_str(&owner.checkpoint_json(&id(1), &[], 0).unwrap()).unwrap();
        st.name = crate::crdt::admin_lww::AdminLwwReg::new("n".repeat(MAX_CHECKPOINT_BYTES), st.name.hlc().clone(), 4);
        let huge = owner.create_op(P::ServerCheckpoint { state: serde_json::to_string(&st).unwrap(), covers });
        assert_eq!(r.ingest_remote(std::slice::from_ref(&huge)).rejected, 1, "a checkpoint past its bound was taken");
        let cp = checkpoint(&mut owner);
        r.ingest_remote(std::slice::from_ref(&cp));
        assert!(r.base.is_some(), "control: a real checkpoint is taken");
    }

    /// Without a checkpoint a joiner that took the founding op at the tail charges the
    /// same trees as one that folded everything at once.
    #[test]
    fn a_joiner_built_op_by_op_charges_as_a_whole_rebuild_does() {
        let (_owner, history, t) = staffed();
        let sid = history[0].server_id.clone();
        let mut all = history.clone();
        all.push(op_at(1, &sid, t + 50, P::ServerRenamed { new_name: "o".repeat(200_000) }));
        all.extend((0..10u64).map(|k| op_at(4, &sid, t + 100 + k, P::NicknameChanged { peer_id: id(4), nickname: "x".repeat(1_000) + &k.to_string() })));
        let mut tail = joiner(&sid, 9);
        for op in &all {
            tail.ingest_remote(std::slice::from_ref(op));
        }
        let mut whole = joiner(&sid, 8);
        whole.ingest_remote(&all);
        assert_eq!(tail.name().len(), 200_000, "the owner is never charged");
        assert_eq!(view(&tail), view(&whole));
    }

    /// A late leave that moves a member's current span later voids the registers written
    /// before the new start, as a removal would have (the record changed in the past, not
    /// at the tail), and the apply arm alone voids a register write dated before the span.
    #[test]
    fn a_late_leave_moving_the_span_voids_the_registers_before_it() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        owner.ingest_remote(&[
            op_at(4, &sid, t + 10, P::NicknameChanged { peer_id: id(4), nickname: "old".into() }),
            op_at(1, &sid, t + 40, readd(&sid, 4, (t + 40) as i64)),
        ]);
        assert_eq!(owner.get_nickname(&id(4)), "old", "control: a repeat admission keeps the span");
        let cp = checkpoint(&mut owner);
        let leave = op_at(4, &sid, t + 20, P::MemberRemoved { peer_id: id(4), seen: None });
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(std::slice::from_ref(&cp));
        r.ingest_remote(std::slice::from_ref(&leave));
        assert!(r.is_member(&id(4)), "the admission on a newer ask opens again after the late leave");
        assert_eq!(r.get_nickname(&id(4)), "", "a nickname from before the span the late leave moved stays");
        let mut applied = r.clone();
        applied.apply_payload(&op_at(4, &sid, t + 30, P::NicknameChanged { peer_id: id(4), nickname: "gap".into() }));
        assert_eq!(applied.get_nickname(&id(4)), "", "the apply arm took a write dated before the current span");
    }

    /// The owner promoting a member whose acts are parked rows (nothing held) rebuilds:
    /// those acts come first now, as a whole rebuild of the same set has them.
    #[test]
    fn an_owner_promotion_at_the_bound_counts_parked_staff_acts() {
        let (mut owner, mut history, t) = staffed();
        let sid = owner.server_id.clone();
        let admit5 = op_at(1, &sid, t + 6, add(&sid, 5));
        owner.ingest_remote(std::slice::from_ref(&admit5));
        history.push(admit5);
        let cp = checkpoint(&mut owner);
        let mut mine: Vec<CrdtOp> = (0..10u64)
            .map(|k| op_at(4, &sid, t + 100 + k, P::NicknameChanged { peer_id: id(4), nickname: "x".repeat(14_000) + &k.to_string() }))
            .collect();
        mine.extend((0..6u8).map(|j| op_at(4, &sid, t + 200 + j as u64, readd(&sid, 70 + j, (t + 200 + j as u64) as i64))));
        let theirs: Vec<CrdtOp> = (0..6u64)
            .map(|k| op_at(5, &sid, t + 300 + k, P::NicknameChanged { peer_id: id(5), nickname: "y".repeat(15_000) + &k.to_string() }))
            .collect();
        let promote = op_at(1, &sid, t + 400, P::RoleChanged { peer_id: id(4), role: MemberRole::Moderator, priority: 3 });
        let mut tail = joiner(&sid, 9);
        tail.ingest_remote(&history);
        tail.ingest_remote(std::slice::from_ref(&cp));
        tail.ingest_remote(&mine);
        tail.ingest_remote(&theirs);
        assert!(!tail.is_member(&id(75)) && tail.held.is_empty(), "control: the member's admissions are parked rows, nothing held");
        tail.ingest_remote(std::slice::from_ref(&promote));
        let mut whole = joiner(&sid, 8);
        whole.ingest_remote(&history);
        whole.ingest_remote(&[cp].into_iter().chain(mine).chain(theirs).chain([promote]).collect::<Vec<_>>());
        assert!(whole.is_member(&id(75)), "control: a moderator's admissions come first");
        assert_eq!(view(&tail), view(&whole), "the tail and a whole rebuild of the same set");
    }

    /// A staff act at the bound takes its bytes out of everyone's budget: when that moves a
    /// share below what is folded, the tail rebuilds as a whole rebuild would.
    #[test]
    fn a_staff_act_at_the_bound_folds_as_a_whole_rebuild_does() {
        let (mut owner, mut history, t) = staffed();
        let sid = owner.server_id.clone();
        let flooders: Vec<u8> = (40..60).collect();
        let admitted: Vec<CrdtOp> = flooders.iter().map(|&f| op_at(1, &sid, t + 10 + f as u64, add(&sid, f))).collect();
        owner.ingest_remote(&admitted);
        history.extend(admitted);
        let cp = checkpoint(&mut owner);
        let flood: Vec<CrdtOp> = flooders
            .iter()
            .flat_map(|&f| (0..20u64).map(move |k| (f, k)))
            .map(|(f, k)| op_at(f, &sid, t + 1000 + f as u64 * 100 + k, P::NicknameChanged { peer_id: id(f), nickname: "x".repeat(500) + &k.to_string() }))
            .collect();
        // Mutes, not admissions: no rebuild for a held op can hide the tail's own verdict.
        let joins: Vec<CrdtOp> = (0..40u64)
            .map(|k| op_at(3, &sid, t + 9000 + k, P::MemberMuted { peer_id: id(40 + (k % 20) as u8), expires_at: u64::MAX - k }))
            .collect();
        let mut tail = joiner(&sid, 9);
        tail.ingest_remote(&history);
        tail.ingest_remote(std::slice::from_ref(&cp));
        tail.ingest_remote(&flood);
        for j in &joins {
            tail.ingest_remote(std::slice::from_ref(j));
        }
        let mut whole = joiner(&sid, 8);
        whole.ingest_remote(&history);
        whole.ingest_remote(&[cp].into_iter().chain(flood).chain(joins).collect::<Vec<_>>());
        assert_eq!(view(&tail), view(&whole), "the tail and a whole rebuild of the same set");
    }

    /// Finding 3: a parked row past its time is deleted at the restart, not kept.
    #[test]
    fn a_restart_deletes_the_rows_parked_past_their_time() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let cp = checkpoint(&mut owner);
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(std::slice::from_ref(&cp));
        let rows: Vec<(CrdtOp, Option<u64>)> = r.op_log.iter().map(|o| (o.clone(), None)).collect();
        let now = crate::crdt::hlc::wall_clock_ms();
        let expired = op_at(4, &sid, t + 100, P::NicknameChanged { peer_id: id(4), nickname: "old".into() });
        let waiting = op_at(4, &sid, t + 101, P::NicknameChanged { peer_id: id(9), nickname: "x".into() });
        let mut restarted = joiner(&sid, 9);
        let mut all = rows.clone();
        all.push((expired.clone(), Some(now - 1)));
        all.push((waiting.clone(), Some(now + PARK_MS)));
        let restored = restarted.restore_op_log(all);
        assert_eq!(restored.dropped, vec![(expired.author.clone(), expired.hlc.clone())], "only the expired row is deleted");
        assert!(restarted.stored.iter().any(|(o, _)| o.hlc == waiting.hlc), "a row still within its time stays parked");
    }

    /// Finding 3: whatever a refusal or a quota parks, a charge group keeps at most
    /// `PARK_GROUP_BYTES` of it, the oldest first.
    #[test]
    fn a_group_keeps_its_parked_rows_within_their_bound() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let cp = checkpoint(&mut owner);
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(std::slice::from_ref(&cp));
        let posts: Vec<CrdtOp> = (0..30u64)
            .map(|k| op_at(4, &sid, t + 100 + k, P::NicknameChanged { peer_id: id(4), nickname: format!("{k:02}{}", "x".repeat(1000)) }))
            .collect();
        r.ingest_remote(&posts);
        assert_eq!(r.get_nickname(&id(4)).get(..2), Some("29"), "control: they all folded");
        r.ingest_remote(&[op_at(1, &sid, t + 50, P::MemberRemoved { peer_id: id(4), seen: None })]);
        let parked: Vec<&CrdtOp> = r.stored.iter().filter(|(_, k)| matches!(k, RowKind::Parked(_))).map(|(o, _)| o).collect();
        let bytes: usize = parked.iter().map(|o| op_size(o)).sum();
        assert!(!parked.is_empty() && bytes <= PARK_GROUP_BYTES, "{} parked rows of {bytes} bytes", parked.len());
        assert!(parked.iter().any(|o| o.hlc == posts[0].hlc), "the oldest stay");
        assert!(!parked.iter().any(|o| o.hlc == posts[29].hlc), "the newest go");
    }

    /// AR-11, the leave case: a member that left and was banned after cannot backdate an
    /// admission into the span its leave closed.
    #[test]
    fn a_ban_after_a_leave_voids_an_admission_backdated_into_that_span() {
        let (_owner, founding) = founded(1);
        let sid = _owner.server_id.clone();
        let t = founding.hlc.physical_ms;
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&[
            founding.clone(),
            op_at(1, &sid, t + 1, add(&sid, 2)),
            op_at(2, &sid, t + 10, P::MemberRemoved { peer_id: id(2), seen: None }),
            op_at(1, &sid, t + 20, ban(2)),
        ]);
        let backdated = op_at(2, &sid, t + 9, add(&sid, 5));
        let mut control = r.clone();
        control.ingest_remote(&[op_at(2, &sid, t + 2, add(&sid, 6))]);
        r.ingest_remote(std::slice::from_ref(&backdated));
        r.ingest_remote(&[op_at(5, &sid, t + 30, P::NicknameChanged { peer_id: id(5), nickname: "p".into() })]);
        assert!(!r.is_member(&id(5)), "a banned leaver seated a puppet in its old span");
        assert!(!control.is_member(&id(6)), "nor earlier in it");
    }

    /// A kick from before 0.14 carries no list and voids nothing: the history a server
    /// already holds keeps whom its later-kicked members admitted.
    #[test]
    fn a_removal_from_before_0_14_voids_nothing() {
        let (_owner, founding) = founded(1);
        let sid = _owner.server_id.clone();
        let t = founding.hlc.physical_ms;
        let history = vec![
            founding.clone(),
            op_at(1, &sid, t + 1, add(&sid, 2)),
            op_at(2, &sid, t + 5, add(&sid, 5)),
            op_at(1, &sid, t + 10, P::MemberRemoved { peer_id: id(2), seen: None }),
        ];
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(&[op_at(1, &sid, t + 4, P::ServerRenamed { new_name: "rebuild".into() })]);
        assert!(r.is_member(&id(5)) && !r.is_member(&id(2)));
    }

    /// AR-11: what the remover saw stays; what it never saw is void, whichever arrives
    /// first, live at the tail or in a rebuild.
    #[test]
    fn a_kick_keeps_the_grants_its_author_saw_and_voids_the_rest() {
        let (mut owner, founding) = founded(1);
        let sid = owner.server_id.clone();
        let t = founding.hlc.physical_ms;
        let admit2 = op_at(1, &sid, t + 1, add(&sid, 2));
        let seen = op_at(2, &sid, t + 5, add(&sid, 5));
        let unseen = op_at(2, &sid, t + 6, add(&sid, 6));
        owner.ingest_remote(&[admit2.clone(), seen.clone()]);
        let authored = owner.clone().author_checked(P::MemberRemoved { peer_id: id(2), seen: None }).expect("the owner kicks 2");
        let P::MemberRemoved { seen: Some(list), .. } = &authored.payload else { panic!("the kick names what it saw") };
        assert_eq!(list.ops.len(), 1, "the one grant of 2 the owner folded");
        let kick = op_at(1, &sid, t + 10, P::MemberRemoved { peer_id: id(2), seen: Some(list.clone()) });
        for order in [vec![admit2.clone(), seen.clone(), unseen.clone(), kick.clone()], vec![admit2.clone(), kick.clone(), unseen.clone(), seen.clone()]] {
            let mut r = joiner(&sid, 9);
            r.ingest_remote(std::slice::from_ref(&founding));
            for op in &order {
                r.ingest_remote(std::slice::from_ref(op));
            }
            assert!(r.is_member(&id(5)), "a grant the remover saw stays");
            assert!(!r.is_member(&id(6)), "a grant it never saw is void");
            assert!(!r.is_member(&id(2)));
        }
    }

    /// A ban closes only the span it ends: after a leave and an admission again, the
    /// grants of the older span stand, listed or not.
    #[test]
    fn a_ban_closes_only_the_last_span() {
        let (_owner, founding) = founded(1);
        let sid = _owner.server_id.clone();
        let t = founding.hlc.physical_ms;
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&[
            founding.clone(),
            op_at(1, &sid, t + 1, add(&sid, 2)),
            op_at(2, &sid, t + 5, add(&sid, 5)),
            op_at(2, &sid, t + 10, P::MemberRemoved { peer_id: id(2), seen: None }),
            op_at(1, &sid, t + 15, readd(&sid, 2, (t + 15) as i64)),
            op_at(1, &sid, t + 20, ban(2)),
        ]);
        assert!(r.is_member(&id(5)) && r.is_banned(&id(2)), "a ban voided a grant of a span a leave had closed");
    }

    /// AR-11 on top of a base: the removal's op is gone, its span end is in the record,
    /// and the member admitted again cannot backdate into the span it was kicked from.
    #[test]
    fn a_member_kicked_and_admitted_again_cannot_backdate_into_its_old_span() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        owner.ingest_remote(&[
            op_at(1, &sid, t + 10, kick(4)),
            op_at(1, &sid, t + 20, readd(&sid, 4, (t + 20) as i64)),
        ]);
        let cp = checkpoint(&mut owner);
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(std::slice::from_ref(&cp));
        assert!(r.is_member(&id(4)));
        r.ingest_remote(&[op_at(4, &sid, t + 9, add(&sid, 5))]);
        assert!(!r.is_member(&id(5)), "a backdated admission inside the kicked span");
        r.ingest_remote(&[op_at(4, &sid, t + 30, add(&sid, 6))]);
        assert!(r.is_member(&id(6)), "control: an admission in its new span stands");
    }

    /// A removal naming a base this replica lacks waits for it: it neither applies nor
    /// voids by a list it cannot judge.
    #[test]
    fn a_removal_naming_a_base_we_lack_waits_for_that_base() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let c1 = checkpoint(&mut owner);
        owner.ingest_remote(&[op_at(2, &sid, t + 40, P::ServerRenamed { new_name: "n".into() })]);
        let c2 = checkpoint(&mut owner);
        let kick = owner.author_checked(P::MemberRemoved { peer_id: id(4), seen: None }).unwrap();
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(std::slice::from_ref(&c1));
        r.ingest_remote(std::slice::from_ref(&kick));
        assert!(r.is_member(&id(4)), "the kick waits for the base it names");
        r.ingest_remote(std::slice::from_ref(&c2));
        assert!(!r.is_member(&id(4)), "and applies once it is here");
    }

    /// The list stays inside the op bound: past `SEEN_CAP` it names the newest and marks
    /// the rest by clock; a list past the cap or not hex is refused.
    #[test]
    fn a_removal_list_is_bounded_and_well_formed() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let grants: Vec<CrdtOp> = (0..(crate::crdt::voids::SEEN_CAP as u64 + 5))
            .map(|k| op_at(2, &sid, t + 100 + k, P::RolePermissionsChanged { role: "member".into(), permissions: (k % 2) as u32 }))
            .collect();
        owner.ingest_remote(&grants);
        let ban = owner.author_checked(P::MemberBanned { peer_id: id(2), seen: None }).expect("the owner bans 2");
        let P::MemberBanned { seen: Some(list), .. } = &ban.payload else { panic!() };
        assert_eq!(list.ops.len(), crate::crdt::voids::SEEN_CAP);
        assert_eq!(list.before.as_ref(), Some(&grants[5].hlc));
        let shipped = SeenGrants { base: list.base.clone(), ops: vec!["f".repeat(32); 1024], before: list.before.clone() };
        let full = op_at(1, &sid, t + 99, P::MemberBanned { peer_id: id(3), seen: Some(Box::new(shipped)) });
        assert!(serde_json::to_string(&full).unwrap().len() < 48 << 10, "the shipping cap keeps a kick about 36 KB");
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(&grants);
        r.ingest_remote(std::slice::from_ref(&ban));
        assert!(r.is_banned(&id(2)), "control");
        assert!(grants.iter().all(|g| r.op_log.iter().any(|o| o.hlc == g.hlc)), "every grant counts as seen, the cut ones too");
        let mut fat = (**list).clone();
        fat.ops.push("0".repeat(32));
        let bad = op_at(1, &sid, ban.hlc.physical_ms + 1, P::MemberBanned { peer_id: id(3), seen: Some(Box::new(fat)) });
        let mut odd = (**list).clone();
        odd.ops[0] = "ZZ".repeat(16);
        let bad2 = op_at(1, &sid, ban.hlc.physical_ms + 2, P::MemberBanned { peer_id: id(3), seen: Some(Box::new(odd)) });
        assert!(!r.op_allowed(&bad) && !r.op_allowed(&bad2), "a list past the cap or not hex is refused");
        let plain = op_at(1, &sid, t + 99, P::MemberRemoved { peer_id: id(3), seen: None });
        assert!(!serde_json::to_string(&plain.payload).unwrap().contains("seen"), "a removal without a list keeps its bytes");
    }

    /// Finding 6: one member and identities the owner admitted (the owner answers anyone)
    /// never make two witnesses; two members of the base from different roots do.
    #[test]
    fn the_writer_rule_needs_two_roots_in_the_base() {
        let (mut owner, _, t) = staffed();
        let sid = owner.server_id.clone();
        owner.ingest_remote(&[op_at(1, &sid, t + 6, add(&sid, 6))]);
        let _cp = checkpoint(&mut owner);
        owner.ingest_remote(&[
            op_at(1, &sid, t + 20, readd(&sid, 9, (t + 20) as i64)),
            op_at(4, &sid, t + 21, readd(&sid, 10, (t + 21) as i64)),
        ]);
        let w = |ids: &[u8]| ids.iter().map(|i| id(*i)).collect::<HashSet<String>>();
        assert!(!owner.checkpoint_witnessed(&id(1), &w(&[4, 9])), "a member and an identity the owner admitted");
        assert!(!owner.checkpoint_witnessed(&id(1), &w(&[4, 10])), "a member and its own puppet");
        assert!(owner.checkpoint_witnessed(&id(1), &w(&[4, 6])), "two members of the base");
        assert!(owner.checkpoint_witnessed(&id(1), &w(&[10, 6])), "a puppet of one and another member");
        assert!(owner.checkpoint_witnessed(&id(1), &w(&[9, 3])), "one of them a moderator");
    }

    /// F8: a stranger's op is never held, at the tail or in a rebuild.
    #[test]
    fn held_takes_only_authors_the_state_knows() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let cp = checkpoint(&mut owner);
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(std::slice::from_ref(&cp));
        r.ingest_remote(&[op_at(77, &sid, t + 100, P::ServerRenamed { new_name: "x".into() })]);
        r.ingest_remote(&[op_at(4, &sid, t + 300, P::NicknameChanged { peer_id: id(4), nickname: "n".into() })]);
        let rebuilt = r.ingest_remote(&[op_at(78, &sid, t + 250, P::ServerRenamed { new_name: "y".into() })]).rebuilt;
        assert!(rebuilt, "control: an op behind the tail goes through a rebuild");
        assert!(r.held.is_empty(), "a stranger's op waits in held");
        r.ingest_remote(&[op_at(5, &sid, t + 200, P::NicknameChanged { peer_id: id(5), nickname: "early".into() })]);
        r.ingest_remote(&[op_at(4, &sid, t + 150, readd(&sid, 5, (t + 150) as i64))]);
        assert_eq!(r.get_nickname(&id(5)), "", "an op ahead of its author's admission is not kept");
        let mut s = r.clone();
        s.ingest_remote(&[op_at(4, &sid, t + 160, readd(&sid, 11, (t + 160) as i64)), op_at(11, &sid, t + 170, P::NicknameChanged { peer_id: id(11), nickname: "ok".into() })]);
        assert_eq!(s.get_nickname(&id(11)), "ok", "control: one known by an admission in the batch folds");
    }

    /// A field of a channel that does not exist, or a label that does not, is refused at
    /// its point: it never stays in a log as an undecided no-op.
    #[test]
    fn a_write_to_a_missing_channel_or_label_is_refused() {
        let (owner, _, _) = staffed();
        let mut s = owner.clone();
        for p in [
            P::ChannelRenamed { channel_id: "nope-c9".into(), new_name: "x".into() },
            P::ChannelPublicChanged { channel_id: "nope-c9".into(), is_public: true },
            P::ChannelPostingChanged { channel_id: "nope-c9".into(), posting: "moderator".into() },
            P::ChannelSlowModeChanged { channel_id: "nope-c9".into(), seconds: 5 },
            P::ChannelMediaOnlyChanged { channel_id: "nope-c9".into(), media_only: true },
            P::ChannelVisibilityChanged { channel_id: "nope-c9".into(), visibility: "moderator".into() },
            P::ChannelVisibilityLabelsChanged { channel_id: "nope-c9".into(), labels: vec![] },
            P::ChannelPostingLabelsChanged { channel_id: "nope-c9".into(), labels: vec![] },
            P::LabelUpdated { label_id: "nope".into(), name: "x".into(), color: "#000".into(), access: None },
        ] {
            let name = payload_name(&p);
            assert!(s.author_checked(p).is_none(), "{name} on a missing element");
        }
        let ch = general(&owner);
        assert!(s.author_checked(P::ChannelRenamed { channel_id: ch, new_name: "x".into() }).is_some(), "control");
    }

    /// A live op the base decides and its parent does not is a row on its own: the ingest
    /// says so, so the node persists it with nothing admitted.
    #[test]
    fn a_dormant_row_made_at_the_door_is_in_the_delta() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let _c1 = checkpoint(&mut owner);
        let late = op_at(2, &sid, t + 40, P::ServerRenamed { new_name: "n".into() });
        owner.ingest_remote(std::slice::from_ref(&late));
        let c2 = checkpoint(&mut owner);
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(std::slice::from_ref(&_c1));
        r.ingest_remote(std::slice::from_ref(&c2));
        let got = r.ingest_remote(std::slice::from_ref(&late));
        assert!(got.admitted.is_empty(), "decided by the base");
        assert!(got.delta(&sid).is_some_and(|d| d.rows.iter().any(|(o, _)| o.hlc == late.hlc)), "the dormant row is in the delta");
    }

    /// R3-1: the first stamped child of a 0.13 checkpoint carries no stamps for anything the
    /// 0.13 checkpoint decided, so an op dated below the 0.13 `covers` (dominated by the
    /// generation-0 base) folds on top of generation 1: an old "everyone" reopens a channel
    /// restricted before the 0.13 checkpoint, an old rename undoes a newer one.
    #[test]
    fn rev3_a_stamped_child_of_a_0_13_base_still_decides_what_covers_decided() {
        let (mut owner, founding) = founded(1);
        let sid = owner.server_id.clone();
        let ch = general(&owner);
        let t = founding.hlc.physical_ms;
        let history = vec![
            op_at(1, &sid, t + 1, add(&sid, 2)),
            op_at(1, &sid, t + 4, P::RoleChanged { peer_id: id(2), role: MemberRole::Admin, priority: 3 }),
            op_at(1, &sid, t + 30, P::ChannelVisibilityChanged { channel_id: ch.clone(), visibility: "moderator".into() }),
            op_at(1, &sid, t + 31, P::ChannelRenamed { channel_id: ch.clone(), new_name: "newer".into() }),
        ];
        owner.ingest_remote(&history);
        // The 0.13 checkpoint: no stamps, no events, covers t+50.
        let mut old = owner.lean_snapshot();
        *old.stamps = Default::default();
        old.member_events.clear();
        old.cp_stamped = false;
        old.retained_print = None;
        let covers = HlcTimestamp { physical_ms: t + 50, counter: 0, actor: id(1) };
        let cp0 = op_at(1, &sid, t + 60, P::ServerCheckpoint { state: serde_json::to_string(&old).unwrap(), covers });
        // A phone of admin 2 offline across the 0.13 checkpoint still holds these (0.13 pruned
        // them everywhere else, and gen 0 decides them).
        let stale = vec![
            op_at(2, &sid, t + 20, P::ChannelVisibilityChanged { channel_id: ch.clone(), visibility: "everyone".into() }),
            op_at(2, &sid, t + 21, P::ChannelRenamed { channel_id: ch.clone(), new_name: "older".into() }),
        ];
        let mut gen0 = joiner(&sid, 9);
        gen0.ingest_remote(&[founding.clone(), cp0.clone()]);
        gen0.ingest_remote(&stale);
        assert_eq!(gen0.base.as_ref().map(|b| b.generation), Some(0));
        assert_eq!(gen0.channels[&ch].visibility, crate::crdt::server_state::ChannelVisibility::ModeratorPlus, "control: gen 0 decides it");
        // The owner upgrades: its state rebases on cp0 and it writes the stamped child.
        let mut child = owner.clone();
        child.ingest_remote(std::slice::from_ref(&cp0));
        let c1 = checkpoint(&mut child);
        let mut r = joiner(&sid, 8);
        r.ingest_remote(&[founding, cp0, c1]);
        assert_eq!(r.base.as_ref().map(|b| b.generation), Some(1));
        r.ingest_remote(&stale);
        assert_eq!(
            (r.channels[&ch].visibility.clone(), r.channels[&ch].name.clone()),
            (crate::crdt::server_state::ChannelVisibility::ModeratorPlus, "newer".to_string()),
            "ops below the 0.13 covers reopened a restricted channel and undid a newer rename on generation 1"
        );
    }

    /// R3-2: the quota charges a joiner's ops to the member at the root of its admission
    /// lineage, and inside a group the oldest ops keep their place. A member the acting
    /// leader admitted floods its own group (the leader's) and, once banned, adds one op
    /// dated just before the ban (still inside its span): the leader's ban is the op the
    /// allocation parks, and the flooder is seated again on every replica.
    #[test]
    fn rev3_a_joiner_flood_never_parks_the_ban_of_the_flooder() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let cp = checkpoint(&mut owner);
        let admit50 = op_at(2, &sid, t + 100, readd(&sid, 50, (t + 100) as i64));
        let flood: Vec<CrdtOp> = (0..24u64)
            .map(|k| op_at(50, &sid, t + 200 + k, P::NicknameChanged { peer_id: id(50), nickname: "x".repeat(10_000) + &k.to_string() }))
            .collect();
        let ban = op_at(2, &sid, t + 300, P::MemberBanned { peer_id: id(50), seen: None });
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(std::slice::from_ref(&cp));
        r.ingest_remote(std::slice::from_ref(&admit50));
        r.ingest_remote(&flood);
        r.ingest_remote(std::slice::from_ref(&ban));
        let mut unbanned_by = None;
        // Every length the flooder could pick to fill the ban's slot, sampled.
        for len in (0..12_000usize).step_by(37) {
            let extra = op_at(50, &sid, t + 299, P::NicknameChanged { peer_id: id(50), nickname: "y".repeat(len) });
            let mut probe = r.clone();
            probe.ingest_remote(std::slice::from_ref(&extra));
            if !probe.is_banned(&id(50)) {
                unbanned_by = Some((len, probe.is_member(&id(50))));
                break;
            }
        }
        assert_eq!(unbanned_by, None, "one backdated op of the flooder parked the ban of it (len, seated again)");
    }

    /// R3-3: the rebuild hysteresis lets a tail op fold that a whole rebuild of the same op set
    /// parks, so two replicas holding the same ops disagree (and a restart changes the state).
    #[test]
    fn rev3_the_same_ops_fold_the_same_at_the_quota_bound() {
        let (mut owner, mut history, t) = staffed();
        let sid = owner.server_id.clone();
        let flooders: Vec<u8> = (40..60).collect();
        let admitted: Vec<CrdtOp> = flooders.iter().map(|&f| op_at(1, &sid, t + 10 + f as u64, add(&sid, f))).collect();
        owner.ingest_remote(&admitted);
        history.extend(admitted);
        let cp = checkpoint(&mut owner);
        let flood: Vec<CrdtOp> = flooders
            .iter()
            .flat_map(|&f| (0..20u64).map(move |k| (f, k)))
            .map(|(f, k)| op_at(f, &sid, t + 1000 + f as u64 * 100 + k, P::NicknameChanged { peer_id: id(f), nickname: "x".repeat(500) + &k.to_string() }))
            .collect();
        let live = op_at(40, &sid, t + 90_000, P::NicknameChanged { peer_id: id(40), nickname: "LIVE".to_string() + &"z".repeat(2_000) });
        let mut tail = joiner(&sid, 9);
        tail.ingest_remote(&history);
        tail.ingest_remote(std::slice::from_ref(&cp));
        tail.ingest_remote(&flood);
        tail.ingest_remote(std::slice::from_ref(&live));
        let mut whole = joiner(&sid, 8);
        whole.ingest_remote(&history);
        let mut all: Vec<CrdtOp> = flood.clone();
        all.push(live.clone());
        all.push(cp.clone());
        whole.ingest_remote(&all);
        assert_eq!(
            tail.get_nickname(&id(40)),
            whole.get_nickname(&id(40)),
            "same ops, different state at the quota bound"
        );
        assert_eq!(view(&tail), view(&whole));
    }

    /// R3-4: what the quota parks stays stored (RAM `stored`, a `crdt_ops` row) for 30 days
    /// and is never trimmed: one member sending its ops in clock order folds a sixteenth of
    /// the budget between rebuilds, and each rebuild parks the excess as rows. The parked set
    /// grows with whatever the member sends.
    #[test]
    fn rev3_a_members_in_order_flood_keeps_the_stored_rows_bounded() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let cp = checkpoint(&mut owner);
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(std::slice::from_ref(&cp));
        let mut sent = 0usize;
        for k in 0..400u64 {
            let op = op_at(4, &sid, t + 1000 + k, P::NicknameChanged { peer_id: id(4), nickname: "x".repeat(10_000) + &k.to_string() });
            sent += serde_json::to_string(&op).unwrap().len();
            r.ingest_remote(std::slice::from_ref(&op));
        }
        let stored: usize = r.stored.iter().map(|(o, _)| serde_json::to_string(o).unwrap().len()).sum();
        let folded: usize = r.op_log.iter().map(|o| serde_json::to_string(o).unwrap().len()).sum();
        assert!(stored + folded <= 2 * QUOTA_BYTES, "one member made us keep {stored} parked + {folded} folded bytes of {sent} sent (budget {QUOTA_BYTES})");
    }

    /// R3-5: design section 3.2: "An op the owner folded is always dominated" by its own
    /// checkpoint. The U10 oracle never checks it (its replicas hold the whole history, so an
    /// undominated history op folds again in order and hides a missing stamp). Lists every
    /// payload kind the owner folded that its checkpoint does not decide.
    #[test]
    fn rev3_every_op_the_owner_folded_is_decided_by_its_checkpoint() {
        let mut rng = 0x1234_5678_9abc_def1u64;
        let mut next = move |n: u64| {
            rng ^= rng << 13;
            rng ^= rng >> 7;
            rng ^= rng << 17;
            rng % n
        };
        let mut leaks: std::collections::BTreeMap<String, usize> = Default::default();
        for _case in 0..300 {
            let (mut owner, _history, t) = staffed();
            let sid = owner.server_id.clone();
            let ch = general(&owner);
            let mut ops = Vec::new();
            for i in 0..(8 + next(18)) {
                let at = t + 20 + i * 3;
                let author = [1u8, 2, 3, 4, 5][next(5) as usize];
                let target = [2u8, 3, 4, 5, 6][next(5) as usize];
                ops.push(op_at(author, &sid, at, gen_payload(&mut next, &sid, &ch, target, at)));
            }
            owner.ingest_remote(&ops);
            let folded: Vec<CrdtOp> = owner.op_log.iter().filter(|o| o.hlc.physical_ms >= t + 20).cloned().collect();
            let _cp = checkpoint(&mut owner);
            let base = owner.base.clone().unwrap();
            for o in folded {
                if !base.judge().dominates(&o, true) {
                    let mut again = owner.clone();
                    again.apply_payload(&o);
                    if view(&again) != view(&owner) {
                        *leaks.entry(payload_name(&o.payload).to_string()).or_default() += 1;
                    }
                }
            }
        }
        assert!(leaks.is_empty(), "ops the owner folded that its checkpoint leaves undecided (never pruned, folded again on top): {leaks:#?}");
    }

    /// R3-6: before the owner's first checkpoint there is no base, and the allocation returns
    /// at once: a server whose owner never checkpointed (under 2,000 ops, or the writer rule
    /// never met) folds whatever a member sends, without bound.
    #[test]
    fn rev3_a_server_without_a_checkpoint_bounds_a_flood_too() {
        let (_owner, history, t) = staffed();
        let sid = _owner.server_id.clone();
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        for k in 0..400u64 {
            let op = op_at(4, &sid, t + 1000 + k, P::NicknameChanged { peer_id: id(4), nickname: "x".repeat(10_000) + &k.to_string() });
            r.ingest_remote(std::slice::from_ref(&op));
        }
        let folded: usize = r.op_log.iter().map(|o| serde_json::to_string(o).unwrap().len()).sum();
        let stored: usize = r.stored.iter().map(|(o, _)| serde_json::to_string(o).unwrap().len()).sum();
        assert!(folded + stored <= 2 * QUOTA_BYTES, "no base, no bound: {folded} folded + {stored} stored (budget {QUOTA_BYTES})");
    }
    /// A member kicked at t+10 signs an admission of a puppet dated t+9 and hands it to any
    /// member after the kick: the fold judges it at its own point, where the kicked member
    /// still sat, and seats the puppet; the puppet then authors as a member.
    #[test]
    fn rev3_cover_a_kicked_member_backdates_an_admission() {
        let (_owner, founding) = founded(1);
        let sid = _owner.server_id.clone();
        let t = founding.hlc.physical_ms;
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&[
            founding.clone(),
            op_at(1, &sid, t + 1, add(&sid, 2)),
            op_at(1, &sid, t + 2, add(&sid, 3)),
            op_at(1, &sid, t + 10, kick(2)),
        ]);
        assert!(!r.is_member(&id(2)));
        let backdated = op_at(2, &sid, t + 9, add(&sid, 5));
        r.ingest_remote(std::slice::from_ref(&backdated));
        let puppet_writes = op_at(5, &sid, t + 20, P::NicknameChanged { peer_id: id(5), nickname: "p".into() });
        r.ingest_remote(std::slice::from_ref(&puppet_writes));
        assert!(!r.is_member(&id(5)), "a kicked member's backdated admission seated a puppet after the kick (puppet nickname {:?})", r.get_nickname(&id(5)));
    }

    /// R3-7: the shape every stamp test lacks: a replica that holds only the founding op, the
    /// base and the late ops (a joiner after the owner's checkpoint). A removal dated before a
    /// channel's creation, which the owner never saw, must not delete the channel there.
    #[test]
    fn rev3_a_late_removal_older_than_the_add_keeps_the_channel_on_a_fresh_joiner() {
        let (mut owner, founding) = founded(1);
        let sid = owner.server_id.clone();
        let t = founding.hlc.physical_ms;
        let c3 = format!("{}-c3", &sid[..8]);
        owner.ingest_remote(&[
            op_at(1, &sid, t + 1, add(&sid, 2)),
            op_at(1, &sid, t + 2, P::RoleChanged { peer_id: id(2), role: MemberRole::Admin, priority: 3 }),
            op_at(1, &sid, t + 31, P::ChannelAdded { channel_id: c3.clone(), name: "c3".into(), category: None, channel_type: "text".into() }),
        ]);
        let cp = checkpoint(&mut owner);
        let late = op_at(2, &sid, t + 21, P::ChannelRemoved { channel_id: c3.clone() });
        let mut fresh = joiner(&sid, 9);
        fresh.ingest_remote(&[founding, cp]);
        fresh.ingest_remote(std::slice::from_ref(&late));
        assert!(fresh.channels.contains_key(&c3), "a removal older than the channel's creation deleted it on a joiner after the checkpoint");
    }

    // ---- t14-cover final round (review 4) ----

    /// An admin the owner kicked sends a removal stamped now: refused at its own point, it
    /// voids nothing, whether a rebuild or the tail decides.
    #[test]
    fn review4_a_kicked_admins_refused_removal_voids_honest_grants() {
        let (_owner, history, t) = staffed();
        let sid = history[0].server_id.clone();
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(&[op_at(3, &sid, t + 10, add(&sid, 5)), op_at(1, &sid, t + 20, kick(2))]);
        assert!(r.is_member(&id(5)) && !r.is_member(&id(2)) && r.is_member(&id(3)));
        r.ingest_remote(&[op_at(2, &sid, t + 30, kick(3))]);
        assert!(r.is_member(&id(3)), "the ex-admin's kick is refused");
        assert!(r.is_member(&id(5)), "before any rebuild");
        assert!(!r.op_log.iter().chain(r.stored.iter().map(|(o, _)| o)).any(|o| o.author == id(2)), "control: 2 has no kept op");
        assert!(r.held.iter().any(|(o, _)| o.author == id(2)), "control: the refused kick waits in held");
        assert!(r.has_op_author(&id(2)), "the author of a held op is outside the authority set");
        r.ingest_remote(&[op_at(1, &sid, t + 15, P::ServerRenamed { new_name: "any late op".into() })]);
        assert!(r.is_member(&id(3)), "the ex-admin's kick is still refused");
        assert!(r.is_member(&id(5)), "a refused removal by a kicked admin voided 3's honest admission of 5");
    }

    /// The same with a demotion instead of a kick.
    #[test]
    fn review4_a_demoted_admins_refused_removal_voids_honest_grants() {
        let (_owner, history, t) = staffed();
        let sid = history[0].server_id.clone();
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(&[
            op_at(4, &sid, t + 10, add(&sid, 5)),
            op_at(1, &sid, t + 20, P::RoleChanged { peer_id: id(3), role: MemberRole::Member, priority: 3 }),
        ]);
        r.ingest_remote(&[op_at(3, &sid, t + 30, kick(4))]);
        r.ingest_remote(&[op_at(1, &sid, t + 15, P::ServerRenamed { new_name: "any late op".into() })]);
        assert!(r.is_member(&id(4)), "the demoted moderator's kick is refused");
        assert!(r.is_member(&id(5)), "a refused removal by a demoted moderator voided 4's honest admission of 5");
    }

    /// The tail and a rebuild of the same set agree when a removal is refused at its own
    /// point, and when an honest one voids (control): a held refused kick changes nothing.
    #[test]
    fn a_refused_removal_leaves_the_tail_and_a_rebuild_equal() {
        let (_owner, history, t) = staffed();
        let sid = history[0].server_id.clone();
        let refused = vec![
            op_at(3, &sid, t + 10, add(&sid, 5)),
            op_at(1, &sid, t + 20, kick(2)),
            op_at(2, &sid, t + 30, kick(3)),
            op_at(1, &sid, t + 40, P::ServerRenamed { new_name: "after".into() }),
        ];
        let honest = vec![op_at(3, &sid, t + 10, add(&sid, 5)), op_at(2, &sid, t + 30, kick(3))];
        for (case, late, voided) in [("refused", refused, false), ("honest", honest, true)] {
            let mut tail = joiner(&sid, 9);
            tail.ingest_remote(&history);
            for op in &late {
                tail.ingest_remote(std::slice::from_ref(op));
            }
            let mut batch = joiner(&sid, 9);
            batch.ingest_remote(&history);
            let mut shuffled = late.clone();
            shuffled.reverse();
            batch.ingest_remote(&shuffled);
            let mut rebuilt = tail.clone();
            rebuilt.fold_all(Vec::new(), Ingested::default());
            assert_eq!(tail.is_member(&id(5)), !voided, "{case}: the tail");
            assert_eq!(view(&tail), view(&rebuilt), "{case}: a rebuild of the tail's own set differs");
            assert_eq!(view(&tail), view(&batch), "{case}: one batch of the same set differs");
            assert_eq!(keys_of(&tail), keys_of(&rebuilt), "{case}: the folded log differs");
        }
    }

    /// A removal folded first and refused only once a late kick of its author arrives is
    /// a parked row, not a held op: it voids nothing either.
    #[test]
    fn a_removal_parked_by_a_late_kick_of_its_author_voids_nothing() {
        let (_owner, history, t) = staffed();
        let sid = history[0].server_id.clone();
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(&[op_at(3, &sid, t + 10, add(&sid, 5)), op_at(2, &sid, t + 30, kick(3))]);
        assert!(!r.is_member(&id(3)) && !r.is_member(&id(5)), "control: the admin's kick folds and voids what it did not see");
        r.ingest_remote(&[op_at(1, &sid, t + 20, kick(2))]);
        assert!(r.stored.iter().any(|(o, k)| o.author == id(2) && matches!(k, RowKind::Parked(_))), "the refused kick is a parked row");
        assert!(r.is_member(&id(3)), "the kicked admin's kick is refused");
        assert!(r.is_member(&id(5)), "a parked removal voided 3's honest admission of 5");
        assert!(!r.op_log.iter().any(|o| o.author == id(2)), "control: 2 has no folded op");
        assert!(r.has_op_author(&id(2)), "the author of a parked op is outside the authority set");
    }

    /// A state whose checkpoint would pass its byte bound is measured before it is
    /// signed: no op, no clock tick, and no new try until the retry time.
    #[test]
    fn an_over_bound_checkpoint_is_tried_once_then_waits() {
        let (mut owner, _history, _t) = staffed();
        checkpoint(&mut owner);
        Arc::make_mut(&mut owner.base.as_mut().unwrap().state).cp_stamped = false;
        let now = crate::crdt::hlc::wall_clock_ms();
        assert!(owner.checkpoint_due(&id(1), now), "control: a base from before 0.14 is due a child");
        let name = owner.name.clone();
        let mut later = now;
        // Plain bytes past the bound, and quotes that pass it only once escaped twice.
        for big in ["n".repeat(MAX_CHECKPOINT_BYTES), "\"".repeat(MAX_CHECKPOINT_BYTES / 3)] {
            owner.name = crate::crdt::admin_lww::AdminLwwReg::new(big, name.hlc().clone(), 4);
            let (log, clock) = (owner.op_log.len(), owner.hlc.as_ref().unwrap().latest().clone());
            assert!(owner.author_due_checkpoint(&id(1), &[], later).is_none(), "an over-bound checkpoint was kept");
            assert_eq!(owner.op_log.len(), log);
            assert_eq!(owner.hlc.as_ref().unwrap().latest(), &clock, "an over-bound checkpoint was signed");
            assert!(!owner.checkpoint_due(&id(1), later + 2_000), "an over-bound checkpoint is tried again at the next tick");
            later += CHECKPOINT_MIN_GAP_MS + 1;
            assert!(owner.checkpoint_due(&id(1), later), "the try comes back after the gap");
        }
        owner.name = name;
        assert!(owner.author_due_checkpoint(&id(1), &[], later).is_some(), "control: a state within the bound checkpoints");
        assert!(!owner.checkpoint_due(&id(1), later), "control: nothing more is due");
    }

    fn retire_at(tag: u8, sid: &str, ms: u64) -> CrdtOp {
        op_at(tag, sid, ms, P::DeviceRetired { device: format!("dev-{tag}"), ops: Vec::new(), posts_until_ms: None, restore: None })
    }

    /// Section 14: a member's retire ranks first in its quota group, so its own flood
    /// never pushes it over its share.
    #[test]
    fn a_retire_ranks_first_in_its_authors_quota_group() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let cp = checkpoint(&mut owner);
        let flood: Vec<CrdtOp> = (0..600u64)
            .map(|k| op_at(4, &sid, t + 1_000 + k, P::NicknameChanged { peer_id: id(4), nickname: "x".repeat(400) + &k.to_string() }))
            .collect();
        let dr = retire_at(4, &sid, t + 5_000);
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(std::slice::from_ref(&cp));
        r.ingest_remote(&flood);
        assert!(!r.op_log.iter().any(|o| o.hlc == flood[599].hlc), "precondition: the flood is over its share");
        r.ingest_remote(std::slice::from_ref(&dr));
        assert!(r.op_log.iter().any(|o| o.hlc == dr.hlc && o.author == dr.author), "the retire folds within the share");
    }

    #[test]
    fn an_author_keeps_at_most_its_newest_undominated_retires() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let cp = checkpoint(&mut owner);
        let retires: Vec<CrdtOp> = (0..MAX_UNDOMINATED_RETIRES as u64 + 6).map(|k| retire_at(4, &sid, t + 1_000 + k)).collect();
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(std::slice::from_ref(&cp));
        r.ingest_remote(&retires);
        let held = |o: &CrdtOp| r.op_log.iter().chain(r.stored.iter().map(|(x, _)| x)).chain(r.held.iter().map(|(x, _)| x)).any(|x| x.hlc == o.hlc && x.author == o.author);
        assert_eq!(retires.iter().filter(|o| held(o)).count(), MAX_UNDOMINATED_RETIRES, "bounded per author");
        assert!(retires[6..].iter().all(&held) && !retires[..6].iter().any(&held), "the oldest go");
    }

    /// Section 14: retires one author floods in, one ingest each, rebuild at most
    /// `RETIRE_REBUILDS_PER_AUTHOR` times a window; the rest wait for the coalesced
    /// rebuild, which places them, and another author keeps its own budget.
    #[test]
    fn a_flood_of_retires_from_one_author_rebuilds_a_bounded_number_of_times() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let cp = checkpoint(&mut owner);
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&history);
        r.ingest_remote(std::slice::from_ref(&cp));
        let flood: Vec<CrdtOp> = (0..40u64).map(|k| retire_at(4, &sid, t + 1_000 + k)).collect();
        let rebuilt = flood.iter().filter(|o| r.ingest_remote(std::slice::from_ref(*o)).rebuilt).count();
        assert_eq!(rebuilt, RETIRE_REBUILDS_PER_AUTHOR as usize, "one author's flood rebuilds a bounded number of times");
        assert!(r.retire_rebuild_due(), "the rest wait for the coalesced rebuild");
        let folded = |r: &ServerState, o: &CrdtOp| r.op_log.iter().any(|x| x.hlc == o.hlc && x.author == o.author);
        assert!(!folded(&r, &flood[39]), "precondition: a held retire is not folded yet");
        assert!(r.rebuild_now().rebuilt);
        assert!(!r.retire_rebuild_due(), "the rebuild clears the wait");
        assert!(flood.iter().all(|o| folded(&r, o)), "the coalesced rebuild places every held retire");
        let other = retire_at(3, &sid, t + 2_000);
        assert!(r.ingest_remote(std::slice::from_ref(&other)).rebuilt, "another author's retire rebuilds on its own budget");
        assert!(folded(&r, &other));
    }

    #[test]
    fn restore_points_are_the_newest_and_oldest_first_fold_of_each_window() {
        let now = 100 * DAY_MS;
        let ago = |d: f64| now - (d * DAY_MS as f64) as u64;
        let held = [(0, ago(0.1)), (1, ago(0.5)), (2, ago(0.9)), (3, ago(2.0)), (4, ago(8.0)), (5, ago(20.0)), (6, ago(29.0)), (7, ago(40.0)), (8, 0), (9, ago(60.0))];
        assert_eq!(restore_picks(&held, now), vec![0, 2, 3, 4, 6, 7, 8], "per window its newest and oldest, at most 8");
        assert!(restore_picks(&[], now).is_empty());
    }

    /// Section 7: a checkpoint this replica once folded as its base stays as a restore
    /// point after the base moves past it, is never served or compared, and comes back
    /// on a restart from the first-fold records; one never folded here is dropped.
    #[test]
    fn a_base_the_replica_moved_past_stays_as_a_restore_point_it_never_serves() {
        let (mut owner, history, t) = staffed();
        let sid = owner.server_id.clone();
        let mut cps = Vec::new();
        for k in 0..4u64 {
            owner.ingest_remote(&[op_at(2, &sid, t + 100 + k, P::ServerRenamed { new_name: format!("n{k}") })]);
            cps.push(checkpoint(&mut owner));
        }
        let kind = |s: &ServerState, cp: &CrdtOp| s.stored.iter().find(|(o, _)| o.hlc == cp.hlc).map(|(_, k)| *k);
        assert_eq!(kind(&owner, &cps[2]), Some(RowKind::Parent));
        assert_eq!(kind(&owner, &cps[0]), Some(RowKind::CutMark), "the lowest stays as the cut's mark");
        assert_eq!(kind(&owner, &cps[1]), Some(RowKind::Restore), "an earlier base is a restore point");
        assert!(!owner.served_log().iter().any(|o| o.hlc == cps[1].hlc), "never on a page");
        let kept: Vec<crate::crdt::digest::KeptRef<'_>> = Vec::new();
        assert!(
            !crate::crdt::digest::entries(&owner, &kept, None).iter().any(|e| matches!(e.item, crate::crdt::digest::Item::Op(o) if o.hlc == cps[1].hlc)),
            "never in the digest",
        );

        let rows: Vec<(CrdtOp, Option<u64>)> =
            owner.op_log.iter().map(|o| (o.clone(), None)).chain(owner.stored.iter().map(|(o, k)| (o.clone(), k.parked_until()))).collect();
        let mut restarted = joiner(&sid, 1);
        restarted.first_folds = owner.first_folds.clone();
        restarted.restore_op_log(rows.clone());
        assert_eq!(kind(&restarted, &cps[1]), Some(RowKind::Restore), "a restart keeps it from the first-fold records");
        let mut forgot = joiner(&sid, 1);
        forgot.restore_op_log(rows);
        assert_eq!(kind(&forgot, &cps[1]), None, "a checkpoint never folded here as the base is dropped");
        let _ = history;
    }

    /// Section 14: first-fold records rotate with what they date, the base's lineage and
    /// the restore points; a rebuild's delta names what stays.
    #[test]
    fn a_rebuild_keeps_first_folds_only_for_the_lineage_and_the_restore_points() {
        let (mut owner, _history, t) = staffed();
        let sid = owner.server_id.clone();
        let mut cps = Vec::new();
        for k in 0..4u64 {
            owner.ingest_remote(&[op_at(2, &sid, t + 100 + k, P::ServerRenamed { new_name: format!("n{k}") })]);
            cps.push(checkpoint(&mut owner));
        }
        let stray = "f".repeat(64);
        Arc::make_mut(&mut owner.first_folds).insert(stray.clone(), 1);
        let out = owner.rebuild_now();
        assert!(!owner.first_folds.contains_key(&stray), "a checkpoint off the lineage and no restore point loses its record");
        for cp in &cps {
            assert!(owner.first_folds.contains_key(&hex::encode(cp.content_hash())), "the lineage keeps its records");
        }
        let mut kept = out.delta(&sid).and_then(|d| d.seen_keep).expect("the rebuild names what stays");
        kept.sort();
        let mut held: Vec<String> = owner.first_folds.keys().cloned().collect();
        held.sort();
        assert_eq!(kept, held);
    }

    /// Section 7 (N6, decision 2): an author keeps its own dominated ops as `Own` rows,
    /// never folded or served, while the checkpoint that first dominated them was first
    /// folded here under 30 days ago; another author's go.
    #[test]
    fn an_author_keeps_its_own_dominated_ops_for_thirty_days() {
        let run = |first_fold_ago: u64| {
            let (mut owner, history, t) = staffed();
            let sid = owner.server_id.clone();
            let theirs = op_at(2, &sid, t + 50, P::NicknameChanged { peer_id: id(2), nickname: "two".into() });
            owner.ingest_remote(std::slice::from_ref(&theirs));
            let first = checkpoint(&mut owner);
            Arc::make_mut(&mut owner.first_folds).insert(hex::encode(first.content_hash()), crate::crdt::hlc::wall_clock_ms() - first_fold_ago);
            let covers = owner.checkpoint_covers();
            let json = owner.checkpoint_json(&id(1), &[], crate::crdt::hlc::wall_clock_ms()).unwrap();
            let (_, ingested) = owner.author_checkpoint(P::ServerCheckpoint { state: json, covers }).expect("the second checkpoint");
            (owner, history[1].clone(), theirs, ingested)
        };
        let kind = |s: &ServerState, o: &CrdtOp| s.stored.iter().find(|(r, _)| r.hlc == o.hlc && r.author == o.author).map(|(_, k)| *k);
        let key = |o: &CrdtOp| (o.author.clone(), o.hlc.physical_ms, o.hlc.counter);

        let (mut owner, mine, theirs, ingested) = run(10 * DAY_MS);
        let sid = owner.server_id.clone();
        assert_eq!(kind(&owner, &mine), Some(RowKind::Own), "our own op stays once two checkpoints decide it");
        assert_eq!(kind(&owner, &theirs), None, "a member's goes");
        assert!(!owner.served_log().iter().any(|o| o.hlc == mine.hlc), "never served");
        let dated = ingested.delta(&sid).map(|d| d.own_since).unwrap_or_default();
        let since = dated.iter().find(|(k, _)| *k == key(&mine)).and_then(|(_, v)| *v).expect("the store learns its first domination");
        assert!(crate::crdt::hlc::wall_clock_ms() - since >= 10 * DAY_MS - 1_000, "dated by the checkpoint that first decided it");
        let old = crate::crdt::hlc::wall_clock_ms() - 31 * DAY_MS;
        for v in Arc::make_mut(&mut owner.own_since).values_mut() {
            *v = old;
        }
        let out = owner.rebuild_now();
        assert_eq!(kind(&owner, &mine), None, "thirty days after, it goes");
        assert!(out.dropped.iter().any(|(a, h)| *a == mine.author && *h == mine.hlc), "and its row is deleted");
        assert!(out.own_since.iter().any(|(k, v)| *k == key(&mine) && v.is_none()), "with its date");

        let (owner, mine, ..) = run(31 * DAY_MS);
        assert_eq!(kind(&owner, &mine), None, "decided by a checkpoint first folded over 30 days ago: gone at once");
    }

    /// Section 14: past 16,384 own rows or 64 MiB, those first dominated longest ago go.
    #[test]
    fn own_rows_over_the_bound_go_oldest_domination_first() {
        let rows = [(30u64, 10usize), (10, 10), (20, 10), (40, 10)];
        assert_eq!(own_over_bound(&rows, 3, 1_000), vec![1], "over the count, the oldest");
        assert_eq!(own_over_bound(&rows, 10, 25), vec![1, 2], "over the bytes, oldest first until it fits");
        assert!(own_over_bound(&rows, 4, 40).is_empty());
    }

    /// Section 14: a restore point off the base's lineage (a base folded more than
    /// `LINEAGE` generations back) keeps its first-fold record, so it stays one.
    #[test]
    fn a_restore_point_off_the_lineage_keeps_its_first_fold() {
        let (mut owner, _history, _) = staffed();
        checkpoint(&mut owner);
        let oldest = checkpoint(&mut owner);
        for _ in 0..LINEAGE + 4 {
            checkpoint(&mut owner);
        }
        let id = hex::encode(oldest.content_hash());
        assert!(!owner.base.as_ref().unwrap().state.cp_lineage.contains(&id), "precondition: off the lineage");
        owner.rebuild_now();
        let kind = owner.stored.iter().find(|(o, _)| o.hlc == oldest.hlc).map(|(_, k)| *k);
        assert_eq!(kind, Some(RowKind::Restore), "the oldest base of its window past the cut's mark stays a restore point");
        assert!(owner.first_folds.contains_key(&id), "with its first fold");
    }

    /// Section 7: the store dates a base's first fold from the rebuild that chose it.
    #[test]
    fn a_rebuild_names_its_base_for_the_first_fold_record() {
        let (mut owner, history, _) = staffed();
        let cp = checkpoint(&mut owner);
        let mut r = joiner(&owner.server_id, 9);
        r.ingest_remote(&history);
        let out = r.ingest_remote(std::slice::from_ref(&cp));
        assert!(out.rebuilt);
        assert_eq!(out.delta(&owner.server_id).and_then(|d| d.base), Some(hex::encode(cp.content_hash())), "the delta names the base");
    }

    /// REVIEW HOL-SEC-211: a 0.14.1 owner device folds an admin's `home_relay` (MANAGE_SERVER
    /// there) and its checkpoint carries it; a 0.14.2 replica must not take a home the owner
    /// never named.
    #[test]
    fn review_a_0141_owner_checkpoint_carries_no_admin_home_relay() {
        use crate::crdt::server_state::HOME_RELAY_KEY;
        let (mut owner, founding) = founded(1);
        let sid = owner.server_id.clone();
        let t = founding.hlc.physical_ms;
        let base = vec![
            op_at(1, &sid, t + 1, add(&sid, 2)),
            op_at(1, &sid, t + 2, P::RoleChanged { peer_id: id(2), role: MemberRole::Admin, priority: 2 }),
        ];
        owner.ingest_remote(&base);
        assert_eq!(owner.get_role(&id(2)), MemberRole::Admin, "precondition: 2 is an admin");
        let evil = op_at(2, &sid, t + 3, P::ServerSettingChanged { key: HOME_RELAY_KEY.into(), value: "evil.example".into() });
        // 0.14.2 refuses it live.
        assert!(!owner.op_allowed(&evil), "precondition: 0.14.2 refuses the admin's op");
        // What a 0.14.1 owner's fold does with it: an ordinary MANAGE_SERVER setting.
        let prio = MemberRole::Admin.priority();
        owner.settings.insert(HOME_RELAY_KEY.into(), crate::crdt::admin_lww::AdminLwwReg::new("evil.example".into(), evil.hlc.clone(), prio));
        let cp = checkpoint(&mut owner);
        let mut r = joiner(&sid, 9);
        r.ingest_remote(&[founding.clone(), cp.clone()]);
        r.ingest_remote(std::slice::from_ref(&evil));
        assert_eq!(r.home_relay(), None, "a 0.14.2 replica took the admin's home relay from a 0.14.1 owner's checkpoint");
    }
}
