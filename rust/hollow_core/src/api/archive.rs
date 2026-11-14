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
    /// Album this message renders grouped into, `None` when standalone.
    pub album_id: Option<String>,
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
                album_id: m.album_id,
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

// What a shards bundle may unpack to. A shard is ciphertext, which never inflates, so
// one never unpacks past the bundle it rides in; the manifest is JSON and compresses,
// and a whole bundle gets a small multiple of its size, with a floor for a small one.
const SHARDS_MANIFEST_MAX: u64 = 16 << 20;
const SHARDS_MIN_UNPACKED: u64 = 64 << 20;
const SHARDS_UNPACK_RATIO: u64 = 4;
/// Entries a bundle's index may list: far more shards than a server's vault keeps.
const SHARDS_MAX_ENTRIES: u64 = 1 << 16;

/// A bundle every entry of which was measured: its manifest, and each shard entry's
/// `(name, index, bytes)`.
struct CheckedBundle<'a> {
    archive: zip::ZipArchive<std::io::Cursor<&'a [u8]>>,
    manifest: serde_json::Value,
    shards: Vec<(String, usize, u64)>,
}

/// Unpack the manifest and every shard into nothing under the bundle's bounds, so a
/// bundle that unpacks past them is refused before anything is stored.
fn check_shard_bundle(zip_bytes: &[u8]) -> Result<CheckedBundle<'_>, String> {
    let too_big = || "This shards bundle unpacks to far more than its size, so nothing was imported.".to_string();
    if let Some(reason) = crate::zip_budget::index_refused(zip_bytes, SHARDS_MAX_ENTRIES) {
        return Err(format!("Failed to open ZIP: {reason}"));
    }
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(zip_bytes))
        .map_err(|e| format!("Failed to open ZIP: {e}"))?;
    let bundle_len = zip_bytes.len() as u64;
    let mut budget = crate::zip_budget::UnpackBudget::new(
        bundle_len.saturating_mul(SHARDS_UNPACK_RATIO).max(SHARDS_MIN_UNPACKED),
    );
    let raw = {
        let entry = archive
            .by_name("manifest.json")
            .map_err(|e| format!("Missing manifest.json: {e}"))?;
        budget.read(entry, SHARDS_MANIFEST_MAX).map_err(|_| too_big())?
    };
    let manifest = serde_json::from_slice(&raw).map_err(|e| format!("Invalid manifest.json: {e}"))?;
    let mut shards = Vec::new();
    for i in 0..archive.len() {
        let entry = archive.by_index(i).map_err(|e| format!("Zip read error: {e}"))?;
        let Some(name) = entry.name().ok().map(|n| n.into_owned()) else { continue };
        if !(name.starts_with("shards/") && name.ends_with(".shard")) {
            continue;
        }
        let size = budget.measure(entry, bundle_len).map_err(|_| too_big())?;
        shards.push((name, i, size));
    }
    Ok(CheckedBundle { archive, manifest, shards })
}

/// The state of a server this device holds, as the store has it.
fn held_server_state(server_id: &str) -> Option<crate::crdt::server_state::ServerState> {
    let store = super::storage::get_store();
    let guard = store.lock().ok()?;
    let json = guard.as_ref()?.load_server_state(server_id).ok()??;
    serde_json::from_str(&json).ok()
}

/// Why a bundle's vault manifest may not be added, `None` when it may. A bundle names no
/// sender, so this is the live judgement (`vault_ops::ingest_vault_manifest`) without
/// one: a creator who is a member and sent the file card it backs, a channel of the
/// server we may read, never a restricted one (its files are never vaulted), and never
/// over a manifest we hold.
fn bundle_manifest_refused(
    state: &crate::crdt::server_state::ServerState,
    us: &str,
    cs: &crate::vault::content_store::ContentStore,
    manifest: &crate::vault::pipeline::VaultManifest,
) -> Option<&'static str> {
    let channel = manifest.channel_id.as_str();
    if !crate::vault::content_store::is_content_id(&manifest.content_id) {
        Some("malformed manifest")
    } else if !state.is_member(&crate::node::resolver::resolve(&manifest.creator_peer_id)) {
        Some("its creator is not a member of the server")
    } else if !state.channels.contains_key(channel) || !crate::node::crypto_handler::channel_readable_by(state, us, channel) {
        Some("a channel we cannot read")
    } else if state.channel_uses_subgroup(channel) {
        Some("a restricted channel's file is never vaulted")
    } else if !matches!(cs.manifest_home(&manifest.content_id), Ok(None)) {
        Some("we already hold a manifest for it")
    } else if !card_is_creators(&manifest.message_id, &manifest.creator_peer_id) {
        Some("we hold no file card from its creator for its message")
    } else {
        None
    }
}

/// Whether we hold a file card for `message_id` and every one was sent by `creator`: the
/// live relink rule, the closest a bundle without a sender gets to its creator.
fn card_is_creators(message_id: &str, creator: &str) -> bool {
    let store = super::storage::get_store();
    let Ok(guard) = store.lock() else { return false };
    let Some(senders) = guard.as_ref().filter(|_| !message_id.is_empty()).and_then(|ms| ms.file_senders_for_message(message_id).ok()) else {
        return false;
    };
    let creator = crate::node::resolver::resolve(creator);
    !senders.is_empty() && senders.iter().all(|sender| crate::node::resolver::resolve(sender) == creator)
}

/// Import a `.hollow-shards` ZIP bundle. Stores new manifests and shards
/// that are not already present locally. Returns a summary of what was imported.
#[frb]
pub fn import_server_shards(archive_path: String) -> Result<ShardImportResultFfi, String> {
    use std::io::Read;

    let zip_bytes = std::fs::read(&archive_path)
        .map_err(|e| format!("Failed to read shards bundle: {e}"))?;
    let CheckedBundle { mut archive, manifest: bundle_manifest, shards: shard_entries } =
        check_shard_bundle(&zip_bytes)?;

    let server_id = bundle_manifest["server_id"]
        .as_str()
        .ok_or("manifest.json missing server_id")?
        .to_string();

    let id = crate::identity::load_or_create_identity()?;
    let us = id.peer_id.to_string();
    // Members take manifests and shards under the live rules. A server we no longer hold
    // (the ex-member fallback bundles exist for) takes only shards our own held
    // manifests pin, so nothing the bundle says is believed.
    let states: std::collections::HashMap<_, _> =
        held_server_state(&server_id).filter(|state| state.is_member(&us)).map(|state| (server_id.clone(), state)).into_iter().collect();

    // Open content store.
    let hollow_dir = crate::identity::data_dir()?;
    let db_path = hollow_dir
        .join("messages.db")
        .to_str()
        .ok_or("Invalid path")?
        .to_string();
    let proto = id
        .keypair
        .to_protobuf_encoding()
        .map_err(|e| format!("Failed to encode keypair: {e}"))?;
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);

    let vault_dir = hollow_dir.join("vault");
    let content_store =
        crate::vault::content_store::ContentStore::open(&db_path, &passphrase, &vault_dir)
            .map_err(|e| format!("Failed to open content store: {e}"))?;

    let mut manifests_imported = 0u32;
    let offered = bundle_manifest["manifests"].as_array().into_iter().flatten();
    for manifest_val in offered.filter(|_| states.contains_key(&server_id)) {
        let Ok(manifest) = serde_json::from_value::<crate::vault::pipeline::VaultManifest>(manifest_val.clone()) else {
            continue;
        };
        if let Some(reason) = bundle_manifest_refused(&states[&server_id], &us, &content_store, &manifest) {
            crate::hollow_log!("[HOLLOW-SECURITY] Skipped bundle manifest {}: {reason}", manifest.content_id);
            continue;
        }
        if content_store.fill_manifest(&server_id, &manifest.channel_id, &manifest) == Ok(true) {
            manifests_imported += 1;
        }
    }

    let mut shards_imported = 0u32;
    let mut shards_skipped = 0u32;

    for (name, idx, size) in &shard_entries {
        // Parse path: shards/{content_id}/{shard_index}.shard
        let parts: Vec<&str> = name.split('/').collect();
        if parts.len() != 3 {
            continue;
        }
        let cid = parts[1];
        let Ok(shard_index) = parts[2].trim_end_matches(".shard").parse::<u16>() else {
            continue;
        };
        if content_store.has_shard(&crate::vault::content_store::shard_key(cid, shard_index)).unwrap_or(false) {
            shards_skipped += 1;
            continue;
        }
        // A shard rides the manifest WE hold for this server, never the bundle's word.
        let held = match content_store.manifest_home(cid) {
            Ok(Some((home, _, _))) if home == server_id => content_store.load_manifest(cid).ok().flatten(),
            _ => None,
        };
        let Some(held) = held else { continue };
        let write_refused = states.contains_key(&server_id).then(|| {
            crate::node::vault_ops::shard_write_refused(&states, &content_store, &us, &server_id, cid, shard_index, &us, *size)
        });
        if let Some(Some(reason)) = write_refused {
            crate::hollow_log!("[HOLLOW-SECURITY] Skipped bundle shard {shard_index} of {cid}: {reason}");
            continue;
        }
        let Ok(entry) = archive.by_index(*idx) else { continue };
        let mut data = Vec::new();
        if entry.take(*size).read_to_end(&mut data).is_err() {
            continue;
        }
        // An unasked copy lands only as the bytes its manifest pins.
        if let Some(reason) = crate::node::vault_ops::shard_bytes_refused(&content_store, cid, shard_index, &data, true) {
            crate::hollow_log!("[HOLLOW-SECURITY] Skipped bundle shard {shard_index} of {cid}: {reason}");
            continue;
        }
        let tier = crate::vault::content_store::StorageTier::from_str(&held.storage_tier);
        if content_store
            .store_shard(&server_id, cid, shard_index, held.k, held.m, held.original_size, tier, &data)
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

#[cfg(test)]
mod tests {
    // t14-zipbomb: how much a shards bundle may unpack to (HOL-SEC-205)

    use super::*;
    use sha2::{Digest, Sha256};
    use std::io::Write;

    struct Entry {
        name: String,
        bytes: Vec<u8>,
        deflated: bool,
    }

    fn deflated(name: &str, bytes: Vec<u8>) -> Entry {
        Entry { name: name.into(), bytes, deflated: true }
    }

    fn bundle_zip(entries: &[Entry]) -> Vec<u8> {
        let mut out = std::io::Cursor::new(Vec::new());
        let mut z = zip::ZipWriter::new(&mut out);
        for e in entries {
            let method = if e.deflated { zip::CompressionMethod::Deflated } else { zip::CompressionMethod::Stored };
            z.start_file(e.name.as_str(), zip::write::SimpleFileOptions::default().compression_method(method)).unwrap();
            z.write_all(&e.bytes).unwrap();
        }
        z.finish().unwrap();
        out.into_inner()
    }

    /// A bundle manifest naming `cids`, each a replicated (k = m = 0) item.
    fn manifest_for(cids: &[String]) -> Vec<u8> {
        let manifests: Vec<serde_json::Value> = cids
            .iter()
            .map(|c| serde_json::json!({"content_id": c, "k": 0, "m": 0, "original_size": 1, "storage_tier": "standard"}))
            .collect();
        serde_json::to_vec(&serde_json::json!({"format_version": 1, "server_id": "srv", "manifests": manifests})).unwrap()
    }

    fn cid(i: u8) -> String {
        hex::encode([i; 32])
    }

    fn noise(len: usize, seed: u8) -> Vec<u8> {
        let mut out = Vec::with_capacity(len + 32);
        let mut block = Sha256::digest([seed]).to_vec();
        while out.len() < len {
            block = Sha256::digest(&block).to_vec();
            out.extend_from_slice(&block);
        }
        out.truncate(len);
        out
    }

    // t14-zipbomb: what a shards bundle may write (HOL-SEC-206)

    const US: u8 = 5;
    const STRANGER: u8 = 9;

    /// A data root holding our identity and, in the store, server "srv" we own with
    /// channel `srv-general`; `secret` is a restricted channel of it.
    fn shard_root() -> (std::sync::MutexGuard<'static, ()>, std::sync::MutexGuard<'static, ()>, crate::test_tmp::TestDir) {
        shard_root_with(0, &[])
    }

    fn shard_root_pledging(pledge: u64) -> (std::sync::MutexGuard<'static, ()>, std::sync::MutexGuard<'static, ()>, crate::test_tmp::TestDir) {
        shard_root_with(pledge, &[])
    }

    /// [`shard_root`] with our storage pledge for "srv" (0 = no limit) and more members.
    fn shard_root_with(pledge: u64, members: &[u8]) -> (std::sync::MutexGuard<'static, ()>, std::sync::MutexGuard<'static, ()>, crate::test_tmp::TestDir) {
        let g = crate::node::resolver::test_lock();
        let s = crate::api::storage::store_test_lock();
        let work = crate::test_tmp::tempdir().unwrap();
        enter_root(&work);
        let (mut state, us) = crate::crdt::testkeys::owned_state("srv", "S", US);
        for op in [
            crate::crdt::operations::CrdtPayload::StoragePledgeChanged { peer_id: us, pledge_bytes: pledge },
            crate::crdt::operations::CrdtPayload::ChannelAdded { channel_id: "secret".into(), name: "secret".into(), category: None, channel_type: String::new() },
            crate::crdt::operations::CrdtPayload::ChannelVisibilityChanged { channel_id: "secret".into(), visibility: "admin".into() },
        ]
        .into_iter()
        .chain(members.iter().map(|&who| crate::crdt::operations::CrdtPayload::MemberAdded {
            peer_id: crate::crdt::testkeys::keys(who).1,
            display_name: "m".into(),
            follow: None,
            ask: None,
        })) {
            let op = state.create_op(op);
            state.apply_op(&op).unwrap();
        }
        let store = crate::storage::MessageStore::open(":memory:", &"ef".repeat(32)).unwrap();
        store.save_server_state("srv", &serde_json::to_string(&state).unwrap()).unwrap();
        let (theirs, _) = crate::crdt::testkeys::owned_state("theirs", "T", STRANGER);
        store.save_server_state("theirs", &serde_json::to_string(&theirs).unwrap()).unwrap();
        crate::api::storage::set_test_store(store);
        (g, s, work)
    }

    /// Point the data root at `work`, holding our identity.
    fn enter_root(work: &crate::test_tmp::TestDir) {
        // SAFETY: serialized by the locks `shard_root` takes.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", work.path()) };
        crate::identity::encryption::clear_session_key();
        let ours = crate::crdt::testkeys::keys(US).0;
        std::fs::write(work.path().join("identity.key"), ours.to_protobuf_encoding().unwrap()).unwrap();
    }

    /// The vault store of `work`, opened as the import opens it.
    fn vault_of(work: &crate::test_tmp::TestDir) -> crate::vault::content_store::ContentStore {
        let proto = crate::crdt::testkeys::keys(US).0.to_protobuf_encoding().unwrap();
        crate::vault::content_store::ContentStore::open(
            work.path().join("messages.db").to_str().unwrap(),
            &hex::encode(&proto[..32]),
            &work.path().join("vault"),
        )
        .unwrap()
    }

    /// A replicated vault item of `creator` in `channel`: its manifest and its one shard.
    fn item(seed: u8, creator: u8, channel: &str) -> (crate::vault::pipeline::VaultManifest, Vec<u8>) {
        let shard = noise(4096, seed);
        let manifest = crate::vault::pipeline::VaultManifest {
            content_id: crate::vault::content_store::content_id(&shard),
            encryption_key: hex::encode([seed; 32]),
            nonce: hex::encode([seed; 12]),
            original_size: 4080,
            k: 0,
            m: 0,
            shard_count: 0,
            file_name: format!("f{seed}.bin"),
            mime_type: "application/octet-stream".into(),
            storage_tier: "standard".into(),
            created_at: 1,
            creator_peer_id: crate::crdt::testkeys::keys(creator).1,
            channel_id: channel.into(),
            message_id: format!("m{seed}"),
            shard_hashes: Vec::new(),
        };
        (manifest, shard)
    }

    /// A file card for `m`'s message in the store, sent by `sender`.
    fn card_by(m: &crate::vault::pipeline::VaultManifest, sender: &str) {
        let store = crate::api::storage::get_store();
        let guard = store.lock().unwrap();
        let ctx = format!("srv:{}", m.channel_id);
        guard
            .as_ref()
            .unwrap()
            .insert_file_metadata(
                &m.content_id[..16], &m.file_name, "bin", &m.mime_type, m.original_size, 1, false, None, None,
                Some(&m.message_id), "channel", &ctx, sender, false, 1_000, None, None, None,
            )
            .unwrap();
    }

    /// The card of `m`'s message, from the creator it names.
    fn card(m: &crate::vault::pipeline::VaultManifest) {
        card_by(m, &m.creator_peer_id.clone());
    }

    fn bundle_of(sid: &str, items: &[(&crate::vault::pipeline::VaultManifest, &[u8])]) -> Vec<u8> {
        let manifest = serde_json::json!({"format_version": 1, "server_id": sid, "manifests": items.iter().map(|(m, _)| m).collect::<Vec<_>>()});
        let mut entries = vec![deflated("manifest.json", serde_json::to_vec(&manifest).unwrap())];
        entries.extend(items.iter().map(|(m, shard)| deflated(&format!("shards/{}/0.shard", m.content_id), shard.to_vec())));
        bundle_zip(&entries)
    }

    fn import(work: &crate::test_tmp::TestDir, bytes: &[u8]) -> Result<ShardImportResultFfi, String> {
        let path = work.path().join("b.hollow-shards");
        std::fs::write(&path, bytes).unwrap();
        import_server_shards(path.to_string_lossy().into_owned())
    }

    /// Shard files anywhere under the vault folder.
    fn shard_files(work: &crate::test_tmp::TestDir) -> usize {
        fn walk(dir: &std::path::Path) -> usize {
            std::fs::read_dir(dir).map_or(0, |d| {
                d.flatten()
                    .map(|e| if e.path().is_dir() { walk(&e.path()) } else { usize::from(e.path().extension().is_some_and(|x| x == "shard")) })
                    .sum()
            })
        }
        walk(&work.path().join("vault"))
    }

    #[test]
    fn a_bundle_whose_manifest_unpacks_past_its_cap_is_refused() {
        let (_g, _s, work) = shard_root();
        // Inside the bundle's whole budget, so only the manifest's own cap refuses it.
        let mut manifest = manifest_for(&[]);
        manifest.extend(std::iter::repeat_n(b' ', 32 << 20));
        let bytes = bundle_zip(&[deflated("manifest.json", manifest)]);
        assert!(bytes.len() < 128 << 10, "{}", bytes.len());
        assert!(import(&work, &bytes).is_err(), "a 32 MiB manifest was read whole");
    }

    #[test]
    fn a_shard_that_unpacks_past_its_bundle_refuses_the_bundle() {
        let (_g, _s, work) = shard_root();
        let c = cid(1);
        let bytes = bundle_zip(&[
            deflated("manifest.json", manifest_for(std::slice::from_ref(&c))),
            deflated(&format!("shards/{c}/0.shard"), vec![0u8; 8 << 20]),
        ]);
        assert!(import(&work, &bytes).is_err(), "a shard that compresses like text is not ciphertext");
        assert_eq!(shard_files(&work), 0, "a refused bundle stored a shard");
    }

    #[test]
    fn shards_together_stop_at_the_bundle_budget() {
        let (_g, _s, work) = shard_root();
        // Every shard stays within the bundle's own size, together they pass 64 MiB.
        let cids: Vec<String> = (0..70).map(cid).collect();
        let mut entries = vec![
            deflated("manifest.json", manifest_for(&cids)),
            Entry { name: "padding.bin".into(), bytes: noise(1 << 20, 9), deflated: false },
        ];
        entries.extend(cids.iter().map(|c| deflated(&format!("shards/{c}/0.shard"), vec![0u8; 1 << 20])));
        let bytes = bundle_zip(&entries);
        assert!(bytes.len() > 1 << 20 && bytes.len() < 2 << 20, "{}", bytes.len());
        assert!(import(&work, &bytes).is_err(), "70 MiB of shards from a bundle of {} bytes", bytes.len());
        assert_eq!(shard_files(&work), 0, "a refused bundle stored a shard");
    }

    #[test]
    fn a_bundle_for_a_server_we_do_not_hold_stores_nothing() {
        let (_g, _s, work) = shard_root();
        for sid in ["elsewhere", "theirs"] {
            let (mut m, shard) = item(1, US, "srv-general");
            m.channel_id = format!("{sid}-general");
            card(&m);
            let got = import(&work, &bundle_of(sid, &[(&m, &shard)])).unwrap();
            assert_eq!((got.manifests_imported, got.shards_imported), (0, 0), "a bundle for {sid} stored something");
            assert!(vault_of(&work).load_manifest(&m.content_id).unwrap().is_none(), "a manifest for {sid} was stored");
        }
        assert_eq!(shard_files(&work), 0, "a shard for a server we are not in was stored");
    }

    /// An ex-member (the server's row is gone, the fallback bundles exist for) takes back
    /// only the shards our OWN held manifests for that server pin, and no manifest.
    #[test]
    fn an_ex_members_bundle_restores_only_the_shards_of_manifests_it_holds() {
        let (_g, _s, work) = shard_root();
        let (held, held_shard) = item(1, US, "gone-general");
        let (junked, _) = item(2, US, "gone-general");
        let (other_home, other_shard) = item(3, US, "srv-general");
        let (unheld, unheld_shard) = item(4, US, "gone-general");
        card(&unheld);
        {
            let vault = vault_of(&work);
            vault.save_manifest("gone", "gone-general", &held).unwrap();
            vault.save_manifest("gone", "gone-general", &junked).unwrap();
            vault.save_manifest("srv", "srv-general", &other_home).unwrap();
        }
        let mut entries = vec![deflated(
            "manifest.json",
            serde_json::to_vec(&serde_json::json!({"server_id": "gone", "manifests": [&held, &unheld]})).unwrap(),
        )];
        entries.push(deflated(&format!("shards/{}/0.shard", held.content_id), held_shard.clone()));
        entries.push(deflated(&format!("shards/{}/0.shard", junked.content_id), noise(4096, 99)));
        entries.push(deflated(&format!("shards/{}/0.shard", other_home.content_id), other_shard));
        entries.push(deflated(&format!("shards/{}/0.shard", unheld.content_id), unheld_shard));
        let got = import(&work, &bundle_zip(&entries)).unwrap();
        assert_eq!(got.manifests_imported, 0, "an ex-member's bundle added a manifest");
        assert_eq!(got.shards_imported, 1);
        let vault = vault_of(&work);
        assert!(vault.load_manifest(&unheld.content_id).unwrap().is_none());
        assert_eq!(shard_files(&work), 1, "a shard no held manifest of that server pins was stored");
        let key = crate::vault::content_store::shard_key(&held.content_id, 0);
        assert_eq!(vault.read_shard("gone", &key).unwrap(), held_shard);
    }

    /// The review's case: a bundle names member X as the creator of Y's content; Y's own
    /// manifest must still land when Y sends it live.
    #[test]
    fn review_t14_a_bundle_manifest_cannot_squat_another_creators_content() {
        use crate::crdt::testkeys::keys;
        const X: u8 = 6;
        const Y: u8 = 7;
        let (_g, _s, work) = shard_root_with(0, &[X, Y]);
        let state: crate::crdt::server_state::ServerState = {
            let store = crate::api::storage::get_store();
            let guard = store.lock().unwrap();
            serde_json::from_str(&guard.as_ref().unwrap().load_server_state("srv").unwrap().unwrap()).unwrap()
        };
        assert!(state.is_member(&keys(X).1) && state.is_member(&keys(Y).1));
        let (real, shard) = item(1, Y, "srv-general");
        card(&real);
        let mut forged = real.clone();
        forged.creator_peer_id = keys(X).1;
        forged.encryption_key = hex::encode([0xee; 32]);
        import(&work, &bundle_of("srv", &[(&forged, &shard)])).unwrap();

        let proto = keys(US).0.to_protobuf_encoding().unwrap();
        let states = std::collections::HashMap::from([("srv".to_string(), state)]);
        crate::node::vault_ops::ingest_vault_manifest(
            &states,
            &keys(Y).1,
            "srv",
            "srv-general",
            &serde_json::to_string(&real).unwrap(),
            work.path().join("messages.db").to_str().unwrap(),
            &hex::encode(&proto[..32]),
        );
        let held = vault_of(&work).load_manifest(&real.content_id).unwrap().unwrap();
        assert_eq!(held.creator_peer_id, keys(Y).1, "a bundle's manifest naming member X held Y's content: Y's own manifest was refused");
    }

    #[test]
    fn a_fill_never_replaces_a_manifest_that_landed_first() {
        let (_g, _s, work) = shard_root();
        let (first, _) = item(1, US, "srv-general");
        let mut late = first.clone();
        late.encryption_key = hex::encode([0xee; 32]);
        let vault = vault_of(&work);
        assert!(vault.fill_manifest("srv", "srv-general", &first).unwrap());
        assert!(!vault.fill_manifest("srv", "srv-general", &late).unwrap(), "a fill over a held manifest counted as added");
        assert_eq!(vault.load_manifest(&first.content_id).unwrap().unwrap().encryption_key, first.encryption_key);
    }

    #[test]
    fn a_bundle_never_replaces_a_held_vault_manifest() {
        let (_g, _s, work) = shard_root();
        let (held, shard) = item(1, US, "srv-general");
        vault_of(&work).save_manifest("srv", "srv-general", &held).unwrap();
        let mut forged = held.clone();
        forged.encryption_key = hex::encode([0xee; 32]);
        forged.file_name = "other.exe".into();
        let got = import(&work, &bundle_of("srv", &[(&forged, &shard)])).unwrap();
        assert_eq!(got.manifests_imported, 0);
        let kept = vault_of(&work).load_manifest(&held.content_id).unwrap().unwrap();
        assert_eq!((kept.encryption_key, kept.file_name), (held.encryption_key, held.file_name), "a bundle replaced the held manifest");
    }

    #[test]
    fn a_bundle_shard_that_does_not_hash_to_its_manifest_is_not_stored() {
        let (_g, _s, work) = shard_root();
        let (m, _) = item(1, US, "srv-general");
        card(&m);
        let (orphan, orphan_shard) = item(2, US, "srv-general");
        let mut entries = vec![deflated(
            "manifest.json",
            serde_json::to_vec(&serde_json::json!({"server_id": "srv", "manifests": [&m]})).unwrap(),
        )];
        entries.push(deflated(&format!("shards/{}/0.shard", m.content_id), noise(4096, 77)));
        // No manifest of ours pins this one at all.
        entries.push(deflated(&format!("shards/{}/0.shard", orphan.content_id), orphan_shard));
        let got = import(&work, &bundle_zip(&entries)).unwrap();
        assert_eq!(got.manifests_imported, 1);
        assert_eq!(got.shards_imported, 0);
        assert_eq!(shard_files(&work), 0, "a shard its manifest does not name was stored");
    }

    #[test]
    fn a_bundle_manifest_is_judged_like_a_live_one() {
        let (_g, _s, work) = shard_root();
        let (good, good_shard) = item(1, US, "srv-general");
        let (stranger, s1) = item(2, STRANGER, "srv-general");
        let (restricted, s2) = item(3, US, "secret");
        let (nowhere, s3) = item(4, US, "no-such-channel");
        let (mut malformed, s4) = item(5, US, "srv-general");
        malformed.content_id = "../../x".into();
        for m in [&good, &stranger, &restricted, &nowhere] {
            card(m);
        }
        let (unseen, s5) = item(6, US, "srv-general");
        let (squat, s6) = item(7, US, "srv-general");
        card_by(&squat, &crate::crdt::testkeys::keys(STRANGER).1);
        let got = import(
            &work,
            &bundle_of("srv", &[(&good, &good_shard), (&stranger, &s1), (&restricted, &s2), (&nowhere, &s3), (&malformed, &s4), (&unseen, &s5), (&squat, &s6)]),
        )
        .unwrap();
        let vault = vault_of(&work);
        for (m, why) in [
            (&stranger, "its creator is not a member"),
            (&restricted, "a restricted channel's file"),
            (&nowhere, "a channel the server lacks"),
            (&unseen, "we hold no file card for its message"),
            (&squat, "its message's card is another member's"),
        ] {
            assert!(vault.load_manifest(&m.content_id).unwrap().is_none(), "a manifest was stored though {why}");
        }
        assert!(vault.load_manifest("../../x").unwrap().is_none(), "a manifest with a malformed content id was stored");
        assert!(vault.load_manifest(&good.content_id).unwrap().is_some());
        assert_eq!((got.manifests_imported, got.shards_imported), (1, 1));
        assert_eq!(shard_files(&work), 1);
    }

    #[test]
    fn a_bundle_shard_lands_only_under_the_server_its_manifest_names() {
        let (_g, _s, work) = shard_root();
        let (m, shard) = item(1, US, "srv-general");
        vault_of(&work).save_manifest("another", "another-general", &m).unwrap();
        let got = import(&work, &bundle_of("srv", &[(&m, &shard)])).unwrap();
        assert_eq!((got.manifests_imported, got.shards_imported), (0, 0));
        assert_eq!(shard_files(&work), 0, "a shard was stored under a server its manifest does not name");
    }

    #[test]
    fn a_bundle_shard_its_manifest_does_not_pin_is_not_stored() {
        let (_g, _s, work) = shard_root();
        // An erasure manifest from before shard hashes: it names no bytes for any shard.
        let (mut m, shard) = item(1, US, "srv-general");
        (m.k, m.m, m.shard_count) = (2, 1, 3);
        vault_of(&work).save_manifest("srv", "srv-general", &m).unwrap();
        let got = import(&work, &bundle_of("srv", &[(&m, &shard)])).unwrap();
        assert_eq!(got.shards_imported, 0, "a shard no manifest pins was stored");
        assert_eq!(shard_files(&work), 0);
    }

    #[test]
    fn a_bundle_stays_inside_our_storage_pledge() {
        let (_g, _s, work) = shard_root_pledging(1000);
        let (m, shard) = item(1, US, "srv-general");
        card(&m);
        let got = import(&work, &bundle_of("srv", &[(&m, &shard)])).unwrap();
        assert_eq!((got.manifests_imported, got.shards_imported), (1, 0), "a 4 KB shard passed a 1000-byte pledge");
        assert_eq!(shard_files(&work), 0);
    }

    #[test]
    fn a_bundle_listing_more_entries_than_a_bundle_holds_is_refused() {
        let (_g, _s, work) = shard_root();
        let manifest = serde_json::to_vec(&serde_json::json!({"server_id": "srv", "manifests": []})).unwrap();
        let fits = crate::zip_budget::zip_listing(SHARDS_MAX_ENTRIES as usize, "manifest.json", &manifest);
        assert!(import(&work, &fits).is_ok(), "an index at the bound was refused");
        let over = crate::zip_budget::zip_listing(SHARDS_MAX_ENTRIES as usize + 1, "manifest.json", &manifest);
        assert!(import(&work, &over).is_err(), "an index past the bound was parsed");
    }

    #[test]
    fn a_real_bundle_from_our_own_export_still_imports() {
        let (_g, _s, from) = shard_root();
        let (a, shard_a) = item(1, US, "srv-general");
        let (b, shard_b) = item(2, US, "srv-general");
        card(&a);
        card(&b);
        {
            let vault = vault_of(&from);
            for (m, shard) in [(&a, &shard_a), (&b, &shard_b)] {
                vault.save_manifest("srv", "srv-general", m).unwrap();
                vault
                    .store_shard("srv", &m.content_id, 0, 0, 0, m.original_size, crate::vault::content_store::StorageTier::Standard, shard)
                    .unwrap();
            }
        }
        let path = from.path().join("ours.hollow-shards");
        export_server_shards("srv".into(), path.to_string_lossy().into_owned()).unwrap();
        let bytes = std::fs::read(&path).unwrap();

        let to = crate::test_tmp::tempdir().unwrap();
        enter_root(&to);
        let got = import(&to, &bytes).unwrap();
        assert_eq!((got.manifests_imported, got.shards_imported), (2, 2));
        assert_eq!(shard_files(&to), 2);
        let vault = vault_of(&to);
        for (m, shard) in [(&a, &shard_a), (&b, &shard_b)] {
            assert_eq!(vault.load_manifest(&m.content_id).unwrap().unwrap().encryption_key, m.encryption_key);
            let key = crate::vault::content_store::shard_key(&m.content_id, 0);
            assert_eq!(&vault.read_shard("srv", &key).unwrap(), shard);
        }
    }
}
