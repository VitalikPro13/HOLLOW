//! The send half of [`Lane::Carried`]: a message the relay must never read (claim
//! C-24) rides inside one device's Olm session as `MessageEnvelope::Carried`.

use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};
use std::time::Instant;

use crate::crypto::{CryptoStore, OlmManager};
use crate::identity::native_identity::NativeKeypair;

use super::types::*;
use super::ws_client::WsCommand;

/// What happens to a message for a device we hold no Olm session with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum NoSession {
    /// Park it until a session exists (drained with every other queued envelope)
    /// and start a key exchange.
    Queue,
    /// Lose it: a live signal that means nothing once late.
    Drop,
}

/// Carry `msg` to one DEVICE from anywhere that holds the relay sender; the node
/// encrypts it on its next turn (see [`OlmLane::deliver`]). `room` pins the relay
/// room, so a device that is offline gets the frame from the relay's buffer when it
/// next joins it; `None` takes the first room we share with the device.
pub(crate) fn carry(ws_cmd_tx: &WsCmdTx, device: &str, room: Option<&str>, msg: &HavenMessage, no_session: NoSession) {
    if let Some(json) = carried_json(msg) {
        carry_json(ws_cmd_tx, device, room, json, no_session);
    }
}

/// [`carry`] for an envelope already built with [`carried_json`].
pub(crate) fn carry_json(ws_cmd_tx: &WsCmdTx, device: &str, room: Option<&str>, json: String, no_session: NoSession) {
    let ticket = WAITING.try_with(|waiting| waiting.borrow_mut().enter(device, &json)).ok();
    let _ = ws_cmd_tx.send(WsCommand::Carry {
        device: device.to_string(),
        room: room.map(str::to_string),
        json,
        no_session,
        ticket,
    });
}

/// Carry `msg` to every online device of our own identity except this one.
/// Returns how many there were.
pub(crate) fn carry_to_own_siblings(
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    local_master: &str,
    local_device: &str,
    msg: &HavenMessage,
    no_session: NoSession,
) -> usize {
    let Some(json) = carried_json(msg) else { return 0 };
    let siblings: Vec<String> = super::crypto_handler::online_devices_for(ws_room_peers, local_master)
        .into_iter()
        .filter(|d| d != local_device)
        .collect();
    for device in &siblings {
        carry_json(ws_cmd_tx, device, None, json.clone(), no_session);
    }
    siblings.len()
}

/// Carry an envelope to every online device of one identity (a master or a device
/// id), the Olm counterpart of `send_raw_to_identity`. Returns how many there were.
pub(crate) fn carry_to_identity(
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    identity: &str,
    json: &str,
    no_session: NoSession,
) -> usize {
    let mut devices = super::crypto_handler::online_devices_for(ws_room_peers, identity);
    if devices.is_empty() && super::crypto_handler::ws_room_for_peer(ws_room_peers, identity).is_some() {
        devices.push(identity.to_string());
    }
    for device in &devices {
        carry_json(ws_cmd_tx, device, None, json.to_string(), no_session);
    }
    devices.len()
}

/// [`carry_to_identity`] for each of `identities` except our own.
pub(crate) fn carry_to_identities<'i>(
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    identities: impl IntoIterator<Item = &'i String>,
    local_master: &str,
    json: &str,
    no_session: NoSession,
) {
    for identity in identities {
        if !super::resolver::same_identity(identity, local_master) {
            carry_to_identity(ws_cmd_tx, ws_room_peers, identity, json, no_session);
        }
    }
}

/// `msg` wrapped for the Olm lane, serialized once for a fan-out.
pub(crate) fn carried_json(msg: &HavenMessage) -> Option<String> {
    debug_assert_eq!(msg.lane(), Lane::Carried, "only a Carried-lane message rides the Olm lane");
    serde_json::to_string(&MessageEnvelope::Carried {
        msg: Box::new(msg.clone()),
        at_ms: super::frame_auth::now_ms(),
    })
    .ok()
}

/// Most envelopes parked for one device: a device that never answers a key exchange
/// must not grow the queue forever.
const QUEUE_CAP: usize = 256;

tokio::task_local! {
    /// The node's carried frames that hold a wire slot and have not been delivered.
    static WAITING: RefCell<Waiting>;
}

/// Most waiting carried frames a node tracks; past it the oldest is encrypted when
/// it is reached, unordered against direct sends.
const WAITING_CAP: usize = 4096;

#[derive(Default)]
struct Waiting {
    next_ticket: u64,
    carries: VecDeque<WaitingCarry>,
}

/// A carried frame between its queueing and its delivery, with its ciphertext once a
/// direct send to the same device had to encrypt it first.
struct WaitingCarry {
    ticket: u64,
    device: String,
    json: String,
    sealed: Option<(usize, Vec<u8>)>,
}

impl Waiting {
    fn enter(&mut self, device: &str, json: &str) -> u64 {
        if self.carries.len() >= WAITING_CAP {
            self.carries.pop_front();
        }
        let ticket = self.next_ticket;
        self.next_ticket += 1;
        self.carries.push_back(WaitingCarry { ticket, device: device.to_string(), json: json.to_string(), sealed: None });
        ticket
    }

    fn take(&mut self, ticket: u64) -> Option<WaitingCarry> {
        let at = self.carries.iter().position(|c| c.ticket == ticket)?;
        self.carries.remove(at)
    }
}

/// Run a node loop with its own book of waiting carried frames ([`encrypt_in_turn`]).
pub(crate) fn with_carry_book<F: std::future::Future>(loop_: F) -> impl std::future::Future<Output = F::Output> {
    WAITING.scope(RefCell::new(Waiting::default()), loop_)
}

/// Olm-encrypt a direct frame to `device` after the carried frames queued for it
/// before it. Those go out first, and a receiver keeps only 40 message keys for
/// frames that arrive behind later ones, so the ratchet must follow the wire.
pub(crate) fn encrypt_in_turn(olm: &mut OlmManager, device: &str, plaintext: &[u8]) -> Result<(usize, Vec<u8>), String> {
    let _ = WAITING.try_with(|waiting| {
        for carry in waiting.borrow_mut().carries.iter_mut().filter(|c| c.device == device && c.sealed.is_none()) {
            match olm.encrypt(device, carry.json.as_bytes()) {
                Ok(sealed) => carry.sealed = Some(sealed),
                Err(_) => break,
            }
        }
    });
    olm.encrypt(device, plaintext)
}

/// Devices whose node leaves its waiting carried frames alone, as a busy event loop does.
#[cfg(test)]
static HELD_LANES: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

/// TEST-ONLY: stop or restart the node of `device` taking carried frames.
#[cfg(test)]
pub(crate) fn hold_carry_lane(device: &str, held: bool) {
    let mut lanes = HELD_LANES.lock().unwrap_or_else(|e| e.into_inner());
    lanes.retain(|d| d != device);
    if held {
        lanes.push(device.to_string());
    }
}

/// Whether the node of `device` takes its next carried frame now; always, outside tests.
pub(crate) fn carry_lane_open(device: &str) -> bool {
    #[cfg(test)]
    {
        !HELD_LANES.lock().unwrap_or_else(|e| e.into_inner()).iter().any(|d| d == device)
    }
    #[cfg(not(test))]
    {
        let _ = device;
        true
    }
}

/// The event loop's half: the state one [`WsCommand::Carry`](super::ws_client::WsCommand::Carry)
/// needs, borrowed for one delivery.
pub(crate) struct OlmLane<'a> {
    olm: &'a mut OlmManager,
    crypto_store: &'a CryptoStore,
    ws_room_peers: &'a WsRoomPeers,
    pending_messages: &'a mut HashMap<String, Vec<String>>,
    key_request_in_flight: &'a mut HashMap<String, Instant>,
    device_keypair: &'a NativeKeypair,
    device_peer_id: &'a str,
}

impl<'a> OlmLane<'a> {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn new(
        olm: &'a mut OlmManager,
        crypto_store: &'a CryptoStore,
        ws_room_peers: &'a WsRoomPeers,
        pending_messages: &'a mut HashMap<String, Vec<String>>,
        key_request_in_flight: &'a mut HashMap<String, Instant>,
        device_keypair: &'a NativeKeypair,
        device_peer_id: &'a str,
    ) -> Self {
        Self { olm, crypto_store, ws_room_peers, pending_messages, key_request_in_flight, device_keypair, device_peer_id }
    }

    /// Encrypt one carried envelope to `device` and return the frames to send in its
    /// place. A device in no room we share, with no `room` pinned, is treated like one
    /// without a session.
    pub(crate) fn deliver(&mut self, device: &str, room: Option<&str>, json: &str, no_session: NoSession, ticket: Option<u64>) -> Vec<WsCommand> {
        // A direct send queued behind this carry may have encrypted it already.
        let sealed = ticket
            .and_then(|ticket| WAITING.try_with(|waiting| waiting.borrow_mut().take(ticket)).ok().flatten())
            .and_then(|carry| carry.sealed);
        let online = super::crypto_handler::send_room_for_peer(self.ws_room_peers, device);
        let room = room.map(str::to_string).or(online.clone());
        if self.olm.has_session(device)
            && let Some(room) = room
        {
            match sealed.map_or_else(|| self.olm.encrypt(device, json.as_bytes()), Ok) {
                Ok((msg_type, ciphertext)) => {
                    super::crypto_handler::persist_olm_session(self.olm, self.crypto_store, device);
                    let frame = super::crypto_handler::encrypted_frame(self.olm, msg_type, &ciphertext);
                    return vec![WsCommand::SendDirect {
                        room_code: room,
                        target_peer: device.to_string(),
                        data: serde_json::to_vec(&frame).unwrap_or_default(),
                    }];
                }
                Err(e) => hollow_log!("[HOLLOW-CRYPTO] Olm lane encrypt to {device} failed: {e}"),
            }
        }
        if no_session == NoSession::Drop {
            return Vec::new();
        }
        self.park(device, json);
        let fresh = self
            .key_request_in_flight
            .get(device)
            .is_some_and(|t| t.elapsed() < std::time::Duration::from_secs(10));
        match online {
            Some(room) if !fresh && !self.olm.has_session(device) => {
                self.key_request_in_flight.insert(device.to_string(), Instant::now());
                let request = super::crypto_handler::signed_key_request(self.device_keypair, self.device_peer_id, device);
                vec![WsCommand::SendDirect {
                    room_code: room,
                    target_peer: device.to_string(),
                    data: serde_json::to_vec(&request).unwrap_or_default(),
                }]
            }
            _ => Vec::new(),
        }
    }

    fn park(&mut self, device: &str, json: &str) {
        let queue = self.pending_messages.entry(device.to_string()).or_default();
        queue.push(json.to_string());
        if queue.len() > QUEUE_CAP {
            queue.remove(0);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Alice and Bob with a session both have read on.
    fn established() -> (OlmManager, OlmManager) {
        let (mut alice, mut bob) = (OlmManager::new(), OlmManager::new());
        let key = bob.generate_one_time_key();
        alice.create_outbound_session("bob", &bob.identity_key_base64(), &key).unwrap();
        let (_, hello) = alice.encrypt("bob", b"hello").unwrap();
        bob.open_prekey("alice", &alice.identity_key_base64(), &hello, "bob").unwrap();
        let (kind, reply) = bob.encrypt("alice", b"reply").unwrap();
        alice.decrypt("bob", kind, &reply).unwrap();
        (alice, bob)
    }

    #[tokio::test]
    async fn a_direct_burst_encrypts_the_carries_queued_before_it_first() {
        with_carry_book(async {
            let (mut alice, mut bob) = established();
            let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
            carry_json(&tx, "bob", None, "carried".to_string(), NoSession::Queue);
            carry_json(&tx, "carol", None, "for carol".to_string(), NoSession::Queue);
            let Ok(WsCommand::Carry { ticket: Some(ticket), .. }) = rx.try_recv() else {
                panic!("a carry queued in the node loop holds a ticket");
            };

            let burst: Vec<_> = (0..60).map(|i| encrypt_in_turn(&mut alice, "bob", format!("d{i}").as_bytes()).unwrap()).collect();
            let carried = WAITING.with(|waiting| waiting.borrow_mut().take(ticket)).and_then(|carry| carry.sealed);
            let carried = carried.expect("the carried frame was encrypted before the burst");
            assert!(
                WAITING.with(|waiting| waiting.borrow().carries.iter().all(|carry| carry.sealed.is_none())),
                "another device's carry waits for its own turn"
            );

            // Bob reads them in wire order: the carried frame, then the burst.
            for (i, (kind, ciphertext)) in std::iter::once(carried).chain(burst).enumerate() {
                assert!(bob.decrypt("alice", kind, &ciphertext).is_ok(), "frame {i} on the wire did not decrypt");
            }
        })
        .await;
    }

    /// Node code reaches Olm only through [`encrypt_in_turn`], so no direct frame takes
    /// a ratchet step ahead of a carry queued before it.
    #[test]
    fn node_code_encrypts_olm_only_in_turn() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/node");
        let mut offenders = Vec::new();
        for entry in std::fs::read_dir(&dir).expect("read src/node") {
            let path = entry.expect("dir entry").path();
            let name = path.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_string();
            if !name.ends_with(".rs") || name == "olm_lane.rs" || name == "test_harness.rs" {
                continue;
            }
            let source = std::fs::read_to_string(&path).expect("read source").replace("\r\n", "\n");
            let code = source.split("\n#[cfg(test)]\nmod tests").next().unwrap_or_default();
            let code: String = code
                .lines()
                .filter(|line| !line.trim_start().starts_with("//"))
                .flat_map(|line| line.chars().filter(|c| !c.is_whitespace()))
                .collect();
            if code.contains("olm.encrypt(") {
                offenders.push(name);
            }
        }
        assert!(offenders.is_empty(), "Olm encrypt outside olm_lane::encrypt_in_turn in {offenders:?}");
    }
}
