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
    let file_data = match std::fs::read(&file_path) {
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
                (file_data.clone(), original_ext.clone(), dims.map(|d| d.0), dims.map(|d| d.1))
            }
        }
    } else if is_image && original_ext == "webp" {
        // WebP passthrough — strip metadata by decode+re-encode.
        let stripped = image_convert::strip_webp_metadata(&file_data)
            .unwrap_or_else(|_| file_data.clone());
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
        (file_data.clone(), original_ext.clone(), override_width, override_height)
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
        if let Err(e) = std::fs::write(&final_path, &final_data) {
            hollow_log!("[HOLLOW-FILE] Failed to save local file: {e}");
        }
    }

    let local_peer = local_peer_str.to_string();
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

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
        // DM path
        let envelope = MessageEnvelope::DirectMessage {
            inner: Box::new(DirectMessagePayload {
                text: signing_payload_text.clone(),
                ts: timestamp,
                sig: sig.clone(),
                pk: pk.clone(),
                mid: Some(message_id.clone()),
                reply_to: None,
                file_id: Some(file_id.clone()),
                link_preview: None,
            }),
        };
        let envelope_json = serde_json::to_string(&envelope)
            .unwrap_or_else(|_| signing_payload_text.clone());

        // Store the text message.
        {
            if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                let _ = store.insert(
                    &peer_str, &signing_payload_text, true, timestamp,
                    sig.as_deref(), pk.as_deref(), Some(&message_id),
                    None, Some(&file_id),
                );
            }
        }

        // Encrypt and send the message + FileHeader + FileChunks via Olm.
        if olm.has_session(&peer_str) {
            // Send message envelope.
            send_encrypted_message(
                            olm, crypto_store,
                            &peer_str, &envelope_json, event_tx,
                                        &ws_cmd_tx, &ws_room_peers,
            ).await;

            // Only send file data if peer is reachable right now.
            // If offline, the file_id is in the message — sync will request it later.
            if peer_is_reachable(&ws_room_peers, &peer_str) {

            // AES-encrypt the file, write ciphertext to temp file.
            let encrypted = crate::vault::pipeline::aes_encrypt(&final_data);
            if let Ok(enc) = encrypted {
                let temp_path = file_transfer::files_dir().join(format!(".stream_send_{file_id}.tmp"));
                if let Ok(()) = std::fs::write(&temp_path, &enc.ciphertext) {
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
                        }),
                    };
                    let header_json = serde_json::to_string(&header).unwrap_or_default();
                    send_encrypted_message(
                                olm, crypto_store,
                                &peer_str, &header_json, event_tx,
                                                            &ws_cmd_tx, &ws_room_peers,
                    ).await;

                    // Stream encrypted file bytes via WebRTC or WS relay.
                    stream_to_peer(
                        &ws_cmd_tx, &ws_room_peers,
                        &webrtc_peers, pending_webrtc_sends, &event_tx,
                        &peer_str, &ws_stream_transfer::StreamKind::File,
                        &file_id, &temp_path, enc.ciphertext.len() as u64,
                    ).await;
                    hollow_log!("[HOLLOW-FILE] Streaming {file_id} ({} bytes) to DM {peer_str}", enc.ciphertext.len());
                }
            }
            } // if connected_peers (file data only)
        }

        hollow_log!("[HOLLOW-FILE] Sent {total_chunks} chunks for {file_id} to DM {peer_str}");

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
                    None, Some(&file_id),
                );
            }
        }

        // Send the TEXT MESSAGE via MLS (for proper sync/queue to offline peers).
        // Only one MLS encrypt call — no SecretReuseError risk.
        if let Some(mls_mgr) = mls {
            if let Ok(ct) = mls_mgr.encrypt(&sid, envelope_json.as_bytes()) {
                let mls_msg = HavenMessage::MlsChannelMessage {
                    server_id: sid.clone(),
                    body: base64::engine::general_purpose::STANDARD.encode(&ct),
                };
                if let Some(state) = server_states.get(&sid) {
                    for member_peer_str in state.members.keys() {
                        if member_peer_str == &local_peer { continue; }
                            if peer_is_reachable(&ws_room_peers, member_peer_str) {
                                send_message_to_peer(
                                    &ws_cmd_tx, &ws_room_peers,
                                    member_peer_str, mls_msg.clone(),
                                );
                            }
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

        let encrypted = crate::vault::pipeline::aes_encrypt(&final_data);
        if let Ok(enc) = encrypted {
            let aes_key_hex = hex::encode(&enc.key);
            let aes_nonce_hex = hex::encode(&enc.nonce);

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
                }),
            };
            let header_json = serde_json::to_string(&header).unwrap_or_default();

            let has_share_ref = share_ref.is_some();

            // Write ciphertext to temp file (shared across all members).
            // Skip for share-backed files — Share handles delivery.
            let temp_path = file_transfer::files_dir().join(format!(".stream_send_{file_id}.tmp"));
            if !has_share_ref {
                let _ = std::fs::write(&temp_path, &enc.ciphertext);
            }
            let ct_size = if has_share_ref { 0 } else { enc.ciphertext.len() as u64 };

            if let Some(state) = server_states.get(&sid) {
                // Broadcast FileHeader via MLS (single encrypt, relay fans out).
                let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&sid));
                if mls_ok {
                    if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), &ws_cmd_tx, &sid, &header, crypto_store) {
                        hollow_log!("[HOLLOW-MLS] FileHeader broadcast failed: {e}");
                    }
                } else {
                    // Olm fallback: send FileHeader to each member individually.
                    for member_peer_str in state.members.keys() {
                        if member_peer_str == &local_peer { continue; }
                            if peer_is_reachable(&ws_room_peers, member_peer_str) && olm.has_session(member_peer_str) {
                                send_encrypted_message(
                                olm, crypto_store,
                                member_peer_str, &header_json, event_tx,
                                    &ws_cmd_tx, &ws_room_peers,
                                ).await;
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
                    // Small server (<6 members, no gossip overlay): full replication.
                    for member_peer_str in state.members.keys() {
                        if member_peer_str == &local_peer { continue; }
                            if peer_is_reachable(&ws_room_peers, member_peer_str) {
                                stream_to_peer(
                                    &ws_cmd_tx, &ws_room_peers,
                                    &webrtc_peers, pending_webrtc_sends, &event_tx,
                                    member_peer_str, &ws_stream_transfer::StreamKind::File,
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

    if peer_is_reachable(&ws_room_peers, &peer_id_str) {
        send_message_to_peer(
            &ws_cmd_tx, &ws_room_peers,
            &peer_id_str, HavenMessage::FileRequest {
                file_id,
                chunks,
                offset,
            },
        );
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
    handle_completed_stream(
        request,
        &sender_peer_id,
        pending_file_streams,
        pending_shard_streams,
        pending_vault_downloads,
        early_file_streams,
        bundle_keypair,
        event_tx,
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

/// Handle a completed stream transfer (file or shard).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_completed_stream(
    request: ws_stream_transfer::StreamRequest,
    sender_peer: &str,
    pending_file_streams: &mut HashMap<String, PendingFileStream>,
    pending_shard_streams: &mut HashMap<String, PendingShardStream>,
    pending_vault_downloads: &mut HashMap<String, (String, usize, usize)>,
    early_file_streams: &mut HashMap<String, (PathBuf, u64, String)>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    db_path: &str,
    db_passphrase: &str,
) {
    use ws_stream_transfer::StreamKind;

    // Share chunks have their own completion path (handle_webrtc_share_chunk_complete)
    // and never flow through this function — early return defensively.
    if matches!(request.kind, StreamKind::ShareChunk { .. }) { return; }

    match request.kind {
        StreamKind::ShareChunk { .. } => unreachable!(),
        StreamKind::File => {
            let file_id = request.id.clone();
            hollow_log!("[HOLLOW-STREAM] Inbound file stream: {file_id} ({} bytes)", request.size);

            if let Some(pfs) = pending_file_streams.remove(&file_id) {
                if let Ok(ciphertext) = std::fs::read(&request.temp_path) {
                    let key_bytes = hex::decode(&pfs.aes_key).unwrap_or_default();
                    let nonce_bytes = hex::decode(&pfs.aes_nonce).unwrap_or_default();
                    if key_bytes.len() == 32 && nonce_bytes.len() == 12 {
                        let key: [u8; 32] = key_bytes.try_into().unwrap();
                        let nonce: [u8; 12] = nonce_bytes.try_into().unwrap();
                        match crate::vault::pipeline::aes_decrypt(&ciphertext, &key, &nonce) {
                            Ok(plaintext) => {
                                let final_path = file_transfer::final_file_path(&file_id, &pfs.ext);
                                if let Ok(()) = std::fs::write(&final_path, &plaintext) {
                                    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                                        let disk_path = final_path.to_string_lossy().to_string();
                                        let _ = store.mark_file_complete(&file_id, &disk_path);
                                    }
                                    let disk_path = final_path.to_string_lossy().to_string();
                                    hollow_log!("[HOLLOW-STREAM] File {file_id} complete: {disk_path}");
                                    let _ = event_tx.send(NetworkEvent::FileCompleted {
                                        file_id,
                                        disk_path,
                                    }).await;
                                } else {
                                    hollow_log!("[HOLLOW-STREAM] Failed to write decrypted file {file_id}");
                                }
                            }
                            Err(e) => {
                                hollow_log!("[HOLLOW-STREAM] AES decrypt failed for {file_id}: {e}");
                                let _ = event_tx.send(NetworkEvent::FileFailed {
                                    file_id,
                                    error: format!("Decrypt failed: {e}"),
                                }).await;
                            }
                        }
                    }
                }
                let _ = std::fs::remove_file(&request.temp_path);
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
                if let Ok(shard_bytes) = std::fs::read(&request.temp_path) {
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
            ws_stream_transfer::StreamKind::File => "file",
            ws_stream_transfer::StreamKind::Shard { .. } => "shard",
            ws_stream_transfer::StreamKind::ShareChunk { .. } => "share_chunk",
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
            handle_completed_stream(
                request, &sender,
                pending_file_streams, pending_shard_streams,
                &mut empty_vault_dl, early_file_streams,
                bundle_keypair, event_tx,
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
