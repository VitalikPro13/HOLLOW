use std::collections::BTreeMap;
use std::io::Read;

use base64::Engine;
use sha2::{Digest, Sha256};

use crate::archive::types::*;

type ZipReader<'a> = zip::ZipArchive<std::io::Cursor<&'a [u8]>>;

// What an archive may unpack to in memory: its messages are JSON, which compresses a few
// times over, and its attachments barely compress. Archives come from other people.
const ARCHIVE_MIN_UNPACKED: u64 = 256 << 20;
const ARCHIVE_UNPACK_RATIO: u64 = 16;

/// Load and verify a `.hollow-archive` zip from bytes.
///
/// Returns the full archive data with per-message and archive-level
/// signature verification results. Extracted file bytes (if any) are
/// written to a temp directory whose path is returned in `files_dir`.
pub(crate) fn load_archive(zip_bytes: &[u8]) -> Result<LoadedArchive, String> {
    let cursor = std::io::Cursor::new(zip_bytes);
    let mut archive = zip::ZipArchive::new(cursor)
        .map_err(|e| format!("Invalid archive: failed to open zip: {e}"))?;

    let budget = (zip_bytes.len() as u64)
        .saturating_mul(ARCHIVE_UNPACK_RATIO)
        .max(ARCHIVE_MIN_UNPACKED);
    let entries = collect_entry_bytes(&mut archive, budget)?;

    let manifest = parse_manifest(entries.manifest_bytes.as_deref())?;

    if manifest.format_version != ARCHIVE_FORMAT_VERSION {
        return Err(format!(
            "Unsupported archive format version {} (expected {})",
            manifest.format_version, ARCHIVE_FORMAT_VERSION
        ));
    }

    let pubkeys = parse_pubkeys(entries.pubkeys_bytes.as_deref())?;

    let messages = parse_messages(&entries.message_entries);

    let edits: Vec<ArchiveEdit> = parse_entry_lists(&entries.edit_entries, "edits");

    let deletions: Vec<ArchiveDeletion> = parse_entry_lists(&entries.deletion_entries, "deletions");

    let reaction_removals: Vec<ArchiveReactionRemoval> =
        parse_entry_lists(&entries.removal_entries, "reaction removals");

    let mut file_metadata = parse_file_metadata(&entries.file_meta_entries);

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

    // The viewer opens `{files_dir}/{file_id}.{file_ext}`: only a file that landed there
    // under exactly that name is included.
    for fm in &mut file_metadata {
        fm.included = fm.included && entries.file_data_entries.contains_key(&format!("{}.{}", fm.file_id, fm.file_ext));
    }

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

/// Parse `manifest.json`.
fn parse_manifest(bytes: Option<&[u8]>) -> Result<ArchiveManifest, String> {
    let bytes = bytes.ok_or("Invalid archive: missing manifest.json")?;
    serde_json::from_slice(bytes)
        .map_err(|e| format!("Invalid archive: malformed manifest.json: {e}"))
}

/// Parse `pubkeys.json` (missing = empty list).
fn parse_pubkeys(bytes: Option<&[u8]>) -> Result<Vec<ArchivePubKey>, String> {
    match bytes {
        Some(bytes) => serde_json::from_slice(bytes)
            .map_err(|e| format!("Invalid archive: malformed pubkeys.json: {e}")),
        None => Ok(Vec::new()),
    }
}

/// Raw bytes of every zip entry, grouped by kind.
#[derive(Default)]
struct ArchiveEntries {
    manifest_bytes: Option<Vec<u8>>,
    pubkeys_bytes: Option<Vec<u8>>,
    message_entries: BTreeMap<String, Vec<u8>>,
    edit_entries: BTreeMap<String, Vec<u8>>,
    deletion_entries: BTreeMap<String, Vec<u8>>,
    removal_entries: BTreeMap<String, Vec<u8>>,
    file_meta_entries: BTreeMap<String, Vec<u8>>,
    /// Attachment bytes by the name they land under (`file_id.ext`).
    file_data_entries: BTreeMap<String, Vec<u8>>,
    archive_sig_bytes: Option<Vec<u8>>,
}

/// Read the raw bytes of every zip entry, grouped by kind, all of them together within
/// `budget` bytes.
///
/// We need the raw bytes of each entry to recompute the archive hash,
/// so read everything in one pass and parse afterwards.
fn collect_entry_bytes(archive: &mut ZipReader<'_>, budget: u64) -> Result<ArchiveEntries, String> {
    let mut entries = ArchiveEntries::default();
    let mut left = budget;

    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)
            .map_err(|e| format!("Failed to read zip entry {i}: {e}"))?;
        let name = entry.name().to_string();
        let landing = attachment_landing(&entry);

        let mut buf = Vec::new();
        (&mut entry).take(left.saturating_add(1)).read_to_end(&mut buf)
            .map_err(|e| format!("Failed to read zip entry '{name}': {e}"))?;
        left = left
            .checked_sub(buf.len() as u64)
            .ok_or("This archive unpacks to far more than its size, so it was not opened.")?;

        classify_entry(&mut entries, &name, landing, buf);
    }

    Ok(entries)
}

/// The name an attachment lands under in the viewer's folder: one inert component under
/// `files/`, read only through `enclosed_name`. Any other entry is never written.
fn attachment_landing(entry: &zip::read::ZipFile<'_>) -> Option<String> {
    use std::path::Component;
    let path = entry.enclosed_name()?;
    let mut parts = path.components();
    match (parts.next(), parts.next(), parts.next()) {
        (Some(Component::Normal(dir)), Some(Component::Normal(leaf)), None) if dir == "files" => leaf
            .to_str()
            .filter(|leaf| crate::node::share_handler::is_inert_file_name(leaf))
            .map(str::to_string),
        _ => None,
    }
}

/// Route one zip entry's bytes into the right bucket by path.
fn classify_entry(entries: &mut ArchiveEntries, name: &str, landing: Option<String>, buf: Vec<u8>) {
    if name == "manifest.json" {
        entries.manifest_bytes = Some(buf);
    } else if name == "archive_signature.json" {
        entries.archive_sig_bytes = Some(buf);
    } else if name == "pubkeys.json" {
        entries.pubkeys_bytes = Some(buf);
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
        } else if let Some(landing) = landing {
            entries.file_data_entries.insert(landing, buf);
        } else {
            crate::hollow_log!("[archive] Skipped an attachment named outside the archive's files");
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
            album: msg.album_id.as_deref(),
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

    if NativeKeypair::peer_id_from_pubkey_protobuf(&pk_bytes).as_deref() != Some(exporter_peer_id) {
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn archive_of(entries: &[(String, Vec<u8>)]) -> Vec<u8> {
        let manifest = serde_json::json!({
            "format_version": ARCHIVE_FORMAT_VERSION,
            "archive_type": "dm",
            "exporter_peer_id": "",
            "export_timestamp": 0,
            "message_count": 0,
            "file_mode": "full",
            "participants": [],
        });
        let mut out = std::io::Cursor::new(Vec::new());
        let mut z = zip::ZipWriter::new(&mut out);
        let manifest = ("manifest.json".to_string(), serde_json::to_vec(&manifest).unwrap());
        for (name, bytes) in std::iter::once(&manifest).chain(entries) {
            z.start_file(name.as_str(), zip::write::SimpleFileOptions::default()).unwrap();
            z.write_all(bytes).unwrap();
        }
        z.finish().unwrap();
        out.into_inner()
    }

    fn meta(file_id: &str, ext: &str) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "file_id": file_id, "file_name": "x", "file_ext": ext, "mime_type": "image/png",
            "size_bytes": 5, "is_image": true, "included": true,
        }))
        .unwrap()
    }

    /// C-LOCAL-01 (the archive twin of C-IDENTITY-01). An archive someone sends lands
    /// its attachments only in the viewer's own folder, under names an export makes,
    /// and the viewer is pointed only at what landed there.
    #[test]
    fn an_archive_lands_attachments_only_in_its_own_folder() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let escaped_name = format!("hollow-archive-escape-{}.bin", std::process::id());
        let escaped = std::env::temp_dir().join(&escaped_name);
        let _ = std::fs::remove_file(&escaped);
        let loaded = load_archive(&archive_of(&[
            (format!("files/../{escaped_name}"), b"planted".to_vec()),
            ("files/ab12.png".to_string(), b"image".to_vec()),
            ("files/ab12.meta.json".to_string(), meta("ab12", "png")),
            ("files/evil.meta.json".to_string(), meta("../../evil", "png")),
        ]));
        let escaped_landed = escaped.exists();
        let _ = std::fs::remove_file(&escaped);
        assert!(!escaped_landed, "a relative name wrote out of the viewer's folder");
        let loaded = loaded.expect("an archive with one bad name still opens");
        let dir = std::path::PathBuf::from(loaded.files_dir.clone().expect("the genuine file landed"));
        let landed = std::fs::read(dir.join("ab12.png"));
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(landed.unwrap(), b"image");
        let included: BTreeMap<&str, bool> =
            loaded.file_metadata.iter().map(|f| (f.file_id.as_str(), f.included)).collect();
        assert_eq!(included.get("ab12"), Some(&true));
        assert_eq!(included.get("../../evil"), Some(&false), "the viewer was pointed out of its folder");

        let absolute = tmp.path().join("absolute.bin");
        let loaded = load_archive(&archive_of(&[(format!("files/{}", absolute.display()), b"planted".to_vec())]));
        if let Ok(LoadedArchive { files_dir: Some(dir), .. }) = &loaded {
            let _ = std::fs::remove_dir_all(dir);
        }
        assert!(!absolute.exists(), "an absolute name wrote where it pointed");

        // `D:name` is relative to drive D's current folder: a join drops the base for it.
        #[cfg(windows)]
        {
            let cwd = std::env::current_dir().unwrap();
            let drive = &cwd.to_str().unwrap()[..2];
            let leaf = format!("hollow-drive-escape-{}.bin", std::process::id());
            let loaded = load_archive(&archive_of(&[(format!("files/{drive}{leaf}"), b"planted".to_vec())]));
            if let Ok(LoadedArchive { files_dir: Some(dir), .. }) = &loaded {
                let _ = std::fs::remove_dir_all(dir);
            }
            let escaped = cwd.join(&leaf).exists();
            let _ = std::fs::remove_file(cwd.join(&leaf));
            assert!(!escaped, "a drive-relative name wrote into the current folder");
        }
    }

    /// An archive unpacks to no more than a real one could from its size, so a small
    /// file never fills the viewer's memory.
    #[test]
    fn an_archive_that_unpacks_past_its_size_is_refused() {
        let zeros = {
            let mut one = std::io::Cursor::new(Vec::new());
            let mut z = zip::ZipWriter::new(&mut one);
            z.start_file("z", zip::write::SimpleFileOptions::default()).unwrap();
            z.write_all(&vec![0u8; 8 << 20]).unwrap();
            z.finish().unwrap();
            one.into_inner()
        };
        let mut src = zip::ZipArchive::new(std::io::Cursor::new(zeros)).unwrap();
        let mut bomb = std::io::Cursor::new(archive_of(&[]));
        {
            let mut z = zip::ZipWriter::new_append(&mut bomb).unwrap();
            for i in 0..40 {
                z.raw_copy_file_rename(src.by_index(0).unwrap(), format!("messages/m{i}.json")).unwrap();
            }
            z.finish().unwrap();
        }
        let bomb = bomb.into_inner();
        assert!(bomb.len() < 1 << 20, "the test bomb is {} bytes", bomb.len());
        assert!(load_archive(&bomb).is_err(), "320 MiB unpacked from a small archive");
    }

    /// C-OLM-06: an exporter key with bytes after the key names an alias id the
    /// exporter never had, so the archive must not verify under it.
    #[test]
    fn an_archive_signed_under_a_padded_key_never_verifies() {
        let kp = crate::identity::native_identity::NativeKeypair::from_secret_bytes(&[5u8; 32]);
        let hash = [9u8; 32];
        let sig = base64::engine::general_purpose::STANDARD.encode(kp.sign(&hash));
        let pk = |bytes: &[u8]| base64::engine::general_purpose::STANDARD.encode(bytes);
        assert!(verify_archive_signature(&kp.peer_id(), &sig, &pk(&kp.public_key_protobuf()), &hash), "control");

        let mut long = kp.public_key_protobuf();
        long.push(0);
        let mut multihash = vec![0x00, long.len() as u8];
        multihash.extend_from_slice(&long);
        let alias = bs58::encode(&multihash).with_alphabet(bs58::Alphabet::BITCOIN).into_string();
        assert!(!verify_archive_signature(&alias, &sig, &pk(&long), &hash));
    }
}
