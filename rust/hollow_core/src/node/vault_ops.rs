use std::collections::HashMap;

use base64::Engine;
use tokio::sync::mpsc;

use crate::crdt::server_state::ServerState;
use crate::crypto::{CryptoStore, MlsManager, OlmManager};
use super::crypto_handler::{
    peer_is_reachable, send_mls_broadcast, send_encrypted_message,
};
use super::file_handler;
use super::types::*;

// ── 1. VaultDownloadFile ─────────────────────────────────────────────

pub(crate) async fn handle_vault_download_file(
    server_states: &mut HashMap<String, crate::crdt::server_state::ServerState>,
    pending_vault_downloads: &mut HashMap<String, (String, usize, usize)>,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    server_id: String,
    content_id: String,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-VAULT] VaultDownloadFile: cid={content_id} in {server_id}");

    let data_dir = crate::identity::data_dir().unwrap_or_default();
    let vault_dir = data_dir.join("vault");

    let result: Result<String, String> = (|| {
        let cs = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir)?;

        // Load manifest
        let manifest = cs.load_manifest(&content_id)?
            .ok_or_else(|| format!("Manifest not found for {content_id}"))?;

        let ext = crate::vault::pipeline::ext_from_filename(&manifest.file_name);

        // Check cache first
        if let Some(cached_path) = crate::vault::pipeline::check_cache(&content_id, &ext) {
            return Ok(cached_path.to_string_lossy().to_string());
        }

        // Collect local shards
        let local_shards = cs.list_content_shards(&server_id, &content_id)?;

        if manifest.k == 0 && manifest.m == 0 {
            // Replication mode — need just one shard (the full ciphertext)
            if let Some(record) = local_shards.first() {
                let shard_data = cs.read_shard_unchecked(&server_id, &record.shard_key)?;
                let packed: Vec<Option<Vec<u8>>> = vec![Some(shard_data)];
                let plaintext = crate::vault::pipeline::reconstruct_file(&manifest, &packed)?;
                let path = crate::vault::pipeline::write_to_cache(&content_id, &ext, &plaintext)?;
                return Ok(path.to_string_lossy().to_string());
            }
            Err("No local shard available for replicated content".into())
        } else {
            // Erasure mode — need k of k+m shards
            let k = manifest.k as usize;
            let m = manifest.m as usize;
            let n = k + m;
            let mut packed: Vec<Option<Vec<u8>>> = vec![None; n];

            for record in &local_shards {
                let idx = record.shard_index as usize;
                if idx < n {
                    if let Ok(data) = cs.read_shard_unchecked(&server_id, &record.shard_key) {
                        packed[idx] = Some(data);
                    }
                }
            }

            let available = packed.iter().filter(|s| s.is_some()).count();
            if available >= k {
                let plaintext = crate::vault::pipeline::reconstruct_file(&manifest, &packed)?;
                let path = crate::vault::pipeline::write_to_cache(&content_id, &ext, &plaintext)?;
                Ok(path.to_string_lossy().to_string())
            } else {
                // Not enough local shards — collect placement info for network fetch.
                // Try saved placements first; if empty (non-uploader), recompute deterministically.
                let mut placements = cs.load_placements(&content_id).unwrap_or_default();
                if placements.is_empty() {
                    // Recompute from server state using the same deterministic algorithm
                    if let Some(state) = server_states.get(&server_id) {
                        let members: Vec<String> = state.members_list().iter().map(|m| m.peer_id.clone()).collect();
                        let pledges: std::collections::HashMap<String, u64> = members.iter()
                            .map(|pid| (pid.clone(), state.get_storage_pledge(pid)))
                            .collect();
                        let mode = crate::vault::adaptive::compute_adaptive_params(members.len());
                        let computed = crate::vault::placement::place(&content_id, &mode, &members, &pledges);
                        placements = computed.iter().map(|sp| crate::vault::content_store::PlacementRecord {
                            content_id: content_id.clone(),
                            shard_index: sp.shard_index,
                            target_peer: sp.target_peer.clone(),
                            server_id: server_id.clone(),
                            shard_key: sp.shard_key.clone(),
                            stored_at: 0,
                            confirmed: false,
                        }).collect();
                    }
                }
                let missing_indices: Vec<usize> = (0..n)
                    .filter(|i| packed[*i].is_none())
                    .collect();
                // Encode placement info into error string for post-closure processing
                let placement_info: Vec<String> = missing_indices.iter()
                    .filter_map(|idx| {
                        placements.iter()
                            .find(|p| p.shard_index as usize == *idx)
                            .map(|p| format!("{}:{}:{}", idx, p.target_peer, p.shard_key))
                    })
                    .collect();
                Err(format!("__NEED_SHARDS__:{}:{}:{}", available, k, placement_info.join("|")))
            }
        }
    })();

    match result {
        Ok(disk_path) => {
            hollow_log!("[HOLLOW-VAULT] Download complete: {disk_path}");
            let _ = event_tx.send(NetworkEvent::VaultDownloadComplete {
                server_id, content_id, disk_path,
            }).await;
        }
        Err(e) if e.starts_with("__NEED_SHARDS__:") => {
            // Parse placement info and request shards from connected peers
            let parts: Vec<&str> = e.splitn(4, ':').collect();
            if parts.len() >= 4 {
                let available: usize = parts[1].parse().unwrap_or(0);
                let k: usize = parts[2].parse().unwrap_or(3);
                let needed = k - available;
                let placement_entries: Vec<&str> = parts[3].split('|').filter(|s| !s.is_empty()).collect();

                let mut requested = 0usize;
                for entry in &placement_entries {
                    if requested >= needed { break; }
                    let ep: Vec<&str> = entry.splitn(3, ':').collect();
                    if ep.len() == 3 {
                        let si: u16 = ep[0].parse().unwrap_or(0);
                        let target_peer = ep[1];
                        let shard_key = ep[2];
                            if peer_is_reachable(&ws_room_peers, target_peer) {
                                let envelope = MessageEnvelope::ShardRequest {
                                    sid: server_id.clone(),
                                    cid: content_id.clone(),
                                    si,
                                    sk: shard_key.to_string(),
                                    target: None,
                                };
                                let json = serde_json::to_string(&envelope).unwrap_or_default();
                                send_encrypted_message(
                                    &mut *olm, crypto_store,
                                    target_peer, &json, &event_tx,
                                    &ws_cmd_tx, &ws_room_peers,
                                ).await;
                                hollow_log!("[HOLLOW-VAULT] Requested shard si={si} from {target_peer}");
                                requested += 1;
                            }
                    }
                }

                let total_available = available + requested;
                if total_available >= k && requested > 0 {
                    // Enough shards reachable — request and wait for them.
                    pending_vault_downloads.insert(
                        content_id.clone(),
                        (server_id.clone(), k, requested),
                    );
                    hollow_log!("[HOLLOW-VAULT] Requested {requested} shards for {content_id} (have {available}, need {k})");
                    let _ = event_tx.send(NetworkEvent::VaultDownloadProgress {
                        server_id, content_id,
                        phase: "Fetching shards from peers...".into(),
                        progress: 0.1,
                    }).await;
                } else {
                    // Not enough shard holders online — fail fast.
                    let online_holders = available + requested;
                    let _ = event_tx.send(NetworkEvent::VaultDownloadFailed {
                        server_id, content_id,
                        error: format!("{online_holders}/{k} shard holders online, need at least {k}. Try again later."),
                    }).await;
                }
            }
        }
        Err(e) => {
            hollow_log!("[HOLLOW-VAULT] Download failed: {e}");
            let _ = event_tx.send(NetworkEvent::VaultDownloadFailed {
                server_id, content_id, error: e,
            }).await;
        }
    }
}

// ── 2. VaultUploadFile ───────────────────────────────────────────────

pub(crate) async fn handle_vault_upload_file(
    server_states: &mut HashMap<String, crate::crdt::server_state::ServerState>,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    webrtc_peers: &std::collections::HashSet<String>,
    pending_webrtc_sends: &mut HashMap<String, (String, super::ws_stream_transfer::StreamKind, String, std::path::PathBuf, u64)>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    file_name: String,
    mime_type: String,
    message_id: String,
    ciphertext: Vec<u8>,
    aes_key: Vec<u8>,
    aes_nonce: Vec<u8>,
    original_size: u64,
    content_id: String,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-VAULT] VaultUploadFile: {file_name} cid={content_id} in {server_id}/{channel_id}");

    let aes_key_copy = aes_key.clone();
    let aes_nonce_copy = aes_nonce.clone();

    let mut upload_fallback_info: Option<(usize, usize)> = None;
    let upload_result: Result<(), String> = (|| {
        let state = server_states.get(&server_id)
            .ok_or_else(|| format!("Server {server_id} not found"))?;
        let local_peer = local_peer_str.to_string();

        // Build members + pledges from server state
        let all_members: Vec<String> = state.members.keys().cloned().collect();
        let pledges: std::collections::HashMap<String, u64> = state.storage_pledges
            .iter()
            .map(|(k, v)| (k.clone(), *v.read()))
            .collect();

        // Upload guard: if not enough peers are online for erasure coding,
        // fall back to replication among online peers only.
        let online_members: Vec<String> = all_members.iter()
            .filter(|m| *m == &local_peer || peer_is_reachable(&ws_room_peers, m))
            .cloned()
            .collect();
        let mode = crate::vault::adaptive::compute_adaptive_params(all_members.len());
        let use_fallback = if let crate::vault::adaptive::VaultMode::ErasureCoding { k, m } = &mode {
            online_members.len() < *k + *m
        } else {
            false
        };
        let members = if use_fallback {
            hollow_log!("[HOLLOW-VAULT] Upload guard: {} online < k+m for {} total members — falling back to replication", online_members.len(), all_members.len());
            online_members.clone()
        } else {
            all_members.clone()
        };

        // Prepare upload plan
        let key: [u8; 32] = aes_key.try_into().map_err(|_| "Invalid AES key length")?;
        let nonce: [u8; 12] = aes_nonce.try_into().map_err(|_| "Invalid AES nonce length")?;
        let plan = crate::vault::pipeline::prepare_upload(
            &ciphertext, &content_id, &key, &nonce,
            &file_name, &mime_type, &channel_id,
            original_size, &local_peer,
            &members, &pledges, &message_id,
        )?;

        // Open ContentStore for local operations
        let data_dir = crate::identity::data_dir().unwrap_or_default();
        let vault_dir = data_dir.join("vault");
        let cs = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir)?;

        // Store local shards
        let tier = crate::vault::content_store::StorageTier::from_str(&plan.manifest.storage_tier);
        for placement in &plan.placements {
            if placement.target_peer == local_peer {
                if let Some((_, shard_data)) = plan.shards.iter().find(|(idx, _)| *idx == placement.shard_index) {
                    let _ = cs.store_shard(
                        &server_id, &content_id, placement.shard_index,
                        plan.manifest.k, plan.manifest.m, plan.manifest.original_size,
                        tier, shard_data,
                    );
                }
            }
        }

        // Save placements + manifest
        let _ = cs.save_placements(&server_id, &content_id, &plan.placements);
        let _ = cs.save_manifest(&server_id, &channel_id, &plan.manifest);

        if use_fallback {
            if let crate::vault::adaptive::VaultMode::ErasureCoding { k, m } = &mode {
                upload_fallback_info = Some((online_members.len(), *k + *m));
            }
        }

        Ok(())
    })();

    match upload_result {
        Err(e) => {
            hollow_log!("[HOLLOW-VAULT] Upload failed: {e}");
            let _ = event_tx.send(NetworkEvent::VaultUploadFailed {
                server_id, content_id, error: e,
            }).await;
        }
        Ok(()) => {
            // Emit replication fallback event if upload guard triggered.
            if let Some((online, needed)) = upload_fallback_info {
                let _ = event_tx.send(NetworkEvent::VaultUploadReplicationFallback {
                    server_id: server_id.clone(), content_id: content_id.clone(),
                    online, needed,
                }).await;
            }
            // Re-prepare plan for shard distribution (need the data again)
            if let Some(state) = server_states.get(&server_id) {
                let local_peer = local_peer_str.to_string();
                let all_members: Vec<String> = state.members.keys().cloned().collect();
                let pledges: std::collections::HashMap<String, u64> = state.storage_pledges
                    .iter().map(|(k, v)| (k.clone(), *v.read())).collect();
                // Use same fallback logic as initial prepare
                let online_members: Vec<String> = all_members.iter()
                    .filter(|m| *m == &local_peer || peer_is_reachable(&ws_room_peers, m))
                    .cloned().collect();
                let mode = crate::vault::adaptive::compute_adaptive_params(all_members.len());
                let members = if let crate::vault::adaptive::VaultMode::ErasureCoding { k, m } = &mode {
                    if online_members.len() < *k + *m { online_members } else { all_members }
                } else { all_members };

                let key: [u8; 32] = aes_key_copy.try_into().unwrap_or([0u8; 32]);
                let nonce: [u8; 12] = aes_nonce_copy.try_into().unwrap_or([0u8; 12]);
                if let Ok(plan) = crate::vault::pipeline::prepare_upload(
                    &ciphertext, &content_id, &key, &nonce,
                    &file_name, &mime_type, &channel_id,
                    original_size, &local_peer, &members, &pledges, &message_id,
                ) {
                    // Send remote shards via streaming
                    for placement in &plan.placements {
                        if placement.target_peer != local_peer {
                            if let Some((_, shard_data)) = plan.shards.iter().find(|(idx, _)| *idx == placement.shard_index) {
                                    if peer_is_reachable(&ws_room_peers, &placement.target_peer) {
                                        // Send ShardStore metadata via MLS or Olm.
                                        let envelope = MessageEnvelope::ShardStore {
                                            inner: Box::new(ShardStorePayload {
                                                sid: server_id.clone(), cid: content_id.clone(),
                                                si: placement.shard_index, sk: placement.shard_key.clone(),
                                                k: plan.manifest.k, m: plan.manifest.m,
                                                total_size: plan.manifest.original_size,
                                                tier: plan.manifest.storage_tier.clone(),
                                                data: String::new(),
                                                chunks: 0,
                                                target: None,
                                            }),
                                        };
                                        let json = serde_json::to_string(&envelope).unwrap_or_default();
                                        send_encrypted_message(
                                            &mut *olm, crypto_store,
                                            &placement.target_peer, &json, &event_tx,
                                            &ws_cmd_tx, &ws_room_peers,
                                        ).await;

                                        // Stream shard bytes via stream_to_peer (WS or libp2p).
                                        let shard_temp_dir = crate::node::file_transfer::files_dir();
                                        let shard_safe_prefix = &content_id[..16.min(content_id.len())];
                                        let shard_temp_name = format!(".stream_shard_{}_{}.tmp", shard_safe_prefix, placement.shard_index);
                                        let shard_temp_path = shard_temp_dir.join(&shard_temp_name);
                                        if let Ok(()) = std::fs::write(&shard_temp_path, shard_data) {
                                            let shard_kind = super::ws_stream_transfer::StreamKind::Shard { shard_index: placement.shard_index };
                                            super::file_handler::stream_to_peer(
                                                &ws_cmd_tx, &ws_room_peers,
                                                webrtc_peers, pending_webrtc_sends, &event_tx,
                                                &placement.target_peer, &shard_kind,
                                                &content_id, &shard_temp_path, shard_data.len() as u64,
                                            ).await;
                                            hollow_log!("[HOLLOW-VAULT] Streaming shard si={} ({} bytes) to {}", placement.shard_index, shard_data.len(), placement.target_peer);
                                        }
                                    }
                            }
                        }
                    }

                    // Broadcast manifest via MLS (or Olm fallback).
                    let manifest_json = serde_json::to_string(&plan.manifest).unwrap_or_default();
                    let manifest_envelope = MessageEnvelope::VaultManifestBroadcast {
                        sid: server_id.clone(),
                        cid: content_id.clone(),
                        chid: channel_id.clone(),
                        manifest: manifest_json,
                    };
                    let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
                    if mls_ok {
                        if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), &ws_cmd_tx, &server_id, &manifest_envelope, crypto_store) {
                            hollow_log!("[HOLLOW-MLS] VaultManifest broadcast failed: {e}");
                        }
                    } else {
                        let manifest_env_json = serde_json::to_string(&manifest_envelope).unwrap_or_default();
                        for member_peer_str in state.members.keys() {
                            if member_peer_str == &local_peer { continue; }
                                if peer_is_reachable(&ws_room_peers, member_peer_str) && olm.has_session(member_peer_str) {
                                    send_encrypted_message(
                                &mut *olm, crypto_store,
                                member_peer_str, &manifest_env_json, &event_tx,
                                        &ws_cmd_tx, &ws_room_peers,
                                    ).await;
                                }
                        }
                    }
                }

                // Link vault content_id to the file record via message_id.
                if !message_id.is_empty() {
                    if let Ok(ms) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                        let _ = ms.set_file_content_id(&message_id, &content_id);
                    }
                }

                hollow_log!("[HOLLOW-VAULT] Upload complete: cid={content_id}");
                let _ = event_tx.send(NetworkEvent::VaultUploadComplete {
                    server_id, content_id, channel_id,
                }).await;
            }
        }
    }
}

// ── 3. DeleteVaultContent ────────────────────────────────────────────

pub(crate) async fn handle_delete_vault_content(
    server_states: &HashMap<String, crate::crdt::server_state::ServerState>,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    local_peer_str: &str,
    server_id: String,
    content_id: String,
    db_path: &str,
    db_passphrase: &str,
) {
    if let Some(state) = server_states.get(&server_id) {
        let local_peer = local_peer_str.to_string();
        if !state.has_permission(&local_peer, crate::crdt::operations::Permission::MANAGE_SERVER) {
            hollow_log!("[HOLLOW-VAULT] Permission denied: cannot delete vault content in {server_id}");
            return;
        }

        hollow_log!("[HOLLOW-VAULT] Deleting vault content {content_id} in {server_id}");

        // Delete local shards and placements
        let data_dir = crate::identity::data_dir().unwrap_or_default();
        let vault_dir = data_dir.join("vault");
        if let Ok(cs) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) {
            let _ = cs.delete_content(&server_id, &content_id);
            let _ = cs.delete_placements(&content_id);
        }

        // Broadcast ShardDelete to connected server members
        let delete_envelope = MessageEnvelope::ShardDelete {
            sid: server_id.clone(),
            cid: content_id.clone(),
        };
        // Broadcast ShardDelete via MLS or Olm fallback.
        let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
        if mls_ok {
            if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), &ws_cmd_tx, &server_id, &delete_envelope, crypto_store) {
                hollow_log!("[HOLLOW-MLS] ShardDelete broadcast failed: {e}");
            }
        } else {
            let delete_json = serde_json::to_string(&delete_envelope).unwrap_or_default();
            for member_peer_str in state.members.keys() {
                if member_peer_str == &local_peer { continue; }
                    if peer_is_reachable(&ws_room_peers, member_peer_str) && olm.has_session(member_peer_str) {
                        send_encrypted_message(
                                &mut *olm, crypto_store,
                                member_peer_str, &delete_json, &event_tx,
                            &ws_cmd_tx, &ws_room_peers,
                        ).await;
                    }
            }
        }

        let _ = event_tx.send(NetworkEvent::ShardDeleted {
            server_id,
            content_id,
        }).await;
    }
}

// ── 4. RequestShardFromPeer ──────────────────────────────────────────

pub(crate) async fn handle_request_shard_from_peer(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    server_id: String,
    content_id: String,
    shard_index: u16,
    shard_key: String,
    target_peer: String,
) {
    hollow_log!("[HOLLOW-VAULT] RequestShardFromPeer: cid={content_id} si={shard_index} from {target_peer}");
        if !peer_is_reachable(&ws_room_peers, &target_peer) {
            hollow_log!("[HOLLOW-VAULT] Cannot request shard: peer {target_peer} not reachable");
            let _ = event_tx.send(NetworkEvent::ShardRequestFailed {
                server_id, content_id, shard_index,
                error: "Peer not reachable".into(),
            }).await;
        } else {
            let envelope = MessageEnvelope::ShardRequest {
                sid: server_id.clone(),
                cid: content_id,
                si: shard_index,
                sk: shard_key,
                target: None,
            };
            let json = serde_json::to_string(&envelope).unwrap_or_default();
            send_encrypted_message(
                &mut *olm, crypto_store,
                &target_peer, &json, &event_tx,
                &ws_cmd_tx, &ws_room_peers,
            ).await;
        }
}

// ── 5. StoreShardOnPeer ──────────────────────────────────────────────

pub(crate) async fn handle_store_shard_on_peer(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    webrtc_peers: &std::collections::HashSet<String>,
    pending_webrtc_sends: &mut HashMap<String, (String, super::ws_stream_transfer::StreamKind, String, std::path::PathBuf, u64)>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    content_id: String,
    shard_index: u16,
    shard_key: String,
    k: u16,
    m: u16,
    total_data_size: u64,
    storage_tier: String,
    data: Vec<u8>,
    target_peer: String,
) {
    let _local_peer = local_peer_str.to_string();
    hollow_log!("[HOLLOW-VAULT] StoreShardOnPeer: cid={content_id} si={shard_index} -> {target_peer}");

        if !peer_is_reachable(&ws_room_peers, &target_peer) {
            hollow_log!("[HOLLOW-VAULT] Cannot store shard: peer {target_peer} not reachable");
            let _ = event_tx.send(NetworkEvent::ShardStoreFailed {
                server_id: server_id.clone(),
                content_id: content_id.clone(),
                shard_index,
                target_peer: target_peer.clone(),
                error: "Peer not reachable".into(),
            }).await;
        } else {
            // Send ShardStore metadata via MLS or Olm fallback.
            let envelope = MessageEnvelope::ShardStore {
                inner: Box::new(ShardStorePayload {
                    sid: server_id.clone(),
                    cid: content_id.clone(),
                    si: shard_index,
                    sk: shard_key.clone(),
                    k,
                    m,
                    total_size: total_data_size,
                    tier: storage_tier.clone(),
                    data: String::new(),
                    chunks: 0,
                    target: None,
                }),
            };
            let json = serde_json::to_string(&envelope).unwrap_or_default();
            send_encrypted_message(
                &mut *olm, crypto_store,
                &target_peer, &json, &event_tx,
                &ws_cmd_tx, &ws_room_peers,
            ).await;

            // Stream shard bytes via stream_to_peer (WS or libp2p).
            let shard_temp_dir = crate::node::file_transfer::files_dir();
            let shard_safe_prefix = &content_id[..16.min(content_id.len())];
            let shard_temp_name = format!(".stream_shard_{}_{}.tmp", shard_safe_prefix, shard_index);
            let shard_temp_path = shard_temp_dir.join(&shard_temp_name);
            if let Ok(()) = std::fs::write(&shard_temp_path, &data) {
                let shard_kind = super::ws_stream_transfer::StreamKind::Shard { shard_index };
                super::file_handler::stream_to_peer(
                    &ws_cmd_tx, &ws_room_peers,
                    webrtc_peers, pending_webrtc_sends, &event_tx,
                    &target_peer, &shard_kind,
                    &content_id, &shard_temp_path, data.len() as u64,
                ).await;
                hollow_log!("[HOLLOW-VAULT] Streaming shard si={shard_index} ({} bytes) to {target_peer}", data.len());
            }
        }
}

// ── 6. InitiateRecoveryPool ──────────────────────────────────────────

pub(crate) async fn handle_initiate_recovery_pool(
    recovery_pool_state: &mut Option<crate::node::recovery_pool::RecoveryPoolState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    local_peer_str: &str,
    server_id: String,
    token: String,
    db_path: &str,
    db_passphrase: &str,
) {
    let room_code = format!("recovery:{}:{}", server_id, token);
    hollow_log!("[RECOVERY-POOL] Initiating pool for server {} — room {}", server_id, room_code);

    // Join the WSS relay room for this recovery pool.
    let _ = ws_cmd_tx.send(crate::node::ws_client::WsCommand::JoinRoom {
        room_code: room_code.clone(),
    });

    // Build local shard inventory.
    let data_dir = crate::identity::data_dir().unwrap_or_default();
    let vault_dir = data_dir.join("vault");
    let inventory = if let Ok(cs) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) {
        crate::node::recovery_pool::build_local_inventory(&cs, &server_id)
    } else {
        crate::node::recovery_pool::MemberInventory::empty()
    };
    let invite_link = format!("hollow://recovery?server={}&token={}", server_id, token);

    // Initialize pool state.
    let mut pool = crate::node::recovery_pool::RecoveryPoolState::new(
        server_id.clone(),
        token.clone(),
        true,
        local_peer_str.to_string(),
        inventory,
    );
    // Populate manifest metadata for transfer plan computation.
    if let Ok(cs) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) {
        pool.populate_from_content_store(&cs);
    }
    *recovery_pool_state = Some(pool);

    let _ = event_tx.send(NetworkEvent::RecoveryPoolCreated {
        server_id,
        invite_link,
    }).await;
}

// ── 7. JoinRecoveryPool ──────────────────────────────────────────────

pub(crate) async fn handle_join_recovery_pool(
    recovery_pool_state: &mut Option<crate::node::recovery_pool::RecoveryPoolState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    local_peer_str: &str,
    server_id: String,
    token: String,
    db_path: &str,
    db_passphrase: &str,
) {
    let room_code = format!("recovery:{}:{}", server_id, token);
    hollow_log!("[RECOVERY-POOL] Joining pool for server {} — room {}", server_id, room_code);

    // Join the WSS relay room.
    let _ = ws_cmd_tx.send(crate::node::ws_client::WsCommand::JoinRoom {
        room_code: room_code.clone(),
    });

    // Build local inventory and send RecoveryHello.
    let data_dir = crate::identity::data_dir().unwrap_or_default();
    let vault_dir = data_dir.join("vault");
    let inventory = if let Ok(cs) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) {
        crate::node::recovery_pool::build_local_inventory(&cs, &server_id)
    } else {
        crate::node::recovery_pool::MemberInventory::empty()
    };

    let hello = HavenMessage::RecoveryHello {
        server_id: server_id.clone(),
        manifest_ids: inventory.manifest_ids.clone(),
        shard_inventory_json: serde_json::to_string(&inventory.shards).unwrap_or_default(),
    };
    if let Ok(hello_bytes) = serde_json::to_vec(&hello) {
        let _ = ws_cmd_tx.send(crate::node::ws_client::WsCommand::SendToRoom {
            room_code: room_code.clone(),
            data: hello_bytes,
        });
    }

    // Initialize pool state (not initiator).
    let mut pool = crate::node::recovery_pool::RecoveryPoolState::new(
        server_id.clone(),
        token.clone(),
        false,
        local_peer_str.to_string(),
        inventory,
    );
    if let Ok(cs) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) {
        pool.populate_from_content_store(&cs);
    }
    *recovery_pool_state = Some(pool);

    let _ = event_tx.send(NetworkEvent::RecoveryPoolJoined {
        server_id,
    }).await;
}

// ── 8. StopRecoveryPool ──────────────────────────────────────────────

pub(crate) async fn handle_stop_recovery_pool(
    recovery_pool_state: &mut Option<crate::node::recovery_pool::RecoveryPoolState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    server_id: String,
) {
    hollow_log!("[RECOVERY-POOL] Stopping pool for server {}", server_id);
    if let Some(pool) = recovery_pool_state.take() {
        let room_code = format!("recovery:{}:{}", pool.server_id, pool.token);
        // Broadcast stop message.
        if let Ok(stop_bytes) = serde_json::to_vec(&HavenMessage::RecoveryStop) {
            let _ = ws_cmd_tx.send(crate::node::ws_client::WsCommand::SendToRoom {
                room_code: room_code.clone(),
                data: stop_bytes,
            });
        }
        // Leave the room.
        let _ = ws_cmd_tx.send(crate::node::ws_client::WsCommand::LeaveRoom {
            room_code,
        });
    }
    let _ = event_tx.send(NetworkEvent::RecoveryPoolStopped {
        server_id,
    }).await;
}

/// Handle `MessageEnvelope::ShardStore` (MLS path).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_shard_store(
    server_states: &HashMap<String, ServerState>,
    pending_shard_streams: &mut HashMap<String, PendingShardStream>,
    olm: &mut OlmManager,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    sender_peer_id: String,
    sid: String,
    cid: String,
    si: u16,
    sk: String,
    k: u16,
    m: u16,
    total_size: u64,
    tier: String,
    data: String,
    chunks: u32,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-MLS-VAULT] ShardStore: cid={cid} si={si} from {sender_peer_id}");
    let is_member = server_states.get(&sid).map(|s| s.members.contains_key(&sender_peer_id)).unwrap_or(false);
    if !is_member { return; }
    if chunks == 0 && data.is_empty() {
        // Streamed shard — data arrives via binary WS stream.
        let key = format!("{cid}:{si}");
        pending_shard_streams.insert(key, PendingShardStream {
            server_id: sid, content_id: cid, shard_index: si,
            shard_key: sk, k, m, total_size, tier,
        });
    } else if chunks == 0 {
        // Inline shard — store directly.
        if let Ok(shard_bytes) = base64::engine::general_purpose::STANDARD.decode(&data) {
            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let vault_dir = data_dir.join("vault");
            if let Ok(cs) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) {
                let tier_enum = crate::vault::content_store::StorageTier::from_str(&tier);
                let _ = cs.store_shard(&sid, &cid, si, k, m, total_size, tier_enum, &shard_bytes);
            }
            let _ = event_tx.send(NetworkEvent::ShardStored {
                server_id: sid.clone(), content_id: cid.clone(),
                shard_index: si, from_peer: sender_peer_id.clone(),
            }).await;
            let ack = MessageEnvelope::ShardStoreAck {
                sid, cid, si, ok: true, err: None, target: None,
            };
            let ack_json = serde_json::to_string(&ack).unwrap_or_default();
            send_encrypted_message(
                olm, crypto_store, &sender_peer_id, &ack_json, event_tx,
                ws_cmd_tx, ws_room_peers,
            ).await;
        }
    }
}

/// Handle `MessageEnvelope::ShardChunk` (MLS path) — legacy no-op.
pub(crate) async fn handle_envelope_shard_chunk(sender_peer_id: &str) {
    hollow_log!("[HOLLOW-MLS-VAULT] ShardChunk via MLS from {sender_peer_id} — legacy, ignoring");
}

/// Handle `MessageEnvelope::ShardStoreAck` (MLS path).
pub(crate) async fn handle_envelope_shard_store_ack(
    event_tx: &mpsc::Sender<NetworkEvent>,
    sid: String,
    cid: String,
    si: u16,
    ok: bool,
    err: Option<String>,
) {
    if ok {
        hollow_log!("[HOLLOW-MLS-VAULT] ShardStoreAck OK: cid={cid} si={si}");
        let _ = event_tx.send(NetworkEvent::ShardStoreAckReceived {
            server_id: sid, content_id: cid, shard_index: si, success: true, error: String::new(),
        }).await;
    } else {
        hollow_log!("[HOLLOW-MLS-VAULT] ShardStoreAck FAILED: cid={cid} si={si} err={err:?}");
        let _ = event_tx.send(NetworkEvent::ShardStoreAckReceived {
            server_id: sid, content_id: cid, shard_index: si, success: false,
            error: err.unwrap_or_default(),
        }).await;
    }
}

/// Handle `MessageEnvelope::ShardDelete` (MLS path) — requires MANAGE_SERVER permission.
pub(crate) async fn handle_envelope_shard_delete(
    server_states: &HashMap<String, ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sender_peer_id: &str,
    sid: String,
    cid: String,
    db_path: &str,
    db_passphrase: &str,
) {
    let has_perm = server_states.get(&sid).map(|s| {
        let role = s.get_role(sender_peer_id);
        let perms = role.default_permissions();
        (perms & crate::crdt::operations::Permission::MANAGE_SERVER) != 0
    }).unwrap_or(false);
    if !has_perm { return; }
    let data_dir = crate::identity::data_dir().unwrap_or_default();
    let vault_dir = data_dir.join("vault");
    if let Ok(cs) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) {
        let _ = cs.delete_content(&sid, &cid);
    }
    let _ = event_tx.send(NetworkEvent::ShardDeleted {
        server_id: sid, content_id: cid,
    }).await;
}

/// Handle `MessageEnvelope::ShardRequest` (MLS path).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_shard_request(
    server_states: &HashMap<String, ServerState>,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    webrtc_peers: &std::collections::HashSet<String>,
    pending_webrtc_sends: &mut HashMap<String, (String, super::ws_stream_transfer::StreamKind, String, std::path::PathBuf, u64)>,
    server_id: &str,
    sender_peer_id: String,
    sid: String,
    cid: String,
    si: u16,
    sk: String,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-MLS-VAULT] ShardRequest: cid={cid} si={si} from {sender_peer_id}");
    let is_member = server_states.get(&sid).map(|s| s.members.contains_key(&sender_peer_id)).unwrap_or(false);
    if !is_member { return; }
    let data_dir = crate::identity::data_dir().unwrap_or_default();
    let vault_dir = data_dir.join("vault");
    if let Ok(cs) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) {
        match cs.read_shard_unchecked(&sid, &sk) {
            Ok(shard_data) => {
                let resp = MessageEnvelope::ShardResponse {
                    sid: sid.clone(), cid: cid.clone(), si,
                    data: String::new(), chunks: 0, found: true, target: None,
                };
                let resp_json = serde_json::to_string(&resp).unwrap_or_default();
                send_encrypted_message(olm, crypto_store, &sender_peer_id, &resp_json, event_tx, ws_cmd_tx, ws_room_peers).await;
                let shard_temp_dir = crate::node::file_transfer::files_dir();
                let shard_safe = &cid[..16.min(cid.len())];
                let shard_temp = shard_temp_dir.join(format!(".stream_shard_{}_{}.tmp", shard_safe, si));
                if std::fs::write(&shard_temp, &shard_data).is_ok() {
                    let shard_kind = super::ws_stream_transfer::StreamKind::Shard { shard_index: si };
                    file_handler::stream_to_peer(
                        ws_cmd_tx, ws_room_peers,
                        webrtc_peers, pending_webrtc_sends, event_tx,
                        &sender_peer_id, &shard_kind,
                        &cid, &shard_temp, shard_data.len() as u64,
                    ).await;
                }
            }
            Err(_) => {
                let resp = MessageEnvelope::ShardResponse {
                    sid, cid, si, data: String::new(), chunks: 0, found: false, target: None,
                };
                let resp_json = serde_json::to_string(&resp).unwrap_or_default();
                send_encrypted_message(olm, crypto_store, &sender_peer_id, &resp_json, event_tx, ws_cmd_tx, ws_room_peers).await;
            }
        }
    }
}

/// Handle `MessageEnvelope::ShardResponse` (MLS path).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_shard_response(
    pending_shard_streams: &mut HashMap<String, PendingShardStream>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sender_peer_id: String,
    sid: String,
    cid: String,
    si: u16,
    data: String,
    _chunks: u32,
    found: bool,
) {
    hollow_log!("[HOLLOW-MLS-VAULT] ShardResponse: cid={cid} si={si} found={found}");
    if found && data.is_empty() {
        let key = format!("{cid}:{si}");
        pending_shard_streams.insert(key, PendingShardStream {
            server_id: sid, content_id: cid, shard_index: si,
            shard_key: String::new(), k: 0, m: 0, total_size: 0, tier: String::new(),
        });
    } else if found {
        if let Ok(_shard_bytes) = base64::engine::general_purpose::STANDARD.decode(&data) {
            let _ = event_tx.send(NetworkEvent::ShardReceived {
                server_id: sid, content_id: cid, shard_index: si,
                from_peer: sender_peer_id,
            }).await;
        }
    }
}

/// Handle `MessageEnvelope::ShardResponseChunk` (MLS path) — legacy no-op.
pub(crate) async fn handle_envelope_shard_response_chunk() {
    hollow_log!("[HOLLOW-MLS-VAULT] ShardResponseChunk via MLS — legacy, ignoring");
}

/// Handle `MessageEnvelope::ShardProbe` (MLS path).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_shard_probe(
    server_states: &HashMap<String, ServerState>,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    sender_peer_id: String,
    sid: String,
    cid: String,
    db_path: &str,
    db_passphrase: &str,
) {
    let is_member = server_states.get(&sid).map(|s| s.members.contains_key(&sender_peer_id)).unwrap_or(false);
    if !is_member { return; }
    let data_dir = crate::identity::data_dir().unwrap_or_default();
    let vault_dir = data_dir.join("vault");
    let mut indices = Vec::new();
    if let Ok(cs) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) {
        if let Ok(records) = cs.list_content_shards(&sid, &cid) {
            indices = records.iter().map(|r| r.shard_index).collect();
        }
    }
    let resp = MessageEnvelope::ShardProbeResponse {
        sid: sid.clone(), cid, shards: indices, target: None,
    };
    let resp_json = serde_json::to_string(&resp).unwrap_or_default();
    send_encrypted_message(olm, crypto_store, &sender_peer_id, &resp_json, event_tx, ws_cmd_tx, ws_room_peers).await;
}

/// Handle `MessageEnvelope::ShardProbeResponse` (MLS path) — informational log only.
pub(crate) async fn handle_envelope_shard_probe_response(
    sender_peer_id: &str,
    _sid: String,
    cid: String,
    shards: Vec<u16>,
) {
    hollow_log!("[HOLLOW-MLS-VAULT] ShardProbeResponse: cid={cid} shards={shards:?} from {sender_peer_id}");
}

/// Handle `MessageEnvelope::VaultManifestBroadcast` (MLS path).
pub(crate) async fn handle_envelope_vault_manifest_broadcast(
    sid: String,
    _cid: String,
    chid: String,
    manifest: String,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-MLS-VAULT] VaultManifestBroadcast: cid={_cid} in {chid}");
    if let Ok(manifest_obj) = serde_json::from_str::<crate::vault::pipeline::VaultManifest>(&manifest) {
        let data_dir = crate::identity::data_dir().unwrap_or_default();
        let vault_dir = data_dir.join("vault");
        if let Ok(cs) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) {
            let _ = cs.save_manifest(&sid, &chid, &manifest_obj);
        }
        if !manifest_obj.message_id.is_empty() {
            if let Ok(ms) = crate::storage::MessageStore::open(db_path, db_passphrase) {
                let _ = ms.set_file_content_id(&manifest_obj.message_id, &manifest_obj.content_id);
            }
        }
    }
}

/// Handle `MessageEnvelope::ShardMigrate` (MLS path).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_shard_migrate(
    server_states: &HashMap<String, ServerState>,
    sender_peer_id: &str,
    sid: String,
    cid: String,
    si: u16,
    _sk: String,
    data: String,
    db_path: &str,
    db_passphrase: &str,
) {
    let is_member = server_states.get(&sid).map(|s| s.members.contains_key(sender_peer_id)).unwrap_or(false);
    if !is_member { return; }
    if let Ok(shard_bytes) = base64::engine::general_purpose::STANDARD.decode(&data) {
        let data_dir = crate::identity::data_dir().unwrap_or_default();
        let vault_dir = data_dir.join("vault");
        if let Ok(cs) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) {
            let tier = crate::vault::content_store::StorageTier::Standard;
            let _ = cs.store_shard(&sid, &cid, si, 0, 0, 0, tier, &shard_bytes);
        }
    }
}
