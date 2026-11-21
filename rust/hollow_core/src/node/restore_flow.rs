//! A fresh install restores the servers it owns after a phrase recovery
//! (DEVICE_PROOF_DESIGN section 8.4): which servers, whom it asks, how the witnesses are
//! judged, the chooser's snapshot and the settling the person's choice writes.

use std::collections::HashMap;

use super::types::{EventTx, ServerStates, WsCmdTx, WsRoomPeers};
use super::witness::{CpFacts, Seen, Stage, WitnessDesk};
use crate::crdt::operations::CrdtOp;
use crate::crdt::server_state::ServerState;
use crate::storage::messages::MessageStore;

/// How often the server list is checked for servers to restore.
const REGISTER_EVERY_MS: i64 = 5_000;
/// Answers a restore round waits for before it settles, at most this long.
const ROUND_WAIT_MS: i64 = 10_000;

fn done_key(server_id: &str, base: &str) -> String {
    format!("restore_done:{server_id}:{base}")
}

/// T and the time of our identity's current recovery, when the person answered the
/// recovery's question here.
fn recovery(store: &MessageStore, local_master: &str) -> Option<(String, i64, i64)> {
    let roster = store.load_roster(local_master).ok().flatten()?;
    let at = roster.recoveries.iter().map(|r| r.at_ms).max()?;
    let base = roster.base();
    let t = super::roster_book::recovery_lost_since(store, &base)?;
    Some((base, t, at))
}

/// `app_settings` prefix of a server we own that a lost-or-stolen removal could not
/// settle from our records (first held here at or after T): `lost_restore:{sid}` holds
/// T and the members our state named before the removal, whom the witness desk asks
/// (once the lost device stops counting, our own state may name nobody else). This
/// device's own row, never in a copy.
pub(crate) const LOST_RESTORE: &str = "lost_restore:";

#[derive(serde::Serialize, serde::Deserialize)]
struct LostRestore {
    t_ms: i64,
    #[serde(default)]
    members: Vec<String>,
}

fn lost_restore(store: &MessageStore, server_id: &str) -> Option<LostRestore> {
    serde_json::from_str(&store.load_setting(&format!("{LOST_RESTORE}{server_id}")).ok()??).ok()
}

/// Whether this device held `state` before `at`: a first fold or a stored op from before.
/// A device that did not holds no record of what the server decided before `at`, so it
/// never settles the server from its own records (HOL-SEC-216).
pub(crate) fn held_before(store: &MessageStore, state: &ServerState, at: i64) -> bool {
    state.first_folds.values().any(|f| (*f as i64) < at) || store.op_first_seen_ms(&state.server_id).is_some_and(|ms| (ms as i64) < at)
}

/// Whether a settling with the answered `t_ms` may stand on this device's records of
/// `state`. "Not sure" (0) names no moment: each server's T is then the oldest restore
/// point held here (`ServerState::lost_t`), which our records hold by definition.
pub(crate) fn records_reach_t(store: &MessageStore, state: &ServerState, t_ms: i64) -> bool {
    t_ms <= 0 || held_before(store, state, t_ms)
}

/// Of a recovery answered with `t_ms` and signed at `at`, whether this device settles
/// `state` from its records (else a server we own restores from witnesses, `register`):
/// held before T; for "not sure", held before the recovery itself (DEVICE_PROOF_DESIGN
/// 8.1: a fresh install, holding no restore point, gets the chooser).
fn recovery_settles_here(store: &MessageStore, state: &ServerState, t_ms: i64, at: i64) -> bool {
    held_before(store, state, if t_ms > 0 { t_ms } else { at })
}

/// Section 8.1: a phrase recovery treats every device it drops as lost or stolen since
/// its T. Of the servers this device held before the recovery (the rest restore from
/// witnesses, `register`), the views from before the drop, to settle them (section
/// 8.3), and T; None when no recovery recorded its T.
pub(crate) fn held_before_recovery(
    server_states: &ServerStates,
    store: &MessageStore,
    local_master: &str,
    dropped: &[String],
) -> Option<(HashMap<String, std::sync::Arc<crate::crdt::authority::AuthorityView>>, u64)> {
    let (_, t_ms, at) = recovery(store, local_master)?;
    let views = server_states
        .iter()
        .filter(|(_, s)| recovery_settles_here(store, s, t_ms, at))
        .map(|(sid, s)| (sid.clone(), s.view_counting(local_master, dropped)))
        .collect();
    Some((views, t_ms.max(0) as u64))
}

/// Note that `state`, a server we own, restores from witnesses since `t_ms`: a lost
/// removal found no record of it here from before T. The older T wins.
pub(crate) fn note_lost_restore(store: &MessageStore, state: &ServerState, local_master: &str, t_ms: i64) {
    if lost_restore(store, &state.server_id).is_some_and(|held| held.t_ms <= t_ms) {
        return;
    }
    let members = state.members.keys().filter(|m| m.as_str() != local_master).take(super::union_list::MAX_ASKED).cloned().collect();
    if let Ok(json) = serde_json::to_string(&LostRestore { t_ms, members }) {
        let _ = store.save_setting(&format!("{LOST_RESTORE}{}", state.server_id), &json);
    }
}

/// Mark for restore every server we own that this device first held at or after the T
/// of our current recovery or of a lost removal (it holds no record from before, so
/// section 8.3 cannot settle it here) and has not settled yet.
pub(crate) fn register(desk: &mut WitnessDesk, server_states: &ServerStates, store: &MessageStore, local_master: &str) {
    let ours = |sid: &str, state: &ServerState| {
        state.anchor_owner().as_deref() == Some(local_master) && !super::conference::is_conference_sid(sid) && !state.is_deleted()
    };
    if let Some((base, t_ms, at)) = recovery(store, local_master) {
        for (sid, state) in server_states {
            if !ours(sid, state) || recovery_settles_here(store, state, t_ms, at) || store.load_setting(&done_key(sid, &base)).ok().flatten().is_some() {
                continue;
            }
            desk.recover(sid, t_ms);
        }
    }
    for (key, _) in store.load_settings_with_prefix(LOST_RESTORE).unwrap_or_default() {
        let Some(sid) = key.strip_prefix(LOST_RESTORE) else { continue };
        let (Some(row), Some(state)) = (lost_restore(store, sid), server_states.get(sid)) else { continue };
        if ours(sid, state) && !records_reach_t(store, state, row.t_ms) {
            desk.recover(sid, row.t_ms);
        }
    }
}

/// The contents the witnesses named that check as bases of the server: signed by our
/// identity with a device proof, at most [`super::witness::CONTENTS_MAX`] and
/// [`super::witness::CONTENT_BYTES_MAX`] in step 2's order.
fn checked_contents(state: &ServerState, seen: &[Seen], contents: &HashMap<String, CrdtOp>, contact: &dyn Fn(&str) -> bool, me: &str) -> HashMap<String, CpFacts> {
    let mut facts = HashMap::new();
    let mut bytes = 0usize;
    for cp in super::witness::content_order(seen, contact) {
        if facts.len() >= super::witness::CONTENTS_MAX {
            break;
        }
        let Some(op) = contents.get(&cp) else { continue };
        if op.author != me || op.verify_author().is_err() || op.proven_device().is_none() {
            continue;
        }
        let size = serde_json::to_string(op).map(|j| j.len()).unwrap_or(usize::MAX);
        if bytes.saturating_add(size) > super::witness::CONTENT_BYTES_MAX {
            continue;
        }
        if let Some(base) = state.base_of_content(op).filter(|b| hex::encode(b.hash) == cp) {
            bytes += size;
            facts.insert(cp, CpFacts::of(&base));
        }
    }
    facts
}

/// Judge `server_id` again over what arrived (steps 1 to 6) and return the identities
/// the checked contents name, for the next asks.
fn rejudge(desk: &mut WitnessDesk, state: &ServerState, store: &MessageStore, db_path: &str, contacts: &std::collections::HashSet<String>, me: &str, now_ms: i64) -> Vec<String> {
    let sid = state.server_id.clone();
    let mut seen = Vec::new();
    let mut contents: HashMap<String, CrdtOp> = HashMap::new();
    for (w, content, at) in desk.taken(&sid) {
        let Some(identity) = super::server_rosters::place(store, db_path, state, &w.by) else { continue };
        if identity == me {
            continue;
        }
        if let Some(op) = content {
            contents.entry(w.cp.clone()).or_insert_with(|| op.clone());
        }
        seen.push(Seen { identity, cp: w.cp.clone(), folded_age_ms: w.folded_age_ms, received_ms: *at });
    }
    let facts = checked_contents(state, &seen, &contents, &|m| contacts.contains(m), me);
    let mut named: Vec<String> = facts.values().flat_map(|f| f.members.iter().cloned()).collect();
    named.sort();
    named.dedup();
    desk.update(&sid, super::witness::judge(&seen, &facts), now_ms);
    desk.keep_contents(&sid, contents.into_iter().filter(|(cp, _)| facts.contains_key(cp)).collect());
    named
}

/// One step of every restore: register, judge, ask, and settle a choice whose round ended.
#[allow(clippy::too_many_arguments)]
pub(crate) fn tick(
    crdt_resync: &mut super::crdt_resync::CrdtResync,
    server_states: &mut ServerStates,
    frame_budget: &mut super::frame_budget::FrameBudget,
    mls: &mut Option<crate::crypto::MlsManager>,
    gossip_overlays: &mut super::types::GossipOverlays,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    event_tx: &EventTx,
    local_master: &str,
    device: &crate::identity::native_identity::NativeKeypair,
    crypto_store: &crate::crypto::CryptoStore,
    crdt_store: &super::crdt_store::CrdtStore,
    db_path: &str,
    db_passphrase: &str,
) {
    let now_ms = super::types::now_ms();
    let due = crdt_resync.witness.register_due(now_ms, REGISTER_EVERY_MS);
    if !due && crdt_resync.witness.all().is_empty() {
        return;
    }
    let Ok(store) = MessageStore::lease(db_path, db_passphrase) else { return };
    if due {
        register(&mut crdt_resync.witness, server_states, &store, local_master);
    }
    let restoring = crdt_resync.witness.restoring();
    let device_id = device.peer_id();
    if restoring.is_empty() {
        publish(&crdt_resync.witness, &store, &device_id, now_ms);
        return;
    }
    let contacts = super::union_list::contacts(&store);
    for sid in restoring {
        let Some(state) = server_states.get(&sid) else { continue };
        // A lost removal's restore may know no member to ask: the members our state
        // named before the removal, and those it names now, are one source like a join
        // answer.
        if crdt_resync.union.sources(&sid, &|m| contacts.contains(m), local_master).is_empty() {
            let before = lost_restore(&store, &sid).map(|r| r.members).unwrap_or_default();
            crdt_resync.union.state_named(&sid, before.into_iter().chain(state.members.keys().cloned()), &|m| contacts.contains(m));
            let members = crdt_resync.union.sources(&sid, &|m| contacts.contains(m), local_master);
            crdt_resync.witness.note_members(&sid, members);
        }
        let named = rejudge(&mut crdt_resync.witness, state, &store, db_path, &contacts, local_master, now_ms);
        if let Some((choice, started, round_at)) = crdt_resync.witness.chosen_round(&sid) {
            let heard = crdt_resync.op_sync.ended_since(&sid, round_at).iter().filter(|d| !super::resolver::same_identity(d, local_master)).count();
            if heard >= super::retire_round::IDENTITIES || now_ms.saturating_sub(started) >= ROUND_WAIT_MS {
                settle(
                    crdt_resync, server_states, mls, gossip_overlays, ws_cmd_tx, ws_room_peers, event_tx, &store, local_master, device,
                    crypto_store, crdt_store, &sid, choice,
                );
            }
            continue;
        }
        // Online devices of the identity, a single-device friend's own id included.
        let devices_of = |m: &str| -> Vec<String> {
            let mut ds = super::crypto_handler::online_devices_for(ws_room_peers, m);
            ds.sort();
            ds
        };
        let asks = crdt_resync.witness.due_asks(&sid, &named, &devices_of, local_master, &device_id, now_ms);
        for (to, ask) in asks {
            let msg = crdt_resync.witness_ask(state, &to, ask);
            super::frame_budget::pace_carried(frame_budget, ws_cmd_tx, &device_id, &to, &msg);
        }
    }
    publish(&crdt_resync.witness, &store, &device_id, now_ms);
}

/// The person chose for `server_id` (`None` = "I don't know"): the round that fetches
/// what members hold above the chosen point, against the witnesses' devices.
#[allow(clippy::too_many_arguments)]
pub(crate) fn choose(
    crdt_resync: &mut super::crdt_resync::CrdtResync,
    server_states: &ServerStates,
    frame_budget: &mut super::frame_budget::FrameBudget,
    ws_cmd_tx: &WsCmdTx,
    local_master: &str,
    device_peer_id: &str,
    server_id: &str,
    cp: Option<String>,
    db_path: &str,
    db_passphrase: &str,
) -> Result<(), String> {
    let state = server_states.get(server_id).ok_or("This server is not being restored.")?;
    crdt_resync.witness.choose(server_id, cp.clone(), super::types::now_ms())?;
    let base = match &cp {
        Some(cp) => crdt_resync.witness.content(server_id, cp),
        None => state.rollback_base(local_master),
    };
    let store = MessageStore::lease(db_path, db_passphrase)?;
    let place = |d: &str| super::server_rosters::place(&store, db_path, state, d);
    for to in crdt_resync.witness.round_devices(server_id, &place) {
        let ask = match &base {
            Some(b) => crdt_resync.sync_ask_on_base(state, &to, None, b, Default::default()),
            None => crdt_resync.sync_ask(state, &to, None, None),
        };
        super::frame_budget::pace_carried(frame_budget, ws_cmd_tx, device_peer_id, &to, &ask);
    }
    publish(&crdt_resync.witness, &store, device_peer_id, super::types::now_ms());
    Ok(())
}

/// The devices of ours whose ops or checkpoints the server holds and our view no longer
/// counts: what the settling drops.
fn dropped_devices(state: &ServerState, x: Option<&CrdtOp>, me: &str) -> Vec<String> {
    let mut out: Vec<String> = state
        .op_log
        .iter()
        .chain(state.stored.iter().map(|(o, _)| o))
        .chain(x)
        .filter(|o| o.author == me)
        .filter_map(|o| o.proven_device())
        .filter(|d| !state.authority.counts(me, d))
        .map(str::to_string)
        .collect();
    out.sort();
    out.dedup();
    out
}

#[allow(clippy::too_many_arguments)]
fn settle(
    crdt_resync: &mut super::crdt_resync::CrdtResync,
    server_states: &mut ServerStates,
    mls: &mut Option<crate::crypto::MlsManager>,
    gossip_overlays: &mut super::types::GossipOverlays,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    event_tx: &EventTx,
    store: &MessageStore,
    local_master: &str,
    device: &crate::identity::native_identity::NativeKeypair,
    crypto_store: &crate::crypto::CryptoStore,
    crdt_store: &super::crdt_store::CrdtStore,
    server_id: &str,
    choice: Option<String>,
) {
    let desk = &mut crdt_resync.witness;
    let x = choice.as_ref().and_then(|cp| desk.content(server_id, cp));
    let (Some(state), Some(t_ms), Some(roster)) =
        (server_states.get_mut(server_id), desk.t_ms(server_id), store.load_roster(local_master).ok().flatten())
    else {
        return;
    };
    let on = match &x {
        Some(x) => crate::crdt::settle::SettleOn::Witnessed(Box::new(x.clone())),
        None if choice.is_some() => {
            desk.unchoose(server_id);
            return;
        }
        None => crate::crdt::settle::SettleOn::Rollback,
    };
    let dropped = dropped_devices(state, x.as_ref(), local_master);
    let seen = store.op_seen_ms(server_id).unwrap_or_default();
    let s = crate::crdt::settle::Settling { before: state.authority.clone(), dropped: &dropped, t_ms: t_ms.max(0) as u64, seen: &seen, roster };
    let counted = super::floor::counted_members(state);
    let Some((ops, ingested)) = state.author_settling_on(local_master, &s, device, &on) else {
        hollow_log!("[HOLLOW-CRDT] Could not write the restore of {server_id}: choose again");
        desk.unchoose(server_id);
        return;
    };
    for i in &ingested {
        crdt_store.persist(i.delta(server_id));
    }
    crdt_store.save_state_snapshot(server_id.to_string(), state);
    // Members may have dropped X, and a settling needs its parent held.
    for op in x.iter().chain(ops.iter()) {
        super::sync_handler::broadcast_op_mls_first(mls, ws_cmd_tx, ws_room_peers, gossip_overlays, event_tx, state, local_master, server_id, op, crypto_store);
    }
    desk.finish(server_id);
    let back = super::floor::settled_newcomers(&counted, state, local_master);
    crdt_resync.floor.note_settled(server_id, back, x.iter().chain(ops.iter()).cloned().collect(), std::time::Instant::now());
    if let Some((base, _, _)) = recovery(store, local_master) {
        let _ = store.save_setting(&done_key(server_id, &base), "1");
    }
    let _ = store.delete_setting(&format!("{LOST_RESTORE}{server_id}"));
    let _ = event_tx.try_send(super::types::NetworkEvent::ServerUpdated { server_id: server_id.to_string() });
    hollow_log!("[HOLLOW-CRDT] Restored {server_id} from members' witnesses ({})", if choice.is_some() { "a named point" } else { "rolled back" });
}

/// The chooser's view of every restore (appendix A), for `api::device_proof`.
#[derive(Debug, Clone)]
pub(crate) struct RestoreSnap {
    pub(crate) server_id: String,
    pub(crate) stage: Stage,
    pub(crate) pick: Option<PointSnap>,
    pub(crate) points: Vec<PointSnap>,
}

#[derive(Debug, Clone)]
pub(crate) struct PointSnap {
    pub(crate) cp: String,
    pub(crate) date_ms: Option<i64>,
    pub(crate) named_by: Vec<String>,
    pub(crate) named_by_names: Vec<Option<String>>,
}

/// Per local device: one node per process in the app, several in the harness.
static SNAPSHOT: std::sync::LazyLock<std::sync::Mutex<HashMap<String, Vec<RestoreSnap>>>> = std::sync::LazyLock::new(Default::default);

fn publish(desk: &WitnessDesk, store: &MessageStore, device_id: &str, now_ms: i64) {
    let name = |m: &str| store.load_signed_card(m).map(|c| c.display_name).filter(|n| !n.is_empty());
    let point = |p: &super::witness::Point| PointSnap {
        cp: p.cp.clone(),
        date_ms: p.date_ms,
        named_by: p.named_by.clone(),
        named_by_names: p.named_by.iter().map(|m| name(m)).collect(),
    };
    let mut snaps: Vec<RestoreSnap> = desk
        .all()
        .into_iter()
        .filter_map(|sid| {
            let stage = desk.stage(&sid, now_ms)?;
            let judged = desk.judged(&sid)?;
            let points: Vec<PointSnap> = judged.points.iter().map(point).collect();
            let pick = judged.pick.as_ref().and_then(|cp| points.iter().find(|p| &p.cp == cp).cloned());
            Some(RestoreSnap { server_id: sid, stage, pick, points })
        })
        .collect();
    snaps.sort_by(|a, b| a.server_id.cmp(&b.server_id));
    let mut all = SNAPSHOT.lock().unwrap_or_else(|e| e.into_inner());
    if snaps.is_empty() {
        all.remove(device_id);
    } else {
        all.insert(device_id.to_string(), snaps);
    }
}

/// Every restore as the running node last judged it.
pub(crate) fn snapshot() -> Vec<RestoreSnap> {
    SNAPSHOT.lock().unwrap_or_else(|e| e.into_inner()).values().flatten().cloned().collect()
}

/// [`snapshot`] of one local device (the harness runs several nodes).
#[cfg(test)]
pub(crate) fn snapshot_of(device_id: &str) -> Vec<RestoreSnap> {
    SNAPSHOT.lock().unwrap_or_else(|e| e.into_inner()).get(device_id).cloned().unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::native_identity::NativeKeypair;
    use crate::identity::roster::Roster;

    /// A "not sure" recovery (T = 0) has each server's T at its oldest restore point
    /// held here, so a server held for a year still settles from our records.
    #[test]
    fn a_not_sure_recovery_still_settles_what_this_device_held_long_before() {
        let _g = super::super::resolver::test_lock();
        let store = MessageStore::open(":memory:", &"ab".repeat(32)).unwrap();
        let kp = |t: u8| NativeKeypair::from_secret_bytes(&[t; 32]);
        let (master, recovery, me) = (kp(0x74), kp(0x75), kp(0x76));
        let at = super::super::types::now_ms() - 60_000;
        let r = Roster::genesis(&master, &recovery, &me, at);
        super::super::roster_book::merge_for_test(&store, &r, &master.peer_id(), &me.peer_id());
        super::super::roster_book::note_recovery_lost_since(&store, &r.base(), 0).unwrap();
        let mut s = ServerState::new("long_held".into(), "long_held".into(), master.peer_id());
        std::sync::Arc::make_mut(&mut s.first_folds).insert("cp".into(), (at - 365 * 86_400_000) as u64);
        let mut states = ServerStates::new();
        states.insert("long_held".into(), s);
        let (views, _) = held_before_recovery(&states, &store, &master.peer_id(), &[]).expect("the recovery recorded its T");
        assert!(views.contains_key("long_held"), "a server held for a year was not settled from our records after a not-sure recovery");
    }

    /// The other half of a "not sure" recovery: only an owned server first held after
    /// the recovery itself goes to the witnesses (the chooser); one held before it
    /// settled from our records and is never handed over as well.
    #[test]
    fn a_not_sure_recovery_hands_the_witnesses_only_what_it_first_held_after_it() {
        let _g = super::super::resolver::test_lock();
        let store = MessageStore::open(":memory:", &"ab".repeat(32)).unwrap();
        let kp = |t: u8| NativeKeypair::from_secret_bytes(&[t; 32]);
        let (master, recovery, me) = (kp(0x77), kp(0x78), kp(0x79));
        let at = super::super::types::now_ms() - 60_000;
        let r = Roster::genesis(&master, &recovery, &me, at);
        super::super::roster_book::merge_for_test(&store, &r, &master.peer_id(), &me.peer_id());
        super::super::roster_book::note_recovery_lost_since(&store, &r.base(), 0).unwrap();
        let state = |sid: &str, first: i64| {
            let mut s = ServerState::new(sid.into(), sid.into(), master.peer_id());
            std::sync::Arc::make_mut(&mut s.first_folds).insert("cp".into(), first as u64);
            s
        };
        let mut states = ServerStates::new();
        states.insert("long_held".into(), state("long_held", at - 365 * 86_400_000));
        states.insert("after".into(), state("after", at + 1));
        let mut desk = WitnessDesk::default();

        register(&mut desk, &states, &store, &master.peer_id());

        assert_eq!(desk.restoring(), vec!["after".to_string()], "the witnesses got the wrong servers");
    }

    /// HOL-SEC-216: a recovery settles from our records only the servers this device
    /// held before T, never those first held between T and the recovery itself.
    #[test]
    fn held_before_judges_against_t_not_the_recovery() {
        let _g = super::super::resolver::test_lock();
        let store = MessageStore::open(":memory:", &"ab".repeat(32)).unwrap();
        let kp = |t: u8| NativeKeypair::from_secret_bytes(&[t; 32]);
        let (master, recovery, me) = (kp(0x71), kp(0x72), kp(0x73));
        let at = super::super::types::now_ms() - 60_000;
        let t = at - 3_600_000;
        let r = Roster::genesis(&master, &recovery, &me, at);
        super::super::roster_book::merge_for_test(&store, &r, &master.peer_id(), &me.peer_id());
        super::super::roster_book::note_recovery_lost_since(&store, &r.base(), t).unwrap();
        let state = |sid: &str, first: i64| {
            let mut s = ServerState::new(sid.into(), sid.into(), master.peer_id());
            std::sync::Arc::make_mut(&mut s.first_folds).insert("cp".into(), first as u64);
            s
        };
        let mut states = ServerStates::new();
        states.insert("before_t".into(), state("before_t", t - 1));
        states.insert("between".into(), state("between", t + 1));

        let (views, t_ms) = held_before_recovery(&states, &store, &master.peer_id(), &[]).expect("the recovery recorded its T");

        assert_eq!(t_ms, t as u64);
        assert!(views.contains_key("before_t"));
        assert!(!views.contains_key("between"), "a server first held after T was settled from our records");
    }
}
