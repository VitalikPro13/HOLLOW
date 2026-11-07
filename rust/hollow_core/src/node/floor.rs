//! Section 8.8 at the node: the hold's teardown layer, the trigger leaves, the member
//! banner, and the floor desk the sync answers feed (INTERFACE item 6).

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::crdt::operations::CrdtOp;

use crate::crdt::hold::Teardown;
use crate::crdt::server_state::ServerState;
use crate::crypto::{CryptoStore, MlsManager};

/// The floor rounds this device runs (8.8 item 1) and the marks it already sent live.
#[derive(Debug, Default)]
pub(crate) struct FloorDesk {
    rounds: HashMap<String, RoundAsk>,
    sent: BTreeSet<(String, crate::crdt::fold::OpKey)>,
    /// A shell's direct asks (R34-2): when the next one goes, and the gap after it.
    shells: HashMap<String, (Instant, Duration)>,
    /// Our settlings still handing their door to the members they brought back.
    grants: HashMap<String, SettleGrant>,
}

/// A settling of ours and the masters it made members again (R34-2).
#[derive(Debug)]
struct SettleGrant {
    masters: BTreeSet<String>,
    ops: Vec<CrdtOp>,
    /// (device, door) pairs already handed.
    sent: BTreeSet<(String, u64)>,
    until: Instant,
}

/// How long a settler keeps handing the door it moved to (the move lands after the
/// settling) to devices it can reach.
const GRANT_FOR: Duration = Duration::from_secs(10 * 60);

/// A shell's first direct ask waits this long, then the gap doubles up to `SHELL_MAX`.
const SHELL_FIRST: Duration = Duration::from_secs(30);
const SHELL_MAX: Duration = Duration::from_secs(30 * 60);
/// Devices one shell round asks.
const SHELL_ASKED: usize = 8;

#[derive(Debug)]
struct RoundAsk {
    started: Instant,
    asked: bool,
    /// The devices the round asked: only their answers count.
    devices: BTreeSet<String>,
    identities: BTreeSet<String>,
    answers: Vec<CrdtOp>,
}

/// H4: a round ends once this many other identities answered, or after `ROUND_MAX`.
const ROUND_IDENTITIES: usize = 2;
const ROUND_MAX: Duration = Duration::from_secs(10);
/// Identities a round asks, by standing in our own state.
const ROUND_ASKED: usize = 4;
/// `floor_base`s one round keeps (each one checked as a base when the round ends).
const ROUND_ANSWERS: usize = 16;

impl FloorDesk {
    /// A lock move in `server_id` or a roster notice of its owner: the shell asks again
    /// on the first gap (R34-2).
    pub(crate) fn reset_shell(&mut self, server_id: &str, now: Instant) {
        if let Some(next) = self.shells.get_mut(server_id) {
            *next = (now + SHELL_FIRST, SHELL_FIRST);
        }
    }

    /// [`Self::reset_shell`] for every shell whose server `owner` owns.
    pub(crate) fn reset_shells_of_owner(&mut self, server_states: &HashMap<String, ServerState>, owner: &str, now: Instant) {
        let owned: Vec<String> = self.shells.keys().filter(|sid| server_states.get(*sid).is_some_and(|s| s.anchor_owner().as_deref() == Some(owner))).cloned().collect();
        for sid in owned {
            self.reset_shell(&sid, now);
        }
    }

    /// Our settling `ops` of `server_id` brought `masters` back as members: hand each of
    /// their devices the settling and the newest door, directly, for `GRANT_FOR`.
    pub(crate) fn note_settled(&mut self, server_id: &str, masters: BTreeSet<String>, ops: Vec<CrdtOp>, now: Instant) {
        if masters.is_empty() || ops.is_empty() {
            return;
        }
        self.grants.insert(server_id.to_string(), SettleGrant { masters, ops, sent: BTreeSet::new(), until: now + GRANT_FOR });
    }

    /// A `floor_base` an answer carried, from device `from`, for `server_id`. `identity`
    /// is the master our view places `from` under (`server_rosters::place`): an unplaced
    /// device, one of ours or one the round did not ask never counts toward H4's wait.
    pub(crate) fn candidate(&mut self, server_id: &str, from: &str, identity: Option<String>, local_master: &str, op: CrdtOp) {
        let Some(round) = self.rounds.get_mut(server_id) else { return };
        let Some(identity) = identity.filter(|m| m != local_master && round.devices.contains(from)) else { return };
        round.identities.insert(identity);
        if round.answers.len() < ROUND_ANSWERS && !round.answers.iter().any(|o| o.content_hash() == op.content_hash()) {
            round.answers.push(op);
        }
    }
}

/// Run the floor rounds (8.8 item 1): ask the room's members in standing order with the
/// floor flag, end each round after two identities answered or 10 s, and mark after a
/// restart that lost the round. Returns, per server, our own new marks with their pins
/// (the pin first), for the live send.
#[allow(clippy::too_many_arguments)]
pub(crate) fn drive(
    crdt_resync: &mut super::crdt_resync::CrdtResync,
    server_states: &mut HashMap<String, ServerState>,
    frame_budget: &mut super::frame_budget::FrameBudget,
    ws_cmd_tx: &super::types::WsCmdTx,
    ws_room_peers: &super::types::WsRoomPeers,
    local_peer_str: &str,
    device_peer_id: &str,
    crdt_store: &super::crdt_store::CrdtStore,
    now: Instant,
) -> Vec<(String, Vec<CrdtOp>)> {
    crdt_resync.floor.rounds.retain(|sid, _| server_states.get(sid).is_some_and(ServerState::floor_round_open));
    let mut out = Vec::new();
    for (sid, state) in server_states.iter_mut() {
        let ingested = if state.floor_round_open() {
            let round = crdt_resync.floor.rounds.entry(sid.clone()).or_insert_with(|| RoundAsk { started: now, asked: false, devices: BTreeSet::new(), identities: BTreeSet::new(), answers: Vec::new() });
            if !round.asked {
                round.asked = true;
                let devices = round_devices(state, ws_room_peers.get(sid), local_peer_str);
                round.devices.extend(devices.iter().cloned());
                for device in devices {
                    let ask = floor_ask(crdt_resync.sync_ask(state, &device, None, None));
                    super::frame_budget::pace_carried(frame_budget, ws_cmd_tx, device_peer_id, &device, &ask);
                }
                continue;
            }
            let round = &crdt_resync.floor.rounds[sid];
            if round.identities.len() < ROUND_IDENTITIES && now.saturating_duration_since(round.started) < ROUND_MAX {
                continue;
            }
            let answers = crdt_resync.floor.rounds.remove(sid).map(|r| r.answers).unwrap_or_default();
            let ended = state.end_floor_round(&answers);
            // Marks that reached us while the round judged under the previous view were
            // dropped with our then eligible base: ask the round's members again for them.
            for device in round_devices(state, ws_room_peers.get(sid), local_peer_str) {
                let ask = crdt_resync.sync_ask(state, &device, None, None);
                super::frame_budget::pace_carried(frame_budget, ws_cmd_tx, device_peer_id, &device, &ask);
            }
            ended
        } else {
            state.mark_after_restart()
        };
        if let Some(ingested) = ingested {
            crdt_store.persist(ingested.delta(sid));
            crdt_store.save_state_snapshot(sid.clone(), state);
        }
        let ours: Vec<CrdtOp> = state
            .stored
            .iter()
            .filter(|(o, k)| *k == crate::crdt::fold::RowKind::FloorMark && o.proven_device() == Some(device_peer_id))
            .map(|(o, _)| o.clone())
            .filter(|o| !crdt_resync.floor.sent.contains(&(sid.clone(), (o.author.clone(), o.hlc.clone()))))
            .collect();
        let mut send = Vec::new();
        for mark in ours {
            crdt_resync.floor.sent.insert((sid.clone(), (mark.author.clone(), mark.hlc.clone())));
            let crate::crdt::operations::CrdtPayload::FloorMark { cp } = &mark.payload else { continue };
            send.extend(crate::crdt::authority::base_content_for(state, cp));
            send.push(mark);
        }
        if !send.is_empty() {
            out.push((sid.clone(), send));
        }
    }
    out
}

/// A shell reaches the settling by itself (8.8 class 2, R34-2): the relay may hide us
/// and every co-member's hold excludes us, so a direct sync ask goes over heard routes to
/// the owner's devices and the SEAT's, at most 8 by standing, after 30 s and then at a
/// doubling gap up to 30 minutes.
#[allow(clippy::too_many_arguments)]
pub(crate) fn drive_shells(
    crdt_resync: &mut super::crdt_resync::CrdtResync,
    server_states: &HashMap<String, ServerState>,
    frame_budget: &mut super::frame_budget::FrameBudget,
    ws_cmd_tx: &super::types::WsCmdTx,
    ws_room_peers: &super::types::WsRoomPeers,
    local_peer_str: &str,
    device_peer_id: &str,
    now: Instant,
) -> usize {
    let shells: Vec<&String> = server_states.iter().filter(|(_, s)| s.recovery.as_ref().is_some_and(|r| r.shell.is_some())).map(|(sid, _)| sid).collect();
    crdt_resync.floor.shells.retain(|sid, _| shells.contains(&sid));
    let mut asked = 0;
    for sid in shells {
        let (at, gap) = *crdt_resync.floor.shells.entry(sid.clone()).or_insert((now + SHELL_FIRST, SHELL_FIRST));
        if now < at {
            continue;
        }
        let next = (gap * 2).min(SHELL_MAX);
        crdt_resync.floor.shells.insert(sid.clone(), (now + next, next));
        let state = &server_states[sid];
        for device in shell_devices(state, ws_room_peers, local_peer_str) {
            let ask = crdt_resync.sync_ask(state, &device, None, None);
            super::frame_budget::pace_carried(frame_budget, ws_cmd_tx, device_peer_id, &device, &ask);
            asked += 1;
        }
    }
    asked
}

/// Our live marks also go, in Olm, to the members KEEP holds that the fold no longer
/// counts: in a step back the member fan-out reads a fold that may count no one.
pub(crate) fn carry_marks_to_keep(
    state: &ServerState,
    ops: &[CrdtOp],
    ws_cmd_tx: &super::types::WsCmdTx,
    ws_room_peers: &super::types::WsRoomPeers,
    local_peer_str: &str,
) {
    let Some(r) = state.recovery.as_deref() else { return };
    let held: Vec<String> = r.pre.members.keys().filter(|m| !state.is_member(m) && state.keeps_peer(m)).cloned().collect();
    for op in ops {
        let Ok(op_json) = serde_json::to_string(op) else { continue };
        let msg = super::types::HavenMessage::CrdtOpBroadcast { server_id: state.server_id.clone(), op_json };
        let Some(json) = super::olm_lane::carried_json(&msg) else { continue };
        super::olm_lane::carry_to_identities(ws_cmd_tx, ws_room_peers, held.iter(), local_peer_str, &json, super::olm_lane::NoSession::Queue);
    }
}

/// The masters a settling makes members that the pre-settling state (`before`: its
/// base's content and fold) did not count, ours excluded: a shell among them is hidden
/// and every co-member's hold excludes it (8.8 class 2, R34-2).
pub(crate) fn settled_newcomers(before: &BTreeSet<String>, after: &ServerState, us: &str) -> BTreeSet<String> {
    after.members.keys().filter(|m| !before.contains(*m) && !super::resolver::same_identity(m, us)).cloned().collect()
}

/// The members `state` counts in both its base's content and its fold: what a settling
/// is judged against for [`settled_newcomers`].
pub(crate) fn counted_members(state: &ServerState) -> BTreeSet<String> {
    state.members.keys().filter(|m| state.base.as_ref().is_none_or(|b| b.state.is_member(m))).cloned().collect()
}

/// Hand our settlings and their newest door to the members they brought back, once per
/// (device, door), over heard routes: the settling rides the Olm lane, the grant goes
/// into the server room as a direct, which reaches a device the relay hides.
pub(crate) fn drive_grants(
    crdt_resync: &mut super::crdt_resync::CrdtResync,
    server_states: &HashMap<String, ServerState>,
    ws_cmd_tx: &super::types::WsCmdTx,
    ws_room_peers: &super::types::WsRoomPeers,
    device_peer_id: &str,
    now: Instant,
) -> usize {
    crdt_resync.floor.grants.retain(|sid, g| now < g.until && server_states.contains_key(sid));
    let mut handed = 0;
    for (sid, grant) in crdt_resync.floor.grants.iter_mut() {
        let Some((n, _, secret)) = server_states[sid].join_lock.newest_door() else { continue };
        let devices: BTreeSet<String> = grant
            .masters
            .iter()
            .flat_map(|m| super::resolver::devices_for(m).into_iter().chain(super::crypto_handler::online_devices_for(ws_room_peers, m)))
            .filter(|d| !super::resolver::is_bare_master(d) && !super::resolver::is_revoked(d))
            .collect();
        for device in devices {
            if grant.sent.contains(&(device.clone(), n)) {
                continue;
            }
            let Some(room) = super::crypto_handler::send_room_for_peer(ws_room_peers, &device) else { continue };
            let Some(data) = super::door_room::grant_frame(sid, n, secret.as_slice(), &device, device_peer_id) else { continue };
            for op in &grant.ops {
                let Ok(op_json) = serde_json::to_string(op) else { continue };
                let msg = super::types::HavenMessage::CrdtOpBroadcast { server_id: sid.clone(), op_json };
                super::olm_lane::carry(ws_cmd_tx, &device, Some(&room), &msg, super::olm_lane::NoSession::Queue);
            }
            crate::hollow_log!("[HOLLOW-CRDT] Handing our settling of {sid} and door {n} to {device}, a member it brought back");
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect { room_code: sid.clone(), target_peer: device.clone(), data });
            grant.sent.insert((device, n));
            handed += 1;
        }
    }
    handed
}

/// The owner's devices first, then the SEAT's by standing, each reachable over a heard
/// route, at most `SHELL_ASKED`.
fn shell_devices(state: &ServerState, ws_room_peers: &super::types::WsRoomPeers, local_peer_str: &str) -> Vec<String> {
    let Some(r) = state.recovery.as_deref() else { return Vec::new() };
    let seat = r.pre.members.keys().filter(|m| state.recovery_hold(None, m) == crate::crdt::hold::Hold::Seat).cloned();
    let owner = state.anchor_owner();
    let mut masters: Vec<String> = owner.clone().into_iter().collect();
    masters.extend(super::standing::rank_masters(state, seat).into_iter().filter(|m| owner.as_ref() != Some(m)));
    masters
        .iter()
        .filter(|m| !super::resolver::same_identity(m, local_peer_str))
        .flat_map(|m| super::resolver::devices_for(m))
        .filter(|d| super::crypto_handler::send_room_for_peer(ws_room_peers, d).is_some())
        .take(SHELL_ASKED)
        .collect()
}

/// One device per identity of the room's members (the fold's or KEEP's), ours excluded,
/// by standing.
fn round_devices(state: &ServerState, room: Option<&HashSet<String>>, local_peer_str: &str) -> Vec<String> {
    let mut room: Vec<&String> = room.into_iter().flatten().filter(|d| state.keeps_peer(d) && !super::resolver::same_identity(d, local_peer_str)).collect();
    room.sort();
    let masters = room.iter().map(|d| super::resolver::resolve(d));
    super::standing::rank_masters(state, masters)
        .into_iter()
        .take(ROUND_ASKED)
        .filter_map(|m| room.iter().find(|d| super::resolver::resolve(d) == m).map(|d| (*d).clone()))
        .collect()
}

/// `ask` as a floor round's: the answer carries the answerer's `floor_base`.
fn floor_ask(mut ask: crate::node::types::HavenMessage) -> crate::node::types::HavenMessage {
    if let crate::node::types::HavenMessage::SyncRequest { x, .. } = &mut ask {
        let mut ext = x.take().map(|b| *b).unwrap_or_default();
        ext.floor = true;
        *x = ext.boxed();
    }
    ask
}

fn write_row(state: &ServerState, crdt_store: &super::crdt_store::CrdtStore) {
    let Some(row) = state.recovery.as_ref().and_then(|r| r.to_json()) else { return };
    crdt_store.persist(Some(crate::crdt::fold::OpDelta {
        server_id: state.server_id.clone(),
        rows: Vec::new(),
        dropped: Vec::new(),
        base: None,
        seen_keep: None,
        own_since: Vec::new(),
        recovery: Some(Some(row)),
    }));
}

/// The second layer of the hold (8.8 class 2): true when nothing may tear `server_id`
/// down for a removal of us now. A kick or ban the hold does not tear down for leaves a
/// SHELL: our MLS groups for the server go, its state, row and room stay.
pub(crate) fn holds_server(
    server_states: &mut HashMap<String, ServerState>,
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    crdt_store: &super::crdt_store::CrdtStore,
    server_id: &str,
) -> bool {
    let Some(state) = server_states.get_mut(server_id) else { return false };
    let Some(us) = state.hlc.as_ref().map(|h| h.actor().to_string()) else { return false };
    let by = match state.recovery_teardown(&us) {
        Teardown::Go => return false,
        Teardown::Keep => return true,
        Teardown::Shell(by) => by,
    };
    let Some(mut r) = state.recovery.as_deref().cloned() else { return false };
    crate::hollow_log!("[HOLLOW-CRDT] Removed from {server_id} during its recovery: kept as a shell until it settles");
    r.shell = Some(by);
    state.recovery = Some(Arc::new(r));
    write_row(state, crdt_store);
    let subs = state.subgroup_channel_ids();
    if let Some(mgr) = mls.as_mut() {
        for gk in std::iter::once(server_id.to_string()).chain(subs.iter().map(|c| crate::crypto::subgroup_id(server_id, c))) {
            if mgr.has_group(&gk) {
                mgr.remove_group(&gk);
            }
        }
        super::crypto_handler::persist_mls_state(mgr, crypto_store);
    }
    true
}

/// Record the trigger leaves (8.8 item 1, R34-3) of every server whose recovery has
/// none yet: per group, the certified masters holding a bound leaf there now.
pub(crate) fn note_trigger_leaves(
    server_states: &mut HashMap<String, ServerState>,
    mls: &Option<MlsManager>,
    crdt_store: &super::crdt_store::CrdtStore,
) {
    for state in server_states.values_mut() {
        let Some(r) = state.recovery.as_deref() else { continue };
        if r.leaves.is_some() {
            continue;
        }
        let mut leaves: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
        let sid = state.server_id.clone();
        let groups = std::iter::once((String::new(), sid.clone()))
            .chain(r.pre.subgroup_channel_ids().into_iter().map(|c| (c.clone(), crate::crypto::subgroup_id(&sid, &c))));
        for (key, gk) in groups {
            let masters: BTreeSet<String> = mls
                .as_ref()
                .filter(|m| m.has_group(&gk))
                .map(|m| m.group_leaves(&gk).iter().filter_map(|l| l.bound().map(|i| i.master.clone())).collect())
                .unwrap_or_default();
            leaves.insert(key, masters);
        }
        let mut r = r.clone();
        r.leaves = Some(leaves);
        state.recovery = Some(Arc::new(r));
        write_row(state, crdt_store);
    }
}

/// The member banner of one server (`api::device_proof::server_recovery`).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct RecoverySnap {
    pub(crate) stepped_back: bool,
    pub(crate) removed_by: Option<String>,
}

/// Per local device, per server in recovery (one node per process in the app).
static SNAPSHOT: std::sync::LazyLock<std::sync::Mutex<HashMap<String, HashMap<String, RecoverySnap>>>> = std::sync::LazyLock::new(Default::default);

/// Publish every server's banner and return the servers whose banner changed: each gets
/// a `ServerUpdated` (INTERFACE item 4: no banner sticks).
pub(crate) fn publish(server_states: &HashMap<String, ServerState>, device_id: &str) -> Vec<String> {
    let now: HashMap<String, RecoverySnap> = server_states
        .iter()
        .filter_map(|(sid, s)| {
            let r = s.recovery.as_deref()?;
            Some((sid.clone(), RecoverySnap { stepped_back: !s.floor_holds(), removed_by: r.shell.clone() }))
        })
        .collect();
    let mut all = SNAPSHOT.lock().unwrap_or_else(|e| e.into_inner());
    let before = all.remove(device_id).unwrap_or_default();
    let mut changed: Vec<String> = now.iter().filter(|(sid, snap)| before.get(*sid) != Some(snap)).map(|(sid, _)| sid.clone()).collect();
    changed.extend(before.keys().filter(|sid| !now.contains_key(*sid) && server_states.contains_key(*sid)).cloned());
    if !now.is_empty() {
        all.insert(device_id.to_string(), now);
    }
    changed
}

/// The banner for `server_id` as the running node last published it.
pub(crate) fn snapshot(server_id: &str) -> RecoverySnap {
    let all = SNAPSHOT.lock().unwrap_or_else(|e| e.into_inner());
    all.values().find_map(|m| m.get(server_id).cloned()).unwrap_or_default()
}


#[cfg(test)]
#[path = "floor_review_b_tests.rs"]
mod review_b_tests;
