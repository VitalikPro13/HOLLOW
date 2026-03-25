use std::collections::HashMap;
use std::time::{SystemTime, UNIX_EPOCH};

use aes_gcm::aead::Aead;
use aes_gcm::{Aes256Gcm, Key, KeyInit, Nonce};
use serde::{Deserialize, Serialize};

use super::adaptive::{apply_tier_multiplier, compute_adaptive_params, determine_tier, VaultMode};
use super::content_store::content_id;
use super::erasure;
use super::placement::{place, ShardPlacement};

/// Manifest describing a vault-stored file. Contains the AES decryption key.
/// Encrypted with MLS group key before broadcast, stored in SQLCipher at rest.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VaultManifest {
    pub content_id: String,
    pub encryption_key: String, // 32-byte AES key, hex-encoded
    pub nonce: String,          // 12-byte AES-GCM nonce, hex-encoded
    pub original_size: u64,
    pub k: u16,          // 0 = full replication sentinel
    pub m: u16,          // 0 = full replication sentinel
    pub shard_count: u16,
    pub file_name: String,
    pub mime_type: String,
    pub storage_tier: String,
    pub created_at: i64,
    pub creator_peer_id: String,
    pub channel_id: String,
}

/// AES-256-GCM encrypted output.
pub struct EncryptedFile {
    pub ciphertext: Vec<u8>,
    pub key: [u8; 32],
    pub nonce: [u8; 12],
}

/// The prepared upload plan — everything needed to distribute a file.
pub struct UploadPlan {
    pub manifest: VaultManifest,
    /// Shards indexed by shard_index. For full replication: single entry at index 0.
    pub shards: Vec<(u16, Vec<u8>)>,
    pub placements: Vec<ShardPlacement>,
    pub content_id: String,
}

// ── AES-256-GCM helpers ──────────────────────────────────────

/// Encrypt plaintext with AES-256-GCM using a random key and nonce.
pub fn aes_encrypt(plaintext: &[u8]) -> Result<EncryptedFile, String> {
    let mut key_bytes = [0u8; 32];
    getrandom::fill(&mut key_bytes)
        .map_err(|e| format!("Failed to generate AES key: {e}"))?;
    let mut nonce_bytes = [0u8; 12];
    getrandom::fill(&mut nonce_bytes)
        .map_err(|e| format!("Failed to generate AES nonce: {e}"))?;

    let key = Key::<Aes256Gcm>::from(key_bytes);
    let cipher = Aes256Gcm::new(&key);
    let nonce = Nonce::from(nonce_bytes);

    let ciphertext = cipher
        .encrypt(&nonce, plaintext)
        .map_err(|e| format!("AES-256-GCM encryption failed: {e}"))?;

    Ok(EncryptedFile {
        ciphertext,
        key: key_bytes,
        nonce: nonce_bytes,
    })
}

/// Decrypt AES-256-GCM ciphertext. Used by the download pipeline.
pub fn aes_decrypt(
    ciphertext: &[u8],
    key: &[u8; 32],
    nonce: &[u8; 12],
) -> Result<Vec<u8>, String> {
    let aes_key = Key::<Aes256Gcm>::from(*key);
    let cipher = Aes256Gcm::new(&aes_key);
    let aes_nonce = Nonce::from(*nonce);

    cipher
        .decrypt(&aes_nonce, ciphertext)
        .map_err(|e| format!("AES-256-GCM decryption failed: {e}"))
}

// ── Upload orchestration ─────────────────────────────────────

/// Prepare a complete upload plan. Pure function — no I/O, no network.
///
/// The caller provides pre-encrypted data (ciphertext + key + nonce) and
/// the pre-computed content_id. This function handles erasure coding,
/// placement computation, and manifest creation.
#[allow(clippy::too_many_arguments)]
pub fn prepare_upload(
    ciphertext: &[u8],
    cid: &str,
    aes_key: &[u8; 32],
    aes_nonce: &[u8; 12],
    file_name: &str,
    mime_type: &str,
    channel_id: &str,
    original_size: u64,
    our_peer_id: &str,
    members: &[String],
    pledges: &HashMap<String, u64>,
) -> Result<UploadPlan, String> {
    let tier = determine_tier(mime_type);
    let mode = compute_adaptive_params(members.len());

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;

    let (shards, placements, k_val, m_val, shard_count) = match &mode {
        VaultMode::FullReplication => {
            // Single "shard" = full ciphertext, sent to every eligible member
            let shards = vec![(0u16, ciphertext.to_vec())];
            let placements = place(cid, &mode, members, pledges);
            (shards, placements, 0u16, 0u16, 0u16)
        }
        VaultMode::ErasureCoding { k, m } => {
            let (k_adj, m_adj) = apply_tier_multiplier(*k, *m, tier);
            let encoded = erasure::encode(ciphertext, k_adj, m_adj, cid)?;
            let n = encoded.len();
            let shards: Vec<(u16, Vec<u8>)> = encoded
                .into_iter()
                .enumerate()
                .map(|(i, data)| (i as u16, data))
                .collect();
            let ec_mode = VaultMode::ErasureCoding {
                k: k_adj,
                m: m_adj,
            };
            let placements = place(cid, &ec_mode, members, pledges);
            (shards, placements, k_adj as u16, m_adj as u16, n as u16)
        }
    };

    let manifest = VaultManifest {
        content_id: cid.to_string(),
        encryption_key: hex::encode(aes_key),
        nonce: hex::encode(aes_nonce),
        original_size,
        k: k_val,
        m: m_val,
        shard_count,
        file_name: file_name.to_string(),
        mime_type: mime_type.to_string(),
        storage_tier: tier.as_str().to_string(),
        created_at: now,
        creator_peer_id: our_peer_id.to_string(),
        channel_id: channel_id.to_string(),
    };

    Ok(UploadPlan {
        manifest,
        shards,
        placements,
        content_id: cid.to_string(),
    })
}

/// Guess MIME type from file extension.
pub fn mime_from_ext(ext: &str) -> String {
    match ext {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "bmp" => "image/bmp",
        "webp" => "image/webp",
        "svg" => "image/svg+xml",
        "mp3" => "audio/mpeg",
        "ogg" => "audio/ogg",
        "wav" => "audio/wav",
        "flac" => "audio/flac",
        "mp4" => "video/mp4",
        "webm" => "video/webm",
        "pdf" => "application/pdf",
        "zip" => "application/zip",
        "txt" => "text/plain",
        _ => "application/octet-stream",
    }
    .to_string()
}

/// Extract file extension from a filename.
pub fn ext_from_filename(name: &str) -> String {
    std::path::Path::new(name)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("bin")
        .to_lowercase()
}

// ── Download / reconstruction ────────────────────────────────

/// Reconstruct a file from its manifest and collected shards.
///
/// For replication mode (k=0, m=0): `packed_shards` should have one `Some` entry
/// containing the full ciphertext.
///
/// For erasure mode: `packed_shards` must have k+m entries (Some/None pattern),
/// with at least k available. These are packed shards (with ShardMetadata headers).
pub fn reconstruct_file(
    manifest: &VaultManifest,
    packed_shards: &[Option<Vec<u8>>],
) -> Result<Vec<u8>, String> {
    // Decode AES key and nonce from manifest hex strings
    let key_vec =
        hex::decode(&manifest.encryption_key).map_err(|e| format!("Invalid AES key hex: {e}"))?;
    let nonce_vec =
        hex::decode(&manifest.nonce).map_err(|e| format!("Invalid nonce hex: {e}"))?;

    let key: [u8; 32] = key_vec
        .try_into()
        .map_err(|_| "AES key must be 32 bytes".to_string())?;
    let nonce: [u8; 12] = nonce_vec
        .try_into()
        .map_err(|_| "AES nonce must be 12 bytes".to_string())?;

    let ciphertext = if manifest.k == 0 && manifest.m == 0 {
        // Replication mode — the shard IS the ciphertext (no erasure headers)
        packed_shards
            .iter()
            .flatten()
            .next()
            .cloned()
            .ok_or_else(|| "No shard data available for replication mode".to_string())?
    } else {
        // Erasure mode — decode from packed shards
        erasure::decode(packed_shards, manifest.k as usize, manifest.m as usize)?
    };

    aes_decrypt(&ciphertext, &key, &nonce)
}

// ── Vault cache ──────────────────────────────────────────────

use std::path::PathBuf;

/// Get the vault cache directory path.
pub fn vault_cache_dir() -> PathBuf {
    let dir = crate::identity::data_dir()
        .unwrap_or_else(|_| PathBuf::from("hollow"))
        .join("vault_cache");
    let _ = std::fs::create_dir_all(&dir);
    dir
}

/// Get the cache file path for a content item.
pub fn cache_path(content_id: &str, ext: &str) -> PathBuf {
    let safe_ext = if ext.is_empty() { "bin" } else { ext };
    vault_cache_dir().join(format!("{content_id}.{safe_ext}"))
}

/// Check if a file is in the local vault cache. Returns the path if found.
pub fn check_cache(content_id: &str, ext: &str) -> Option<PathBuf> {
    let path = cache_path(content_id, ext);
    if path.exists() {
        Some(path)
    } else {
        None
    }
}

/// Write decrypted file data to the vault cache. Returns the disk path.
pub fn write_to_cache(content_id: &str, ext: &str, data: &[u8]) -> Result<PathBuf, String> {
    let path = cache_path(content_id, ext);
    std::fs::write(&path, data).map_err(|e| format!("Failed to write cache file: {e}"))?;
    Ok(path)
}

/// Evict oldest cache files until total size is under max_bytes * 0.8.
/// Returns bytes freed. Does nothing if already under limit.
pub fn evict_cache_if_needed(max_bytes: u64) -> Result<u64, String> {
    let dir = vault_cache_dir();
    let entries = std::fs::read_dir(&dir).map_err(|e| format!("Failed to read cache dir: {e}"))?;

    let mut files: Vec<(PathBuf, u64, std::time::SystemTime)> = Vec::new();
    let mut total_size: u64 = 0;

    for entry in entries.flatten() {
        if let Ok(meta) = entry.metadata() {
            if meta.is_file() {
                let size = meta.len();
                let modified = meta.modified().unwrap_or(std::time::UNIX_EPOCH);
                files.push((entry.path(), size, modified));
                total_size += size;
            }
        }
    }

    if total_size <= max_bytes {
        return Ok(0);
    }

    // Sort by modified time — oldest first (evict oldest)
    files.sort_by(|a, b| a.2.cmp(&b.2));

    let target = (max_bytes as f64 * 0.8) as u64;
    let mut freed: u64 = 0;

    for (path, size, _) in &files {
        if total_size - freed <= target {
            break;
        }
        if std::fs::remove_file(path).is_ok() {
            freed += size;
        }
    }

    Ok(freed)
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── AES-256-GCM ──────────────────────────────────────────

    #[test]
    fn aes_encrypt_decrypt_round_trip() {
        let data = b"Hello, Haven Vault! This is a secret file.";
        let encrypted = aes_encrypt(data).unwrap();
        assert_ne!(encrypted.ciphertext, data);
        let decrypted = aes_decrypt(&encrypted.ciphertext, &encrypted.key, &encrypted.nonce).unwrap();
        assert_eq!(decrypted, data);
    }

    #[test]
    fn aes_different_keys() {
        let data = b"Same data, different encryptions";
        let e1 = aes_encrypt(data).unwrap();
        let e2 = aes_encrypt(data).unwrap();
        // Random keys → different ciphertexts
        assert_ne!(e1.ciphertext, e2.ciphertext);
        assert_ne!(e1.key, e2.key);
    }

    #[test]
    fn aes_wrong_key_fails() {
        let data = b"test data";
        let encrypted = aes_encrypt(data).unwrap();
        let wrong_key = [0xFFu8; 32];
        let result = aes_decrypt(&encrypted.ciphertext, &wrong_key, &encrypted.nonce);
        assert!(result.is_err());
    }

    #[test]
    fn aes_wrong_nonce_fails() {
        let data = b"test data";
        let encrypted = aes_encrypt(data).unwrap();
        let wrong_nonce = [0xFFu8; 12];
        let result = aes_decrypt(&encrypted.ciphertext, &encrypted.key, &wrong_nonce);
        assert!(result.is_err());
    }

    #[test]
    fn aes_corrupt_ciphertext_fails() {
        let data = b"test data";
        let encrypted = aes_encrypt(data).unwrap();
        let mut corrupted = encrypted.ciphertext.clone();
        if let Some(byte) = corrupted.last_mut() {
            *byte ^= 0xFF;
        }
        let result = aes_decrypt(&corrupted, &encrypted.key, &encrypted.nonce);
        assert!(result.is_err());
    }

    #[test]
    fn aes_empty_data() {
        let encrypted = aes_encrypt(b"").unwrap();
        let decrypted = aes_decrypt(&encrypted.ciphertext, &encrypted.key, &encrypted.nonce).unwrap();
        assert!(decrypted.is_empty());
    }

    #[test]
    fn aes_large_data() {
        let data: Vec<u8> = (0..1_000_000).map(|i| (i % 256) as u8).collect();
        let encrypted = aes_encrypt(&data).unwrap();
        let decrypted = aes_decrypt(&encrypted.ciphertext, &encrypted.key, &encrypted.nonce).unwrap();
        assert_eq!(decrypted, data);
    }

    // ── prepare_upload ───────────────────────────────────────

    fn make_members(names: &[&str]) -> Vec<String> {
        names.iter().map(|s| s.to_string()).collect()
    }

    fn make_pledges(names: &[&str], amount: u64) -> HashMap<String, u64> {
        names.iter().map(|s| (s.to_string(), amount)).collect()
    }

    #[test]
    fn prepare_upload_full_replication() {
        let data = b"small file for 3-member server";
        let encrypted = aes_encrypt(data).unwrap();
        let cid = content_id(&encrypted.ciphertext);
        let members = make_members(&["peer_a", "peer_b", "peer_c"]);
        let pledges = make_pledges(&["peer_a", "peer_b", "peer_c"], 1_000_000_000);

        let plan = prepare_upload(
            &encrypted.ciphertext, &cid, &encrypted.key, &encrypted.nonce,
            "test.txt", "text/plain", "ch1", data.len() as u64,
            "peer_a", &members, &pledges,
        ).unwrap();

        // Full replication sentinels
        assert_eq!(plan.manifest.k, 0);
        assert_eq!(plan.manifest.m, 0);
        assert_eq!(plan.manifest.shard_count, 0);
        assert_eq!(plan.shards.len(), 1);
        assert_eq!(plan.shards[0].0, 0); // shard_index = 0
        // Placements for all 3 members
        assert_eq!(plan.placements.len(), 3);
    }

    #[test]
    fn prepare_upload_erasure_coding() {
        let data = b"file for 8-member server with erasure coding";
        let encrypted = aes_encrypt(data).unwrap();
        let cid = content_id(&encrypted.ciphertext);
        let members: Vec<String> = (0..8).map(|i| format!("peer_{i}")).collect();
        let pledges: HashMap<String, u64> = members.iter().map(|m| (m.clone(), 1_000_000_000)).collect();

        let plan = prepare_upload(
            &encrypted.ciphertext, &cid, &encrypted.key, &encrypted.nonce,
            "photo.webp", "image/webp", "ch1", data.len() as u64,
            "peer_0", &members, &pledges,
        ).unwrap();

        // 8 members → k=3, m=2 (standard tier, no adjustment)
        assert_eq!(plan.manifest.k, 3);
        assert_eq!(plan.manifest.m, 2);
        assert_eq!(plan.manifest.shard_count, 5);
        assert_eq!(plan.shards.len(), 5);
        assert_eq!(plan.placements.len(), 5);
    }

    #[test]
    fn prepare_upload_audio_low_tier() {
        let data = b"audio file";
        let encrypted = aes_encrypt(data).unwrap();
        let cid = content_id(&encrypted.ciphertext);
        let members: Vec<String> = (0..8).map(|i| format!("peer_{i}")).collect();
        let pledges: HashMap<String, u64> = members.iter().map(|m| (m.clone(), 1_000_000_000)).collect();

        let plan = prepare_upload(
            &encrypted.ciphertext, &cid, &encrypted.key, &encrypted.nonce,
            "voice.mp3", "audio/mpeg", "ch1", data.len() as u64,
            "peer_0", &members, &pledges,
        ).unwrap();

        assert_eq!(plan.manifest.storage_tier, "low");
        // Low tier: k=3, m adjusted from 2 → ceil(2*0.6)=2 (min 1, 0.6*2=1.2→2)
        assert_eq!(plan.manifest.k, 3);
        // m = ceil(2 * 0.6) = ceil(1.2) = 2
        assert_eq!(plan.manifest.m, 2);
    }

    #[test]
    fn prepare_upload_zero_pledge_excluded() {
        let data = b"file data";
        let encrypted = aes_encrypt(data).unwrap();
        let cid = content_id(&encrypted.ciphertext);
        let members = make_members(&["peer_a", "peer_b", "peer_c"]);
        let mut pledges = make_pledges(&["peer_a", "peer_c"], 1_000_000_000);
        pledges.insert("peer_b".to_string(), 0);

        let plan = prepare_upload(
            &encrypted.ciphertext, &cid, &encrypted.key, &encrypted.nonce,
            "test.txt", "text/plain", "ch1", data.len() as u64,
            "peer_a", &members, &pledges,
        ).unwrap();

        // peer_b excluded from placements (full replication, <6 members)
        for p in &plan.placements {
            assert_ne!(p.target_peer, "peer_b");
        }
    }

    #[test]
    fn manifest_serde_round_trip() {
        let manifest = VaultManifest {
            content_id: "abc123".into(),
            encryption_key: hex::encode([0xAA; 32]),
            nonce: hex::encode([0xBB; 12]),
            original_size: 12345,
            k: 3,
            m: 2,
            shard_count: 5,
            file_name: "photo.webp".into(),
            mime_type: "image/webp".into(),
            storage_tier: "standard".into(),
            created_at: 1710000000,
            creator_peer_id: "12D3KooW...".into(),
            channel_id: "ch1".into(),
        };
        let json = serde_json::to_string(&manifest).unwrap();
        let back: VaultManifest = serde_json::from_str(&json).unwrap();
        assert_eq!(back.content_id, manifest.content_id);
        assert_eq!(back.encryption_key, manifest.encryption_key);
        assert_eq!(back.nonce, manifest.nonce);
        assert_eq!(back.k, manifest.k);
        assert_eq!(back.m, manifest.m);
        assert_eq!(back.original_size, manifest.original_size);
    }

    #[test]
    fn mime_from_ext_common() {
        assert_eq!(mime_from_ext("png"), "image/png");
        assert_eq!(mime_from_ext("mp3"), "audio/mpeg");
        assert_eq!(mime_from_ext("pdf"), "application/pdf");
        assert_eq!(mime_from_ext("xyz"), "application/octet-stream");
    }

    // ── reconstruct_file ─────────────────────────────────────

    #[test]
    fn reconstruct_file_replication() {
        let original = b"Hello, this is a replicated file!";
        let encrypted = aes_encrypt(original).unwrap();
        let cid = content_id(&encrypted.ciphertext);

        let manifest = VaultManifest {
            content_id: cid,
            encryption_key: hex::encode(encrypted.key),
            nonce: hex::encode(encrypted.nonce),
            original_size: original.len() as u64,
            k: 0, m: 0, shard_count: 0,
            file_name: "test.txt".into(),
            mime_type: "text/plain".into(),
            storage_tier: "standard".into(),
            created_at: 0,
            creator_peer_id: "peer".into(),
            channel_id: "ch".into(),
        };

        // Replication: single shard = full ciphertext
        let shards: Vec<Option<Vec<u8>>> = vec![Some(encrypted.ciphertext)];
        let result = reconstruct_file(&manifest, &shards).unwrap();
        assert_eq!(result, original);
    }

    #[test]
    fn reconstruct_file_erasure() {
        let original = b"File to be erasure-coded and reconstructed";
        let encrypted = aes_encrypt(original).unwrap();
        let cid = content_id(&encrypted.ciphertext);

        let k = 3usize;
        let m = 2usize;
        let encoded = erasure::encode(&encrypted.ciphertext, k, m, &cid).unwrap();

        let manifest = VaultManifest {
            content_id: cid,
            encryption_key: hex::encode(encrypted.key),
            nonce: hex::encode(encrypted.nonce),
            original_size: original.len() as u64,
            k: k as u16, m: m as u16, shard_count: (k + m) as u16,
            file_name: "test.dat".into(),
            mime_type: "application/octet-stream".into(),
            storage_tier: "standard".into(),
            created_at: 0,
            creator_peer_id: "peer".into(),
            channel_id: "ch".into(),
        };

        // Drop m parity shards
        let mut shards: Vec<Option<Vec<u8>>> = encoded.into_iter().map(Some).collect();
        for i in k..k + m {
            shards[i] = None;
        }

        let result = reconstruct_file(&manifest, &shards).unwrap();
        assert_eq!(result, original);
    }

    #[test]
    fn reconstruct_file_wrong_key_fails() {
        let original = b"secret data";
        let encrypted = aes_encrypt(original).unwrap();
        let cid = content_id(&encrypted.ciphertext);

        let manifest = VaultManifest {
            content_id: cid,
            encryption_key: hex::encode([0xFFu8; 32]), // wrong key
            nonce: hex::encode(encrypted.nonce),
            original_size: original.len() as u64,
            k: 0, m: 0, shard_count: 0,
            file_name: "test.txt".into(),
            mime_type: "text/plain".into(),
            storage_tier: "standard".into(),
            created_at: 0,
            creator_peer_id: "peer".into(),
            channel_id: "ch".into(),
        };

        let shards: Vec<Option<Vec<u8>>> = vec![Some(encrypted.ciphertext)];
        let result = reconstruct_file(&manifest, &shards);
        assert!(result.is_err());
    }

    // ── cache helpers ────────────────────────────────────────

    #[test]
    fn cache_write_and_check() {
        let data = b"cached file data";
        // Use a unique content_id to avoid test interference
        let cid = content_id(data);
        let path = write_to_cache(&cid, "txt", data).unwrap();
        assert!(path.exists());

        let found = check_cache(&cid, "txt");
        assert!(found.is_some());
        assert_eq!(found.unwrap(), path);

        // Cleanup
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn cache_check_nonexistent() {
        assert!(check_cache("nonexistent_content_id_12345", "bin").is_none());
    }
}
