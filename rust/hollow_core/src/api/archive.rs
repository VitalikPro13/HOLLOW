use flutter_rust_bridge::frb;

use crate::archive::types as at;

// ── FFI result structs ──────────────────────────────────────────

/// Summary result from verifying an archive.
pub struct ArchiveVerifyResult {
    pub archive_type: String,
    pub exporter_peer_id: String,
    pub export_timestamp: i64,
    pub message_count: u32,
    pub archive_signature_valid: bool,
    pub messages_with_valid_sig: u32,
    pub messages_with_invalid_sig: u32,
    pub messages_without_sig: u32,
    pub participant_ids: Vec<String>,
    pub peer_id: Option<String>,
    pub server_id: Option<String>,
    pub channel_id: Option<String>,
    pub channel_name: Option<String>,
    pub server_name: Option<String>,
    pub channels: Vec<ArchiveChannelInfoFfi>,
}

/// Channel info for multi-channel (server) archives.
#[derive(Clone)]
pub struct ArchiveChannelInfoFfi {
    pub channel_id: String,
    pub channel_name: String,
    pub message_count: u32,
}

/// A single message from an imported archive.
pub struct ArchiveMessageFfi {
    pub message_id: String,
    pub sender_id: String,
    pub text: String,
    pub timestamp: i64,
    pub signature: Option<String>,
    pub public_key: Option<String>,
    pub edited_at: Option<i64>,
    pub hidden_at: Option<i64>,
    pub reply_to_mid: Option<String>,
    pub file_id: Option<String>,
    /// Channel ID — populated only in server (multi-channel) archives.
    pub channel_id: Option<String>,
    pub reactions: Vec<ArchiveReactionFfi>,
    /// Whether this message's signature is valid (None if not yet verified).
    pub signature_valid: Option<bool>,
}

/// A reaction on a message.
pub struct ArchiveReactionFfi {
    pub emoji: String,
    pub peer_id: String,
    pub added_at: i64,
    pub signature: Option<String>,
    pub public_key: Option<String>,
}

/// An edit history entry.
pub struct ArchiveEditFfi {
    pub message_id: String,
    pub old_text: String,
    pub new_text: String,
    pub edited_at: i64,
    pub signature: Option<String>,
    pub public_key: Option<String>,
    pub prev_signature: Option<String>,
    pub prev_public_key: Option<String>,
    pub prev_timestamp: Option<i64>,
}

/// A deletion evidence entry.
pub struct ArchiveDeletionFfi {
    pub message_id: String,
    pub deleted_text: String,
    pub deleted_at: i64,
    pub signature: Option<String>,
    pub public_key: Option<String>,
}

/// A reaction removal evidence entry.
pub struct ArchiveReactionRemovalFfi {
    pub message_id: String,
    pub emoji: String,
    pub peer_id: String,
    pub removed_at: i64,
    pub signature: Option<String>,
    pub public_key: Option<String>,
}

/// A public key entry for offline verification.
pub struct ArchivePubKeyFfi {
    pub peer_id: String,
    pub public_key_b64: String,
}

/// File metadata from an archive.
pub struct ArchiveFileFfi {
    pub file_id: String,
    pub file_name: String,
    pub file_ext: String,
    pub mime_type: String,
    pub size_bytes: u64,
    pub is_image: bool,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub sha256: Option<String>,
    pub included: bool,
}

/// Full loaded archive data for the POV viewer.
pub struct ArchiveData {
    pub archive_type: String,
    pub exporter_peer_id: String,
    pub export_timestamp: i64,
    pub file_mode: String,
    pub peer_id: Option<String>,
    pub server_id: Option<String>,
    pub channel_id: Option<String>,
    pub channel_name: Option<String>,
    pub server_name: Option<String>,
    pub channels: Vec<ArchiveChannelInfoFfi>,
    pub participants: Vec<String>,
    pub messages: Vec<ArchiveMessageFfi>,
    pub edits: Vec<ArchiveEditFfi>,
    pub deletions: Vec<ArchiveDeletionFfi>,
    pub reaction_removals: Vec<ArchiveReactionRemovalFfi>,
    pub pubkeys: Vec<ArchivePubKeyFfi>,
    pub files: Vec<ArchiveFileFfi>,
    pub verification: ArchiveVerifyResult,
    /// Path to temp directory with extracted file bytes (if any).
    pub files_dir: Option<String>,
}

// ── FFI functions ───────────────────────────────────────────────

/// Export a DM conversation as a `.hollow-archive` file. `file_mode` is "full",
/// "images_only" or "placeholder"; returns the file size in bytes.
#[frb]
pub fn export_dm_archive(
    peer_id: String,
    output_path: String,
    file_mode: String,
) -> Result<u64, String> {
    let store = crate::api::storage::get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;

    let id_data = crate::identity::load_or_create_identity()?;
    let data_dir = crate::identity::data_dir()?;

    let zip_bytes = crate::archive::exporter::export_archive(
        ms,
        &id_data.keypair,
        at::ArchiveTarget::Dm { peer_id },
        at::FileMode::from_str(&file_mode),
        &data_dir,
    )?;

    let size = zip_bytes.len() as u64;
    std::fs::write(&output_path, &zip_bytes)
        .map_err(|e| format!("Failed to write archive: {e}"))?;
    Ok(size)
}

/// Export a channel conversation as a `.hollow-archive` file. `file_mode` is "full",
/// "images_only" or "placeholder"; returns the file size in bytes.
#[frb]
pub fn export_channel_archive(
    server_id: String,
    channel_id: String,
    channel_name: Option<String>,
    output_path: String,
    file_mode: String,
) -> Result<u64, String> {
    let store = crate::api::storage::get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;

    let id_data = crate::identity::load_or_create_identity()?;
    let data_dir = crate::identity::data_dir()?;

    let zip_bytes = crate::archive::exporter::export_archive(
        ms,
        &id_data.keypair,
        at::ArchiveTarget::Channel {
            server_id,
            channel_id,
            channel_name,
        },
        at::FileMode::from_str(&file_mode),
        &data_dir,
    )?;

    let size = zip_bytes.len() as u64;
    std::fs::write(&output_path, &zip_bytes)
        .map_err(|e| format!("Failed to write archive: {e}"))?;
    Ok(size)
}

/// Export every text channel of a server as one `.hollow-archive` file.
/// `channels_json` is `[{"channel_id": "...", "channel_name": "..."}]`; returns the
/// file size in bytes.
#[frb]
pub fn export_server_archive(
    server_id: String,
    server_name: String,
    channels_json: String,
    output_path: String,
    file_mode: String,
) -> Result<u64, String> {
    let store = crate::api::storage::get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;

    let id_data = crate::identity::load_or_create_identity()?;
    let data_dir = crate::identity::data_dir()?;

    let channels_raw: Vec<serde_json::Value> = serde_json::from_str(&channels_json)
        .map_err(|e| format!("Invalid channels_json: {e}"))?;
    let channels: Vec<(String, String)> = channels_raw
        .into_iter()
        .map(|v| {
            let ch_id = v["channel_id"].as_str().unwrap_or("").to_string();
            let ch_name = v["channel_name"].as_str().unwrap_or("").to_string();
            (ch_id, ch_name)
        })
        .collect();

    let zip_bytes = crate::archive::exporter::export_archive(
        ms,
        &id_data.keypair,
        at::ArchiveTarget::Server {
            server_id,
            server_name,
            channels,
        },
        at::FileMode::from_str(&file_mode),
        &data_dir,
    )?;

    let size = zip_bytes.len() as u64;
    std::fs::write(&output_path, &zip_bytes)
        .map_err(|e| format!("Failed to write archive: {e}"))?;
    Ok(size)
}

/// Verify a `.hollow-archive` file. Quick check — parses manifest + signatures,
/// reports validity summary without loading full message data.
#[frb]
pub fn verify_archive(archive_path: String) -> Result<ArchiveVerifyResult, String> {
    let zip_bytes = std::fs::read(&archive_path)
        .map_err(|e| format!("Failed to read archive file: {e}"))?;

    let result = crate::archive::loader::verify_archive(&zip_bytes)?;

    Ok(ArchiveVerifyResult {
        archive_type: result.archive_type,
        exporter_peer_id: result.exporter_peer_id,
        export_timestamp: result.export_timestamp,
        message_count: result.message_count,
        archive_signature_valid: result.archive_signature_valid,
        messages_with_valid_sig: result.messages_with_valid_sig,
        messages_with_invalid_sig: result.messages_with_invalid_sig,
        messages_without_sig: result.messages_without_sig,
        participant_ids: result.participant_ids,
        peer_id: result.peer_id,
        server_id: result.server_id,
        channel_id: result.channel_id,
        channel_name: result.channel_name,
        server_name: result.server_name,
        channels: result.channels.into_iter().map(|c| ArchiveChannelInfoFfi {
            channel_id: c.channel_id,
            channel_name: c.channel_name,
            message_count: c.message_count,
        }).collect(),
    })
}

/// Load a `.hollow-archive` file for the viewer: every message, edit, deletion, file
/// and verification result.
#[frb]
pub fn load_archive(archive_path: String) -> Result<ArchiveData, String> {
    let zip_bytes = std::fs::read(&archive_path)
        .map_err(|e| format!("Failed to read archive file: {e}"))?;

    let loaded = crate::archive::loader::load_archive(&zip_bytes)?;

    let sig_map: std::collections::HashMap<String, bool> = loaded
        .per_message_results
        .iter()
        .map(|v| (v.message_id.clone(), v.signature_valid))
        .collect();

    let messages: Vec<ArchiveMessageFfi> = loaded
        .messages
        .into_iter()
        .map(|m| {
            let sig_valid = sig_map.get(&m.message_id).copied();
            ArchiveMessageFfi {
                message_id: m.message_id,
                sender_id: m.sender_id,
                text: m.text,
                timestamp: m.timestamp,
                signature: m.signature,
                public_key: m.public_key,
                edited_at: m.edited_at,
                hidden_at: m.hidden_at,
                reply_to_mid: m.reply_to_mid,
                file_id: m.file_id,
                channel_id: m.channel_id,
                reactions: m
                    .reactions
                    .into_iter()
                    .map(|r| ArchiveReactionFfi {
                        emoji: r.emoji,
                        peer_id: r.peer_id,
                        added_at: r.added_at,
                        signature: r.signature,
                        public_key: r.public_key,
                    })
                    .collect(),
                signature_valid: sig_valid,
            }
        })
        .collect();

    let edits: Vec<ArchiveEditFfi> = loaded
        .edits
        .into_iter()
        .map(|e| ArchiveEditFfi {
            message_id: e.message_id,
            old_text: e.old_text,
            new_text: e.new_text,
            edited_at: e.edited_at,
            signature: e.signature,
            public_key: e.public_key,
            prev_signature: e.prev_signature,
            prev_public_key: e.prev_public_key,
            prev_timestamp: e.prev_timestamp,
        })
        .collect();

    let deletions: Vec<ArchiveDeletionFfi> = loaded
        .deletions
        .into_iter()
        .map(|d| ArchiveDeletionFfi {
            message_id: d.message_id,
            deleted_text: d.deleted_text,
            deleted_at: d.deleted_at,
            signature: d.signature,
            public_key: d.public_key,
        })
        .collect();

    let reaction_removals: Vec<ArchiveReactionRemovalFfi> = loaded
        .reaction_removals
        .into_iter()
        .map(|r| ArchiveReactionRemovalFfi {
            message_id: r.message_id,
            emoji: r.emoji,
            peer_id: r.peer_id,
            removed_at: r.removed_at,
            signature: r.signature,
            public_key: r.public_key,
        })
        .collect();

    let pubkeys: Vec<ArchivePubKeyFfi> = loaded
        .pubkeys
        .into_iter()
        .map(|p| ArchivePubKeyFfi {
            peer_id: p.peer_id,
            public_key_b64: p.public_key_b64,
        })
        .collect();

    let files: Vec<ArchiveFileFfi> = loaded
        .file_metadata
        .into_iter()
        .map(|f| ArchiveFileFfi {
            file_id: f.file_id,
            file_name: f.file_name,
            file_ext: f.file_ext,
            mime_type: f.mime_type,
            size_bytes: f.size_bytes,
            is_image: f.is_image,
            width: f.width,
            height: f.height,
            sha256: f.sha256,
            included: f.included,
        })
        .collect();

    let mut valid = 0u32;
    let mut invalid = 0u32;
    let mut unsigned = 0u32;
    for v in &loaded.per_message_results {
        if !v.has_signature {
            unsigned += 1;
        } else if v.signature_valid {
            valid += 1;
        } else {
            invalid += 1;
        }
    }

    let channels_ffi: Vec<ArchiveChannelInfoFfi> = loaded.manifest.channels.iter().map(|c| {
        ArchiveChannelInfoFfi {
            channel_id: c.channel_id.clone(),
            channel_name: c.channel_name.clone(),
            message_count: c.message_count,
        }
    }).collect();

    let verification = ArchiveVerifyResult {
        archive_type: loaded.manifest.archive_type.clone(),
        exporter_peer_id: loaded.manifest.exporter_peer_id.clone(),
        export_timestamp: loaded.manifest.export_timestamp,
        message_count: loaded.manifest.message_count,
        archive_signature_valid: loaded.archive_signature_valid,
        messages_with_valid_sig: valid,
        messages_with_invalid_sig: invalid,
        messages_without_sig: unsigned,
        participant_ids: loaded.manifest.participants.clone(),
        peer_id: loaded.manifest.peer_id.clone(),
        server_id: loaded.manifest.server_id.clone(),
        channel_id: loaded.manifest.channel_id.clone(),
        channel_name: loaded.manifest.channel_name.clone(),
        server_name: loaded.manifest.server_name.clone(),
        channels: channels_ffi.clone(),
    };

    Ok(ArchiveData {
        archive_type: loaded.manifest.archive_type,
        exporter_peer_id: loaded.manifest.exporter_peer_id,
        export_timestamp: loaded.manifest.export_timestamp,
        file_mode: loaded.manifest.file_mode,
        peer_id: loaded.manifest.peer_id,
        server_id: loaded.manifest.server_id,
        channel_id: loaded.manifest.channel_id,
        channel_name: loaded.manifest.channel_name,
        server_name: loaded.manifest.server_name,
        channels: loaded.manifest.channels.into_iter().map(|c| ArchiveChannelInfoFfi {
            channel_id: c.channel_id,
            channel_name: c.channel_name,
            message_count: c.message_count,
        }).collect(),
        participants: loaded.manifest.participants,
        messages,
        edits,
        deletions,
        reaction_removals,
        pubkeys,
        files,
        verification,
        files_dir: loaded.files_dir,
    })
}

// ── Shard export/import (Evidence Recovery Phase B) ─────────────

/// Result of importing a `.hollow-shards` bundle.
pub struct ShardImportResultFfi {
    pub server_id: String,
    pub manifests_imported: u32,
    pub shards_imported: u32,
    pub shards_skipped: u32,
    pub new_reconstructable: u32,
}

/// Export all vault shards for a server as a `.hollow-shards` ZIP bundle.
/// Contains manifest.json + shards/{content_id}/{shard_index}.shard files.
/// Returns the file size in bytes on success.
#[frb]
pub fn export_server_shards(
    server_id: String,
    output_path: String,
) -> Result<u64, String> {
    let hollow_dir = crate::identity::data_dir()?;
    let db_path = hollow_dir
        .join("messages.db")
        .to_str()
        .ok_or("Invalid path")?
        .to_string();

    let id = crate::identity::load_or_create_identity()?;
    let proto = id
        .keypair
        .to_protobuf_encoding()
        .map_err(|e| format!("Failed to encode keypair: {e}"))?;
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);

    let vault_dir = hollow_dir.join("vault");
    let content_store =
        crate::vault::content_store::ContentStore::open(&db_path, &passphrase, &vault_dir)
            .map_err(|e| format!("Failed to open content store: {e}"))?;

    let manifests = content_store.list_manifests(&server_id).unwrap_or_default();
    let shards = content_store.list_shards(&server_id).unwrap_or_default();

    // Build bundle manifest JSON.
    let manifests_json = serde_json::to_string(&manifests)
        .map_err(|e| format!("Failed to serialize manifests: {e}"))?;
    let bundle_manifest = serde_json::json!({
        "format_version": 1,
        "server_id": server_id,
        "exporter_peer_id": id.peer_id.to_string(),
        "timestamp": std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs(),
        "shard_count": shards.len(),
        "manifest_count": manifests.len(),
        "manifests": serde_json::from_str::<serde_json::Value>(&manifests_json)
            .unwrap_or(serde_json::Value::Array(vec![])),
    });
    let bundle_manifest_bytes = serde_json::to_vec_pretty(&bundle_manifest)
        .map_err(|e| format!("Failed to serialize bundle manifest: {e}"))?;

    // Write ZIP.
    let mut zip_buf = std::io::Cursor::new(Vec::new());
    {
        use std::io::Write;
        let mut zip = zip::ZipWriter::new(&mut zip_buf);
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);

        // manifest.json
        zip.start_file("manifest.json", options)
            .map_err(|e| format!("Zip error: {e}"))?;
        zip.write_all(&bundle_manifest_bytes)
            .map_err(|e| format!("Zip write error: {e}"))?;

        // shards/{content_id}/{shard_index}.shard
        for shard in &shards {
            let data = content_store
                .read_shard_unchecked(&server_id, &shard.shard_key);
            if let Ok(data) = data {
                let path = format!(
                    "shards/{}/{}.shard",
                    shard.content_id, shard.shard_index
                );
                zip.start_file(path, options)
                    .map_err(|e| format!("Zip error: {e}"))?;
                zip.write_all(&data)
                    .map_err(|e| format!("Zip write error: {e}"))?;
            }
        }

        zip.finish().map_err(|e| format!("Zip finish error: {e}"))?;
    }

    let bytes = zip_buf.into_inner();
    let size = bytes.len() as u64;
    std::fs::write(&output_path, &bytes)
        .map_err(|e| format!("Failed to write shards bundle: {e}"))?;
    Ok(size)
}

/// Import a `.hollow-shards` ZIP bundle. Stores new manifests and shards
/// that are not already present locally. Returns a summary of what was imported.
#[frb]
pub fn import_server_shards(archive_path: String) -> Result<ShardImportResultFfi, String> {
    use std::io::Read;

    let zip_bytes = std::fs::read(&archive_path)
        .map_err(|e| format!("Failed to read shards bundle: {e}"))?;

    let cursor = std::io::Cursor::new(&zip_bytes);
    let mut archive = zip::ZipArchive::new(cursor)
        .map_err(|e| format!("Failed to open ZIP: {e}"))?;

    // Read bundle manifest.
    let bundle_manifest: serde_json::Value = {
        let mut entry = archive
            .by_name("manifest.json")
            .map_err(|e| format!("Missing manifest.json: {e}"))?;
        let mut buf = Vec::new();
        entry
            .read_to_end(&mut buf)
            .map_err(|e| format!("Failed to read manifest.json: {e}"))?;
        serde_json::from_slice(&buf)
            .map_err(|e| format!("Invalid manifest.json: {e}"))?
    };

    let server_id = bundle_manifest["server_id"]
        .as_str()
        .ok_or("manifest.json missing server_id")?
        .to_string();

    // Open content store.
    let hollow_dir = crate::identity::data_dir()?;
    let db_path = hollow_dir
        .join("messages.db")
        .to_str()
        .ok_or("Invalid path")?
        .to_string();

    let id = crate::identity::load_or_create_identity()?;
    let proto = id
        .keypair
        .to_protobuf_encoding()
        .map_err(|e| format!("Failed to encode keypair: {e}"))?;
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);

    let vault_dir = hollow_dir.join("vault");
    let content_store =
        crate::vault::content_store::ContentStore::open(&db_path, &passphrase, &vault_dir)
            .map_err(|e| format!("Failed to open content store: {e}"))?;

    // Import manifests.
    let mut manifests_imported = 0u32;
    if let Some(manifests_arr) = bundle_manifest["manifests"].as_array() {
        for manifest_val in manifests_arr {
            if let Ok(manifest) =
                serde_json::from_value::<crate::vault::pipeline::VaultManifest>(
                    manifest_val.clone(),
                )
            {
                let _ = content_store.save_manifest(
                    &server_id,
                    &manifest.channel_id,
                    &manifest,
                );
                manifests_imported += 1;
            }
        }
    }

    // Import shards.
    let mut shards_imported = 0u32;
    let mut shards_skipped = 0u32;

    // Collect shard file names first (ZipArchive needs index-based access).
    let shard_entries: Vec<(String, usize)> = (0..archive.len())
        .filter_map(|i| {
            let name = archive.by_index(i).ok()?.name().to_string();
            if name.starts_with("shards/") && name.ends_with(".shard") {
                Some((name, i))
            } else {
                None
            }
        })
        .collect();

    for (name, idx) in &shard_entries {
        // Parse path: shards/{content_id}/{shard_index}.shard
        let parts: Vec<&str> = name.split('/').collect();
        if parts.len() != 3 {
            continue;
        }
        let cid = parts[1];
        let shard_index_str = parts[2].trim_end_matches(".shard");
        let shard_index: u16 = match shard_index_str.parse() {
            Ok(v) => v,
            Err(_) => continue,
        };

        // Check if we already have this shard.
        let shard_key = crate::vault::content_store::shard_key(cid, shard_index);
        if content_store.has_shard(&shard_key).unwrap_or(false) {
            shards_skipped += 1;
            continue;
        }

        // Read shard data from ZIP.
        let mut entry = match archive.by_index(*idx) {
            Ok(e) => e,
            Err(_) => continue,
        };
        let mut data = Vec::new();
        if entry.read_to_end(&mut data).is_err() {
            continue;
        }

        // We need k, m, total_data_size from the manifest for this content_id.
        // Try to find it in the bundle's manifests.
        let manifest_info = bundle_manifest["manifests"]
            .as_array()
            .and_then(|arr| {
                arr.iter().find(|m| m["content_id"].as_str() == Some(cid))
            });

        let (k, m, total_data_size, tier) = if let Some(m) = manifest_info {
            (
                m["k"].as_u64().unwrap_or(3) as u16,
                m["m"].as_u64().unwrap_or(2) as u16,
                m["original_size"].as_u64().unwrap_or(0),
                crate::vault::content_store::StorageTier::from_str(
                    m["storage_tier"].as_str().unwrap_or("standard"),
                ),
            )
        } else {
            // Fallback: skip shards without manifests.
            continue;
        };

        if content_store
            .store_shard(&server_id, cid, shard_index, k, m, total_data_size, tier, &data)
            .is_ok()
        {
            shards_imported += 1;
        }
    }

    // Count how many files are now newly reconstructable.
    let manifests = content_store.list_manifests(&server_id).unwrap_or_default();
    let mut new_reconstructable = 0u32;
    for manifest in &manifests {
        if manifest.k == 0 && manifest.m == 0 {
            continue;
        }
        let local = content_store
            .list_content_shards(&server_id, &manifest.content_id)
            .unwrap_or_default();
        if local.len() as u16 >= manifest.k {
            new_reconstructable += 1;
        }
    }

    Ok(ShardImportResultFfi {
        server_id,
        manifests_imported,
        shards_imported,
        shards_skipped,
        new_reconstructable,
    })
}
