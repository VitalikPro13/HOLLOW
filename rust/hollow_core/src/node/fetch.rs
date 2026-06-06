//! Minimal background fetch node for FCM/APNs push notification Tier 2.
//!
//! Connects invisibly (fetch mode), joins one DM room, decrypts incoming
//! messages via Olm, and returns them. No servers, no CRDT, no MLS.

use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio_tungstenite::tungstenite::Message;

use crate::crypto::{CryptoStore, OlmManager};
#[allow(unused_imports)]
use crate::hollow_log;
use crate::node::crypto_handler::{persist_crypto_state, persist_olm_session};
use crate::node::types::{DirectMessagePayload, HavenMessage, MessageEnvelope};
use crate::node::ws_client;

/// A message fetched during background push processing.
pub(crate) struct FetchedDm {
    pub from_peer: String,
    pub text: String,
    pub timestamp: i64,
    pub message_id: String,
}

/// Run a one-shot fetch: connect invisibly, join one DM room, collect messages, return.
pub(crate) async fn run_fetch(
    relay_domain: &str,
    peer_id: &str,
    keypair_proto: &[u8],
    pub_key_b64: &str,
    license_key: Option<&str>,
    sender_peer_id: &str,
    timeout: Duration,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    db_path: &str,
    db_passphrase: &str,
) -> Result<Vec<FetchedDm>, String> {
    let relay_url = format!("wss://{relay_domain}/ws");
    let dm_room = crate::node::types::dm_room_code(peer_id, sender_peer_id);

    hollow_log!("[HOLLOW-FETCH] Connecting to {relay_url} (fetch mode) for DM room {dm_room}");

    let ws_stream = ws_client::connect_and_auth(
        &relay_url, peer_id, keypair_proto, pub_key_b64, license_key, true,
    )
    .await?;

    let (mut write, mut read) = ws_stream.split();

    // Join the single DM room.
    let join_msg = serde_json::json!({"type": "join", "room": dm_room});
    write
        .send(Message::Text(join_msg.to_string().into()))
        .await
        .map_err(|e| format!("Failed to join DM room: {e}"))?;

    hollow_log!("[HOLLOW-FETCH] Joined DM room, waiting for messages (timeout: {}s)", timeout.as_secs());

    let mut messages = Vec::new();
    let deadline = tokio::time::Instant::now() + timeout;
    // After the first message arrives, the relay replays its whole buffer
    // back-to-back. Switch to a short idle window so we drain the burst then
    // return promptly (Android only grants ~30s total).
    const IDLE_AFTER_FIRST: Duration = Duration::from_secs(2);

    loop {
        // Overall deadline caps the wait for the FIRST message; once we have
        // messages we only wait IDLE_AFTER_FIRST between subsequent frames.
        let until_deadline = deadline.saturating_duration_since(tokio::time::Instant::now());
        if until_deadline.is_zero() {
            hollow_log!("[HOLLOW-FETCH] Timeout reached, returning {} messages", messages.len());
            break;
        }
        let wait = if messages.is_empty() {
            until_deadline
        } else {
            IDLE_AFTER_FIRST.min(until_deadline)
        };

        let msg = match tokio::time::timeout(wait, read.next()).await {
            Ok(Some(Ok(msg))) => msg,
            Ok(Some(Err(e))) => {
                hollow_log!("[HOLLOW-FETCH] WS read error: {e}");
                break;
            }
            Ok(None) => {
                hollow_log!("[HOLLOW-FETCH] WS connection closed");
                break;
            }
            Err(_) => {
                // Idle/overall timeout — done collecting.
                hollow_log!("[HOLLOW-FETCH] Wait elapsed, returning {} messages", messages.len());
                break;
            }
        };

        match msg {
            Message::Text(text) => {
                if let Ok(server_msg) = serde_json::from_str::<serde_json::Value>(&*text) {
                    let msg_type = server_msg.get("type").and_then(|v| v.as_str()).unwrap_or("");
                    match msg_type {
                        "members" => {
                            hollow_log!("[HOLLOW-FETCH] Received room members");
                        }
                        "peer_joined" => {
                            // Sender came online in the room — messages may follow.
                        }
                        "direct" | "msg" => {
                            // Legacy text-direct path (kept as a fallback; real DMs
                            // arrive as binary 0x06 frames below).
                            let from = server_msg
                                .get("from")
                                .and_then(|v| v.as_str())
                                .unwrap_or("");
                            let data = server_msg
                                .get("data")
                                .and_then(|v| v.as_str())
                                .unwrap_or("");

                            if let Some(dm) =
                                try_decrypt_dm(from, data, olm, crypto_store, db_path, db_passphrase, peer_id)
                            {
                                persist_olm_session(olm, crypto_store, from);
                                messages.push(dm);
                            }
                        }
                        _ => {}
                    }
                }
            }
            Message::Binary(data) => {
                // Real DMs arrive as binary relay frames. The frame the relay
                // sends (live or replayed from the offline buffer) is:
                //   [0x06][room\0][sender\0][payload]
                // where payload is the HavenMessage JSON. Mirror the full node's
                // parser (ws_client.rs parse_binary_relay_frame).
                if data.len() > 3 && data[0] == 0x06 {
                    if let Some((from, payload)) = parse_direct_frame(&data[1..]) {
                        if let Some(dm) = try_decrypt_dm(
                            &from, &payload, olm, crypto_store, db_path, db_passphrase, peer_id,
                        ) {
                            persist_olm_session(olm, crypto_store, &from);
                            messages.push(dm);
                        }
                    }
                }
                // Other binary frames (file transfers, topic broadcast) — ignore.
            }
            Message::Close(_) => {
                hollow_log!("[HOLLOW-FETCH] WS close frame received");
                break;
            }
            _ => {}
        }
    }

    // Close WebSocket gracefully.
    let _ = write.close().await;

    hollow_log!("[HOLLOW-FETCH] Fetch complete, returning {} messages", messages.len());
    Ok(messages)
}

/// Parse the body of a relay direct frame (after the leading 0x06 type byte):
///   [room\0][sender\0][payload]
/// Returns (sender_peer_id, payload_as_utf8_string). The room code is not
/// needed here — the fetch node only joined the one DM room.
fn parse_direct_frame(body: &[u8]) -> Option<(String, String)> {
    let room_end = body.iter().position(|&b| b == 0)?;
    let after_room = &body[room_end + 1..];
    let sender_end = after_room.iter().position(|&b| b == 0)?;
    let sender = String::from_utf8_lossy(&after_room[..sender_end]).to_string();
    let payload = &after_room[sender_end + 1..];
    let payload_str = String::from_utf8_lossy(payload).to_string();
    Some((sender, payload_str))
}

/// Attempt to decrypt a single incoming WS message as a DM.
fn try_decrypt_dm(
    from: &str,
    data: &str,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    db_path: &str,
    db_passphrase: &str,
    _local_peer_id: &str,
) -> Option<FetchedDm> {
    let haven: HavenMessage = serde_json::from_str(data).ok()?;

    match haven {
        HavenMessage::Encrypted {
            message_type,
            body,
            identity_key,
        } => {
            let ciphertext = OlmManager::decode_base64(&body).ok()?;

            let plaintext = if message_type == 0 {
                // PreKeyMessage
                let their_identity = identity_key.as_deref()?;
                if olm.has_session(from) {
                    match olm.try_decrypt_prekey_with_existing(from, &ciphertext) {
                        Ok(pt) => pt,
                        Err(_) => {
                            olm.remove_session(from);
                            match olm.create_inbound_session(from, their_identity, &ciphertext) {
                                Ok(pt) => {
                                    persist_crypto_state(olm, crypto_store, from);
                                    pt
                                }
                                Err(e) => {
                                    hollow_log!("[HOLLOW-FETCH] PreKey session creation failed for {from}: {e}");
                                    return None;
                                }
                            }
                        }
                    }
                } else {
                    match olm.create_inbound_session(from, their_identity, &ciphertext) {
                        Ok(pt) => {
                            persist_crypto_state(olm, crypto_store, from);
                            pt
                        }
                        Err(e) => {
                            hollow_log!("[HOLLOW-FETCH] PreKey session creation failed for {from}: {e}");
                            return None;
                        }
                    }
                }
            } else {
                match olm.decrypt(from, message_type, &ciphertext) {
                    Ok(pt) => pt,
                    Err(e) => {
                        hollow_log!("[HOLLOW-FETCH] Decrypt failed for {from}: {e}");
                        return None;
                    }
                }
            };

            let text = String::from_utf8_lossy(&plaintext).to_string();
            match serde_json::from_str::<MessageEnvelope>(&text) {
                Ok(MessageEnvelope::DirectMessage { inner }) => {
                    let DirectMessagePayload {
                        text: msg_text,
                        ts,
                        mid,
                        reply_to,
                        file_id,
                        sig,
                        pk,
                        link_preview,
                        ..
                    } = *inner;

                    let msg_text = if msg_text.len() > 4000 {
                        msg_text[..4000].to_string()
                    } else {
                        msg_text
                    };

                    // Persist to DB so the full node doesn't re-fetch.
                    // Dedup by message_id: a replayed buffered message may also be
                    // pulled later by full-node DM-sync. Skip the INSERT if it
                    // already exists, but still surface it for the notification.
                    if let Ok(store) =
                        crate::storage::MessageStore::open(db_path, db_passphrase)
                    {
                        let already_exists = mid
                            .as_deref()
                            .map(|m| store.dm_message_exists(m))
                            .unwrap_or(false);
                        hollow_log!(
                            "[HOLLOW-FETCH] insert DM from={} mid={:?} ts={} exists={} text_len={}",
                            from, mid, ts, already_exists, msg_text.len()
                        );
                        if !already_exists {
                            let _ = store.insert(
                                from,
                                &msg_text,
                                false,
                                ts,
                                sig.as_deref(),
                                pk.as_deref(),
                                mid.as_deref(),
                                reply_to.as_deref(),
                                file_id.as_deref(),
                            );
                            if let (Some(lp), Some(message_id)) =
                                (link_preview.as_ref(), mid.as_ref())
                            {
                                if let Ok(lp_json) = serde_json::to_string(lp) {
                                    let _ = store.update_link_preview(message_id, &lp_json);
                                }
                            }
                        }
                    }

                    Some(FetchedDm {
                        from_peer: from.to_string(),
                        text: msg_text,
                        timestamp: ts,
                        message_id: mid.unwrap_or_default(),
                    })
                }
                Ok(MessageEnvelope::EditMessage { mid, text: new_text, ts, sig, pk, .. }) => {
                    // An edit to an offline peer is buffered + pushed too. Apply it
                    // to the existing row (by message_id) so the DB stays consistent
                    // with the sender — preventing the "edit appears as a second
                    // message" duplication when the full node later DM-syncs.
                    let new_text = if new_text.len() > 4000 {
                        new_text[..4000].to_string()
                    } else {
                        new_text
                    };
                    if let Ok(store) =
                        crate::storage::MessageStore::open(db_path, db_passphrase)
                    {
                        let applied = store
                            .edit_dm_message(&mid, &new_text, ts, sig.as_deref(), pk.as_deref())
                            .unwrap_or(false);
                        hollow_log!(
                            "[HOLLOW-FETCH] edit DM mid={mid} ts={ts} applied={applied} text_len={}",
                            new_text.len()
                        );
                        if !applied {
                            // Original not present yet (edit arrived before the
                            // message). Stamp edited_at if the row exists; otherwise
                            // the later DM-sync will carry the edited text with this
                            // mid and insert it once.
                            let _ = store.set_dm_message_edited_at(&mid, ts);
                        }
                    }
                    Some(FetchedDm {
                        from_peer: from.to_string(),
                        text: new_text,
                        timestamp: ts,
                        message_id: mid,
                    })
                }
                _ => None, // Other envelope types — ignore in fetch mode.
            }
        }
        _ => None,
    }
}
