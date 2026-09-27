//! Minimal background fetch node for FCM/APNs push notification Tier 2.
//!
//! Connects invisibly and joins ONE room: the DM room for the sender (Olm), or
//! the SERVER room for a channel wake (MLS group ciphertext fanned out per
//! offline member, or signed public-channel plaintext). No CRDT, no gossip.

use std::time::Duration;

use base64::Engine;
use futures_util::{SinkExt, StreamExt};
use tokio_tungstenite::tungstenite::Message;

use crate::crypto::{CryptoStore, MlsManager, OlmManager};
#[allow(unused_imports)]
use crate::hollow_log;
use crate::node::crypto_handler::{
    check_backfill_signature, persist_crypto_state, persist_mls_state,
    persist_olm_session, PkCache,
};
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
    /// Channel posts only: WE read a mention of us in the decrypted text. The
    /// sender's push flag is never trusted for this.
    pub mentions_me: bool,
}

/// Run a one-shot fetch: connect invisibly, join one room, collect messages.
///
/// `server_room` Some = a CHANNEL wake (MLS, or public plaintext), None = a DM
/// wake. `peer_id` is the DEVICE the socket AUTHENTICATES as: the relay keyed
/// this device's push token and offline buffer by it. `local_master` is this
/// identity's MASTER, and the DM room is derived from it plus the sender's
/// master, never the device id, or the fetch joins the wrong room.
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
    // The push payload names the server; one we are not a member of is never
    // joined, or the payload steers our socket into any room (J4).
    if let Some(sid) = server_room
        && stored_server_state(db_path, db_passphrase, sid).is_none_or(|s| !s.members.contains_key(local_master))
    {
        hollow_log!("[HOLLOW-FETCH] Channel wake for a server we are not a member of, nothing fetched");
        return Ok(Vec::new());
    }
    let room = fetch_room_code(server_room, local_master, sender_peer_id);

    // AUTO-DOWNLOAD GATE (#41): this headless process never receives Dart's
    // `set_auto_download_config` (the FCM isolate is a fresh process), so the
    // persisted settings are loaded directly; the process-global default is
    // permissive and would write inline images the live node would have gated.
    load_auto_download_conf_from_settings(db_path, db_passphrase);

    hollow_log!(
        "[HOLLOW-FETCH] Connecting to {relay_url} (fetch mode) for {} room {room}",
        if server_room.is_some() { "server" } else { "DM" }
    );

    let ws_stream = ws_client::connect_and_auth(
        &relay_url, peer_id, keypair_proto, pub_key_b64, license_key, true,
    )
    .await?;

    let (mut write, mut read) = ws_stream.split();

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
                if handle_kill_frame(
                    &text, &mut write, peer_id, local_master, db_path, db_passphrase,
                ).await {
                    // The identity is gone; there is nothing left to fetch into.
                    break;
                }
                handle_text_frame(
                    &text, olm, crypto_store, db_path, db_passphrase, peer_id, local_master,
                    &mut messages,
                );
            }
            Message::Binary(data) => {
                handle_binary_frame(
                    &data, server_room, olm, mls, &mut mls_dirty, crypto_store, db_path,
                    db_passphrase, peer_id, local_master, &mut messages,
                );
            }
            Message::Close(_) => {
                hollow_log!("[HOLLOW-FETCH] WS close frame received");
                break;
            }
            _ => {}
        }
    }

    let _ = write.close().await;

    // Persist advanced MLS ratchet state (channel wake). Single-writer-safe:
    // the fetch only runs when the full node is NOT running (Android guard /
    // iOS app-active heartbeat), mirroring the Olm session persistence above.
    if mls_dirty {
        if let Some(mls_mgr) = mls.as_ref() {
            persist_mls_state(mls_mgr, crypto_store);
        }
    }

    let mut merged = merge_fetched_messages(messages);
    if server_room.is_some() {
        merged = filter_by_notification_level(merged, db_path, db_passphrase);
    }

    hollow_log!("[HOLLOW-FETCH] Fetch complete, returning {} messages", merged.len());
    Ok(merged)
}

/// Compute the single room the fetch joins: the server room for a channel
/// wake, or the MASTER-paired DM room for a DM wake.
fn fetch_room_code(server_room: Option<&str>, local_master: &str, sender_peer_id: &str) -> String {
    match server_room {
        Some(s) => s.to_string(),
        None => {
            // MASTER-paired DM room: resolve both ends to their master (the
            // resolver is warmed from DB links before this call). The socket
            // still AUTHS as the device.
            let sender_master = crate::node::resolver::resolve(sender_peer_id);
            crate::node::types::dm_room_code(local_master, &sender_master)
        }
    }
}

// After the first message the relay replays its whole buffer back-to-back, so a
// short idle window drains the burst and returns PROMPTLY: the notification
// cannot render until run_fetch returns. An outstanding inlined image holds the
// connection to the full deadline instead, so images are never cut off.
const IDLE_AFTER_FIRST: Duration = Duration::from_millis(1200);

/// How long to wait for the next WS frame, or `None` once the overall deadline
/// has been reached.
///
/// The deadline caps the wait for the FIRST message; after that only
/// IDLE_AFTER_FIRST, unless a companion image is still outstanding.
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
            hollow_log!("[HOLLOW-FETCH] Wait elapsed, returning {} messages", collected);
            None
        }
    }
}

/// Handle a relay text frame: room control messages plus the legacy
/// text-direct DM path.
#[allow(clippy::too_many_arguments)]
/// The relay's parked destruction order, on the push isolate's socket.
///
/// Same rules as the full node minus the relaunch: this process has no window to
/// send back to Welcome, and the marker makes the next real launch finish the job.
/// Returns true when the wipe ran.
async fn handle_kill_frame(
    text: &str,
    write: &mut (impl futures_util::SinkExt<Message> + Unpin),
    device_peer_id: &str,
    local_master: &str,
    db_path: &str,
    db_passphrase: &str,
) -> bool {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(text) else { return false };
    if value.get("type").and_then(|v| v.as_str()) != Some("kill_signal") {
        return false;
    }
    let blob = value.get("blob").and_then(|v| v.as_str()).unwrap_or("");
    let ack = serde_json::json!({ "type": "kill_ack" }).to_string();

    let Some(order) = crate::node::destroy::decode_kill_blob(blob) else {
        let _ = write.send(Message::Text(ack.into())).await;
        return false;
    };
    match crate::node::destroy::judge_own_order(
        &order, local_master, device_peer_id, db_path, db_passphrase,
    ) {
        crate::node::destroy::Verdict::Apply => {
            hollow_log!("[HOLLOW-DESTROY] Kill signal accepted in the fetch node");
            if let Ok(root) = crate::identity::data_dir() {
                let _ = crate::api::wipe::destroy_data_root(&root);
            }
            let _ = write.send(Message::Text(ack.into())).await;
            true
        }
        crate::node::destroy::Verdict::RejectPermanent(reason) => {
            hollow_log!("[HOLLOW-DESTROY] Fetch node refused a destruction order: {reason}");
            let _ = write.send(Message::Text(ack.into())).await;
            false
        }
        crate::node::destroy::Verdict::RejectTransient(reason) => {
            hollow_log!("[HOLLOW-DESTROY] Fetch node could not judge a destruction order: {reason}");
            false
        }
    }
}

fn handle_text_frame(
    text: &str,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    db_path: &str,
    db_passphrase: &str,
    peer_id: &str,
    local_master: &str,
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
                // Legacy text-direct fallback; real DMs arrive as 0x06 below.
                let from = server_msg
                    .get("from")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                let data = server_msg
                    .get("data")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");

                if let Some(dm) = try_decrypt_dm(
                    from, data, olm, crypto_store, db_path, db_passphrase, peer_id, local_master,
                ) {
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
    local_master: &str,
    messages: &mut Vec<FetchedDm>,
) {
    // Relay frames (payload = HavenMessage JSON):
    //   0x06 [room\0][sender\0][payload]          — direct (live or offline-buffer replay)
    //   0x05 [room\0][sender\0][payload]          — room broadcast (live)
    //   0x08 [room\0][topic\0][sender\0][payload] — topic broadcast (live)
    // A DM wake only cares about 0x06 (Olm ciphertext). A channel wake reads
    // channel payloads from all three: the buffered 0x09 fan-out replays as
    // 0x06, while messages sent live during the window arrive as 0x05/0x08.
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
                &from, &payload, mls, mls_dirty, db_path, db_passphrase, local_master,
            ) {
                messages.push(entry);
            }
        } else if data[0] == 0x06 {
            if let Some(dm) = try_decrypt_dm(
                &from, &payload, olm, crypto_store, db_path, db_passphrase, peer_id, local_master,
            ) {
                persist_olm_session(olm, crypto_store, &from);
                messages.push(dm);
            }
        }
    }
    // Other binary frames (file transfers) — ignore.
}

/// A FileHeader and its companion text DM can arrive as TWO entries sharing one
/// message_id. Keep ONE entry per mid, preferring the real caption text but
/// always carrying the image_path; a captionless image keeps its own entry.
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

/// Merge a second entry sharing the same mid: prefer the real caption over the
/// "[file:...]" sentinel and keep the image_path from whichever had it.
fn merge_duplicate_entry(existing: &mut FetchedDm, m: FetchedDm) {
    let img = existing.image_path.clone().or_else(|| m.image_path.clone());
    if existing.text.starts_with("[file:") && !m.text.starts_with("[file:") {
        *existing = m;
    }
    existing.image_path = img;
}

/// Parse the body of a relay direct/broadcast frame (after the type byte):
///   [room\0][sender\0][payload]
/// Returns (sender_peer_id, payload). The room code is not needed: one room.
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
/// A stale-epoch decrypt failure (a member missed a commit while offline) is
/// logged and skipped: the banner falls back to a content-free line and the app
/// self-heals on next open. Public channels are signed plaintext.
fn try_process_channel_msg(
    from: &str,
    data: &str,
    mls: &mut Option<MlsManager>,
    mls_dirty: &mut bool,
    db_path: &str,
    db_passphrase: &str,
    local_master: &str,
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
            let envelope = serde_json::from_str::<MessageEnvelope>(&envelope_str).ok()?;
            let state = stored_server_state(db_path, db_passphrase, &server_id);
            let restricted = |cid: &str| state.as_ref().is_some_and(|s| s.channel_uses_subgroup(cid));
            if !crate::node::crypto_handler::mls_envelope_fits_group(
                &envelope, &server_id, channel_id.as_deref(), restricted,
            ) {
                hollow_log!("[HOLLOW-SECURITY] REJECTED push envelope in {group_key}: it names another server, channel or a DM");
                return None;
            }
            match envelope {
                MessageEnvelope::ChannelMessage { inner } => {
                    let ChannelMessagePayload {
                        sid, cid, text, ts, sig, pk, mid, reply_to, file_id,
                        link_preview, order_us, album,
                    } = *inner;
                    // Conference chat is live-only — it must never be persisted
                    // by a push-fetch either (mirrors the live-ingest guard).
                    if crate::node::conference::is_conference_sid(&sid) {
                        return None;
                    }
                    // The MLS leaf credential is the sender's DEVICE id, but the
                    // message is signed by and attributed to the MASTER, so the
                    // fetched row is master-keyed like the live handler's.
                    let sender_master = crate::node::resolver::resolve(&sender);
                    // Reject a present-but-invalid signature (defence in depth
                    // behind MLS group membership) — see fetch_channel_sig_rejected.
                    let lp_digest = link_preview.as_ref()
                        .map(crate::node::crypto_handler::link_preview_digest);
                    let extras = crate::node::crypto_handler::SignedExtras {
                        mid: mid.as_deref(),
                        reply_to: reply_to.as_deref(),
                        file_id: file_id.as_deref(),
                        order_us,
                        lp_digest: lp_digest.as_deref(),
                        album: album.as_deref(),
                    };
                    if fetch_channel_sig_rejected(
                        &sender_master, &sid, &cid, ts, &text, sig.as_deref(), pk.as_deref(),
                        &extras,
                    ) || fetch_post_refused(
                        state.as_ref()?, &sender_master, &sid, &cid, file_id.is_some(), ts,
                        db_path, db_passphrase,
                    ) {
                        return None;
                    }
                    insert_channel_row(
                        db_path, db_passphrase, &sid, &cid, &sender_master, &text, ts,
                        sig.as_deref(), pk.as_deref(), mid.as_deref(), reply_to.as_deref(),
                        file_id.as_deref(), order_us, album.as_deref(), link_preview.as_ref(),
                    );
                    let mentions_me = fetched_post_mentions(
                        state.as_ref()?, local_master, &text, reply_to.as_deref(), db_path, db_passphrase,
                    );
                    banner_worthy(&sender_master).then_some(FetchedDm {
                        from_peer: sender_master,
                        text,
                        timestamp: ts,
                        message_id: mid.unwrap_or_default(),
                        image_path: None,
                        server_id: Some(sid),
                        channel_id: Some(cid),
                        mentions_me,
                    })
                }
                // Edits/deletes/reactions while offline are reconciled by the
                // full app's channel sync — not notification-worthy here.
                _ => None,
            }
        }
        HavenMessage::PublicChannelMessage {
            server_id, channel_id, text, ts, sig, pk, mid, reply_to, file_id,
            link_preview, order_us, album,
            // Guest display metadata — irrelevant to the push-fetch path
            // (members store metadata from the MLS FileHeader instead).
            file_meta: _,
        } => {
            // Plaintext, so anyone in the room can send one: only a channel that is
            // public in our own state takes it (guests get no pushes). Meeting chat
            // is never stored.
            if crate::node::conference::is_conference_sid(&server_id) {
                return None;
            }
            let state = stored_server_state(db_path, db_passphrase, &server_id)?;
            if !crate::node::message_ops::public_frame_accepted(Some(&state), false, &server_id, &channel_id) {
                return None;
            }
            // Public channels: signed plaintext. The frame author is the sender's
            // DEVICE id but the message is attributed to their MASTER, so resolve
            // and the fetched row lands master-keyed like the live handler's.
            let sender_master = crate::node::resolver::resolve(from);
            // Public channels are PLAINTEXT, so a hostile relay can tamper in
            // flight. The push path must reject a present-but-invalid signature
            // too, or the tampered row is stored and never re-verified.
            let lp_digest = link_preview.as_ref()
                .map(crate::node::crypto_handler::link_preview_digest);
            let extras = crate::node::crypto_handler::SignedExtras {
                mid: Some(&mid),
                reply_to: reply_to.as_deref(),
                file_id: file_id.as_deref(),
                order_us,
                lp_digest: lp_digest.as_deref(),
                album: album.as_deref().map(String::as_str),
            };
            if fetch_channel_sig_rejected(
                &sender_master, &server_id, &channel_id, ts, &text,
                sig.as_deref(), pk.as_deref(), &extras,
            ) || fetch_post_refused(
                &state, &sender_master, &server_id, &channel_id, file_id.is_some(), ts,
                db_path, db_passphrase,
            ) {
                return None;
            }
            insert_channel_row(
                db_path, db_passphrase, &server_id, &channel_id, &sender_master, &text, ts,
                sig.as_deref(), pk.as_deref(), Some(&mid), reply_to.as_deref(),
                file_id.as_deref(), order_us, album.as_deref().map(String::as_str), link_preview.as_ref(),
            );
            let mentions_me = fetched_post_mentions(
                &state, local_master, &text, reply_to.as_deref(), db_path, db_passphrase,
            );
            banner_worthy(&sender_master).then_some(FetchedDm {
                from_peer: sender_master,
                text,
                timestamp: ts,
                message_id: mid,
                image_path: None,
                server_id: Some(server_id),
                channel_id: Some(channel_id),
                mentions_me,
            })
        }
        _ => None,
    }
}

/// Whether a push wake's sender may be named in a content-free fallback banner.
/// Anyone who knows our device id can make the relay wake us, so an empty wake
/// from a stranger, a blocked or a revoked device shows nothing (K3). A channel
/// wake needs a member of that server, a DM wake a friend, one of our own
/// devices, or someone we share a server with. The trust sets must be warm.
pub(crate) fn push_sender_known(
    store: &crate::storage::MessageStore,
    local_master: &str,
    sender: &str,
    server_id: Option<&str>,
) -> bool {
    if crate::node::blocklist::is_blocked(sender) || crate::node::resolver::is_revoked(sender) {
        return false;
    }
    let master = crate::node::resolver::resolve(sender);
    let both_members = |json: &str| {
        serde_json::from_str::<crate::crdt::server_state::ServerState>(json).is_ok_and(|s| {
            !s.is_deleted() && s.members.contains_key(&master) && s.members.contains_key(local_master)
        })
    };
    if let Some(sid) = server_id {
        return store.load_server_state(sid).ok().flatten().is_some_and(|j| both_members(&j));
    }
    master == local_master
        || store.get_friend_status(&master).ok().flatten().as_deref() == Some("accepted")
        || store.load_all_servers().is_ok_and(|all| all.iter().any(|(_, j)| both_members(j)))
}

/// A blocked member's post is stored like the live node stores it, where the UI
/// hides it, but it never becomes a banner.
fn banner_worthy(sender_master: &str) -> bool {
    !crate::node::blocklist::is_blocked(sender_master)
}

/// Our own reading of a fetched post: does it mention us.
fn fetched_post_mentions(
    state: &crate::crdt::server_state::ServerState,
    local_master: &str,
    text: &str,
    reply_to: Option<&str>,
    db_path: &str,
    db_passphrase: &str,
) -> bool {
    let reply_author = reply_to.and_then(|m| {
        crate::storage::MessageStore::open(db_path, db_passphrase)
            .ok()?
            .get_channel_message_sender(m)
    });
    crate::node::message_ops::post_mentions_member(state, local_master, text, reply_author.as_deref())
}

/// The channel wake's banners follow OUR per-channel level, judged on the
/// decrypted posts: "nothing" drops a channel, "mentions" keeps only posts that
/// mention us. The relay's mention flag decided only whether to wake us.
fn filter_by_notification_level(
    messages: Vec<FetchedDm>,
    db_path: &str,
    db_passphrase: &str,
) -> Vec<FetchedDm> {
    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else {
        return Vec::new();
    };
    let mut levels: std::collections::HashMap<(String, String), String> = std::collections::HashMap::new();
    messages
        .into_iter()
        .filter(|m| {
            let (Some(sid), Some(cid)) = (&m.server_id, &m.channel_id) else { return true };
            let level = levels
                .entry((sid.clone(), cid.clone()))
                .or_insert_with(|| channel_notification_level(&store, sid, cid));
            match level.as_str() {
                "nothing" => false,
                "mentions" => m.mentions_me,
                _ => true,
            }
        })
        .collect()
}

/// Effective local level: the channel's own setting, else the server default,
/// else "all".
pub(crate) fn channel_notification_level(
    store: &crate::storage::MessageStore,
    server_id: &str,
    channel_id: &str,
) -> String {
    let own = store.load_setting(&format!("notif:{server_id}:{channel_id}")).unwrap_or(None);
    match own.as_deref() {
        Some("all") | Some("mentions") | Some("nothing") => own.unwrap_or_default(),
        _ => store
            .load_setting(&format!("notif:{server_id}"))
            .unwrap_or(None)
            .filter(|v| v == "mentions" || v == "nothing")
            .unwrap_or_else(|| "all".to_string()),
    }
}

/// Our stored view of a server: the fetch node runs no CRDT of its own.
fn stored_server_state(
    db_path: &str,
    db_passphrase: &str,
    server_id: &str,
) -> Option<crate::crdt::server_state::ServerState> {
    let store = crate::storage::MessageStore::open(db_path, db_passphrase).ok()?;
    let json = store.load_server_state(server_id).ok()??;
    serde_json::from_str(&json).ok()
}

/// The live node's post gate (member, visibility, posting, mute, media-only, slow
/// mode) for a push-fetched channel post: true = drop.
#[allow(clippy::too_many_arguments)]
fn fetch_post_refused(
    state: &crate::crdt::server_state::ServerState,
    sender_master: &str,
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
    if let Some(reason) = crate::node::message_ops::live_channel_post_refusal(
        state, sender_master, cid, has_file, now_ms,
    ) {
        hollow_log!("[HOLLOW-FETCH] DROPPED push channel post from {sender_master} in {sid}/{cid}: {reason}");
        return true;
    }
    let slow = crate::node::message_ops::slow_mode_window_ms(state, sender_master, cid)
        .is_some_and(|window| {
            crate::storage::MessageStore::open(db_path, db_passphrase)
                .is_ok_and(|store| store.channel_sender_has_msg_in_range(sid, cid, sender_master, ts - window, ts))
        });
    if slow {
        hollow_log!("[HOLLOW-FETCH] DROPPED push slow-mode violation from {sender_master} in {cid}");
    }
    slow
}

/// True when a push-fetched channel message must NOT be stored: only a VERIFYING
/// signature is accepted, absent included (the 0.8.5 backfill rule).
///
/// Both sync and the app dedup by `message_id`, so an unchecked row would never
/// be re-verified. A hostile relay can tamper with a plaintext public-channel
/// frame; for MLS this is defence in depth behind group membership.
#[allow(clippy::too_many_arguments)]
fn fetch_channel_sig_rejected(
    sender_master: &str,
    sid: &str,
    cid: &str,
    ts: i64,
    text: &str,
    sig: Option<&str>,
    pk: Option<&str>,
    extras: &crate::node::crypto_handler::SignedExtras,
) -> bool {
    let mut pk_cache = PkCache::new();
    let verdict = check_backfill_signature(
        sender_master, "ch", &format!("{sid}:{cid}"),
        ts, None, extras, text, sig, pk, &mut pk_cache,
    );
    if !verdict.is_acceptable() {
        hollow_log!(
            "[HOLLOW-FETCH] REJECTED push channel message in {sid}/{cid} claiming sender {sender_master} — {}",
            verdict.reject_reason()
        );
        return true;
    }
    false
}

/// Insert a fetched channel message row, deduplicated by message_id: the same
/// message may arrive again via channel sync when the full app opens.
/// `order_us` is the SENDER's Lamport stamp, persisted faithfully because the v2
/// signature binds it; a local default would store a row that fails re-serving.
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
    order_us: Option<i64>,
    album: Option<&str>,
    link_preview: Option<&LinkPreviewRef>,
) {
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let exists = mid.map(|m| store.channel_message_exists(m)).unwrap_or(false);
        hollow_log!(
            "[HOLLOW-FETCH] insert channel msg {}/{} from={} mid={:?} exists={}",
            server_id, channel_id, sender, mid, exists
        );
        if !exists {
            let inserted = store.insert_channel_message(
                server_id, channel_id, sender, text, false, ts, sig, pk, mid,
                reply_to, file_id, order_us, album,
            );
            // Persist the preview too: dedup by mid means the full app never
            // re-ingests this row, so a dropped card is lost forever.
            if let (Ok(n), Some(lp), Some(message_id)) = (inserted, link_preview, mid) {
                if n > 0 {
                    if let Ok(lp_json) = serde_json::to_string(lp) {
                        let _ = store.update_channel_link_preview(message_id, &lp_json);
                    }
                }
            }
        }
    }
}

/// Attempt to decrypt a single incoming WS message as a DM.
#[allow(clippy::too_many_arguments)]
fn try_decrypt_dm(
    from: &str,
    data: &str,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    db_path: &str,
    db_passphrase: &str,
    local_peer_id: &str,
    // OUR master id — the recipient half of the DM signing context. `local_peer_id`
    // is THIS device (used only for the own-sibling self-check); the signature is
    // over the master, so the two are distinct on a linked device.
    local_master: &str,
) -> Option<FetchedDm> {
    let haven: HavenMessage = match serde_json::from_str(data) {
        Ok(h) => h,
        Err(e) => {
            hollow_log!("[HOLLOW-FETCH] Buffered DM frame from {from} ({} B) failed HavenMessage parse — dropped: {e}", data.len());
            return None;
        }
    };

    // DEFENSE: never process an envelope from OUR OWN identity (a sibling
    // self-echo). This inserter hardcodes `is_mine=false` and files under
    // `resolve(from)`, so the row would land in the wrong thread and the
    // mid-keyed dedup would then block the correct copy from ever landing.
    if crate::node::resolver::same_identity(from, local_peer_id) {
        hollow_log!("[HOLLOW-FETCH] Skipping own-sibling envelope from {from}");
        return None;
    }

    // Olm decrypt is keyed by the SENDER DEVICE id, since sessions are
    // per-device, but rows and the surfaced conversation key on the MASTER, so a
    // multi-device sender's messages land in the one thread.
    let convo = crate::node::resolver::resolve(from);

    // BLOCK GUARD: relay-buffered replays from a blocked identity are dropped
    // exactly like live traffic.
    if crate::node::blocklist::is_blocked(from) {
        return None;
    }

    match haven {
        HavenMessage::Encrypted {
            message_type,
            body,
            identity_key,
            identity_sig,
            identity_pk,
        } => {
            let ciphertext = match OlmManager::decode_base64(&body) {
                Ok(b) => b,
                Err(e) => {
                    hollow_log!("[HOLLOW-FETCH] Encrypted body from {from}: base64 decode failed — dropped: {e}");
                    return None;
                }
            };

            let plaintext = olm_decrypt_payload(
                from, message_type, identity_key.as_deref(),
                identity_sig.as_deref(), identity_pk.as_deref(),
                &ciphertext, olm, crypto_store,
            )?;
            // The app loads this session later and never sees the PreKey, so the
            // key-change notice is recorded here or not at all.
            if let (0, Some(key), Ok(store)) = (
                message_type,
                identity_key.as_deref(),
                crate::storage::MessageStore::open(db_path, db_passphrase),
            ) {
                crate::node::security_alerts::pin_olm_identity_key(&store, local_master, &convo, from, key);
            }

            let text = String::from_utf8_lossy(&plaintext).to_string();
            match serde_json::from_str::<MessageEnvelope>(&text) {
                Ok(MessageEnvelope::DirectMessage { inner }) => {
                    handle_direct_message(from, &convo, local_master, *inner, db_path, db_passphrase)
                }
                Ok(MessageEnvelope::EditMessage { mid, text: new_text, ts, sig, pk, .. }) => {
                    handle_edit_message(&convo, local_master, mid, new_text, ts, sig, pk, db_path, db_passphrase)
                }
                Ok(MessageEnvelope::LinkPreviewSet { mid, lp, ts, sig, pk, sid, .. })
                    if sid.is_none() =>
                {
                    handle_link_preview_set(
                        &convo, local_master, mid, lp, ts, sig, pk, db_path, db_passphrase,
                    )
                }
                Ok(MessageEnvelope::FileHeader { inner }) => {
                    handle_file_header(&convo, local_master, *inner, db_path, db_passphrase)
                }
                Err(e) => {
                    hollow_log!("[HOLLOW-FETCH] Decrypted envelope from {from} failed MessageEnvelope parse ({} B) — dropped: {e}", text.len());
                    None
                }
                Ok(_) => None, // Other envelope types — ignore in fetch mode.
            }
        }
        _ => None,
    }
}

/// Decrypt an Olm-encrypted DM body. Sessions are keyed by the SENDER DEVICE
/// id (`from`). Returns `None` (logged) when decryption fails.
#[allow(clippy::too_many_arguments)]
fn olm_decrypt_payload(
    from: &str,
    message_type: usize,
    identity_key: Option<&str>,
    identity_sig: Option<&str>,
    identity_pk: Option<&str>,
    ciphertext: &[u8],
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
) -> Option<Vec<u8>> {
    if message_type == 0 {
        // PreKeyMessage
        let their_identity = match identity_key {
            Some(k) => k,
            None => {
                hollow_log!("[HOLLOW-FETCH] PreKey from {from} missing identity_key — dropped");
                return None;
            }
        };
        // Same gate as the live node, and here it matters twice: a session built
        // in this isolate is persisted and loaded by the app afterwards.
        if !crate::node::crypto_handler::verify_olm_identity(from, their_identity, identity_sig, identity_pk) {
            hollow_log!("[HOLLOW-SECURITY] REJECTED PreKey from {from} in fetch: identity key not signed by that device");
            return None;
        }
        if olm.has_session(from) {
            match olm.try_decrypt_prekey_with_existing(from, ciphertext) {
                Ok(pt) => Some(pt),
                Err(e) => {
                    hollow_log!("[HOLLOW-FETCH] PreKey from {from} undecryptable with existing session ({e}) — rebuilding inbound session");
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

/// True when an unverified signature on a push-fetched DM (or edit) must be
/// rejected: `Valid` or the row is not stored, absent included (0.8.5).
///
/// Inbound-only, since own-sibling echoes are dropped in `try_decrypt_dm`, so
/// the signer is always the friend's MASTER. The DM is Olm-authenticated
/// already; this is defence in depth and keeps push consistent with live.
#[allow(clippy::too_many_arguments)]
fn fetch_dm_sig_rejected(
    convo: &str,
    local_master: &str,
    ts: i64,
    text: &str,
    sig: Option<&str>,
    pk: Option<&str>,
    extras: &crate::node::crypto_handler::SignedExtras,
) -> bool {
    let mut pk_cache = PkCache::new();
    // ts already IS the edit timestamp for an edit envelope (the send side signs
    // over it), so edited_at stays None and the payload uses ts directly.
    let verdict = check_backfill_signature(
        convo, "dm", local_master, ts, None, extras, text, sig, pk, &mut pk_cache,
    );
    if !verdict.is_acceptable() {
        hollow_log!(
            "[HOLLOW-FETCH] REJECTED push DM from {convo} — {} (ts={ts})",
            verdict.reject_reason()
        );
        return true;
    }
    false
}

/// Handle a decrypted DirectMessage envelope: persist the row (dedup by
/// message_id) and surface it for the notification.
fn handle_direct_message(
    from: &str,
    convo: &str,
    local_master: &str,
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
        order_us,
        album,
        ..
    } = inner;

    // The v2 extras come from the wire fields persisted below.
    let lp_digest = link_preview.as_ref()
        .map(crate::node::crypto_handler::link_preview_digest);
    let extras = crate::node::crypto_handler::SignedExtras {
        mid: mid.as_deref(),
        reply_to: reply_to.as_deref(),
        file_id: file_id.as_deref(),
        order_us,
        lp_digest: lp_digest.as_deref(),
        album: album.as_deref(),
    };
    if fetch_dm_sig_rejected(convo, local_master, ts, &msg_text, sig.as_deref(), pk.as_deref(), &extras) {
        return None;
    }

    persist_direct_message(
        from, convo, &msg_text, ts, mid.as_deref(), reply_to.as_deref(), file_id.as_deref(),
        order_us, album.as_deref(), sig.as_deref(), pk.as_deref(), link_preview.as_ref(),
        db_path, db_passphrase,
    );

    Some(FetchedDm {
        from_peer: convo.to_string(),
        text: msg_text,
        timestamp: ts,
        message_id: mid.unwrap_or_default(),
        image_path: None,
        server_id: None,
        channel_id: None,
        mentions_me: false,
    })
}

/// Persist to DB so the full node does not re-fetch. Dedup by message_id (a
/// replayed buffered message may also be pulled later by DM-sync): skip the
/// INSERT if it already exists, but still surface it for the notification.
#[allow(clippy::too_many_arguments)]
fn persist_direct_message(
    from: &str,
    convo: &str,
    msg_text: &str,
    ts: i64,
    mid: Option<&str>,
    reply_to: Option<&str>,
    file_id: Option<&str>,
    // The SENDER's Lamport stamp from the wire — persisted faithfully because
    // the v2 signature binds it (a ts*1000 default would wedge later re-serves).
    order_us: Option<i64>,
    album: Option<&str>,
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
                order_us,
                album,
            );
            if let (Some(lp), Some(message_id)) = (link_preview, mid) {
                if let Ok(lp_json) = serde_json::to_string(lp) {
                    let _ = store.update_link_preview(message_id, &lp_json);
                }
            }
        } else if !msg_text.starts_with("[file:") {
            // Row already exists: the inlined-image FileHeader for this mid won
            // the INSERT OR IGNORE and stored an unsigned "[file:<id>]" sentinel.
            // This is the real CAPTION, so promote the sentinel text AND its
            // sig/pk, or the captioned image renders as "Unsigned". Only the
            // sender's own row: the signature says nothing about anyone else's.
            let scope = crate::node::message_ops::RowScope::Dm { convo, is_mine: false };
            if let Some(message_id) = mid.filter(|m| {
                crate::node::message_ops::change_may_touch_row(&store, &scope, Some(m))
            }) {
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

/// Apply a late link preview (#45) while the app is backgrounded.
///
/// The fetch node has to handle this or the card is lost for good: preview bytes
/// never ride sync backfill, only `lp_digest` does. Returns `None`, because a
/// card landing on a message the user already has is not a new notification.
#[allow(clippy::too_many_arguments)]
fn handle_link_preview_set(
    convo: &str,
    local_master: &str,
    mid: String,
    lp: Option<Box<crate::node::LinkPreviewRef>>,
    ts: i64,
    sig: Option<String>,
    pk: Option<String>,
    db_path: &str,
    db_passphrase: &str,
) -> Option<FetchedDm> {
    let store = crate::storage::MessageStore::open(db_path, db_passphrase).ok()?;
    // Only the sender's own message in its conversation with us can gain a card
    // here; own-sibling envelopes never reach this node.
    crate::node::message_ops::live_dm_change(&store, &mid, convo, local_master)?;
    let row = store.get_dm_message_sig_row(&mid)?;

    // Same gate as the live path: verify over OUR row's text and extras with
    // the NEW digest, and reject rather than log.
    let lp_digest = lp.as_deref().map(crate::node::crypto_handler::link_preview_digest);
    let extras = crate::node::crypto_handler::SignedExtras {
        mid: Some(&mid),
        reply_to: row.reply_to_mid.as_deref(),
        file_id: row.file_id.as_deref(),
        order_us: row.order_us,
        lp_digest: lp_digest.as_deref(),
        album: row.album_id.as_deref(),
    };
    if fetch_dm_sig_rejected(
        convo, local_master, ts, &row.text, sig.as_deref(), pk.as_deref(), &extras,
    ) {
        return None;
    }

    let lp_json = lp.as_deref().and_then(|c| serde_json::to_string(c).ok());
    let applied = store
        .update_link_preview_and_sig(&mid, lp_json.as_deref(), sig.as_deref(), pk.as_deref())
        .unwrap_or(false);
    hollow_log!("[HOLLOW-FETCH] link preview mid={mid} applied={applied}");
    None
}

/// Handle a decrypted EditMessage envelope. An edit to an offline peer is
/// buffered and pushed too; applying it by message_id keeps the DB consistent
/// with the sender and stops the edit appearing as a second message later.
#[allow(clippy::too_many_arguments)]
fn handle_edit_message(
    convo: &str,
    local_master: &str,
    mid: String,
    new_text: String,
    ts: i64,
    sig: Option<String>,
    pk: Option<String>,
    db_path: &str,
    db_passphrase: &str,
) -> Option<FetchedDm> {
    // Only the sender's own message in its conversation with us; an edit that
    // arrives before its original is left to DM-sync, matching the live handler.
    let store = crate::storage::MessageStore::open(db_path, db_passphrase).ok()?;
    crate::node::message_ops::live_dm_change(&store, &mid, convo, local_master)?;
    // Reject a tampered edit before it overwrites the stored row. The v2 edit
    // signature binds the ORIGINAL row's structural fields, so they are
    // reconstructed from our stored row.
    let row_extras = store.get_dm_message_sig_row(&mid);
    let lp_digest = row_extras.as_ref()
        .and_then(|r| r.link_preview.as_ref())
        .map(crate::node::crypto_handler::link_preview_digest);
    let extras = crate::node::crypto_handler::SignedExtras {
        mid: Some(&mid),
        reply_to: row_extras.as_ref().and_then(|r| r.reply_to_mid.as_deref()),
        file_id: row_extras.as_ref().and_then(|r| r.file_id.as_deref()),
        order_us: row_extras.as_ref().and_then(|r| r.order_us),
        lp_digest: lp_digest.as_deref(),
        album: row_extras.as_ref().and_then(|r| r.album_id.as_deref()),
    };
    if fetch_dm_sig_rejected(convo, local_master, ts, &new_text, sig.as_deref(), pk.as_deref(), &extras) {
        return None;
    }
    let applied = store
        .edit_dm_message(&mid, &new_text, ts, sig.as_deref(), pk.as_deref())
        .unwrap_or(false);
    hollow_log!(
        "[HOLLOW-FETCH] edit DM mid={mid} ts={ts} applied={applied} text_len={}",
        new_text.len()
    );
    if !applied {
        // Same text as the row: still stamp edited_at so the badge shows.
        let _ = store.set_dm_message_edited_at(&mid, ts);
    }
    Some(FetchedDm {
        from_peer: convo.to_string(),
        text: new_text,
        timestamp: ts,
        message_id: mid,
        image_path: None,
        server_id: None,
        channel_id: None,
        mentions_me: false,
    })
}

/// Handle a decrypted FileHeader envelope. An offline image DM inlines its
/// AES-encrypted bytes here, so decrypting and writing them with COMPLETE
/// metadata is what makes the message render as a real image with no live
/// stream. Returns None: the FileHeader is not itself notifiable, its companion
/// text DM under the same mid is.
fn handle_file_header(
    convo: &str,
    local_master: &str,
    p: FileHeaderPayload,
    db_path: &str,
    db_passphrase: &str,
) -> Option<FetchedDm> {
    // The live header gate: a DM header only, from the owner of any card we already
    // hold, and never for bytes already on disk.
    if p.sid.is_some() {
        return None;
    }
    {
        let store = crate::storage::MessageStore::open(db_path, db_passphrase).ok()?;
        if let Some(reason) = crate::node::file_handler::file_header_refused(
            &store, &std::collections::HashMap::new(), &p.fid, None, None, convo, false,
        ) {
            hollow_log!("[HOLLOW-SECURITY] REJECTED FileHeader for {} from {convo} in fetch: {reason}", p.fid);
            return None;
        }
        if crate::node::file_handler::file_bytes_on_disk(&store, &p.fid) {
            return None;
        }
    }
    if p.inline_bytes.is_some() && p.aes_key.is_some() && p.aes_nonce.is_some() {
        // AUTO-DOWNLOAD GATE (#41): honour the same config as the live node.
        // Gated keeps the sentinel row and metadata, so the card renders with a
        // manual Download button, but never writes the bytes.
        let auto_ok = crate::node::file_handler::auto_download_allows(
            p.size, &p.name, &p.ext, &format!("dm:{convo}"), p.voice,
        );
        if !auto_ok {
            let msg_text = format!("[file:{}]", p.fid);
            persist_inline_image(convo, local_master, &p, &msg_text, None, db_path, db_passphrase);
            hollow_log!(
                "[HOLLOW-FETCH] Auto-download gate dropped inline image bytes for {} (dm:{convo}) — message kept",
                p.fid
            );
            return Some(FetchedDm {
                from_peer: convo.to_string(),
                text: msg_text,
                timestamp: p.ts,
                message_id: p.mid.clone().unwrap_or_default(),
                image_path: None,
                server_id: None,
                channel_id: None,
                mentions_me: false,
            });
        }
    }
    if let (Some(b64), Some(key_hex), Some(nonce_hex)) =
        (p.inline_bytes.as_ref(), p.aes_key.as_ref(), p.aes_nonce.as_ref())
    {
        let decoded = decrypt_inline_image(b64, key_hex, nonce_hex);
        // SECURITY (FILE-1): the path below is built from two raw wire strings,
        // and an absolute `fid` makes `Path::join` discard the base directory. A
        // header whose id or extension is not the shape we mint writes nothing.
        if !crate::node::file_transfer::is_wire_file_id(&p.fid)
            || !crate::node::file_transfer::is_wire_ext(&p.ext)
        {
            hollow_log!(
                "[HOLLOW-SECURITY] REJECTED inline FileHeader from {convo}: bad file id or extension"
            );
            return None;
        }
        if let Some(plaintext) = decoded {
            let files_dir = crate::node::file_transfer::files_dir();
            let _ = std::fs::create_dir_all(&files_dir);
            let disk_path = crate::node::file_transfer::final_file_path(&p.fid, &p.ext);
            if crate::node::at_rest::write_all(&disk_path, &plaintext).is_ok() {
                let disk_str = disk_path.to_string_lossy().to_string();
                // The companion text DM is sent through a room lookup that fails
                // for an OFFLINE peer, so the fetch often gets ONLY this
                // FileHeader. Insert the MESSAGE row here (INSERT OR IGNORE) or
                // the image lands on disk with nothing referencing it.
                let msg_text = format!("[file:{}]", p.fid);
                persist_inline_image(convo, local_master, &p, &msg_text, Some(&disk_str), db_path, db_passphrase);
                hollow_log!(
                    "[HOLLOW-FETCH] wrote inline image {} ({} bytes) -> {}",
                    p.fid, plaintext.len(), disk_str
                );
                // A REAL image message: run_fetch keeps it and merges the
                // image_path onto the companion text DM by mid.
                return Some(FetchedDm {
                    from_peer: convo.to_string(),
                    text: msg_text,
                    timestamp: p.ts,
                    message_id: p.mid.clone().unwrap_or_default(),
                    image_path: Some(disk_str),
                    server_id: None,
                    channel_id: None,
                    mentions_me: false,
                });
            }
        }
    }
    None
}

/// Load the auto-download config from the persisted settings table so the fetch
/// node's gate matches the live node's (#41). Absent or malformed settings fall
/// back to the same defaults the Dart providers use.
fn load_auto_download_conf_from_settings(db_path: &str, db_passphrase: &str) {
    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else {
        return;
    };
    let threshold = store
        .load_setting("auto_download_threshold_mb")
        .ok()
        .flatten()
        .and_then(|s| s.trim().parse::<u32>().ok())
        .filter(|mb| *mb == 0 || *mb >= 34)
        .unwrap_or(169);
    let overrides = store
        .load_setting("auto_download_overrides")
        .ok()
        .flatten()
        .and_then(|s| serde_json::from_str::<std::collections::HashMap<String, bool>>(&s).ok())
        .unwrap_or_default();
    hollow_log!(
        "[HOLLOW-FETCH] Auto-download config loaded: {threshold} MB, {} override(s)",
        overrides.len()
    );
    crate::node::file_handler::set_auto_download_conf(threshold, overrides);
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
/// `disk_str` = Some(path) marks the file complete on disk; None = the bytes
/// were gated (auto-download off) — rows only, card renders a Download button.
fn persist_inline_image(
    convo: &str,
    local_master: &str,
    p: &FileHeaderPayload,
    msg_text: &str,
    disk_str: Option<&str>,
    db_path: &str,
    db_passphrase: &str,
) {
    if let Ok(store) =
        crate::storage::MessageStore::open(db_path, db_passphrase)
    {
        // SECURITY (backfill rule, 0.8.5): the header's sig is the MESSAGE
        // signature over the sentinel text, so the row is stored ONLY when it
        // VERIFIES. A CAPTIONED image's header legitimately fails here and its
        // companion caption DM creates the row. `order_us` from the header.
        let extras = crate::node::crypto_handler::SignedExtras {
            mid: p.mid.as_deref(),
            reply_to: None,
            file_id: Some(&p.fid),
            order_us: p.order_us,
            lp_digest: None,
            album: p.album.as_deref(),
        };
        let sentinel_sig_ok = check_backfill_signature(
            convo, "dm", local_master, p.ts, None, &extras, msg_text,
            p.sig.as_deref(), p.pk.as_deref(), &mut PkCache::new(),
        ).is_acceptable();
        if sentinel_sig_ok
            && !p.mid.as_deref()
                .map(|m| store.dm_message_exists(m))
                .unwrap_or(false)
        {
            let _ = store.insert(
                convo, msg_text, false, p.ts,
                p.sig.as_deref(), p.pk.as_deref(),
                p.mid.as_deref(), None, Some(&p.fid), p.order_us, p.album.as_deref(),
            );
        }
        // context_id + sender_id key on the MASTER so the file lands under the
        // same thread as its message row. Owner guard (0.8.5), see
        // `file_handler::file_meta_write_allowed`.
        if crate::node::file_handler::file_meta_write_allowed(&store, &p.fid, convo) {
            let thumb =
                crate::node::file_handler::accept_header_thumb(p.thumb.clone(), p.img, &p.mime);
            let _ = store.insert_file_metadata(
                &p.fid, &p.name, &p.ext, &p.mime,
                p.size, 0, p.img, p.w, p.h,
                p.mid.as_deref(), "dm", convo,
                convo, false, p.ts,
                p.vthumb.as_ref(), thumb.as_deref(),
            );
        }
        if let Some(disk_str) = disk_str {
            let _ = store.mark_file_complete(&p.fid, disk_str);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::native_identity::NativeKeypair;
    use crate::node::crypto_handler::{link_preview_digest, sign_message_versioned, SignedExtras};

    fn kp(seed: u8) -> NativeKeypair {
        NativeKeypair::from_secret_bytes(&[seed; 32])
    }

    fn pk_b64(k: &NativeKeypair) -> String {
        base64::engine::general_purpose::STANDARD.encode(k.public_key_protobuf())
    }

    fn card() -> LinkPreviewRef {
        LinkPreviewRef {
            url: "https://evil.example/".to_string(), title: "Login".to_string(),
            description: String::new(), domain: "evil.example".to_string(),
            site_name: String::new(), thumb_webp_b64: None, thumb_w: None, thumb_h: None, rich: None,
        }
    }

    /// B4, B7, B8 on the push path: a friend's validly signed edit, card or caption
    /// lands only on its own row in its conversation with us, never on another
    /// conversation's row or on one of ours.
    #[test]
    fn authz_push_dm_change_touches_only_the_senders_own_rows() {
        let _g = crate::node::resolver::test_lock();
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("push.db").to_string_lossy().into_owned();
        let pass = "ab".repeat(32);
        let open = || crate::storage::MessageStore::open(&path, &pass).unwrap();
        let (alice, bob, mallory) = (kp(161), kp(162), kp(163));
        let (a, b, m) = (alice.peer_id(), bob.peer_id(), mallory.peer_id());
        {
            let store = open();
            store.insert(&b, "from bob", false, 1_000, None, None, Some("b1"), None, None, Some(1_000_000), None).unwrap();
            store.insert(&b, "to bob", true, 1_100, None, None, Some("a1"), None, None, Some(1_100_000), None).unwrap();
            store.insert(&b, "[file:f1]", false, 1_200, None, None, Some("f1"), None, Some("f1"), Some(1_200_000), None).unwrap();
        }
        let text = |mid: &str| open().get_dm_message_sig_row(mid).unwrap().text;

        let edit = |k: &NativeKeypair, mid: &str, new: &str| {
            let row = crate::node::message_ops::RowExtras::load_dm(&open(), mid);
            let (sig, pk) = sign_message_versioned(
                k, &pk_b64(k), "dm", &a, &k.peer_id(), 5_000, &row.as_signed(mid), new,
            );
            handle_edit_message(&k.peer_id(), &a, mid.into(), new.into(), 5_000, sig, pk, &path, &pass)
        };
        assert!(edit(&mallory, "b1", "send money").is_none());
        assert!(edit(&bob, "a1", "words in our mouth").is_none());
        assert_eq!(text("b1"), "from bob");
        assert_eq!(text("a1"), "to bob");

        let attach = |k: &NativeKeypair, mid: &str| {
            let row = open().get_dm_message_sig_row(mid).unwrap();
            let digest = link_preview_digest(&card());
            let extras = SignedExtras {
                mid: Some(mid), reply_to: row.reply_to_mid.as_deref(), file_id: row.file_id.as_deref(),
                order_us: row.order_us, lp_digest: Some(&digest), album: row.album_id.as_deref(),
            };
            let ts = row.edited_at.unwrap_or(row.timestamp);
            let (sig, pk) = sign_message_versioned(k, &pk_b64(k), "dm", &a, &k.peer_id(), ts, &extras, &row.text);
            handle_link_preview_set(&k.peer_id(), &a, mid.into(), Some(Box::new(card())), ts, sig, pk, &path, &pass);
        };
        attach(&mallory, "b1");
        assert_eq!(open().get_dm_message_sig_row("b1").unwrap().link_preview, None);

        persist_direct_message(
            &m, &m, "invoice attached", 1_300, Some("f1"), None, Some("f1"), Some(1_300_000), None,
            None, None, None, &path, &pass,
        );
        assert_eq!(text("f1"), "[file:f1]");

        // The row's own author still goes through on every path.
        assert!(edit(&bob, "b1", "from bob, edited").is_some());
        assert_eq!(text("b1"), "from bob, edited");
        attach(&bob, "b1");
        assert_eq!(open().get_dm_message_sig_row("b1").unwrap().link_preview, Some(card()));
        persist_direct_message(
            &b, &b, "the photo", 1_200, Some("f1"), None, Some("f1"), Some(1_200_000), None,
            None, None, None, &path, &pass,
        );
        assert_eq!(text("f1"), "the photo");
    }

    fn temp_store() -> (tempfile::TempDir, String, String) {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("push.db").to_string_lossy().into_owned();
        let pass = "ab".repeat(32);
        crate::storage::MessageStore::open(&path, &pass).unwrap();
        (tmp, path, pass)
    }

    fn server_with(sid: &str, members: &[(&str, &str)]) -> crate::crdt::server_state::ServerState {
        let mut state = crate::crdt::server_state::ServerState::new(sid.into(), "s".into(), members[0].0.into());
        for (id, name) in members {
            state.members.insert((*id).into(), crate::crdt::server_state::MemberInfo {
                peer_id: (*id).into(),
                display_name: (*name).into(),
            });
        }
        state
    }

    /// HOL-SEC-035 (K1). The push fetch node and the iOS extension are fresh
    /// processes that never loaded the block list, so a blocked sender's DM was
    /// stored and shown by the push path while the app dropped it.
    #[test]
    fn authz_a_fresh_push_process_knows_our_blocks() {
        let _g = crate::node::resolver::test_lock();
        crate::node::resolver::clear_all();
        crate::node::blocklist::clear_for_test();
        let (_tmp, path, pass) = temp_store();
        let store = crate::storage::MessageStore::open(&path, &pass).unwrap();
        let bob = kp(171).peer_id();
        store.block_peer(&bob).unwrap();

        crate::node::resolver::warm_from_store(&store);
        assert!(
            crate::node::blocklist::is_blocked(&bob),
            "HOL-SEC-035: a fresh push process did not know the block list",
        );
        assert!(!banner_worthy(&bob), "a blocked member's post never becomes a banner");

        let src = |f: &str| {
            std::fs::read_to_string(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(f))
                .unwrap()
                .replace("\r\n", "\n")
        };
        let fetch_node = src("src/api/network.rs");
        let start = fetch_node.find("pub fn start_fetch_node(").unwrap();
        assert!(fetch_node[start..].split("\n}\n").next().unwrap().contains("warm_from_store("));
        let nse = src("src/push_enrich.rs");
        let start = nse.find("fn fetch_and_decrypt(").unwrap();
        assert!(nse[start..].split("\n}\n").next().unwrap().contains("warm_from_store("));
        crate::node::blocklist::clear_for_test();
        crate::node::resolver::clear_all();
    }

    /// HOL-SEC-035 (K2). A session first built by the push path was loaded by the
    /// app later, so the PreKey that carried a changed key was never seen by the
    /// live pin and the key change never raised its notice.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)] // the resolver guard is process-global
    async fn authz_a_key_change_first_seen_by_push_is_recorded() {
        let _g = crate::node::resolver::test_lock();
        crate::node::resolver::clear_all();
        crate::node::blocklist::clear_for_test();
        let (_tmp, path, pass) = temp_store();
        let (alice, bob) = (kp(172), kp(173));
        let (a, b) = (alice.peer_id(), bob.peer_id());
        crate::storage::MessageStore::open(&path, &pass).unwrap().set_olm_key_pin(&b, "an older key").unwrap();

        let mut alice_olm = OlmManager::new();
        let otk = alice_olm.generate_one_time_key();
        let mut bob_olm = OlmManager::new();
        crate::node::crypto_handler::bind_olm_identity(&mut bob_olm, &bob);
        bob_olm.create_outbound_session(&a, &alice_olm.identity_key_base64(), &otk).unwrap();
        let extras = SignedExtras { mid: Some("k2"), order_us: Some(1_000_000), ..SignedExtras::default() };
        let (sig, pk) = sign_message_versioned(&bob, &pk_b64(&bob), "dm", &a, &b, 1_000, &extras, "hi");
        let envelope = serde_json::to_string(&MessageEnvelope::DirectMessage {
            inner: Box::new(DirectMessagePayload {
                text: "hi".into(), ts: 1_000, sig, pk, mid: Some("k2".into()), reply_to: None,
                file_id: None, link_preview: None, convo: None, order_us: Some(1_000_000), album: None,
            }),
        })
        .unwrap();
        let (message_type, ciphertext) = bob_olm.encrypt(&a, envelope.as_bytes()).unwrap();
        assert_eq!(message_type, 0, "the first message is a PreKey");
        let frame = serde_json::to_string(
            &crate::node::crypto_handler::encrypted_frame(&bob_olm, message_type, &ciphertext),
        )
        .unwrap();

        let crypto_store = CryptoStore::open(path.clone(), pass.clone()).unwrap();
        assert!(try_decrypt_dm(&b, &frame, &mut alice_olm, &crypto_store, &path, &pass, &a, &a).is_some());
        let store = crate::storage::MessageStore::open(&path, &pass).unwrap();
        assert!(
            store.get_security_alerts().unwrap().iter().any(|al| {
                al.kind == crate::node::security_alerts::KIND_KEY_CHANGED && al.peer_id == b
            }),
            "HOL-SEC-035: a key change first seen by the push path raised no notice",
        );
        assert_eq!(store.get_olm_key_pin(&b).unwrap(), Some(bob_olm.identity_key_base64()));
        crate::node::resolver::clear_all();
    }

    /// HOL-SEC-035 (K3). Anyone who knows a device id can make the relay wake it,
    /// and an empty wake used to put up a banner naming the sender.
    #[test]
    fn authz_an_empty_wake_names_only_a_sender_we_know() {
        let _g = crate::node::resolver::test_lock();
        crate::node::resolver::clear_all();
        crate::node::blocklist::clear_for_test();
        let (_tmp, path, pass) = temp_store();
        let store = crate::storage::MessageStore::open(&path, &pass).unwrap();
        let me = kp(174).peer_id();
        let (friend, member, stranger, blocked) =
            (kp(175).peer_id(), kp(176).peer_id(), kp(177).peer_id(), kp(178).peer_id());
        store.save_friend(&friend, "accepted", "outgoing", 1).unwrap();
        store.save_friend(&blocked, "accepted", "outgoing", 1).unwrap();
        let state = server_with("srv-k3", &[(&me, "me"), (&member, "m")]);
        store.save_server_state("srv-k3", &serde_json::to_string(&state).unwrap()).unwrap();
        store.block_peer(&blocked).unwrap();
        crate::node::resolver::warm_from_store(&store);

        assert!(push_sender_known(&store, &me, &friend, None));
        assert!(push_sender_known(&store, &me, &member, None), "we share a server");
        assert!(push_sender_known(&store, &me, &member, Some("srv-k3")));
        assert!(!push_sender_known(&store, &me, &stranger, None), "HOL-SEC-035: a stranger's wake named them");
        assert!(!push_sender_known(&store, &me, &friend, Some("srv-k3")), "a channel wake needs a member");
        assert!(!push_sender_known(&store, &me, &blocked, None));

        let src = std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../lib/src/core/services/push_notification_service.dart"),
        )
        .unwrap()
        .replace("\r\n", "\n");
        for fallback in ["Future<void> _showDmFallbackIfNeeded(", "Future<void> _showChannelWakeFallback({"] {
            let start = src.find(fallback).unwrap();
            assert!(
                src[start..].split("\n}\n").next().unwrap().contains("_pushSenderKnown("),
                "{fallback} names a sender nobody vouched for",
            );
        }
        crate::node::blocklist::clear_for_test();
        crate::node::resolver::clear_all();
    }

    /// HOL-SEC-035 (C14). The relay flag "mentions you" is set by the sender, and a
    /// mentions-only channel showed every post of a wake whose flag was set. The
    /// woken device now judges each post's mention itself.
    #[test]
    fn authz_a_mentions_only_channel_shows_only_mentions_we_read() {
        let (_tmp, path, pass) = temp_store();
        let store = crate::storage::MessageStore::open(&path, &pass).unwrap();
        let me = kp(179).peer_id();
        let other = kp(180).peer_id();
        let state = server_with("srv-c14", &[(&me, "Alice"), (&other, "Bob")]);
        store.save_server_state("srv-c14", &serde_json::to_string(&state).unwrap()).unwrap();
        store.save_setting("notif:srv-c14:quiet", "mentions").unwrap();
        store.save_setting("notif:srv-c14:muted", "nothing").unwrap();
        let post = |cid: &str, mid: &str, text: &str| FetchedDm {
            from_peer: other.clone(),
            text: text.into(),
            timestamp: 1,
            message_id: mid.into(),
            image_path: None,
            server_id: Some("srv-c14".into()),
            channel_id: Some(cid.into()),
            mentions_me: fetched_post_mentions(&state, &me, text, None, &path, &pass),
        };
        let kept: Vec<String> = filter_by_notification_level(
            vec![
                post("quiet", "q1", "spam for everyone who reads the banner"),
                post("quiet", "q2", "@Alice look at this"),
                post("quiet", "q3", "@everyone meeting"),
                post("muted", "m1", "@Alice even here"),
                post("open", "o1", "plain chatter"),
            ],
            &path,
            &pass,
        )
        .into_iter()
        .map(|m| m.message_id)
        .collect();
        assert_eq!(
            kept,
            vec!["q2", "q3", "o1"],
            "HOL-SEC-035: a mentions-only channel showed a post that does not mention us",
        );
    }

    /// J4. The push payload names the server room, and a server we are not a
    /// member of must never be joined on its say-so.
    #[tokio::test]
    async fn a_channel_wake_for_a_server_we_do_not_hold_joins_nothing() {
        let (_tmp, path, pass) = temp_store();
        let me = kp(181);
        let mut olm = OlmManager::new();
        let mut mls = None;
        let crypto_store = CryptoStore::open(path.clone(), pass.clone()).unwrap();
        let proto = me.to_protobuf_encoding().unwrap();
        let fetched = run_fetch(
            "127.0.0.1:9", &me.peer_id(), &me.peer_id(), &proto, &pk_b64(&me), None,
            &kp(182).peer_id(), Some("a-server-we-never-joined"), Duration::from_secs(2),
            &mut olm, &mut mls, &crypto_store, &path, &pass,
        )
        .await;
        assert!(
            matches!(fetched.as_deref(), Ok([])),
            "a wake for a foreign server tried to connect: {:?}",
            fetched.err(),
        );
    }

    /// C11 on the push path: a DM is stored exactly as signed or not at all. The
    /// 4,000-byte clamp cut a full composer of Cyrillic in half, and the clipped
    /// row then failed its signature on every device it was served to.
    #[test]
    fn push_dm_is_stored_whole_or_dropped_never_clipped() {
        let _g = crate::node::resolver::test_lock();
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("push.db").to_string_lossy().into_owned();
        let pass = "ab".repeat(32);
        let (alice, bob) = (kp(164), kp(165));
        let (a, b) = (alice.peer_id(), bob.peer_id());
        let push = |mid: &str, text: &str| {
            let extras = SignedExtras { mid: Some(mid), order_us: Some(1_000_000), ..SignedExtras::default() };
            let (sig, pk) = sign_message_versioned(&bob, &pk_b64(&bob), "dm", &a, &b, 1_000, &extras, text);
            let inner = DirectMessagePayload {
                text: text.into(), ts: 1_000, sig, pk, mid: Some(mid.into()), reply_to: None,
                file_id: None, link_preview: None, convo: None, order_us: Some(1_000_000), album: None,
            };
            handle_direct_message(&b, &b, &a, inner, &path, &pass)
        };
        let stored = |mid: &str| {
            crate::storage::MessageStore::open(&path, &pass).unwrap().get_dm_message_sig_row(mid).map(|r| r.text)
        };

        let long = "я".repeat(4_000);
        assert_eq!(push("long", &long).map(|f| f.text).as_ref(), Some(&long));
        assert_eq!(stored("long").as_ref(), Some(&long));

        let over = "x".repeat(crate::node::crypto_handler::MAX_MESSAGE_BYTES + 1);
        assert!(push("over", &over).is_none());
        assert_eq!(stored("over"), None);
    }
}
