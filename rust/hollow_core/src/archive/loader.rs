use std::collections::BTreeMap;
use std::io::Read;

use base64::Engine;
use sha2::{Digest, Sha256};

use crate::archive::types::*;
use crate::node::{message_signing_payload, verify_message_signature};

/// Load and verify a `.hollow-archive` zip from bytes.
///
/// Returns the full archive data with per-message and archive-level
/// signature verification results. Extracted file bytes (if any) are
/// written to a temp directory whose path is returned in `files_dir`.
pub(crate) fn load_archive(zip_bytes: &[u8]) -> Result<LoadedArchive, String> {
    let cursor = std::io::Cursor::new(zip_bytes);
    let mut archive = zip::ZipArchive::new(cursor)
        .map_err(|e| format!("Invalid archive: failed to open zip: {e}"))?;

    // ── 1. Read and parse manifest ──────────────────────────────
    let manifest: ArchiveManifest = {
        let mut entry = archive
            .by_name("manifest.json")
            .map_err(|_| "Invalid archive: missing manifest.json")?;
        let mut buf = Vec::new();
        entry.read_to_end(&mut buf)
            .map_err(|e| format!("Failed to read manifest.json: {e}"))?;
        serde_json::from_slice(&buf)
            .map_err(|e| format!("Invalid archive: malformed manifest.json: {e}"))?
    };

    if manifest.format_version != ARCHIVE_FORMAT_VERSION {
        return Err(format!(
            "Unsupported archive format version {} (expected {})",
            manifest.format_version, ARCHIVE_FORMAT_VERSION
        ));
    }

    // ── 2. Read pubkeys.json ────────────────────────────────────
    let pubkeys: Vec<ArchivePubKey> = match archive.by_name("pubkeys.json") {
        Ok(mut entry) => {
            let mut buf = Vec::new();
            entry.read_to_end(&mut buf)
                .map_err(|e| format!("Failed to read pubkeys.json: {e}"))?;
            serde_json::from_slice(&buf)
                .map_err(|e| format!("Invalid archive: malformed pubkeys.json: {e}"))?
        }
        Err(_) => Vec::new(),
    };

    // ── 3. Read all entry bytes for hash verification ───────────
    // We need the raw bytes of each entry to recompute the archive hash,
    // so read everything in one pass and parse afterwards.
    let mut manifest_bytes: Option<Vec<u8>> = None;
    let mut message_entries: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    let mut edit_entries: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    let mut deletion_entries: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    let mut removal_entries: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    let mut file_meta_entries: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    let mut file_data_entries: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    let mut archive_sig_bytes: Option<Vec<u8>> = None;

    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)
            .map_err(|e| format!("Failed to read zip entry {i}: {e}"))?;
        let name = entry.name().to_string();

        let mut buf = Vec::new();
        entry.read_to_end(&mut buf)
            .map_err(|e| format!("Failed to read zip entry '{name}': {e}"))?;

        if name == "manifest.json" {
            manifest_bytes = Some(buf);
        } else if name == "archive_signature.json" {
            archive_sig_bytes = Some(buf);
        } else if name == "pubkeys.json" {
            // Already parsed above, skip.
        } else if let Some(rest) = name.strip_prefix("messages/") {
            if let Some(mid) = rest.strip_suffix(".json") {
                message_entries.insert(mid.to_string(), buf);
            }
        } else if let Some(rest) = name.strip_prefix("edits/") {
            if let Some(mid) = rest.strip_suffix(".json") {
                edit_entries.insert(mid.to_string(), buf);
            }
        } else if let Some(rest) = name.strip_prefix("deletions/") {
            if let Some(mid) = rest.strip_suffix(".json") {
                deletion_entries.insert(mid.to_string(), buf);
            }
        } else if let Some(rest) = name.strip_prefix("reaction_removals/") {
            if let Some(mid) = rest.strip_suffix(".json") {
                removal_entries.insert(mid.to_string(), buf);
            }
        } else if let Some(rest) = name.strip_prefix("files/") {
            if rest.ends_with(".meta.json") {
                let fid = rest.strip_suffix(".meta.json").unwrap_or(rest).to_string();
                file_meta_entries.insert(fid, buf);
            } else {
                // Actual file bytes: key is "file_id.ext"
                file_data_entries.insert(rest.to_string(), buf);
            }
        }
    }

    // ── 4. Parse messages ───────────────────────────────────────
    let mut messages: Vec<ArchiveMessage> = Vec::new();
    let mut parse_warnings: Vec<String> = Vec::new();
    for (mid, json) in &message_entries {
        match serde_json::from_slice::<ArchiveMessage>(json) {
            Ok(msg) => messages.push(msg),
            Err(e) => {
                parse_warnings.push(format!("Skipped malformed message {mid}: {e}"));
                crate::hollow_log!("[archive] Skipped malformed message {mid}: {e}");
            }
        }
    }
    messages.sort_by_key(|m| m.timestamp);

    // ── 5. Parse edits ──────────────────────────────────────────
    let mut edits: Vec<ArchiveEdit> = Vec::new();
    for (mid, json) in &edit_entries {
        match serde_json::from_slice::<Vec<ArchiveEdit>>(json) {
            Ok(entries) => edits.extend(entries),
            Err(e) => {
                crate::hollow_log!("[archive] Skipped malformed edits for {mid}: {e}");
            }
        }
    }

    // ── 6. Parse deletions ──────────────────────────────────────
    let mut deletions: Vec<ArchiveDeletion> = Vec::new();
    for (mid, json) in &deletion_entries {
        match serde_json::from_slice::<Vec<ArchiveDeletion>>(json) {
            Ok(entries) => deletions.extend(entries),
            Err(e) => {
                crate::hollow_log!("[archive] Skipped malformed deletions for {mid}: {e}");
            }
        }
    }

    // ── 7. Parse reaction removals ──────────────────────────────
    let mut reaction_removals: Vec<ArchiveReactionRemoval> = Vec::new();
    for (mid, json) in &removal_entries {
        match serde_json::from_slice::<Vec<ArchiveReactionRemoval>>(json) {
            Ok(entries) => reaction_removals.extend(entries),
            Err(e) => {
                crate::hollow_log!("[archive] Skipped malformed reaction removals for {mid}: {e}");
            }
        }
    }

    // ── 8. Parse file metadata ──────────────────────────────────
    let mut file_metadata: Vec<ArchiveFileMetadata> = Vec::new();
    for json in file_meta_entries.values() {
        match serde_json::from_slice::<ArchiveFileMetadata>(json) {
            Ok(fm) => file_metadata.push(fm),
            Err(e) => {
                crate::hollow_log!("[archive] Skipped malformed file metadata: {e}");
            }
        }
    }

    // ── 9. Extract file bytes to temp dir ───────────────────────
    let files_dir = if !file_data_entries.is_empty() {
        let tmp = std::env::temp_dir().join(format!("hollow-archive-{}", export_timestamp_slug()));
        let _ = std::fs::create_dir_all(&tmp);
        for (name, bytes) in &file_data_entries {
            let path = tmp.join(name);
            let _ = std::fs::write(&path, bytes);
        }
        Some(tmp.to_string_lossy().to_string())
    } else {
        None
    };

    // ── 10. Per-message signature verification ──────────────────
    let msg_type = if manifest.archive_type == "dm" { "dm" } else { "ch" };
    // For single-channel archives, context is fixed.
    // For server (multi-channel) archives, context is per-message from channel_id.
    let fixed_context = if manifest.archive_type == "dm" {
        Some(manifest.peer_id.clone().unwrap_or_default())
    } else if manifest.archive_type == "channel" {
        Some(format!(
            "{}:{}",
            manifest.server_id.as_deref().unwrap_or(""),
            manifest.channel_id.as_deref().unwrap_or("")
        ))
    } else {
        None // Server archives use per-message context.
    };

    let mut per_message_results: Vec<MessageVerification> = Vec::new();
    for msg in &messages {
        let has_signature = msg.signature.is_some() && msg.public_key.is_some();

        let signature_valid = if has_signature {
            let context = if let Some(ref ctx) = fixed_context {
                ctx.clone()
            } else {
                // Server archive: context = "server_id:channel_id" from the message.
                format!(
                    "{}:{}",
                    manifest.server_id.as_deref().unwrap_or(""),
                    msg.channel_id.as_deref().unwrap_or("")
                )
            };
            // For edited messages, the main-row signature uses edited_at timestamp.
            let ts = msg.edited_at.unwrap_or(msg.timestamp);
            let payload = message_signing_payload(msg_type, &context, &msg.sender_id, ts, &msg.text);
            verify_message_signature(
                &msg.sender_id,
                msg.signature.as_deref(),
                msg.public_key.as_deref(),
                &payload,
            )
        } else {
            false
        };

        per_message_results.push(MessageVerification {
            message_id: msg.message_id.clone(),
            has_signature,
            signature_valid,
        });
    }

    // ── 11. Archive-level signature verification ────────────────
    let archive_signature_valid = if let Some(sig_bytes) = &archive_sig_bytes {
        match serde_json::from_slice::<ArchiveSignature>(sig_bytes) {
            Ok(arch_sig) => {
                // Recompute content hash from actual zip entry bytes.
                let file_hashes: BTreeMap<String, String> = file_metadata
                    .iter()
                    .map(|fm| {
                        let hash = if let Some(h) = &fm.sha256 {
                            h.clone()
                        } else {
                            "placeholder".to_string()
                        };
                        (fm.file_id.clone(), hash)
                    })
                    .collect();

                let manifest_raw = manifest_bytes.as_deref().unwrap_or(b"");
                let recomputed = compute_archive_hash(
                    manifest_raw,
                    &message_entries,
                    &edit_entries,
                    &deletion_entries,
                    &removal_entries,
                    &file_hashes,
                );
                let recomputed_hex = hex::encode(recomputed);

                if recomputed_hex != arch_sig.content_hash_hex {
                    crate::hollow_log!(
                        "[archive] Content hash mismatch: computed={recomputed_hex}, stored={}",
                        arch_sig.content_hash_hex
                    );
                    false
                } else {
                    // Verify the Ed25519 signature on the hash.
                    verify_archive_signature(
                        &arch_sig.exporter_peer_id,
                        &arch_sig.signature_b64,
                        &arch_sig.public_key_b64,
                        &recomputed,
                    )
                }
            }
            Err(e) => {
                crate::hollow_log!("[archive] Failed to parse archive_signature.json: {e}");
                false
            }
        }
    } else {
        crate::hollow_log!("[archive] Archive has no archive_signature.json");
        false
    };

    Ok(LoadedArchive {
        manifest,
        messages,
        edits,
        deletions,
        reaction_removals,
        pubkeys,
        file_metadata,
        files_dir,
        archive_signature_valid,
        per_message_results,
    })
}

/// Quick-verify an archive: parse, check signatures, return summary.
pub(crate) fn verify_archive(zip_bytes: &[u8]) -> Result<VerifyResult, String> {
    let loaded = load_archive(zip_bytes)?;

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

    Ok(VerifyResult {
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
        channels: loaded.manifest.channels.clone(),
    })
}

/// Recompute the archive-level hash (same algorithm as exporter).
fn compute_archive_hash(
    manifest_json: &[u8],
    message_jsons: &BTreeMap<String, Vec<u8>>,
    edit_jsons: &BTreeMap<String, Vec<u8>>,
    deletion_jsons: &BTreeMap<String, Vec<u8>>,
    removal_jsons: &BTreeMap<String, Vec<u8>>,
    file_hashes: &BTreeMap<String, String>,
) -> [u8; 32] {
    let mut hasher = Sha256::new();

    hasher.update(manifest_json);
    hasher.update(b"\n");

    for json in message_jsons.values() {
        let h = Sha256::digest(json);
        hasher.update(hex::encode(h).as_bytes());
        hasher.update(b"\n");
    }

    for json in edit_jsons.values() {
        let h = Sha256::digest(json);
        hasher.update(hex::encode(h).as_bytes());
        hasher.update(b"\n");
    }

    for json in deletion_jsons.values() {
        let h = Sha256::digest(json);
        hasher.update(hex::encode(h).as_bytes());
        hasher.update(b"\n");
    }

    for json in removal_jsons.values() {
        let h = Sha256::digest(json);
        hasher.update(hex::encode(h).as_bytes());
        hasher.update(b"\n");
    }

    for hash in file_hashes.values() {
        hasher.update(hash.as_bytes());
        hasher.update(b"\n");
    }

    hasher.finalize().into()
}

/// Verify an Ed25519 signature on the archive content hash.
fn verify_archive_signature(
    exporter_peer_id: &str,
    sig_b64: &str,
    pk_b64: &str,
    content_hash: &[u8; 32],
) -> bool {
    use crate::identity::native_identity::NativeKeypair;

    let Ok(pk_bytes) = base64::engine::general_purpose::STANDARD.decode(pk_b64) else {
        return false;
    };
    let Ok(sig_bytes) = base64::engine::general_purpose::STANDARD.decode(sig_b64) else {
        return false;
    };

    // Verify PeerId matches the public key.
    if pk_bytes.len() >= 36 && pk_bytes[0] == 0x08 && pk_bytes[1] == 0x01 {
        let mut multihash = Vec::with_capacity(2 + pk_bytes.len());
        multihash.push(0x00);
        multihash.push(pk_bytes.len() as u8);
        multihash.extend_from_slice(&pk_bytes);
        let derived_pid = bs58::encode(&multihash)
            .with_alphabet(bs58::Alphabet::BITCOIN)
            .into_string();
        if derived_pid != exporter_peer_id {
            return false;
        }
    } else {
        return false;
    }

    NativeKeypair::verify_peer_signature(&pk_bytes, &sig_bytes, content_hash).unwrap_or(false)
}

/// Generate a short timestamp slug for temp directory naming.
fn export_timestamp_slug() -> String {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .to_string()
}
