use std::collections::{HashMap, HashSet};

use tokio::sync::mpsc;

use crate::crypto::{CryptoStore, MlsManager, OlmManager};
use crate::crdt::server_state::ServerState;
use super::crypto_handler::{
    message_signing_payload, sign_message, verify_message_signature,
    peer_is_reachable, send_mls_broadcast, send_mls_broadcast_topic, send_encrypted_message,
    send_message_to_peer,
};
use super::types::*;

// ── 1. SendMessage (DM) ──────────────────────────────────────────────

#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_send_message(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    key_request_in_flight: &mut HashMap<String, std::time::Instant>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
    // THIS device's keypair — signs the Olm KeyRequest (Fix B).
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    peer_id_str: String,
    text: String,
    message_id: String,
    reply_to_mid: Option<String>,
    link_preview: Option<LinkPreviewRef>,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-SWARM] SendMessage received for {peer_id_str} mid={message_id}");

    // Wrap DM in signed envelope.
    let local_peer = local_peer_str.to_string();
    // Lamport-bumped send stamp (chat_clock.rs): strictly after every message
    // this device has seen, so cross-machine clock skew can't sort our reply
    // above the message it answers. The signed ms `ts` and the `order_us`
    // ordering key both derive from the ONE stamp (order_us is NOT signed;
    // it's carried over the wire + persisted for same-ms burst ordering).
    let dm_order_us = crate::chat_clock::next_send_stamp_us();
    let dm_timestamp = dm_order_us / 1000;
    let signing_payload = message_signing_payload(
        "dm", &peer_id_str, &local_peer, dm_timestamp, &text,
    );
    let (sig, pk) = sign_message(bundle_keypair, pub_key_b64, &signing_payload);
    let recipient_master = super::resolver::resolve(&peer_id_str);
    let build_dm = |convo: Option<String>| MessageEnvelope::DirectMessage {
        inner: Box::new(DirectMessagePayload {
            text: text.clone(),
            ts: dm_timestamp,
            sig: sig.clone(),
            pk: pk.clone(),
            mid: Some(message_id.clone()),
            reply_to: reply_to_mid.clone(),
            file_id: None,
            link_preview: link_preview.clone(),
            convo,
            order_us: Some(dm_order_us),
        }),
    };
    let envelope_json = serde_json::to_string(&build_dm(None))
        .unwrap_or_else(|_| text.clone());
    // Sibling self-echo variant carries the recipient master as the conversation
    // key, so our other device files it under the right thread (not under us).
    let sibling_envelope_json = serde_json::to_string(&build_dm(Some(recipient_master.clone())))
        .unwrap_or_else(|_| text.clone());

    // Persist sent DM locally with the same Rust-generated timestamp.
    // This ensures DM sync timestamps are consistent (no Dart DateTime.now() mismatch).
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let _ = store.insert(
                &peer_id_str, &text, true, dm_timestamp,
                sig.as_deref(), pk.as_deref(), Some(&message_id),
                reply_to_mid.as_deref(), None, Some(dm_order_us),
            );
            if let Some(lp) = &link_preview {
                if let Ok(lp_json) = serde_json::to_string(lp) {
                    let _ = store.update_link_preview(&message_id, &lp_json);
                }
            }
        }
    }

    // ── Multi-device fan-out (Phase 6, Step 3) ──────────────────────────
    // `peer_id_str` is the recipient's MASTER identity (that's what the friend
    // list / UI keys on). Olm sessions, `pending_messages`, and room membership
    // are all keyed by DEVICE peer_ids, so encrypting to the bare master would
    // hit no session and target a peer nobody authenticates as. Expand the
    // master into its known device peer_ids and run the per-device send for
    // each. Single-device friends (no device list ingested) resolve to an empty
    // device set → fall back to the master id as-is = byte-for-byte old behavior.
    //
    // We ALSO fan out to our OWN other online devices (self fan-out), so a DM
    // typed on one of our devices appears live on the sibling. The local DB
    // insert + `MessageSent` event above already happened keyed on the master,
    // so the SENDING device's UI is correct; this delivers the same envelope to
    // our other devices' Olm inboxes (they persist it on receive, keyed by our
    // master via `convo_peer`).
    fan_out_dm_envelope(
        olm, crypto_store, event_tx, ws_cmd_tx, ws_room_peers,
        pending_messages, key_request_in_flight,
        local_peer_str, device_keypair, device_peer_id, &recipient_master, &envelope_json,
        Some(&sibling_envelope_json),
    ).await;

    // Hydrate the optimistic Dart entry with sig/pk so the
    // Message Proof dialog shows VERIFIED without a restart.
    let _ = event_tx.send(NetworkEvent::MessageSent {
        to_peer: peer_id_str.clone(),
        message_id: message_id.clone(),
        timestamp: dm_timestamp,
        signature: sig.clone(),
        public_key: pk.clone(),
    }).await;
}

/// Expand a recipient MASTER id into its device set (plus our own sibling
/// devices for self fan-out) and deliver one already-signed DM envelope to each
/// (Phase 6 multi-device, Step 3). Single-device recipients (no device list
/// ingested) resolve to an empty device set → the master id is used as-is, which
/// is byte-for-byte the pre-multi-device behavior. Used by every DM send path:
/// new message, edit, delete, reaction add/remove.
///
/// NOTE: `pending_messages` is keyed per DEVICE, so a queued envelope is drained
/// to the right device when ITS session establishes (PeerJoined/RoomMembers/
/// KeyBundle). The caller is responsible for the local DB write + UI event, both
/// of which stay keyed on the MASTER.
#[allow(clippy::too_many_arguments)]
async fn fan_out_dm_envelope(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    key_request_in_flight: &mut HashMap<String, std::time::Instant>,
    local_peer_str: &str,
    // THIS device's identity — signs the KeyRequest (Fix B).
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    recipient_master: &str,
    envelope_json: &str,
    // For DirectMessage sends, a variant of the envelope with `convo` set to
    // `recipient_master` — delivered to OUR OWN sibling devices so they file the
    // echo under the right conversation (not under ourselves). `None` for
    // edit/delete/reaction (siblings resolve the convo from the message row by
    // mid on receive), so siblings get the plain `envelope_json`.
    sibling_envelope_json: Option<&str>,
) {
    // Recipient's devices (genuine other party) always get the plain envelope.
    // Target set = the persisted device list UNION the devices CURRENTLY in the
    // DM room that resolve to this master. The live room is authoritative: a
    // device that's online right now must be reached even if the stored device
    // list is stale/polluted (ghost ids from old wipe+reimport tests) or simply
    // doesn't yet contain this freshly-rotated device id. Without the live union
    // the fan-out would deliver only to a dead ghost id and skip the connected
    // device — the exact "first message lost, peer shows offline" symptom.
    let dm_room = dm_room_code(local_peer_str, recipient_master);
    // Self-DM ("Saved messages"): the recipient IS us — there is no other party
    // to deliver to, and the recipient-branch fallback below would queue a dead
    // envelope under the bare master id forever. Our own siblings (next block)
    // still get their copy.
    let self_dm = super::resolver::same_identity(local_peer_str, recipient_master);
    let recipient_devices = if self_dm {
        Vec::new()
    } else {
        collect_target_devices(
            ws_room_peers, Some(olm), &dm_room, recipient_master, recipient_master, /*exclude*/ None,
        )
    };
    for device_peer in &recipient_devices {
        send_dm_to_device(
            olm, crypto_store, event_tx, ws_cmd_tx, ws_room_peers,
            pending_messages, key_request_in_flight,
            device_keypair, device_peer_id,
            device_peer, envelope_json, &dm_room, /*is_sibling*/ false,
        ).await;
    }

    // Our own sibling devices (self fan-out) get the convo-tagged variant when one
    // is supplied; otherwise the plain envelope. Same live-union logic, excluding
    // THIS device (never echo to ourselves).
    let own_master = super::resolver::resolve(local_peer_str);
    let sibling_json = sibling_envelope_json.unwrap_or(envelope_json);
    // Siblings: live-only (None for olm) — an offline own-sibling is reached via
    // pending_messages queue + Step 5 backfill, NOT via the offline-buffer/push
    // path (we never want to PUSH our own phone for our OWN outgoing message).
    let mut siblings: HashSet<String> = collect_target_devices(
        ws_room_peers, None, &dm_room, &own_master, "", /*exclude*/ Some(device_peer_id),
    ).into_iter().collect();
    // ALSO union peers in our `inbox:{master}` room. A freshly-linked sibling joins
    // the inbox room IMMEDIATELY (it's the sibling rendezvous) but may not have
    // joined this specific DM-with-friend room yet when we send our FIRST message —
    // so the DM-room union alone misses it and the echo goes to a stale ghost id
    // from the stored device list. The inbox union catches the live sibling right
    // away (fixes "VM's first DM to AL never mirrors to Pixel").
    let inbox_room = format!("inbox:{own_master}");
    if let Some(peers) = ws_room_peers.get(&inbox_room) {
        for p in peers {
            if p != device_peer_id && super::resolver::resolve(p) == own_master {
                siblings.insert(p.clone());
            }
        }
    }
    siblings.remove(&own_master);
    for sibling in &siblings {
        if recipient_devices.contains(sibling) {
            continue;
        }
        send_dm_to_device(
            olm, crypto_store, event_tx, ws_cmd_tx, ws_room_peers,
            pending_messages, key_request_in_flight,
            device_keypair, device_peer_id,
            sibling, sibling_json, &dm_room, /*is_sibling*/ true,
        ).await;
    }
}

/// Build the set of device peer_ids to fan a DM out to for one master identity.
///
/// LIVENESS-FILTERED (Step 7 ghost fix): a stored device id from
/// `resolver::devices_for` is targeted ONLY if it is reachable — it has an Olm
/// session OR is currently in a room. A device list accumulates dead "ghost" ids
/// across re-link cycles (union-merge never prunes); without this filter the
/// fan-out addresses every ghost → no session → `send_dm_to_device` either
/// room-sends ("Sent encrypted DM to offline <ghost>", firing a spurious push +
/// unread on the receiver) or queues a KeyRequest forever. A ghost has been seen
/// by NO device, so it has neither a session nor room presence → it's dropped.
/// A genuinely-offline REAL device (seen before → has a persisted session) still
/// passes and gets the normal offline-buffer treatment.
///
/// The set is then UNIONed with every peer currently in `dm_room` that resolves to
/// `master` (the live room is always authoritative — a freshly-rotated device id
/// not yet in the stored list is still reached). `fallback_self` is returned only
/// if the whole set is empty and non-empty itself (single-device recipient → send
/// to the master id as-is, pre-multi-device behavior); pass "" to skip the fallback
/// (self fan-out, where "no live siblings" must mean send to nobody). `exclude`
/// drops one id (our own device).
fn collect_target_devices(
    ws_room_peers: &HashMap<String, HashSet<String>>,
    // When Some, also include OFFLINE-but-real devices (Step 9A push): a device
    // that is in the resolver's signed-list view AND we hold an Olm session with
    // → it gets the offline-buffer/push treatment so a fully-quit phone wakes.
    // None = live-only (self fan-out to our own siblings: never push our own phone).
    olm: Option<&OlmManager>,
    dm_room: &str,
    master: &str,
    fallback_self: &str,
    exclude: Option<&str>,
) -> Vec<String> {
    // Online devices: stored devices CURRENTLY IN A ROOM (reachable right now).
    // Room-presence is the unambiguous liveness test that drops dead ghosts (a
    // ghost has a STALE persisted Olm session, so `has_session` alone is NOT a
    // liveness test — it's only used below to qualify the OFFLINE set).
    let mut set: HashSet<String> = super::resolver::devices_for(master)
        .into_iter()
        .filter(|d| super::crypto_handler::ws_room_for_peer(ws_room_peers, d).is_some())
        .collect();
    // Offline-but-real devices (Step 9A) — see `offline_session_devices`. Self
    // fan-out passes None to skip this (never push our own phone).
    if let Some(olm) = olm {
        set.extend(offline_session_devices(olm, ws_room_peers, master));
    }
    // Union: peers physically in the DM room that resolve to this master (always
    // included — live presence trumps the stored list, and is reachable by definition).
    set.extend(room_peers_of_master(ws_room_peers, dm_room, master));
    if let Some(ex) = exclude {
        set.remove(ex);
    }
    // Never target the bare master (no device authenticates as it) — except the
    // single-device fallback below, where master == device id by definition.
    set.remove(master);
    if set.is_empty() && !fallback_self.is_empty() {
        return vec![fallback_self.to_string()];
    }
    set.into_iter().collect()
}

/// Offline-but-real devices of one master (Step 9A push): a known device of
/// this master that is NOT in a room but we DO hold an Olm session with. The
/// resolver's `devices_for` reflects the signed device list MINUS revoked
/// tombstones (Step 7 `forget`s a revoked device), so it's the authoritative
/// "real devices" set; intersecting with `has_session` drops never-contacted
/// ghosts (a real offline phone we've messaged has a session; a ghost we never
/// established one with does not). These hit `send_dm_to_device`'s
/// session+offline branch → relay buffers under the device id + pushes its
/// token → the quit phone's background fetch (which now auths as that device)
/// decrypts the preview. Without this a fully-quit phone was never targeted at
/// all → no push (the Step 9A break). Also the target predicate for the
/// channel-push offline fan-out (same "real offline device" definition).
fn offline_session_devices(
    olm: &OlmManager,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    master: &str,
) -> Vec<String> {
    super::resolver::devices_for(master)
        .into_iter()
        .filter(|d| {
            super::crypto_handler::ws_room_for_peer(ws_room_peers, d).is_none()
                && olm.has_session(d)
        })
        .collect()
}

/// Peers currently present in `room` whose identity resolves to `master`.
fn room_peers_of_master(
    ws_room_peers: &HashMap<String, HashSet<String>>,
    room: &str,
    master: &str,
) -> Vec<String> {
    let Some(peers) = ws_room_peers.get(room) else {
        return Vec::new();
    };
    peers
        .iter()
        .filter(|p| super::resolver::resolve(p) == master)
        .cloned()
        .collect()
}

/// Send one already-signed DM envelope to ONE concrete device peer_id (Phase 6
/// multi-device fan-out). This is the per-device half of `handle_send_message`,
/// split out so the master→devices loop can run it once per target. `device_peer`
/// is always a real device id (or the master id itself for a single-device
/// recipient), never a master that no device authenticates as.
///
/// Three branches, identical in shape to the pre-fan-out code, just keyed by the
/// device id:
///   - session + online → encrypt and deliver now,
///   - session + offline → encrypt to the DM room (push trigger) + queue for
///     reconnect,
///   - no session → queue + KeyRequest (drained on session establishment).
#[allow(clippy::too_many_arguments)]
async fn send_dm_to_device(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    key_request_in_flight: &mut HashMap<String, std::time::Instant>,
    // THIS device's identity — signs the KeyRequest (Fix B).
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    device_peer: &str,
    envelope_json: &str,
    dm_room: &str,
    // True when `device_peer` is one of OUR OWN sibling devices (self-echo fan-out),
    // not the genuine recipient. A sibling mirror is NEVER notification-worthy, so
    // when the sibling is offline we must NOT do the "encrypt to DM room (push
    // trigger)" room-send (the relay would fire an FCM push and the sibling would
    // buzz for OUR OWN outgoing message). We still queue it for silent delivery on
    // the sibling's next reconnect (+ Step 5 backfill closes any residual gap).
    is_sibling: bool,
) {
    // EXACT-device reachability, not the identity-wide `peer_is_reachable`: in a
    // fan-out, device A may be online while sibling device B is offline. The
    // identity-wide check would report B "reachable" (because A is), send B's
    // copy down the online path, and `send_encrypted_message`'s own
    // `ws_room_for_peer` (exact membership) would then find no room for B and
    // DROP it with no offline buffering. Checking exact membership here routes an
    // offline-but-sibling-online device into the offline-buffer branch correctly.
    let device_online = super::crypto_handler::ws_room_for_peer(ws_room_peers, device_peer).is_some();

    if !olm.has_session(device_peer) {
        // No session with this device — queue the signed envelope. Drained when
        // the device reconnects (PeerJoined/RoomMembers/KeyBundle).
        queue_dm_key_request(
            ws_cmd_tx, ws_room_peers, pending_messages, key_request_in_flight,
            device_keypair, device_peer_id, device_peer, envelope_json, device_online,
        );
        return;
    }
    if device_online && !is_sibling {
        send_dm_online_recipient(
            olm, crypto_store, event_tx, ws_cmd_tx, pending_messages,
            device_peer, envelope_json, dm_room,
        ).await;
    } else if is_sibling && device_online {
        // Our OWN sibling device, online — send the self-echo NOW. Siblings meet
        // in inbox:{our_master}, NOT dm_room_code(M,M), so route via the flexible
        // ws_room_for_peer lookup (which finds the inbox room), NOT the DM room.
        // The multi-room one-way risk doesn't apply here: a sibling shares only
        // the inbox room with us, so the lookup is unambiguous.
        send_encrypted_message(
            olm, crypto_store, device_peer, envelope_json,
            event_tx, ws_cmd_tx, ws_room_peers,
        ).await;
        queue_pending_envelope(pending_messages, device_peer, envelope_json);
    } else if is_sibling {
        // Session exists but our OWN sibling device is offline. Do NOT room-send
        // (that would trigger a push — Pixel buzzing for VM's own message). Just
        // queue for silent delivery when the sibling reconnects; Step 5 backfill
        // also closes the gap on next inbox-join.
        queue_pending_envelope(pending_messages, device_peer, envelope_json);
    } else {
        send_dm_offline_recipient(olm, crypto_store, ws_cmd_tx, device_peer, envelope_json, dm_room);
        // Also queue for when this device comes back online (push may fail).
        queue_pending_envelope(pending_messages, device_peer, envelope_json);
    }
}

/// Genuine recipient device, online — encrypt and send into the DETERMINISTIC
/// DM room (the master-pair `dm_room_code` the caller computed), NOT a
/// `ws_room_for_peer` lookup. When the recipient's device is co-present in more
/// than one of our rooms (its DM room PLUS an inbox/server room during
/// friend-handshake churn), the first-match lookup inside
/// send_encrypted_message can pick a room the recipient has since left → the
/// relay buffers the frame against a room they never rejoin and it's silently
/// lost (the one-way DM bug: sends "succeed" but never arrive). The offline
/// path (`send_dm_offline_recipient`) already routes by dm_room for this exact
/// reason; the online path must too. Every device of the FRIEND is a member of
/// dm_room. NOTE: siblings never take this path — they meet in
/// inbox:{our_master}, NOT dm_room_code(M,M), so dm_room is wrong for them;
/// the sibling self-echo path keeps the flexible lookup.
#[allow(clippy::too_many_arguments)]
async fn send_dm_online_recipient(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    device_peer: &str,
    envelope_json: &str,
    dm_room: &str,
) {
    match encrypt_dm_wire(olm, crypto_store, device_peer, envelope_json, /*log_prekey*/ true) {
        Ok(json) => {
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
                room_code: dm_room.to_string(),
                target_peer: device_peer.to_string(),
                data: json.into_bytes(),
            });
        }
        Err(e) => {
            let _ = event_tx
                .send(NetworkEvent::MessageSendFailed {
                    to_peer: device_peer.to_string(),
                    error: format!("Encryption failed: {e}"),
                })
                .await;
        }
    }
    // ALSO queue for re-delivery on the next session (re)establishment.
    // The relay never ACKs a direct message, and a session we believe is
    // confirmed bidirectional can be silently dead on the PEER's side —
    // the classic "KeyRequest while we hold a session — peer lost theirs"
    // desync, which is acute right after a device link (the freshly-linked
    // sibling and its source churn their ratchet during the snapshot
    // handshake). A DM encrypted on that doomed ratchet is undecryptable and,
    // without this queue, lost forever (it was the "first sibling DM never
    // mirrors, every later one does" bug). The re-key/decrypt-fail path
    // (swarm.rs), PeerJoined, and KeyBundle all `.remove()`-drain this queue
    // on a FRESH session, re-delivering the envelope; the receiver dedups by
    // `message_id`, so the redundant copy on a healthy session is harmless.
    // Cap per-device so a long-lived healthy session (no reconnect to drain
    // it) can't grow the queue unbounded.
    const RETRY_QUEUE_CAP: usize = 20;
    let q = pending_messages.entry(device_peer.to_string()).or_default();
    q.push(envelope_json.to_string());
    if q.len() > RETRY_QUEUE_CAP {
        let overflow = q.len() - RETRY_QUEUE_CAP;
        q.drain(0..overflow);
    }
}

/// Session exists but the recipient device is offline — encrypt and send to the
/// DM room anyway. The relay sees the target isn't in the room and triggers a
/// push notification. The DM room is the MASTER-pair room (computed once by the
/// caller from the recipient's master) — every device of the recipient is a
/// member of it. `dm_room_code` is pure now, so we must NOT recompute it from
/// `device_peer` here (that would key the room on the device id, not the
/// identity).
fn send_dm_offline_recipient(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    device_peer: &str,
    envelope_json: &str,
    dm_room: &str,
) {
    match encrypt_dm_wire(olm, crypto_store, device_peer, envelope_json, /*log_prekey*/ false) {
        Ok(json) => {
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
                room_code: dm_room.to_string(),
                target_peer: device_peer.to_string(),
                data: json.into_bytes(),
            });
            hollow_log!("[HOLLOW-PUSH] Sent encrypted DM to offline {device_peer} via DM room (push trigger)");
        }
        Err(e) => {
            hollow_log!("[HOLLOW-PUSH] Encrypt for offline {device_peer} failed: {e}");
        }
    }
}

/// Encrypt one signed DM envelope to one device's Olm session and wrap it as
/// `HavenMessage::Encrypted` wire JSON. Persists the ratcheted session on
/// success only (encrypt failure leaves the stored session untouched).
fn encrypt_dm_wire(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    device_peer: &str,
    envelope_json: &str,
    log_prekey: bool,
) -> Result<String, String> {
    let (msg_type, ciphertext) = olm
        .encrypt(device_peer, envelope_json.as_bytes())
        .map_err(|e| e.to_string())?;
    super::crypto_handler::persist_olm_session(olm, crypto_store, device_peer);
    if log_prekey && msg_type == 0 {
        hollow_log!("[HOLLOW-CRYPTO] Sending PreKey (type 0) to {device_peer}");
    }
    let identity_key = if msg_type == 0 {
        Some(olm.identity_key_base64())
    } else {
        None
    };
    let haven_msg = HavenMessage::Encrypted {
        message_type: msg_type,
        body: OlmManager::encode_base64(&ciphertext),
        identity_key,
    };
    Ok(serde_json::to_string(&haven_msg).unwrap_or_default())
}

/// Queue one signed envelope under a DEVICE id for silent re-delivery on that
/// device's next session (re)establishment / reconnect drain.
fn queue_pending_envelope(
    pending_messages: &mut HashMap<String, Vec<String>>,
    device_peer: &str,
    envelope_json: &str,
) {
    pending_messages
        .entry(device_peer.to_string())
        .or_default()
        .push(envelope_json.to_string());
}

/// No Olm session with this device — queue the signed envelope (drained on
/// PeerJoined/RoomMembers/KeyBundle) and fire a throttled KeyRequest.
#[allow(clippy::too_many_arguments)]
fn queue_dm_key_request(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    key_request_in_flight: &mut HashMap<String, std::time::Instant>,
    // THIS device's identity — signs the KeyRequest (Fix B).
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    device_peer: &str,
    envelope_json: &str,
    device_online: bool,
) {
    queue_pending_envelope(pending_messages, device_peer, envelope_json);

    let req_fresh = key_request_in_flight
        .get(device_peer)
        .is_some_and(|t| t.elapsed() < std::time::Duration::from_secs(10));
    if !req_fresh {
        hollow_log!("[HOLLOW-SWARM] No session for {device_peer}, sending KeyRequest");
        // Only mark in-flight if we actually sent it — exact-device presence
        // gates the send, so don't strand the timestamp on an offline device.
        if device_online {
            send_message_to_peer(
                ws_cmd_tx, ws_room_peers,
                device_peer,
                super::crypto_handler::signed_key_request(
                    device_keypair, device_peer_id, device_peer,
                ),
            );
            key_request_in_flight.insert(device_peer.to_string(), std::time::Instant::now());
        }
    }
}

// ── 2. SendChannelMessage ────────────────────────────────────────────

pub(crate) async fn handle_send_channel_message(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    mls: &mut Option<MlsManager>,
    server_states: &HashMap<String, ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    text: String,
    message_id: String,
    reply_to_mid: Option<String>,
    link_preview: Option<LinkPreviewRef>,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-SWARM] SendChannelMessage for channel {channel_id} in server {server_id} mid={message_id}");

    let server = match server_states.get(&server_id) {
        Some(s) => s,
        None => {
            let _ = event_tx.send(NetworkEvent::Error {
                message: format!("Unknown server {server_id}"),
            }).await;
            return;
        }
    };

    // Posting permission + moderation trio gates (mute / media-only / slow mode).
    // Receivers drop violations too — these are the cooperative-client fast-fail path.
    if let Some(message) = channel_send_gate_error(
        server, local_peer_str, &server_id, &channel_id, db_path, db_passphrase,
    ).await {
        let _ = event_tx.send(NetworkEvent::Error { message }).await;
        return;
    }

    let local_peer = local_peer_str.to_string();

    // Lamport-bumped send stamp — see the DM send / chat_clock.rs.
    let order_us = crate::chat_clock::next_send_stamp_us();
    let timestamp = order_us / 1000;

    // Sign the message before encryption.
    let signing_payload = message_signing_payload(
        "ch", &format!("{}:{}", server_id, channel_id),
        &local_peer, timestamp, &text,
    );
    let (sig, pk) = sign_message(bundle_keypair, pub_key_b64, &signing_payload);

    // Mention metadata — shared by the notification hint and the offline push
    // fan-out below.
    let (has_everyone, mentioned_names) = channel_mention_meta(&text);

    // Wire bytes of the message as broadcast to the room — re-delivered to
    // OFFLINE members via targeted 0x09 frames (relay offline buffer). The MLS
    // group ciphertext / signed public plaintext is decryptable by any member,
    // so one encryption serves both paths. None on the legacy Olm fan-out path
    // (pairwise sessions can't pre-encrypt for offline peers without burning
    // ratchet slots) — those members still get a content-free wake push.
    let offline_wire_bytes: Option<Vec<u8>> = if server.is_channel_public(&channel_id) {
        // Public channels: plaintext broadcast (no MLS/Olm). Guests receive it too.
        let msg = HavenMessage::PublicChannelMessage {
            server_id: server_id.clone(),
            channel_id: channel_id.clone(),
            text: text.clone(),
            ts: timestamp,
            sig: sig.clone(),
            pk: pk.clone(),
            mid: message_id.clone(),
            reply_to: reply_to_mid.clone(),
            file_id: None,
            link_preview: link_preview.clone(),
        };
        send_public_channel_msg(ws_cmd_tx, &server_id, &msg)
    } else {
        let envelope = MessageEnvelope::ChannelMessage {
            inner: Box::new(ChannelMessagePayload {
                sid: server_id.clone(),
                cid: channel_id.clone(),
                text: text.clone(),
                ts: timestamp,
                sig: sig.clone(),
                pk: pk.clone(),
                mid: Some(message_id.clone()),
                reply_to: reply_to_mid.clone(),
                file_id: None,
                link_preview: link_preview.clone(),
                order_us: Some(order_us),
            }),
        };
        broadcast_channel_envelope(
            olm, crypto_store, mls, event_tx, ws_cmd_tx, ws_room_peers,
            server, local_peer_str, &server_id, &channel_id, &envelope,
            "Encrypt failed, falling back to Olm", /*bootstrap_subgroup*/ true,
        ).await
    };

    // Broadcast notification hint via SendToRoom (reaches all room members, even unsubscribed).
    {
        let hint = HavenMessage::ChannelNotificationHint {
            server_id: server_id.clone(),
            channel_id: channel_id.clone(),
            message_id: message_id.clone(),
            has_everyone,
            mentioned_names: mentioned_names.clone(),
            is_reply: reply_to_mid.is_some(),
        };
        if let Ok(hint_bytes) = serde_json::to_vec(&hint) {
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom {
                room_code: server_id.clone(),
                data: hint_bytes,
            });
        }
    }

    // ── Offline-member push fan-out (channel push notifications) ─────────
    queue_offline_channel_push(
        olm, ws_cmd_tx, ws_room_peers, server, local_peer_str,
        &server_id, &channel_id, reply_to_mid.as_deref(),
        has_everyone, &mentioned_names, &offline_wire_bytes,
        db_path, db_passphrase,
    );

    // Persist locally with same timestamp as sent.
    persist_sent_channel_message(
        &server_id, &channel_id, &local_peer, &text, timestamp,
        sig.as_deref(), pk.as_deref(), &message_id,
        reply_to_mid.as_deref(), order_us, &link_preview,
        db_path, db_passphrase,
    );

    // Hydrate the optimistic Dart entry with sig/pk so the
    // Message Proof dialog shows VERIFIED without a restart.
    let _ = event_tx.send(NetworkEvent::ChannelMessageSent {
        server_id: server_id.clone(),
        channel_id: channel_id.clone(),
        message_id: message_id.clone(),
        timestamp,
        signature: sig.clone(),
        public_key: pk.clone(),
    }).await;
}

/// Cooperative-client fast-fail gates for a channel send: posting permission +
/// the moderation trio (mute / media-only / slow mode). Receivers drop
/// violations too. Returns the user-facing error for the FIRST failed gate,
/// `None` when the send may proceed. Async — the slow-mode check reads the
/// `MessageStore` on the blocking pool (SQLCipher key derivation is expensive
/// and must not stall the event loop).
async fn channel_send_gate_error(
    server: &ServerState,
    local_peer_str: &str,
    server_id: &str,
    channel_id: &str,
    db_path: &str,
    db_passphrase: &str,
) -> Option<String> {
    if !server.can_post_in_channel(local_peer_str, channel_id) {
        return Some("You don't have permission to post in this channel".to_string());
    }
    if let Some(message) = muted_send_error(server, local_peer_str) {
        return Some(message);
    }
    if server.is_channel_media_only(channel_id) {
        // Standalone text is rejected; captions ride the file send path.
        return Some("This is a media-only channel — attach an image, GIF, or video".to_string());
    }
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    slow_mode_wait_error(
        server, local_peer_str, server_id, channel_id,
        now_ms, db_path, db_passphrase,
    ).await
}

/// Send-side mute gate (master-keyed, lazy expiry — the same lookup the
/// new-message gate uses): `Some(error)` when we are muted on this server.
/// Shared by the new-message, edit, and add-reaction send paths. Deletes and
/// reaction removals are deliberately NOT gated — removing your own content
/// is always allowed — and slow mode / media-only never apply to
/// edits/deletes/reactions.
fn muted_send_error(server: &ServerState, local_peer_str: &str) -> Option<String> {
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;
    if server.is_muted(local_peer_str, now_ms) {
        return Some("You are muted on this server".to_string());
    }
    None
}

/// Slow-mode half of the send gates: error when our own latest message in the
/// channel is still inside the slow-mode window. The Mod+ exemption
/// short-circuits BEFORE any store access; the open+query hops onto the
/// blocking pool.
async fn slow_mode_wait_error(
    server: &ServerState,
    local_peer_str: &str,
    server_id: &str,
    channel_id: &str,
    now_ms: i64,
    db_path: &str,
    db_passphrase: &str,
) -> Option<String> {
    let slow = server.channel_slow_mode(channel_id);
    if slow == 0 || server.bypasses_slow_mode(local_peer_str) {
        return None;
    }
    let last_ts = latest_own_channel_ts_blocking(server_id, channel_id, db_path, db_passphrase).await?;
    let next_allowed = last_ts + (slow as i64) * 1000;
    if now_ms < next_allowed {
        let wait_s = ((next_allowed - now_ms) + 999) / 1000;
        return Some(format!("Slow mode is on — wait {wait_s}s before sending again"));
    }
    None
}

/// Our own latest message ts in a channel, read on the blocking pool with
/// owned captures — the store is created and dropped entirely inside the
/// closure (rusqlite `Connection` is !Sync, never held across an .await).
/// Store-open failure = `None` (gate allows — mirrors the original inline
/// behavior). Shared with the channel file send gate (file_handler).
pub(crate) async fn latest_own_channel_ts_blocking(
    server_id: &str,
    channel_id: &str,
    db_path: &str,
    db_passphrase: &str,
) -> Option<i64> {
    let sid = server_id.to_string();
    let cid = channel_id.to_string();
    let path = db_path.to_string();
    let pass = db_passphrase.to_string();
    tokio::task::spawn_blocking(move || {
        let store = crate::storage::MessageStore::open(&path, &pass).ok()?;
        store.latest_own_channel_ts(&sid, &cid)
    })
    .await
    .ok()
    .flatten()
}

/// Mention metadata for one outgoing channel message: (`has_everyone`,
/// mentioned @names minus "everyone").
fn channel_mention_meta(text: &str) -> (bool, Vec<String>) {
    let has_at = text.contains('@');
    let has_everyone = has_at && text.contains("@everyone");
    let mut mentioned_names: Vec<String> = Vec::new();
    if has_at {
        for word in text.split_whitespace() {
            if let Some(name) = word.strip_prefix('@') {
                if !name.is_empty() && name != "everyone" {
                    mentioned_names.push(name.to_string());
                }
            }
        }
    }
    (has_everyone, mentioned_names)
}

/// Serialize + broadcast one public-channel `HavenMessage` to the server room
/// (plaintext — no MLS/Olm; guests receive it too, still Ed25519-signed).
/// Returns the wire bytes for the offline 0x09 push fan-out.
fn send_public_channel_msg(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    server_id: &str,
    msg: &HavenMessage,
) -> Option<Vec<u8>> {
    let data = serde_json::to_vec(msg).ok()?;
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom {
        room_code: server_id.to_string(),
        data: data.clone(),
    });
    Some(data)
}

/// Broadcast one non-public channel envelope to the server. MLS path: encrypt
/// once → single WS topic broadcast to the room; restricted channels (Option B)
/// encrypt under their per-channel subgroup instead of the server-wide group.
/// Olm per-device fan-out is the fallback (MLS encrypt failure) and the
/// pre-bootstrap path (no group yet). Returns the MLS wire bytes for the
/// offline 0x09 push fan-out when the MLS broadcast succeeded, `None`
/// otherwise. `bootstrap_subgroup` additionally kicks off subgroup bootstrap on
/// the no-group path (ALL content sends — a client that only edits/reacts must
/// still escape the Olm fallback; `request_subgroup_bootstrap` is cheap and
/// no-ops when we're the coordinator or nobody qualifying is online).
/// Shared driver for send/edit/delete/add-reaction/remove-reaction.
#[allow(clippy::too_many_arguments)]
async fn broadcast_channel_envelope(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    server: &ServerState,
    local_peer_str: &str,
    server_id: &str,
    channel_id: &str,
    envelope: &MessageEnvelope,
    mls_fail_log: &str,
    bootstrap_subgroup: bool,
) -> Option<Vec<u8>> {
    let use_subgroup = server.channel_uses_subgroup(channel_id);
    let group_key = if use_subgroup {
        crate::crypto::subgroup_id(server_id, channel_id)
    } else {
        server_id.to_string()
    };
    let use_mls = mls.as_ref().is_some_and(|m| m.has_group(&group_key));
    if use_mls {
        match send_mls_broadcast_topic(mls.as_mut().unwrap(), ws_cmd_tx, server_id, channel_id, use_subgroup, envelope, crypto_store) {
            Ok(wire_bytes) => return Some(wire_bytes),
            Err(e) => {
                hollow_log!("[HOLLOW-MLS] {mls_fail_log}: {e}");
                let envelope_json = serde_json::to_string(envelope).unwrap_or_default();
                olm_fanout_channel_envelope(
                    olm, crypto_store, event_tx, ws_cmd_tx, ws_room_peers,
                    server, local_peer_str, channel_id, use_subgroup, &envelope_json,
                ).await;
            }
        }
        return None;
    }
    // Subgroup not yet bootstrapped (or legacy server with no MLS group):
    // Olm fan-out to qualifying members, and (for a restricted channel) kick
    // off subgroup bootstrap by sending our KeyPackage to the subgroup
    // coordinator so future messages can use the subgroup.
    if bootstrap_subgroup && use_subgroup {
        if let Some(mls_mgr) = mls.as_mut() {
            super::crypto_handler::request_subgroup_bootstrap(
                mls_mgr, ws_cmd_tx, ws_room_peers, server,
                server_id, channel_id, local_peer_str,
            );
        }
    }
    let envelope_json = serde_json::to_string(envelope).unwrap_or_default();
    olm_fanout_channel_envelope(
        olm, crypto_store, event_tx, ws_cmd_tx, ws_room_peers,
        server, local_peer_str, channel_id, use_subgroup, &envelope_json,
    ).await;
    None
}

/// Olm fan-out of one channel envelope JSON to every qualifying server member.
/// Olm is per-device: encrypt to EACH online device of the member. Subgroup
/// channels only fan to members who can see the channel.
#[allow(clippy::too_many_arguments)]
async fn olm_fanout_channel_envelope(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    server: &ServerState,
    local_peer_str: &str,
    channel_id: &str,
    use_subgroup: bool,
    envelope_json: &str,
) {
    for member_peer_str in server.members.keys() {
        if super::resolver::same_identity(member_peer_str, local_peer_str) { continue; }
        // Subgroup: only fan to members who qualify for the channel.
        if use_subgroup && !server.can_see_channel(member_peer_str, channel_id) { continue; }
        for dev in crate::node::crypto_handler::online_devices_for(ws_room_peers, member_peer_str) {
            send_encrypted_message(
                olm, crypto_store,
                &dev, envelope_json,
                event_tx,
                ws_cmd_tx, ws_room_peers,
            ).await;
        }
    }
}

/// Offline-member push fan-out (channel push notifications). Room/topic
/// broadcasts only reach ONLINE peers; offline members get the message later
/// via channel sync. To make their phones light up NOW, hand the relay one
/// targeted 0x09 frame per offline member: the same wire bytes the room just
/// received (buffered + replayed to that member's background fetch node) plus
/// push metadata (channel + per-target mention flag) the relay filters against
/// the member's registered push prefs. The relay never learns server
/// membership — the SENDER picks the targets from its CRDT. Sync — may open
/// the `MessageStore` (reply-author lookup).
#[allow(clippy::too_many_arguments)]
fn queue_offline_channel_push(
    olm: &OlmManager,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    server: &ServerState,
    local_peer_str: &str,
    server_id: &str,
    channel_id: &str,
    reply_to_mid: Option<&str>,
    has_everyone: bool,
    mentioned_names: &[String],
    offline_wire_bytes: &Option<Vec<u8>>,
    db_path: &str,
    db_passphrase: &str,
) {
    // `server.members` is MASTER-keyed (Step 6). Pick masters who are NOT
    // reachable by ANY of their devices, and who aren't us.
    let offline_members: Vec<&String> = server.members.keys()
        .filter(|p| {
            !super::resolver::same_identity(p, local_peer_str)
                && !peer_is_reachable(ws_room_peers, p)
                // Restricted channel (Option B): only members who can see the
                // channel get the ciphertext + push (others can't decrypt it).
                && server.can_see_channel(p, channel_id)
        })
        .collect();
    if offline_members.is_empty() {
        return;
    }
    // A reply mentions the replied-to message's author.
    let reply_author: Option<String> = reply_to_mid.and_then(|mid| {
        crate::storage::MessageStore::open(db_path, db_passphrase)
            .ok()
            .and_then(|s| s.get_channel_message_sender(mid))
    });
    hollow_log!(
        "[HOLLOW-PUSH] Channel push fan-out: {} offline member(s) for {}/{}",
        offline_members.len(), server_id, channel_id
    );
    for member in offline_members {
        let mentioned = member_is_mentioned(
            server, member, has_everyone, reply_author.as_deref(), mentioned_names,
        );
        // Expand the offline MASTER member into its real DEVICE ids — the
        // relay keys the push token + offline buffer by DEVICE id (Step 9A).
        // Targeting the bare master buffers under an id no device authenticates
        // as → no push reaches any device. Real-device predicate mirrors the
        // DM fan-out (`offline_session_devices`): a known device of this master,
        // offline (not in a room), that we hold an Olm session with (drops
        // never-contacted ghosts). A single-device member (no device links) →
        // fall back to the master id, which IS that member's device id =
        // pre-multi-device behavior.
        let mut targets = offline_session_devices(olm, ws_room_peers, member);
        if targets.is_empty() {
            targets.push(member.clone());
        }
        for target in targets {
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendChannelDirect {
                room_code: server_id.to_string(),
                target_peer: target,
                channel_id: channel_id.to_string(),
                mention: mentioned,
                data: offline_wire_bytes.clone().unwrap_or_default(),
            });
        }
    }
}

/// Mention flag per MEMBER (master) for the channel push: @everyone, a reply to
/// their message, or their display name / nickname mentioned.
fn member_is_mentioned(
    server: &ServerState,
    member: &str,
    has_everyone: bool,
    reply_author: Option<&str>,
    mentioned_names: &[String],
) -> bool {
    has_everyone
        || reply_author == Some(member)
        || (!mentioned_names.is_empty() && {
            let display = server.members.get(member)
                .map(|m| m.display_name.as_str())
                .unwrap_or("");
            let nick = server.nicknames.get(member).map(|n| n.read().as_str());
            mentioned_names.iter().any(|n| {
                (!display.is_empty() && n.eq_ignore_ascii_case(display))
                    || nick.is_some_and(|nk| n.eq_ignore_ascii_case(nk))
            })
        })
}

/// Persist our own outgoing channel message locally with the same signed
/// timestamp we sent (no Dart DateTime.now() mismatch). Sync — owns the store.
#[allow(clippy::too_many_arguments)]
fn persist_sent_channel_message(
    server_id: &str,
    channel_id: &str,
    local_peer: &str,
    text: &str,
    timestamp: i64,
    sig: Option<&str>,
    pk: Option<&str>,
    message_id: &str,
    reply_to_mid: Option<&str>,
    order_us: i64,
    link_preview: &Option<LinkPreviewRef>,
    db_path: &str,
    db_passphrase: &str,
) {
    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else {
        return;
    };
    let _ = store.insert_channel_message(
        server_id, channel_id, local_peer, text, true, timestamp,
        sig, pk, Some(message_id),
        reply_to_mid, None, Some(order_us),
    );
    if let Some(lp) = link_preview {
        if let Ok(lp_json) = serde_json::to_string(lp) {
            let _ = store.update_channel_link_preview(message_id, &lp_json);
        }
    }
}

// ── 3. EditChannelMessage ────────────────────────────────────────────

pub(crate) async fn handle_edit_channel_message(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    mls: &mut Option<MlsManager>,
    server_states: &HashMap<String, ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    message_id: String,
    new_text: String,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-SWARM] EditChannelMessage {message_id} in {server_id}/{channel_id}");

    let server = match server_states.get(&server_id) {
        Some(s) => s,
        None => {
            let _ = event_tx.send(NetworkEvent::Error {
                message: format!("Unknown server {server_id}"),
            }).await;
            return;
        }
    };

    // Moderation gate: mute blocks edits (authoring content) exactly like the
    // new-message send gate; receivers drop a muted member's edits too.
    // Deletes stay allowed — removing your own content is never blocked —
    // and slow mode / media-only don't apply to edits.
    if let Some(message) = muted_send_error(server, local_peer_str) {
        let _ = event_tx.send(NetworkEvent::Error { message }).await;
        return;
    }

    let local_peer = local_peer_str.to_string();
    let edit_timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    // Sign the edit using the canonical payload format so
    // the Dart verifier (which reconstructs from the current
    // message state) can verify edited messages.
    let signing_payload = message_signing_payload(
        "ch",
        &format!("{}:{}", server_id, channel_id),
        &local_peer,
        edit_timestamp,
        &new_text,
    );
    let (sig, pk) = sign_message(bundle_keypair, pub_key_b64, &signing_payload);

    // Update local DB (preserves old text in message_edits table).
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let _ = store.edit_channel_message(
                &message_id, &new_text, edit_timestamp,
                sig.as_deref(), pk.as_deref(),
            );
        }
    }

    // Broadcast edit to all server members.
    if server.is_channel_public(&channel_id) {
        let msg = HavenMessage::PublicChannelEdit {
            server_id: server_id.clone(), channel_id: channel_id.clone(),
            mid: message_id.clone(), text: new_text.clone(),
            ts: edit_timestamp, sig: sig.clone(), pk: pk.clone(),
        };
        send_public_channel_msg(ws_cmd_tx, &server_id, &msg);
    } else {
        let envelope = MessageEnvelope::EditMessage {
            mid: message_id.clone(),
            text: new_text.clone(),
            ts: edit_timestamp,
            sig: sig.clone(),
            pk: pk.clone(),
            sid: Some(server_id.clone()),
            cid: Some(channel_id.clone()),
        };
        broadcast_channel_envelope(
            olm, crypto_store, mls, event_tx, ws_cmd_tx, ws_room_peers,
            server, local_peer_str, &server_id, &channel_id, &envelope,
            "Edit encrypt failed, falling back to Olm", /*bootstrap_subgroup*/ true,
        ).await;
    }

    let _ = event_tx.send(NetworkEvent::ChannelMessageEdited {
        server_id,
        channel_id,
        message_id,
        new_text,
        edited_at: edit_timestamp,
        signature: sig,
        public_key: pk,
    }).await;
}

// ── 4. EditDmMessage ─────────────────────────────────────────────────

#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_edit_dm_message(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    key_request_in_flight: &mut HashMap<String, std::time::Instant>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
    // THIS device's keypair — signs the Olm KeyRequest (Fix B).
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    peer_id_str: String,
    message_id: String,
    new_text: String,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-SWARM] EditDmMessage {message_id} for {peer_id_str}");

    let local_peer = local_peer_str.to_string();
    let edit_timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    // Sign the edit using the canonical payload format so
    // the Dart verifier (which reconstructs from the current
    // message state) can verify edited messages.
    let signing_payload = message_signing_payload(
        "dm",
        &peer_id_str,
        &local_peer,
        edit_timestamp,
        &new_text,
    );
    let (sig, pk) = sign_message(bundle_keypair, pub_key_b64, &signing_payload);

    // Update local DB.
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let _ = store.edit_dm_message(
                &message_id, &new_text, edit_timestamp,
                sig.as_deref(), pk.as_deref(),
            );
        }
    }

    // Update any queued pending message (pre-edit text → edited text) so a later
    // PeerJoined drain sends the edited text, not the stale original. Multi-device:
    // the original message was queued PER DEVICE (under device ids, not the master),
    // so scan every queue rather than only the master's.
    rewrite_pending_dm_edits(pending_messages, &message_id, &new_text, edit_timestamp, &sig, &pk);

    // Send edit to the DM peer.
    let envelope = MessageEnvelope::EditMessage {
        mid: message_id.clone(),
        text: new_text.clone(),
        ts: edit_timestamp,
        sig: sig.clone(),
        pk: pk.clone(),
        sid: None,
        cid: None,
    };
    let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();

    // Multi-device fan-out (Step 3): deliver the edit to every device of the
    // recipient + our own siblings. A device with no session yet gets the whole
    // edited conversation via Step 5 backfill.
    let recipient_master = super::resolver::resolve(&peer_id_str);
    fan_out_dm_envelope(
        olm, crypto_store, event_tx, ws_cmd_tx, ws_room_peers,
        pending_messages, key_request_in_flight,
        local_peer_str, device_keypair, device_peer_id, &recipient_master, &envelope_json,
        None, // edit/delete/reaction: sibling resolves convo by mid on receive
    ).await;

    // Emit event so Dart updates UI — include sig/pk so the
    // in-memory message's fields match the canonical payload.
    // Multi-device: the DM thread key is the peer's MASTER id (no-op single-device).
    let _ = event_tx.send(NetworkEvent::DmMessageEdited {
        peer_id: super::resolver::resolve(&peer_id_str),
        message_id,
        new_text,
        edited_at: edit_timestamp,
        signature: sig,
        public_key: pk,
    }).await;
}

/// Rewrite every queued copy of an edited DM (pre-edit text → edited text)
/// across ALL per-device pending queues, so a later PeerJoined drain sends the
/// edited text, not the stale original.
fn rewrite_pending_dm_edits(
    pending_messages: &mut HashMap<String, Vec<String>>,
    message_id: &str,
    new_text: &str,
    edit_timestamp: i64,
    sig: &Option<String>,
    pk: &Option<String>,
) {
    for queued in pending_messages.values_mut() {
        for entry in queued.iter_mut() {
            rewrite_pending_entry_if_edited(entry, message_id, new_text, edit_timestamp, sig, pk);
        }
    }
}

/// Replace ONE queued envelope's text in place when it is the DirectMessage
/// being edited. Preserves the original `order_us` (ordering unchanged on edit).
fn rewrite_pending_entry_if_edited(
    entry: &mut String,
    message_id: &str,
    new_text: &str,
    edit_timestamp: i64,
    sig: &Option<String>,
    pk: &Option<String>,
) {
    let Ok(env) = serde_json::from_str::<MessageEnvelope>(entry) else {
        return;
    };
    let MessageEnvelope::DirectMessage { inner } = env else {
        return;
    };
    if inner.mid.as_deref() != Some(message_id) {
        return;
    }
    let updated = MessageEnvelope::DirectMessage {
        inner: Box::new(DirectMessagePayload {
            text: new_text.to_string(),
            ts: edit_timestamp,
            sig: sig.clone(),
            pk: pk.clone(),
            mid: inner.mid.clone(),
            reply_to: inner.reply_to.clone(),
            file_id: inner.file_id.clone(),
            link_preview: inner.link_preview.clone(),
            convo: inner.convo.clone(),
            order_us: inner.order_us, // preserve original ordering on edit
        }),
    };
    if let Ok(json) = serde_json::to_string(&updated) {
        *entry = json;
        hollow_log!("[HOLLOW-SWARM] Updated pending message {message_id} with edited text");
    }
}

// ── 5. DeleteChannelMessage ──────────────────────────────────────────

pub(crate) async fn handle_delete_channel_message(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    mls: &mut Option<MlsManager>,
    server_states: &HashMap<String, ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    message_id: String,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-SWARM] DeleteChannelMessage {message_id} in {server_id}/{channel_id}");

    let server = match server_states.get(&server_id) {
        Some(s) => s,
        None => {
            let _ = event_tx.send(NetworkEvent::Error {
                message: format!("Unknown server {server_id}"),
            }).await;
            return;
        }
    };

    let local_peer = local_peer_str.to_string();
    let delete_timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    // Sign the deletion using the canonical payload format
    // with the text at deletion time. Uses "ch-delete" msg
    // type so a delete signature cannot be confused with or
    // replayed as a send signature. Fetches current text
    // from DB so the archive viewer (later) can verify the
    // delete against the same state the exporter saw.
    let current_text = crate::storage::MessageStore::open(db_path, db_passphrase)
        .ok()
        .and_then(|store| store.get_channel_message_text(&message_id))
        .unwrap_or_default();

    let signing_payload = message_signing_payload(
        "ch-delete",
        &format!("{}:{}", server_id, channel_id),
        &local_peer,
        delete_timestamp,
        &current_text,
    );
    let (sig, pk) = sign_message(bundle_keypair, pub_key_b64, &signing_payload);

    // Hide in local DB (preserves text in message_deletions table).
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let _ = store.hide_channel_message(
                &message_id, delete_timestamp,
                sig.as_deref(), pk.as_deref(),
            );
        }
    }

    // Broadcast deletion to all server members.
    if server.is_channel_public(&channel_id) {
        let msg = HavenMessage::PublicChannelDelete {
            server_id: server_id.clone(), channel_id: channel_id.clone(),
            mid: message_id.clone(), ts: delete_timestamp,
            sig: sig.clone(), pk: pk.clone(),
        };
        send_public_channel_msg(ws_cmd_tx, &server_id, &msg);
    } else {
        let envelope = MessageEnvelope::DeleteMessage {
            mid: message_id.clone(),
            ts: delete_timestamp,
            sig: sig.clone(),
            pk: pk.clone(),
            sid: Some(server_id.clone()),
            cid: Some(channel_id.clone()),
        };
        broadcast_channel_envelope(
            olm, crypto_store, mls, event_tx, ws_cmd_tx, ws_room_peers,
            server, local_peer_str, &server_id, &channel_id, &envelope,
            "Delete encrypt failed, falling back to Olm", /*bootstrap_subgroup*/ true,
        ).await;
    }

    let _ = event_tx.send(NetworkEvent::ChannelMessageDeleted {
        server_id,
        channel_id,
        message_id,
        deleted_at: delete_timestamp,
    }).await;
}

// ── 6. DeleteDmMessage ───────────────────────────────────────────────

#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_delete_dm_message(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    key_request_in_flight: &mut HashMap<String, std::time::Instant>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
    // THIS device's keypair — signs the Olm KeyRequest (Fix B).
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    peer_id_str: String,
    message_id: String,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-SWARM] DeleteDmMessage {message_id} for {peer_id_str}");

    let local_peer = local_peer_str.to_string();
    let delete_timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    // Sign the deletion using the canonical payload format
    // with the text at deletion time. Uses "dm-delete" msg
    // type — distinct from "dm" to prevent replay.
    let current_text = crate::storage::MessageStore::open(db_path, db_passphrase)
        .ok()
        .and_then(|store| store.get_dm_message_text(&message_id))
        .unwrap_or_default();

    let signing_payload = message_signing_payload(
        "dm-delete",
        &peer_id_str,
        &local_peer,
        delete_timestamp,
        &current_text,
    );
    let (sig, pk) = sign_message(bundle_keypair, pub_key_b64, &signing_payload);

    // Hide in local DB.
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let _ = store.hide_dm_message(
                &message_id, delete_timestamp,
                sig.as_deref(), pk.as_deref(),
            );
        }
    }

    // Send deletion to the DM peer.
    let envelope = MessageEnvelope::DeleteMessage {
        mid: message_id.clone(),
        ts: delete_timestamp,
        sig: sig.clone(),
        pk: pk.clone(),
        sid: None,
        cid: None,
    };
    let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();

    // Multi-device fan-out (Step 3): deliver the deletion to every device of the
    // recipient + our own siblings (offline devices get it buffered/queued).
    let recipient_master = super::resolver::resolve(&peer_id_str);
    fan_out_dm_envelope(
        olm, crypto_store, event_tx, ws_cmd_tx, ws_room_peers,
        pending_messages, key_request_in_flight,
        local_peer_str, device_keypair, device_peer_id, &recipient_master, &envelope_json,
        None, // edit/delete/reaction: sibling resolves convo by mid on receive
    ).await;

    // Emit event so Dart updates UI.
    // Multi-device: the DM thread key is the peer's MASTER id (no-op single-device).
    let _ = event_tx.send(NetworkEvent::DmMessageDeleted {
        peer_id: super::resolver::resolve(&peer_id_str),
        message_id,
        deleted_at: delete_timestamp,
    }).await;
}

// ── 7. AddChannelReaction ────────────────────────────────────────────

pub(crate) async fn handle_add_channel_reaction(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    mls: &mut Option<MlsManager>,
    server_states: &HashMap<String, ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    message_id: String,
    emoji: String,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-SWARM] AddChannelReaction {emoji} on {message_id} in {server_id}/{channel_id}");

    let server = match server_states.get(&server_id) {
        Some(s) => s,
        None => {
            let _ = event_tx.send(NetworkEvent::Error {
                message: format!("Unknown server {server_id}"),
            }).await;
            return;
        }
    };

    // Moderation gate: mute blocks adding reactions (authoring content)
    // exactly like the new-message send gate; receivers drop them too.
    // Removing a reaction stays allowed — removing your own content is never
    // blocked — and slow mode / media-only don't apply to reactions.
    if let Some(message) = muted_send_error(server, local_peer_str) {
        let _ = event_tx.send(NetworkEvent::Error { message }).await;
        return;
    }

    let local_peer = local_peer_str.to_string();
    let reaction_ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    let signing_payload = format!("reaction:{}:{}:{}", message_id, emoji, reaction_ts);
    let (sig, pk) = sign_message(bundle_keypair, pub_key_b64, &signing_payload);

    // Save to local DB.
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let _ = store.add_reaction(
                &message_id, &emoji, &local_peer, reaction_ts,
                sig.as_deref(), pk.as_deref(),
            );
        }
    }

    // Broadcast to all server members.
    if server.is_channel_public(&channel_id) {
        let msg = HavenMessage::PublicChannelAddReaction {
            server_id: server_id.clone(), channel_id: channel_id.clone(),
            mid: message_id.clone(), emoji: emoji.clone(),
            ts: reaction_ts, sig: sig.clone(), pk: pk.clone(),
        };
        send_public_channel_msg(ws_cmd_tx, &server_id, &msg);
    } else {
        let envelope = MessageEnvelope::AddReaction {
            mid: message_id.clone(),
            emoji: emoji.clone(),
            ts: reaction_ts,
            sig: sig.clone(),
            pk: pk.clone(),
            sid: Some(server_id.clone()),
            cid: Some(channel_id.clone()),
        };
        broadcast_channel_envelope(
            olm, crypto_store, mls, event_tx, ws_cmd_tx, ws_room_peers,
            server, local_peer_str, &server_id, &channel_id, &envelope,
            "Reaction encrypt failed, falling back to Olm", /*bootstrap_subgroup*/ true,
        ).await;
    }

    let _ = event_tx.send(NetworkEvent::ChannelReactionAdded {
        server_id,
        channel_id,
        message_id,
        emoji,
        reactor: local_peer,
        added_at: reaction_ts,
    }).await;
}

// ── 8. AddDmReaction ─────────────────────────────────────────────────

#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_add_dm_reaction(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    key_request_in_flight: &mut HashMap<String, std::time::Instant>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
    // THIS device's keypair — signs the Olm KeyRequest (Fix B).
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    peer_id_str: String,
    message_id: String,
    emoji: String,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-SWARM] AddDmReaction {emoji} on {message_id} for {peer_id_str}");

    let local_peer = local_peer_str.to_string();
    let reaction_ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    let signing_payload = format!("reaction:{}:{}:{}", message_id, emoji, reaction_ts);
    let (sig, pk) = sign_message(bundle_keypair, pub_key_b64, &signing_payload);

    // Multi-device: attribute our own reaction to our MASTER id so it lands under
    // the same identity on our other devices (no-op single-device).
    let reactor_master = super::resolver::resolve(&local_peer);

    // Save to local DB.
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let _ = store.add_reaction(
                &message_id, &emoji, &reactor_master, reaction_ts,
                sig.as_deref(), pk.as_deref(),
            );
        }
    }

    // Send to DM peer.
    let envelope = MessageEnvelope::AddReaction {
        mid: message_id.clone(),
        emoji: emoji.clone(),
        ts: reaction_ts,
        sig: sig.clone(),
        pk: pk.clone(),
        sid: None,
        cid: None,
    };
    let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();

    // Multi-device fan-out (Step 3): every device of the recipient + our siblings.
    let recipient_master = super::resolver::resolve(&peer_id_str);
    fan_out_dm_envelope(
        olm, crypto_store, event_tx, ws_cmd_tx, ws_room_peers,
        pending_messages, key_request_in_flight,
        local_peer_str, device_keypair, device_peer_id, &recipient_master, &envelope_json,
        None, // edit/delete/reaction: sibling resolves convo by mid on receive
    ).await;

    let _ = event_tx.send(NetworkEvent::DmReactionAdded {
        peer_id: super::resolver::resolve(&peer_id_str),
        message_id,
        emoji,
        reactor: reactor_master,
        added_at: reaction_ts,
    }).await;
}

// ── 9. RemoveChannelReaction ─────────────────────────────────────────

pub(crate) async fn handle_remove_channel_reaction(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    mls: &mut Option<MlsManager>,
    server_states: &HashMap<String, ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    message_id: String,
    emoji: String,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-SWARM] RemoveChannelReaction {emoji} on {message_id} in {server_id}/{channel_id}");

    let server = match server_states.get(&server_id) {
        Some(s) => s,
        None => {
            let _ = event_tx.send(NetworkEvent::Error {
                message: format!("Unknown server {server_id}"),
            }).await;
            return;
        }
    };

    let local_peer = local_peer_str.to_string();
    let remove_ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    let signing_payload = format!("unreaction:{}:{}:{}", message_id, emoji, remove_ts);
    let (sig, pk) = sign_message(bundle_keypair, pub_key_b64, &signing_payload);

    // Remove from local DB.
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let _ = store.remove_reaction(
                &message_id, &emoji, &local_peer, remove_ts,
                sig.as_deref(), pk.as_deref(),
            );
        }
    }

    // Broadcast to all server members.
    if server.is_channel_public(&channel_id) {
        let msg = HavenMessage::PublicChannelRemoveReaction {
            server_id: server_id.clone(), channel_id: channel_id.clone(),
            mid: message_id.clone(), emoji: emoji.clone(),
            ts: remove_ts, sig: sig.clone(), pk: pk.clone(),
        };
        send_public_channel_msg(ws_cmd_tx, &server_id, &msg);
    } else {
        let envelope = MessageEnvelope::RemoveReaction {
            mid: message_id.clone(),
            emoji: emoji.clone(),
            ts: remove_ts,
            sig: sig.clone(),
            pk: pk.clone(),
            sid: Some(server_id.clone()),
            cid: Some(channel_id.clone()),
        };
        broadcast_channel_envelope(
            olm, crypto_store, mls, event_tx, ws_cmd_tx, ws_room_peers,
            server, local_peer_str, &server_id, &channel_id, &envelope,
            "Remove reaction encrypt failed, Olm fallback", /*bootstrap_subgroup*/ true,
        ).await;
    }

    let _ = event_tx.send(NetworkEvent::ChannelReactionRemoved {
        server_id,
        channel_id,
        message_id,
        emoji,
        reactor: local_peer,
        removed_at: remove_ts,
    }).await;
}

// ── 10. RemoveDmReaction ─────────────────────────────────────────────

#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_remove_dm_reaction(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    key_request_in_flight: &mut HashMap<String, std::time::Instant>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
    // THIS device's keypair — signs the Olm KeyRequest (Fix B).
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    peer_id_str: String,
    message_id: String,
    emoji: String,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-SWARM] RemoveDmReaction {emoji} on {message_id} for {peer_id_str}");

    let local_peer = local_peer_str.to_string();
    let remove_ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    let signing_payload = format!("unreaction:{}:{}:{}", message_id, emoji, remove_ts);
    let (sig, pk) = sign_message(bundle_keypair, pub_key_b64, &signing_payload);

    // Multi-device: our own reaction is keyed by our MASTER id (see AddDmReaction).
    let reactor_master = super::resolver::resolve(&local_peer);

    // Remove from local DB.
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let _ = store.remove_reaction(
                &message_id, &emoji, &reactor_master, remove_ts,
                sig.as_deref(), pk.as_deref(),
            );
        }
    }

    // Send to DM peer.
    let envelope = MessageEnvelope::RemoveReaction {
        mid: message_id.clone(),
        emoji: emoji.clone(),
        ts: remove_ts,
        sig: sig.clone(),
        pk: pk.clone(),
        sid: None,
        cid: None,
    };
    let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();

    // Multi-device fan-out (Step 3): every device of the recipient + our siblings.
    let recipient_master = super::resolver::resolve(&peer_id_str);
    fan_out_dm_envelope(
        olm, crypto_store, event_tx, ws_cmd_tx, ws_room_peers,
        pending_messages, key_request_in_flight,
        local_peer_str, device_keypair, device_peer_id, &recipient_master, &envelope_json,
        None, // edit/delete/reaction: sibling resolves convo by mid on receive
    ).await;

    let _ = event_tx.send(NetworkEvent::DmReactionRemoved {
        peer_id: super::resolver::resolve(&peer_id_str),
        message_id,
        emoji,
        reactor: reactor_master,
        removed_at: remove_ts,
    }).await;
}

/// Handle `MessageEnvelope::ChannelMessage` (MLS-decrypted path).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_channel_message(
    event_tx: &mpsc::Sender<NetworkEvent>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    server_state: Option<&ServerState>,
    local_peer: &str,
    sender_peer_id: String,
    sid: String,
    cid: String,
    text: String,
    ts: i64,
    sig: Option<String>,
    pk: Option<String>,
    mid: Option<String>,
    reply_to: Option<String>,
    file_id: Option<String>,
    link_preview: Option<LinkPreviewRef>,
    order_us: Option<i64>,
    db_path: &str,
    db_passphrase: &str,
) {
    // SECURITY: conference chat NEVER rides the channel pipeline — it has its
    // own RAM-only HavenMessage::ConferenceChat path. A modified client
    // sending a ChannelMessage envelope under a conf group would otherwise
    // PERSIST into channel_messages (violating the live-only invariant), so
    // drop it here regardless of signature.
    if super::conference::is_conference_sid(&sid) {
        hollow_log!("[HOLLOW-SECURITY] Dropped ChannelMessage envelope for conference sid {sid}");
        return;
    }

    // SECURITY: a missing OR invalid signature is rejected — mirrors the direct
    // (non-MLS) twin in swarm.rs. Covers both callers: MLS-decrypted private
    // channels and plaintext PUBLIC channels, where this is the only authorship
    // binding there is.
    if channel_sig_rejected(&sender_peer_id, &sid, &cid, ts, &text, sig.as_deref(), pk.as_deref()) {
        return;
    }

    // Multi-device: a message from ANY of our own devices is ours.
    let is_mine = super::resolver::same_identity(&sender_peer_id, local_peer);

    // Moderation trio (receive-side): drop LIVE messages that violate the
    // channel's rules — see `live_channel_moderation_drop`.
    if let Some(state) = server_state {
        if live_channel_moderation_drop(
            state, &sender_peer_id, &sid, &cid, file_id.is_some(), ts, db_path, db_passphrase,
        ).await {
            return;
        }
    }

    let Some(is_new) = persist_incoming_channel_message(
        &sid, &cid, &sender_peer_id, &text, is_mine, ts,
        sig.as_deref(), pk.as_deref(), mid.as_deref(),
        reply_to.as_deref(), file_id.as_deref(), order_us,
        &link_preview, db_path, db_passphrase,
    ) else {
        // Store-open failure — the message is silently gone otherwise; log
        // channel + sender context (never content) so the drop is diagnosable.
        hollow_log!(
            "[HOLLOW-SWARM] DROPPED incoming channel message in {sid}/{cid} from {sender_peer_id} (mid={mid:?}) — MessageStore::open failed"
        );
        return;
    };
    // ALWAYS emit — a ChannelSyncBatch racing this live message inserts
    // the row first without emitting; suppressing the live event too left
    // the open pane stale until re-entry. Dart dedups by message_id and
    // skips unread/notifications when `duplicate`.
    let _ = event_tx.send(NetworkEvent::ChannelMessageReceived {
        server_id: sid,
        channel_id: cid,
        from_peer: sender_peer_id,
        text,
        timestamp: ts,
        message_id: mid.unwrap_or_default(),
        reply_to_mid: reply_to.unwrap_or_default(),
        link_preview,
        signature: sig,
        public_key: pk,
        duplicate: !is_new,
    }).await;
}

/// SECURITY: true = drop this LIVE channel message.
///
/// A signature is REQUIRED, not merely checked when present. The old
/// `if sig.is_none() { return false }` early-out was itself the bypass: strip
/// `sig`/`pk` and verification was skipped entirely.
///
/// This matters most for PUBLIC channels, which carry no MLS layer — there the
/// signature is the ONLY thing binding content and authorship to an Ed25519
/// identity, so without it a message's attribution rests entirely on the
/// relay-reported sender id. On MLS channels it is defence in depth behind group
/// membership.
///
/// LIVE ingest only. Sync backfill (`ChannelSyncBatch`, `sync_handler`)
/// deliberately still tolerates unsigned rows, so history predating per-message
/// signing (e2cc8ab, 2026-03-09) keeps replicating instead of diverging between
/// peers. Same live-enforce / backfill-tolerate split the moderation trio uses.
fn channel_sig_rejected(
    sender_peer_id: &str,
    sid: &str,
    cid: &str,
    ts: i64,
    text: &str,
    sig: Option<&str>,
    pk: Option<&str>,
) -> bool {
    let signing_payload = message_signing_payload(
        "ch", &format!("{}:{}", sid, cid),
        sender_peer_id, ts, text,
    );
    if !verify_message_signature(sender_peer_id, sig, pk, &signing_payload) {
        hollow_log!(
            "[HOLLOW-SECURITY] REJECTED ChannelMessage (MLS) from {sender_peer_id} — signature verification FAILED"
        );
        return true;
    }
    false
}

/// Receive-side moderation trio for one LIVE channel message: true = drop
/// (mute / media-only / slow-mode violation), so a modified client can't bypass
/// what receivers refuse to store. Sync backfill intentionally skips these
/// gates — history may legitimately predate a mute / slow-mode / media-only
/// change, and dropping it there would diverge stored history. Async — the
/// slow-mode window check reads the `MessageStore` on the blocking pool.
#[allow(clippy::too_many_arguments)]
async fn live_channel_moderation_drop(
    state: &ServerState,
    sender_peer_id: &str,
    sid: &str,
    cid: &str,
    has_file: bool,
    ts: i64,
    db_path: &str,
    db_passphrase: &str,
) -> bool {
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;
    if state.is_muted(sender_peer_id, now_ms) {
        hollow_log!("[HOLLOW-MOD] DROPPED channel message from muted member {sender_peer_id} in {sid}");
        return true;
    }
    if state.is_channel_media_only(cid) && !has_file {
        hollow_log!("[HOLLOW-MOD] DROPPED text-only message from {sender_peer_id} in media-only channel {cid}");
        return true;
    }
    let slow = state.channel_slow_mode(cid);
    if slow > 0 && !state.bypasses_slow_mode(sender_peer_id) {
        // Open+query on the blocking pool with owned captures (SQLCipher key
        // derivation is expensive; the store lives entirely inside the
        // closure — Connection is !Sync). Open failure = allow, as before.
        let window_start = ts - (slow as i64) * 1000;
        let (sid_o, cid_o) = (sid.to_string(), cid.to_string());
        let sender = sender_peer_id.to_string();
        let (path, pass) = (db_path.to_string(), db_passphrase.to_string());
        let violation = tokio::task::spawn_blocking(move || {
            crate::storage::MessageStore::open(&path, &pass)
                .map(|store| store.channel_sender_has_msg_in_range(&sid_o, &cid_o, &sender, window_start, ts))
                .unwrap_or(false)
        }).await.unwrap_or(false);
        if violation {
            hollow_log!("[HOLLOW-MOD] DROPPED slow-mode violation from {sender_peer_id} in {cid} (window {slow}s)");
            return true;
        }
    }
    false
}

/// LIVE-ingest mute gate shared by the edit and add-reaction envelope
/// handlers: true = drop (the sender is muted — master-keyed, lazy expiry;
/// every call site resolves the sender to its MASTER first). Mirrors the mute
/// half of `live_channel_moderation_drop`. Deletes and reaction removals stay
/// allowed — removing your own content is never blocked — and sync backfill
/// never routes through these handlers, so history predating a mute survives.
pub(crate) fn live_muted_ingest_drop(server_state: Option<&ServerState>, sender: &str, action: &str) -> bool {
    let Some(state) = server_state else { return false; };
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;
    if state.is_muted(sender, now_ms) {
        hollow_log!("[HOLLOW-MOD] DROPPED {action} from muted member {sender}");
        return true;
    }
    false
}

/// Persist one incoming channel message with message-id dedup (replays); the
/// content UNIQUE index is legacy-only (WHERE message_id IS NULL) so
/// identical-text spam in the same millisecond persists as distinct messages.
/// Returns `Some(is_new)`, or `None` when the store could not be opened (the
/// caller then emits nothing, matching the pre-split behavior). Sync — owns
/// the store.
#[allow(clippy::too_many_arguments)]
fn persist_incoming_channel_message(
    sid: &str,
    cid: &str,
    sender_peer_id: &str,
    text: &str,
    is_mine: bool,
    ts: i64,
    sig: Option<&str>,
    pk: Option<&str>,
    mid: Option<&str>,
    reply_to: Option<&str>,
    file_id: Option<&str>,
    order_us: Option<i64>,
    link_preview: &Option<LinkPreviewRef>,
    db_path: &str,
    db_passphrase: &str,
) -> Option<bool> {
    let store = crate::storage::MessageStore::open(db_path, db_passphrase).ok()?;
    let already = mid
        .map(|m| store.channel_message_exists(m))
        .unwrap_or(false);
    let is_new = if already {
        false
    } else {
        store.insert_channel_message(
            sid, cid, sender_peer_id, text, is_mine, ts,
            sig, pk, mid, reply_to, file_id, order_us,
        ).map(|r| r > 0).unwrap_or(false)
    };
    if is_new {
        if let (Some(lp), Some(message_id)) = (link_preview.as_ref(), mid) {
            if let Ok(lp_json) = serde_json::to_string(lp) {
                let _ = store.update_channel_link_preview(message_id, &lp_json);
            }
        }
    }
    Some(is_new)
}

/// Handle `MessageEnvelope::EditMessage` (MLS-decrypted path).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_edit_message(
    event_tx: &mpsc::Sender<NetworkEvent>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    server_state: Option<&ServerState>,
    peer_str: &str,
    mid: String,
    new_text: String,
    ts: i64,
    sig: Option<String>,
    pk: Option<String>,
    sid: Option<String>,
    cid: Option<String>,
    db_path: &str,
    db_passphrase: &str,
) {
    // Moderation (LIVE ingest only): drop edits from muted members, mirroring
    // the new-message ingest gate — a modified client can't author content
    // through the edit path while muted.
    if live_muted_ingest_drop(server_state, peer_str, "edit") {
        return;
    }
    let mut edit_applied = false;
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let sender = store.get_channel_message_sender(&mid);
        if sender.as_deref() == Some(peer_str) {
            let _ = store.edit_channel_message(
                &mid, &new_text, ts,
                sig.as_deref(), pk.as_deref(),
            );
            edit_applied = true;
        } else if sender.is_some() {
            hollow_log!("[HOLLOW-EDIT] MLS rejected: {peer_str} tried to edit message {mid} owned by {sender:?}");
        }
        // sender == None → message not synced yet; sync batch will bring the edited version.
    }
    if edit_applied {
        if let (Some(s_id), Some(c_id)) = (sid, cid) {
            let _ = event_tx.send(NetworkEvent::ChannelMessageEdited {
                server_id: s_id,
                channel_id: c_id,
                message_id: mid,
                new_text,
                edited_at: ts,
                signature: sig,
                public_key: pk,
            }).await;
        }
    }
}

/// Handle `MessageEnvelope::DeleteMessage` (MLS-decrypted path).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_delete_message(
    event_tx: &mpsc::Sender<NetworkEvent>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    sender_peer_id: &str,
    mid: String,
    ts: i64,
    sig: Option<String>,
    pk: Option<String>,
    sid: Option<String>,
    cid: Option<String>,
    db_path: &str,
    db_passphrase: &str,
) {
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let sender = store.get_channel_message_sender(&mid);
        if sender.as_deref() != Some(sender_peer_id) {
            hollow_log!("[HOLLOW-SECURITY] REJECTED MLS DeleteMessage from {sender_peer_id} — not the sender of {mid}");
            return;
        }
        let _ = store.hide_channel_message(
            &mid, ts,
            sig.as_deref(), pk.as_deref(),
        );
    }
    if let (Some(s_id), Some(c_id)) = (sid, cid) {
        let _ = event_tx.send(NetworkEvent::ChannelMessageDeleted {
            server_id: s_id,
            channel_id: c_id,
            message_id: mid,
            deleted_at: ts,
        }).await;
    }
}

/// Handle `MessageEnvelope::AddReaction` (MLS-decrypted path).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_add_reaction(
    event_tx: &mpsc::Sender<NetworkEvent>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    server_state: Option<&ServerState>,
    peer_str: &str,
    mid: String,
    emoji: String,
    ts: i64,
    sig: Option<String>,
    pk: Option<String>,
    sid: Option<String>,
    cid: Option<String>,
    db_path: &str,
    db_passphrase: &str,
) {
    // Choke-point validation for EVERY inbound add path (MLS envelope, Olm
    // fallback, public channel): short Unicode emoji or a well-formed custom
    // emote token — nothing else reaches the DB.
    if !super::emotes::valid_reaction_emoji(&emoji) {
        hollow_log!("[HOLLOW-SECURITY] REJECTED reaction from {peer_str} — invalid emoji string ({} bytes)", emoji.len());
        return;
    }
    // Moderation (LIVE ingest only): drop reactions from muted members,
    // mirroring the new-message ingest gate; reaction REMOVALS stay allowed.
    if live_muted_ingest_drop(server_state, peer_str, "reaction") {
        return;
    }
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let _ = store.add_reaction(
            &mid, &emoji, peer_str, ts,
            sig.as_deref(), pk.as_deref(),
        );
    }
    if let (Some(s_id), Some(c_id)) = (sid, cid) {
        let _ = event_tx.send(NetworkEvent::ChannelReactionAdded {
            server_id: s_id,
            channel_id: c_id,
            message_id: mid,
            emoji,
            reactor: peer_str.to_string(),
            added_at: ts,
        }).await;
    }
}

/// Handle `MessageEnvelope::RemoveReaction` (MLS-decrypted path).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_remove_reaction(
    event_tx: &mpsc::Sender<NetworkEvent>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    peer_str: &str,
    mid: String,
    emoji: String,
    ts: i64,
    sig: Option<String>,
    pk: Option<String>,
    sid: Option<String>,
    cid: Option<String>,
    db_path: &str,
    db_passphrase: &str,
) {
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let _ = store.remove_reaction(
            &mid, &emoji, peer_str, ts,
            sig.as_deref(), pk.as_deref(),
        );
    }
    if let (Some(s_id), Some(c_id)) = (sid, cid) {
        let _ = event_tx.send(NetworkEvent::ChannelReactionRemoved {
            server_id: s_id,
            channel_id: c_id,
            message_id: mid,
            emoji,
            reactor: peer_str.to_string(),
            removed_at: ts,
        }).await;
    }
}
