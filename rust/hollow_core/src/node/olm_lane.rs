//! The send half of [`Lane::Carried`]: a message the relay must never read (claim
//! C-24) rides inside one device's Olm session as `MessageEnvelope::Carried`.

use std::collections::HashMap;
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
    let _ = ws_cmd_tx.send(WsCommand::Carry {
        device: device.to_string(),
        room: room.map(str::to_string),
        json,
        no_session,
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
    pub(crate) fn deliver(&mut self, device: &str, room: Option<&str>, json: &str, no_session: NoSession) -> Vec<WsCommand> {
        let online = super::crypto_handler::send_room_for_peer(self.ws_room_peers, device);
        let room = room.map(str::to_string).or(online.clone());
        if self.olm.has_session(device)
            && let Some(room) = room
        {
            match self.olm.encrypt(device, json.as_bytes()) {
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
