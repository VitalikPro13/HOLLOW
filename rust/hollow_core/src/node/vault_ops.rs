use std::collections::HashMap;

use tokio::sync::mpsc;

use crate::crdt::server_state::ServerState;
use crate::crypto::{CryptoStore, MlsManager, OlmManager};
use super::crypto_handler::{
    peer_is_reachable, preferred_online_device, send_mls_broadcast, send_encrypted_message,
};
use super::types::*;

// ── 1. VaultDownloadFile ─────────────────────────────────────────────

/// What our own store can do for a download.
enum LocalShards {
    /// The file is in the cache now, at this path.
    Done(String),
    /// `have` of the `need` shards a rebuild takes; each missing index with its holders
    /// (placement identity, shard key).
    Need { have: usize, need: usize, missing: Vec<(u16, Vec<(String, String)>)> },
}

/// Rebuild `content_id` from the shards we hold, or say which to pull and from whom.
/// `local` is our master id, the identity placements name.
fn local_shards(
    server_states: &HashMap<String, ServerState>,
    vault_dir: &std::path::Path,
    server_id: &str,
    content_id: &str,
    local: &str,
    db_path: &str,
    db_passphrase: &str,
) -> Result<LocalShards, String> {
    let cs = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, vault_dir)?;
    let manifest = cs.load_manifest(content_id)?
        .ok_or_else(|| format!("Manifest not found for {content_id}"))?;
    let ext = crate::vault::pipeline::ext_from_filename(&manifest.file_name);
    if let Some(cached_path) = crate::vault::pipeline::check_cache(content_id, &ext) {
        return Ok(LocalShards::Done(cached_path.to_string_lossy().to_string()));
    }

    // Non-uploaders hold no placements: recompute them as the uploader did.
    let mut placements = cs.load_placements(content_id).unwrap_or_default();
    if placements.is_empty() && let Some(state) = server_states.get(server_id) {
        let members: Vec<String> = state.members_list().iter().map(|m| m.peer_id.clone()).collect();
        let pledges: std::collections::HashMap<String, u64> = members.iter()
            .map(|pid| (pid.clone(), state.get_storage_pledge(pid)))
            .collect();
        let mode = crate::vault::adaptive::compute_adaptive_params(members.len());
        let computed = crate::vault::placement::place(content_id, &mode, &members, &pledges);
        placements = computed.iter().map(|sp| crate::vault::content_store::PlacementRecord {
            content_id: content_id.to_string(),
            shard_index: sp.shard_index,
            target_peer: sp.target_peer.clone(),
            server_id: server_id.to_string(),
            shard_key: sp.shard_key.clone(),
            stored_at: 0,
            confirmed: false,
        }).collect();
    }

    // Replication keeps the whole ciphertext as shard 0, so one copy rebuilds it.
    let need = (manifest.k as usize).max(1);
    let (mut packed, _) = gather_vault_shards(&cs, &manifest);
    if packed.iter().flatten().count() >= need {
        match crate::vault::pipeline::reconstruct_file(&manifest, &packed) {
            Ok(plaintext) => {
                vault_bytes_checked(content_id, &plaintext, db_path, db_passphrase)?;
                let path = crate::vault::pipeline::write_to_cache(content_id, &ext, &plaintext)?;
                return Ok(LocalShards::Done(path.to_string_lossy().to_string()));
            }
            Err(e) => {
                let ours: std::collections::HashSet<u16> = placements.iter()
                    .filter(|p| super::resolver::resolve(&p.target_peer) == local)
                    .map(|p| p.shard_index)
                    .collect();
                if drop_unpinned_shards(&cs, &manifest, &packed, &ours) == 0 {
                    return Err(e);
                }
                hollow_log!("[HOLLOW-VAULT] Rebuild of {content_id} failed ({e}): pulling its shards again");
                packed = gather_vault_shards(&cs, &manifest).0;
            }
        }
    }
    let missing = (0..packed.len())
        .filter(|idx| packed[*idx].is_none())
        .map(|idx| {
            let holders = placements.iter()
                .filter(|p| p.shard_index as usize == idx)
                .map(|p| (p.target_peer.clone(), p.shard_key.clone()))
                .collect();
            (idx as u16, holders)
        })
        .collect();
    Ok(LocalShards::Need { have: packed.iter().flatten().count(), need, missing })
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_vault_download_file(
    server_states: &mut HashMap<String, crate::crdt::server_state::ServerState>,
    pending_vault_downloads: &mut HashMap<String, (String, usize, usize)>,
    vault_shard_asks: &mut ShardAsks,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    server_id: String,
    content_id: String,
    // The person asked, so the download gets a fresh budget of pulls of its own.
    user_asked: bool,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-VAULT] VaultDownloadFile: cid={content_id} in {server_id}");
    if user_asked && let Some(book) = vault_shard_asks.pulls.get_mut(&content_id) {
        book.repulls = 0;
    }

    let vault_dir = crate::identity::data_dir().unwrap_or_default().join("vault");
    match local_shards(server_states, &vault_dir, &server_id, &content_id, &bundle_keypair.peer_id(), db_path, db_passphrase) {
        Ok(LocalShards::Done(disk_path)) => {
            hollow_log!("[HOLLOW-VAULT] Download complete: {disk_path}");
            let _ = event_tx.send(NetworkEvent::VaultDownloadComplete {
                server_id, content_id, disk_path,
            }).await;
        }
        Ok(LocalShards::Need { have, need, missing }) => {
            let mut requested = 0usize;
            for (si, holders) in &missing {
                if have + requested >= need { break; }
                // Placements are MASTER-keyed: ask one concrete online DEVICE of the
                // first holder that never answered this content with a wrong shard.
                let holder = holders.iter()
                    .filter(|(peer, _)| !holder_refuted(vault_shard_asks, &content_id, peer))
                    .find_map(|(peer, sk)| preferred_online_device(ws_room_peers, peer).map(|dev| (peer, sk, dev)));
                let Some((target_peer, shard_key, dev)) = holder else { continue };
                let envelope = MessageEnvelope::ShardRequest {
                    sid: server_id.clone(),
                    cid: content_id.clone(),
                    si: *si,
                    sk: shard_key.clone(),
                    target: None,
                };
                let json = serde_json::to_string(&envelope).unwrap_or_default();
                stamp_shard_ask(vault_shard_asks, &content_id, *si, &dev);
                send_encrypted_message(
                    &mut *olm, crypto_store,
                    &dev, &json, event_tx,
                    ws_cmd_tx, ws_room_peers,
                ).await;
                hollow_log!("[HOLLOW-VAULT] Requested shard si={si} from {target_peer} (device {dev})");
                requested += 1;
            }

            if requested > 0 && have + requested >= need {
                pending_vault_downloads.insert(content_id.clone(), (server_id.clone(), need, requested));
                hollow_log!("[HOLLOW-VAULT] Requested {requested} shards for {content_id} (have {have}, need {need})");
                let _ = event_tx.send(NetworkEvent::VaultDownloadProgress {
                    server_id, content_id,
                    phase: "Fetching shards from peers...".into(),
                    progress: 0.1,
                }).await;
            } else {
                let online_holders = have + requested;
                let _ = event_tx.send(NetworkEvent::VaultDownloadFailed {
                    server_id, content_id,
                    error: format!("{online_holders}/{need} shard holders online, need at least {need}. Try again later."),
                }).await;
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

/// A download whose rebuild dropped shards it has to pull again, with the holder whose
/// answer was not the shard, when one was.
pub(crate) struct VaultRepull {
    pub server_id: String,
    pub content_id: String,
    pub refuted: Option<String>,
}

/// Pull a download's missing shards afresh: at most `MAX_VAULT_REPULLS` times on its own,
/// never again from a holder that answered it with a wrong shard.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_vault_repull(
    server_states: &mut HashMap<String, crate::crdt::server_state::ServerState>,
    pending_vault_downloads: &mut HashMap<String, (String, usize, usize)>,
    vault_shard_asks: &mut ShardAsks,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    repull: VaultRepull,
    db_path: &str,
    db_passphrase: &str,
) {
    let VaultRepull { server_id, content_id, refuted } = repull;
    if let Some(holder) = &refuted {
        refute_holder(vault_shard_asks, &content_id, holder);
    }
    pending_vault_downloads.remove(&content_id);
    if !take_repull(vault_shard_asks, &content_id) {
        hollow_log!("[HOLLOW-VAULT] Gave up on {content_id} after {MAX_VAULT_REPULLS} fresh pulls");
        let _ = event_tx.send(NetworkEvent::VaultDownloadFailed {
            server_id, content_id,
            error: "The copies of this file online are damaged. Try again later.".into(),
        }).await;
        return;
    }
    hollow_log!("[HOLLOW-VAULT] Pulling the shards of {content_id} afresh");
    Box::pin(handle_vault_download_file(
        server_states, pending_vault_downloads, vault_shard_asks, olm, crypto_store, mls,
        event_tx, ws_cmd_tx, ws_room_peers, bundle_keypair,
        server_id, content_id, false, db_path, db_passphrase,
    ))
    .await;
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
    hollow_log!("[HOLLOW-VAULT] VaultUploadFile: cid={content_id} in {server_id}/{channel_id}");

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
    device_peer_id: &str,
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

                                stream_shard(
                                    ws_cmd_tx, ws_room_peers,
                                    webrtc_peers, pending_webrtc_sends, event_tx,
                                    device_peer_id, &dev, &content_id, placement.shard_index, shard_data,
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
                    && let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &manifest_envelope, crypto_store, Some(state))
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
            && let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &delete_envelope, crypto_store, Some(state))
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
    vault_shard_asks: &mut ShardAsks,
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
                    cid: content_id.clone(),
                    si: shard_index,
                    sk: shard_key,
                    target: None,
                };
                let json = serde_json::to_string(&envelope).unwrap_or_default();
                stamp_shard_ask(vault_shard_asks, &content_id, shard_index, &dev);
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
    device_peer_id: &str,
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

                stream_shard(
                    ws_cmd_tx, ws_room_peers,
                    webrtc_peers, pending_webrtc_sends, event_tx,
                    device_peer_id, &dev, &content_id, shard_index, &data,
                ).await;
                hollow_log!("[HOLLOW-VAULT] Streaming shard si={shard_index} ({} bytes) to {target_peer} (device {dev})", data.len());
            }
        }
}

// ── 6. InitiateRecoveryPool ──────────────────────────────────────────

#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_initiate_recovery_pool(
    recovery_pool_state: &mut Option<crate::node::recovery_pool::RecoveryPoolState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    device_peer_id: &str,
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
        device_peer_id.to_string(),
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

#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_join_recovery_pool(
    recovery_pool_state: &mut Option<crate::node::recovery_pool::RecoveryPoolState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
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
        device_peer_id.to_string(),
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

/// Plan the pool's transfers when we are its coordinator. The room never echoes a frame
/// to its sender, so we carry out our own part ourselves, after the plan is on its way so
/// that a member we stream to holds the plan before our bytes.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn coordinate_recovery(
    pool: &crate::node::recovery_pool::RecoveryPoolState,
    pending_shard_streams: &mut HashMap<String, PendingShardStream>,
    pending_vault_downloads: &mut HashMap<String, (String, usize, usize)>,
    server_states: &HashMap<String, ServerState>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    local_peer_str: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    if !pool.is_coordinator() || pool.members.len() < 2 {
        return;
    }
    let plan = pool.compute_transfer_plan();
    if plan.is_empty() {
        return;
    }
    hollow_log!("[RECOVERY-POOL] Coordinator: broadcasting transfer plan with {} assignments", plan.len());
    let msg = HavenMessage::RecoveryTransferPlan { plan_json: serde_json::to_string(&plan).unwrap_or_default() };
    if let Some(bytes) = pool.seal(&pool.local_device, &msg) {
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom { room_code: pool.room_code(), data: bytes });
    }
    apply_recovery_plan(
        pool, &plan, pending_shard_streams, pending_vault_downloads, server_states, ws_cmd_tx, local_peer_str,
        db_path, db_passphrase,
    )
    .await;
}

/// Our part of the coordinator's `plan`: wait for each shard planned for us, from its
/// planned source alone, and stream each one we hold to the member it is planned for.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn apply_recovery_plan(
    pool: &crate::node::recovery_pool::RecoveryPoolState,
    plan: &[crate::node::recovery_pool::TransferAssignment],
    pending_shard_streams: &mut HashMap<String, PendingShardStream>,
    pending_vault_downloads: &mut HashMap<String, (String, usize, usize)>,
    server_states: &HashMap<String, ServerState>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    local_peer_str: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[RECOVERY-POOL] Processing {} transfer assignments", plan.len());
    let vault_dir = crate::identity::data_dir().unwrap_or_default().join("vault");
    let Ok(cs) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) else {
        return;
    };
    for assignment in plan {
        // The id names our shard files and temps.
        if !crate::vault::content_store::is_content_id(&assignment.content_id) {
            hollow_log!("[HOLLOW-SECURITY] Skipped a transfer assignment: not a content id");
            continue;
        }
        let sk = crate::vault::content_store::shard_key(&assignment.content_id, assignment.shard_index);
        if assignment.dest_peer == pool.local_device
            && let Some(meta) = pool.manifest_meta.get(&assignment.content_id)
        {
            if cs.has_shard(&sk).unwrap_or(false) {
                continue;
            }
            let key = format!("{}:{}", assignment.content_id, assignment.shard_index);
            pending_shard_streams.insert(key, PendingShardStream {
                server_id: pool.server_id.clone(),
                content_id: assignment.content_id.clone(),
                shard_index: assignment.shard_index,
                shard_key: sk.clone(),
                k: meta.k,
                m: meta.m,
                total_size: meta.total_data_size,
                tier: meta.storage_tier.clone(),
                sender: assignment.source_peer.clone(),
                stream_id: shard_stream_id(&assignment.content_id, assignment.shard_index, &assignment.source_peer, &pool.local_device),
                pledge: our_pledge(server_states, &pool.server_id, local_peer_str),
                asked: false,
                recovery: true,
            });
            // Rebuild the file once enough of its shards are here.
            pending_vault_downloads.entry(assignment.content_id.clone())
                .or_insert((pool.server_id.clone(), meta.k as usize, 0));
        }

        if assignment.source_peer == pool.local_device && pool.members.contains_key(&assignment.dest_peer) {
            let Ok(shard_bytes) = cs.read_shard_unchecked(&pool.server_id, &sk) else { continue };
            hollow_log!("[RECOVERY-POOL] Sending shard {}:{} ({} bytes) to {}",
                assignment.content_id, assignment.shard_index, shard_bytes.len(), assignment.dest_peer);
            super::ws_stream_transfer::ws_stream_send_bytes(
                ws_cmd_tx,
                &pool.room_code(),
                &assignment.dest_peer,
                &super::ws_stream_transfer::StreamKind::Shard { shard_index: assignment.shard_index },
                &shard_stream_id(&assignment.content_id, assignment.shard_index, &pool.local_device, &assignment.dest_peer),
                &shard_bytes,
            ).await;

            let received = HavenMessage::RecoveryShardReceived {
                content_id: assignment.content_id.clone(),
                shard_index: assignment.shard_index,
            };
            if let Some(bytes) = pool.seal(&pool.local_device, &received) {
                let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom { room_code: pool.room_code(), data: bytes });
            }
        }
    }
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
    if !crate::vault::content_store::is_content_id(cid) {
        return Some("not a content id");
    }
    let Some(state) = server_states.get(sid).filter(|s| s.is_member(sender)) else {
        return Some("not a member of the server");
    };
    if cs.has_shard(&crate::vault::content_store::shard_key(cid, si)).unwrap_or(true) {
        return Some("that shard is already held");
    }
    let used = cs.total_storage_used(sid).unwrap_or(0);
    if pledge_refused(state.get_storage_pledge(local_peer), used, incoming_bytes) {
        return Some("our storage pledge for the server is full");
    }
    None
}

/// Whether `incoming` more bytes would take a server's vault on our disk past our
/// pledge for it (0 pledges no limit).
pub(crate) fn pledge_refused(pledge: u64, used: u64, incoming: u64) -> bool {
    pledge > 0 && used.saturating_add(incoming) > pledge
}

/// Our storage pledge for `sid`, snapshotted into a shard stream when it registers.
pub(crate) fn our_pledge(server_states: &HashMap<String, ServerState>, sid: &str, local_peer: &str) -> u64 {
    server_states.get(sid).map_or(0, |state| state.get_storage_pledge(local_peer))
}

/// Our shard pulls: the device asked for each shard we have not heard back on ("cid:si"
/// -> device, sent at), and per content id what its downloads learned.
#[derive(Default)]
pub(crate) struct ShardAsks {
    asks: HashMap<String, (String, std::time::Instant)>,
    pulls: HashMap<String, PullBook>,
}

/// One content id's pulls: the holders that answered with a wrong shard, and the fresh
/// pulls its rebuilds made on their own since the person last asked.
struct PullBook {
    refuted: std::collections::HashSet<String>,
    repulls: u8,
    at: std::time::Instant,
}

/// Outstanding shard pulls (and content ids with a pull book) kept at once; the oldest
/// goes first.
const MAX_SHARD_ASKS: usize = 512;

/// How long a shard pull waits for its answer.
const SHARD_ASK_TTL: std::time::Duration = std::time::Duration::from_secs(300);

/// Fresh pulls a download makes on its own after its shards fail their manifest.
const MAX_VAULT_REPULLS: u8 = 3;

/// Record that `device` was asked for shard `si` of `cid`.
pub(crate) fn stamp_shard_ask(asks: &mut ShardAsks, cid: &str, si: u16, device: &str) {
    let asks = &mut asks.asks;
    asks.retain(|_, (_, at)| at.elapsed() < SHARD_ASK_TTL);
    asks.insert(format!("{cid}:{si}"), (device.to_string(), std::time::Instant::now()));
    while asks.len() > MAX_SHARD_ASKS {
        let Some(oldest) = asks.iter().min_by_key(|(_, (_, at))| *at).map(|(key, _)| key.clone()) else { break };
        asks.remove(&oldest);
    }
}

/// Whether a ShardResponse from `device` answers a pull of ours, consuming the ask:
/// one answer per ask, only from the device asked, and only while it is fresh.
pub(crate) fn take_shard_ask(asks: &mut ShardAsks, cid: &str, si: u16, device: &str) -> bool {
    let key = format!("{cid}:{si}");
    match asks.asks.get(&key) {
        Some((asked, at)) if asked == device => {
            let fresh = at.elapsed() < SHARD_ASK_TTL;
            asks.asks.remove(&key);
            fresh
        }
        _ => false,
    }
}

fn pull_book<'a>(asks: &'a mut ShardAsks, cid: &str) -> &'a mut PullBook {
    if !asks.pulls.contains_key(cid)
        && asks.pulls.len() >= MAX_SHARD_ASKS
        && let Some(stalest) = asks.pulls.iter().min_by_key(|(_, book)| book.at).map(|(key, _)| key.clone())
    {
        asks.pulls.remove(&stalest);
    }
    let book = asks.pulls.entry(cid.to_string()).or_insert_with(|| PullBook {
        refuted: Default::default(),
        repulls: 0,
        at: std::time::Instant::now(),
    });
    book.at = std::time::Instant::now();
    book
}

/// Never ask `holder` (a device; its identity is kept) for shards of `cid` again: it
/// answered with bytes that are not the shard.
pub(crate) fn refute_holder(asks: &mut ShardAsks, cid: &str, holder: &str) {
    pull_book(asks, cid).refuted.insert(super::resolver::resolve(holder));
}

/// Whether `holder` once answered a pull of `cid` with bytes that are not the shard.
pub(crate) fn holder_refuted(asks: &ShardAsks, cid: &str, holder: &str) -> bool {
    asks.pulls.get(cid).is_some_and(|book| book.refuted.contains(&super::resolver::resolve(holder)))
}

/// Whether a download of `cid` may make one more fresh pull on its own, counting it.
pub(crate) fn take_repull(asks: &mut ShardAsks, cid: &str) -> bool {
    let book = pull_book(asks, cid);
    book.repulls = book.repulls.saturating_add(1);
    book.repulls <= MAX_VAULT_REPULLS
}

/// Why `bytes` may not be stored as shard `si` of `cid`, `None` when they may: once we
/// hold the manifest, a shard must be the one it names, since a held shard is never
/// replaced and a wrong first copy would refuse the real one. An unasked copy that comes
/// while we pull the content (`pulling`) lands only as the bytes its manifest pins: held,
/// it would refuse the answer we asked for.
pub(crate) fn shard_bytes_refused(
    cs: &crate::vault::content_store::ContentStore,
    cid: &str,
    si: u16,
    bytes: &[u8],
    pulling: bool,
) -> Option<&'static str> {
    let manifest = cs.load_manifest(cid).ok().flatten();
    match manifest.as_ref().and_then(|m| m.shard_hash(si)) {
        Some(expected) => {
            (crate::vault::content_store::content_id(bytes) != expected).then_some("not the shard its manifest names")
        }
        None => pulling.then_some("an unasked copy its manifest does not pin, while we pull the content"),
    }
}

/// Whether a pull of ours for any shard of `cid` waits for its answer.
pub(crate) fn pull_waiting(asks: &ShardAsks, cid: &str) -> bool {
    asks.asks.iter().any(|(key, (_, at))| {
        key.strip_prefix(cid).is_some_and(|rest| rest.starts_with(':')) && at.elapsed() < SHARD_ASK_TTL
    })
}

/// The shards of `manifest`'s content we hold, by index, and how many copies were
/// deleted for not being the shard the manifest names (or no longer the bytes we
/// stored). A held shard is never replaced, so a wrong copy would refuse the real one
/// forever; this is where a download deletes one.
pub(crate) fn gather_vault_shards(
    cs: &crate::vault::content_store::ContentStore,
    manifest: &crate::vault::pipeline::VaultManifest,
) -> (Vec<Option<Vec<u8>>>, usize) {
    let n = (manifest.k as usize + manifest.m as usize).max(1);
    let mut packed: Vec<Option<Vec<u8>>> = vec![None; n];
    let mut dropped = 0;
    for (si, slot) in packed.iter_mut().enumerate() {
        // The key is global: a copy planted under another server blocks this one too.
        let key = crate::vault::content_store::shard_key(&manifest.content_id, si as u16);
        let Ok(Some(record)) = cs.get_shard_record(&key) else { continue };
        let expected = manifest.shard_hash(si as u16).unwrap_or(&record.data_hash);
        match cs.read_shard_unchecked(&record.server_id, &key) {
            Ok(bytes) if crate::vault::content_store::content_id(&bytes) == expected => *slot = Some(bytes),
            _ => {
                hollow_log!("[HOLLOW-SECURITY] Deleted shard {si} of {}: not the shard its manifest names", manifest.content_id);
                let _ = cs.delete_shard(&record.server_id, &key);
                dropped += 1;
            }
        }
    }
    (packed, dropped)
}

/// Whether `packed` holds a copy `manifest` pins no hash for, so a failed rebuild may be
/// that copy's fault.
pub(crate) fn holds_unpinned(manifest: &crate::vault::pipeline::VaultManifest, packed: &[Option<Vec<u8>>]) -> bool {
    packed.iter().enumerate().any(|(si, copy)| copy.is_some() && manifest.shard_hash(si as u16).is_none())
}

/// After the shards in `packed` failed to rebuild `manifest`'s content, delete those the
/// manifest pins no hash for and return how many: one of them is bad and nothing tells
/// which, so they are pulled again. A copy at an index in `ours` stays: we hold it as a
/// placement, and other members pull it from us.
pub(crate) fn drop_unpinned_shards(
    cs: &crate::vault::content_store::ContentStore,
    manifest: &crate::vault::pipeline::VaultManifest,
    packed: &[Option<Vec<u8>>],
    ours: &std::collections::HashSet<u16>,
) -> usize {
    let mut dropped = 0;
    for si in (0..packed.len()).filter(|si| packed[*si].is_some()) {
        if manifest.shard_hash(si as u16).is_some() || ours.contains(&(si as u16)) {
            continue;
        }
        let key = crate::vault::content_store::shard_key(&manifest.content_id, si as u16);
        if let Ok(Some(record)) = cs.get_shard_record(&key)
            && cs.delete_shard(&record.server_id, &key).is_ok()
        {
            dropped += 1;
        }
    }
    if dropped > 0 {
        hollow_log!("[HOLLOW-SECURITY] Deleted {dropped} shard(s) of {} its manifest cannot vouch for after a failed rebuild", manifest.content_id);
    }
    dropped
}

/// The temp in `dir` a shard send over a data channel streams from: its transfer's own,
/// named by the stream id, whose alphanumerics alone reach the name.
pub(crate) fn shard_send_temp(dir: &std::path::Path, stream_id: &str) -> std::path::PathBuf {
    let name: String = stream_id.chars().filter(|c| c.is_ascii_alphanumeric()).take(64).collect();
    dir.join(format!(".stream_shard_{name}.tmp"))
}

/// The wire id of the stream carrying shard `si` of `cid` from device `from` to device
/// `to`. A content id fills the 64-byte id field by itself, and both lanes key their
/// sends, temps and receive streams by this id, so every transfer needs its own: one
/// holder streams shards of a file to several devices, several holders to one device.
pub(crate) fn shard_stream_id(cid: &str, si: u16, from: &str, to: &str) -> String {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(b"hollow-shard-stream1");
    for part in [cid, from, to] {
        h.update((part.len() as u64).to_be_bytes());
        h.update(part.as_bytes());
    }
    h.update(si.to_be_bytes());
    hex::encode(h.finalize())
}

/// Stream shard `si` of `cid` from our device `us` to device `to`, under its own stream id.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn stream_shard(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    webrtc_peers: &std::collections::HashSet<String>,
    pending_webrtc_sends: &mut HashMap<String, (String, super::ws_stream_transfer::StreamKind, String, std::path::PathBuf, u64)>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    us: &str,
    to: &str,
    cid: &str,
    si: u16,
    bytes: &[u8],
) {
    super::file_handler::stream_to_peer_bytes(
        ws_cmd_tx, ws_room_peers, webrtc_peers, pending_webrtc_sends, event_tx,
        to, &super::ws_stream_transfer::StreamKind::Shard { shard_index: si },
        &shard_stream_id(cid, si, us, to), bytes,
    ).await;
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

    fn temp_db() -> (crate::test_tmp::TestDir, String, String) {
        let tmp = crate::test_tmp::tempdir().unwrap();
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
        let cid = "c1".repeat(32);
        let refused = |who: &str, sid: &str, si: u16, bytes: u64| {
            shard_write_refused(&states, &cs, who, sid, &cid, si, &local, bytes)
        };
        assert_eq!(refused(&stranger, "srv", 0, 8), Some("not a member of the server"));
        assert_eq!(refused(&bob, "other-srv", 0, 8), Some("not a member of the server"));
        assert_eq!(refused(&bob, "srv", 0, 8), None);
        cs.store_shard("srv", &cid, 0, 0, 0, 8, StorageTier::Standard, b"realbyte").unwrap();
        assert_eq!(refused(&bob, "srv", 0, 8), Some("that shard is already held"));
        assert_eq!(refused(&bob, "srv", 1, 60), Some("our storage pledge for the server is full"));
        assert_eq!(refused(&bob, "srv", 1, 8), None);
        // A-R4: the id names files on our disk.
        for bad in ["C:\\a\\b\\c", "../../x", &"C1".repeat(32)] {
            assert_eq!(
                shard_write_refused(&states, &cs, &bob, "srv", bad, 1, &local, 8),
                Some("not a content id"),
                "A-R4: a shard under {bad:?} was taken",
            );
        }
    }

    /// A-V1: a streamed shard is judged by its real size at completion, against the
    /// pledge snapshotted when its stream registered.
    #[test]
    fn pledge_refused_counts_the_real_size() {
        assert!(!pledge_refused(0, u64::MAX, u64::MAX), "pledge 0 is no limit");
        assert!(!pledge_refused(64, 56, 8));
        assert!(pledge_refused(64, 56, 9));
        assert!(pledge_refused(64, u64::MAX, 1), "no overflow past the pledge");
    }

    /// A-V6: a shard is never replaced once held, so only the device we asked may
    /// answer, once, and only for the shard we asked it for.
    #[test]
    fn an_unasked_shard_response_is_dropped() {
        let cid = "c1".repeat(32);
        let mut asks = ShardAsks::default();
        assert!(!take_shard_ask(&mut asks, &cid, 0, "bob"), "A-V6: an answer nobody asked for was taken");
        stamp_shard_ask(&mut asks, &cid, 0, "bob");
        assert!(!take_shard_ask(&mut asks, &cid, 0, "mallory"), "A-V6: another device answered for bob");
        assert!(!take_shard_ask(&mut asks, &cid, 1, "bob"), "A-V6: an answer for another shard was taken");
        assert!(take_shard_ask(&mut asks, &cid, 0, "bob"), "the device we asked was refused");
        assert!(!take_shard_ask(&mut asks, &cid, 0, "bob"), "A-V6: a second answer to one ask was taken");
        if let Some(old) = std::time::Instant::now().checked_sub(SHARD_ASK_TTL) {
            asks.asks.insert(format!("{cid}:2"), ("bob".into(), old));
            assert!(!take_shard_ask(&mut asks, &cid, 2, "bob"), "an expired ask was answered");
        }
        for si in 0..(MAX_SHARD_ASKS as u16 + 8) {
            stamp_shard_ask(&mut asks, &cid, si, "bob");
        }
        assert_eq!(asks.asks.len(), MAX_SHARD_ASKS);
    }

    // ── HOL-SEC-117: a bad shard never blocks a download for good ──

    fn manifest_for(cid: &str, k: u16, m: u16, shard_hashes: Vec<String>) -> crate::vault::pipeline::VaultManifest {
        crate::vault::pipeline::VaultManifest {
            content_id: cid.to_string(),
            encryption_key: "00".repeat(32),
            nonce: "00".repeat(12),
            original_size: 40,
            k,
            m,
            shard_count: k + m,
            file_name: "a.bin".into(),
            mime_type: "application/octet-stream".into(),
            storage_tier: "standard".into(),
            created_at: 1,
            creator_peer_id: "creator".into(),
            channel_id: "srv-general".into(),
            message_id: String::new(),
            shard_hashes,
        }
    }

    /// Once we hold its manifest, a shard lands only as the bytes the manifest names: a
    /// held shard is never replaced, so a wrong first copy refused the real one forever.
    #[test]
    fn a_shard_must_be_the_one_its_manifest_names() {
        let (tmp, db, pass) = temp_db();
        let cs = ContentStore::open(&db, &pass, &tmp.path().join("vault")).unwrap();
        let ciphertext = b"the whole ciphertext".to_vec();
        let whole = crate::vault::content_store::content_id(&ciphertext);
        assert_eq!(shard_bytes_refused(&cs, &whole, 0, b"junk", false), None, "no manifest yet, nothing to judge by");
        cs.save_manifest("srv", "srv-general", &manifest_for(&whole, 0, 0, Vec::new())).unwrap();
        assert!(
            shard_bytes_refused(&cs, &whole, 0, b"junk", false).is_some(),
            "HOL-SEC-117: a replicated copy that is not the ciphertext was taken",
        );
        assert_eq!(shard_bytes_refused(&cs, &whole, 0, &ciphertext, false), None);

        let shards: Vec<Vec<u8>> = (0..5u8).map(|i| vec![i; 8]).collect();
        let hashes = shards.iter().map(|s| crate::vault::content_store::content_id(s)).collect();
        let erasure = "e1".repeat(32);
        cs.save_manifest("srv", "srv-general", &manifest_for(&erasure, 3, 2, hashes)).unwrap();
        assert!(
            shard_bytes_refused(&cs, &erasure, 1, &shards[2], false).is_some(),
            "HOL-SEC-117: another index's bytes were taken as shard 1",
        );
        assert_eq!(shard_bytes_refused(&cs, &erasure, 1, &shards[1], false), None);
        let legacy = "e2".repeat(32);
        cs.save_manifest("srv", "srv-general", &manifest_for(&legacy, 3, 2, Vec::new())).unwrap();
        assert_eq!(shard_bytes_refused(&cs, &legacy, 1, b"junk", false), None, "a manifest without hashes pins nothing");

        // While we pull the content, an unasked copy lands only as the bytes the manifest pins.
        assert!(
            shard_bytes_refused(&cs, &legacy, 1, b"junk", true).is_some(),
            "HOL-SEC-117 residual: an unpinned unasked copy was taken while we pull its content",
        );
        assert!(shard_bytes_refused(&cs, &"e3".repeat(32), 1, b"junk", true).is_some(), "no manifest pins nothing");
        assert_eq!(shard_bytes_refused(&cs, &erasure, 1, &shards[1], true), None, "a pinned copy still lands");
        assert!(shard_bytes_refused(&cs, &erasure, 1, &shards[2], true).is_some());
    }

    /// V5-2: a shard send's temp stays in its folder whatever id a member stored the
    /// shard under (the stream id it is named by is hex), and a multi-byte id never panics
    /// the node.
    #[test]
    fn a_shard_send_temp_stays_in_its_folder() {
        let dir = std::path::Path::new("files");
        for cid in ["..\\..\\x", "../../x", "C:\\Users\\x\\Startup", "/etc/passwd", &format!("a{}", "é".repeat(40)), &"a1".repeat(32)] {
            let id = shard_stream_id(cid, 3, "holder", "asker");
            assert!(id.len() == 64 && id.bytes().all(|b| b.is_ascii_hexdigit()), "the stream id of {cid:?} is {id:?}");
            for named in [cid, id.as_str()] {
                let temp = shard_send_temp(dir, named);
                assert_eq!(temp.parent(), Some(dir), "V5-2: the temp for {named:?} left its folder: {temp:?}");
                let name = temp.file_name().and_then(|n| n.to_str()).expect("a plain name");
                assert!(name.starts_with(".stream_shard_") && name.ends_with(".tmp"), "{name}");
                assert!(name.bytes().all(|b| b.is_ascii_alphanumeric() || b"._".contains(&b)), "V5-2: {name:?} carries a path character");
            }
        }
    }

    /// Each transfer of a shard streams under its own id: another shard, sender or
    /// receiver is another id, and both ends derive the same one.
    #[test]
    fn each_shard_transfer_has_its_own_stream_id() {
        let cid = "ab".repeat(32);
        let id = shard_stream_id(&cid, 1, "alice", "bob");
        assert_eq!(id, shard_stream_id(&cid, 1, "alice", "bob"));
        for other in [
            shard_stream_id(&"cd".repeat(32), 1, "alice", "bob"),
            shard_stream_id(&cid, 2, "alice", "bob"),
            shard_stream_id(&cid, 1, "carol", "bob"),
            shard_stream_id(&cid, 1, "alice", "carol"),
            shard_stream_id(&cid, 1, "bob", "alice"),
            shard_stream_id(&cid, 1, "alic", "ebob"),
        ] {
            assert_ne!(id, other, "two transfers share a stream id");
        }
    }

    /// A pull waits for the content it asked a shard of, only while its ask is fresh.
    #[test]
    fn a_pull_waits_only_for_its_own_content() {
        let cid = "c1".repeat(32);
        let mut asks = ShardAsks::default();
        assert!(!pull_waiting(&asks, &cid));
        stamp_shard_ask(&mut asks, &cid, 3, "bob");
        assert!(pull_waiting(&asks, &cid), "HOL-SEC-117 residual: a waiting pull was not seen");
        assert!(!pull_waiting(&asks, &"c2".repeat(32)), "another content's pull counted");
        assert!(!pull_waiting(&asks, &cid[..63]), "a prefix of the id counted");
        assert!(take_shard_ask(&mut asks, &cid, 3, "bob"));
        assert!(!pull_waiting(&asks, &cid), "an answered pull still waits");
        if let Some(old) = std::time::Instant::now().checked_sub(SHARD_ASK_TTL) {
            asks.asks.insert(format!("{cid}:0"), ("bob".into(), old));
            assert!(!pull_waiting(&asks, &cid), "an expired pull still waits");
        }
    }

    /// A rebuild deletes each copy its manifest refutes (wherever it was filed), keeps the
    /// rest, and after a failed rebuild deletes only the copies nothing vouches for.
    #[test]
    fn a_rebuild_deletes_the_copies_its_manifest_refutes() {
        let (tmp, db, pass) = temp_db();
        let cs = ContentStore::open(&db, &pass, &tmp.path().join("vault")).unwrap();
        let shards: Vec<Vec<u8>> = (0..5u8).map(|i| vec![i; 8]).collect();
        let cid = "e1".repeat(32);
        let key = |si: u16| crate::vault::content_store::shard_key(&cid, si);
        let pinned = manifest_for(&cid, 3, 2, shards.iter().map(|s| crate::vault::content_store::content_id(s)).collect());
        cs.store_shard("srv", &cid, 0, 3, 2, 40, StorageTier::Standard, &shards[0]).unwrap();
        cs.store_shard("srv", &cid, 1, 3, 2, 40, StorageTier::Standard, b"planted").unwrap();
        // The shard key is global, so a copy filed under another server blocks this one too.
        cs.store_shard("other-srv", &cid, 2, 3, 2, 40, StorageTier::Standard, b"planted elsewhere").unwrap();
        let (packed, dropped) = gather_vault_shards(&cs, &pinned);
        assert_eq!(dropped, 2, "HOL-SEC-117: a planted copy survived the rebuild");
        assert_eq!(packed[0].as_deref(), Some(&shards[0][..]));
        assert!(packed[1].is_none() && packed[2].is_none());
        assert!(
            !cs.has_shard(&key(1)).unwrap() && !cs.has_shard(&key(2)).unwrap(),
            "HOL-SEC-117: a refuted copy is still held and refuses the real one",
        );
        assert!(cs.has_shard(&key(0)).unwrap(), "the real shard was deleted");
        assert_eq!(drop_unpinned_shards(&cs, &pinned, &packed, &Default::default()), 0, "every copy left is pinned, so a failed rebuild is not theirs");

        let legacy = manifest_for(&cid, 3, 2, Vec::new());
        cs.store_shard("srv", &cid, 1, 3, 2, 40, StorageTier::Standard, b"planted again").unwrap();
        let (packed, dropped) = gather_vault_shards(&cs, &legacy);
        assert_eq!(dropped, 0, "an unpinned copy that is still the bytes we stored waits for a rebuild");
        assert_eq!(
            drop_unpinned_shards(&cs, &legacy, &packed, &Default::default()),
            2,
            "HOL-SEC-117: a failed rebuild kept the copies nothing vouches for",
        );
        assert!(!cs.has_shard(&key(0)).unwrap() && !cs.has_shard(&key(1)).unwrap());

        let ciphertext = b"the whole ciphertext".to_vec();
        let whole = crate::vault::content_store::content_id(&ciphertext);
        cs.store_shard("srv", &whole, 0, 0, 0, 0, StorageTier::Standard, b"junk").unwrap();
        let (packed, dropped) = gather_vault_shards(&cs, &manifest_for(&whole, 0, 0, Vec::new()));
        assert_eq!((packed.len(), dropped), (1, 1), "HOL-SEC-117: a planted replicated copy survived");
    }

    /// A rebuild that fails on copies its manifest cannot vouch for deletes them and pulls
    /// afresh; replicated content with no copy here is pulled from a holder.
    #[test]
    fn a_failed_local_rebuild_pulls_afresh() {
        let _g = super::super::resolver::test_lock();
        let (tmp, db, pass) = temp_db();
        let vault = tmp.path().join("vault");
        let cs = ContentStore::open(&db, &pass, &vault).unwrap();
        let (states, local) = server_with(&[], 0);
        let ciphertext = b"an erasure-coded ciphertext long enough to split in three".to_vec();
        let cid = crate::vault::content_store::content_id(&ciphertext);
        let shards = crate::vault::erasure::encode(&ciphertext, 3, 2, &cid).unwrap();
        cs.save_manifest("srv", "srv-general", &manifest_for(&cid, 3, 2, Vec::new())).unwrap();
        for si in 0..2u16 {
            cs.store_shard("srv", &cid, si, 3, 2, 0, StorageTier::Standard, &shards[si as usize]).unwrap();
        }
        cs.store_shard("srv", &cid, 2, 3, 2, 0, StorageTier::Standard, b"planted").unwrap();
        let planned = local_shards(&states, &vault, "srv", &cid, &local, &db, &pass);
        assert!(
            matches!(&planned, Ok(LocalShards::Need { have: 0, need: 3, missing }) if missing.len() == 5),
            "HOL-SEC-117: a failed rebuild kept the copies nothing vouches for: {:?}",
            planned.as_ref().err(),
        );
        for si in 0..3u16 {
            assert!(!cs.has_shard(&crate::vault::content_store::shard_key(&cid, si)).unwrap());
        }

        let whole = "c3".repeat(32);
        cs.save_manifest("srv", "srv-general", &manifest_for(&whole, 0, 0, Vec::new())).unwrap();
        let planned = local_shards(&states, &vault, "srv", &whole, &local, &db, &pass);
        assert!(
            matches!(&planned, Ok(LocalShards::Need { have: 0, need: 1, .. })),
            "HOL-SEC-117: replicated content with no copy here is never pulled: {:?}",
            planned.as_ref().err(),
        );
    }

    /// A failed rebuild of a manifest that pins no hashes deletes the copies pulled or
    /// planted here and keeps the one we hold as a placement: other members pull it from us.
    #[test]
    fn a_failed_legacy_rebuild_keeps_the_copies_we_hold_for_others() {
        let _g = super::super::resolver::test_lock();
        let (tmp, db, pass) = temp_db();
        let vault = tmp.path().join("vault");
        let cs = ContentStore::open(&db, &pass, &vault).unwrap();
        let (states, local) = server_with(&[], 0);
        let ciphertext = b"an erasure-coded ciphertext long enough to split in three".to_vec();
        let cid = crate::vault::content_store::content_id(&ciphertext);
        let shards = crate::vault::erasure::encode(&ciphertext, 3, 2, &cid).unwrap();
        cs.save_manifest("srv", "srv-general", &manifest_for(&cid, 3, 2, Vec::new())).unwrap();
        let placements: Vec<_> = (0..5u16)
            .map(|si| crate::vault::placement::ShardPlacement {
                shard_index: si,
                target_peer: if si == 0 { local.clone() } else { format!("holder-{si}") },
                shard_key: crate::vault::content_store::shard_key(&cid, si),
            })
            .collect();
        cs.save_placements("srv", &cid, &placements).unwrap();
        for si in 0..2u16 {
            cs.store_shard("srv", &cid, si, 3, 2, 0, StorageTier::Standard, &shards[si as usize]).unwrap();
        }
        cs.store_shard("srv", &cid, 2, 3, 2, 0, StorageTier::Standard, b"planted").unwrap();
        let planned = local_shards(&states, &vault, "srv", &cid, &local, &db, &pass);
        let held = |si: u16| cs.has_shard(&crate::vault::content_store::shard_key(&cid, si)).unwrap();
        assert!(held(0), "HOL-SEC-117 residual: a failed legacy rebuild deleted the copy we hold for others");
        assert!(!held(1) && !held(2), "the copies pulled or planted here were kept");
        assert!(
            matches!(&planned, Ok(LocalShards::Need { have: 1, need: 3, missing }) if missing.len() == 4),
            "a failed rebuild must pull everything but our own copy: {:?}",
            planned.as_ref().err(),
        );
    }

    /// A holder whose answer was not the shard is not asked for that content again, and a
    /// download pulls afresh on its own only `MAX_VAULT_REPULLS` times.
    #[test]
    fn a_refuted_holder_is_skipped_and_fresh_pulls_are_capped() {
        let _g = super::super::resolver::test_lock();
        let (cid, other) = ("c1".repeat(32), "c2".repeat(32));
        let mut asks = ShardAsks::default();
        assert!(!holder_refuted(&asks, &cid, "mallory"));
        refute_holder(&mut asks, &cid, "mallory");
        assert!(holder_refuted(&asks, &cid, "mallory"), "HOL-SEC-117: a holder that answered with a wrong shard is asked again");
        assert!(!holder_refuted(&asks, &cid, "bob"));
        assert!(!holder_refuted(&asks, &other, "mallory"), "a wrong shard of one file says nothing of another");
        for _ in 0..MAX_VAULT_REPULLS {
            assert!(take_repull(&mut asks, &cid));
        }
        assert!(!take_repull(&mut asks, &cid), "HOL-SEC-117: a download pulls afresh without end");
        assert!(take_repull(&mut asks, &other), "another file's pulls are its own");
        for i in 0..(MAX_SHARD_ASKS + 8) {
            refute_holder(&mut asks, &format!("{i:064}"), "mallory");
        }
        assert!(asks.pulls.len() <= MAX_SHARD_ASKS, "the pull books are bounded");
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

        assert!(
            arm("Ok(MessageEnvelope::ShardRequest {").contains("vault_ops::stream_shard("),
            "V5-2: the ShardRequest arm names its stream or temp from the member's id",
        );
        let response = arm("Ok(MessageEnvelope::ShardResponse {");
        let asked = response.find("vault_ops::take_shard_ask(").expect("A-V6: the ShardResponse arm takes no ask");
        assert!(asked < response.find("if !found").expect("the found branch"), "A-V6: an unasked miss is heard before the ask check");
        let ops = std::fs::read_to_string(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/node/vault_ops.rs"))
            .expect("read vault_ops.rs");
        let ops = &ops[..ops.find("#[cfg(test)]").expect("the tests")];

        let plan_arm = &swarm[swarm.find("HavenMessage::RecoveryTransferPlan { plan_json } =>").expect("the plan arm")..];
        let plan_arm = &plan_arm[..plan_arm.find("_ => {}").expect("the plan arm's end")];
        assert!(plan_arm.contains("vault_ops::apply_recovery_plan("), "A-R4: the plan arm skips the plan's rules");
        let plan = &ops[ops.find("async fn apply_recovery_plan(").expect("the plan's rules")..];
        let plan = &plan[..plan.find("\n}").expect("their end")];
        let check = plan.find("is_content_id(&assignment.content_id)").expect("A-R4: a plan takes any content id");
        assert!(check < plan.find("pending_shard_streams.insert(").expect("its registration"), "A-R4: the id is checked too late");
        assert!(!plan.contains("clip_bytes(&assignment.content_id"), "A-R4: a temp is named from the plan's id");

        let mut sends = 0;
        for src in [swarm.as_str(), ops] {
            for request in src.split("= MessageEnvelope::ShardRequest {").skip(1) {
                let until_sent = &request[..request.find("send_encrypted_message(").expect("its send")];
                assert!(until_sent.contains("stamp_shard_ask("), "A-V6: a ShardRequest goes out with no ask recorded");
                sends += 1;
            }
        }
        assert_eq!(sends, 4, "every ShardRequest send site is scanned");

        let handler = std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/node/file_handler.rs"),
        )
        .expect("read file_handler.rs");
        let done = &handler[handler.find("async fn handle_shard_stream_complete(").expect("the shard completion")..];
        let done = &done[..done.find("store_shard(").expect("its store")];
        assert!(done.contains("vault_ops::pledge_refused("), "A-V1: a streamed shard is stored past the pledge");
        assert!(done.contains("p.stream_id == request.id"), "a shard stream completes a transfer its id does not name");
        assert!(done.contains("p.sender == sender_peer"), "A-V6: any device completes a shard stream registered for another");

        assert!(done.contains("vault_ops::shard_bytes_refused("), "HOL-SEC-117: a streamed shard lands unchecked against its manifest");
        for from in [
            "Ok(MessageEnvelope::ShardStore { inner }) => {",
            "Ok(MessageEnvelope::ShardResponse {",
            "Ok(MessageEnvelope::ShardMigrate {",
        ] {
            let body = arm(from);
            let checked = body.find("vault_ops::shard_bytes_refused(").unwrap_or_else(|| panic!("HOL-SEC-117: {from} skips the manifest check"));
            assert!(checked < body.find("store_shard(").expect("its store"), "HOL-SEC-117: {from} checks the bytes after storing them");
        }
        // A stream completion hands a failed rebuild to the fresh pull, which knows our placements.
        for (src, from, after_failure) in [
            (handler.as_str(), "async fn attempt_vault_reconstruction(", "vault_ops::holds_unpinned("),
            (ops, "fn local_shards(", "drop_unpinned_shards("),
        ] {
            let body = &src[src.find(from).expect("a rebuild site")..];
            let body = &body[..body.find("\n}").expect("its end")];
            let rebuild = body.find("reconstruct_file(").expect("its rebuild");
            let gathered = body.find("gather_vault_shards(").unwrap_or(usize::MAX);
            assert!(gathered < rebuild, "HOL-SEC-117: {from} rebuilds from copies its manifest refutes");
            assert!(body[rebuild..].contains(after_failure), "HOL-SEC-117: {from} keeps unvouched copies after a failed rebuild");
        }
        assert_eq!(
            swarm.matches("vault_ops::handle_vault_repull(").count(),
            2,
            "HOL-SEC-117: a shard completion's fresh pull is dropped on the floor",
        );
    }

    /// Every shard stream rides its own transfer's id, never the file's content id: the
    /// byte senders go through `stream_shard`, the recovery plan and every receive
    /// registration through `shard_stream_id`.
    #[test]
    fn shard_streams_ride_their_own_ids() {
        let read = |file: &str| {
            std::fs::read_to_string(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(file)).expect("read the source")
        };
        let swarm = read("src/node/swarm.rs");
        let ops = read("src/node/vault_ops.rs");
        let ops = &ops[..ops.find("#[cfg(test)]").expect("the tests")];
        let handler = read("src/node/file_handler.rs");
        let handler = &handler[..handler.find("#[cfg(test)]").expect("the tests")];
        assert_eq!(
            [swarm.as_str(), ops, handler].iter().map(|s| s.matches("stream_to_peer_bytes(").count()).sum::<usize>(),
            2,
            "shard bytes stream past stream_shard, under an id of their own choosing",
        );
        let body = |src: &str, from: &str| {
            let body = &src[src.find(from).unwrap_or_else(|| panic!("missing {from}"))..];
            body[..body.find("\n}").expect("its end")].to_string()
        };
        for from in ["async fn handle_vault_upload_prepared(", "async fn handle_store_shard_on_peer("] {
            assert!(body(ops, from).contains("stream_shard("), "{from} streams a shard under another id");
        }
        assert_eq!(
            body(ops, "async fn apply_recovery_plan(").matches("shard_stream_id(").count(),
            2,
            "a recovery transfer streams, or is awaited, under another id",
        );
        let registrations: Vec<&str> = swarm.split("PendingShardStream {").skip(1).collect();
        assert_eq!(registrations.len(), 2, "every shard stream registration is scanned");
        for fields in registrations {
            let fields = &fields[..fields.find("});").expect("its end")];
            assert!(fields.contains("stream_id: vault_ops::shard_stream_id("), "a shard stream registration awaits another id");
        }
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
                shard_hashes: Vec::new(),
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
