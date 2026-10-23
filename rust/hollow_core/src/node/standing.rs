//! Who leads a server's MLS groups while the owner is away (design g13w2-f, "standing").
//!
//! Candidates rank by role tier, then by the position of their current membership in
//! the signed fold, then by id, so a master id anyone can grind buys no precedence. A
//! 0.12.2 replica still picks the lowest id, so standing applies only where every leaf
//! of the tree declares the tally capability (the gate) and a ratchet keeps it so.
//! Remove the gate, the old rule and the walk's old-rule last resort in 0.14.

use std::cmp::Reverse;
use std::collections::{BinaryHeap, HashMap, HashSet};
use std::time::{Duration, Instant};

use crate::crdt::hlc::HlcTimestamp;
use crate::crdt::operations::MemberRole;
use crate::crdt::server_state::{Anchor, ServerState};
use crate::crypto::mls_tally::LeafRecord;
use crate::crypto::MlsManager;

type Peers = HashMap<String, HashSet<String>>;

/// Where a current membership sits in the fold; `Max` sorts after every clock.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum Pos {
    At(HlcTimestamp),
    Max,
}

/// Every current member's position: the least fixed point of
/// `pos(M) = min over M's admitters a of max(hlc_a, pos(a))`, where an admitter that is
/// no longer a member reads `Max` and a span nobody is recorded admitting reads its own
/// opening clock. Settled in increasing order, so it depends on the ops alone and never
/// on map order, and nobody ever ranks before whoever admitted them.
pub(crate) fn positions(state: &ServerState) -> HashMap<String, Pos> {
    let mut pos: HashMap<String, Pos> = HashMap::new();
    let mut by_author: HashMap<&str, Vec<(&str, &HlcTimestamp)>> = HashMap::new();
    let mut heap: BinaryHeap<Reverse<(Pos, String)>> = BinaryHeap::new();
    for member in state.members.keys() {
        let open = state.member_record.get(member).and_then(|spans| spans.last()).filter(|s| s.until_ms == u64::MAX);
        let seed = match open {
            Some(span) if span.admitted.is_empty() => Pos::At(opened_at(state, member)),
            _ => Pos::Max,
        };
        for (author, hlc) in open.map(|s| s.admitted.as_slice()).unwrap_or_default() {
            if state.members.contains_key(author) {
                by_author.entry(author.as_str()).or_default().push((member.as_str(), hlc));
            }
        }
        if seed != Pos::Max {
            heap.push(Reverse((seed.clone(), member.clone())));
        }
        pos.insert(member.clone(), seed);
    }
    let mut settled: HashSet<String> = HashSet::new();
    while let Some(Reverse((at, member))) = heap.pop() {
        if !settled.insert(member.clone()) || pos.get(&member) != Some(&at) {
            continue;
        }
        let Pos::At(at_hlc) = &at else { break };
        for (admittee, hlc) in by_author.get(member.as_str()).into_iter().flatten() {
            let candidate = Pos::At((*hlc).max(at_hlc).clone());
            if pos.get(*admittee).is_some_and(|p| candidate < *p) {
                pos.insert(admittee.to_string(), candidate.clone());
                heap.push(Reverse((candidate, admittee.to_string())));
            }
        }
    }
    pos
}

/// The clock that opened `member`'s current span: its full HLC, else (for spans
/// written before 0.13) its physical time alone; the latest possible without one.
fn opened_at(state: &ServerState, member: &str) -> HlcTimestamp {
    let open = state.member_record.get(member).and_then(|spans| spans.last()).filter(|s| s.until_ms == u64::MAX);
    match open {
        Some(span) => span.from_hlc.clone().unwrap_or(HlcTimestamp { physical_ms: span.from_ms, counter: 0, actor: String::new() }),
        None => HlcTimestamp { physical_ms: u64::MAX, counter: u32::MAX, actor: String::new() },
    }
}

fn tier(state: &ServerState, master: &str) -> u8 {
    match state.get_role(master) {
        MemberRole::Owner => 0,
        MemberRole::Admin => 1,
        MemberRole::Moderator => 2,
        _ => 3,
    }
}

/// `masters` ordered by standing, first = leads: role tier, position, the member's own
/// opening clock, then the id.
pub(crate) fn rank_masters(state: &ServerState, masters: impl IntoIterator<Item = String>) -> Vec<String> {
    let pos = positions(state);
    let mut keyed: Vec<((u8, Pos, HlcTimestamp), String)> = masters
        .into_iter()
        .map(|m| {
            let p = pos.get(&m).cloned().unwrap_or(Pos::Max);
            ((tier(state, &m), p, opened_at(state, &m)), m)
        })
        .collect();
    keyed.sort();
    keyed.dedup_by(|a, b| a.1 == b.1);
    keyed.into_iter().map(|(_, m)| m).collect()
}

/// The first of `masters` by standing.
pub(crate) fn first_by_standing(state: &ServerState, masters: impl IntoIterator<Item = String>) -> Option<String> {
    rank_masters(state, masters).into_iter().next()
}

/// How a replica picks who leads one group.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) enum Rule {
    /// The gate is off: the 0.12.2 rule, byte for byte.
    #[default]
    Old,
    /// The gate is on. Candidates are the masters with an online device holding a bound
    /// leaf in our tree of the group (by device, master), or the CRDT's qualifiers
    /// (`None`) when founding a subgroup nobody holds.
    Standing(Option<HashMap<String, String>>),
    /// A Legacy view of a tree that would be on: elects by the old rule but never acts.
    Abstain,
}

impl Rule {
    pub(crate) fn on(&self) -> bool {
        matches!(self, Rule::Standing(_))
    }

    /// Whether this replica may act as leader (commit, serve catch-ups, ask for leaves).
    pub(crate) fn may_lead(&self) -> bool {
        !matches!(self, Rule::Abstain)
    }

    /// Whether `master` may stand for election: under standing, one of its online
    /// devices (or we ourselves) holds a bound leaf in our tree, when we hold one. An
    /// owner whose only online device is leafless answers nothing for the group.
    pub(crate) fn admits(&self, master: &str, local_master: &str, peers: &Peers) -> bool {
        match self {
            Rule::Standing(Some(leaves)) => leaves.iter().any(|(device, m)| {
                m == master && (master == local_master || peers.values().any(|room| room.contains(device)))
            }),
            _ => true,
        }
    }
}

/// Every leaf bound and declaring the tally capability. `declares`, never `capable`, so
/// a later tally layout cannot flip the gate on older 0.13 replicas.
pub(crate) fn tree_declares(records: &[LeafRecord]) -> bool {
    !records.is_empty() && records.iter().all(|r| r.identity.is_some() && r.declares)
}

fn holders(records: &[LeafRecord]) -> HashMap<String, String> {
    records.iter().filter_map(|r| r.identity.as_ref().map(|i| (i.device.clone(), i.master.clone()))).collect()
}

/// The rule for `group_key` (the server group or a restricted channel's subgroup).
pub(crate) fn rule(mls: &MlsManager, state: &ServerState, group_key: &str) -> Rule {
    let (server_id, channel) = crate::crypto::split_group_key(group_key);
    let subgroup = channel.map(|_| mls.has_group(group_key).then(|| mls.leaf_records(group_key)));
    rule_from(&mls.leaf_records(&server_id), state.anchor() == Anchor::Legacy, subgroup.as_ref().map(Option::as_deref))
}

/// The gate matrix over our trees: the server group's records (empty when we hold no
/// copy), whether our anchor is Legacy, and for a subgroup key its records when we hold it.
fn rule_from(server_records: &[LeafRecord], legacy: bool, subgroup: Option<Option<&[LeafRecord]>>) -> Rule {
    let server = if !tree_declares(server_records) {
        Rule::Old
    } else if legacy {
        Rule::Abstain
    } else {
        Rule::Standing(Some(holders(server_records)))
    };
    match subgroup {
        Some(_) if !server.on() => server,
        None => server,
        Some(None) => Rule::Standing(None),
        Some(Some(records)) if tree_declares(records) => Rule::Standing(Some(holders(records))),
        Some(Some(_)) => Rule::Old,
    }
}

/// How long a leafless asker waits on a target that neither acked nor seated it.
pub(crate) const WALK_STEP: Duration = Duration::from_secs(6);
/// A required probe unanswered this long counts as silence.
pub(crate) const SILENCE_AFTER: Duration = Duration::from_secs(15);
/// How long a silent responder is skipped, and the window holding at most one skip.
pub(crate) const SKIP_FOR: Duration = Duration::from_secs(600);
/// A silence clock starts only on a probe at least this long after the previous one
/// to the same responder: the answerer's own hint cooldown may drop closer ones.
pub(crate) const PROBE_SPACING: Duration = Duration::from_secs(20);

/// How long a repair request we answered, and the committer its forward names, count:
/// our window for the repair's Welcome (`mls_authority::ASKED_WINDOW`).
const REPAIR_ASK_FOR: Duration = Duration::from_secs(120);

/// What a KeyPackage's receiver did with it (`HavenMessage::MlsKeyPackageAck`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub(crate) enum KpOutcome {
    /// Queued for its own commit.
    Commit,
    /// Passed on to the coordinator its gate names.
    Forwarded,
    /// Holds no group and will not found one, or refuses the package.
    #[default]
    Cannot,
}

/// Whether `via`, the committer a forward of our repair package names, may seat us: the
/// anchored owner, or a current unbanned member holding a bound leaf in our tree. Never
/// required to be the forwarder's coordinator, whose view of who is online is its own.
pub(crate) fn may_commit_named_repair(state: &ServerState, bound_masters: &[String], via: &str) -> bool {
    state.anchor_owner().as_deref() == Some(via)
        || (state.members.contains_key(via) && !state.is_banned(via) && bound_masters.iter().any(|m| m == via))
}

/// The id an ack names a package by: hex of the first 16 bytes of its SHA-256.
pub(crate) fn package_tag(key_package: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    hex::encode(&Sha256::digest(key_package)[..16])
}

/// One leafless ask in flight for a group.
#[derive(Clone, Debug)]
struct Walk {
    /// Masters asked in this pass, in order.
    asked: Vec<String>,
    /// The package this pass sends to every target, so a slow committer and a later
    /// forward of the same bytes never seat us twice.
    package: Vec<u8>,
    /// The devices of the current target and when they were asked.
    devices: Vec<String>,
    sent: Instant,
    ack: Option<KpOutcome>,
}

#[derive(Default)]
struct Inner {
    walks: HashMap<String, Walk>,
    /// (group, responder master) -> when our last required probe to it went out.
    probed: HashMap<(String, String), Instant>,
    /// (group, responder master) -> a required probe whose answer is still due.
    clocks: HashMap<(String, String), Instant>,
    /// group -> (skipped master, when).
    skips: HashMap<String, (String, Instant)>,
    /// group -> (the master whose repair request we answered, our package's tag, when).
    answers: HashMap<String, (String, String, Instant)>,
    /// group -> (the master whose repair request we answered, the master it forwarded
    /// our package to, when).
    delegates: HashMap<String, (String, String, Instant)>,
}

/// RAM-only bookkeeping of the leaders a device talks to: leafless walks and silent
/// catch-up responders. Never persisted; a restart starts both afresh.
#[derive(Default)]
pub(crate) struct LeadBook {
    inner: std::sync::Mutex<Inner>,
}

impl LeadBook {
    fn with<R>(&self, f: impl FnOnce(&mut Inner) -> R) -> R {
        let mut g = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        f(&mut g)
    }

    /// The walk's package for `group_key`, if a pass is under way. None once a target
    /// said it commits it: asked again, that commit's Welcome never came, and the same
    /// bytes would only read as already seated.
    pub(crate) fn walk_package(&self, group_key: &str) -> Option<Vec<u8>> {
        self.with(|i| i.walks.get(group_key).filter(|w| w.ack != Some(KpOutcome::Commit)).map(|w| w.package.clone()))
    }

    /// Masters already asked in this pass.
    pub(crate) fn walk_asked(&self, group_key: &str) -> Vec<String> {
        self.with(|i| i.walks.get(group_key).map(|w| w.asked.clone()).unwrap_or_default())
    }

    /// The master asked last in this pass.
    pub(crate) fn walk_target(&self, group_key: &str) -> Option<String> {
        self.with(|i| i.walks.get(group_key).and_then(|w| w.asked.last().cloned()))
    }

    /// Record an ask of `target` (its `devices`) with `package`; a full pass restarts.
    pub(crate) fn note_walk_ask(&self, group_key: &str, target: &str, devices: Vec<String>, package: Vec<u8>, restart: bool) {
        self.with(|i| {
            let walk = i.walks.entry(group_key.to_string()).or_insert_with(|| Walk {
                asked: Vec::new(),
                package: package.clone(),
                devices: Vec::new(),
                sent: Instant::now(),
                ack: None,
            });
            if restart {
                walk.asked.clear();
            }
            walk.package = package;
            walk.asked.push(target.to_string());
            walk.devices = devices;
            walk.sent = Instant::now();
            walk.ack = None;
        })
    }

    /// An ack from `device` for `tag`: counts only from a device we asked, for the
    /// package we sent it.
    pub(crate) fn note_ack(&self, group_key: &str, device: &str, tag: &str, outcome: KpOutcome) -> bool {
        self.with(|i| {
            let Some(walk) = i.walks.get_mut(group_key) else { return false };
            if !walk.devices.iter().any(|d| d == device) || package_tag(&walk.package) != tag {
                return false;
            }
            // One device's Cannot never outweighs a sibling that took it.
            if walk.ack.is_none() || outcome != KpOutcome::Cannot {
                walk.ack = Some(outcome);
            }
            true
        })
    }

    /// Whether the walk should step on now: the target said it cannot, or nothing came
    /// back within [`WALK_STEP`]. An ack that it commits or forwards waits for the
    /// ordinary re-ask.
    pub(crate) fn walk_step_due(&self, group_key: &str) -> bool {
        self.with(|i| {
            i.walks.get(group_key).is_some_and(|w| match w.ack {
                Some(KpOutcome::Cannot) => true,
                Some(_) => false,
                None => w.sent.elapsed() >= WALK_STEP,
            })
        })
    }

    /// We answered `master`'s repair request in `group_key` with `key_package`.
    pub(crate) fn note_repair_answer(&self, group_key: &str, master: &str, key_package: &[u8]) {
        self.with(|i| {
            i.answers.insert(group_key.to_string(), (master.to_string(), package_tag(key_package), Instant::now()));
        })
    }

    /// `acker` says it forwarded the package tagged `package` to `via`: counted only from
    /// a device of the master we answered, for the package we answered it with, and only
    /// when `via` may commit a repair ([`may_commit_named_repair`]).
    pub(crate) fn note_repair_delegate(
        &self,
        group_key: &str,
        acker: &str,
        package: &str,
        via: &str,
        state: &ServerState,
        bound_masters: &[String],
    ) -> bool {
        if !may_commit_named_repair(state, bound_masters, via) {
            return false;
        }
        self.with(|i| {
            let Some((answered, tag, at)) = i.answers.get(group_key).cloned() else { return false };
            if at.elapsed() >= REPAIR_ASK_FOR || tag != package || !super::resolver::same_identity(acker, &answered) {
                return false;
            }
            i.delegates.insert(group_key.to_string(), (answered, via.to_string(), Instant::now()));
            true
        })
    }

    /// The master `requester` lately named as committing the repair we answered it with.
    pub(crate) fn repair_delegate(&self, group_key: &str, requester: &str) -> Option<String> {
        self.with(|i| {
            i.delegates
                .get(group_key)
                .filter(|(r, _, at)| r == requester && at.elapsed() < REPAIR_ASK_FOR)
                .map(|(_, via, _)| via.clone())
        })
    }

    /// We hold a leaf now: the walk is over.
    pub(crate) fn end_walk(&self, group_key: &str) {
        self.with(|i| {
            i.walks.remove(group_key);
        })
    }

    /// A required probe to `responder` went out; starts a silence clock only when the
    /// last one to it was at least [`PROBE_SPACING`] ago and `clocked` (the gate is on).
    pub(crate) fn note_probe(&self, group_key: &str, responder: &str, clocked: bool) {
        self.note_probe_at(group_key, responder, clocked, Instant::now());
    }

    pub(crate) fn note_probe_at(&self, group_key: &str, responder: &str, clocked: bool, now: Instant) {
        self.with(|i| {
            let key = (group_key.to_string(), responder.to_string());
            let spaced = i.probed.get(&key).is_none_or(|t| now.saturating_duration_since(*t) >= PROBE_SPACING);
            i.probed.insert(key.clone(), now);
            if clocked && spaced {
                i.clocks.entry(key).or_insert(now);
            }
        })
    }

    /// Anything for the group from `master`: its clock stops and a skip of it ends.
    pub(crate) fn heard(&self, group_key: &str, master: &str) {
        self.with(|i| {
            i.clocks.remove(&(group_key.to_string(), master.to_string()));
            if i.skips.get(group_key).is_some_and(|(m, _)| m == master) {
                i.skips.remove(group_key);
            }
        })
    }

    /// The responders our elections leave out for `group_key` right now: at most one,
    /// skipped once its clock ran past [`SILENCE_AFTER`], for [`SKIP_FOR`].
    pub(crate) fn skipped(&self, group_key: &str) -> HashSet<String> {
        self.skipped_at(group_key, Instant::now())
    }

    pub(crate) fn skipped_at(&self, group_key: &str, now: Instant) -> HashSet<String> {
        self.with(|i| {
            if i.skips.get(group_key).is_some_and(|(_, at)| now.saturating_duration_since(*at) >= SKIP_FOR) {
                i.skips.remove(group_key);
            }
            let silent: Option<(String, Instant)> = i
                .clocks
                .iter()
                .filter(|((g, _), started)| g == group_key && now.saturating_duration_since(**started) >= SILENCE_AFTER)
                .map(|((_, m), started)| (m.clone(), *started))
                .min_by(|a, b| a.1.cmp(&b.1).then_with(|| a.0.cmp(&b.0)));
            if let Some((master, _)) = silent {
                i.clocks.remove(&(group_key.to_string(), master.clone()));
                // One skip per window: a second silent responder waits for this one's to lapse.
                if !i.skips.contains_key(group_key) {
                    i.skips.insert(group_key.to_string(), (master, now));
                }
            }
            i.skips.get(group_key).map(|(m, _)| m.clone()).into_iter().collect()
        })
    }
}

/// Online CRDT members a leafless asker of a non-Legacy server tries, in order: by
/// standing (the owner first), with the old-rule target moved last unless it is the
/// owner.
pub(crate) fn walk_order(state: &ServerState, local_master: &str, peers: &Peers, old_target: Option<&str>) -> Vec<String> {
    let online = state
        .members
        .keys()
        .filter(|m| !super::resolver::same_identity(m, local_master) && super::crypto_handler::peer_is_reachable(peers, m))
        .cloned();
    let mut order = rank_masters(state, online);
    if let Some(old) = old_target
        && state.get_role(old) != MemberRole::Owner
        && let Some(at) = order.iter().position(|m| m == old)
    {
        let old = order.remove(at);
        order.push(old);
    }
    order
}

/// The next master a leafless walk asks, and whether that starts a new pass.
pub(crate) fn next_walk_target(order: &[String], asked: &[String]) -> Option<(String, bool)> {
    match order.iter().find(|m| !asked.contains(m)) {
        Some(m) => Some((m.clone(), false)),
        None => order.first().map(|m| (m.clone(), true)),
    }
}

/// Whether a leafless device may answer `requester`'s KeyPackage request in a
/// non-Legacy server: the owner, or a master at or above its walk target by standing.
pub(crate) fn leafless_may_answer(state: &ServerState, requester: &str, walk_target: Option<&str>) -> bool {
    if state.get_role(requester) == MemberRole::Owner {
        return true;
    }
    let Some(target) = walk_target else { return false };
    if super::resolver::same_identity(requester, target) {
        return true;
    }
    rank_masters(state, [requester.to_string(), target.to_string()]).first().map(String::as_str) == Some(requester)
}

/// Tell the device that sent a KeyPackage what became of it ([`KpOutcome`]).
#[inline(never)]
pub(crate) fn ack_key_package(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    peers: &Peers,
    device: &str,
    server_id: &str,
    channel_id: Option<String>,
    key_package: &[u8],
    outcome: KpOutcome,
    via: Option<&str>,
) {
    let msg = super::types::HavenMessage::MlsKeyPackageAck {
        server_id: server_id.to_string(),
        channel_id,
        package: package_tag(key_package),
        outcome,
        via: via.map(str::to_string),
    };
    super::crypto_handler::send_raw_to_peer(ws_cmd_tx, peers, device, serde_json::to_vec(&msg).unwrap_or_default());
}

/// Test-only switches, by device id. `OldLeaf`: the device mints leaves without the
/// tally and, like 0.12.2, never acks or forwards a KeyPackage. `NoRatchet`: its
/// committer skips the ratchet. `WelcomeOnReceipt`: a hostile committer that queues
/// every KeyPackage it receives, elected or not.
pub(crate) mod knobs {
    #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
    pub(crate) enum Knob {
        OldLeaf,
        NoRatchet,
        WelcomeOnReceipt,
    }

    #[cfg(test)]
    static SET: std::sync::LazyLock<std::sync::Mutex<std::collections::HashSet<(Knob, String)>>> =
        std::sync::LazyLock::new(Default::default);

    #[cfg(test)]
    pub(crate) fn set(knob: Knob, device: &str, on: bool) {
        let mut set = SET.lock().unwrap_or_else(|p| p.into_inner());
        if on {
            set.insert((knob, device.to_string()));
        } else {
            set.remove(&(knob, device.to_string()));
        }
    }

    #[inline]
    pub(crate) fn on(knob: Knob, device: &str) -> bool {
        #[cfg(test)]
        {
            SET.lock().unwrap_or_else(|p| p.into_inner()).contains(&(knob, device.to_string()))
        }
        #[cfg(not(test))]
        {
            let _ = (knob, device);
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crdt::admin_lww::AdminLwwReg;
    use crate::crdt::server_state::{MemberInfo, MemberSpan};

    fn hlc(ms: u64) -> HlcTimestamp {
        HlcTimestamp { physical_ms: ms, counter: 0, actor: "a".into() }
    }

    /// A state whose `members` hold `(master, opened at, admitted by [(author, at)])`;
    /// the first is the owner (founder, no admitters).
    /// (master, opened at, admitted by [(author, at)]).
    type Row<'a> = (&'a str, u64, &'a [(&'a str, u64)]);

    fn state(members: &[Row]) -> ServerState {
        let mut s = ServerState::new("0123456789abcdef0123456789abcdef01234567".into(), "s".into(), members[0].0.into());
        for (m, at, by) in members {
            s.members.insert((*m).into(), MemberInfo { peer_id: (*m).into(), display_name: (*m).into() });
            s.member_record.insert(
                (*m).into(),
                vec![MemberSpan {
                    from_ms: *at,
                    until_ms: u64::MAX,
                    asked_at: 0,
                    from_hlc: Some(hlc(*at)),
                    admitted: by.iter().map(|(a, t)| ((*a).to_string(), hlc(*t))).collect(),
                }],
            );
        }
        s
    }

    fn set_role(s: &mut ServerState, m: &str, role: MemberRole) {
        let p = role.priority();
        s.roles.insert(m.into(), AdminLwwReg::new(role, hlc(1), p));
    }

    fn ranked(s: &ServerState, masters: &[&str]) -> Vec<String> {
        rank_masters(s, masters.iter().map(|m| m.to_string()))
    }

    /// Unit 1: role tier first, then position, then the id; a non-member sorts last.
    #[test]
    fn rank_masters_orders_by_tier_then_position_then_id() {
        let mut s = state(&[
            ("own", 10, &[]),
            ("a_early", 20, &[("own", 20)]),
            ("b_late", 30, &[("own", 30)]),
            ("c_admin", 40, &[("own", 40)]),
            ("d_mod", 50, &[("own", 50)]),
            ("e_tie1", 60, &[("own", 60)]),
            ("f_tie2", 60, &[("own", 60)]),
        ]);
        set_role(&mut s, "c_admin", MemberRole::Admin);
        set_role(&mut s, "d_mod", MemberRole::Moderator);
        assert_eq!(
            ranked(&s, &["zz_stranger", "f_tie2", "b_late", "d_mod", "e_tie1", "a_early", "c_admin", "own"]),
            vec!["own", "c_admin", "d_mod", "a_early", "b_late", "e_tie1", "f_tie2", "zz_stranger"],
        );
        // An id grinding below everyone buys nothing.
        let mut s2 = s.clone();
        s2.members.insert("0000_ground".into(), MemberInfo { peer_id: "0000_ground".into(), display_name: String::new() });
        s2.member_record.insert(
            "0000_ground".into(),
            vec![MemberSpan { from_ms: 70, until_ms: u64::MAX, asked_at: 0, from_hlc: Some(hlc(70)), admitted: vec![("own".into(), hlc(70))] }],
        );
        assert_eq!(first_by_standing(&s2, ["0000_ground".to_string(), "b_late".to_string()]).as_deref(), Some("b_late"));
        // Position, not the member's own clock: admitted early by someone who left, it
        // ranks behind a later member admitted by a sitting one.
        let mut s3 = s.clone();
        s3.member_record.get_mut("a_early").unwrap()[0].admitted = vec![("gone".into(), hlc(20))];
        assert_eq!(ranked(&s3, &["a_early", "b_late"]), vec!["b_late", "a_early"]);
        // A member with no open span reads Max.
        s2.member_record.get_mut("a_early").unwrap()[0].until_ms = 25;
        assert_eq!(ranked(&s2, &["a_early", "b_late"]), vec!["b_late", "a_early"]);
    }

    /// Unit 2: the gate matrix (server, subgroup held / not held, Legacy, leafless, a
    /// leaf that declares but carries an unreadable tally).
    #[test]
    fn the_gate_matrix() {
        let rec = |dev: &str, master: &str, declares: bool| LeafRecord {
            index: 0,
            identity: Some(crate::crypto::LeafIdentity { device: dev.into(), master: master.into() }),
            declares,
            tally: None,
            commit_written: false,
            fresh_day: 0,
        };
        let on = vec![rec("o-d", "o", true), rec("a-d", "a", true)];
        let mixed = vec![rec("o-d", "o", true), rec("a-d", "a", false)];
        let unbound = vec![rec("o-d", "o", true), LeafRecord { identity: None, ..rec("x", "x", true) }];
        let holders = |r: &[LeafRecord]| Rule::Standing(Some(r.iter().filter_map(|l| l.identity.as_ref().map(|i| (i.device.clone(), i.master.clone()))).collect()));
        assert_eq!(rule_from(&on, false, None), holders(&on), "all declare: on, candidates are the holders");
        assert_eq!(rule_from(&mixed, false, None), Rule::Old, "one stale leaf: off");
        assert_eq!(rule_from(&unbound, false, None), Rule::Old, "an unbound leaf: off");
        assert_eq!(rule_from(&[], false, None), Rule::Old, "a leafless replica leads by the old rule");
        assert_eq!(rule_from(&on, true, None), Rule::Abstain, "a Legacy view of an on tree abstains");
        assert!(!Rule::Abstain.may_lead() && !Rule::Abstain.on());
        // `declares` decides, never whether the tally decodes (tally: None above).
        assert!(tree_declares(&on));
        let sub_on = vec![rec("a-d", "a", true)];
        let sub_mixed = vec![rec("a-d", "a", false)];
        assert_eq!(rule_from(&on, false, Some(Some(&sub_on))), holders(&sub_on), "subgroup on: its own holders");
        assert_eq!(rule_from(&on, false, Some(Some(&sub_mixed))), Rule::Old, "the subgroup's own tree must declare");
        assert_eq!(rule_from(&mixed, false, Some(Some(&sub_on))), Rule::Old, "and the server gate must be on");
        assert_eq!(rule_from(&on, false, Some(None)), Rule::Standing(None), "founding a subgroup: CRDT qualifiers");
        assert_eq!(rule_from(&mixed, false, Some(None)), Rule::Old);
        assert_eq!(rule_from(&on, true, Some(Some(&sub_on))), Rule::Abstain);
        // A candidate needs an ONLINE device holding a leaf: a leafless owner phone is none.
        let peers: Peers = [("room".to_string(), ["o-phone".to_string(), "a-d".to_string()].into())].into();
        let rule = rule_from(&on, false, None);
        assert!(!rule.admits("o", "me", &peers), "the owner's only online device holds no leaf");
        assert!(rule.admits("a", "me", &peers));
        assert!(rule.admits("o", "o", &peers), "we count as online");
        assert!(!rule.admits("zz", "me", &peers), "no leaf at all");
        assert!(Rule::Old.admits("zz", "me", &peers));
    }

    /// Unit 6: the walk orders by standing with the owner first and the old-rule target
    /// last, cycles through a pass, and the H1b gate answers only at or above it.
    #[test]
    fn the_walk_order_its_cursor_and_the_h1b_gate() {
        let mut s = state(&[
            ("own", 10, &[]),
            ("adm", 40, &[("own", 40)]),
            ("mem", 20, &[("own", 20)]),
            ("000x", 50, &[("own", 50)]),
            ("me", 60, &[("own", 60)]),
        ]);
        set_role(&mut s, "adm", MemberRole::Admin);
        let peers: Peers = [("room".to_string(), ["own", "adm", "mem", "000x", "me"].iter().map(|p| p.to_string()).collect())].into();
        let order = walk_order(&s, "me", &peers, Some("000x"));
        assert_eq!(order, vec!["own", "adm", "mem", "000x"]);
        let away: Peers = [("room".to_string(), ["adm", "mem", "000x", "me"].iter().map(|p| p.to_string()).collect())].into();
        let order = walk_order(&s, "me", &away, Some("000x"));
        assert_eq!(order, vec!["adm", "mem", "000x"], "the owner away; the old target last");
        let mut asked = Vec::new();
        for want in ["adm", "mem", "000x"] {
            let (next, restart) = next_walk_target(&order, &asked).unwrap();
            assert_eq!((next.as_str(), restart), (want, false));
            asked.push(next);
        }
        assert_eq!(next_walk_target(&order, &asked), Some(("adm".to_string(), true)), "a full pass restarts");
        assert_eq!(next_walk_target(&[], &asked), None);
        // The old rule's target goes last even when it stands early.
        let order = walk_order(&s, "me", &away, Some("mem"));
        assert_eq!(order, vec!["adm", "000x", "mem"]);

        assert!(leafless_may_answer(&s, "own", None), "the owner always");
        assert!(!leafless_may_answer(&s, "adm", None), "nobody else without a walk target");
        assert!(leafless_may_answer(&s, "adm", Some("mem")), "above our target");
        assert!(leafless_may_answer(&s, "mem", Some("mem")), "our target itself");
        assert!(!leafless_may_answer(&s, "000x", Some("mem")), "below our target: refused");
    }

    /// Unit 7: an admission authored by a member who has since left buys its admittee
    /// nothing; unit 9: a duplicate admission never worsens a position.
    #[test]
    fn a_removed_members_backdated_admission_buys_no_standing() {
        // gone admitted m early, then left; m holds no other admitter.
        let s = state(&[("own", 10, &[]), ("m", 15, &[("gone", 15)]), ("late", 40, &[("own", 40)])]);
        let pos = positions(&s);
        assert_eq!(pos["m"], Pos::Max);
        assert_eq!(ranked(&s, &["m", "late"]), vec!["late", "m"]);
    }

    #[test]
    fn a_duplicate_backdated_admission_cannot_worsen_a_members_position() {
        let honest = state(&[("own", 10, &[]), ("x", 30, &[("own", 30)]), ("m", 20, &[("own", 20)])]);
        let mut dup = honest.clone();
        // x backdates an admission of m to before the honest one: min keeps the owner's.
        dup.member_record.get_mut("m").unwrap()[0].admitted.push(("x".into(), hlc(19)));
        assert_eq!(positions(&honest)["m"], positions(&dup)["m"]);
        assert_eq!(positions(&dup)["m"], Pos::At(hlc(20)));
        // A duplicate lifts an accomplice no higher than its author stands.
        let mut lift = state(&[("own", 10, &[]), ("x", 30, &[("own", 30)]), ("acc", 50, &[("own", 50)])]);
        lift.member_record.get_mut("acc").unwrap()[0].admitted.push(("x".into(), hlc(25)));
        assert_eq!(positions(&lift)["acc"], Pos::At(hlc(30)));
    }

    /// Unit 10: a departed admitter demotes only who it alone admitted.
    #[test]
    fn a_departed_admitter_demotes_only_what_it_alone_admitted() {
        let s = state(&[
            ("own", 10, &[]),
            ("alone", 20, &[("gone", 20)]),
            ("both", 21, &[("gone", 21), ("own", 22)]),
            ("child", 30, &[("alone", 30)]),
        ]);
        let pos = positions(&s);
        assert_eq!(pos["alone"], Pos::Max);
        assert_eq!(pos["child"], Pos::Max, "its admittees go with it");
        assert_eq!(pos["both"], Pos::At(hlc(22)), "a second, sitting admitter keeps the place");
    }

    /// Unit 8: positions recurse through admitters; a rejoined admitter carries its
    /// admittees no earlier than its new span; a cycle with no seeded entry reads Max.
    #[test]
    fn position_recursion() {
        let s = state(&[("own", 10, &[]), ("a", 20, &[("own", 20)]), ("b", 15, &[("a", 15)]), ("c", 12, &[("b", 12)])]);
        let pos = positions(&s);
        assert_eq!((pos["a"].clone(), pos["b"].clone(), pos["c"].clone()), (Pos::At(hlc(20)), Pos::At(hlc(20)), Pos::At(hlc(20))));
        let rejoined = state(&[("own", 10, &[]), ("a", 90, &[("own", 90)]), ("b", 15, &[("a", 15)])]);
        assert_eq!(positions(&rejoined)["b"], Pos::At(hlc(90)));
        let cycle = state(&[("own", 10, &[]), ("p", 20, &[("q", 20)]), ("q", 21, &[("p", 21)])]);
        let pos = positions(&cycle);
        assert_eq!((pos["p"].clone(), pos["q"].clone()), (Pos::Max, Pos::Max));
        // Spans written before 0.13 read their physical time.
        let mut old = state(&[("own", 10, &[]), ("o", 20, &[])]);
        old.member_record.get_mut("o").unwrap()[0].from_hlc = None;
        assert_eq!(positions(&old)["o"], Pos::At(HlcTimestamp { physical_ms: 20, counter: 0, actor: String::new() }));
    }

    /// Unit 15: the least fixed point is a function of the ops alone: six insertion
    /// orders of a three-member admission cycle with one outside admitter agree.
    #[test]
    fn positions_are_the_same_for_every_insertion_order() {
        let rows: [Row; 3] = [("p", 20, &[("q", 20), ("own", 50)]), ("q", 21, &[("r", 21)]), ("r", 22, &[("p", 22)])];
        let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]];
        let mut seen = Vec::new();
        for order in orders {
            let mut members: Vec<Row> = vec![("own", 10, &[])];
            members.extend(order.iter().map(|i| rows[*i]));
            let pos = positions(&state(&members));
            let mut v: Vec<(String, Pos)> = pos.into_iter().collect();
            v.sort();
            seen.push(v);
        }
        assert!(seen.windows(2).all(|w| w[0] == w[1]), "{seen:?}");
        let pos: HashMap<String, Pos> = seen[0].iter().cloned().collect();
        assert_eq!(pos["p"], Pos::At(hlc(50)), "the outside admitter seeds the cycle");
        assert_eq!(pos["r"], Pos::At(hlc(50)));
        assert_eq!(pos["q"], Pos::At(hlc(50)));
    }

    /// Unit 12 (part): an ack counts only from a device we asked, for the package we sent.
    #[test]
    fn an_ack_counts_only_from_a_device_we_asked_for_our_package() {
        let book = LeadBook::default();
        book.note_walk_ask("g", "adm", vec!["adm-d".into()], b"pkg".to_vec(), false);
        let tag = package_tag(b"pkg");
        assert!(!book.note_ack("g", "x-d", &tag, KpOutcome::Cannot), "a device we did not ask");
        assert!(!book.note_ack("g", "adm-d", &package_tag(b"other"), KpOutcome::Cannot), "another package");
        assert!(!book.walk_step_due("g"));
        assert!(book.note_ack("g", "adm-d", &tag, KpOutcome::Forwarded));
        assert!(!book.walk_step_due("g"), "a forward waits for the ordinary re-ask");
        assert_eq!(book.walk_package("g"), Some(b"pkg".to_vec()), "the pass keeps its package");
        book.note_walk_ask("g", "mem", vec!["mem-d".into()], b"pkg".to_vec(), false);
        assert!(book.note_ack("g", "mem-d", &tag, KpOutcome::Cannot));
        assert!(book.walk_step_due("g"), "Cannot steps at once");
        assert_eq!(book.walk_asked("g"), vec!["adm", "mem"]);
        book.note_walk_ask("g", "own", vec!["own-d".into()], b"pkg".to_vec(), false);
        assert!(book.note_ack("g", "own-d", &tag, KpOutcome::Commit));
        assert!(book.walk_package("g").is_none(), "asked again after a Commit, the next ask mints afresh");
        book.end_walk("g");
        assert!(book.walk_target("g").is_none());
    }

    /// The committer a forward names counts only from the master we answered, for the
    /// package we answered it with, and only when it is the owner or a current unbanned
    /// member with a bound leaf in our tree; never required to be the coordinator.
    #[test]
    fn an_ack_naming_a_non_member_or_another_package_sets_no_delegate() {
        let mut s = state(&[("own", 10, &[]), ("resp", 20, &[("own", 20)]), ("coord", 30, &[("own", 30)]), ("leafless", 40, &[("own", 40)])]);
        s.members.insert("banned".into(), MemberInfo { peer_id: "banned".into(), display_name: "banned".into() });
        s.banned_members.insert("banned".into(), AdminLwwReg::new(true, hlc(50), 3));
        let leaves: Vec<String> = ["own", "resp", "coord", "banned", "rogue"].iter().map(|m| m.to_string()).collect();
        let book = LeadBook::default();
        let tag = package_tag(b"pkg");
        assert!(!book.note_repair_delegate("g", "resp", &tag, "coord", &s, &leaves), "no request answered yet");
        book.note_repair_answer("g", "resp", b"pkg");
        assert!(!book.note_repair_delegate("g", "other", &tag, "coord", &s, &leaves), "an ack from a master we did not answer");
        assert!(!book.note_repair_delegate("g", "resp", &package_tag(b"other"), "coord", &s, &leaves), "another package");
        assert!(!book.note_repair_delegate("h", "resp", &tag, "coord", &s, &leaves), "another group");
        assert!(!book.note_repair_delegate("g", "resp", &tag, "rogue", &s, &leaves), "a bound leaf of no member");
        assert!(!book.note_repair_delegate("g", "resp", &tag, "banned", &s, &leaves), "a banned member");
        assert!(!book.note_repair_delegate("g", "resp", &tag, "leafless", &s, &leaves), "a member with no leaf in our tree");
        assert!(book.repair_delegate("g", "resp").is_none());
        assert!(book.note_repair_delegate("g", "resp", &tag, "coord", &s, &leaves));
        assert_eq!(book.repair_delegate("g", "resp").as_deref(), Some("coord"));
        assert!(book.repair_delegate("g", "other").is_none(), "only the master we answered names one");
        assert!(book.repair_delegate("h", "resp").is_none());
        assert!(book.note_repair_delegate("g", "resp", &tag, "own", &s, &[]), "the owner needs no leaf in our tree");
        assert_eq!(book.repair_delegate("g", "resp").as_deref(), Some("own"));
    }

    /// The silence clock starts only on a spaced required probe with the gate on, and
    /// the skip clears on contact.
    #[test]
    fn silence_starts_only_on_spaced_required_probes() {
        let book = LeadBook::default();
        let t0 = Instant::now();
        book.note_probe_at("g", "a", false, t0);
        assert!(book.skipped_at("g", t0 + Duration::from_secs(60)).is_empty(), "gate off: no clock");
        book.note_probe_at("g", "a", true, t0 + Duration::from_secs(10));
        assert!(book.skipped_at("g", t0 + Duration::from_secs(60)).is_empty(), "10 s after the last probe: no clock");
        book.note_probe_at("g", "a", true, t0 + Duration::from_secs(40));
        assert!(book.skipped_at("g", t0 + Duration::from_secs(54)).is_empty(), "inside the silence window");
        assert_eq!(book.skipped_at("g", t0 + Duration::from_secs(56)), HashSet::from(["a".to_string()]));
        // A second silent responder inside the window does not replace the skip.
        book.note_probe_at("g", "b", true, t0 + Duration::from_secs(56));
        assert_eq!(book.skipped_at("g", t0 + Duration::from_secs(80)), HashSet::from(["a".to_string()]), "one skip per window");
        // The skip lapses with its window.
        assert!(book.skipped_at("g", t0 + Duration::from_secs(56) + SKIP_FOR).is_empty(), "a skip expires");
        book.note_probe_at("g", "a", true, t0 + Duration::from_secs(700));
        assert_eq!(book.skipped_at("g", t0 + Duration::from_secs(716)), HashSet::from(["a".to_string()]));
        book.heard("g", "a");
        assert!(book.skipped_at("g", t0 + Duration::from_secs(717)).is_empty(), "contact ends the skip");
    }

    /// Unit 14 (round 3): over 30 simulated minutes of responders that each go silent,
    /// ours is never lower than the second in standing.
    #[test]
    fn three_successive_silent_responders_never_move_ours_past_the_second_in_standing() {
        let standing = ["a", "b", "c", "x"];
        let book = LeadBook::default();
        let t0 = Instant::now();
        let mut now = t0;
        let mut worst = 0;
        while now < t0 + Duration::from_secs(1800) {
            let skipped = book.skipped_at("g", now);
            let pos = standing.iter().position(|m| !skipped.contains(*m)).unwrap();
            worst = worst.max(pos);
            // Every responder we pick stays silent.
            book.note_probe_at("g", standing[pos], true, now);
            now += Duration::from_secs(21);
        }
        assert!(worst <= 1, "our responder fell to {}", standing[worst]);
    }
}
