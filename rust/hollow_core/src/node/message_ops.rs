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

pub(crate) async fn handle_send_message(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    key_request_in_flight: &mut HashSet<String>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
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
    let envelope = MessageEnvelope::DirectMessage {
        inner: Box::new(DirectMessagePayload {
            text: text.clone(),
            ts: dm_timestamp,
            sig: sig.clone(),
            pk: pk.clone(),
            mid: Some(message_id.clone()),
            reply_to: reply_to_mid.clone(),
            file_id: None,
            link_preview: link_preview.clone(),
        }),
    };
    let envelope_json = serde_json::to_string(&envelope)
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

    if olm.has_session(&peer_id_str) && peer_is_reachable(ws_room_peers, &peer_id_str) {
        // Session exists and peer is online — encrypt and send.
        send_encrypted_message(
            olm,
            crypto_store,
            &peer_id_str,
            &envelope_json,
            event_tx,
            ws_cmd_tx, ws_room_peers,
        ).await;
    } else {
        // No session or peer offline — queue the signed envelope.
        // Messages will be drained when the peer reconnects (PeerJoined/RoomMembers).
        pending_messages
            .entry(peer_id_str.clone())
            .or_default()
            .push(envelope_json);

        if !olm.has_session(&peer_id_str) && !key_request_in_flight.contains(&peer_id_str) {
            hollow_log!("[HOLLOW-SWARM] No session for {peer_id_str}, sending KeyRequest");
            if peer_is_reachable(ws_room_peers, &peer_id_str) {
                send_message_to_peer(
                    ws_cmd_tx, ws_room_peers,
                    &peer_id_str, HavenMessage::KeyRequest,
                );
                key_request_in_flight.insert(peer_id_str.clone());
            }
        }
    }

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
    // MLS path: encrypt once → single WS broadcast to room.
    let use_mls = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
    if use_mls {
        match send_mls_broadcast_topic(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &channel_id, &envelope, crypto_store) {
            Ok(()) => {}
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

    // Broadcast notification hint via SendToRoom (reaches all room members, even unsubscribed).
    {
        let has_everyone = text.contains("@everyone");
        let mut mentioned_names = Vec::new();
        for word in text.split_whitespace() {
            if let Some(name) = word.strip_prefix('@') {
                if !name.is_empty() && name != "everyone" {
                    mentioned_names.push(name.to_string());
                }
            }
        }
        let hint = HavenMessage::ChannelNotificationHint {
            server_id: server_id.clone(),
            channel_id: channel_id.clone(),
            has_everyone,
            mentioned_names,
            is_reply: reply_to_mid.is_some(),
        };
        if let Ok(hint_bytes) = serde_json::to_vec(&hint) {
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom {
                room_code: server_id.clone(),
                data: hint_bytes,
            });
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
            Ok(()) => {}
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
        // Olm fan-out fallback.
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

    // Emit event so Dart updates UI — include sig/pk so the
    // in-memory message's fields match the canonical payload
    // reconstructed by the Message Proof dialog.
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

pub(crate) async fn handle_edit_dm_message(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
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

    if olm.has_session(&peer_id_str) {
        send_encrypted_message(
                                olm, crypto_store,
                                &peer_id_str, &envelope_json,
            event_tx,
                                    ws_cmd_tx, ws_room_peers,
        ).await;
    }

    // Emit event so Dart updates UI — include sig/pk so the
    // in-memory message's fields match the canonical payload.
    let _ = event_tx.send(NetworkEvent::DmMessageEdited {
        peer_id: peer_id_str,
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
            Ok(()) => {}
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
        // Olm fan-out fallback.
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

    // Emit event so Dart updates UI.
    let _ = event_tx.send(NetworkEvent::ChannelMessageDeleted {
        server_id,
        channel_id,
        message_id,
        deleted_at: delete_timestamp,
    }).await;
}

// ── 6. DeleteDmMessage ───────────────────────────────────────────────

pub(crate) async fn handle_delete_dm_message(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
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

    if olm.has_session(&peer_id_str) {
        send_encrypted_message(
                                olm, crypto_store,
                                &peer_id_str, &envelope_json,
            event_tx,
                                    ws_cmd_tx, ws_room_peers,
        ).await;
    }

    // Emit event so Dart updates UI.
    let _ = event_tx.send(NetworkEvent::DmMessageDeleted {
        peer_id: peer_id_str,
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
            Ok(()) => {}
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

pub(crate) async fn handle_add_dm_reaction(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
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

    // Save to local DB.
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let _ = store.add_reaction(
                &message_id, &emoji, &local_peer, reaction_ts,
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

    if olm.has_session(&peer_id_str) {
        send_encrypted_message(
                                olm, crypto_store,
                                &peer_id_str, &envelope_json,
            event_tx,
                                    ws_cmd_tx, ws_room_peers,
        ).await;
    }

    let _ = event_tx.send(NetworkEvent::DmReactionAdded {
        peer_id: peer_id_str,
        message_id,
        emoji,
        reactor: local_peer,
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
            Ok(()) => {}
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

pub(crate) async fn handle_remove_dm_reaction(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
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

    // Remove from local DB.
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let _ = store.remove_reaction(
                &message_id, &emoji, &local_peer, remove_ts,
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

    if olm.has_session(&peer_id_str) {
        send_encrypted_message(
                                olm, crypto_store,
                                &peer_id_str, &envelope_json,
            event_tx,
                                    ws_cmd_tx, ws_room_peers,
        ).await;
    }

    let _ = event_tx.send(NetworkEvent::DmReactionRemoved {
        peer_id: peer_id_str,
        message_id,
        emoji,
        reactor: local_peer,
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

    let is_mine = sender_peer_id == local_peer;

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
        } else {
            hollow_log!("[HOLLOW-EDIT] MLS rejected: {peer_str} tried to edit message {mid} owned by {sender:?}");
        }
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
