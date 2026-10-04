//! Door-proof server rooms, the member's side (design D1). The relay shows a server
//! room's roster, presence, broadcasts and rings only to sockets that prove the
//! newest door of the server's join lock, so every member hands its socket that door
//! (`WsCommand::SetDoor`), and a member whose door is older than the relay's newest
//! (it was offline while the lock moved) asks the members who can see for it.

use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use zeroize::Zeroizing;

use super::join_lock::LockLink;
use super::sealed_box;
use super::types::{HavenMessage, ServerStates, WsCmdTx, WsRoomPeers};
use super::ws_client::{DoorSecret, WsCommand};
use crate::identity::native_identity::NativeKeypair;

tokio::task_local! {
    /// Peers the relay hides from us that spoke to us, by the room they spoke from:
    /// the only way to answer them, since no roster lists them. One table per node.
    static HEARD: std::cell::RefCell<HashMap<String, String>>;
}

/// The most hidden peers a node keeps a way back to; past it the table starts over.
const MAX_HEARD: usize = 4096;

/// Run a node loop with its own table of the hidden peers it hears ([`heard_room`]).
pub(crate) fn with_heard_routes<F: std::future::Future>(loop_: F) -> impl std::future::Future<Output = F::Output> {
    HEARD.scope(std::cell::RefCell::new(HashMap::new()), loop_)
}

/// `peer`, whom no room shows us, spoke to us from `room`. Only a room where answering
/// a stranger is the point (a server with a public channel, one we browse as a guest)
/// should keep a way back, or a stranger who knows a member's id learns from the
/// answer that it is there.
pub(crate) fn note_heard(peer: &str, room: &str) {
    let _ = HEARD.try_with(|heard| {
        let mut heard = heard.borrow_mut();
        if heard.len() >= MAX_HEARD && !heard.contains_key(peer) {
            heard.clear();
        }
        heard.insert(peer.to_string(), room.to_string());
    });
}

/// The room a hidden `peer` last spoke to us from.
pub(crate) fn heard_room(peer: &str) -> Option<String> {
    HEARD.try_with(|heard| heard.borrow().get(peer).cloned()).ok().flatten()
}

/// The hidden peers we heard in `room`.
pub(crate) fn heard_in(room: &str) -> Vec<String> {
    HEARD
        .try_with(|heard| heard.borrow().iter().filter(|(_, r)| r.as_str() == room).map(|(p, _)| p.clone()).collect())
        .unwrap_or_default()
}

/// A new relay connection: who was in which room then says nothing now.
pub(crate) fn forget_heard() {
    let _ = HEARD.try_with(|heard| heard.borrow_mut().clear());
}

const GRANT_DOMAIN: &[u8] = b"hollow-door-grant1";
/// Between two asks for one room's door, and two answers to one device.
const ASK_GAP: Duration = Duration::from_secs(20);
/// Former members' devices we remember telling: past it the oldest is forgotten.
const TOLD_CAP: usize = 4096;
/// How many of the members who see an ask answer it.
const ANSWERERS: usize = 3;

/// The identity `device` speaks for: its master, unless it is a bare master id, a
/// revoked device or one its roster disowns (HOL-SEC-083).
pub(crate) fn speaks_for(device: &str) -> Option<String> {
    let master = super::resolver::resolve(device);
    let refused = super::resolver::is_bare_master(device)
        || super::resolver::is_revoked(device)
        || super::resolver::disowns(&master, device);
    (!refused).then_some(master)
}

#[derive(Default)]
pub(crate) struct DoorRooms {
    /// The door our socket proves per server room: its number and public half.
    sent: HashMap<String, (u64, String)>,
    /// Server rooms the relay hides us in: it counts no door of ours as its newest.
    hidden: HashSet<String>,
    /// Doors members handed us, newer than our state holds: number, public half, secret.
    granted: HashMap<String, (u64, String, Zeroizing<[u8; 32]>)>,
    asked: HashMap<String, Instant>,
    /// (room, asker) -> the door we last handed it, and when.
    answered: HashMap<(String, String), (u64, Instant)>,
    /// (room, asker) -> the removal we told that former member's device of. Once per
    /// removal: one notice is enough to leave on, and each tells it we are online.
    told: HashMap<(String, String), crate::crdt::hlc::HlcTimestamp>,
}

fn grant_aad(server_id: &str, n: u64, asker: &str, granter: &str) -> Vec<u8> {
    [server_id.as_bytes(), b"\0", &n.to_le_bytes(), b"\0", asker.as_bytes(), b"\0", granter.as_bytes()].concat()
}

impl DoorRooms {
    pub(crate) fn is_hidden(&self, room: &str) -> bool {
        self.hidden.contains(room)
    }

    /// Hand the socket the newest door of every self-certifying server we are a
    /// member of, and take it back from the ones we no longer are. Cheap when nothing
    /// changed: it runs on every turn of the node's loop.
    pub(crate) fn sync(&mut self, server_states: &ServerStates, local_master: &str, ws_cmd_tx: &WsCmdTx) {
        let mut kept: HashSet<&str> = HashSet::new();
        for (sid, state) in server_states {
            if !crate::crdt::anchor::is_genesis_id(sid) || state.is_deleted() || !state.is_member(local_master) {
                continue;
            }
            let ours = state.join_lock.newest_door_id();
            if self.granted.get(sid).is_some_and(|(g, _, _)| ours.is_some_and(|(n, _)| n >= *g)) {
                self.granted.remove(sid);
            }
            let (n, public, secret) = match (self.granted.get(sid), ours) {
                (Some((n, public, secret)), _) => (*n, public.clone(), Some(secret.clone())),
                (None, Some((n, public))) => (n, public.to_string(), None),
                (None, None) => continue,
            };
            kept.insert(sid);
            if self.sent.get(sid.as_str()).is_some_and(|(sn, sp)| *sn == n && *sp == public) {
                continue;
            }
            let Some(secret) = secret.or_else(|| state.join_lock.newest_door().map(|(_, _, s)| s)) else { continue };
            self.sent.insert(sid.clone(), (n, public));
            let _ = ws_cmd_tx.send(WsCommand::SetDoor { room_code: sid.clone(), door: Some(DoorSecret(secret)) });
        }
        self.granted.retain(|sid, _| kept.contains(sid.as_str()));
        let gone: Vec<String> = self.sent.keys().filter(|sid| !kept.contains(sid.as_str())).cloned().collect();
        for sid in gone {
            self.sent.remove(&sid);
            let _ = ws_cmd_tx.send(WsCommand::SetDoor { room_code: sid, door: None });
        }
    }

    /// The relay said whether it counts us as holding `room`'s newest door. Hidden in a
    /// server we are a member of, we prove the newest door our state holds, and failing
    /// that ask the members who can see for it. Returns whether we asked.
    pub(crate) fn on_status(
        &mut self,
        room: &str,
        proved: bool,
        server_states: &ServerStates,
        local_master: &str,
        ws_cmd_tx: &WsCmdTx,
    ) -> bool {
        if proved {
            self.hidden.remove(room);
            self.asked.remove(room);
            return false;
        }
        self.hidden.insert(room.to_string());
        if !server_states.get(room).is_some_and(|s| !s.is_deleted() && s.is_member(local_master)) {
            return false;
        }
        // Hand the socket our newest door again in case it never got it; one it
        // already holds changes nothing there.
        self.sent.remove(room);
        self.sync(server_states, local_master, ws_cmd_tx);
        if self.asked.get(room).is_some_and(|t| t.elapsed() < ASK_GAP) {
            return false;
        }
        self.asked.insert(room.to_string(), Instant::now());
        hollow_log!("[HOLLOW-WS] The relay hides us in {room}: asking its members for the newest door");
        if let Ok(data) = serde_json::to_vec(&HavenMessage::DoorAsk { server_id: room.to_string() }) {
            let _ = ws_cmd_tx.send(WsCommand::SendToRoom { room_code: room.to_string(), data });
        }
        true
    }

    /// A device the relay hides in `room` asked for its door. We answer when it is a
    /// device of a current member, we hold a door, and we are among the first few of
    /// the members who see the room by a per-asker order (so not everyone answers). A
    /// former member's device is told of its removal instead, when an Olm session
    /// with it can carry the notice.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn answer_ask(
        &mut self,
        room: &str,
        server_id: &str,
        asker: &str,
        olm: &crate::crypto::OlmManager,
        server_states: &ServerStates,
        ws_room_peers: &WsRoomPeers,
        local_master: &str,
        our_device: &str,
        ws_cmd_tx: &WsCmdTx,
    ) -> bool {
        let Some(state) = server_states.get(room).filter(|_| server_id == room) else { return false };
        let master = speaks_for(asker)
            .filter(|_| asker != our_device && !state.is_deleted() && state.is_member(local_master));
        let Some(master) = master else {
            hollow_log!("[HOLLOW-SECURITY] Not answering a door ask in {room} from {asker}: no device of a member");
            return false;
        };
        if !state.is_member(&master) {
            return olm.has_session(asker) && self.tell_removal(room, asker, &master, state, ws_room_peers, our_device, ws_cmd_tx);
        }
        let Some((n, _, secret)) = state.join_lock.newest_door() else { return false };
        if !self.first_to_answer(room, asker, ws_room_peers, our_device) {
            return false;
        }
        let key = (room.to_string(), asker.to_string());
        if self.answered.get(&key).is_some_and(|(sent, t)| *sent == n && t.elapsed() < ASK_GAP) {
            return false;
        }
        let Some(sealed) = super::join_lock::peer_x25519(asker)
            .and_then(|to| sealed_box::seal(&to, GRANT_DOMAIN, &grant_aad(room, n, asker, our_device), secret.as_slice()))
        else {
            return false;
        };
        self.answered.retain(|_, (_, t)| t.elapsed() < ASK_GAP);
        self.answered.insert(key, (n, Instant::now()));
        let grant = HavenMessage::DoorGrant { server_id: room.to_string(), n, eph: sealed.eph, ct: sealed.ct };
        let Ok(data) = serde_json::to_vec(&grant) else { return false };
        hollow_log!("[HOLLOW-WS] Handing door {n} of {room} to {asker}, a member's device the relay hides");
        let _ = ws_cmd_tx.send(WsCommand::SendDirect { room_code: room.to_string(), target_peer: asker.to_string(), data });
        true
    }

    fn first_to_answer(&self, room: &str, asker: &str, ws_room_peers: &WsRoomPeers, our_device: &str) -> bool {
        use sha2::{Digest, Sha256};
        let rank = |device: &str| Sha256::digest(format!("{asker}\n{device}").as_bytes());
        let ours = rank(our_device);
        let ahead = ws_room_peers
            .get(room)
            .into_iter()
            .flatten()
            .filter(|d| d.as_str() != our_device && d.as_str() != asker && rank(d) < ours)
            .count();
        ahead < ANSWERERS
    }

    /// A former member's device asked: hand it the op that removed it, with what its
    /// own fold needs to admit that op, so it leaves. Never a door, nothing to anyone
    /// our log never shows as a member, and one notice per removal and device.
    #[allow(clippy::too_many_arguments)]
    fn tell_removal(
        &mut self,
        room: &str,
        asker: &str,
        master: &str,
        state: &crate::crdt::server_state::ServerState,
        ws_room_peers: &WsRoomPeers,
        our_device: &str,
        ws_cmd_tx: &WsCmdTx,
    ) -> bool {
        // A door ask carries no state vector, so the notice reaches back to the anchor.
        let nothing_held = crate::crdt::sync::StateVector { server_id: room.to_string(), entries: HashMap::new() };
        let notice = crate::crdt::sync::removal_notice(state, master, &nothing_held);
        let Some(removal) = notice.last().map(|op| op.hlc.clone()) else {
            hollow_log!("[HOLLOW-SECURITY] Not answering a door ask in {room} from {asker}: no device of a member");
            return false;
        };
        let key = (room.to_string(), asker.to_string());
        if self.told.get(&key) == Some(&removal) || !self.first_to_answer(room, asker, ws_room_peers, our_device) {
            return false;
        }
        let Ok(ops_json) = serde_json::to_string(&notice) else { return false };
        if self.told.len() >= TOLD_CAP
            && !self.told.contains_key(&key)
            && let Some(oldest) = self.told.iter().min_by(|a, b| a.1.cmp(b.1)).map(|(k, _)| k.clone())
        {
            self.told.remove(&oldest);
        }
        self.told.insert(key, removal);
        hollow_log!("[HOLLOW-WS] Telling {asker}, a former member the relay hides in {room}, of its removal");
        super::olm_lane::carry(
            ws_cmd_tx,
            asker,
            Some(room),
            &HavenMessage::SyncResponse { server_id: room.to_string(), ops_json, nonce: None },
            super::olm_lane::NoSession::Drop,
        );
        true
    }

    /// A member handed us a door. We keep it only when it is the newest lock of the
    /// relay's chain as we verified it back to the owner, then prove it.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn on_grant(
        &mut self,
        room: &str,
        from: &str,
        server_id: &str,
        n: u64,
        eph: &str,
        ct: &str,
        relay_tip: Option<&LockLink>,
        device_keypair: &NativeKeypair,
        our_device: &str,
        server_states: &ServerStates,
        local_master: &str,
        ws_cmd_tx: &WsCmdTx,
    ) -> bool {
        if server_id != room || !self.hidden.contains(room) {
            return false;
        }
        let aad = grant_aad(room, n, our_device, from);
        let secret = sealed_box::open(&device_keypair.x25519_scalar_bytes(), GRANT_DOMAIN, &aad, eph, ct)
            .and_then(|plain| <[u8; 32]>::try_from(plain.as_slice()).ok())
            .map(Zeroizing::new);
        let fits = |s: &[u8; 32]| {
            relay_tip.is_some_and(|tip| tip.n == n && tip.door_key() == Some(sealed_box::public_of(s)))
        };
        let Some(secret) = secret.filter(|s| fits(s)) else {
            hollow_log!("[HOLLOW-SECURITY] Dropped a door grant for {room} from {from}: not the newest door of the relay's chain");
            return false;
        };
        hollow_log!("[HOLLOW-WS] {from} handed us door {n} of {room}");
        let public = sealed_box::key_to_text(&sealed_box::public_of(&secret));
        self.granted.insert(room.to_string(), (n, public, secret));
        self.sync(server_states, local_master, ws_cmd_tx);
        true
    }

    /// A new relay connection: the socket proves whatever we hand it again.
    pub(crate) fn on_connected(&mut self) {
        self.hidden.clear();
        self.asked.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::super::resolver;
    use super::super::ws_client::WsCommand;
    use super::{speaks_for, DoorRooms, HavenMessage};
    use crate::crdt::hlc::HlcTimestamp;
    use crate::crdt::operations::{CrdtOp, CrdtPayload, JoinAsk};
    use crate::crdt::server_state::ServerState;
    use crate::crdt::testkeys::keys;

    fn op_at(tag: u8, sid: &str, ms: u64, payload: CrdtPayload) -> CrdtOp {
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

    /// HOL-SEC-114: a kicked member's device that asks for the door is handed its
    /// removal and never the door; a stranger's ask gets nothing. Each notice also
    /// tells the asker we are online, so a device hears of one removal once, and only
    /// when our session with it can carry the notice.
    #[test]
    fn a_former_member_asking_for_the_door_is_told_its_removal_once() {
        let _g = resolver::test_lock();
        resolver::clear_for_test();
        let (kp, owner, pk) = keys(1);
        let (_, founding) = ServerState::found("S".into(), owner.clone(), kp, pk);
        let sid = founding.server_id.clone();
        let t = founding.hlc.physical_ms;
        let kicked = keys(2).1;
        let admit = |at: i64| CrdtPayload::MemberAdded {
            peer_id: kicked.clone(),
            display_name: "m".into(),
            follow: None,
            ask: Some(JoinAsk::sign(&sid, at, &keys(2).0)),
        };
        let mut state = ServerState::skeleton(sid.clone());
        state.ingest_remote(&[
            founding,
            op_at(1, &sid, t + 1, admit(1)),
            op_at(1, &sid, t + 2, CrdtPayload::MemberRemoved { peer_id: kicked.clone() }),
        ]);
        let mut states = std::collections::HashMap::from([(sid.clone(), state)]);
        resolver::update("kicked-device", &kicked);
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let mut doors = DoorRooms::default();
        let peers = std::collections::HashMap::new();
        let mut olm = crate::crypto::OlmManager::new();
        let ask = |doors: &mut DoorRooms, states: &std::collections::HashMap<String, ServerState>, olm: &crate::crypto::OlmManager, asker: &str| {
            doors.answer_ask(&sid, &sid, asker, olm, states, &peers, &owner, "our-device", &tx)
        };

        assert!(!ask(&mut doors, &states, &olm, "kicked-device") && rx.try_recv().is_err(), "told with no session to carry it");
        let mut theirs = crate::crypto::OlmManager::new();
        let otk = theirs.generate_one_time_key();
        olm.create_outbound_session("kicked-device", &theirs.identity_key_base64(), &otk).unwrap();
        assert!(ask(&mut doors, &states, &olm, "kicked-device"), "a kicked member's device asked and was not told");
        match rx.try_recv() {
            Ok(WsCommand::Carry { device, room, json, .. }) => {
                assert_eq!((device.as_str(), room.as_deref()), ("kicked-device", Some(sid.as_str())));
                let ops = match serde_json::from_str(&json) {
                    Ok(super::super::types::MessageEnvelope::Carried { msg, .. }) => match *msg {
                        HavenMessage::SyncResponse { ops_json, .. } => crate::crdt::operations::parse_ops_tolerant(&ops_json),
                        other => panic!("not a sync answer: {other:?}"),
                    },
                    other => panic!("not a carried envelope: {other:?}"),
                };
                assert!(
                    matches!(ops.last().map(|op| &op.payload), Some(CrdtPayload::MemberRemoved { peer_id }) if *peer_id == kicked),
                    "the notice does not end on the removal"
                );
            }
            other => panic!("no removal notice went out: {other:?}"),
        }
        assert!(!ask(&mut doors, &states, &olm, "kicked-device") && rx.try_recv().is_err(), "told of the same removal again");
        assert!(!ask(&mut doors, &states, &olm, &keys(9).1) && rx.try_recv().is_err(), "a stranger was told something");

        // Admitted again on a newer ask and removed again: that removal is news.
        states.get_mut(&sid).unwrap().ingest_remote(&[
            op_at(1, &sid, t + 3, admit(2)),
            op_at(1, &sid, t + 4, CrdtPayload::MemberRemoved { peer_id: kicked.clone() }),
        ]);
        assert!(ask(&mut doors, &states, &olm, "kicked-device"), "a second removal was never told");
        assert!(matches!(rx.try_recv(), Ok(WsCommand::Carry { .. })));
        resolver::clear_for_test();
    }

    /// HOL-SEC-114: a former member is told of its removal only through a device its
    /// roster counts, never through the bare master id or a revoked device.
    #[test]
    fn authz_a_bare_master_or_revoked_device_speaks_for_no_one() {
        let _g = resolver::test_lock();
        resolver::clear_for_test();
        resolver::update("device", "master");
        resolver::update("revoked", "master");
        resolver::note_roster("master");
        assert_eq!(speaks_for("device").as_deref(), Some("master"));
        assert_eq!(speaks_for("master"), None, "the bare master id spoke for its identity");
        resolver::mark_revoked(&["revoked".to_string()]);
        assert_eq!(speaks_for("revoked"), None, "a revoked device spoke for its identity");
        resolver::clear_for_test();
    }
}
