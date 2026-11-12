//! Our identity's server leaves, kept until they land.
//!
//! A leave is one signed op, and until the owner holds it the server still counts us.
//! The device that leaves keeps the op, the server's room and its door, across restarts,
//! until the owner's own answer shows our membership ended: a frame handed to a socket
//! is no landing (the socket may be dead, the owner may refuse it until it learns of our
//! admission). Every other member is handed the op once.
//! Every device also keeps the leaves of its own identity it hears, and folds them into
//! any later join of that server: a join a sibling announced before the leave, or one
//! a stale membership answers, cannot bring the server back.

use std::collections::{BTreeMap, BTreeSet, HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

use crate::crdt::hlc::HlcTimestamp;
use crate::crdt::operations::{CrdtOp, CrdtPayload};
use crate::crypto::OlmManager;

use super::types::{HavenMessage, WsCmdTx, WsRoomPeers};

const SETTING: &str = "leave_book";
/// Leaves of ours still on their way; past it one already handed to a member goes first.
const PENDING_CAP: usize = 32;
/// Leaves of our identity kept against a late join; past it the device holding the
/// most gives one up.
const LEFT_CAP: usize = 256;
/// A leave no one could be handed for this long is given up, and its room with it.
const PATIENCE_MS: u64 = 30 * 24 * 3600 * 1000;
/// Between two copies parked for one device we hold no session with.
const ASK_GAP: Duration = Duration::from_secs(20);
/// Asking the owner whether it holds our leave: first again after this, doubling up to
/// the most below while it never says so. An owner device coming online is asked at once.
const PROBE_GAP: Duration = Duration::from_secs(20);
const PROBE_GAP_MAX: Duration = Duration::from_secs(3600);
/// Our asks an owner's answer may echo: one from a slow socket still counts.
const PROBE_NONCES: usize = 4;

/// A door our socket keeps proving while it hands on a leave.
#[derive(Clone, Serialize, Deserialize)]
struct HeldDoor {
    #[serde(default)]
    n: u64,
    #[serde(default)]
    secret: String,
}

#[derive(Clone, Default, Serialize, Deserialize)]
struct PendingLeave {
    #[serde(default)]
    op_json: String,
    #[serde(default)]
    owner: Option<String>,
    /// Every other member when we left, master-keyed.
    #[serde(default)]
    targets: Vec<String>,
    #[serde(default)]
    reached: BTreeSet<String>,
    #[serde(default)]
    door: Option<HeldDoor>,
    #[serde(default)]
    since_ms: u64,
    /// The clock of the leave the user made: an owner holding our membership ended at or
    /// after it holds the leave.
    #[serde(default)]
    left_hlc: Option<HlcTimestamp>,
}

impl PendingLeave {
    /// Without an owner to answer, every other member handed the op is the most we get.
    fn landed(&self) -> bool {
        self.owner.is_none() && self.targets.iter().all(|t| self.reached.contains(t))
    }

    fn left_hlc(&self) -> Option<HlcTimestamp> {
        self.left_hlc.clone().or_else(|| match crate::crdt::operations::read_op(&self.op_json) {
            crate::crdt::operations::ReadOp::Op(op) => Some(op.hlc),
            _ => None,
        })
    }
}

/// When we next ask the owner, and the asks its answer may echo (RAM only).
struct Probe {
    nonces: VecDeque<u64>,
    next: Instant,
    gap: Duration,
    /// The owner's devices online at the last pass.
    seen: Vec<String>,
}

impl Probe {
    fn new() -> Self {
        Self { nonces: VecDeque::new(), next: Instant::now(), gap: PROBE_GAP, seen: Vec::new() }
    }
}

/// `op` as the owner ending our membership of `server_id` outright: its deletion, or
/// its removal or ban of us no earlier than our leave (an older one may predate a
/// rejoin). Signed by that owner, never by whoever carried it.
fn closed_by_owner(op: &CrdtOp, server_id: &str, owner: &str, local_master: &str, left: &HlcTimestamp) -> bool {
    let closes = match &op.payload {
        CrdtPayload::ServerDeleted { .. } => true,
        CrdtPayload::MemberRemoved { peer_id, .. } | CrdtPayload::MemberBanned { peer_id, .. } => {
            peer_id == local_master && op.hlc >= *left
        }
        _ => false,
    };
    closes && op.server_id == server_id && op.author == owner && op.verify_author().is_ok()
}

/// The owner's answer to our ask as a former member's notice: its last op ends our
/// membership no earlier than our leave (`crdt::sync::removal_notice`).
fn ends_us_since(ops: &[CrdtOp], server_id: &str, local_master: &str, left: &HlcTimestamp) -> bool {
    ops.last().is_some_and(|op| {
        matches!(&op.payload, CrdtPayload::MemberRemoved { peer_id, .. } | CrdtPayload::MemberBanned { peer_id, .. } if peer_id == local_master)
            && op.server_id == server_id
            && op.hlc >= *left
            && op.verify_author().is_ok()
    })
}

/// A sync ask that only a former member's notice answers with ops: a member is sent an
/// empty digest answer, a stranger nothing.
fn ask_owner(server_id: &str, nonce: u64) -> HavenMessage {
    HavenMessage::SyncRequest {
        server_id: server_id.to_string(),
        state_vector_json: String::new(),
        mls_epoch: None,
        nonce: Some(nonce),
        full: None,
        digest: Some(crate::crdt::digest::OpDigest {
            ask: nonce,
            salt: crate::crdt::digest::new_salt(),
            base: None,
            bref: None,
            from: None,
            ranges: Vec::new(),
            round: 0,
            rs: None,
        }),
        x: None,
    }
}

#[derive(Clone, Default, Serialize, Deserialize)]
struct LeftMark {
    #[serde(default)]
    op_json: String,
    /// The device of ours that told us: a full book evicts from the busiest one.
    #[serde(default)]
    from: String,
    #[serde(default)]
    at_ms: u64,
    /// The leave that ended our membership as members fold it: the earliest at or past
    /// `opened`. A book saved before it names `op_json`'s.
    #[serde(default)]
    closer: Option<HlcTimestamp>,
    /// The ask of our identity's newest membership this device knows of: a leave
    /// stamped before it ended an earlier one.
    #[serde(default)]
    opened: i64,
}

impl LeftMark {
    fn closer(&self) -> Option<HlcTimestamp> {
        self.closer.clone().or_else(|| match crate::crdt::operations::read_op(&self.op_json) {
            crate::crdt::operations::ReadOp::Op(op) => Some(op.hlc),
            _ => None,
        })
    }
}

/// The leave that ends the membership opened by ask `opened`, from the one held and a
/// new one: the fold closes a span at its first leave, and no ask opens a span unless it
/// is newer than the leave before (`crdt::members::opens`).
fn first_leave_since(held: Option<HlcTimestamp>, leave: &HlcTimestamp, opened: i64) -> Option<HlcTimestamp> {
    let ends_it = |at: &&HlcTimestamp| i128::from(at.physical_ms) >= i128::from(opened);
    let first = held.iter().chain([leave]).filter(ends_it).min().cloned();
    first.or(held)
}

/// What a new ask to join a server our identity left names and is stamped past.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct AskFloor {
    /// The leave that ended our membership as members fold it: an ask naming it counts by
    /// its stamp, else members take it for one from before.
    pub(crate) follows: Option<HlcTimestamp>,
    /// Our identity's newest leave we hold. The ask is stamped past it and its admission
    /// past the ask, so no leave of ours we know of ends the membership it opens.
    pub(crate) past_ms: Option<u64>,
}

/// The ask that opened our identity's newest membership `state` records.
pub(crate) fn opened_by(state: Option<&crate::crdt::server_state::ServerState>, local_master: &str) -> Option<i64> {
    state?.member_record.get(local_master)?.last().map(|span| span.asked_at)
}

#[derive(Default, Serialize, Deserialize)]
struct Stored {
    #[serde(default)]
    pending: BTreeMap<String, PendingLeave>,
    #[serde(default)]
    left: BTreeMap<String, LeftMark>,
}

pub(crate) struct LeaveBook {
    stored: Stored,
    parked: HashMap<String, Instant>,
    probes: HashMap<String, Probe>,
    db_path: String,
    db_passphrase: String,
    /// Saves run off the event loop; the newest one written wins, whatever order the
    /// pool runs them in.
    saves: u64,
    written: Arc<Mutex<u64>>,
}

/// `op_json` as our own identity's leave of `server_id`, handed to us by `sender`: only
/// one of our own counted devices may tell us, and only an op our master signed. A
/// signature proves who left, the sender's place in our roster that we may act on it.
pub(crate) fn own_leave(server_id: &str, op_json: &str, sender: &str, local_master: &str) -> Option<CrdtOp> {
    if !super::resolver::is_own_unrevoked_device(sender, local_master) {
        return None;
    }
    let crate::crdt::operations::ReadOp::Op(op) = crate::crdt::operations::read_op(op_json) else { return None };
    let ours = op.server_id == server_id
        && op.author == local_master
        && matches!(&op.payload, CrdtPayload::MemberRemoved { peer_id, .. } if peer_id == local_master)
        && op.hlc.physical_ms <= crate::crdt::hlc::wall_clock_ms().saturating_add(crate::crdt::hlc::MAX_DRIFT_MS);
    (ours && op.verify_author().is_ok()).then_some(op)
}

fn now_ms() -> u64 {
    crate::crdt::hlc::wall_clock_ms()
}

impl LeaveBook {
    pub(crate) fn load(db_path: &str, db_passphrase: &str) -> Self {
        let stored = crate::storage::MessageStore::lease(db_path, db_passphrase)
            .ok()
            .and_then(|store| store.load_setting(SETTING).ok().flatten())
            .and_then(|json| serde_json::from_str(&json).ok())
            .unwrap_or_default();
        Self {
            stored,
            parked: HashMap::new(),
            probes: HashMap::new(),
            db_path: db_path.to_string(),
            db_passphrase: db_passphrase.to_string(),
            saves: 0,
            written: Arc::new(Mutex::new(0)),
        }
    }

    fn save(&mut self) {
        if self.db_path.is_empty() {
            return;
        }
        let Ok(json) = serde_json::to_string(&self.stored) else { return };
        self.saves += 1;
        let (n, written) = (self.saves, self.written.clone());
        let (path, pass) = (self.db_path.clone(), self.db_passphrase.clone());
        let write = move || {
            let mut last = written.lock().unwrap_or_else(|e| e.into_inner());
            if *last > n {
                return;
            }
            match crate::storage::MessageStore::lease(&path, &pass).and_then(|store| store.save_setting(SETTING, &json)) {
                Ok(()) => *last = n,
                Err(e) => hollow_log!("[HOLLOW-CRDT] Could not keep our pending leaves: {e}"),
            }
        };
        match tokio::runtime::Handle::try_current() {
            Ok(rt) => drop(rt.spawn_blocking(write)),
            Err(_) => write(),
        }
    }

    /// We left `server_id` with `op`, ending the membership ask `opened` began: keep it,
    /// and its room and door, until it lands. Returns a room a full book gave up to make space.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn begin(
        &mut self,
        server_id: &str,
        op: &CrdtOp,
        owner: Option<String>,
        targets: Vec<String>,
        door: Option<(u64, Zeroizing<[u8; 32]>)>,
        local_device: &str,
        opened: Option<i64>,
    ) -> Option<String> {
        let Ok(op_json) = serde_json::to_string(op) else { return None };
        let mut dropped = None;
        let pending = &mut self.stored.pending;
        if pending.len() >= PENDING_CAP && !pending.contains_key(server_id) {
            let victim = pending
                .iter()
                .min_by_key(|(_, p)| (p.reached.is_empty(), p.since_ms))
                .map(|(sid, _)| sid.clone());
            if let Some(victim) = victim {
                pending.remove(&victim);
                dropped = Some(victim);
            }
        }
        pending.insert(
            server_id.to_string(),
            PendingLeave {
                op_json: op_json.clone(),
                owner,
                targets,
                reached: BTreeSet::new(),
                door: door.map(|(n, secret)| HeldDoor { n, secret: hex::encode(secret.as_slice()) }),
                since_ms: now_ms(),
                left_hlc: Some(op.hlc.clone()),
            },
        );
        self.probes.remove(server_id);
        // A span from before asks were recorded names no ask: our own leave is all we know.
        let opened = opened.filter(|at| *at > 0).unwrap_or(i64::try_from(op.hlc.physical_ms).unwrap_or(i64::MAX));
        let (closer, opened) = self.closer_with(server_id, op, Some(opened));
        // A sibling's newer leave already held stays the newest one: a rejoin's ask is
        // stamped past it.
        let (op_json, from, at_ms) = match self.stored.left.get(server_id) {
            Some(mark) if mark.at_ms > op.hlc.physical_ms => (mark.op_json.clone(), mark.from.clone(), mark.at_ms),
            _ => (op_json, local_device.to_string(), op.hlc.physical_ms),
        };
        self.keep_left(server_id, LeftMark { op_json, from, at_ms, closer, opened });
        self.save();
        dropped
    }

    /// An own device told us our identity left `server_id` ([`own_leave`] passed).
    /// `opened`: the ask of the newest membership of ours we know of, when we know one.
    pub(crate) fn note_left(&mut self, server_id: &str, op: &CrdtOp, from: &str, opened: Option<i64>) {
        let Ok(op_json) = serde_json::to_string(op) else { return };
        let (closer, opened) = self.closer_with(server_id, op, opened);
        match self.stored.left.get_mut(server_id) {
            Some(mark) if mark.at_ms >= op.hlc.physical_ms => {
                if mark.closer == closer && mark.opened == opened {
                    return;
                }
                mark.closer = closer;
                mark.opened = opened;
            }
            _ => {
                let at_ms = op.hlc.physical_ms;
                self.keep_left(server_id, LeftMark { op_json, from: from.to_string(), at_ms, closer, opened });
            }
        }
        self.save();
    }

    /// The closer and opening ask `server_id`'s mark holds once it hears of leave `op`.
    fn closer_with(&self, server_id: &str, op: &CrdtOp, opened: Option<i64>) -> (Option<HlcTimestamp>, i64) {
        let held = self.stored.left.get(server_id);
        let opened = held.map_or(0, |m| m.opened).max(opened.unwrap_or(0));
        (first_leave_since(held.and_then(LeftMark::closer), &op.hlc, opened), opened)
    }

    fn keep_left(&mut self, server_id: &str, mark: LeftMark) {
        let left = &mut self.stored.left;
        if left.len() >= LEFT_CAP && !left.contains_key(server_id) {
            let mut per_device: HashMap<&str, usize> = HashMap::new();
            for mark in left.values() {
                *per_device.entry(mark.from.as_str()).or_default() += 1;
            }
            let busiest = per_device.into_iter().max_by_key(|(d, n)| (*n, d.to_string())).map(|(d, _)| d.to_string());
            let victim = left
                .iter()
                .filter(|(_, m)| Some(&m.from) == busiest.as_ref())
                .min_by_key(|(_, m)| m.at_ms)
                .map(|(sid, _)| sid.clone());
            if let Some(victim) = victim {
                left.remove(&victim);
            }
        }
        left.insert(server_id.to_string(), mark);
    }

    /// Our identity's newest leave of `server_id` we hold, for a join of it to fold in.
    pub(crate) fn left_op(&self, server_id: &str) -> Option<CrdtOp> {
        let mark = self.stored.left.get(server_id)?;
        match crate::crdt::operations::read_op(&mark.op_json) {
            crate::crdt::operations::ReadOp::Op(op) => Some(op),
            _ => None,
        }
    }

    /// What a new ask to join `server_id` names and is stamped past.
    pub(crate) fn ask_floor(&self, server_id: &str) -> AskFloor {
        let Some(mark) = self.stored.left.get(server_id) else { return AskFloor::default() };
        let follows = mark.closer();
        let past_ms = follows.as_ref().map(|c| c.physical_ms).into_iter().chain([mark.at_ms]).max();
        AskFloor { follows, past_ms }
    }

    /// A join of `server_id` holds us a member past our leave: the leave is history.
    pub(crate) fn forget_left(&mut self, server_id: &str) {
        if self.stored.left.remove(server_id).is_some() {
            self.save();
        }
    }

    /// We are a member of `server_id` again: a leave from before never needs to land.
    pub(crate) fn drop_pending(&mut self, server_id: &str) {
        self.probes.remove(server_id);
        if self.stored.pending.remove(server_id).is_some() {
            self.save();
        }
    }

    /// The owner our pending leave of `server_id` names deleted the server, or removed or
    /// banned us: nobody there needs our leave any more. Only that owner's signed op ends it.
    pub(crate) fn owner_closed(&mut self, server_id: &str, op_json: &str, local_master: &str) -> bool {
        let Some(pending) = self.stored.pending.get(server_id) else { return false };
        let (Some(owner), Some(left)) = (pending.owner.clone(), pending.left_hlc()) else { return false };
        let crate::crdt::operations::ReadOp::Op(op) = crate::crdt::operations::read_op(op_json) else { return false };
        if !closed_by_owner(&op, server_id, &owner, local_master, &left) {
            return false;
        }
        hollow_log!("[HOLLOW-CRDT] The owner of {server_id} closed it to us: our leave needs no landing");
        self.drop_pending(server_id);
        true
    }

    /// A device of the owner answered one of our asks of `server_id`: when its answer shows
    /// our membership ended at or after our leave, or the server closed to us, the leave
    /// landed. Any other answer, or none, leaves it on its way.
    pub(crate) fn on_answer(&mut self, server_id: &str, ops_json: &str, nonce: Option<u64>, sender: &str, local_master: &str) -> bool {
        let Some(pending) = self.stored.pending.get(server_id) else { return false };
        let (Some(owner), Some(left)) = (pending.owner.as_deref(), pending.left_hlc()) else { return false };
        let asked = self.probes.get(server_id).is_some_and(|p| nonce.is_some_and(|n| p.nonces.contains(&n)));
        if !asked || super::resolver::is_revoked(sender) || super::resolver::resolve(sender) != owner {
            return false;
        }
        let ops = crate::crdt::operations::parse_ops_tolerant(ops_json).ops;
        let landed = ops.iter().any(|op| closed_by_owner(op, server_id, owner, local_master, &left))
            || ends_us_since(&ops, server_id, local_master, &left);
        if landed {
            hollow_log!("[HOLLOW-CRDT] The owner of {server_id} holds our leave");
            self.drop_pending(server_id);
        }
        landed
    }

    /// Whether a leave of ours still holds `server_id`'s room.
    pub(crate) fn holds_room(&self, server_id: &str) -> bool {
        self.stored.pending.contains_key(server_id)
    }

    /// The rooms our pending leaves hold, to join on every connect.
    pub(crate) fn rooms(&self) -> Vec<String> {
        self.stored.pending.keys().cloned().collect()
    }

    /// The doors our pending leaves prove, for the socket.
    pub(crate) fn doors(&self) -> Vec<(String, u64, Zeroizing<[u8; 32]>)> {
        self.stored
            .pending
            .iter()
            .filter_map(|(sid, p)| {
                let door = p.door.as_ref()?;
                let bytes = Zeroizing::new(hex::decode(&door.secret).ok()?);
                let secret: [u8; 32] = bytes.as_slice().try_into().ok()?;
                Some((sid.clone(), door.n, Zeroizing::new(secret)))
            })
            .collect()
    }

    /// Hand every pending leave on: once to each other member device we can reach now
    /// (one we hold no session with gets a copy parked behind a key exchange), and to the
    /// owner's devices with an ask whether it holds it, again whenever one comes online
    /// and on a backoff. Returns the rooms whose leave landed or was given up.
    pub(crate) fn drive(&mut self, olm: &OlmManager, ws_room_peers: &WsRoomPeers, ws_cmd_tx: &WsCmdTx) -> Vec<String> {
        if self.stored.pending.is_empty() {
            self.probes.clear();
            return Vec::new();
        }
        let now = now_ms();
        self.parked.retain(|_, t| t.elapsed() < ASK_GAP);
        // One pass over who is online, by identity, for every leave and target below.
        let mut online: HashMap<String, Vec<String>> = HashMap::new();
        for device in ws_room_peers.values().flatten() {
            if super::resolver::is_bare_master(device) || super::resolver::is_revoked(device) {
                continue;
            }
            let held = online.entry(super::resolver::resolve(device)).or_default();
            if !held.contains(device) {
                held.push(device.clone());
            }
        }
        let mut done = Vec::new();
        let mut changed = false;
        for (sid, pending) in self.stored.pending.iter_mut() {
            // Nothing for a server the relay refuses leaves at all: handing it now would
            // count devices as reached that never got it.
            if super::relay_denial::denied(sid) {
                continue;
            }
            if now.saturating_sub(pending.since_ms) > PATIENCE_MS {
                hollow_log!("[HOLLOW-CRDT] Gave up handing on our leave of {sid}");
                done.push(sid.clone());
                continue;
            }
            let msg = HavenMessage::CrdtOpBroadcast { server_id: sid.clone(), op_json: pending.op_json.clone() };
            let Some(json) = super::olm_lane::carried_json(&msg) else { continue };
            if let Some(owner) = &pending.owner {
                let devices = online.get(owner).cloned().unwrap_or_default();
                let probe = self.probes.entry(sid.clone()).or_insert_with(Probe::new);
                let back = devices.iter().any(|d| !probe.seen.contains(d));
                probe.seen = devices.clone();
                if !devices.is_empty() && (back || Instant::now() >= probe.next) {
                    let mut salt = [0u8; 8];
                    let _ = getrandom::fill(&mut salt);
                    let nonce = u64::from_le_bytes(salt);
                    if probe.nonces.len() >= PROBE_NONCES {
                        probe.nonces.pop_front();
                    }
                    probe.nonces.push_back(nonce);
                    let ask = super::olm_lane::carried_json(&ask_owner(sid, nonce));
                    for device in &devices {
                        // The op first: the owner reads it before it answers the ask.
                        super::olm_lane::carry_json(ws_cmd_tx, device, None, json.clone(), super::olm_lane::NoSession::Queue);
                        if let Some(ask) = &ask {
                            super::olm_lane::carry_json(ws_cmd_tx, device, None, ask.clone(), super::olm_lane::NoSession::Queue);
                        }
                    }
                    probe.next = Instant::now() + probe.gap;
                    probe.gap = (probe.gap * 2).min(PROBE_GAP_MAX);
                    if pending.reached.insert(owner.clone()) {
                        hollow_log!("[HOLLOW-CRDT] Handed our leave of {sid} to its owner");
                        changed = true;
                    }
                }
            }
            let open: Vec<String> = pending
                .targets
                .iter()
                .filter(|t| !pending.reached.contains(*t) && pending.owner.as_ref() != Some(*t))
                .cloned()
                .collect();
            for target in open {
                for device in online.get(&target).into_iter().flatten() {
                    if olm.has_session(device) {
                        super::olm_lane::carry_json(ws_cmd_tx, device, None, json.clone(), super::olm_lane::NoSession::Queue);
                        if pending.reached.insert(target.clone()) {
                            hollow_log!("[HOLLOW-CRDT] Handed our leave of {sid} to {target}");
                            changed = true;
                        }
                    } else if !self.parked.contains_key(device) {
                        self.parked.insert(device.clone(), Instant::now());
                        super::olm_lane::carry_json(ws_cmd_tx, device, None, json.clone(), super::olm_lane::NoSession::Queue);
                    }
                }
            }
            if pending.landed() {
                done.push(sid.clone());
            }
        }
        for sid in &done {
            self.stored.pending.remove(sid);
            self.probes.remove(sid);
            changed = true;
        }
        if changed {
            self.save();
        }
        done
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn book() -> LeaveBook {
        LeaveBook {
            stored: Stored::default(),
            parked: HashMap::new(),
            probes: HashMap::new(),
            db_path: String::new(),
            db_passphrase: String::new(),
            saves: 0,
            written: Arc::new(Mutex::new(0)),
        }
    }

    fn mark(from: &str, at_ms: u64) -> LeftMark {
        LeftMark { op_json: String::new(), from: from.to_string(), at_ms, ..Default::default() }
    }

    /// A full book of left marks gives up one of the device that told us the most,
    /// whatever the age of the others' marks.
    #[test]
    fn a_full_left_book_evicts_from_the_busiest_device() {
        let mut b = book();
        b.stored.left.insert("quiet-old".into(), mark("quiet", 1));
        for i in 0..LEFT_CAP - 1 {
            b.stored.left.insert(format!("loud-{i:04}"), mark("loud", 100 + i as u64));
        }
        b.keep_left("new", mark("quiet", 10_000));
        assert_eq!(b.stored.left.len(), LEFT_CAP);
        assert!(b.stored.left.contains_key("quiet-old"), "the quiet device's old mark stays");
        assert!(!b.stored.left.contains_key("loud-0000"), "the busiest device's oldest mark goes");
    }

    /// A hand-off never lands a leave while an owner can answer for it; without one,
    /// every other member handed the op is the most there is.
    #[test]
    fn a_leave_lands_on_the_owners_word_alone() {
        let mut p = PendingLeave { owner: Some("o".into()), targets: vec!["o".into(), "x".into()], ..Default::default() };
        p.reached.extend(["o".to_string(), "x".to_string()]);
        assert!(!p.landed(), "an owner handed the op is not an owner holding it");
        let mut ownerless = PendingLeave { targets: vec!["x".into(), "y".into()], ..Default::default() };
        ownerless.reached.insert("x".into());
        assert!(!ownerless.landed());
        ownerless.reached.insert("y".into());
        assert!(ownerless.landed());
    }

    fn signed(tag: u8, ms: u64, payload: CrdtPayload) -> CrdtOp {
        signed_in("S", tag, ms, payload)
    }

    fn signed_in(sid: &str, tag: u8, ms: u64, payload: CrdtPayload) -> CrdtOp {
        let (kp, id, pk) = crate::crdt::testkeys::keys(tag);
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

    /// Our leave of S, made at 1000, waiting on owner 1's word; we asked with nonce 7.
    fn waiting(us: &str) -> (LeaveBook, CrdtOp) {
        let leave = signed(2, 1_000, CrdtPayload::MemberRemoved { peer_id: us.into(), seen: None });
        let mut b = book();
        b.stored.pending.insert(
            "S".into(),
            PendingLeave {
                op_json: serde_json::to_string(&leave).unwrap(),
                owner: Some(crate::crdt::testkeys::keys(1).1),
                left_hlc: Some(leave.hlc.clone()),
                ..Default::default()
            },
        );
        let mut probe = Probe::new();
        probe.nonces.push_back(7);
        b.probes.insert("S".into(), probe);
        (b, leave)
    }

    /// Only the owner's answer to our own ask lands a leave, and only when it ends our
    /// membership at or after the leave, or closes the server to us.
    #[test]
    fn only_the_owners_answer_to_our_ask_lands_a_leave() {
        let owner = crate::crdt::testkeys::keys(1).1;
        let us = crate::crdt::testkeys::keys(2).1;
        let x = crate::crdt::testkeys::keys(3).1;
        let json = |ops: &[&CrdtOp]| serde_json::to_string(ops).unwrap();
        let (mut b, leave) = waiting(&us);
        let notice = json(&[&leave]);
        assert!(!b.on_answer("S", &notice, Some(8), &owner, &us), "an answer to no ask of ours");
        assert!(!b.on_answer("S", &notice, None, &owner, &us), "an answer to no ask at all");
        assert!(!b.on_answer("S", &notice, Some(7), &x, &us), "a member who is not the owner");
        assert!(!b.on_answer("T", &notice, Some(7), &owner, &us), "another server's answer");
        assert!(!b.on_answer("S", "[]", Some(7), &owner, &us), "a member's answer: the owner still counts us");
        let older = signed(1, 500, CrdtPayload::MemberRemoved { peer_id: us.clone(), seen: None });
        assert!(!b.on_answer("S", &json(&[&older]), Some(7), &owner, &us), "a removal from before our leave");
        let other = signed(1, 2_000, CrdtPayload::MemberRemoved { peer_id: x.clone(), seen: None });
        assert!(!b.on_answer("S", &json(&[&other]), Some(7), &owner, &us), "someone else's removal");
        let mut forged = leave.clone();
        forged.hlc.physical_ms += 1;
        assert!(!b.on_answer("S", &json(&[&forged]), Some(7), &owner, &us), "a removal its signature does not cover");
        let elsewhere = signed_in("T", 2, 1_000, CrdtPayload::MemberRemoved { peer_id: us.clone(), seen: None });
        assert!(!b.on_answer("S", &json(&[&elsewhere]), Some(7), &owner, &us), "a removal from another server");
        assert!(b.stored.pending.contains_key("S"));
        assert!(b.on_answer("S", &json(&[&other, &leave]), Some(7), &owner, &us), "the owner's notice of our leave");
        assert!(!b.stored.pending.contains_key("S"), "a leave the owner holds stays pending");

        let (mut b, _) = waiting(&us);
        let ban = signed(1, 1_500, CrdtPayload::MemberBanned { peer_id: us.clone(), seen: None });
        assert!(b.on_answer("S", &json(&[&ban, &older]), Some(7), &owner, &us), "the owner's ban of us closes the server to us");
        let (mut b, _) = waiting(&us);
        let deleted = signed(1, 900, CrdtPayload::ServerDeleted { deleted_at: 900 });
        assert!(b.on_answer("S", &json(&[&deleted]), Some(7), &owner, &us), "the owner's deletion closes it");
    }

    /// F2 of the w2-d re-check: a new ask names the leave members' folds end our membership
    /// at (the first one at or past the ask that opened it, whichever device made it) and is
    /// stamped past the newest leave we hold. A leave from an earlier membership, or one a
    /// sibling's rejoin came before, moves the named leave as the fold would.
    #[test]
    fn a_new_ask_names_the_leave_that_ended_our_membership() {
        let us = crate::crdt::testkeys::keys(2).1;
        let leave = |ms: u64| signed(2, ms, CrdtPayload::MemberRemoved { peer_id: us.clone(), seen: None });
        let floor = |b: &LeaveBook| {
            let f = b.ask_floor("S");
            (f.follows.map(|c| c.physical_ms), f.past_ms)
        };
        let mut b = book();
        b.begin("S", &leave(1_000), None, Vec::new(), None, "dev-a", Some(900));
        assert_eq!(floor(&b), (Some(1_000), Some(1_000)));
        b.note_left("S", &leave(1_005), "dev-b", None);
        assert_eq!(floor(&b), (Some(1_000), Some(1_005)), "a sibling's later leave of the same membership changes no name");
        b.note_left("S", &leave(995), "dev-b", None);
        assert_eq!(floor(&b), (Some(995), Some(1_005)), "a sibling's earlier leave of it ended it first");
        b.note_left("S", &leave(850), "dev-b", None);
        assert_eq!(floor(&b), (Some(995), Some(1_005)), "a leave from before the ask that opened it ended an earlier one");
        b.note_left("S", &leave(1_200), "dev-b", Some(1_200));
        assert_eq!(floor(&b), (Some(1_200), Some(1_200)), "a leave after a sibling's rejoin ends that membership");
        b.forget_left("S");
        assert_eq!(b.ask_floor("S"), AskFloor::default());

        // A member that still holds the server names its membership's ask with the leave.
        let mut b = book();
        b.note_left("S", &leave(700), "dev-b", None);
        b.note_left("S", &leave(1_100), "dev-b", Some(1_000));
        assert_eq!(floor(&b), (Some(1_100), Some(1_100)), "the first leave of a newer membership");

        // Our own leave of a span saved before asks were kept names itself.
        let mut b = book();
        b.note_left("S", &leave(500), "dev-b", None);
        b.begin("S", &leave(1_000), None, Vec::new(), None, "dev-a", Some(0));
        assert_eq!(floor(&b), (Some(1_000), Some(1_000)));

        // A book saved before the named leave was kept names its newest leave, and learns.
        let old = format!(r#"{{"left":{{"S":{{"op_json":{},"from":"dev-b","at_ms":1000}}}}}}"#, serde_json::to_string(&serde_json::to_string(&leave(1_000)).unwrap()).unwrap());
        let mut b = book();
        b.stored = serde_json::from_str(&old).expect("an old book loads");
        assert_eq!(floor(&b), (Some(1_000), Some(1_000)));
        b.note_left("S", &leave(990), "dev-b", None);
        assert_eq!(floor(&b), (Some(990), Some(1_000)));
    }

    /// Only the recorded owner's own signed deletion, or its removal or ban of us, ends a
    /// pending leave, whoever hands it on.
    #[test]
    fn only_the_owner_closes_a_pending_leave() {
        let us = crate::crdt::testkeys::keys(2).1;
        let x = crate::crdt::testkeys::keys(3).1;
        let closes = |op: CrdtOp| waiting(&us).0.owner_closed("S", &serde_json::to_string(&op).unwrap(), &us);
        assert!(!closes(signed(3, 900, CrdtPayload::ServerDeleted { deleted_at: 900 })), "a member's deletion");
        assert!(!closes(signed(3, 900, CrdtPayload::MemberBanned { peer_id: us.clone(), seen: None })), "a member's ban");
        assert!(!closes(signed(1, 900, CrdtPayload::MemberRemoved { peer_id: x.clone(), seen: None })), "the owner removing someone else");
        assert!(!closes(signed(1, 900, CrdtPayload::ServerRenamed { new_name: "n".into() })), "an op that closes nothing");
        assert!(!closes(signed(1, 900, CrdtPayload::MemberBanned { peer_id: us.clone(), seen: None })), "a ban from before our leave");
        assert!(!closes(signed_in("T", 1, 1_500, CrdtPayload::ServerDeleted { deleted_at: 900 })), "another server's deletion");
        let mut unsigned = signed(1, 900, CrdtPayload::ServerDeleted { deleted_at: 900 });
        unsigned.auth = None;
        assert!(!closes(unsigned), "an unsigned deletion");
        assert!(closes(signed(1, 900, CrdtPayload::ServerDeleted { deleted_at: 900 })));
        assert!(closes(signed(1, 1_001, CrdtPayload::MemberRemoved { peer_id: us.clone(), seen: None })));
        assert!(closes(signed(1, 1_500, CrdtPayload::MemberBanned { peer_id: us.clone(), seen: None })));
    }
}
