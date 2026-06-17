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
    let dm_timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
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
                reply_to_mid.as_deref(), None,
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
        local_peer_str, device_peer_id, &recipient_master, &envelope_json,
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
    let recipient_devices = collect_target_devices(
        ws_room_peers, &dm_room, recipient_master, recipient_master, /*exclude*/ None,
    );
    for device_peer in &recipient_devices {
        send_dm_to_device(
            olm, crypto_store, event_tx, ws_cmd_tx, ws_room_peers,
            pending_messages, key_request_in_flight,
            device_peer, envelope_json, &dm_room, /*is_sibling*/ false,
        ).await;
    }

    // Our own sibling devices (self fan-out) get the convo-tagged variant when one
    // is supplied; otherwise the plain envelope. Same live-union logic, excluding
    // THIS device (never echo to ourselves).
    let own_master = super::resolver::resolve(local_peer_str);
    let sibling_json = sibling_envelope_json.unwrap_or(envelope_json);
    let mut siblings: HashSet<String> = collect_target_devices(
        ws_room_peers, &dm_room, &own_master, "", /*exclude*/ Some(device_peer_id),
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
            sibling, sibling_json, &dm_room, /*is_sibling*/ true,
        ).await;
    }
}

/// Build the set of device peer_ids to fan a DM out to for one master identity:
/// the persisted device list (`resolver::devices_for`) UNION every peer currently
/// in `dm_room` that resolves to `master`. The live-room union is what makes this
/// robust to a stale/polluted stored list — an online device is always included,
/// a ghost id in the stored list is harmless (it just queues + KeyRequests and
/// never connects). `fallback_self` is pushed only if the whole set is empty and
/// non-empty itself (single-device recipient → send to the master id as-is,
/// pre-multi-device behavior); pass "" to skip the fallback (self fan-out, where
/// "no siblings" must mean send to nobody). `exclude` drops one id (our own
/// device) from the result.
fn collect_target_devices(
    ws_room_peers: &HashMap<String, HashSet<String>>,
    dm_room: &str,
    master: &str,
    fallback_self: &str,
    exclude: Option<&str>,
) -> Vec<String> {
    let mut set: HashSet<String> = super::resolver::devices_for(master).into_iter().collect();
    // Union: peers physically in the DM room that resolve to this master.
    if let Some(peers) = ws_room_peers.get(dm_room) {
        for p in peers {
            if super::resolver::resolve(p) == master {
                set.insert(p.clone());
            }
        }
    }
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

    if olm.has_session(device_peer) {
        if device_online {
            // Session exists and device is online — encrypt and send.
            send_encrypted_message(
                olm,
                crypto_store,
                device_peer,
                envelope_json,
                event_tx,
                ws_cmd_tx, ws_room_peers,
            ).await;
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
        } else if is_sibling {
            // Session exists but our OWN sibling device is offline. Do NOT room-send
            // (that would trigger a push — Pixel buzzing for VM's own message). Just
            // queue for silent delivery when the sibling reconnects; Step 5 backfill
            // also closes the gap on next inbox-join.
            pending_messages
                .entry(device_peer.to_string())
                .or_default()
                .push(envelope_json.to_string());
        } else {
            // Session exists but device is offline — encrypt and send to DM room
            // anyway. The relay sees the target isn't in the room and triggers a
            // push notification.
            match olm.encrypt(device_peer, envelope_json.as_bytes()) {
                Ok((msg_type, ciphertext)) => {
                    super::crypto_handler::persist_olm_session(olm, crypto_store, device_peer);
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
                    // The DM room is the MASTER-pair room (computed once by the
                    // caller from the recipient's master) — every device of the
                    // recipient is a member of it. `dm_room_code` is pure now, so
                    // we must NOT recompute it from `device_peer` here (that would
                    // key the room on the device id, not the identity).
                    let json = serde_json::to_string(&haven_msg).unwrap_or_default();
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
            // Also queue for when this device comes back online (push may fail).
            pending_messages
                .entry(device_peer.to_string())
                .or_default()
                .push(envelope_json.to_string());
        }
    } else {
        // No session with this device — queue the signed envelope. Drained when
        // the device reconnects (PeerJoined/RoomMembers/KeyBundle).
        pending_messages
            .entry(device_peer.to_string())
            .or_default()
            .push(envelope_json.to_string());

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
                    device_peer, HavenMessage::KeyRequest,
                );
                key_request_in_flight.insert(device_peer.to_string(), std::time::Instant::now());
            }
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

    if !server.can_post_in_channel(local_peer_str, &channel_id) {
        let _ = event_tx.send(NetworkEvent::Error {
            message: "You don't have permission to post in this channel".to_string(),
        }).await;
        return;
    }

    let local_peer = local_peer_str.to_string();
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    // Sign the message before encryption.
    let signing_payload = message_signing_payload(
        "ch", &format!("{}:{}", server_id, channel_id),
        &local_peer, timestamp, &text,
    );
    let (sig, pk) = sign_message(bundle_keypair, pub_key_b64, &signing_payload);

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
        }),
    };
    // Mention metadata — shared by the notification hint and the offline push
    // fan-out below.
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

    // Wire bytes of the message as broadcast to the room — re-delivered to
    // OFFLINE members via targeted 0x09 frames (relay offline buffer). The MLS
    // group ciphertext / signed public plaintext is decryptable by any member,
    // so one encryption serves both paths. None on the legacy Olm fan-out path
    // (pairwise sessions can't pre-encrypt for offline peers without burning
    // ratchet slots) — those members still get a content-free wake push.
    let mut offline_wire_bytes: Option<Vec<u8>> = None;

    // Public channels: plaintext broadcast (no MLS/Olm). Guests receive it too.
    if server.is_channel_public(&channel_id) {
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
        if let Ok(data) = serde_json::to_vec(&msg) {
            offline_wire_bytes = Some(data.clone());
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom {
                room_code: server_id.clone(),
                data,
            });
        }
    } else {
        // MLS path: encrypt once → single WS broadcast to room.
        let use_mls = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
        if use_mls {
            match send_mls_broadcast_topic(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &channel_id, &envelope, crypto_store) {
                Ok(wire_bytes) => { offline_wire_bytes = Some(wire_bytes); }
                Err(e) => {
                    hollow_log!("[HOLLOW-MLS] Encrypt failed, falling back to Olm: {e}");
                    let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();
                    for member_peer_str in server.members.keys() {
                        if member_peer_str == &local_peer { continue; }
                            if peer_is_reachable(ws_room_peers, member_peer_str) {
                                send_encrypted_message(
                                    olm, crypto_store,
                                    member_peer_str, &envelope_json,
                                    event_tx,
                                    ws_cmd_tx, ws_room_peers,
                                ).await;
                            }
                    }
                }
            }
        } else {
            // Legacy Olm fan-out path.
            let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();
            for member_peer_str in server.members.keys() {
                if member_peer_str == &local_peer { continue; }
                    if peer_is_reachable(ws_room_peers, member_peer_str) {
                        send_encrypted_message(
                                    olm, crypto_store,
                                    member_peer_str, &envelope_json,
                            event_tx,
                                                                ws_cmd_tx, ws_room_peers,
                        ).await;
                    }
            }
        }
    }

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
    // Room/topic broadcasts only reach ONLINE peers; offline members get the
    // message later via channel sync. To make their phones light up NOW, hand
    // the relay one targeted 0x09 frame per offline member: the same wire bytes
    // the room just received (buffered + replayed to that member's background
    // fetch node) plus push metadata (channel + per-target mention flag) the
    // relay filters against the member's registered push prefs. The relay never
    // learns server membership — the SENDER picks the targets from its CRDT.
    {
        let offline_members: Vec<&String> = server.members.keys()
            .filter(|p| {
                p.as_str() != local_peer_str && !peer_is_reachable(ws_room_peers, p)
            })
            .collect();
        if !offline_members.is_empty() {
            // A reply mentions the replied-to message's author.
            let reply_author: Option<String> = reply_to_mid.as_deref().and_then(|mid| {
                crate::storage::MessageStore::open(db_path, db_passphrase)
                    .ok()
                    .and_then(|s| s.get_channel_message_sender(mid))
            });
            hollow_log!(
                "[HOLLOW-PUSH] Channel push fan-out: {} offline member(s) for {}/{}",
                offline_members.len(), server_id, channel_id
            );
            for member in offline_members {
                let mentioned = has_everyone
                    || reply_author.as_deref() == Some(member.as_str())
                    || (!mentioned_names.is_empty() && {
                        let display = server.members.get(member)
                            .map(|m| m.display_name.as_str())
                            .unwrap_or("");
                        let nick = server.nicknames.get(member).map(|n| n.read().as_str());
                        mentioned_names.iter().any(|n| {
                            (!display.is_empty() && n.eq_ignore_ascii_case(display))
                                || nick.is_some_and(|nk| n.eq_ignore_ascii_case(nk))
                        })
                    });
                let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendChannelDirect {
                    room_code: server_id.clone(),
                    target_peer: member.clone(),
                    channel_id: channel_id.clone(),
                    mention: mentioned,
                    data: offline_wire_bytes.clone().unwrap_or_default(),
                });
            }
        }
    }

    // Persist locally with same timestamp as sent.
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let _ = store.insert_channel_message(
            &server_id, &channel_id, &local_peer, &text, true, timestamp,
            sig.as_deref(), pk.as_deref(), Some(&message_id),
            reply_to_mid.as_deref(), None,
        );
        if let Some(lp) = &link_preview {
            if let Ok(lp_json) = serde_json::to_string(lp) {
                let _ = store.update_channel_link_preview(&message_id, &lp_json);
            }
        }
    }

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
        if let Ok(data) = serde_json::to_vec(&msg) {
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom {
                room_code: server_id.clone(), data,
            });
        }
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

        let use_mls = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
        if use_mls {
            match send_mls_broadcast_topic(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &channel_id, &envelope, crypto_store) {
                Ok(_) => {}
                Err(e) => {
                    hollow_log!("[HOLLOW-MLS] Edit encrypt failed, falling back to Olm: {e}");
                    let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();
                    for member_peer_str in server.members.keys() {
                        if member_peer_str == &local_peer { continue; }
                            if peer_is_reachable(ws_room_peers, member_peer_str) {
                                send_encrypted_message(
                                    olm, crypto_store,
                                    member_peer_str, &envelope_json,
                                    event_tx,
                                    ws_cmd_tx, ws_room_peers,
                                ).await;
                            }
                    }
                }
            }
        } else {
            let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();
            for member_peer_str in server.members.keys() {
                if member_peer_str == &local_peer { continue; }
                    if peer_is_reachable(ws_room_peers, member_peer_str) {
                        send_encrypted_message(
                            olm, crypto_store,
                            member_peer_str, &envelope_json,
                            event_tx,
                            ws_cmd_tx, ws_room_peers,
                        ).await;
                    }
            }
        }
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
    for queued in pending_messages.values_mut() {
        for entry in queued.iter_mut() {
            if let Ok(env) = serde_json::from_str::<MessageEnvelope>(entry) {
                if let MessageEnvelope::DirectMessage { ref inner } = env {
                    if inner.mid.as_deref() == Some(&message_id) {
                        let updated = MessageEnvelope::DirectMessage {
                            inner: Box::new(DirectMessagePayload {
                                text: new_text.clone(),
                                ts: edit_timestamp,
                                sig: sig.clone(),
                                pk: pk.clone(),
                                mid: inner.mid.clone(),
                                reply_to: inner.reply_to.clone(),
                                file_id: inner.file_id.clone(),
                                link_preview: inner.link_preview.clone(),
                                convo: inner.convo.clone(),
                            }),
                        };
                        if let Ok(json) = serde_json::to_string(&updated) {
                            *entry = json;
                            hollow_log!("[HOLLOW-SWARM] Updated pending message {message_id} with edited text");
                        }
                    }
                }
            }
        }
    }

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
        local_peer_str, device_peer_id, &recipient_master, &envelope_json,
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
        if let Ok(data) = serde_json::to_vec(&msg) {
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom {
                room_code: server_id.clone(), data,
            });
        }
    } else {
        let envelope = MessageEnvelope::DeleteMessage {
            mid: message_id.clone(),
            ts: delete_timestamp,
            sig: sig.clone(),
            pk: pk.clone(),
            sid: Some(server_id.clone()),
            cid: Some(channel_id.clone()),
        };

        let use_mls = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
        if use_mls {
            match send_mls_broadcast_topic(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &channel_id, &envelope, crypto_store) {
                Ok(_) => {}
                Err(e) => {
                    hollow_log!("[HOLLOW-MLS] Delete encrypt failed, falling back to Olm: {e}");
                    let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();
                    for member_peer_str in server.members.keys() {
                        if member_peer_str == &local_peer { continue; }
                            if peer_is_reachable(ws_room_peers, member_peer_str) {
                                send_encrypted_message(
                                    olm, crypto_store,
                                    member_peer_str, &envelope_json,
                                    event_tx,
                                    ws_cmd_tx, ws_room_peers,
                                ).await;
                            }
                    }
                }
            }
        } else {
            let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();
            for member_peer_str in server.members.keys() {
                if member_peer_str == &local_peer { continue; }
                    if peer_is_reachable(ws_room_peers, member_peer_str) {
                        send_encrypted_message(
                            olm, crypto_store,
                            member_peer_str, &envelope_json,
                            event_tx,
                            ws_cmd_tx, ws_room_peers,
                        ).await;
                    }
            }
        }
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
        local_peer_str, device_peer_id, &recipient_master, &envelope_json,
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
        if let Ok(data) = serde_json::to_vec(&msg) {
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom {
                room_code: server_id.clone(), data,
            });
        }
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

        let use_mls = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
        if use_mls {
            match send_mls_broadcast_topic(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &channel_id, &envelope, crypto_store) {
                Ok(_) => {}
                Err(e) => {
                    hollow_log!("[HOLLOW-MLS] Reaction encrypt failed, falling back to Olm: {e}");
                    let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();
                    for member_peer_str in server.members.keys() {
                        if member_peer_str == &local_peer { continue; }
                            if peer_is_reachable(ws_room_peers, member_peer_str) {
                                send_encrypted_message(
                                    olm, crypto_store,
                                    member_peer_str, &envelope_json,
                                    event_tx,
                                    ws_cmd_tx, ws_room_peers,
                                ).await;
                            }
                    }
                }
            }
        } else {
            let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();
            for member_peer_str in server.members.keys() {
                if member_peer_str == &local_peer { continue; }
                    if peer_is_reachable(ws_room_peers, member_peer_str) {
                        send_encrypted_message(
                            olm, crypto_store,
                            member_peer_str, &envelope_json,
                            event_tx,
                            ws_cmd_tx, ws_room_peers,
                        ).await;
                    }
            }
        }
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
        local_peer_str, device_peer_id, &recipient_master, &envelope_json,
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
        if let Ok(data) = serde_json::to_vec(&msg) {
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom {
                room_code: server_id.clone(), data,
            });
        }
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

        let use_mls = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
        if use_mls {
            match send_mls_broadcast_topic(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &channel_id, &envelope, crypto_store) {
                Ok(_) => {}
                Err(e) => {
                    hollow_log!("[HOLLOW-MLS] Remove reaction encrypt failed, Olm fallback: {e}");
                    let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();
                    for member_peer_str in server.members.keys() {
                        if member_peer_str == &local_peer { continue; }
                            if peer_is_reachable(ws_room_peers, member_peer_str) {
                                send_encrypted_message(
                                    olm, crypto_store,
                                    member_peer_str, &envelope_json,
                                    event_tx,
                                    ws_cmd_tx, ws_room_peers,
                                ).await;
                            }
                    }
                }
            }
        } else {
            let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();
            for member_peer_str in server.members.keys() {
                if member_peer_str == &local_peer { continue; }
                    if peer_is_reachable(ws_room_peers, member_peer_str) {
                        send_encrypted_message(
                            olm, crypto_store,
                            member_peer_str, &envelope_json,
                            event_tx,
                            ws_cmd_tx, ws_room_peers,
                        ).await;
                    }
            }
        }
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
        local_peer_str, device_peer_id, &recipient_master, &envelope_json,
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
    db_path: &str,
    db_passphrase: &str,
) {
    let signing_payload = message_signing_payload(
        "ch", &format!("{}:{}", sid, cid),
        &sender_peer_id, ts, &text,
    );
    verify_message_signature(
        &sender_peer_id,
        sig.as_deref(),
        pk.as_deref(),
        &signing_payload,
    );

    // Multi-device: a message from ANY of our own devices is ours.
    let is_mine = super::resolver::same_identity(&sender_peer_id, local_peer);

    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let rows = store.insert_channel_message(
            &sid, &cid, &sender_peer_id, &text, is_mine, ts,
            sig.as_deref(), pk.as_deref(), mid.as_deref(),
            reply_to.as_deref(), file_id.as_deref(),
        );
        let is_new = rows.as_ref().map(|&r| r > 0).unwrap_or(false);
        if is_new {
            if let (Some(lp), Some(message_id)) = (link_preview.as_ref(), mid.as_ref()) {
                if let Ok(lp_json) = serde_json::to_string(lp) {
                    let _ = store.update_channel_link_preview(message_id, &lp_json);
                }
            }
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
            }).await;
        }
    }
}

/// Handle `MessageEnvelope::EditMessage` (MLS-decrypted path).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_edit_message(
    event_tx: &mpsc::Sender<NetworkEvent>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
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
