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
use crate::node::types::{
    ChannelMessagePayload, DirectMessagePayload, FileHeaderPayload, HavenMessage, LinkPreviewRef,
    MessageEnvelope,
};
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
/// `peer_id`: the DEVICE peer_id the socket AUTHENTICATES as (multi-device:
/// the relay keyed this device's push token + offline buffer by it, so the fetch
/// MUST auth as the device, not the master, to receive its buffered ciphertext).
/// `local_master`: this identity's MASTER peer_id — DM rooms are MASTER-paired
/// (`dm_room_code` is pure; the live node always computes it from masters), so
/// the room is derived from `local_master` + the sender's master, NOT the device
/// id, or the fetch joins the wrong room and finds nothing.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn run_fetch(
    relay_domain: &str,
    peer_id: &str,
    local_master: &str,
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
    let room = fetch_room_code(server_room, local_master, sender_peer_id);

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

    loop {
        let Some(wait) = next_wait(&messages, deadline) else {
            hollow_log!("[HOLLOW-FETCH] Timeout reached, returning {} messages", messages.len());
            break;
        };

        let Some(msg) = next_ws_frame(&mut read, wait, messages.len()).await else {
            break;
        };

        match msg {
            Message::Text(text) => {
                handle_text_frame(
                    &text, olm, crypto_store, db_path, db_passphrase, peer_id, &mut messages,
                );
            }
            Message::Binary(data) => {
                handle_binary_frame(
                    &data, server_room, olm, mls, &mut mls_dirty, crypto_store, db_path,
                    db_passphrase, peer_id, &mut messages,
                );
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

    let merged = merge_fetched_messages(messages);

    hollow_log!("[HOLLOW-FETCH] Fetch complete, returning {} messages", merged.len());
    Ok(merged)
}

/// Compute the single room the fetch joins: the server room for a channel
/// wake, or the MASTER-paired DM room for a DM wake.
fn fetch_room_code(server_room: Option<&str>, local_master: &str, sender_peer_id: &str) -> String {
    match server_room {
        Some(s) => s.to_string(),
        None => {
            // MASTER-paired DM room: resolve both ends to their master identity
            // (resolver warmed from DB links before this call). A single-device
            // install resolves each to itself → identical to the pre-multi-device
            // room. The socket still AUTHS as the device (`peer_id`) above.
            let sender_master = crate::node::resolver::resolve(sender_peer_id);
            crate::node::types::dm_room_code(local_master, &sender_master)
        }
    }
}

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

/// How long to wait for the next WS frame, or `None` once the overall
/// deadline has been reached (done collecting).
///
/// Overall deadline caps the wait for the FIRST message; once we have
/// messages we only wait IDLE_AFTER_FIRST between subsequent frames —
/// UNLESS we're still expecting a companion image (a text DM with a
/// file_id arrived but its image marker hasn't), in which case we hold
/// out to the full deadline so the image isn't cut off.
/// Outstanding image = a DM references a file (caption "[file:...]" or a
/// file_id) but no entry has delivered the image bytes (image_path) yet.
/// Hold the connection open to the full deadline so the larger FileHeader
/// frame isn't cut off by the short idle window.
fn next_wait(messages: &[FetchedDm], deadline: tokio::time::Instant) -> Option<Duration> {
    let outstanding_image = {
        let have_image = messages.iter().any(|m| m.image_path.is_some());
        let want_image = messages.iter().any(|m| m.text.starts_with("[file:"));
        want_image && !have_image
    };
    let until_deadline = deadline.saturating_duration_since(tokio::time::Instant::now());
    if until_deadline.is_zero() {
        return None;
    }
    Some(if messages.is_empty() || outstanding_image {
        until_deadline
    } else {
        IDLE_AFTER_FIRST.min(until_deadline)
    })
}

/// Wait up to `wait` for the next WS frame. Returns `None` when the read
/// errored, the connection closed, or the wait elapsed — all of which end
/// collection (`collected` is only used for the log line).
async fn next_ws_frame<S>(read: &mut S, wait: Duration, collected: usize) -> Option<Message>
where
    S: futures_util::Stream<Item = Result<Message, tokio_tungstenite::tungstenite::Error>> + Unpin,
{
    match tokio::time::timeout(wait, read.next()).await {
        Ok(Some(Ok(msg))) => Some(msg),
        Ok(Some(Err(e))) => {
            hollow_log!("[HOLLOW-FETCH] WS read error: {e}");
            None
        }
        Ok(None) => {
            hollow_log!("[HOLLOW-FETCH] WS connection closed");
            None
        }
        Err(_) => {
            // Idle/overall timeout — done collecting.
            hollow_log!("[HOLLOW-FETCH] Wait elapsed, returning {} messages", collected);
            None
        }
    }
}

/// Handle a relay text frame: room control messages plus the legacy
/// text-direct DM path.
fn handle_text_frame(
    text: &str,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    db_path: &str,
    db_passphrase: &str,
    peer_id: &str,
    messages: &mut Vec<FetchedDm>,
) {
    if let Ok(server_msg) = serde_json::from_str::<serde_json::Value>(text) {
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

/// Handle a relay binary frame.
#[allow(clippy::too_many_arguments)]
fn handle_binary_frame(
    data: &[u8],
    server_room: Option<&str>,
    olm: &mut OlmManager,
    mls: &mut Option<MlsManager>,
    mls_dirty: &mut bool,
    crypto_store: &CryptoStore,
    db_path: &str,
    db_passphrase: &str,
    peer_id: &str,
    messages: &mut Vec<FetchedDm>,
) {
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
                &from, &payload, mls, mls_dirty, db_path, db_passphrase,
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

/// A FileHeader and its companion text DM can arrive as TWO entries sharing
/// one message_id: the FileHeader entry has text "[file:<id>]" + image_path,
/// and (for a CAPTIONED image) the text DM has the real caption. Dedup by mid:
/// keep ONE entry per mid, preferring the real caption text but always carrying
/// the image_path. The FileHeader entry alone (captionless image) is kept as-is.
fn merge_fetched_messages(messages: Vec<FetchedDm>) -> Vec<FetchedDm> {
    let image_paths = collect_image_paths(&messages);
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
            Some(existing) => merge_duplicate_entry(existing, m),
        }
    }
    let mut merged: Vec<FetchedDm> = Vec::with_capacity(order.len() + no_mid.len());
    for mid in order {
        if let Some(m) = by_mid.remove(&mid) {
            merged.push(m);
        }
    }
    merged.extend(no_mid);
    merged
}

/// Map of message_id → image_path for every entry that delivered image bytes.
fn collect_image_paths(messages: &[FetchedDm]) -> std::collections::HashMap<String, String> {
    let mut image_paths: std::collections::HashMap<String, String> =
        std::collections::HashMap::new();
    for m in messages {
        if let Some(p) = &m.image_path {
            if !m.message_id.is_empty() {
                image_paths.insert(m.message_id.clone(), p.clone());
            }
        }
    }
    image_paths
}

/// Merge a second entry sharing the same mid into the existing one.
/// Prefer the real caption over the "[file:...]" sentinel; keep
/// the image_path from whichever had it.
fn merge_duplicate_entry(existing: &mut FetchedDm, m: FetchedDm) {
    let img = existing.image_path.clone().or_else(|| m.image_path.clone());
    if existing.text.starts_with("[file:") && !m.text.starts_with("[file:") {
        *existing = m;
    }
    existing.image_path = img;
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
        HavenMessage::MlsChannelMessage { server_id, body, channel_id } => {
            let mls_mgr = mls.as_mut()?;
            // Restricted channel (Option B): decrypt under the per-channel subgroup.
            let group_key = match &channel_id {
                Some(cid) => crate::crypto::subgroup_id(&server_id, cid),
                None => server_id.clone(),
            };
            if !mls_mgr.has_group(&group_key) {
                hollow_log!("[HOLLOW-FETCH] No MLS group for {group_key} — skip (app syncs later)");
                return None;
            }
            let ciphertext = OlmManager::decode_base64(&body).ok()?;
            let (plaintext, sender) = match mls_mgr.decrypt(&group_key, &ciphertext) {
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
                    // Conference chat is live-only — it must never be persisted
                    // by a push-fetch either (mirrors the live-ingest guard).
                    if crate::node::conference::is_conference_sid(&sid) {
                        return None;
                    }
                    // The MLS leaf credential is the sender's DEVICE id, but the
                    // message is signed by — and attributed to — the MASTER. Resolve
                    // so the fetched row is master-keyed, mirroring the live MLS
                    // handler (swarm.rs sender_master). Single-device → no-op.
                    let sender_master = crate::node::resolver::resolve(&sender);
                    let text = clip_text(text);
                    insert_channel_row(
                        db_path, db_passphrase, &sid, &cid, &sender_master, &text, ts,
                        sig.as_deref(), pk.as_deref(), mid.as_deref(), reply_to.as_deref(),
                        file_id.as_deref(),
                    );
                    Some(FetchedDm {
                        from_peer: sender_master,
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
            // Public channels: signed plaintext. The relay-attested frame author
            // (`from`) is the sender's DEVICE id, but the message is signed by — and
            // attributed to — the sender's MASTER. Resolve so the fetched row lands
            // master-keyed (matching the live handler) and renders the sender's name
            // instead of a raw device id. The resolver is warmed from DB links before
            // run_fetch; a single-device sender resolves to itself (no-op).
            let sender_master = crate::node::resolver::resolve(from);
            let text = clip_text(text);
            insert_channel_row(
                db_path, db_passphrase, &server_id, &channel_id, &sender_master, &text, ts,
                sig.as_deref(), pk.as_deref(), Some(&mid), reply_to.as_deref(),
                file_id.as_deref(),
            );
            Some(FetchedDm {
                from_peer: sender_master,
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
                reply_to, file_id, None, // push-fetch frame carries no order_us → ts*1000 default
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
    local_peer_id: &str,
) -> Option<FetchedDm> {
    let haven: HavenMessage = serde_json::from_str(data).ok()?;

    // DEFENSE: never process an envelope from OUR OWN identity (a sibling
    // self-echo). This inserter hardcodes `is_mine=false` and files under
    // `resolve(from)` — for a sibling sender that's OUR OWN master, so the row
    // would land in a wrong/own thread on the wrong side, and the mid-keyed
    // dedup would then block the correctly-oriented copy from ever landing.
    // Today sibling echoes are queue-only (never room-sent/buffered), so this
    // shouldn't fire — it's a guard against that upstream invariant changing.
    if crate::node::resolver::same_identity(from, local_peer_id) {
        hollow_log!("[HOLLOW-FETCH] Skipping own-sibling envelope from {from}");
        return None;
    }

    // Olm decrypt is keyed by the SENDER DEVICE id (`from`) — sessions are
    // per-device. But DB rows + the surfaced conversation key on the MASTER, so a
    // multi-device sender's messages land in the one thread (matching the live
    // node's `convo_peer = resolve(peer_id)`). The resolver is warmed from DB
    // links before run_fetch; a single-device sender resolves to itself.
    let convo = crate::node::resolver::resolve(from);

    // BLOCK GUARD: relay-buffered replays from a blocked identity are dropped
    // exactly like live traffic (covers both the DirectMessage and FileHeader
    // offline branches below).
    if crate::node::blocklist::is_blocked(from) {
        return None;
    }

    match haven {
        HavenMessage::Encrypted {
            message_type,
            body,
            identity_key,
        } => {
            let ciphertext = OlmManager::decode_base64(&body).ok()?;

            let plaintext = olm_decrypt_payload(
                from, message_type, identity_key.as_deref(), &ciphertext, olm, crypto_store,
            )?;

            let text = String::from_utf8_lossy(&plaintext).to_string();
            match serde_json::from_str::<MessageEnvelope>(&text) {
                Ok(MessageEnvelope::DirectMessage { inner }) => {
                    handle_direct_message(from, &convo, *inner, db_path, db_passphrase)
                }
                Ok(MessageEnvelope::EditMessage { mid, text: new_text, ts, sig, pk, .. }) => {
                    handle_edit_message(&convo, mid, new_text, ts, sig, pk, db_path, db_passphrase)
                }
                Ok(MessageEnvelope::FileHeader { inner }) => {
                    handle_file_header(&convo, *inner, db_path, db_passphrase)
                }
                _ => None, // Other envelope types — ignore in fetch mode.
            }
        }
        _ => None,
    }
}

/// Decrypt an Olm-encrypted DM body. Sessions are keyed by the SENDER DEVICE
/// id (`from`). Returns `None` (logged) when decryption fails.
fn olm_decrypt_payload(
    from: &str,
    message_type: usize,
    identity_key: Option<&str>,
    ciphertext: &[u8],
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
) -> Option<Vec<u8>> {
    if message_type == 0 {
        // PreKeyMessage
        let their_identity = identity_key?;
        if olm.has_session(from) {
            match olm.try_decrypt_prekey_with_existing(from, ciphertext) {
                Ok(pt) => Some(pt),
                Err(_) => {
                    olm.remove_session(from);
                    create_inbound_prekey_session(from, their_identity, ciphertext, olm, crypto_store)
                }
            }
        } else {
            create_inbound_prekey_session(from, their_identity, ciphertext, olm, crypto_store)
        }
    } else {
        match olm.decrypt(from, message_type, ciphertext) {
            Ok(pt) => Some(pt),
            Err(e) => {
                hollow_log!("[HOLLOW-FETCH] Decrypt failed for {from}: {e}");
                None
            }
        }
    }
}

/// Create a fresh inbound Olm session from a PreKeyMessage and persist it.
fn create_inbound_prekey_session(
    from: &str,
    their_identity: &str,
    ciphertext: &[u8],
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
) -> Option<Vec<u8>> {
    match olm.create_inbound_session(from, their_identity, ciphertext) {
        Ok(pt) => {
            persist_crypto_state(olm, crypto_store, from);
            Some(pt)
        }
        Err(e) => {
            hollow_log!("[HOLLOW-FETCH] PreKey session creation failed for {from}: {e}");
            None
        }
    }
}

/// Handle a decrypted DirectMessage envelope: persist the row (dedup by
/// message_id) and surface it for the notification.
fn handle_direct_message(
    from: &str,
    convo: &str,
    inner: DirectMessagePayload,
    db_path: &str,
    db_passphrase: &str,
) -> Option<FetchedDm> {
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
    } = inner;

    let msg_text = if msg_text.len() > 4000 {
        msg_text[..4000].to_string()
    } else {
        msg_text
    };

    persist_direct_message(
        from, convo, &msg_text, ts, mid.as_deref(), reply_to.as_deref(), file_id.as_deref(),
        sig.as_deref(), pk.as_deref(), link_preview.as_ref(), db_path, db_passphrase,
    );

    Some(FetchedDm {
        from_peer: convo.to_string(),
        text: msg_text,
        timestamp: ts,
        message_id: mid.unwrap_or_default(),
        image_path: None,
        server_id: None,
        channel_id: None,
    })
}

/// Persist to DB so the full node doesn't re-fetch.
/// Dedup by message_id: a replayed buffered message may also be
/// pulled later by full-node DM-sync. Skip the INSERT if it
/// already exists, but still surface it for the notification.
#[allow(clippy::too_many_arguments)]
fn persist_direct_message(
    from: &str,
    convo: &str,
    msg_text: &str,
    ts: i64,
    mid: Option<&str>,
    reply_to: Option<&str>,
    file_id: Option<&str>,
    sig: Option<&str>,
    pk: Option<&str>,
    link_preview: Option<&LinkPreviewRef>,
    db_path: &str,
    db_passphrase: &str,
) {
    if let Ok(store) =
        crate::storage::MessageStore::open(db_path, db_passphrase)
    {
        let already_exists = mid
            .map(|m| store.dm_message_exists(m))
            .unwrap_or(false);
        hollow_log!(
            "[HOLLOW-FETCH] insert DM from={} convo={} mid={:?} ts={} exists={} text_len={}",
            from, convo, mid, ts, already_exists, msg_text.len()
        );
        if !already_exists {
            let _ = store.insert(
                convo,
                msg_text,
                false,
                ts,
                sig,
                pk,
                mid,
                reply_to,
                file_id,
                None, // push-fetch frame carries no order_us → ts*1000 default
            );
            if let (Some(lp), Some(message_id)) = (link_preview, mid) {
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
            if let Some(message_id) = mid {
                let _ = store.promote_file_sentinel_to_caption(
                    message_id,
                    msg_text,
                    sig,
                    pk,
                );
            }
        }
    }
}

/// Handle a decrypted EditMessage envelope.
/// An edit to an offline peer is buffered + pushed too. Apply it
/// to the existing row (by message_id) so the DB stays consistent
/// with the sender — preventing the "edit appears as a second
/// message" duplication when the full node later DM-syncs.
#[allow(clippy::too_many_arguments)]
fn handle_edit_message(
    convo: &str,
    mid: String,
    new_text: String,
    ts: i64,
    sig: Option<String>,
    pk: Option<String>,
    db_path: &str,
    db_passphrase: &str,
) -> Option<FetchedDm> {
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
        from_peer: convo.to_string(),
        text: new_text,
        timestamp: ts,
        message_id: mid,
        image_path: None,
        server_id: None,
        channel_id: None,
    })
}

/// Handle a decrypted FileHeader envelope.
/// An offline image DM inlines its AES-encrypted bytes in the
/// FileHeader (file_handler.rs send_encrypted_image_to_peer).
/// Decrypt + write the file to disk and record COMPLETE metadata
/// so the message renders as a real image (and the notification
/// can show a preview) — no live stream needed. Returns None: the
/// FileHeader is not itself a notifiable message; its companion
/// text DM (same mid) is what gets surfaced.
fn handle_file_header(
    convo: &str,
    p: FileHeaderPayload,
    db_path: &str,
    db_passphrase: &str,
) -> Option<FetchedDm> {
    if let (Some(b64), Some(key_hex), Some(nonce_hex)) =
        (p.inline_bytes.as_ref(), p.aes_key.as_ref(), p.aes_nonce.as_ref())
    {
        let decoded = decrypt_inline_image(b64, key_hex, nonce_hex);
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
                let msg_text = format!("[file:{}]", p.fid);
                persist_inline_image(convo, &p, &msg_text, &disk_str, db_path, db_passphrase);
                hollow_log!(
                    "[HOLLOW-FETCH] wrote inline image {} ({} bytes) -> {}",
                    p.fid, plaintext.len(), disk_str
                );
                // Return a REAL image message (text "[file:...]",
                // image_path set). run_fetch keeps it (non-empty
                // text) and, if the companion text DM also arrived,
                // merges this image_path onto it by mid.
                return Some(FetchedDm {
                    from_peer: convo.to_string(),
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

/// Base64-decode + AES-decrypt the inlined image bytes from a FileHeader.
fn decrypt_inline_image(b64: &str, key_hex: &str, nonce_hex: &str) -> Option<Vec<u8>> {
    base64::engine::general_purpose::STANDARD
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
        })
}

/// Persist the message row + file metadata for an inlined image FileHeader.
fn persist_inline_image(
    convo: &str,
    p: &FileHeaderPayload,
    msg_text: &str,
    disk_str: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    if let Ok(store) =
        crate::storage::MessageStore::open(db_path, db_passphrase)
    {
        if !p.mid.as_deref()
            .map(|m| store.dm_message_exists(m))
            .unwrap_or(false)
        {
            let _ = store.insert(
                convo, msg_text, false, p.ts,
                p.sig.as_deref(), p.pk.as_deref(),
                p.mid.as_deref(), None, Some(&p.fid), None,
            );
        }
        // context_id + sender_id key on the MASTER so the
        // file lands under the same thread as its message
        // row (Step 5.1 DM-file context rule).
        let _ = store.insert_file_metadata(
            &p.fid, &p.name, &p.ext, &p.mime,
            p.size, 0, p.img, p.w, p.h,
            p.mid.as_deref(), "dm", convo,
            convo, false, p.ts,
            p.vthumb.as_ref(),
        );
        let _ = store.mark_file_complete(&p.fid, disk_str);
    }
}
