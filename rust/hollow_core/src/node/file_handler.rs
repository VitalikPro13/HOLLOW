use std::collections::HashMap;
use std::path::PathBuf;

use base64::Engine;
use tokio::sync::mpsc;

use crate::crdt::server_state::ServerState;
use crate::crypto::{MlsManager, OlmManager, CryptoStore};
use crate::node::file_transfer;
use crate::node::image_convert;
use super::crypto_handler::{
    message_signing_payload, sign_message,
    peer_is_reachable, ws_room_for_peer,
    send_mls_broadcast, send_encrypted_message,
    send_message_to_peer,
};
use super::gossip;
use super::types::*;
use super::ws_stream_transfer;

/// Max automatic re-requests after a failed file decrypt/assembly before giving
/// up and surfacing FileFailed to the UI. A transient truncation race (bytes not
/// fully flushed on the sender/receiver under concurrent transfers) clears on the
/// first or second retry; a genuinely corrupt source won't, so we cap it.
const FILE_DECRYPT_MAX_RETRIES: u32 = 3;

/// Handle NodeCommand::SendFile — the large file sending handler.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_send_file(
    peer_id: Option<String>,
    server_id: Option<String>,
    channel_id: Option<String>,
    file_path: String,
    message_id: String,
    message_text: String,
    vthumb: Option<VideoThumbRef>,
    override_width: Option<u32>,
    override_height: Option<u32>,
    share_ref: Option<super::types::ShareRef>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    server_states: &HashMap<String, ServerState>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
    device_peer_id: &str,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    mls: &mut Option<MlsManager>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    webrtc_peers: &std::collections::HashSet<String>,
    pending_webrtc_sends: &mut HashMap<String, (String, ws_stream_transfer::StreamKind, String, PathBuf, u64)>,
    gossip_overlays: &mut HashMap<String, gossip::GossipOverlay>,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-FILE] SendFile: {file_path} mid={message_id}");

    // 1. Read file from disk.
    let mut file_data = match tokio::fs::read(&file_path).await {
        Ok(d) => d,
        Err(e) => {
            hollow_log!("[HOLLOW-FILE] Failed to read file: {e}");
            let _ = event_tx.send(NetworkEvent::FileFailed {
                file_id: message_id.clone(),
                error: format!("Failed to read file: {e}"),
            }).await;
            return;
        }
    };

    // 2. Extract filename and extension.
    let path = std::path::Path::new(&file_path);
    let original_name = path.file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .to_string();
    let original_ext = path.extension()
        .unwrap_or_default()
        .to_string_lossy()
        .to_lowercase();

    // 3. Check size limit (34MB default, hard cap on default relay).
    let max_size = if let Some(ref sid) = server_id {
        server_states.get(sid)
            .and_then(|s| s.settings.get("max_file_size_mb"))
            .and_then(|reg| reg.read().parse::<u64>().ok())
            .unwrap_or(34) * 1024 * 1024
    } else {
        file_transfer::DEFAULT_MAX_FILE_SIZE
    };
    if share_ref.is_none() && file_data.len() as u64 > max_size {
        hollow_log!("[HOLLOW-FILE] File too large: {} > {}", file_data.len(), max_size);
        let _ = event_tx.send(NetworkEvent::FileFailed {
            file_id: message_id.clone(),
            error: format!("File too large ({}MB limit)", max_size / 1024 / 1024),
        }).await;
        return;
    }

    // 4. Convert to WebP if image.
    //
    // Phase 6.75: honor the user-configurable image quality tier.
    // Lossless (100%) / Balanced (50%, default) / Small (30%).
    // We read the setting from app_settings each send — a single
    // SQLite KV lookup so the cost is negligible. Bypass rules:
    //   - GIFs → animated WebP at all tiers (even lossless beats GIF)
    //   - WebP inputs pass through untouched (already encoded)
    // No size-based bypass: even tiny 20 KB PNGs routinely drop
    // to 2-3 KB at Q=50 (~90% reduction), and "tiny × millions of
    // messages" is still meaningful bandwidth. The encode cost on
    // small files is trivial.
    let mime = file_transfer::mime_from_ext(&original_ext);
    let is_image = file_transfer::is_image_mime(&mime);

    let webp_quality = {
        crate::storage::MessageStore::open(db_path, db_passphrase)
            .ok()
            .and_then(|s| s.load_setting("image_quality").ok().flatten())
            .map(|s| image_convert::WebpQuality::from_setting(&s))
            .unwrap_or_default()
    };

    let (final_data, final_ext, width, height) = if is_image
        && image_convert::should_convert_to_webp(&original_ext)
    {
        match image_convert::convert_to_webp_with_quality(&file_data, webp_quality) {
            Ok((webp_data, w, h)) => {
                hollow_log!("[HOLLOW-FILE] Converted to WebP ({:?}): {}KB -> {}KB ({}x{})",
                    webp_quality, file_data.len() / 1024, webp_data.len() / 1024, w, h);
                (webp_data, "webp".to_string(), Some(w), Some(h))
            }
            Err(e) => {
                hollow_log!("[HOLLOW-FILE] WebP conversion failed, sending original: {e}");
                let dims = image_convert::get_image_dimensions(&file_data).ok();
                (std::mem::take(&mut file_data), original_ext.clone(), dims.map(|d| d.0), dims.map(|d| d.1))
            }
        }
    } else if is_image && original_ext == "webp" {
        // WebP passthrough — strip metadata by decode+re-encode.
        let stripped = image_convert::strip_webp_metadata(&file_data)
            .unwrap_or_else(|_| std::mem::take(&mut file_data));
        let dims = image_convert::get_image_dimensions(&stripped).ok();
        (stripped, original_ext.clone(), dims.map(|d| d.0), dims.map(|d| d.1))
    } else if is_image && original_ext == "gif" {
        // GIF → animated WebP at all quality tiers (even lossless
        // WebP beats GIF's LZW compression).
        match image_convert::convert_gif_to_animated_webp(&file_data, webp_quality) {
            Ok((webp_data, w, h)) => {
                hollow_log!(
                    "[HOLLOW-FILE] Converted GIF to animated WebP ({:?}): {}KB -> {}KB ({}x{})",
                    webp_quality, file_data.len() / 1024, webp_data.len() / 1024, w, h
                );
                (webp_data, "webp".to_string(), Some(w), Some(h))
            }
            Err(e) => {
                // Fallback: strip metadata and send as GIF.
                hollow_log!(
                    "[HOLLOW-FILE] GIF->WebP conversion failed, sending as GIF: {e}"
                );
                let stripped = image_convert::strip_gif_metadata(&file_data);
                let dims = image_convert::get_image_dimensions(&stripped).ok();
                (stripped, original_ext.clone(), dims.map(|d| d.0), dims.map(|d| d.1))
            }
        }
    } else {
        // Non-image files: use Dart-supplied dimensions if any (Phase 6.75
        // video preview passes the source video's dimensions through here).
        (std::mem::take(&mut file_data), original_ext.clone(), override_width, override_height)
    };

    // 5. Generate file ID.
    let file_id = file_transfer::generate_file_id();
    let file_size = final_data.len() as u64;
    let total_chunks = 0u32; // 0 = streamed transfer
    let final_mime = file_transfer::mime_from_ext(&final_ext);

    // Determine if this is a vault server (6+ members).
    let member_count = if let Some(ref sid) = server_id {
        server_states.get(sid).map(|s| s.members.len()).unwrap_or(0)
    } else {
        0
    };
    // Store full file locally for DMs, <6 servers, or images (need local preview).
    let store_full_file = server_id.is_none() || member_count < 6 || is_image;

    hollow_log!("[HOLLOW-FILE] File {file_id}: {original_name} -> {file_size} bytes (streamed={store_full_file})");

    // 6. Store file locally (skip for non-image vault files — shards handle storage).
    let final_path = file_transfer::final_file_path(&file_id, &final_ext);
    if store_full_file {
        if let Err(e) = tokio::fs::write(&final_path, &final_data).await {
            hollow_log!("[HOLLOW-FILE] Failed to save local file: {e}");
        }
    }

    let local_peer = local_peer_str.to_string();
    let now_dur = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let timestamp = now_dur.as_millis() as i64;
    // Microsecond send timestamp for stable ordering (Step 9C/C4).
    let order_us = now_dur.as_micros() as i64;

    // 7. Save file metadata to DB.
    let ctx_type;
    let ctx_id;
    if let Some(ref sid) = server_id {
        ctx_type = "channel";
        ctx_id = format!("{}:{}", sid, channel_id.as_deref().unwrap_or(""));
    } else {
        ctx_type = "dm";
        ctx_id = peer_id.clone().unwrap_or_default();
    }

    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let _ = store.insert_file_metadata(
                &file_id, &original_name, &final_ext, &final_mime,
                file_size, total_chunks, is_image,
                width, height,
                Some(&message_id), ctx_type, &ctx_id,
                &local_peer, true, timestamp,
                vthumb.as_ref(),
            );
            if store_full_file {
                let _ = store.mark_file_complete(
                    &file_id,
                    &final_path.to_string_lossy(),
                );
            }
        }
    }

    // Emit FileCompleted on the sender side too, so the
    // sender's UI reloads the chat from the DB and picks
    // up the real width/height/videoThumb/etc that Rust
    // wrote to the local row. Without this, the sender's
    // optimistic FileAttachment (built without dimensions
    // by addFileMessage) is stuck with the wrong size.
    // Receivers already get this via the stream-receive
    // code path at swarm.rs:6898; sender path was missing.
    if store_full_file {
        let _ = event_tx.send(NetworkEvent::FileCompleted {
            file_id: file_id.clone(),
            disk_path: final_path.to_string_lossy().to_string(),
        }).await;
    }

    // 8. Build and send the message with file_id.
    let signing_payload_text = if message_text.is_empty() {
        format!("[file:{}]", file_id)
    } else {
        message_text.clone()
    };

    // Sign using the canonical payload format (must match
    // verify_message_signature on the receive path).
    // Previously this called sign_message with raw text,
    // causing every file-message signature to fail verification.
    let (sig, pk) = if let Some(ref peer_str) = peer_id {
        // DM: context = recipient, sender = local
        let payload = message_signing_payload(
            "dm", peer_str, &local_peer, timestamp, &signing_payload_text,
        );
        sign_message(bundle_keypair, pub_key_b64, &payload)
    } else if let (Some(sid), Some(cid)) = (&server_id, &channel_id) {
        // Channel: context = server_id:channel_id, sender = local
        let payload = message_signing_payload(
            "ch", &format!("{sid}:{cid}"), &local_peer, timestamp, &signing_payload_text,
        );
        sign_message(bundle_keypair, pub_key_b64, &payload)
    } else {
        (None, None)
    };

    if let Some(peer_str) = peer_id {
        // DM path. The companion caption / "[file:...]" DM is a DirectMessage; for
        // a sibling self-echo it must carry `convo` = the recipient master so our
        // other device files it under the right thread (see message_ops fan-out).
        let build_file_dm = |convo: Option<String>| MessageEnvelope::DirectMessage {
            inner: Box::new(DirectMessagePayload {
                text: signing_payload_text.clone(),
                ts: timestamp,
                sig: sig.clone(),
                pk: pk.clone(),
                mid: Some(message_id.clone()),
                reply_to: None,
                file_id: Some(file_id.clone()),
                link_preview: None,
                convo,
                order_us: Some(order_us),
            }),
        };

        // Store the text message (keyed by the recipient MASTER id — same as the
        // DM-thread key the UI/receive path uses).
        {
            if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                let _ = store.insert(
                    &peer_str, &signing_payload_text, true, timestamp,
                    sig.as_deref(), pk.as_deref(), Some(&message_id),
                    None, Some(&file_id), Some(order_us),
                );
            }
        }

        // ── Multi-device fan-out (Phase 6, Step 3) ──────────────────────
        // `peer_str` is the recipient's MASTER id. The companion DM caption,
        // FileHeader, and (online) WebRTC stream all key on per-DEVICE Olm
        // sessions / room membership, so we must deliver to each of the
        // recipient's devices AND our own siblings (so a file sent from one of
        // our devices mirrors live to the other). Single-device recipients
        // resolve to an empty device set → fall back to the master id = exact
        // pre-multi-device behavior. The DELICATE offline-image caption ratchet
        // rule (send exactly once via send_encrypted_text_to_peer, never
        // send_encrypted_message) holds PER DEVICE — each device has its own Olm
        // ratchet, so "exactly once per device" is the correct generalization.
        // Target set = persisted device list UNION devices currently in the DM
        // room (live presence is authoritative — see message_ops::collect_target_devices;
        // a stale/polluted stored list must not hide the connected device).
        let recipient_master = crate::node::resolver::resolve(&peer_str);
        let dm_room_f = crate::node::types::dm_room_code(local_peer_str, &recipient_master);
        // LIVENESS-FILTERED (Step 7 ghost fix, mirrors message_ops::collect_target_devices):
        // only target stored devices CURRENTLY IN A ROOM. A dead ghost id (from a
        // re-link cycle) has a stale session but is in no room, so without this it
        // would hit the offline room-send path → spurious push + unread on a phantom
        // device. The live-room union below still catches any real online device the
        // stored list missed; the single-device fallback preserves offline push.
        let mut file_set: std::collections::HashSet<String> =
            crate::node::resolver::devices_for(&recipient_master)
                .into_iter()
                .filter(|d| ws_room_for_peer(&ws_room_peers, d).is_some())
                .collect();
        let own_master_f = crate::node::resolver::resolve(local_peer_str);
        for sib in crate::node::resolver::devices_for(&own_master_f) {
            if ws_room_for_peer(&ws_room_peers, &sib).is_some() {
                file_set.insert(sib);
            }
        }
        if let Some(peers) = ws_room_peers.get(&dm_room_f) {
            for p in peers {
                let m = crate::node::resolver::resolve(p);
                if m == recipient_master || m == own_master_f {
                    file_set.insert(p.clone());
                }
            }
        }
        file_set.remove(device_peer_id);      // never send to ourselves
        file_set.remove(&recipient_master);   // never the bare master
        file_set.remove(&own_master_f);
        let mut file_targets: Vec<String> = file_set.into_iter().collect();
        if file_targets.is_empty() {
            // Single-device recipient with no live device → master id as-is.
            file_targets.push(peer_str.clone());
        }
        hollow_log!(
            "[HOLLOW-MULTIDEV] DM file fan-out for master {peer_str}: {} target device(s)",
            file_targets.len()
        );

        for peer_str in &file_targets {
        let peer_str = peer_str.as_str();
        // Per-device companion DM envelope: a sibling self-echo carries `convo`
        // (recipient master) so it files under the right thread; the recipient's
        // own devices get the plain envelope (convo=None).
        let is_sibling_target = crate::node::resolver::same_identity(peer_str, local_peer_str);
        let envelope_json = serde_json::to_string(&build_file_dm(
            if is_sibling_target { Some(recipient_master.clone()) } else { None },
        )).unwrap_or_else(|_| signing_payload_text.clone());
        // Encrypt and send the message + FileHeader + FileChunks via Olm.
        if olm.has_session(peer_str) {
            // EXACT-device reachability (not identity-wide): in a fan-out one
            // device may be online while a sibling is offline. ws_room_for_peer
            // = exact membership.
            let reachable = ws_room_for_peer(&ws_room_peers, peer_str).is_some();

            // Send the message (caption / "[file:...]") envelope.
            //
            // CRITICAL — Olm ratchet ordering: `send_encrypted_message` ALWAYS
            // calls olm.encrypt() (advancing + persisting the ratchet) BEFORE it
            // checks reachability, and DISCARDS the ciphertext if the peer is
            // offline. For an OFFLINE IMAGE that wasted encryption burns a ratchet
            // slot the receiver never sees — a permanent gap that breaks decrypt
            // of the FileHeader/caption that follow. So when offline-and-image we
            // must NOT call it here; the caption is sent exactly once below via
            // the DM-room-direct path (which also actually delivers to the buffer).
            // The online path and the non-image offline path are unchanged.
            let offline_image = !reachable && is_image;
            if !offline_image {
                send_encrypted_message(
                                olm, crypto_store,
                                peer_str, &envelope_json, event_tx,
                                            &ws_cmd_tx, &ws_room_peers,
                ).await;
            }

            // Only send file data if peer is reachable right now.
            // If offline, the file_id is in the message — sync will request it later.
            if reachable {

            // AES-encrypt the file, write ciphertext to temp file.
            let encrypted = crate::vault::pipeline::aes_encrypt(&final_data);
            if let Ok(enc) = encrypted {
                // Per-device temp file: sibling devices may stream the same
                // file_id concurrently, so the ciphertext temp must not collide.
                let temp_path = file_transfer::files_dir().join(format!(".stream_send_{file_id}_{peer_str}.tmp"));
                if let Ok(()) = tokio::fs::write(&temp_path, &enc.ciphertext).await {
                    let aes_key_hex = hex::encode(enc.key);
                    let aes_nonce_hex = hex::encode(enc.nonce);

                    // Send FileHeader via Olm (carries AES key — tiny, secure).
                    let header = MessageEnvelope::FileHeader {
                        inner: Box::new(FileHeaderPayload {
                            fid: file_id.clone(),
                            name: original_name.clone(),
                            ext: final_ext.clone(),
                            mime: final_mime.clone(),
                            size: file_size,
                            chunks: 0,
                            img: is_image,
                            w: width,
                            h: height,
                            mid: Some(message_id.clone()),
                            sid: None,
                            cid: None,
                            ts: timestamp,
                            sig: None,
                            pk: None,
                            aes_key: Some(aes_key_hex),
                            aes_nonce: Some(aes_nonce_hex),
                            target: None,
                            vthumb: vthumb.clone(),
                            share_ref: None,
                            inline_bytes: None,
                        }),
                    };
                    let header_json = serde_json::to_string(&header).unwrap_or_default();
                    send_encrypted_message(
                                olm, crypto_store,
                                peer_str, &header_json, event_tx,
                                                            &ws_cmd_tx, &ws_room_peers,
                    ).await;

                    // Stream encrypted file bytes via WebRTC or WS relay.
                    stream_to_peer(
                        &ws_cmd_tx, &ws_room_peers,
                        &webrtc_peers, pending_webrtc_sends, &event_tx,
                        peer_str, &ws_stream_transfer::StreamKind::File,
                        &file_id, &temp_path, enc.ciphertext.len() as u64,
                    ).await;
                    hollow_log!("[HOLLOW-FILE] Streaming {file_id} ({} bytes) to DM {peer_str}", enc.ciphertext.len());
                }
            }
            } else if is_image {
                // Peer is OFFLINE and this is an image: inline the AES-encrypted
                // bytes INTO the FileHeader and send it via SendDirectImage (0x08)
                // so the relay buffers it under the per-peer image cap. The FCM
                // fetch node then writes the file to disk and renders a real image
                // preview in the push notification — no live stream needed. Larger
                // non-image files still fall back to request-on-open via DM-sync.
                if let Ok(enc) = crate::vault::pipeline::aes_encrypt(&final_data) {
                    let header = MessageEnvelope::FileHeader {
                        inner: Box::new(FileHeaderPayload {
                            fid: file_id.clone(),
                            name: original_name.clone(),
                            ext: final_ext.clone(),
                            mime: final_mime.clone(),
                            size: file_size,
                            chunks: 0,
                            img: is_image,
                            w: width,
                            h: height,
                            mid: Some(message_id.clone()),
                            sid: None,
                            cid: None,
                            ts: timestamp,
                            // Carry the signature on the offline-image FileHeader.
                            // For a CAPTIONLESS image this is the ONLY transmitted
                            // signature (the "[file:...]" companion DM is dropped
                            // to offline peers), and it's signed over the same
                            // "[file:<id>]" text the fetch node stores — so the
                            // row verifies instead of showing "Unsigned". For a
                            // CAPTIONED image the caption DM carries its own sig
                            // over the caption text and overwrites this via
                            // promote_file_sentinel_to_caption; harmless here.
                            sig: sig.clone(),
                            pk: pk.clone(),
                            aes_key: Some(hex::encode(enc.key)),
                            aes_nonce: Some(hex::encode(enc.nonce)),
                            target: None,
                            vthumb: vthumb.clone(),
                            share_ref: None,
                            inline_bytes: Some(
                                base64::engine::general_purpose::STANDARD
                                    .encode(&enc.ciphertext),
                            ),
                        }),
                    };
                    let header_json = serde_json::to_string(&header).unwrap_or_default();
                    // Target the MASTER-pair DM room directly (computed once above
                    // as `dm_room_f`) — the offline peer is not a member of any
                    // known room, so a lookup would drop the message, and
                    // `dm_room_code` is pure now so it must NOT be recomputed from
                    // the per-device `peer_str` (that keys the room on the device,
                    // not the identity → the offline buffer/replay room mismatches).
                    // The relay buffers it under the image cap (mirrors offline text-DM).
                    crate::node::crypto_handler::send_encrypted_image_to_peer(
                        olm, crypto_store,
                        peer_str, dm_room_f.clone(), &header_json, event_tx,
                        &ws_cmd_tx,
                    ).await;
                    hollow_log!("[HOLLOW-FILE] Inlined offline image {file_id} ({} enc bytes) to DM {peer_str}", enc.ciphertext.len());

                    // If this image has a CAPTION, send it now — exactly once,
                    // AFTER the FileHeader — straight to the DM room (0x04, text
                    // cap). We deliberately skipped the caption's normal send
                    // above (offline_image guard) to avoid a wasted Olm
                    // encryption that would corrupt the ratchet. The caption
                    // shares the FileHeader's message_id, so the fetch node merges
                    // them (real caption wins over the "[file:...]" sentinel) and
                    // the offline peer sees the captioned image. Encryption order
                    // on the wire is FileHeader (#N) then caption (#N+1) — no gap.
                    if !message_text.is_empty() {
                        crate::node::crypto_handler::send_encrypted_text_to_peer(
                            olm, crypto_store,
                            peer_str, dm_room_f.clone(), &envelope_json, event_tx,
                            &ws_cmd_tx,
                        ).await;
                        hollow_log!("[HOLLOW-FILE] Buffered offline image caption for DM {peer_str}");
                    }
                }
            } // if peer reachable (live stream) / else offline image (inline)
        }

        hollow_log!("[HOLLOW-FILE] Sent {total_chunks} chunks for {file_id} to DM {peer_str}");
        } // for peer_str in &file_targets

    } else if let (Some(sid), Some(cid)) = (server_id, channel_id) {
        // Channel path — broadcast via MLS.
        let envelope = MessageEnvelope::ChannelMessage {
            inner: Box::new(ChannelMessagePayload {
                sid: sid.clone(),
                cid: cid.clone(),
                text: signing_payload_text.clone(),
                ts: timestamp,
                sig: sig.clone(),
                pk: pk.clone(),
                mid: Some(message_id.clone()),
                reply_to: None,
                file_id: Some(file_id.clone()),
                link_preview: None,
                order_us: Some(order_us),
            }),
        };
        let envelope_json = serde_json::to_string(&envelope)
            .unwrap_or_else(|_| signing_payload_text.clone());

        // Store the text message.
        {
            if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                let _ = store.insert_channel_message(
                    &sid, &cid, &local_peer, &signing_payload_text, true, timestamp,
                    sig.as_deref(), pk.as_deref(), Some(&message_id),
                    None, Some(&file_id), Some(order_us),
                );
            }
        }

        // Send the TEXT MESSAGE via MLS (for proper sync/queue to offline peers).
        if let Some(mls_mgr) = mls {
            if let Ok(ct) = mls_mgr.encrypt(&sid, envelope_json.as_bytes()) {
                crate::node::crypto_handler::persist_mls_state(mls_mgr, crypto_store);
                let mls_msg = HavenMessage::MlsChannelMessage {
                    server_id: sid.clone(),
                    body: base64::engine::general_purpose::STANDARD.encode(&ct),
                };
                if let Some(state) = server_states.get(&sid) {
                    let mls_data = serde_json::to_vec(&mls_msg).unwrap_or_default();
                    for member_peer_str in state.members.keys() {
                        if super::resolver::same_identity(member_peer_str, &local_peer) { continue; }
                        super::crypto_handler::send_raw_to_identity(&ws_cmd_tx, &ws_room_peers, member_peer_str, mls_data.clone());
                    }
                }
            }
        }

        // Send FileHeader + file bytes via stream to connected peers.
        // Skip full-file streaming in erasure coding mode (6+ members) —
        // vault shards are distributed separately via VaultUploadFile.
        let member_count = server_states.get(&sid)
            .map(|s| s.members.len())
            .unwrap_or(0);
        // Stream images to online peers even in vault mode (instant display).
        // Non-image files in 6+ servers use vault shards only.
        let use_vault_only = member_count >= 6 && !is_image;

        let has_share_ref = share_ref.is_some();

        // Vault-only: generate key+nonce for the FileHeader without encrypting.
        // The vault upload path (crdt.rs) does its own AES encryption.
        let (aes_key_hex, aes_nonce_hex, temp_path, ct_size) = if use_vault_only {
            match crate::vault::pipeline::aes_generate_key_nonce() {
                Ok((key, nonce)) => {
                    let temp_path = file_transfer::files_dir().join(format!(".stream_send_{file_id}.tmp"));
                    (hex::encode(key), hex::encode(nonce), temp_path, 0u64)
                }
                Err(e) => {
                    hollow_log!("[HOLLOW-FILE] AES key generation failed: {e}");
                    return;
                }
            }
        } else {
            match crate::vault::pipeline::aes_encrypt(&final_data) {
                Ok(enc) => {
                    let key_hex = hex::encode(&enc.key);
                    let nonce_hex = hex::encode(&enc.nonce);
                    let temp_path = file_transfer::files_dir().join(format!(".stream_send_{file_id}.tmp"));
                    if !has_share_ref {
                        let _ = tokio::fs::write(&temp_path, &enc.ciphertext).await;
                    }
                    let ct_size = if has_share_ref { 0 } else { enc.ciphertext.len() as u64 };
                    (key_hex, nonce_hex, temp_path, ct_size)
                }
                Err(e) => {
                    hollow_log!("[HOLLOW-FILE] AES encryption failed: {e}");
                    return;
                }
            }
        };

        {
            let header = MessageEnvelope::FileHeader {
                inner: Box::new(FileHeaderPayload {
                    fid: file_id.clone(),
                    name: original_name.clone(),
                    ext: final_ext.clone(),
                    mime: final_mime.clone(),
                    size: file_size,
                    chunks: 0,
                    img: is_image,
                    w: width,
                    h: height,
                    mid: Some(message_id.clone()),
                    sid: Some(sid.clone()),
                    cid: Some(cid.clone()),
                    ts: timestamp,
                    sig: None,
                    pk: None,
                    aes_key: Some(aes_key_hex),
                    aes_nonce: Some(aes_nonce_hex),
                    target: None,
                    vthumb: vthumb.clone(),
                    share_ref: share_ref.clone(),
                    inline_bytes: None,
                }),
            };
            let header_json = serde_json::to_string(&header).unwrap_or_default();

            if let Some(state) = server_states.get(&sid) {
                // Broadcast FileHeader via MLS (single encrypt, relay fans out).
                let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&sid));
                if mls_ok {
                    if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), &ws_cmd_tx, &sid, &header, crypto_store) {
                        hollow_log!("[HOLLOW-MLS] FileHeader broadcast failed: {e}");
                    }
                } else {
                    // Olm fallback: send FileHeader to each ONLINE DEVICE of each member.
                    for member_peer_str in state.members.keys() {
                        if super::resolver::same_identity(member_peer_str, &local_peer) { continue; }
                        for dev in super::crypto_handler::online_devices_for(&ws_room_peers, member_peer_str) {
                            if olm.has_session(&dev) {
                                send_encrypted_message(
                                    olm, crypto_store,
                                    &dev, &header_json, event_tx,
                                    &ws_cmd_tx, &ws_room_peers,
                                ).await;
                            }
                        }
                    }
                }

                if has_share_ref {
                    hollow_log!("[HOLLOW-FILE] Share-backed file {file_id} — skipping binary streaming");
                } else if use_vault_only {
                    hollow_log!("[HOLLOW-FILE] Erasure coding active ({member_count} members) — skipping full-file streaming, vault handles shard distribution");
                } else if let Some(overlay) = gossip_overlays.get_mut(&sid) {
                    // Gossip broadcast: send to gossip neighbors only (they relay further).
                    let broadcast_id = gossip::generate_broadcast_id();
                    overlay.mark_broadcast_seen(&broadcast_id);

                    // MLS-broadcast BroadcastMeta so all peers know this file is coming.
                    let meta_envelope = MessageEnvelope::BroadcastMeta {
                        broadcast_id: broadcast_id.clone(),
                        origin: local_peer.clone(),
                        sid: sid.clone(),
                        cid: cid.clone(),
                        file_id: file_id.clone(),
                        ttl: gossip::DEFAULT_BROADCAST_TTL,
                    };
                    if let Some(mls_mgr) = mls {
                        if mls_mgr.has_group(&sid) {
                            let _ = send_mls_broadcast(mls_mgr, &ws_cmd_tx, &sid, &meta_envelope, crypto_store);
                        }
                    }

                    broadcast_to_gossip_neighbors(
                        overlay, &webrtc_peers, &event_tx,
                        &broadcast_id, gossip::DEFAULT_BROADCAST_TTL,
                        &local_peer, &temp_path.to_string_lossy(),
                        ct_size, "file", 0, None, &cid,
                    ).await;

                    hollow_log!("[HOLLOW-GOSSIP] File {file_id} broadcast initiated (bid={broadcast_id})");
                } else {
                    // Small server (<6 members, no gossip overlay): full replication
                    // to each ONLINE DEVICE of each member.
                    for member_peer_str in state.members.keys() {
                        if super::resolver::same_identity(member_peer_str, &local_peer) { continue; }
                        for dev in super::crypto_handler::online_devices_for(&ws_room_peers, member_peer_str) {
                            stream_to_peer(
                                &ws_cmd_tx, &ws_room_peers,
                                &webrtc_peers, pending_webrtc_sends, &event_tx,
                                &dev, &ws_stream_transfer::StreamKind::File,
                                &file_id, &temp_path, ct_size,
                            ).await;
                        }
                    }
                }
            }
        }

        hollow_log!("[HOLLOW-FILE] Streamed {file_id} to channel {cid}");
    }
}

/// Handle NodeCommand::RequestFile — request file from peer.
/// Checks for a partial WS transfer and includes the byte offset for resumption.
#[allow(clippy::too_many_arguments)]
pub(crate) fn handle_request_file(
    file_id: String,
    peer_id_str: String,
    chunks: Vec<u32>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    pending_ws_transfers: &HashMap<String, super::ws_stream_transfer::WsTransferState>,
) {
    let offset = pending_ws_transfers.get(&file_id)
        .map(|s| s.bytes_received)
        .unwrap_or(0);

    if offset > 0 {
        hollow_log!("[HOLLOW-FILE] Resuming file {file_id} from offset {offset} from peer {peer_id_str}");
    } else {
        hollow_log!("[HOLLOW-FILE] Requesting file {file_id} from peer {peer_id_str}");
    }

    // Multi-device: `peer_id_str` is the conversation MASTER (the UI/friend key),
    // which no socket authenticates as — sending the FileRequest directly would be
    // silently dropped, so the file bytes never arrive (FileHeader synced but the
    // image/Download stays broken). Resolve to EXACTLY ONE online device.
    //
    // CRITICAL — request from ONE device, NOT a fan-out. A DM file is fanned out
    // at SEND time to the recipient's devices AND siblings, so MULTIPLE devices
    // hold a copy — but each holder re-encrypts its stream with its OWN random
    // AES key. Requesting from several → several streams arrive, but the receiver
    // only kept ONE FileHeader's AES key → every other stream fails AES-GCM
    // decrypt and auto-re-requests, an infinite FileHeader/stream/decrypt-fail
    // loop (the "stuck loading forever, 16.2/16.2 KB" + 4.5k log lines bug).
    // Deterministic single pick (lowest device id). If the requester already
    // knows a live device id, use it as-is. Single-device → the raw id unchanged.
    let target = if ws_room_peers.values().any(|peers| peers.contains(&peer_id_str)) {
        // Already a live device id — request from it directly.
        Some(peer_id_str.clone())
    } else {
        let mut devices = super::crypto_handler::online_devices_for(&ws_room_peers, &peer_id_str);
        devices.sort();
        devices.into_iter().next()
            .or_else(|| peer_is_reachable(&ws_room_peers, &peer_id_str).then(|| peer_id_str.clone()))
    };
    match target {
        Some(t) => {
            send_message_to_peer(
                &ws_cmd_tx, &ws_room_peers,
                &t, HavenMessage::FileRequest { file_id, chunks, offset },
            );
        }
        None => {
            hollow_log!("[HOLLOW-FILE] No online device for {peer_id_str} — FileRequest for {file_id} not sent");
        }
    }
}

/// Handle NodeCommand::WebRtcTransferComplete — completed WebRTC transfer.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_webrtc_transfer_complete(
    transfer_id: String,
    temp_path: String,
    sender_peer_id: String,
    kind: String,
    shard_index: u16,
    pending_file_streams: &mut HashMap<String, PendingFileStream>,
    pending_shard_streams: &mut HashMap<String, PendingShardStream>,
    pending_vault_downloads: &mut HashMap<String, (String, usize, usize)>,
    early_file_streams: &mut HashMap<String, (PathBuf, u64, String)>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    gossip_overlays: &mut HashMap<String, gossip::GossipOverlay>,
    webrtc_peers: &std::collections::HashSet<String>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-WEBRTC] Transfer complete: {transfer_id} from {sender_peer_id}");
    let stream_kind = if kind == "shard" {
        ws_stream_transfer::StreamKind::Shard { shard_index }
    } else {
        ws_stream_transfer::StreamKind::File
    };
    let temp_path_buf = PathBuf::from(&temp_path);
    let file_size = std::fs::metadata(&temp_path).map(|m| m.len()).unwrap_or(0);
    let request = ws_stream_transfer::StreamRequest {
        kind: stream_kind,
        id: transfer_id.clone(),
        size: file_size,
        temp_path: temp_path_buf,
    };
    // WebRTC-completed transfers are File/Shard only; link snapshots are relay-only.
    let mut empty_link_snapshots = HashMap::new();
    handle_completed_stream(
        request,
        &sender_peer_id,
        pending_file_streams,
        pending_shard_streams,
        pending_vault_downloads,
        early_file_streams,
        &mut empty_link_snapshots,
        bundle_keypair,
        event_tx,
        ws_cmd_tx,
        ws_room_peers,
        db_path,
        db_passphrase,
    ).await;

    // Gossip relay: if this file has a pending relay, forward to neighbors.
    if kind == "file" {
        for overlay in gossip_overlays.values_mut() {
            if let Some(relay) = overlay.take_pending_relay(&transfer_id) {
                if relay.ttl > 0 {
                    hollow_log!(
                        "[HOLLOW-GOSSIP] Relaying file {transfer_id} (bid={}, ttl={}) to neighbors",
                        relay.broadcast_id, relay.ttl
                    );
                    broadcast_to_gossip_neighbors(
                        overlay, webrtc_peers, event_tx,
                        &relay.broadcast_id, relay.ttl.saturating_sub(1),
                        &relay.origin, &temp_path,
                        file_size, "file", 0,
                        Some(&relay.sender_peer_id),
                        &relay.channel_id,
                    ).await;
                }
                break;
            }
        }
    }
}

/// Handle NodeCommand::WebRtcSendComplete — completed send.
pub(crate) fn handle_webrtc_send_complete(
    transfer_id: String,
    pending_webrtc_sends: &mut HashMap<String, (String, ws_stream_transfer::StreamKind, String, PathBuf, u64)>,
) {
    hollow_log!("[HOLLOW-WEBRTC] Send complete: {transfer_id}");
    if let Some((_, _, _, path, _)) = pending_webrtc_sends.remove(&transfer_id) {
        if path.file_name().map(|n| n.to_string_lossy().starts_with(".stream_send_")).unwrap_or(false) {
            let _ = std::fs::remove_file(&path);
        }
    }
    // Share chunk temps bypass pending_webrtc_sends — clean by transfer_id pattern.
    // Share transfer_ids are "{short_root}:{chunk_index}".
    if transfer_id.contains(':') {
        let short_root = transfer_id.split(':').next().unwrap_or("");
        let idx_str = transfer_id.split(':').nth(1).unwrap_or("");
        if let Ok(shares_dir) = super::share_handler::shares_dir() {
            let tmp = shares_dir.join(format!(".send_{short_root}_{idx_str}.tmp"));
            let _ = std::fs::remove_file(&tmp);
        }
    }
}

/// Handle NodeCommand::WebRtcTransferFailed — failed transfer with retry.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_webrtc_transfer_failed(
    transfer_id: String,
    peer_id: String,
    error: String,
    webrtc_peers: &mut std::collections::HashSet<String>,
    pending_webrtc_sends: &mut HashMap<String, (String, ws_stream_transfer::StreamKind, String, PathBuf, u64)>,
    pending_file_streams: &HashMap<String, PendingFileStream>,
    early_file_streams: &mut HashMap<String, (PathBuf, u64, String)>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    event_tx: &mpsc::Sender<NetworkEvent>,
) {
    hollow_log!("[HOLLOW-WEBRTC] Transfer failed: {transfer_id} to/from {peer_id}: {error}");
    webrtc_peers.remove(&peer_id);
    // Sender-side retry: re-send via WSS relay.
    if let Some((_, kind, id, source_path, total_size)) = pending_webrtc_sends.remove(&transfer_id) {
        hollow_log!("[HOLLOW-WEBRTC] Sender fallback: retrying {id} via WSS relay");
        stream_to_peer(
            &ws_cmd_tx, &ws_room_peers,
            &webrtc_peers, pending_webrtc_sends, &event_tx,
            &peer_id, &kind, &id, &source_path, total_size,
        ).await;
    }
    // Receiver-side retry: if we have a pending file stream for this transfer,
    // send a FileRequest to get it via WSS. Also remove early arrival if present.
    if pending_file_streams.contains_key(&transfer_id) || early_file_streams.contains_key(&transfer_id) {
        early_file_streams.remove(&transfer_id);
        hollow_log!("[HOLLOW-WEBRTC] Receiver fallback: requesting {transfer_id} via FileRequest");
        send_message_to_peer(
            &ws_cmd_tx, &ws_room_peers,
            &peer_id, HavenMessage::FileRequest {
                file_id: transfer_id,
                chunks: vec![],
                offset: 0,
            },
        );
    }
}

/// Decryption material for an in-flight multi-device link snapshot. The snapshot
/// bytes are AES-256-GCM encrypted with a one-time random key generated for this
/// link session; the receiver holds the key/nonce here keyed by link session id
/// until the chunked transfer reassembles.
pub(crate) struct LinkSnapshotState {
    /// The link CODE the receiver typed — the passphrase the inbound `.hollow` blob
    /// is encrypted with. We stash the blob + this code for a next-launch import via
    /// the proven `import_backup` pipeline (NOT an in-place import).
    pub code: String,
}

/// Handle a completed stream transfer (file, shard, or link snapshot).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_completed_stream(
    request: ws_stream_transfer::StreamRequest,
    sender_peer: &str,
    pending_file_streams: &mut HashMap<String, PendingFileStream>,
    pending_shard_streams: &mut HashMap<String, PendingShardStream>,
    pending_vault_downloads: &mut HashMap<String, (String, usize, usize)>,
    early_file_streams: &mut HashMap<String, (PathBuf, u64, String)>,
    pending_link_snapshots: &mut HashMap<String, LinkSnapshotState>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    db_path: &str,
    db_passphrase: &str,
) {
    use ws_stream_transfer::StreamKind;

    // Share chunks have their own completion path (handle_webrtc_share_chunk_complete)
    // and never flow through this function — early return defensively.
    if matches!(request.kind, StreamKind::ShareChunk { .. }) { return; }

    match request.kind {
        StreamKind::ShareChunk { .. } => unreachable!(),
        StreamKind::LinkSnapshot => {
            let link_id = request.id.clone();
            // Events use the bare session id (no "link_" transport prefix) so Dart
            // sees a consistent id across LinkProgress/LinkComplete/LinkFailed.
            let bare_id = link_id.strip_prefix("link_").unwrap_or(&link_id).to_string();
            hollow_log!("[HOLLOW-LINK] Inbound link snapshot: {link_id} ({} bytes)", request.size);

            let Some(state) = pending_link_snapshots.remove(&link_id) else {
                // No decryption material registered for this link session — drop it.
                hollow_log!("[HOLLOW-LINK] No pending link state for {link_id} — dropping snapshot");
                let _ = std::fs::remove_file(&request.temp_path);
                let _ = event_tx.send(NetworkEvent::LinkFailed {
                    link_id: bare_id,
                    error: "no pending link session".to_string(),
                }).await;
                return;
            };

            // The inbound bytes are a full `.hollow` backup blob encrypted with the
            // link CODE. We DON'T import in-place (that path was fragile). Instead we
            // STASH the blob + code and signal a restart; on next launch the bootstrap
            // imports it via the exact same `import_backup` pipeline as a manual
            // restore (the known-good, pre-node-start window).
            let outcome: Result<(), String> = (|| {
                let blob = std::fs::read(&request.temp_path)
                    .map_err(|e| format!("read link blob: {e}"))?;
                crate::api::storage::stash_pending_link(&blob, &state.code)
                    .map_err(|e| format!("stash failed: {e}"))
            })();

            let _ = std::fs::remove_file(&request.temp_path);

            match outcome {
                Ok(()) => {
                    hollow_log!("[HOLLOW-LINK] Snapshot {link_id} stashed ({} bytes) — restart to import", request.size);
                    // Tell the SENDER we truly have everything, so its spinner flips to
                    // "Data sent" only now (not when it merely finished queuing bytes).
                    super::crypto_handler::send_message_to_peer(
                        ws_cmd_tx, ws_room_peers, sender_peer,
                        super::types::HavenMessage::LinkSnapshotAck { link_id: link_id.clone() },
                    );
                    hollow_log!("[HOLLOW-LINK] Sent LinkSnapshotAck for {link_id} to {sender_peer}");
                    let _ = event_tx.send(NetworkEvent::LinkComplete {
                        link_id: bare_id,
                        msg_count: 0,
                        friend_count: 0,
                        server_count: 0,
                    }).await;
                }
                Err(e) => {
                    hollow_log!("[HOLLOW-LINK] Snapshot {link_id} stash failed: {e}");
                    let _ = event_tx.send(NetworkEvent::LinkFailed { link_id: bare_id, error: e }).await;
                }
            }
        }
        StreamKind::File => {
            let file_id = request.id.clone();
            hollow_log!("[HOLLOW-STREAM] Inbound file stream: {file_id} ({} bytes)", request.size);

            if let Some(pfs) = pending_file_streams.remove(&file_id) {
                // Outcome of the decrypt attempt: Some(disk_path) on success, None on
                // any failure (read error, bad key length, or GCM auth failure). A GCM
                // failure here is usually a transient assembly/truncation race under
                // concurrent transfers — the bytes on the source are fine — so we
                // auto re-request rather than give up (see FILE_DECRYPT_MAX_RETRIES).
                let mut decrypted_path: Option<String> = None;
                let mut fail_reason = String::from("unreadable stream");
                if let Ok(ciphertext) = tokio::fs::read(&request.temp_path).await {
                    let key_bytes = hex::decode(&pfs.aes_key).unwrap_or_default();
                    let nonce_bytes = hex::decode(&pfs.aes_nonce).unwrap_or_default();
                    if key_bytes.len() == 32 && nonce_bytes.len() == 12 {
                        let key: [u8; 32] = key_bytes.try_into().unwrap();
                        let nonce: [u8; 12] = nonce_bytes.try_into().unwrap();
                        match crate::vault::pipeline::aes_decrypt(&ciphertext, &key, &nonce) {
                            Ok(plaintext) => {
                                let final_path = file_transfer::final_file_path(&file_id, &pfs.ext);
                                if let Ok(()) = tokio::fs::write(&final_path, &plaintext).await {
                                    let disk_path = final_path.to_string_lossy().to_string();
                                    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                                        let _ = store.mark_file_complete(&file_id, &disk_path);
                                    }
                                    hollow_log!("[HOLLOW-STREAM] File {file_id} complete: {disk_path}");
                                    decrypted_path = Some(disk_path);
                                } else {
                                    fail_reason = "failed to write decrypted file".to_string();
                                }
                            }
                            Err(e) => { fail_reason = format!("decrypt failed: {e}"); }
                        }
                    } else {
                        fail_reason = "invalid AES key/nonce length".to_string();
                    }
                }
                match decrypted_path {
                    Some(disk_path) => {
                        // Success — consume the assembled stream.
                        let _ = std::fs::remove_file(&request.temp_path);
                        let _ = event_tx.send(NetworkEvent::FileCompleted { file_id, disk_path }).await;
                    }
                    None => {
                        // The ciphertext is intact (right size) but didn't decrypt
                        // against THIS pending stream's key. ROOT CAUSE: the bytes
                        // (fast WebRTC P2P) routinely BEAT the FileHeader (slower
                        // Olm/relay) — the logs show `FileHeader received` the line
                        // AFTER `decrypt failed`. So these bytes belong to a header
                        // that hasn't landed yet; the `pfs` we just popped was a STALE
                        // pending stream from a prior request (wrong key). Previously
                        // we deleted the bytes + immediately re-requested, which spawned
                        // ANOTHER crossed header/stream pair → an endless decrypt-fail
                        // loop that only a restart (serializing one clean pair) fixed.
                        //
                        // FIX: PRESERVE the bytes as an early-arrival (keyed by file_id)
                        // and DO NOT re-request. The header that was already in flight
                        // arrives a moment later and its early-arrival path reprocesses
                        // these exact bytes against the CORRECT key → success, no loop.
                        // (`request.temp_path` is intentionally NOT removed here.)
                        hollow_log!(
                            "[HOLLOW-STREAM] File {file_id} {fail_reason} — bytes arrived before their header; holding as early-arrival for the matching key"
                        );
                        early_file_streams.insert(
                            file_id.clone(),
                            (request.temp_path.clone(), request.size, sender_peer.to_string()),
                        );
                        // Safety net: if NO matching header ever arrives (e.g. the Olm
                        // header was genuinely lost, not just late), one bounded
                        // re-request recovers it. Gated on retry_count so it can't loop.
                        if pfs.retry_count < FILE_DECRYPT_MAX_RETRIES
                            && peer_is_reachable(ws_room_peers, &pfs.sender)
                        {
                            let next = pfs.retry_count + 1;
                            let sender = pfs.sender.clone();
                            let mut retry_pfs = pfs;
                            retry_pfs.retry_count = next;
                            // Keep the pending stream so a late header preserves the count.
                            pending_file_streams.insert(file_id.clone(), retry_pfs);
                            send_message_to_peer(
                                ws_cmd_tx, ws_room_peers,
                                &sender, HavenMessage::FileRequest {
                                    file_id: file_id.clone(),
                                    chunks: vec![],
                                    offset: 0,
                                },
                            );
                            hollow_log!("[HOLLOW-STREAM] File {file_id} — safety re-request {next}/{FILE_DECRYPT_MAX_RETRIES} from {sender}");
                        }
                    }
                }
            } else {
                // WebRTC race: bytes arrived before FileHeader. Save for later.
                hollow_log!("[HOLLOW-STREAM] No pending FileHeader for stream {file_id} — saving as early arrival");
                early_file_streams.insert(file_id, (request.temp_path.clone(), request.size, sender_peer.to_string()));
                // Don't delete the temp file — FileHeader handler will pick it up.
            }
        }
        StreamKind::Shard { shard_index } => {
            let content_id = request.id.clone();
            let key = format!("{content_id}:{shard_index}");
            hollow_log!("[HOLLOW-STREAM] Inbound shard stream: cid={content_id} si={shard_index} ({} bytes)", request.size);

            if let Some(pss) = pending_shard_streams.remove(&key) {
                if let Ok(shard_bytes) = tokio::fs::read(&request.temp_path).await {
                    let data_dir = crate::identity::data_dir().unwrap_or_default();
                    let vault_dir = data_dir.join("vault");
                    if let Ok(content_store) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) {
                        let tier = crate::vault::content_store::StorageTier::from_str(&pss.tier);
                        let _ = content_store.store_shard(
                            &pss.server_id, &pss.content_id, pss.shard_index,
                            pss.k, pss.m, pss.total_size, tier, &shard_bytes,
                        );
                        hollow_log!("[HOLLOW-STREAM] Shard stored: cid={content_id} si={shard_index}");
                        let _ = event_tx.send(NetworkEvent::ShardStored {
                            server_id: pss.server_id.clone(),
                            content_id: content_id.clone(),
                            shard_index,
                            from_peer: sender_peer.to_string(),
                        }).await;

                        if let Some((dl_server_id, dl_k, _)) = pending_vault_downloads.remove(&content_id) {
                            hollow_log!("[HOLLOW-VAULT] Shard arrived for pending download — attempting reconstruction: {content_id}");
                            if let Ok(manifest) = content_store.load_manifest(&content_id) {
                                if let Some(manifest) = manifest {
                                    let n = dl_k + manifest.m as usize;
                                    let local_shards = content_store.list_content_shards(&dl_server_id, &content_id).unwrap_or_default();
                                    let mut packed: Vec<Option<Vec<u8>>> = vec![None; n];
                                    for record in &local_shards {
                                        let idx = record.shard_index as usize;
                                        if idx < n {
                                            if let Ok(data) = content_store.read_shard_unchecked(&dl_server_id, &record.shard_key) {
                                                packed[idx] = Some(data);
                                            }
                                        }
                                    }
                                    let avail = packed.iter().filter(|s| s.is_some()).count();
                                    if avail >= dl_k {
                                        let ext = crate::vault::pipeline::ext_from_filename(&manifest.file_name);
                                        match crate::vault::pipeline::reconstruct_file(&manifest, &packed) {
                                            Ok(plaintext) => {
                                                if let Ok(path) = crate::vault::pipeline::write_to_cache(&content_id, &ext, &plaintext) {
                                                    let disk_path = path.to_string_lossy().to_string();
                                                    hollow_log!("[HOLLOW-VAULT] Download reconstructed: {disk_path}");
                                                    let _ = event_tx.send(NetworkEvent::VaultDownloadComplete {
                                                        server_id: dl_server_id, content_id: content_id.clone(), disk_path,
                                                    }).await;
                                                }
                                            }
                                            Err(e) => {
                                                hollow_log!("[HOLLOW-VAULT] Reconstruction failed: {e}");
                                                let _ = event_tx.send(NetworkEvent::VaultDownloadFailed {
                                                    server_id: dl_server_id, content_id: content_id.clone(), error: e,
                                                }).await;
                                            }
                                        }
                                    } else {
                                        pending_vault_downloads.insert(content_id.clone(), (dl_server_id, dl_k, 0));
                                        hollow_log!("[HOLLOW-VAULT] Still need more shards: have {avail}, need {dl_k}");
                                    }
                                }
                            }
                        }
                    }
                }
                let _ = std::fs::remove_file(&request.temp_path);
            } else {
                hollow_log!("[HOLLOW-STREAM] No pending ShardStore for stream {key} — ignoring");
                let _ = std::fs::remove_file(&request.temp_path);
            }
        }
    }
}


/// Stream file or shard data to a peer. Prefers WebRTC data channel if available,
/// falls back to WS binary frames via relay.
pub(crate) async fn stream_to_peer(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    webrtc_peers: &std::collections::HashSet<String>,
    pending_webrtc_sends: &mut HashMap<String, (String, ws_stream_transfer::StreamKind, String, PathBuf, u64)>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    peer_str: &str,
    kind: &ws_stream_transfer::StreamKind,
    id: &str,
    source_path: &std::path::Path,
    total_size: u64,
) {
    // Prefer WebRTC data channel if peer has one active.
    if webrtc_peers.contains(peer_str) {
        let kind_str = match kind {
            ws_stream_transfer::StreamKind::Shard { .. } => "shard",
            ws_stream_transfer::StreamKind::ShareChunk { .. } => "share_chunk",
            // LinkSnapshot is relay-only and never routed over WebRTC; treat as file.
            ws_stream_transfer::StreamKind::File | ws_stream_transfer::StreamKind::LinkSnapshot => "file",
        };
        let shard_index = match kind {
            ws_stream_transfer::StreamKind::Shard { shard_index } => *shard_index,
            _ => 0,
        };
        // Store for fallback on failure.
        pending_webrtc_sends.insert(id.to_string(), (
            peer_str.to_string(), kind.clone(), id.to_string(),
            source_path.to_path_buf(), total_size,
        ));
        let _ = event_tx.send(NetworkEvent::WebRtcSendFile {
            peer_id: peer_str.to_string(),
            transfer_id: id.to_string(),
            file_path: source_path.to_string_lossy().to_string(),
            total_size,
            kind: kind_str.to_string(),
            shard_index,
            chunk_index: 0,
        }).await;
        hollow_log!("[HOLLOW-WEBRTC] Routing {id} to {peer_str} via WebRTC data channel");
        return;
    }
    // Fallback: WSS relay binary streaming.
    if let Some(room) = ws_room_for_peer(ws_room_peers, peer_str) {
        ws_stream_transfer::ws_stream_send(
            ws_cmd_tx, &room, peer_str, kind, id, source_path, total_size, 0,
        ).await;
    } else {
        hollow_log!("[HOLLOW-STREAM] Peer {peer_str} unreachable via WS — cannot stream {id}");
    }
}

/// Stream data from an in-memory buffer to a peer. Prefers WebRTC (writes temp file for Dart),
/// falls back to WS binary frames via relay (streams from memory, no disk).
pub(crate) async fn stream_to_peer_bytes(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    webrtc_peers: &std::collections::HashSet<String>,
    pending_webrtc_sends: &mut HashMap<String, (String, ws_stream_transfer::StreamKind, String, PathBuf, u64)>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    peer_str: &str,
    kind: &ws_stream_transfer::StreamKind,
    id: &str,
    data: &[u8],
) {
    if webrtc_peers.contains(peer_str) {
        // WebRTC: Dart reads from file path — must write temp file.
        let temp_path = file_transfer::files_dir().join(format!(".stream_shard_{id}.tmp"));
        let _ = std::fs::write(&temp_path, data);
        let total_size = data.len() as u64;
        let kind_str = match kind {
            ws_stream_transfer::StreamKind::Shard { .. } => "shard",
            ws_stream_transfer::StreamKind::ShareChunk { .. } => "share_chunk",
            // LinkSnapshot is relay-only and never routed over WebRTC; treat as file.
            ws_stream_transfer::StreamKind::File | ws_stream_transfer::StreamKind::LinkSnapshot => "file",
        };
        let shard_index = match kind {
            ws_stream_transfer::StreamKind::Shard { shard_index } => *shard_index,
            _ => 0,
        };
        pending_webrtc_sends.insert(id.to_string(), (
            peer_str.to_string(), kind.clone(), id.to_string(),
            temp_path.to_path_buf(), total_size,
        ));
        let _ = event_tx.send(NetworkEvent::WebRtcSendFile {
            peer_id: peer_str.to_string(),
            transfer_id: id.to_string(),
            file_path: temp_path.to_string_lossy().to_string(),
            total_size,
            kind: kind_str.to_string(),
            shard_index,
            chunk_index: 0,
        }).await;
        hollow_log!("[HOLLOW-WEBRTC] Routing {id} to {peer_str} via WebRTC data channel (from bytes)");
        return;
    }
    if let Some(room) = ws_room_for_peer(ws_room_peers, peer_str) {
        ws_stream_transfer::ws_stream_send_bytes(
            ws_cmd_tx, &room, peer_str, kind, id, data,
        ).await;
    } else {
        hollow_log!("[HOLLOW-STREAM] Peer {peer_str} unreachable via WS — cannot stream {id}");
    }
}

/// Broadcast a file to all gossip neighbors for a server (minus an optional exclude peer).
/// Used for gossip relay tree file distribution.
pub(crate) async fn broadcast_to_gossip_neighbors(
    gossip_overlay: &gossip::GossipOverlay,
    webrtc_peers: &std::collections::HashSet<String>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    broadcast_id: &str,
    ttl: u8,
    origin_peer_id: &str,
    file_path: &str,
    total_size: u64,
    kind: &str,
    shard_index: u16,
    exclude_peer: Option<&str>,
    channel_id: &str,
) {
    let targets = gossip_overlay.get_relay_targets(exclude_peer);
    let target_count = targets.len();
    hollow_log!(
        "[HOLLOW-GOSSIP] Broadcasting {broadcast_id} (ttl={ttl}) to {target_count} neighbors (server={})",
        gossip_overlay.server_id
    );

    for peer_id in targets {
        if webrtc_peers.contains(&peer_id) {
            // Emit GossipRelayFile event — Dart will send via data channel with broadcast header.
            let _ = event_tx.send(NetworkEvent::GossipRelayFile {
                broadcast_id: broadcast_id.to_string(),
                ttl,
                origin_peer_id: origin_peer_id.to_string(),
                file_path: file_path.to_string(),
                total_size,
                kind: kind.to_string(),
                shard_index,
                exclude_peer_id: exclude_peer.unwrap_or("").to_string(),
                server_id: gossip_overlay.server_id.clone(),
                channel_id: channel_id.to_string(),
            }).await;
        } else {
            hollow_log!("[HOLLOW-GOSSIP] Neighbor {peer_id} has no data channel — skipping");
        }
    }
}

/// Handle `MessageEnvelope::FileHeader` — register pending stream + emit FileHeaderReceived.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_file_header(
    server_states: &HashMap<String, ServerState>,
    pending_file_streams: &mut HashMap<String, PendingFileStream>,
    pending_shard_streams: &mut HashMap<String, PendingShardStream>,
    early_file_streams: &mut HashMap<String, (PathBuf, u64, String)>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    server_id: &str,
    sender_peer_id: String,
    fid: String,
    name: String,
    ext: String,
    mime: String,
    size: u64,
    chunks: u32,
    img: bool,
    w: Option<u32>,
    h: Option<u32>,
    mid: Option<String>,
    sid: Option<String>,
    cid: Option<String>,
    ts: i64,
    aes_key: Option<String>,
    aes_nonce: Option<String>,
    vthumb: Option<VideoThumbRef>,
    share_ref: Option<super::types::ShareRef>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-FILE] MLS FileHeader: {fid} ({name}, {size} bytes, {chunks} chunks, share_ref={})", share_ref.is_some());

    if share_ref.is_none() {
        let max_mb_str = if let Some(state) = server_states.get(server_id) {
            state.settings.get("max_file_size_mb")
                .map(|r| r.read().clone())
                .unwrap_or_else(|| "34".to_string())
        } else { "34".to_string() };
        let max_bytes = max_mb_str.parse::<u64>().unwrap_or(34) * 1024 * 1024;
        if size > max_bytes {
            hollow_log!("[HOLLOW-SECURITY] REJECTED MLS FileHeader from {sender_peer_id} — size {size} exceeds max {max_bytes}");
            return;
        }
    }

    let ctx_type = "channel";
    let ctx_id = match (&sid, &cid) {
        (Some(s), Some(c)) => format!("{s}:{c}"),
        _ => server_id.to_string(),
    };

    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let _ = store.insert_file_metadata(
            &fid, &name, &ext, &mime,
            size, chunks, img,
            w, h,
            mid.as_deref(), ctx_type, &ctx_id,
            &sender_peer_id, false, ts,
            vthumb.as_ref(),
        );
    }

    // Register pending stream so binary file bytes can be decrypted on arrival.
    // Skip for share-backed files — no binary data arrives via P2P, Share handles delivery.
    if share_ref.is_none() && let (Some(ak), Some(an)) = (aes_key, aes_nonce) {
        pending_file_streams.insert(fid.clone(), PendingFileStream {
            aes_key: ak,
            aes_nonce: an,
            file_name: name.clone(),
            ext: ext.clone(),
            sender: sender_peer_id.clone(),
            server_id: sid.clone().unwrap_or_else(|| server_id.to_string()),
            channel_id: cid.clone().unwrap_or_default(),
            message_id: mid.clone().unwrap_or_default(),
            is_image: img,
            width: w,
            height: h,
            retry_count: 0,
        });
        hollow_log!("[HOLLOW-FILE] Registered pending stream for {fid} (MLS streamed transfer)");

        // Check if WebRTC bytes already arrived before this FileHeader.
        if let Some((temp_path, file_size, sender)) = early_file_streams.remove(&fid) {
            hollow_log!("[HOLLOW-FILE] Early arrival found for {fid} (MLS path) — processing now");
            let request = ws_stream_transfer::StreamRequest {
                kind: ws_stream_transfer::StreamKind::File,
                id: fid.clone(),
                size: file_size,
                temp_path,
            };
            let mut empty_vault_dl = HashMap::new();
            // This early-arrival path only ever carries StreamKind::File; link
            // snapshots never take the WebRTC early-arrival route, so an empty map is fine.
            let mut empty_link_snapshots = HashMap::new();
            handle_completed_stream(
                request, &sender,
                pending_file_streams, pending_shard_streams,
                &mut empty_vault_dl, early_file_streams,
                &mut empty_link_snapshots,
                bundle_keypair, event_tx,
                ws_cmd_tx, ws_room_peers,
                db_path, db_passphrase,
            ).await;
        }
    }

    let _ = event_tx.send(NetworkEvent::FileHeaderReceived {
        file_id: fid,
        file_name: name,
        size_bytes: size,
        is_image: img,
        width: w,
        height: h,
        message_id: mid.unwrap_or_default(),
        sender_id: sender_peer_id,
        server_id: sid.unwrap_or_else(|| server_id.to_string()),
        channel_id: cid.unwrap_or_default(),
        video_thumb: vthumb,
        share_ref,
    }).await;
}

/// Handle `MessageEnvelope::FileChunk` — write chunk + assemble on completion.
pub(crate) async fn handle_envelope_file_chunk(
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    fid: String,
    idx: u32,
    data: String,
    db_path: &str,
    db_passphrase: &str,
) {
    let chunk_bytes = match base64::engine::general_purpose::STANDARD.decode(&data) {
        Ok(b) => b,
        Err(e) => {
            hollow_log!("[HOLLOW-FILE] MLS chunk decode failed: {e}");
            return;
        }
    };

    if let Err(e) = file_transfer::write_chunk(&fid, idx, &chunk_bytes) {
        hollow_log!("[HOLLOW-FILE] {e}");
    } else {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            if let Ok(received) = store.mark_chunk_received(&fid, idx) {
                if let Ok(Some(file_meta)) = store.get_file_metadata(&fid) {
                    let _ = event_tx.send(NetworkEvent::FileProgress {
                        file_id: fid.clone(),
                        chunks_received: received,
                        total_chunks: file_meta.chunk_count,
                    }).await;

                    if received >= file_meta.chunk_count {
                        let final_path = file_transfer::final_file_path(&fid, &file_meta.file_ext);
                        match file_transfer::assemble_file(&fid, file_meta.chunk_count, &final_path) {
                            Ok(()) => {
                                let disk_path = final_path.to_string_lossy().to_string();
                                let _ = store.mark_file_complete(&fid, &disk_path);
                                hollow_log!("[HOLLOW-FILE] MLS file {fid} complete: {disk_path}");
                                let _ = event_tx.send(NetworkEvent::FileCompleted {
                                    file_id: fid,
                                    disk_path,
                                }).await;
                            }
                            Err(e) => {
                                hollow_log!("[HOLLOW-FILE] MLS assembly failed: {e}");
                                let _ = event_tx.send(NetworkEvent::FileFailed {
                                    file_id: fid,
                                    error: e,
                                }).await;
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Handle `MessageEnvelope::BroadcastMeta` — gossip relay tree dedup + pending relay registration.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_broadcast_meta(
    gossip_overlays: &mut HashMap<String, gossip::GossipOverlay>,
    local_peer_str: &str,
    sender_peer_id: &str,
    broadcast_id: String,
    origin: String,
    sid: String,
    cid: String,
    file_id: String,
    ttl: u8,
) {
    // SECURITY (Phase 6.25): Validate TTL from wire, cap at MAX_BROADCAST_TTL.
    let effective_ttl = ttl.min(MAX_BROADCAST_TTL);
    hollow_log!("[HOLLOW-GOSSIP] BroadcastMeta: bid={broadcast_id} origin={origin} fid={file_id} server={sid} ch={cid} ttl={effective_ttl}");
    if effective_ttl == 0 {
        hollow_log!("[HOLLOW-GOSSIP] BroadcastMeta TTL=0, not relaying");
    } else if let Some(overlay) = gossip_overlays.get_mut(&sid) {
        overlay.mark_broadcast_seen(&broadcast_id);
        if origin != local_peer_str {
            overlay.add_pending_relay(
                &file_id, &broadcast_id,
                effective_ttl.saturating_sub(1),
                &origin, &cid, sender_peer_id,
            );
        }
    }
}
