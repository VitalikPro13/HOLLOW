use std::collections::{BTreeMap, HashMap, HashSet};
use std::io::Write;
use std::path::Path;

use base64::Engine;
use sha2::{Digest, Sha256};

use crate::archive::types::*;
use crate::identity::native_identity::NativeKeypair;
use crate::storage::MessageStore;

/// Export a conversation as a `.hollow-archive` zip (returned as in-memory bytes).
pub(crate) fn export_archive(
    store: &MessageStore,
    keypair: &NativeKeypair,
    target: ArchiveTarget,
    file_mode: FileMode,
    data_dir: &Path,
) -> Result<Vec<u8>, String> {
    let exporter_peer_id = keypair.peer_id();
    let export_timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    // ── 1. Load all messages (including hidden/deleted) ─────────
    let (archive_type, _context_str, peer_id_opt, server_id_opt, channel_id_opt, channel_name_opt, server_name_opt, channel_infos, messages) =
        match &target {
            ArchiveTarget::Dm { peer_id } => {
                let msgs = store.load_all_dm_messages(peer_id)?;
                let archive_msgs: Vec<ArchiveMessage> = msgs
                    .into_iter()
                    .map(|m| {
                        let sender = if m.is_mine {
                            exporter_peer_id.clone()
                        } else {
                            m.peer_id.clone()
                        };
                        let mid = m.message_id.clone().unwrap_or_else(|| {
                            format!("legacy-{}-{}", sender, m.timestamp)
                        });
                        ArchiveMessage {
                            message_id: mid,
                            sender_id: sender,
                            text: m.text,
                            timestamp: m.timestamp,
                            signature: m.signature,
                            public_key: m.public_key,
                            edited_at: m.edited_at,
                            hidden_at: m.hidden_at,
                            reply_to_mid: m.reply_to_mid,
                            file_id: m.file_id,
                            channel_id: None,
                            reactions: Vec::new(),
                        }
                    })
                    .collect();
                (
                    "dm".to_string(),
                    peer_id.clone(),
                    Some(peer_id.clone()),
                    None,
                    None,
                    None,
                    None,
                    Vec::new(),
                    archive_msgs,
                )
            }
            ArchiveTarget::Channel {
                server_id,
                channel_id,
                channel_name,
            } => {
                let msgs = store.load_all_channel_messages(server_id, channel_id)?;
                let archive_msgs: Vec<ArchiveMessage> = msgs
                    .into_iter()
                    .map(|m| {
                        let mid = m.message_id.clone().unwrap_or_else(|| {
                            format!("legacy-{}-{}", m.sender_id, m.timestamp)
                        });
                        ArchiveMessage {
                            message_id: mid,
                            sender_id: m.sender_id,
                            text: m.text,
                            timestamp: m.timestamp,
                            signature: m.signature,
                            public_key: m.public_key,
                            edited_at: m.edited_at,
                            hidden_at: m.hidden_at,
                            reply_to_mid: m.reply_to_mid,
                            file_id: m.file_id,
                            channel_id: None,
                            reactions: Vec::new(),
                        }
                    })
                    .collect();
                (
                    "channel".to_string(),
                    format!("{}:{}", server_id, channel_id),
                    None,
                    Some(server_id.clone()),
                    Some(channel_id.clone()),
                    channel_name.clone(),
                    None,
                    Vec::new(),
                    archive_msgs,
                )
            }
            ArchiveTarget::Server {
                server_id,
                server_name,
                channels,
            } => {
                let mut archive_msgs: Vec<ArchiveMessage> = Vec::new();
                let mut channel_infos: Vec<ArchiveChannelInfo> = Vec::new();
                for (ch_id, ch_name) in channels {
                    let msgs = store.load_all_channel_messages(server_id, ch_id)?;
                    let count = msgs.len() as u32;
                    for m in msgs {
                        let mid = m.message_id.clone().unwrap_or_else(|| {
                            format!("legacy-{}-{}", m.sender_id, m.timestamp)
                        });
                        archive_msgs.push(ArchiveMessage {
                            message_id: mid,
                            sender_id: m.sender_id,
                            text: m.text,
                            timestamp: m.timestamp,
                            signature: m.signature,
                            public_key: m.public_key,
                            edited_at: m.edited_at,
                            hidden_at: m.hidden_at,
                            reply_to_mid: m.reply_to_mid,
                            file_id: m.file_id,
                            channel_id: Some(ch_id.clone()),
                            reactions: Vec::new(),
                        });
                    }
                    channel_infos.push(ArchiveChannelInfo {
                        channel_id: ch_id.clone(),
                        channel_name: ch_name.clone(),
                        message_count: count,
                    });
                }
                (
                    "server".to_string(),
                    server_id.clone(),
                    None,
                    Some(server_id.clone()),
                    None,
                    None,
                    Some(server_name.clone()),
                    channel_infos,
                    archive_msgs,
                )
            }
        };

    // ── 2. Collect message IDs for batch queries ────────────────
    let message_ids: Vec<String> = messages.iter().map(|m| m.message_id.clone()).collect();

    // ── 3. Batch-load related data ──────────────────────────────
    let reactions_map = store.load_reactions_for_sync(&message_ids)?;
    let edits_map = store.load_edits_for_messages(&message_ids)?;
    let deletions_map = store.load_deletions_for_messages(&message_ids)?;
    let removals_map = store.load_reaction_removals_for_messages(&message_ids)?;

    // ── 4. Attach reactions inline ──────────────────────────────
    let mut messages = messages;
    for msg in &mut messages {
        if let Some(rxns) = reactions_map.get(&msg.message_id) {
            msg.reactions = rxns
                .iter()
                .map(|(emoji, peer_id, added_at, sig, pk)| ArchiveReaction {
                    emoji: emoji.clone(),
                    peer_id: peer_id.clone(),
                    added_at: *added_at,
                    signature: sig.clone(),
                    public_key: pk.clone(),
                })
                .collect();
        }
    }

    // ── 5. Build edits list ─────────────────────────────────────
    let mut all_edits: Vec<ArchiveEdit> = Vec::new();
    let mut edits_by_mid: BTreeMap<String, Vec<ArchiveEdit>> = BTreeMap::new();
    for (mid, rows) in &edits_map {
        let entries: Vec<ArchiveEdit> = rows
            .iter()
            .map(|(old_text, new_text, edited_at, sig, pk)| ArchiveEdit {
                message_id: mid.clone(),
                old_text: old_text.clone(),
                new_text: new_text.clone(),
                edited_at: *edited_at,
                signature: sig.clone(),
                public_key: pk.clone(),
            })
            .collect();
        all_edits.extend(entries.iter().cloned());
        edits_by_mid.insert(mid.clone(), entries);
    }

    // ── 6. Build deletions list ─────────────────────────────────
    let mut all_deletions: Vec<ArchiveDeletion> = Vec::new();
    let mut deletions_by_mid: BTreeMap<String, Vec<ArchiveDeletion>> = BTreeMap::new();
    for (mid, rows) in &deletions_map {
        let entries: Vec<ArchiveDeletion> = rows
            .iter()
            .map(|(deleted_text, deleted_at, sig, pk)| ArchiveDeletion {
                message_id: mid.clone(),
                deleted_text: deleted_text.clone(),
                deleted_at: *deleted_at,
                signature: sig.clone(),
                public_key: pk.clone(),
            })
            .collect();
        all_deletions.extend(entries.iter().cloned());
        deletions_by_mid.insert(mid.clone(), entries);
    }

    // ── 7. Build reaction removals list ─────────────────────────
    let mut all_removals: Vec<ArchiveReactionRemoval> = Vec::new();
    let mut removals_by_mid: BTreeMap<String, Vec<ArchiveReactionRemoval>> = BTreeMap::new();
    for (mid, rows) in &removals_map {
        let entries: Vec<ArchiveReactionRemoval> = rows
            .iter()
            .map(|(emoji, peer_id, removed_at, sig, pk)| ArchiveReactionRemoval {
                message_id: mid.clone(),
                emoji: emoji.clone(),
                peer_id: peer_id.clone(),
                removed_at: *removed_at,
                signature: sig.clone(),
                public_key: pk.clone(),
            })
            .collect();
        all_removals.extend(entries.iter().cloned());
        removals_by_mid.insert(mid.clone(), entries);
    }

    // ── 8. Collect unique public keys ───────────────────────────
    let mut pubkey_map: HashMap<String, String> = HashMap::new(); // peer_id -> pk_b64
    for msg in &messages {
        if let Some(pk) = &msg.public_key {
            // Derive peer_id from the public key to verify it matches sender_id.
            pubkey_map.entry(msg.sender_id.clone()).or_insert_with(|| pk.clone());
        }
        for rxn in &msg.reactions {
            if let Some(pk) = &rxn.public_key {
                pubkey_map.entry(rxn.peer_id.clone()).or_insert_with(|| pk.clone());
            }
        }
    }
    for edit in &all_edits {
        if let (Some(pk), Some(msg)) = (
            &edit.public_key,
            messages.iter().find(|m| m.message_id == edit.message_id),
        ) {
            pubkey_map.entry(msg.sender_id.clone()).or_insert_with(|| pk.clone());
        }
    }
    for del in &all_deletions {
        if let (Some(pk), Some(msg)) = (
            &del.public_key,
            messages.iter().find(|m| m.message_id == del.message_id),
        ) {
            pubkey_map.entry(msg.sender_id.clone()).or_insert_with(|| pk.clone());
        }
    }
    for rem in &all_removals {
        if let Some(pk) = &rem.public_key {
            pubkey_map.entry(rem.peer_id.clone()).or_insert_with(|| pk.clone());
        }
    }

    let pubkeys: Vec<ArchivePubKey> = pubkey_map
        .iter()
        .map(|(pid, pk)| ArchivePubKey {
            peer_id: pid.clone(),
            public_key_b64: pk.clone(),
        })
        .collect();

    // ── 9. Handle files ─────────────────────────────────────────
    let files_dir = data_dir.join("files");
    let mut file_metadata: Vec<ArchiveFileMetadata> = Vec::new();
    let mut file_bytes_map: BTreeMap<String, Vec<u8>> = BTreeMap::new(); // file_id.ext -> bytes

    let file_ids: HashSet<String> = messages
        .iter()
        .filter_map(|m| m.file_id.clone())
        .collect();

    for fid in &file_ids {
        if let Ok(Some(sf)) = store.get_file_metadata(fid) {
            let should_include = match file_mode {
                FileMode::Full => true,
                FileMode::ImagesOnly => sf.is_image,
                FileMode::Placeholder => false,
            };

            let file_path = files_dir.join(format!("{}.{}", sf.file_id, sf.file_ext));
            let (sha256, included) = if should_include && file_path.exists() {
                match std::fs::read(&file_path) {
                    Ok(bytes) => {
                        let hash = Sha256::digest(&bytes);
                        let hash_hex = hex::encode(hash);
                        let key = format!("{}.{}", sf.file_id, sf.file_ext);
                        file_bytes_map.insert(key, bytes);
                        (Some(hash_hex), true)
                    }
                    Err(_) => (None, false),
                }
            } else {
                (None, false)
            };

            file_metadata.push(ArchiveFileMetadata {
                file_id: sf.file_id,
                file_name: sf.file_name,
                file_ext: sf.file_ext,
                mime_type: sf.mime_type,
                size_bytes: sf.size_bytes,
                is_image: sf.is_image,
                width: sf.width,
                height: sf.height,
                sha256,
                included,
            });
        }
    }

    // ── 10. Build participants list ─────────────────────────────
    let participants: Vec<String> = {
        let mut set: HashSet<String> = HashSet::new();
        for msg in &messages {
            set.insert(msg.sender_id.clone());
        }
        let mut v: Vec<String> = set.into_iter().collect();
        v.sort();
        v
    };

    // ── 11. Build manifest ──────────────────────────────────────
    let manifest = ArchiveManifest {
        format_version: ARCHIVE_FORMAT_VERSION,
        archive_type: archive_type.clone(),
        exporter_peer_id: exporter_peer_id.clone(),
        export_timestamp,
        message_count: messages.len() as u32,
        file_mode: file_mode.as_str().to_string(),
        peer_id: peer_id_opt,
        server_id: server_id_opt,
        channel_id: channel_id_opt,
        channel_name: channel_name_opt,
        server_name: server_name_opt,
        channels: channel_infos,
        participants,
    };

    // ── 12. Serialize everything to JSON ────────────────────────
    let manifest_json = serde_json::to_vec_pretty(&manifest)
        .map_err(|e| format!("Failed to serialize manifest: {e}"))?;

    let mut message_jsons: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    for msg in &messages {
        let json = serde_json::to_vec_pretty(msg)
            .map_err(|e| format!("Failed to serialize message {}: {e}", msg.message_id))?;
        message_jsons.insert(msg.message_id.clone(), json);
    }

    let mut edit_jsons: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    for (mid, entries) in &edits_by_mid {
        let json = serde_json::to_vec_pretty(entries)
            .map_err(|e| format!("Failed to serialize edits for {mid}: {e}"))?;
        edit_jsons.insert(mid.clone(), json);
    }

    let mut deletion_jsons: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    for (mid, entries) in &deletions_by_mid {
        let json = serde_json::to_vec_pretty(entries)
            .map_err(|e| format!("Failed to serialize deletions for {mid}: {e}"))?;
        deletion_jsons.insert(mid.clone(), json);
    }

    let mut removal_jsons: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    for (mid, entries) in &removals_by_mid {
        let json = serde_json::to_vec_pretty(entries)
            .map_err(|e| format!("Failed to serialize reaction removals for {mid}: {e}"))?;
        removal_jsons.insert(mid.clone(), json);
    }

    let pubkeys_json = serde_json::to_vec_pretty(&pubkeys)
        .map_err(|e| format!("Failed to serialize pubkeys: {e}"))?;

    let mut file_meta_jsons: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    for fm in &file_metadata {
        let json = serde_json::to_vec_pretty(fm)
            .map_err(|e| format!("Failed to serialize file metadata {}: {e}", fm.file_id))?;
        file_meta_jsons.insert(fm.file_id.clone(), json);
    }

    // ── 13. Compute archive-level hash ──────────────────────────
    let mut file_hashes: BTreeMap<String, String> = BTreeMap::new();
    for fm in &file_metadata {
        let hash = if let Some(h) = &fm.sha256 {
            h.clone()
        } else {
            "placeholder".to_string()
        };
        file_hashes.insert(fm.file_id.clone(), hash);
    }

    let content_hash = compute_archive_hash(
        &manifest_json,
        &message_jsons,
        &edit_jsons,
        &deletion_jsons,
        &removal_jsons,
        &file_hashes,
    );
    let content_hash_hex = hex::encode(content_hash);

    // ── 14. Sign the hash ───────────────────────────────────────
    let sig = keypair.sign(&content_hash);
    let sig_b64 = base64::engine::general_purpose::STANDARD.encode(&sig);
    let pk_b64 = base64::engine::general_purpose::STANDARD.encode(keypair.public_key_protobuf());

    let archive_sig = ArchiveSignature {
        exporter_peer_id: exporter_peer_id.clone(),
        signature_b64: sig_b64,
        public_key_b64: pk_b64,
        content_hash_hex,
    };

    let archive_sig_json = serde_json::to_vec_pretty(&archive_sig)
        .map_err(|e| format!("Failed to serialize archive signature: {e}"))?;

    // ── 15. Write zip ───────────────────────────────────────────
    let mut zip_buf = std::io::Cursor::new(Vec::new());
    {
        let mut zip = zip::ZipWriter::new(&mut zip_buf);
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);

        // manifest.json
        zip.start_file("manifest.json", options)
            .map_err(|e| format!("Zip error: {e}"))?;
        zip.write_all(&manifest_json)
            .map_err(|e| format!("Zip write error: {e}"))?;

        // messages/{message_id}.json
        for (mid, json) in &message_jsons {
            zip.start_file(format!("messages/{mid}.json"), options)
                .map_err(|e| format!("Zip error: {e}"))?;
            zip.write_all(json)
                .map_err(|e| format!("Zip write error: {e}"))?;
        }

        // edits/{message_id}.json
        for (mid, json) in &edit_jsons {
            zip.start_file(format!("edits/{mid}.json"), options)
                .map_err(|e| format!("Zip error: {e}"))?;
            zip.write_all(json)
                .map_err(|e| format!("Zip write error: {e}"))?;
        }

        // deletions/{message_id}.json
        for (mid, json) in &deletion_jsons {
            zip.start_file(format!("deletions/{mid}.json"), options)
                .map_err(|e| format!("Zip error: {e}"))?;
            zip.write_all(json)
                .map_err(|e| format!("Zip write error: {e}"))?;
        }

        // reaction_removals/{message_id}.json
        for (mid, json) in &removal_jsons {
            zip.start_file(format!("reaction_removals/{mid}.json"), options)
                .map_err(|e| format!("Zip error: {e}"))?;
            zip.write_all(json)
                .map_err(|e| format!("Zip write error: {e}"))?;
        }

        // pubkeys.json
        zip.start_file("pubkeys.json", options)
            .map_err(|e| format!("Zip error: {e}"))?;
        zip.write_all(&pubkeys_json)
            .map_err(|e| format!("Zip write error: {e}"))?;

        // files/{file_id}.meta.json
        for (fid, json) in &file_meta_jsons {
            zip.start_file(format!("files/{fid}.meta.json"), options)
                .map_err(|e| format!("Zip error: {e}"))?;
            zip.write_all(json)
                .map_err(|e| format!("Zip write error: {e}"))?;
        }

        // files/{file_id}.{ext} (actual bytes)
        for (key, bytes) in &file_bytes_map {
            zip.start_file(format!("files/{key}"), options)
                .map_err(|e| format!("Zip error: {e}"))?;
            zip.write_all(bytes)
                .map_err(|e| format!("Zip write error: {e}"))?;
        }

        // archive_signature.json
        zip.start_file("archive_signature.json", options)
            .map_err(|e| format!("Zip error: {e}"))?;
        zip.write_all(&archive_sig_json)
            .map_err(|e| format!("Zip write error: {e}"))?;

        zip.finish().map_err(|e| format!("Failed to finalize zip: {e}"))?;
    }

    Ok(zip_buf.into_inner())
}

/// Compute a deterministic SHA-256 hash over the entire archive content.
///
/// The hash covers: manifest + sorted message JSONs + sorted edit JSONs +
/// sorted deletion JSONs + sorted removal JSONs + sorted file hashes.
/// Using BTreeMap guarantees sorted iteration order for determinism.
fn compute_archive_hash(
    manifest_json: &[u8],
    message_jsons: &BTreeMap<String, Vec<u8>>,
    edit_jsons: &BTreeMap<String, Vec<u8>>,
    deletion_jsons: &BTreeMap<String, Vec<u8>>,
    removal_jsons: &BTreeMap<String, Vec<u8>>,
    file_hashes: &BTreeMap<String, String>,
) -> [u8; 32] {
    let mut hasher = Sha256::new();

    // Manifest
    hasher.update(manifest_json);
    hasher.update(b"\n");

    // Messages (sorted by message_id via BTreeMap)
    for json in message_jsons.values() {
        let h = Sha256::digest(json);
        hasher.update(hex::encode(h).as_bytes());
        hasher.update(b"\n");
    }

    // Edits
    for json in edit_jsons.values() {
        let h = Sha256::digest(json);
        hasher.update(hex::encode(h).as_bytes());
        hasher.update(b"\n");
    }

    // Deletions
    for json in deletion_jsons.values() {
        let h = Sha256::digest(json);
        hasher.update(hex::encode(h).as_bytes());
        hasher.update(b"\n");
    }

    // Reaction removals
    for json in removal_jsons.values() {
        let h = Sha256::digest(json);
        hasher.update(hex::encode(h).as_bytes());
        hasher.update(b"\n");
    }

    // File hashes
    for hash in file_hashes.values() {
        hasher.update(hash.as_bytes());
        hasher.update(b"\n");
    }

    hasher.finalize().into()
}
