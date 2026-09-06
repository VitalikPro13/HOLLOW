use std::collections::BTreeMap;
use std::io::Read;

use base64::Engine;
use sha2::{Digest, Sha256};

use crate::archive::types::*;

type ZipReader<'a> = zip::ZipArchive<std::io::Cursor<&'a [u8]>>;

/// Load and verify a `.hollow-archive` zip from bytes.
///
/// Returns the full archive data with per-message and archive-level
/// signature verification results. Extracted file bytes (if any) are
/// written to a temp directory whose path is returned in `files_dir`.
pub(crate) fn load_archive(zip_bytes: &[u8]) -> Result<LoadedArchive, String> {
    let cursor = std::io::Cursor::new(zip_bytes);
    let mut archive = zip::ZipArchive::new(cursor)
        .map_err(|e| format!("Invalid archive: failed to open zip: {e}"))?;

    let manifest = read_manifest(&mut archive)?;

    if manifest.format_version != ARCHIVE_FORMAT_VERSION {
        return Err(format!(
            "Unsupported archive format version {} (expected {})",
            manifest.format_version, ARCHIVE_FORMAT_VERSION
        ));
    }

    let pubkeys = read_pubkeys(&mut archive)?;

    let entries = collect_entry_bytes(&mut archive)?;

    let messages = parse_messages(&entries.message_entries);

    let edits: Vec<ArchiveEdit> = parse_entry_lists(&entries.edit_entries, "edits");

    let deletions: Vec<ArchiveDeletion> = parse_entry_lists(&entries.deletion_entries, "deletions");

    let reaction_removals: Vec<ArchiveReactionRemoval> =
        parse_entry_lists(&entries.removal_entries, "reaction removals");

    let file_metadata = parse_file_metadata(&entries.file_meta_entries);

    let files_dir = extract_files_to_temp(&entries.file_data_entries);

    let msg_type = if manifest.archive_type == "dm" { "dm" } else { "ch" };
    let is_dm = manifest.archive_type == "dm";
    let dm_peer = manifest.peer_id.clone().unwrap_or_default();
    let dm_exporter = manifest.exporter_peer_id.clone();

    let mut per_message_results: Vec<MessageVerification> = Vec::new();
    for msg in &messages {
        per_message_results.push(verify_one_message(
            msg,
            &manifest,
            msg_type,
            is_dm,
            &dm_peer,
            &dm_exporter,
        ));
    }

    let archive_signature_valid = verify_archive_level_signature(&entries, &file_metadata);

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

/// Read and parse `manifest.json` from the zip.
fn read_manifest(archive: &mut ZipReader<'_>) -> Result<ArchiveManifest, String> {
    let mut entry = archive
        .by_name("manifest.json")
        .map_err(|_| "Invalid archive: missing manifest.json")?;
    let mut buf = Vec::new();
    entry.read_to_end(&mut buf)
        .map_err(|e| format!("Failed to read manifest.json: {e}"))?;
    serde_json::from_slice(&buf)
        .map_err(|e| format!("Invalid archive: malformed manifest.json: {e}"))
}

/// Read and parse `pubkeys.json` from the zip (missing = empty list).
fn read_pubkeys(archive: &mut ZipReader<'_>) -> Result<Vec<ArchivePubKey>, String> {
    match archive.by_name("pubkeys.json") {
        Ok(mut entry) => {
            let mut buf = Vec::new();
            entry.read_to_end(&mut buf)
                .map_err(|e| format!("Failed to read pubkeys.json: {e}"))?;
            serde_json::from_slice(&buf)
                .map_err(|e| format!("Invalid archive: malformed pubkeys.json: {e}"))
        }
        Err(_) => Ok(Vec::new()),
    }
}

/// Raw bytes of every zip entry, grouped by kind.
#[derive(Default)]
struct ArchiveEntries {
    manifest_bytes: Option<Vec<u8>>,
    message_entries: BTreeMap<String, Vec<u8>>,
    edit_entries: BTreeMap<String, Vec<u8>>,
    deletion_entries: BTreeMap<String, Vec<u8>>,
    removal_entries: BTreeMap<String, Vec<u8>>,
    file_meta_entries: BTreeMap<String, Vec<u8>>,
    file_data_entries: BTreeMap<String, Vec<u8>>,
    archive_sig_bytes: Option<Vec<u8>>,
}

/// Read the raw bytes of every zip entry, grouped by kind.
///
/// We need the raw bytes of each entry to recompute the archive hash,
/// so read everything in one pass and parse afterwards.
fn collect_entry_bytes(archive: &mut ZipReader<'_>) -> Result<ArchiveEntries, String> {
    let mut entries = ArchiveEntries::default();

    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)
            .map_err(|e| format!("Failed to read zip entry {i}: {e}"))?;
        let name = entry.name().to_string();

        let mut buf = Vec::new();
        entry.read_to_end(&mut buf)
            .map_err(|e| format!("Failed to read zip entry '{name}': {e}"))?;

        classify_entry(&mut entries, &name, buf);
    }

    Ok(entries)
}

/// Route one zip entry's bytes into the right bucket by path.
fn classify_entry(entries: &mut ArchiveEntries, name: &str, buf: Vec<u8>) {
    if name == "manifest.json" {
        entries.manifest_bytes = Some(buf);
    } else if name == "archive_signature.json" {
        entries.archive_sig_bytes = Some(buf);
    } else if name == "pubkeys.json" {
        // Already parsed above, skip.
    } else if let Some(mid) = strip_json_entry(name, "messages/") {
        entries.message_entries.insert(mid.to_string(), buf);
    } else if let Some(mid) = strip_json_entry(name, "edits/") {
        entries.edit_entries.insert(mid.to_string(), buf);
    } else if let Some(mid) = strip_json_entry(name, "deletions/") {
        entries.deletion_entries.insert(mid.to_string(), buf);
    } else if let Some(mid) = strip_json_entry(name, "reaction_removals/") {
        entries.removal_entries.insert(mid.to_string(), buf);
    } else if let Some(rest) = name.strip_prefix("files/") {
        if rest.ends_with(".meta.json") {
            let fid = rest.strip_suffix(".meta.json").unwrap_or(rest).to_string();
            entries.file_meta_entries.insert(fid, buf);
        } else {
            // Actual file bytes: key is "file_id.ext"
            entries.file_data_entries.insert(rest.to_string(), buf);
        }
    }
}

/// `"{prefix}{mid}.json"` → `Some(mid)`; anything else → `None`.
fn strip_json_entry<'a>(name: &'a str, prefix: &str) -> Option<&'a str> {
    name.strip_prefix(prefix)?.strip_suffix(".json")
}

/// Parse message JSONs, skipping malformed entries, sorted by timestamp.
fn parse_messages(message_entries: &BTreeMap<String, Vec<u8>>) -> Vec<ArchiveMessage> {
    let mut messages: Vec<ArchiveMessage> = Vec::new();
    let mut parse_warnings: Vec<String> = Vec::new();
    for (mid, json) in message_entries {
        match serde_json::from_slice::<ArchiveMessage>(json) {
            Ok(msg) => messages.push(msg),
            Err(e) => {
                parse_warnings.push(format!("Skipped malformed message {mid}: {e}"));
                crate::hollow_log!("[archive] Skipped malformed message {mid}: {e}");
            }
        }
    }
    messages.sort_by_key(|m| m.timestamp);
    messages
}

/// Parse per-message JSON arrays (edits / deletions / reaction removals),
/// skipping malformed entries with a log line.
fn parse_entry_lists<T: serde::de::DeserializeOwned>(
    entries: &BTreeMap<String, Vec<u8>>,
    kind: &str,
) -> Vec<T> {
    let mut items: Vec<T> = Vec::new();
    for (mid, json) in entries {
        match serde_json::from_slice::<Vec<T>>(json) {
            Ok(parsed) => items.extend(parsed),
            Err(e) => {
                crate::hollow_log!("[archive] Skipped malformed {kind} for {mid}: {e}");
            }
        }
    }
    items
}

/// Parse file metadata JSONs, skipping malformed entries.
fn parse_file_metadata(file_meta_entries: &BTreeMap<String, Vec<u8>>) -> Vec<ArchiveFileMetadata> {
    let mut file_metadata: Vec<ArchiveFileMetadata> = Vec::new();
    for json in file_meta_entries.values() {
        match serde_json::from_slice::<ArchiveFileMetadata>(json) {
            Ok(fm) => file_metadata.push(fm),
            Err(e) => {
                crate::hollow_log!("[archive] Skipped malformed file metadata: {e}");
            }
        }
    }
    file_metadata
}

/// Write extracted file bytes to a temp directory; returns its path
/// (or `None` when the archive contains no file bytes).
fn extract_files_to_temp(file_data_entries: &BTreeMap<String, Vec<u8>>) -> Option<String> {
    if file_data_entries.is_empty() {
        return None;
    }
    let tmp = std::env::temp_dir().join(format!("hollow-archive-{}", export_timestamp_slug()));
    let _ = std::fs::create_dir_all(&tmp);
    for (name, bytes) in file_data_entries {
        let path = tmp.join(name);
        let _ = std::fs::write(&path, bytes);
    }
    Some(tmp.to_string_lossy().to_string())
}

/// Verify a single message's Ed25519 signature against its signing payload.
fn verify_one_message(
    msg: &ArchiveMessage,
    manifest: &ArchiveManifest,
    msg_type: &str,
    is_dm: bool,
    dm_peer: &str,
    dm_exporter: &str,
) -> MessageVerification {
    let has_signature = msg.signature.is_some() && msg.public_key.is_some();

    let signature_valid = if has_signature {
        let context = message_signing_context(msg, manifest, is_dm, dm_peer, dm_exporter);
        // For edited messages, the main-row signature uses edited_at timestamp.
        let ts = msg.edited_at.unwrap_or(msg.timestamp);
        // v2 only (0.8.5): a pre-0.8.3 archive row reports unverified rather
        // than falling back to the text-only v1 payload, which left the archive's
        // reply_to / file_id / order_us free to be edited in the export.
        // Edit signatures bind the same full extras as originals,
        // so the edited branch differs only in the timestamp above.
        let extras = crate::node::crypto_handler::SignedExtras {
            mid: Some(&msg.message_id),
            reply_to: msg.reply_to_mid.as_deref(),
            file_id: msg.file_id.as_deref(),
            order_us: msg.order_us,
            lp_digest: msg.lp_digest.as_deref(),
        };
        crate::node::crypto_handler::verify_message_signature_v2(
            &msg.sender_id,
            msg.signature.as_deref(),
            msg.public_key.as_deref(),
            msg_type,
            &context,
            ts,
            &extras,
            &msg.text,
            &mut crate::node::crypto_handler::PkCache::new(),
        )
    } else {
        false
    };

    MessageVerification {
        message_id: msg.message_id.clone(),
        has_signature,
        signature_valid,
    }
}

/// Reconstruct the signing context a message was originally signed under.
fn message_signing_context(
    msg: &ArchiveMessage,
    manifest: &ArchiveManifest,
    is_dm: bool,
    dm_peer: &str,
    dm_exporter: &str,
) -> String {
    if is_dm {
        // DM signing context = the recipient's peer ID.
        // If the exporter sent this message, recipient = dm_peer.
        // If the exporter received it, recipient = exporter.
        if msg.sender_id == dm_exporter {
            dm_peer.to_string()
        } else {
            dm_exporter.to_string()
        }
    } else if manifest.archive_type == "channel" {
        format!(
            "{}:{}",
            manifest.server_id.as_deref().unwrap_or(""),
            manifest.channel_id.as_deref().unwrap_or("")
        )
    } else {
        // Server archive: context = "server_id:channel_id" from the message.
        format!(
            "{}:{}",
            manifest.server_id.as_deref().unwrap_or(""),
            msg.channel_id.as_deref().unwrap_or("")
        )
    }
}

/// Recompute the archive content hash from the stored entry bytes and
/// verify the exporter's Ed25519 signature over it.
fn verify_archive_level_signature(
    entries: &ArchiveEntries,
    file_metadata: &[ArchiveFileMetadata],
) -> bool {
    let Some(sig_bytes) = &entries.archive_sig_bytes else {
        crate::hollow_log!("[archive] Archive has no archive_signature.json");
        return false;
    };

    let arch_sig = match serde_json::from_slice::<ArchiveSignature>(sig_bytes) {
        Ok(arch_sig) => arch_sig,
        Err(e) => {
            crate::hollow_log!("[archive] Failed to parse archive_signature.json: {e}");
            return false;
        }
    };

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

    let manifest_raw = entries.manifest_bytes.as_deref().unwrap_or(b"");
    let recomputed = compute_archive_hash(
        manifest_raw,
        &entries.message_entries,
        &entries.edit_entries,
        &entries.deletion_entries,
        &entries.removal_entries,
        &file_hashes,
    );
    let recomputed_hex = hex::encode(recomputed);

    if recomputed_hex != arch_sig.content_hash_hex {
        crate::hollow_log!(
            "[archive] Content hash mismatch: computed={recomputed_hex}, stored={}",
            arch_sig.content_hash_hex
        );
        return false;
    }

    // Verify the Ed25519 signature on the hash.
    verify_archive_signature(
        &arch_sig.exporter_peer_id,
        &arch_sig.signature_b64,
        &arch_sig.public_key_b64,
        &recomputed,
    )
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
