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

/// Export a DM conversation as a `.hollow-archive` file.
/// `file_mode`: "full", "images_only", or "placeholder".
/// Returns the file size in bytes on success.
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

/// Export a channel conversation as a `.hollow-archive` file.
/// `file_mode`: "full", "images_only", or "placeholder".
/// Returns the file size in bytes on success.
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

/// Export all text channels of a server as a single `.hollow-archive` file.
/// `channels_json`: JSON array of `[{"channel_id": "...", "channel_name": "..."}]`.
/// `file_mode`: "full", "images_only", or "placeholder".
/// Returns the file size in bytes on success.
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

    // Parse channels JSON.
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

/// Load a `.hollow-archive` file for rendering in the POV viewer.
/// Full parse: returns all messages, edits, deletions, files, and verification results.
#[frb]
pub fn load_archive(archive_path: String) -> Result<ArchiveData, String> {
    let zip_bytes = std::fs::read(&archive_path)
        .map_err(|e| format!("Failed to read archive file: {e}"))?;

    let loaded = crate::archive::loader::load_archive(&zip_bytes)?;

    // Build per-message signature lookup.
    let sig_map: std::collections::HashMap<String, bool> = loaded
        .per_message_results
        .iter()
        .map(|v| (v.message_id.clone(), v.signature_valid))
        .collect();

    // Convert to FFI types.
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

    // Build verification summary.
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
