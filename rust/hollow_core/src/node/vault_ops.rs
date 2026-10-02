use std::collections::HashMap;

use tokio::sync::mpsc;

use crate::crdt::server_state::ServerState;
use crate::crypto::{CryptoStore, MlsManager, OlmManager};
use super::crypto_handler::{
    peer_is_reachable, preferred_online_device, send_mls_broadcast, send_encrypted_message,
};
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
                vault_bytes_checked(&content_id, &plaintext, db_path, db_passphrase)?;
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
                vault_bytes_checked(&content_id, &plaintext, db_path, db_passphrase)?;
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
                            // Placements are MASTER-keyed (server members), so
                            // resolve to a concrete online DEVICE: an Olm send to a
                            // bare master has no session or socket.
                            if let Some(dev) = preferred_online_device(&ws_room_peers, target_peer) {
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
                                    &dev, &json, &event_tx,
                                    &ws_cmd_tx, &ws_room_peers,
                                ).await;
                                hollow_log!("[HOLLOW-VAULT] Requested shard si={si} from {target_peer} (device {dev})");
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
    server_states: &HashMap<String, crate::crdt::server_state::ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    cmd_tx: &mpsc::Sender<super::types::NodeCommand>,
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

    // Snapshot membership and pledges on the loop, then hop the Reed-Solomon encode
    // (up to 34MB of CPU) and the shard disk writes onto the blocking pool: this
    // used to freeze the event loop for the largest CPU+disk unit in the codebase.
    let Some(state) = server_states.get(&server_id) else {
        let _ = event_tx.send(NetworkEvent::VaultUploadFailed {
            server_id: server_id.clone(), content_id,
            error: format!("Server {server_id} not found"),
        }).await;
        return;
    };
    // A restricted channel's file never enters the vault: the manifest (and so the
    // key) goes to the whole server, and shards to every member.
    if state.channel_uses_subgroup(&channel_id) {
        let _ = event_tx.send(NetworkEvent::VaultUploadFailed {
            server_id: server_id.clone(), content_id,
            error: "Files in a restricted channel are not stored in the vault".into(),
        }).await;
        return;
    }
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
    let fallback_info = if use_fallback {
        if let crate::vault::adaptive::VaultMode::ErasureCoding { k, m } = &mode {
            Some((online_members.len(), *k + *m))
        } else { None }
    } else { None };
    let members = if use_fallback {
        hollow_log!("[HOLLOW-VAULT] Upload guard: {} online < k+m for {} total members — falling back to replication", online_members.len(), all_members.len());
        online_members
    } else {
        all_members
    };

    let key: [u8; 32] = match aes_key.try_into() {
        Ok(k) => k,
        Err(_) => {
            let _ = event_tx.send(NetworkEvent::VaultUploadFailed {
                server_id, content_id, error: "Invalid AES key length".into(),
            }).await;
            return;
        }
    };
    let nonce: [u8; 12] = match aes_nonce.try_into() {
        Ok(n) => n,
        Err(_) => {
            let _ = event_tx.send(NetworkEvent::VaultUploadFailed {
                server_id, content_id, error: "Invalid AES nonce length".into(),
            }).await;
            return;
        }
    };

    let cmd_tx = cmd_tx.clone();
    let event_tx = event_tx.clone();
    let db_path = db_path.to_string();
    let db_passphrase = db_passphrase.to_string();
    tokio::spawn(async move {
        let sid = server_id.clone();
        let cid = content_id.clone();
        let chid = channel_id.clone();
        let mid = message_id.clone();
        let prepared = tokio::task::spawn_blocking(move || -> Result<crate::vault::pipeline::UploadPlan, String> {
            // Prepare upload plan (single call — reused for both local storage
            // and remote distribution).
            let plan = crate::vault::pipeline::prepare_upload(
                &ciphertext, &content_id, &key, &nonce,
                &file_name, &mime_type, &channel_id,
                original_size, &local_peer,
                &members, &pledges, &message_id,
            )?;

            // Open ContentStore for local operations
            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let vault_dir = data_dir.join("vault");
            let cs = crate::vault::content_store::ContentStore::open(&db_path, &db_passphrase, &vault_dir)?;

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

            Ok(plan)
        })
        .await
        .map_err(|e| format!("Vault prepare task panicked: {e}"))
        .and_then(|r| r);

        match prepared {
            Err(e) => {
                hollow_log!("[HOLLOW-VAULT] Upload failed: {e}");
                let _ = event_tx.send(NetworkEvent::VaultUploadFailed {
                    server_id: sid, content_id: cid, error: e,
                }).await;
            }
            Ok(plan) => {
                let _ = cmd_tx.send(super::types::NodeCommand::VaultUploadPrepared(Box::new(
                    super::types::VaultUploadPreparedPayload {
                        server_id: sid, channel_id: chid, content_id: cid,
                        message_id: mid, plan, fallback_info,
                    },
                ))).await;
            }
        }
    });
}

/// Resume a vault upload after off-loop erasure coding: shard distribution,
/// manifest broadcast, file-record link, completion event.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_vault_upload_prepared(
    server_states: &HashMap<String, crate::crdt::server_state::ServerState>,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    webrtc_peers: &std::collections::HashSet<String>,
    pending_webrtc_sends: &mut HashMap<String, (String, super::ws_stream_transfer::StreamKind, String, std::path::PathBuf, u64)>,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    content_id: String,
    message_id: String,
    plan: crate::vault::pipeline::UploadPlan,
    fallback_info: Option<(usize, usize)>,
    db_path: &str,
    db_passphrase: &str,
) {
    {
        {
            // Emit replication fallback event if upload guard triggered.
            if let Some((online, needed)) = fallback_info {
                let _ = event_tx.send(NetworkEvent::VaultUploadReplicationFallback {
                    server_id: server_id.clone(), content_id: content_id.clone(),
                    online, needed,
                }).await;
            }
            // Distribute remote shards using the plan from the single prepare_upload() call.
            let local_peer = local_peer_str.to_string();
            for placement in &plan.placements {
                if placement.target_peer != local_peer {
                    if let Some((_, shard_data)) = plan.shards.iter().find(|(idx, _)| *idx == placement.shard_index) {
                            // The placement records the MASTER, but delivery goes
                            // to ONE concrete online device of it: the metadata Olm
                            // send and the byte stream must hit the SAME socket. A
                            // device without the shard replies found:false.
                            if let Some(dev) = preferred_online_device(&ws_room_peers, &placement.target_peer) {
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
                                    &dev, &json, &event_tx,
                                    &ws_cmd_tx, &ws_room_peers,
                                ).await;

                                // Stream shard bytes directly from memory (no temp file for WS path).
                                let shard_kind = super::ws_stream_transfer::StreamKind::Shard { shard_index: placement.shard_index };
                                super::file_handler::stream_to_peer_bytes(
                                    &ws_cmd_tx, &ws_room_peers,
                                    webrtc_peers, pending_webrtc_sends, &event_tx,
                                    &dev, &shard_kind,
                                    &content_id, shard_data,
                                ).await;
                                hollow_log!("[HOLLOW-VAULT] Streaming shard si={} ({} bytes) to {} (device {})", placement.shard_index, shard_data.len(), placement.target_peer, dev);
                            }
                    }
                }
            }

            // Broadcast manifest via MLS (or Olm fallback).
            if let Some(state) = server_states.get(&server_id) {
                let manifest_json = serde_json::to_string(&plan.manifest).unwrap_or_default();
                let manifest_envelope = MessageEnvelope::VaultManifestBroadcast {
                    sid: server_id.clone(),
                    cid: content_id.clone(),
                    chid: channel_id.clone(),
                    manifest: manifest_json,
                };
                // MLS to the group when we hold it, PLUS the Olm copy to exactly
                // the online member devices that hold no leaf in it. Measuring OUR
                // own encrypt says nothing about the receiver's ability to decrypt,
                // and a leaf-less member never learned the manifest existed. Never
                // a plaintext fallback here: the manifest is encrypted content.
                let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
                if mls_ok
                    && let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), &ws_cmd_tx, &server_id, &manifest_envelope, crypto_store)
                {
                    hollow_log!("[HOLLOW-MLS] VaultManifest broadcast failed: {e}");
                }
                let leafless = super::crypto_handler::leafless_member_devices(
                    mls, &server_id, state, &ws_room_peers, &local_peer,
                );
                if !leafless.is_empty() {
                    let manifest_env_json = serde_json::to_string(&manifest_envelope).unwrap_or_default();
                    // Olm is per-device: send to each leaf-less online device.
                    for dev in &leafless {
                        if olm.has_session(dev) {
                            send_encrypted_message(
                                &mut *olm, crypto_store,
                                dev, &manifest_env_json, &event_tx,
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
            let _ = cs.delete_placements(&server_id, &content_id);
        }

        // Broadcast ShardDelete to connected server members
        let delete_envelope = MessageEnvelope::ShardDelete {
            sid: server_id.clone(),
            cid: content_id.clone(),
        };
        // MLS to the group when we hold it, PLUS the Olm copy to exactly the online
        // member devices that hold no leaf in it. Same complement rule as the
        // manifest broadcast: a leaf-less member keeping a shard we just deleted
        // would hold it forever. Never a plaintext fallback: encrypted content.
        let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
        if mls_ok
            && let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), &ws_cmd_tx, &server_id, &delete_envelope, crypto_store)
        {
            hollow_log!("[HOLLOW-MLS] ShardDelete broadcast failed: {e}");
        }
        let leafless = super::crypto_handler::leafless_member_devices(
            mls, &server_id, state, &ws_room_peers, &local_peer,
        );
        if !leafless.is_empty() {
            let delete_json = serde_json::to_string(&delete_envelope).unwrap_or_default();
            for dev in &leafless {
                if olm.has_session(dev) {
                    send_encrypted_message(
                        &mut *olm, crypto_store,
                        dev, &delete_json, &event_tx,
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
        // MASTER-keyed placement target → concrete online device (Olm sessions and
        // sockets are per-DEVICE; the bare master has neither).
        match preferred_online_device(&ws_room_peers, &target_peer) {
            None => {
                hollow_log!("[HOLLOW-VAULT] Cannot request shard: peer {target_peer} not reachable");
                let _ = event_tx.send(NetworkEvent::ShardRequestFailed {
                    server_id, content_id, shard_index,
                    error: "Peer not reachable".into(),
                }).await;
            }
            Some(dev) => {
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
                    &dev, &json, &event_tx,
                    &ws_cmd_tx, &ws_room_peers,
                ).await;
            }
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

        // MASTER-keyed target → one concrete online device; metadata + byte
        // stream must hit the SAME socket.
        match preferred_online_device(&ws_room_peers, &target_peer) {
            None => {
                hollow_log!("[HOLLOW-VAULT] Cannot store shard: peer {target_peer} not reachable");
                let _ = event_tx.send(NetworkEvent::ShardStoreFailed {
                    server_id: server_id.clone(),
                    content_id: content_id.clone(),
                    shard_index,
                    target_peer: target_peer.clone(),
                    error: "Peer not reachable".into(),
                }).await;
            }
            Some(dev) => {
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
                    &dev, &json, &event_tx,
                    &ws_cmd_tx, &ws_room_peers,
                ).await;

                // Stream shard bytes directly from memory.
                let shard_kind = super::ws_stream_transfer::StreamKind::Shard { shard_index };
                super::file_handler::stream_to_peer_bytes(
                    &ws_cmd_tx, &ws_room_peers,
                    webrtc_peers, pending_webrtc_sends, &event_tx,
                    &dev, &shard_kind,
                    &content_id, &data,
                ).await;
                hollow_log!("[HOLLOW-VAULT] Streaming shard si={shard_index} ({} bytes) to {target_peer} (device {dev})", data.len());
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
    let room_code = crate::node::recovery_pool::pool_room(&server_id, &token);
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
    device_peer_id: &str,
    server_id: String,
    token: String,
    db_path: &str,
    db_passphrase: &str,
) {
    let room_code = crate::node::recovery_pool::pool_room(&server_id, &token);
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
    if let Some(hello_bytes) = crate::node::recovery_pool::seal_control(&server_id, &token, device_peer_id, &hello) {
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
    device_peer_id: &str,
    server_id: String,
) {
    hollow_log!("[RECOVERY-POOL] Stopping pool for server {}", server_id);
    if let Some(pool) = recovery_pool_state.take() {
        let room_code = pool.room_code();
        // Broadcast stop message.
        if let Some(stop_bytes) = pool.seal(device_peer_id, &HavenMessage::RecoveryStop) {
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

/// Why a peer may not put shard `si` of `cid` for `sid` on our disk, `None` when it
/// may: the ONE gate for every shard write (store, response, migrate). A shard's
/// bytes never change once held, so a second writer is refused outright, and the
/// file rebuilt from shards is checked against its content id anyway.
#[allow(clippy::too_many_arguments)]
pub(crate) fn shard_write_refused(
    server_states: &HashMap<String, ServerState>,
    cs: &crate::vault::content_store::ContentStore,
    sender: &str,
    sid: &str,
    cid: &str,
    si: u16,
    local_peer: &str,
    incoming_bytes: u64,
) -> Option<&'static str> {
    let Some(state) = server_states.get(sid).filter(|s| s.is_member(sender)) else {
        return Some("not a member of the server");
    };
    if cs.has_shard(&crate::vault::content_store::shard_key(cid, si)).unwrap_or(true) {
        return Some("that shard is already held");
    }
    let pledge = state.get_storage_pledge(local_peer);
    let used = cs.total_storage_used(sid).unwrap_or(0);
    if pledge > 0 && used.saturating_add(incoming_bytes) > pledge {
        return Some("our storage pledge for the server is full");
    }
    None
}

/// Why `requester` may not pull a shard of `cid` in `sid`, `None` when it may. When
/// we hold the manifest, serving follows the channel the file was posted in.
pub(crate) fn shard_serve_refused(
    server_states: &HashMap<String, ServerState>,
    cs: &crate::vault::content_store::ContentStore,
    requester: &str,
    sid: &str,
    cid: &str,
) -> Option<&'static str> {
    let Some(state) = server_states.get(sid).filter(|s| s.is_member(requester)) else {
        return Some("not a member of the server");
    };
    match cs.manifest_home(cid) {
        Ok(Some((home, _, _))) if home != sid => Some("the content belongs to another server"),
        Ok(Some((_, channel_id, _)))
            if !super::crypto_handler::channel_readable_by(state, requester, &channel_id) =>
        {
            Some("cannot read the channel the file was posted in")
        }
        _ => None,
    }
}

/// A peer's order to delete vault content: only a member holding Manage Server in the
/// server named, and it reaches only that server's shards and placements.
pub(crate) async fn handle_shard_delete(
    server_states: &HashMap<String, ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sender_peer_id: &str,
    sid: String,
    cid: String,
    db_path: &str,
    db_passphrase: &str,
) {
    let allowed = server_states.get(&sid).is_some_and(|s| {
        s.is_member(sender_peer_id)
            && s.has_permission(sender_peer_id, crate::crdt::operations::Permission::MANAGE_SERVER)
    });
    if !allowed {
        hollow_log!("[HOLLOW-SECURITY] REJECTED ShardDelete for {cid} from {sender_peer_id}: no Manage Server in {sid}");
        return;
    }
    let vault_dir = crate::identity::data_dir().unwrap_or_default().join("vault");
    if let Ok(cs) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) {
        let _ = cs.delete_content(&sid, &cid);
        let _ = cs.delete_placements(&sid, &cid);
    }
    hollow_log!("[HOLLOW-VAULT] Shard content deleted: cid={cid}");
    let _ = event_tx.send(NetworkEvent::ShardDeleted {
        server_id: sid, content_id: cid,
    }).await;
}

/// `Err` when a reconstructed vault file is not the one its cards commit to.
fn vault_bytes_checked(content_id: &str, plaintext: &[u8], db_path: &str, db_passphrase: &str) -> Result<(), String> {
    let store = crate::storage::MessageStore::open(db_path, db_passphrase)?;
    match super::file_commit::vault_plaintext_refused(&store, content_id, plaintext) {
        Some(reason) => {
            hollow_log!("[HOLLOW-SECURITY] REFUSED vault content {content_id}: {reason}");
            Err(super::file_handler::FORGED_FILE_ERROR.to_string())
        }
        None => Ok(()),
    }
}

/// A vault manifest from a peer. It carries the file's key and names the message
/// whose card it backs, so it lands only from the member who created it, never over
/// another creator's manifest, and relinks only that creator's own file card.
pub(crate) fn ingest_vault_manifest(
    server_states: &HashMap<String, ServerState>,
    sender_peer_id: &str,
    sid: &str,
    chid: &str,
    manifest: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    let Ok(manifest) = serde_json::from_str::<crate::vault::pipeline::VaultManifest>(manifest) else {
        return;
    };
    let creator = super::resolver::resolve(&manifest.creator_peer_id);
    let refusal = if !server_states.get(sid).is_some_and(|s| s.is_member(sender_peer_id)) {
        Some("not a member of the server")
    } else if super::resolver::resolve(sender_peer_id) != creator {
        Some("the manifest names another creator")
    } else if manifest.channel_id != chid || !crate::vault::content_store::is_content_id(&manifest.content_id) {
        Some("malformed manifest")
    } else {
        None
    };
    if let Some(reason) = refusal {
        hollow_log!("[HOLLOW-SECURITY] REJECTED vault manifest {} from {sender_peer_id}: {reason}", manifest.content_id);
        return;
    }
    let vault_dir = crate::identity::data_dir().unwrap_or_default().join("vault");
    let Ok(cs) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) else {
        return;
    };
    if let Ok(Some((home, _, existing))) = cs.manifest_home(&manifest.content_id) {
        if home != sid || super::resolver::resolve(&existing) != creator {
            hollow_log!("[HOLLOW-SECURITY] REJECTED vault manifest {} from {sender_peer_id}: it is another creator's", manifest.content_id);
            return;
        }
    }
    let _ = cs.save_manifest(sid, chid, &manifest);
    if manifest.message_id.is_empty() {
        return;
    }
    if let Ok(ms) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let cards = ms.file_senders_for_message(&manifest.message_id).unwrap_or_default();
        if cards.iter().all(|sender| super::resolver::resolve(sender) == creator) {
            let _ = ms.set_file_content_id(&manifest.message_id, &manifest.content_id);
        } else {
            hollow_log!("[HOLLOW-SECURITY] REJECTED vault relink of {} from {sender_peer_id}: not its file card", manifest.message_id);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crdt::operations::CrdtPayload;
    use crate::crdt::testkeys::{keys, owned_state};
    use crate::vault::content_store::{ContentStore, StorageTier};

    /// Server "srv" owned by tag 1 (the local node), with `members` added.
    fn server_with(members: &[&str], local_pledge: u64) -> (HashMap<String, ServerState>, String) {
        let (mut state, owner) = owned_state("srv", "S", 1);
        let mut ops = vec![CrdtPayload::StoragePledgeChanged { peer_id: owner.clone(), pledge_bytes: local_pledge }];
        ops.extend(members.iter().map(|id| CrdtPayload::MemberAdded {
            peer_id: id.to_string(),
            display_name: "m".into(),
            follow: None,
            ask: None,
        }));
        for payload in ops {
            let op = state.create_op(payload);
            state.apply_op(&op).unwrap();
        }
        (HashMap::from([("srv".to_string(), state)]), owner)
    }

    fn temp_db() -> (tempfile::TempDir, String, String) {
        let tmp = tempfile::tempdir().unwrap();
        let db = tmp.path().join("vault.db").to_string_lossy().into_owned();
        (tmp, db, "ab".repeat(32))
    }

    /// H11, H14, V1-2: a shard lands only from a member of its server, only while we
    /// do not hold it, and only inside our pledge. A second writer used to replace
    /// the bytes (and their recorded hash) of any shard we held.
    #[test]
    fn authz_shard_write_needs_a_member_and_a_shard_we_lack() {
        let _g = super::super::resolver::test_lock();
        let (tmp, db, pass) = temp_db();
        let cs = ContentStore::open(&db, &pass, &tmp.path().join("vault")).unwrap();
        let (bob, stranger) = (keys(2).1, keys(3).1);
        let (states, local) = server_with(&[&bob], 64);
        let refused = |who: &str, sid: &str, si: u16, bytes: u64| {
            shard_write_refused(&states, &cs, who, sid, "cid-1", si, &local, bytes)
        };
        assert_eq!(refused(&stranger, "srv", 0, 8), Some("not a member of the server"));
        assert_eq!(refused(&bob, "other-srv", 0, 8), Some("not a member of the server"));
        assert_eq!(refused(&bob, "srv", 0, 8), None);
        cs.store_shard("srv", "cid-1", 0, 0, 0, 8, StorageTier::Standard, b"realbyte").unwrap();
        assert_eq!(refused(&bob, "srv", 0, 8), Some("that shard is already held"));
        assert_eq!(refused(&bob, "srv", 1, 60), Some("our storage pledge for the server is full"));
        assert_eq!(refused(&bob, "srv", 1, 8), None);
    }

    /// H13: a restricted channel's file never enters the vault, whose manifest (and
    /// so the key) goes to the whole server.
    #[tokio::test]
    async fn authz_restricted_channel_file_never_enters_the_vault() {
        let _g = super::super::resolver::test_lock();
        let (mut states, local) = server_with(&[], 0);
        let state = states.get_mut("srv").unwrap();
        let op = state.create_op(CrdtPayload::ChannelVisibilityChanged {
            channel_id: "srv-general".into(),
            visibility: "admin".into(),
        });
        state.apply_op(&op).unwrap();
        let (tx, mut rx) = mpsc::channel(8);
        let (cmd_tx, mut cmd_rx) = mpsc::channel(8);
        handle_vault_upload_file(
            &states, &tx, &HashMap::new(), &cmd_tx, &local,
            "srv".into(), "srv-general".into(), "a.txt".into(), "text/plain".into(), "m1".into(),
            vec![1, 2, 3], vec![0; 32], vec![0; 12], 3, "c".repeat(64), "unused.db", "00",
        ).await;
        assert!(
            matches!(rx.try_recv(), Ok(NetworkEvent::VaultUploadFailed { .. })),
            "a restricted channel's file was taken into the vault",
        );
        tokio::task::yield_now().await;
        assert!(cmd_rx.try_recv().is_err(), "the upload went ahead anyway");
    }

    /// Every vault arm runs its gate; the unit tests above drive only the gates.
    #[test]
    fn vault_gates_stay_wired() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/node/swarm.rs");
        let swarm = std::fs::read_to_string(path).expect("read swarm.rs");
        let arm = |from: &str| {
            let start = swarm.find(from).unwrap_or_else(|| panic!("missing {from}"));
            let end = swarm[start + from.len()..].find("Ok(MessageEnvelope::").map_or(swarm.len(), |e| start + from.len() + e);
            swarm[start..end].to_string()
        };
        for (from, gate) in [
            ("Ok(MessageEnvelope::ShardStore { inner }) => {", "vault_ops::shard_write_refused("),
            ("Ok(MessageEnvelope::ShardResponse {", "vault_ops::shard_write_refused("),
            ("Ok(MessageEnvelope::ShardMigrate {", "vault_ops::shard_write_refused("),
            ("Ok(MessageEnvelope::ShardRequest {", "vault_ops::shard_serve_refused("),
            ("Ok(MessageEnvelope::ShardStoreAck {", "placement_target("),
            ("Ok(MessageEnvelope::ShardDelete {", "vault_ops::handle_shard_delete("),
            ("Ok(MessageEnvelope::VaultManifestBroadcast {", "vault_ops::ingest_vault_manifest("),
        ] {
            assert!(arm(from).contains(gate), "swarm.rs: the Olm arm {from} skips {gate}");
        }
        let mls = &swarm[swarm.find("// -- Vault envelopes via MLS --").expect("the MLS vault arms")..];
        let mls = &mls[..mls.find("// -- Voice channel signaling --").expect("end of the MLS vault arms")];
        assert!(mls.contains("vault_ops::handle_shard_delete(") && mls.contains("vault_ops::ingest_vault_manifest("));
        assert!(!mls.contains("store_shard(") && !mls.contains("pending_shard_streams"), "an MLS arm writes shards again");
    }

    /// H15: a manifest carries the file's key and names the card it backs, so it lands
    /// only from the member it names as creator, never over another creator's, and
    /// relinks only that creator's own card.
    #[test]
    fn authz_vault_manifest_lands_only_from_its_creator() {
        let _g = super::super::resolver::test_lock();
        let (_tmp, db, pass) = temp_db();
        let (bob, mallory) = (keys(2).1, keys(3).1);
        let (states, _) = server_with(&[&bob, &mallory], 0);
        let manifest = |cid: &str, creator: &str, mid: &str| {
            serde_json::to_string(&crate::vault::pipeline::VaultManifest {
                content_id: cid.to_string(),
                encryption_key: "00".repeat(32),
                nonce: "00".repeat(12),
                original_size: 4,
                k: 0,
                m: 0,
                shard_count: 0,
                file_name: "a.png".into(),
                mime_type: "image/png".into(),
                storage_tier: "standard".into(),
                created_at: 1,
                creator_peer_id: creator.to_string(),
                channel_id: "srv-general".into(),
                message_id: mid.to_string(),
            })
            .unwrap()
        };
        let store = || crate::storage::MessageStore::open(&db, &pass).unwrap();
        store().insert_file_metadata(
            "f-bob", "a.png", "png", "image/png", 4, 0, true, None, None, Some("m-bob"),
            "channel", "srv:srv-general", &bob, false, 1, None, None, None,
        ).unwrap();
        let home = |cid: &str| {
            ContentStore::open(&db, &pass, std::path::Path::new("unused")).unwrap().manifest_home(cid).unwrap()
        };
        let (bob_cid, evil_cid) = ("b".repeat(64), "e".repeat(64));

        ingest_vault_manifest(&states, &mallory, "srv", "srv-general", &manifest(&bob_cid, &bob, "m-bob"), &db, &pass);
        assert_eq!(home(&bob_cid), None, "a manifest naming another creator");
        ingest_vault_manifest(&states, &bob, "srv", "srv-general", &manifest(&bob_cid, &bob, "m-bob"), &db, &pass);
        assert_eq!(home(&bob_cid).map(|h| h.2), Some(bob.clone()));
        assert_eq!(store().get_content_id_for_file("f-bob").unwrap(), Some(bob_cid.clone()));

        ingest_vault_manifest(&states, &mallory, "srv", "srv-general", &manifest(&bob_cid, &mallory, ""), &db, &pass);
        assert_eq!(home(&bob_cid).map(|h| h.2), Some(bob.clone()), "another creator's manifest replaced");
        ingest_vault_manifest(&states, &mallory, "srv", "srv-general", &manifest(&evil_cid, &mallory, "m-bob"), &db, &pass);
        assert_eq!(store().get_content_id_for_file("f-bob").unwrap(), Some(bob_cid.clone()), "Bob's card relinked");
        ingest_vault_manifest(&states, &mallory, "srv", "srv-general", &manifest("..\\..\\x", &mallory, ""), &db, &pass);
        assert_eq!(home("..\\..\\x"), None, "a content id that is not a hash");
    }
}
