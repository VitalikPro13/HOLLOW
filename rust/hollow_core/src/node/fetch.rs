//! Minimal background fetch node for FCM/APNs push notification Tier 2.
//!
//! Connects invisibly (fetch mode) and joins ONE room:
//! - DM wake: the DM room for the sender — decrypts buffered DMs via Olm.
//! - Channel wake: the SERVER room — decrypts buffered channel messages via
//!   MLS (group ciphertext fanned out per-offline-member as 0x09 frames by the
//!   sender) or reads signed public-channel plaintext. No CRDT, no gossip.

use std::time::Duration;

use base64::Engine;
use futures_util::{SinkExt, StreamExt};
use tokio_tungstenite::tungstenite::Message;

use crate::crypto::{CryptoStore, MlsManager, OlmManager};
#[allow(unused_imports)]
use crate::hollow_log;
use crate::node::crypto_handler::{persist_crypto_state, persist_mls_state, persist_olm_session};
use crate::node::types::{ChannelMessagePayload, DirectMessagePayload, HavenMessage, MessageEnvelope};
use crate::node::ws_client;

/// A message fetched during background push processing.
pub(crate) struct FetchedDm {
    pub from_peer: String,
    pub text: String,
    pub timestamp: i64,
    pub message_id: String,
    /// On-disk path to an inlined image written for this message (by message_id),
    /// for the notification's BigPicture preview. None for text-only messages.
    pub image_path: Option<String>,
    /// Set for channel messages (channel wake): the server this message belongs to.
    pub server_id: Option<String>,
    /// Set for channel messages (channel wake): the channel this message belongs to.
    pub channel_id: Option<String>,
}

/// Run a one-shot fetch: connect invisibly, join one room, collect messages, return.
///
/// `server_room`: when Some, this is a CHANNEL wake — join the server room and
/// decrypt channel messages (MLS via `mls` when available, public plaintext
/// otherwise). When None, this is a DM wake — join the DM room for
/// `sender_peer_id` and decrypt via Olm.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn run_fetch(
    relay_domain: &str,
    peer_id: &str,
    keypair_proto: &[u8],
    pub_key_b64: &str,
    license_key: Option<&str>,
    sender_peer_id: &str,
    server_room: Option<&str>,
    timeout: Duration,
    olm: &mut OlmManager,
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    db_path: &str,
    db_passphrase: &str,
) -> Result<Vec<FetchedDm>, String> {
    let relay_url = format!("wss://{relay_domain}/ws");
    let room = match server_room {
        Some(s) => s.to_string(),
        None => crate::node::types::dm_room_code(peer_id, sender_peer_id),
    };

    hollow_log!(
        "[HOLLOW-FETCH] Connecting to {relay_url} (fetch mode) for {} room {room}",
        if server_room.is_some() { "server" } else { "DM" }
    );

    let ws_stream = ws_client::connect_and_auth(
        &relay_url, peer_id, keypair_proto, pub_key_b64, license_key, true,
    )
    .await?;

    let (mut write, mut read) = ws_stream.split();

    // Join the single room (DM or server).
    let join_msg = serde_json::json!({"type": "join", "room": room});
    write
        .send(Message::Text(join_msg.to_string().into()))
        .await
        .map_err(|e| format!("Failed to join room: {e}"))?;

    hollow_log!("[HOLLOW-FETCH] Joined room, waiting for messages (timeout: {}s)", timeout.as_secs());
    let mut mls_dirty = false;

    let mut messages: Vec<FetchedDm> = Vec::new();
    let deadline = tokio::time::Instant::now() + timeout;
    // After the first message arrives, the relay replays its whole buffer
    // back-to-back. Switch to a short idle window so we drain the burst then
    // return PROMPTLY — the notification can't render content until run_fetch
    // returns, so this idle directly gates how fast the user sees the message.
    // 1.2s is enough to catch a back-to-back buffer replay over a mobile link
    // while keeping perceived latency low. The larger inlined-image FileHeader
    // case does NOT rely on this: when a text DM references a file but its image
    // bytes haven't arrived, `outstanding_image` below holds the connection open
    // to the full deadline instead, so images are never cut off.
    const IDLE_AFTER_FIRST: Duration = Duration::from_millis(1200);

    loop {
        // Overall deadline caps the wait for the FIRST message; once we have
        // messages we only wait IDLE_AFTER_FIRST between subsequent frames —
        // UNLESS we're still expecting a companion image (a text DM with a
        // file_id arrived but its image marker hasn't), in which case we hold
        // out to the full deadline so the image isn't cut off.
        // Outstanding image = a DM references a file (caption "[file:...]" or a
        // file_id) but no entry has delivered the image bytes (image_path) yet.
        // Hold the connection open to the full deadline so the larger FileHeader
        // frame isn't cut off by the short idle window.
        let outstanding_image = {
            let have_image = messages.iter().any(|m| m.image_path.is_some());
            let want_image = messages.iter().any(|m| m.text.starts_with("[file:"));
            want_image && !have_image
        };
        let until_deadline = deadline.saturating_duration_since(tokio::time::Instant::now());
        if until_deadline.is_zero() {
            hollow_log!("[HOLLOW-FETCH] Timeout reached, returning {} messages", messages.len());
            break;
        }
        let wait = if messages.is_empty() || outstanding_image {
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
                // Relay frames (payload = HavenMessage JSON):
                //   0x06 [room\0][sender\0][payload]          — direct (live or offline-buffer replay)
                //   0x05 [room\0][sender\0][payload]          — room broadcast (live)
                //   0x08 [room\0][topic\0][sender\0][payload] — topic broadcast (live)
                // A DM wake only cares about 0x06 (Olm ciphertext, mirrors
                // ws_client.rs parse_binary_relay_frame). A channel wake reads
                // channel payloads from any of the three — the buffered 0x09
                // fan-out replays as 0x06, while messages sent live during the
                // fetch window arrive as 0x05/0x08.
                let parsed: Option<(String, String)> = if data.len() > 3 {
                    match data[0] {
                        0x06 | 0x05 => parse_direct_frame(&data[1..]),
                        0x08 => parse_topic_frame(&data[1..]),
                        _ => None,
                    }
                } else {
                    None
                };
                if let Some((from, payload)) = parsed {
                    if server_room.is_some() {
                        if let Some(entry) = try_process_channel_msg(
                            &from, &payload, mls, &mut mls_dirty, db_path, db_passphrase,
                        ) {
                            messages.push(entry);
                        }
                    } else if data[0] == 0x06 {
                        if let Some(dm) = try_decrypt_dm(
                            &from, &payload, olm, crypto_store, db_path, db_passphrase, peer_id,
                        ) {
                            persist_olm_session(olm, crypto_store, &from);
                            messages.push(dm);
                        }
                    }
                }
                // Other binary frames (file transfers) — ignore.
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

    // Persist advanced MLS ratchet state (channel wake). Single-writer-safe:
    // the fetch only runs when the full node is NOT running (Android guard /
    // iOS app-active heartbeat), mirroring the Olm session persistence above.
    if mls_dirty {
        if let Some(mls_mgr) = mls.as_ref() {
            persist_mls_state(mls_mgr, crypto_store);
        }
    }

    // A FileHeader and its companion text DM can arrive as TWO entries sharing
    // one message_id: the FileHeader entry has text "[file:<id>]" + image_path,
    // and (for a CAPTIONED image) the text DM has the real caption. Dedup by mid:
    // keep ONE entry per mid, preferring the real caption text but always carrying
    // the image_path. The FileHeader entry alone (captionless image) is kept as-is.
    let mut image_paths: std::collections::HashMap<String, String> =
        std::collections::HashMap::new();
    for m in &messages {
        if let Some(p) = &m.image_path {
            if !m.message_id.is_empty() {
                image_paths.insert(m.message_id.clone(), p.clone());
            }
        }
    }
    let mut order: Vec<String> = Vec::new();
    let mut by_mid: std::collections::HashMap<String, FetchedDm> =
        std::collections::HashMap::new();
    let mut no_mid: Vec<FetchedDm> = Vec::new();
    for mut m in messages.into_iter() {
        // Attach the image path to whatever entry references this mid.
        if m.image_path.is_none() && !m.message_id.is_empty() {
            if let Some(path) = image_paths.get(&m.message_id) {
                m.image_path = Some(path.clone());
            }
        }
        if m.message_id.is_empty() {
            no_mid.push(m);
            continue;
        }
        match by_mid.get_mut(&m.message_id) {
            None => {
                order.push(m.message_id.clone());
                by_mid.insert(m.message_id.clone(), m);
            }
            Some(existing) => {
                // Prefer the real caption over the "[file:...]" sentinel; keep
                // the image_path from whichever had it.
                let img = existing.image_path.clone().or_else(|| m.image_path.clone());
                if existing.text.starts_with("[file:") && !m.text.starts_with("[file:") {
                    *existing = m;
                }
                existing.image_path = img;
            }
        }
    }
    let mut merged: Vec<FetchedDm> = Vec::with_capacity(order.len() + no_mid.len());
    for mid in order {
        if let Some(m) = by_mid.remove(&mid) {
            merged.push(m);
        }
    }
    merged.extend(no_mid);

    hollow_log!("[HOLLOW-FETCH] Fetch complete, returning {} messages", merged.len());
    Ok(merged)
}

/// Parse the body of a relay direct/broadcast frame (after the type byte):
///   [room\0][sender\0][payload]
/// Returns (sender_peer_id, payload_as_utf8_string). The room code is not
/// needed here — the fetch node only joined one room.
fn parse_direct_frame(body: &[u8]) -> Option<(String, String)> {
    let room_end = body.iter().position(|&b| b == 0)?;
    let after_room = &body[room_end + 1..];
    let sender_end = after_room.iter().position(|&b| b == 0)?;
    let sender = String::from_utf8_lossy(&after_room[..sender_end]).to_string();
    let payload = &after_room[sender_end + 1..];
    let payload_str = String::from_utf8_lossy(payload).to_string();
    Some((sender, payload_str))
}

/// Parse the body of a relay topic-broadcast frame (after the 0x08 type byte):
///   [room\0][topic\0][sender\0][payload]
/// Returns (sender_peer_id, payload_as_utf8_string).
fn parse_topic_frame(body: &[u8]) -> Option<(String, String)> {
    let room_end = body.iter().position(|&b| b == 0)?;
    let after_room = &body[room_end + 1..];
    let topic_end = after_room.iter().position(|&b| b == 0)?;
    parse_direct_frame_tail(&after_room[topic_end + 1..])
}

/// [sender\0][payload] tail shared by topic frames.
fn parse_direct_frame_tail(body: &[u8]) -> Option<(String, String)> {
    let sender_end = body.iter().position(|&b| b == 0)?;
    let sender = String::from_utf8_lossy(&body[..sender_end]).to_string();
    let payload = String::from_utf8_lossy(&body[sender_end + 1..]).to_string();
    Some((sender, payload))
}

/// Process a channel-wake payload: an MLS-encrypted or public channel message.
///
/// MLS: decrypts on the loaded group state and persists the row — exactly what
/// the live node would do. A stale-epoch decrypt failure (member missed a
/// commit while offline) is logged and skipped: the banner falls back to a
/// content-free line and the app self-heals via channel sync + MLS recovery on
/// next open. Public channels: signed plaintext, inserted directly.
fn try_process_channel_msg(
    from: &str,
    data: &str,
    mls: &mut Option<MlsManager>,
    mls_dirty: &mut bool,
    db_path: &str,
    db_passphrase: &str,
) -> Option<FetchedDm> {
    let haven: HavenMessage = serde_json::from_str(data).ok()?;

    match haven {
        HavenMessage::MlsChannelMessage { server_id, body } => {
            let mls_mgr = mls.as_mut()?;
            if !mls_mgr.has_group(&server_id) {
                hollow_log!("[HOLLOW-FETCH] No MLS group for {server_id} — skip (app syncs later)");
                return None;
            }
            let ciphertext = OlmManager::decode_base64(&body).ok()?;
            let (plaintext, sender) = match mls_mgr.decrypt(&server_id, &ciphertext) {
                Ok(r) => r,
                Err(e) => {
                    hollow_log!("[HOLLOW-FETCH] MLS decrypt failed (stale epoch?): {e} — app self-heals via sync");
                    return None;
                }
            };
            *mls_dirty = true;
            let envelope_str = String::from_utf8_lossy(&plaintext);
            match serde_json::from_str::<MessageEnvelope>(&envelope_str).ok()? {
                MessageEnvelope::ChannelMessage { inner } => {
                    let ChannelMessagePayload {
                        sid, cid, text, ts, sig, pk, mid, reply_to, file_id, ..
                    } = *inner;
                    let text = clip_text(text);
                    insert_channel_row(
                        db_path, db_passphrase, &sid, &cid, &sender, &text, ts,
                        sig.as_deref(), pk.as_deref(), mid.as_deref(), reply_to.as_deref(),
                        file_id.as_deref(),
                    );
                    Some(FetchedDm {
                        from_peer: sender,
                        text,
                        timestamp: ts,
                        message_id: mid.unwrap_or_default(),
                        image_path: None,
                        server_id: Some(sid),
                        channel_id: Some(cid),
                    })
                }
                // Edits/deletes/reactions while offline are reconciled by the
                // full app's channel sync — not notification-worthy here.
                _ => None,
            }
        }
        HavenMessage::PublicChannelMessage {
            server_id, channel_id, text, ts, sig, pk, mid, reply_to, file_id, ..
        } => {
            // Public channels: signed plaintext. The sender is the relay-attested
            // frame author (`from`) — same source the live handler uses.
            let text = clip_text(text);
            insert_channel_row(
                db_path, db_passphrase, &server_id, &channel_id, from, &text, ts,
                sig.as_deref(), pk.as_deref(), Some(&mid), reply_to.as_deref(),
                file_id.as_deref(),
            );
            Some(FetchedDm {
                from_peer: from.to_string(),
                text,
                timestamp: ts,
                message_id: mid,
                image_path: None,
                server_id: Some(server_id),
                channel_id: Some(channel_id),
            })
        }
        _ => None,
    }
}

fn clip_text(text: String) -> String {
    if text.len() > 4000 {
        let mut end = 4000;
        while end > 0 && !text.is_char_boundary(end) {
            end -= 1;
        }
        text[..end].to_string()
    } else {
        text
    }
}

/// Insert a fetched channel message row, deduplicated by message_id — the same
/// message may arrive again via channel sync when the full app opens.
#[allow(clippy::too_many_arguments)]
fn insert_channel_row(
    db_path: &str,
    db_passphrase: &str,
    server_id: &str,
    channel_id: &str,
    sender: &str,
    text: &str,
    ts: i64,
    sig: Option<&str>,
    pk: Option<&str>,
    mid: Option<&str>,
    reply_to: Option<&str>,
    file_id: Option<&str>,
) {
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let exists = mid.map(|m| store.channel_message_exists(m)).unwrap_or(false);
        hollow_log!(
            "[HOLLOW-FETCH] insert channel msg {}/{} from={} mid={:?} exists={}",
            server_id, channel_id, sender, mid, exists
        );
        if !exists {
            let _ = store.insert_channel_message(
                server_id, channel_id, sender, text, false, ts, sig, pk, mid,
                reply_to, file_id,
            );
        }
    }
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
                        } else if !msg_text.starts_with("[file:") {
                            // Row already exists — likely the inlined-image
                            // FileHeader for this same mid won the INSERT OR
                            // IGNORE and stored a "[file:<id>]" sentinel (with no
                            // signature). This is the real CAPTION (shares the
                            // mid): promote the sentinel to the caption text AND
                            // its sig/pk so the captioned image renders correctly
                            // and verifies (otherwise it shows "Unsigned"). No-op
                            // if the row already has real text.
                            if let Some(message_id) = mid.as_deref() {
                                let _ = store.promote_file_sentinel_to_caption(
                                    message_id,
                                    &msg_text,
                                    sig.as_deref(),
                                    pk.as_deref(),
                                );
                            }
                        }
                    }

                    Some(FetchedDm {
                        from_peer: from.to_string(),
                        text: msg_text,
                        timestamp: ts,
                        message_id: mid.unwrap_or_default(),
                        image_path: None,
                        server_id: None,
                        channel_id: None,
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
                        image_path: None,
                        server_id: None,
                        channel_id: None,
                    })
                }
                Ok(MessageEnvelope::FileHeader { inner }) => {
                    // An offline image DM inlines its AES-encrypted bytes in the
                    // FileHeader (file_handler.rs send_encrypted_image_to_peer).
                    // Decrypt + write the file to disk and record COMPLETE metadata
                    // so the message renders as a real image (and the notification
                    // can show a preview) — no live stream needed. Returns None: the
                    // FileHeader is not itself a notifiable message; its companion
                    // text DM (same mid) is what gets surfaced.
                    let p = *inner;
                    if let (Some(b64), Some(key_hex), Some(nonce_hex)) =
                        (p.inline_bytes.as_ref(), p.aes_key.as_ref(), p.aes_nonce.as_ref())
                    {
                        let decoded = base64::engine::general_purpose::STANDARD
                            .decode(b64)
                            .ok()
                            .and_then(|ct| {
                                let key = hex::decode(key_hex).ok()?;
                                let nonce = hex::decode(nonce_hex).ok()?;
                                if key.len() != 32 || nonce.len() != 12 {
                                    return None;
                                }
                                let mut k = [0u8; 32];
                                let mut n = [0u8; 12];
                                k.copy_from_slice(&key);
                                n.copy_from_slice(&nonce);
                                crate::vault::pipeline::aes_decrypt(&ct, &k, &n).ok()
                            });
                        if let Some(plaintext) = decoded {
                            let files_dir = crate::node::file_transfer::files_dir();
                            let _ = std::fs::create_dir_all(&files_dir);
                            let disk_path = files_dir.join(format!("{}.{}", p.fid, p.ext));
                            if std::fs::write(&disk_path, &plaintext).is_ok() {
                                let disk_str = disk_path.to_string_lossy().to_string();
                                // The companion text DM ("[file:...]") is sent via a
                                // path that drops to OFFLINE peers (file_handler uses
                                // a room lookup that fails when the peer isn't in a
                                // room), so the fetch often gets ONLY this FileHeader.
                                // Insert the MESSAGE row ourselves (INSERT OR IGNORE,
                                // so a later DM-sync / companion DM won't duplicate it)
                                // — otherwise the image file lands on disk with no
                                // message referencing it and renders as nothing.
                                let mid_str = p.mid.clone().unwrap_or_default();
                                let msg_text = format!("[file:{}]", p.fid);
                                if let Ok(store) =
                                    crate::storage::MessageStore::open(db_path, db_passphrase)
                                {
                                    if !p.mid.as_deref()
                                        .map(|m| store.dm_message_exists(m))
                                        .unwrap_or(false)
                                    {
                                        let _ = store.insert(
                                            from, &msg_text, false, p.ts,
                                            p.sig.as_deref(), p.pk.as_deref(),
                                            p.mid.as_deref(), None, Some(&p.fid),
                                        );
                                    }
                                    let _ = store.insert_file_metadata(
                                        &p.fid, &p.name, &p.ext, &p.mime,
                                        p.size, 0, p.img, p.w, p.h,
                                        p.mid.as_deref(), "dm", from,
                                        from, false, p.ts,
                                        p.vthumb.as_ref(),
                                    );
                                    let _ = store.mark_file_complete(&p.fid, &disk_str);
                                }
                                hollow_log!(
                                    "[HOLLOW-FETCH] wrote inline image {} ({} bytes) -> {}",
                                    p.fid, plaintext.len(), disk_str
                                );
                                // Return a REAL image message (text "[file:...]",
                                // image_path set). run_fetch keeps it (non-empty
                                // text) and, if the companion text DM also arrived,
                                // merges this image_path onto it by mid.
                                return Some(FetchedDm {
                                    from_peer: from.to_string(),
                                    text: msg_text,
                                    timestamp: p.ts,
                                    message_id: p.mid.clone().unwrap_or_default(),
                                    image_path: Some(disk_str),
                                    server_id: None,
                                    channel_id: None,
                                });
                            }
                        }
                    }
                    None
                }
                _ => None, // Other envelope types — ignore in fetch mode.
            }
        }
        _ => None,
    }
}
