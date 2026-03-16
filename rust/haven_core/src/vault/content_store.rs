use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Storage tiers for vault content.
/// Determines retention policy and redundancy multiplier.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum StorageTier {
    Standard, // images, documents, files
    Low,      // voice recordings
}

impl StorageTier {
    pub fn as_str(&self) -> &'static str {
        match self {
            StorageTier::Standard => "standard",
            StorageTier::Low => "low",
        }
    }

    pub fn from_str(s: &str) -> Self {
        match s {
            "low" => StorageTier::Low,
            _ => StorageTier::Standard,
        }
    }
}

/// Metadata for a locally stored shard, mirrors the vault_shards DB row.
#[derive(Debug, Clone)]
pub struct ShardRecord {
    pub shard_key: String,
    pub server_id: String,
    pub content_id: String,
    pub shard_index: u16,
    pub k: u16,
    pub m: u16,
    pub shard_size: u64,
    pub total_data_size: u64,
    pub stored_at: i64,
    pub last_verified: Option<i64>,
    pub storage_tier: StorageTier,
    pub data_hash: String,
}

/// Metadata for a tracked shard placement (which peer should store which shard).
#[derive(Debug, Clone)]
pub struct PlacementRecord {
    pub content_id: String,
    pub shard_index: u16,
    pub target_peer: String,
    pub server_id: String,
    pub shard_key: String,
    pub stored_at: i64,
    pub confirmed: bool,
}

// ── Pure functions ───────────────────────────────────────────

/// Compute the content ID for a block of data.
/// SHA-256 hash, hex-encoded (64 chars). Canonical content identifier.
pub fn content_id(data: &[u8]) -> String {
    hex::encode(Sha256::digest(data))
}

/// Compute the shard key for a specific shard of a content item.
/// SHA-256(content_id_bytes || shard_index as big-endian u16), hex-encoded.
/// Used as DHT routing key and local filename.
pub fn shard_key(content_id: &str, shard_index: u16) -> String {
    let mut hasher = Sha256::new();
    hasher.update(content_id.as_bytes());
    hasher.update(&shard_index.to_be_bytes());
    hex::encode(hasher.finalize())
}

/// Sanitize a string for use in file paths: keep only alphanumeric, hyphen, underscore.
fn sanitize_path_component(s: &str) -> String {
    s.chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .collect()
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

// ── ContentStore ─────────────────────────────────────────────

/// Content-addressed storage layer for vault shards.
/// Manages shard files on disk and metadata in SQLCipher.
pub struct ContentStore {
    conn: Connection,
    base_dir: PathBuf,
}

impl ContentStore {
    /// Open the content store. Creates vault tables if they don't exist.
    /// `db_path` and `passphrase` connect to the same messages.db as other stores.
    /// `base_dir` is the root for shard file storage (e.g., ~/.haven/vault/).
    pub fn open(db_path: &str, passphrase: &str, base_dir: &Path) -> Result<Self, String> {
        let conn =
            Connection::open(db_path).map_err(|e| format!("Failed to open content store: {e}"))?;

        conn.execute_batch(&format!("PRAGMA key = \"x'{passphrase}'\";"))
            .map_err(|e| format!("Failed to set encryption key: {e}"))?;

        conn.execute(
            "CREATE TABLE IF NOT EXISTS vault_shards (
                shard_key       TEXT    PRIMARY KEY,
                server_id       TEXT    NOT NULL,
                content_id      TEXT    NOT NULL,
                shard_index     INTEGER NOT NULL,
                k               INTEGER NOT NULL,
                m               INTEGER NOT NULL,
                shard_size      INTEGER NOT NULL,
                total_data_size INTEGER NOT NULL,
                stored_at       INTEGER NOT NULL,
                last_verified   INTEGER,
                storage_tier    TEXT    NOT NULL DEFAULT 'standard',
                data_hash       TEXT    NOT NULL
            )",
            [],
        )
        .map_err(|e| format!("Failed to create vault_shards table: {e}"))?;

        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_vault_shards_server_content
             ON vault_shards (server_id, content_id)",
            [],
        )
        .map_err(|e| format!("Failed to create server_content index: {e}"))?;

        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_vault_shards_server_tier
             ON vault_shards (server_id, storage_tier)",
            [],
        )
        .map_err(|e| format!("Failed to create server_tier index: {e}"))?;

        conn.execute(
            "CREATE TABLE IF NOT EXISTS vault_placement (
                content_id   TEXT    NOT NULL,
                shard_index  INTEGER NOT NULL,
                target_peer  TEXT    NOT NULL,
                server_id    TEXT    NOT NULL,
                shard_key    TEXT    NOT NULL,
                stored_at    INTEGER NOT NULL,
                confirmed    INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (content_id, shard_index)
            )",
            [],
        )
        .map_err(|e| format!("Failed to create vault_placement table: {e}"))?;

        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_vault_placement_server
             ON vault_placement (server_id)",
            [],
        )
        .map_err(|e| format!("Failed to create placement server index: {e}"))?;

        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_vault_placement_peer
             ON vault_placement (target_peer)",
            [],
        )
        .map_err(|e| format!("Failed to create placement peer index: {e}"))?;

        std::fs::create_dir_all(base_dir)
            .map_err(|e| format!("Failed to create vault base dir: {e}"))?;

        Ok(ContentStore {
            conn,
            base_dir: base_dir.to_path_buf(),
        })
    }

    /// Directory for a specific server's shards. Creates if needed.
    fn server_dir(&self, server_id: &str) -> PathBuf {
        let sanitized = sanitize_path_component(server_id);
        let dir = self.base_dir.join(sanitized);
        let _ = std::fs::create_dir_all(&dir);
        dir
    }

    /// File path for a shard: {base_dir}/{server_id}/{shard_key}.shard
    fn shard_path(&self, server_id: &str, shard_key_str: &str) -> PathBuf {
        let sanitized_key = sanitize_path_component(shard_key_str);
        self.server_dir(server_id).join(format!("{sanitized_key}.shard"))
    }

    /// Store a shard: write data to disk and record metadata in DB.
    /// Returns the computed shard_key.
    #[allow(clippy::too_many_arguments)]
    pub fn store_shard(
        &self,
        server_id: &str,
        cid: &str,
        shard_index: u16,
        k: u16,
        m: u16,
        total_data_size: u64,
        tier: StorageTier,
        data: &[u8],
    ) -> Result<String, String> {
        let key = shard_key(cid, shard_index);
        let path = self.shard_path(server_id, &key);
        let data_hash = hex::encode(Sha256::digest(data));
        let shard_size = data.len() as u64;

        std::fs::write(&path, data)
            .map_err(|e| format!("Failed to write shard file: {e}"))?;

        self.conn
            .execute(
                "INSERT OR REPLACE INTO vault_shards
                 (shard_key, server_id, content_id, shard_index, k, m,
                  shard_size, total_data_size, stored_at, storage_tier, data_hash)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                params![
                    key,
                    server_id,
                    cid,
                    shard_index as i32,
                    k as i32,
                    m as i32,
                    shard_size as i64,
                    total_data_size as i64,
                    now_secs(),
                    tier.as_str(),
                    data_hash,
                ],
            )
            .map_err(|e| format!("Failed to insert shard record: {e}"))?;

        Ok(key)
    }

    /// Read a shard from disk with integrity verification.
    /// Verifies SHA-256(data) matches the stored data_hash.
    pub fn read_shard(&self, server_id: &str, shard_key_str: &str) -> Result<Vec<u8>, String> {
        let path = self.shard_path(server_id, shard_key_str);
        let data =
            std::fs::read(&path).map_err(|e| format!("Failed to read shard file: {e}"))?;

        // Look up expected hash from DB
        let stored_hash: String = self
            .conn
            .query_row(
                "SELECT data_hash FROM vault_shards WHERE shard_key = ?1",
                params![shard_key_str],
                |row| row.get(0),
            )
            .map_err(|e| format!("Shard record not found in DB: {e}"))?;

        let actual_hash = hex::encode(Sha256::digest(&data));
        if actual_hash != stored_hash {
            return Err(format!(
                "Integrity check failed for shard {shard_key_str}: expected {stored_hash}, got {actual_hash}"
            ));
        }

        // Update last_verified
        let _ = self.conn.execute(
            "UPDATE vault_shards SET last_verified = ?1 WHERE shard_key = ?2",
            params![now_secs(), shard_key_str],
        );

        Ok(data)
    }

    /// Read shard data without integrity check (performance path).
    pub fn read_shard_unchecked(
        &self,
        server_id: &str,
        shard_key_str: &str,
    ) -> Result<Vec<u8>, String> {
        let path = self.shard_path(server_id, shard_key_str);
        std::fs::read(&path).map_err(|e| format!("Failed to read shard file: {e}"))
    }

    /// Delete a shard: remove file from disk and record from DB.
    pub fn delete_shard(&self, server_id: &str, shard_key_str: &str) -> Result<(), String> {
        let path = self.shard_path(server_id, shard_key_str);
        let _ = std::fs::remove_file(&path);

        self.conn
            .execute(
                "DELETE FROM vault_shards WHERE shard_key = ?1",
                params![shard_key_str],
            )
            .map_err(|e| format!("Failed to delete shard record: {e}"))?;

        Ok(())
    }

    /// Delete all shards for a content item. Returns count deleted.
    pub fn delete_content(&self, server_id: &str, cid: &str) -> Result<u32, String> {
        // First collect shard keys to delete files
        let mut stmt = self
            .conn
            .prepare("SELECT shard_key FROM vault_shards WHERE server_id = ?1 AND content_id = ?2")
            .map_err(|e| format!("Failed to prepare query: {e}"))?;

        let keys: Vec<String> = stmt
            .query_map(params![server_id, cid], |row| row.get(0))
            .map_err(|e| format!("Failed to query shards: {e}"))?
            .filter_map(|r| r.ok())
            .collect();

        // Delete files
        for key in &keys {
            let path = self.shard_path(server_id, key);
            let _ = std::fs::remove_file(&path);
        }

        // Delete DB records
        let deleted = self
            .conn
            .execute(
                "DELETE FROM vault_shards WHERE server_id = ?1 AND content_id = ?2",
                params![server_id, cid],
            )
            .map_err(|e| format!("Failed to delete content records: {e}"))?;

        Ok(deleted as u32)
    }

    /// List all shards for a server, sorted by content_id + shard_index.
    pub fn list_shards(&self, server_id: &str) -> Result<Vec<ShardRecord>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT shard_key, server_id, content_id, shard_index, k, m,
                        shard_size, total_data_size, stored_at, last_verified,
                        storage_tier, data_hash
                 FROM vault_shards WHERE server_id = ?1
                 ORDER BY content_id, shard_index",
            )
            .map_err(|e| format!("Failed to prepare query: {e}"))?;

        let rows = stmt
            .query_map(params![server_id], |row| Ok(row_to_record(row)))
            .map_err(|e| format!("Failed to query shards: {e}"))?;

        let mut result = Vec::new();
        for row in rows {
            result.push(row.map_err(|e| format!("Failed to read row: {e}"))?);
        }
        Ok(result)
    }

    /// List shards for a specific content item, sorted by shard_index.
    pub fn list_content_shards(
        &self,
        server_id: &str,
        cid: &str,
    ) -> Result<Vec<ShardRecord>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT shard_key, server_id, content_id, shard_index, k, m,
                        shard_size, total_data_size, stored_at, last_verified,
                        storage_tier, data_hash
                 FROM vault_shards WHERE server_id = ?1 AND content_id = ?2
                 ORDER BY shard_index",
            )
            .map_err(|e| format!("Failed to prepare query: {e}"))?;

        let rows = stmt
            .query_map(params![server_id, cid], |row| Ok(row_to_record(row)))
            .map_err(|e| format!("Failed to query content shards: {e}"))?;

        let mut result = Vec::new();
        for row in rows {
            result.push(row.map_err(|e| format!("Failed to read row: {e}"))?);
        }
        Ok(result)
    }

    /// Total storage used by shards for a server (bytes).
    pub fn total_storage_used(&self, server_id: &str) -> Result<u64, String> {
        self.conn
            .query_row(
                "SELECT COALESCE(SUM(shard_size), 0) FROM vault_shards WHERE server_id = ?1",
                params![server_id],
                |row| row.get::<_, i64>(0),
            )
            .map(|v| v as u64)
            .map_err(|e| format!("Failed to query storage used: {e}"))
    }

    /// Total storage used across all servers (bytes).
    pub fn total_storage_used_all(&self) -> Result<u64, String> {
        self.conn
            .query_row(
                "SELECT COALESCE(SUM(shard_size), 0) FROM vault_shards",
                [],
                |row| row.get::<_, i64>(0),
            )
            .map(|v| v as u64)
            .map_err(|e| format!("Failed to query total storage: {e}"))
    }

    /// Check if a shard exists in the DB.
    pub fn has_shard(&self, shard_key_str: &str) -> Result<bool, String> {
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM vault_shards WHERE shard_key = ?1",
                params![shard_key_str],
                |row| row.get::<_, i64>(0),
            )
            .map(|c| c > 0)
            .map_err(|e| format!("Failed to check shard existence: {e}"))
    }

    /// Get metadata for a specific shard (DB lookup only).
    pub fn get_shard_record(&self, shard_key_str: &str) -> Result<Option<ShardRecord>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT shard_key, server_id, content_id, shard_index, k, m,
                        shard_size, total_data_size, stored_at, last_verified,
                        storage_tier, data_hash
                 FROM vault_shards WHERE shard_key = ?1",
            )
            .map_err(|e| format!("Failed to prepare query: {e}"))?;

        let mut rows = stmt
            .query_map(params![shard_key_str], |row| Ok(row_to_record(row)))
            .map_err(|e| format!("Failed to query shard: {e}"))?;

        match rows.next() {
            Some(Ok(record)) => Ok(Some(record)),
            Some(Err(e)) => Err(format!("Failed to read shard record: {e}")),
            None => Ok(None),
        }
    }

    /// Update the last_verified timestamp for a shard.
    pub fn mark_verified(&self, shard_key_str: &str) -> Result<(), String> {
        self.conn
            .execute(
                "UPDATE vault_shards SET last_verified = ?1 WHERE shard_key = ?2",
                params![now_secs(), shard_key_str],
            )
            .map_err(|e| format!("Failed to mark verified: {e}"))?;
        Ok(())
    }

    /// Verify integrity of all shards for a server.
    /// Returns list of shard_keys that failed (corrupt or missing files).
    pub fn verify_server_shards(&self, server_id: &str) -> Result<Vec<String>, String> {
        let records = self.list_shards(server_id)?;
        let mut failed = Vec::new();
        for record in &records {
            if self.read_shard(server_id, &record.shard_key).is_err() {
                failed.push(record.shard_key.clone());
            }
        }
        Ok(failed)
    }

    // ── Placement tracking ───────────────────────────────────

    /// Save shard placements for a content item.
    pub fn save_placements(
        &self,
        server_id: &str,
        cid: &str,
        placements: &[super::placement::ShardPlacement],
    ) -> Result<(), String> {
        for p in placements {
            self.conn
                .execute(
                    "INSERT OR REPLACE INTO vault_placement
                     (content_id, shard_index, target_peer, server_id, shard_key, stored_at, confirmed)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0)",
                    params![
                        cid,
                        p.shard_index as i32,
                        p.target_peer,
                        server_id,
                        p.shard_key,
                        now_secs(),
                    ],
                )
                .map_err(|e| format!("Failed to save placement: {e}"))?;
        }
        Ok(())
    }

    /// Load all placements for a content item, sorted by shard_index.
    pub fn load_placements(&self, cid: &str) -> Result<Vec<PlacementRecord>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT content_id, shard_index, target_peer, server_id, shard_key, stored_at, confirmed
                 FROM vault_placement WHERE content_id = ?1
                 ORDER BY shard_index",
            )
            .map_err(|e| format!("Failed to prepare placement query: {e}"))?;

        let rows = stmt
            .query_map(params![cid], |row| {
                Ok(PlacementRecord {
                    content_id: row.get::<_, String>(0).unwrap_or_default(),
                    shard_index: row.get::<_, i32>(1).unwrap_or(0) as u16,
                    target_peer: row.get::<_, String>(2).unwrap_or_default(),
                    server_id: row.get::<_, String>(3).unwrap_or_default(),
                    shard_key: row.get::<_, String>(4).unwrap_or_default(),
                    stored_at: row.get::<_, i64>(5).unwrap_or(0),
                    confirmed: row.get::<_, i32>(6).unwrap_or(0) != 0,
                })
            })
            .map_err(|e| format!("Failed to query placements: {e}"))?;

        let mut result = Vec::new();
        for row in rows {
            result.push(row.map_err(|e| format!("Failed to read placement row: {e}"))?);
        }
        Ok(result)
    }

    /// Mark a shard placement as confirmed (peer acknowledged receipt).
    pub fn confirm_placement(&self, cid: &str, shard_index: u16) -> Result<(), String> {
        self.conn
            .execute(
                "UPDATE vault_placement SET confirmed = 1
                 WHERE content_id = ?1 AND shard_index = ?2",
                params![cid, shard_index as i32],
            )
            .map_err(|e| format!("Failed to confirm placement: {e}"))?;
        Ok(())
    }

    /// Delete all placements for a content item. Returns count deleted.
    pub fn delete_placements(&self, cid: &str) -> Result<u32, String> {
        let deleted = self
            .conn
            .execute(
                "DELETE FROM vault_placement WHERE content_id = ?1",
                params![cid],
            )
            .map_err(|e| format!("Failed to delete placements: {e}"))?;
        Ok(deleted as u32)
    }

    /// List all placements for a server, sorted by content_id + shard_index.
    pub fn list_server_placements(&self, server_id: &str) -> Result<Vec<PlacementRecord>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT content_id, shard_index, target_peer, server_id, shard_key, stored_at, confirmed
                 FROM vault_placement WHERE server_id = ?1
                 ORDER BY content_id, shard_index",
            )
            .map_err(|e| format!("Failed to prepare server placement query: {e}"))?;

        let rows = stmt
            .query_map(params![server_id], |row| {
                Ok(PlacementRecord {
                    content_id: row.get::<_, String>(0).unwrap_or_default(),
                    shard_index: row.get::<_, i32>(1).unwrap_or(0) as u16,
                    target_peer: row.get::<_, String>(2).unwrap_or_default(),
                    server_id: row.get::<_, String>(3).unwrap_or_default(),
                    shard_key: row.get::<_, String>(4).unwrap_or_default(),
                    stored_at: row.get::<_, i64>(5).unwrap_or(0),
                    confirmed: row.get::<_, i32>(6).unwrap_or(0) != 0,
                })
            })
            .map_err(|e| format!("Failed to query server placements: {e}"))?;

        let mut result = Vec::new();
        for row in rows {
            result.push(row.map_err(|e| format!("Failed to read placement row: {e}"))?);
        }
        Ok(result)
    }

    /// Count unconfirmed placements for a content item.
    pub fn unconfirmed_placement_count(&self, cid: &str) -> Result<u32, String> {
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM vault_placement
                 WHERE content_id = ?1 AND confirmed = 0",
                params![cid],
                |row| row.get::<_, i64>(0),
            )
            .map(|c| c as u32)
            .map_err(|e| format!("Failed to count unconfirmed placements: {e}"))
    }
}

/// Map a DB row to a ShardRecord.
fn row_to_record(row: &rusqlite::Row) -> ShardRecord {
    ShardRecord {
        shard_key: row.get::<_, String>(0).unwrap_or_default(),
        server_id: row.get::<_, String>(1).unwrap_or_default(),
        content_id: row.get::<_, String>(2).unwrap_or_default(),
        shard_index: row.get::<_, i32>(3).unwrap_or(0) as u16,
        k: row.get::<_, i32>(4).unwrap_or(0) as u16,
        m: row.get::<_, i32>(5).unwrap_or(0) as u16,
        shard_size: row.get::<_, i64>(6).unwrap_or(0) as u64,
        total_data_size: row.get::<_, i64>(7).unwrap_or(0) as u64,
        stored_at: row.get::<_, i64>(8).unwrap_or(0),
        last_verified: row.get::<_, Option<i64>>(9).unwrap_or(None),
        storage_tier: StorageTier::from_str(&row.get::<_, String>(10).unwrap_or_default()),
        data_hash: row.get::<_, String>(11).unwrap_or_default(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    /// Create a ContentStore backed by in-memory SQLCipher and a temp directory.
    fn test_store() -> (ContentStore, TempDir) {
        let tmp = TempDir::new().unwrap();
        let store = ContentStore::open(":memory:", "testkey", tmp.path()).unwrap();
        (store, tmp)
    }

    // ── Pure function tests ──────────────────────────────────

    #[test]
    fn content_id_deterministic() {
        let a = content_id(b"hello vault");
        let b = content_id(b"hello vault");
        assert_eq!(a, b);
        let c = content_id(b"different data");
        assert_ne!(a, c);
    }

    #[test]
    fn content_id_hex_length() {
        let id = content_id(b"test data");
        assert_eq!(id.len(), 64);
        assert!(id.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn content_id_empty_data() {
        let id = content_id(b"");
        assert_eq!(id.len(), 64);
        // SHA-256 of empty = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        assert_eq!(
            id,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn shard_key_deterministic() {
        let a = shard_key("abc123", 5);
        let b = shard_key("abc123", 5);
        assert_eq!(a, b);
    }

    #[test]
    fn shard_key_varies_with_index() {
        let a = shard_key("content1", 0);
        let b = shard_key("content1", 1);
        let c = shard_key("content1", 256);
        assert_ne!(a, b);
        assert_ne!(a, c);
        assert_ne!(b, c);
    }

    #[test]
    fn shard_key_varies_with_content_id() {
        let a = shard_key("aaa", 0);
        let b = shard_key("bbb", 0);
        assert_ne!(a, b);
    }

    #[test]
    fn shard_key_hex_length() {
        let key = shard_key("test", 42);
        assert_eq!(key.len(), 64);
        assert!(key.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn storage_tier_round_trip() {
        assert_eq!(
            StorageTier::from_str(StorageTier::Standard.as_str()),
            StorageTier::Standard
        );
        assert_eq!(
            StorageTier::from_str(StorageTier::Low.as_str()),
            StorageTier::Low
        );
    }

    #[test]
    fn storage_tier_default() {
        assert_eq!(StorageTier::from_str("unknown"), StorageTier::Standard);
        assert_eq!(StorageTier::from_str(""), StorageTier::Standard);
    }

    // ── DB + disk tests ──────────────────────────────────────

    #[test]
    fn store_and_read_shard() {
        let (store, _tmp) = test_store();
        let data = b"shard data payload";
        let key = store
            .store_shard("srv1", "cid1", 0, 3, 2, 1000, StorageTier::Standard, data)
            .unwrap();
        assert_eq!(key.len(), 64);

        let read_back = store.read_shard("srv1", &key).unwrap();
        assert_eq!(read_back, data);
    }

    #[test]
    fn read_shard_integrity_pass() {
        let (store, _tmp) = test_store();
        let data = b"integrity test data";
        let key = store
            .store_shard("srv1", "cid1", 0, 3, 2, 500, StorageTier::Standard, data)
            .unwrap();
        // Should succeed — data matches hash
        assert!(store.read_shard("srv1", &key).is_ok());
    }

    #[test]
    fn read_shard_integrity_fail() {
        let (store, _tmp) = test_store();
        let data = b"original data";
        let key = store
            .store_shard("srv1", "cid1", 0, 3, 2, 500, StorageTier::Standard, data)
            .unwrap();

        // Corrupt the file on disk
        let path = store.shard_path("srv1", &key);
        std::fs::write(&path, b"corrupted!!").unwrap();

        let result = store.read_shard("srv1", &key);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("Integrity check failed"));
    }

    #[test]
    fn read_shard_missing_file() {
        let (store, _tmp) = test_store();
        let result = store.read_shard("srv1", "nonexistent_key");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("Failed to read"));
    }

    #[test]
    fn delete_shard() {
        let (store, _tmp) = test_store();
        let data = b"to be deleted";
        let key = store
            .store_shard("srv1", "cid1", 0, 3, 2, 500, StorageTier::Standard, data)
            .unwrap();

        assert!(store.has_shard(&key).unwrap());
        let path = store.shard_path("srv1", &key);
        assert!(path.exists());

        store.delete_shard("srv1", &key).unwrap();
        assert!(!store.has_shard(&key).unwrap());
        assert!(!path.exists());
    }

    #[test]
    fn delete_content() {
        let (store, _tmp) = test_store();
        // Store 3 shards for same content
        for i in 0..3u16 {
            store
                .store_shard(
                    "srv1",
                    "cid1",
                    i,
                    3,
                    2,
                    1000,
                    StorageTier::Standard,
                    &[i as u8; 10],
                )
                .unwrap();
        }
        // Store 1 shard for different content
        store
            .store_shard(
                "srv1",
                "cid2",
                0,
                3,
                2,
                500,
                StorageTier::Standard,
                b"other",
            )
            .unwrap();

        let deleted = store.delete_content("srv1", "cid1").unwrap();
        assert_eq!(deleted, 3);

        // cid1 shards gone
        assert!(store.list_content_shards("srv1", "cid1").unwrap().is_empty());
        // cid2 still there
        assert_eq!(store.list_content_shards("srv1", "cid2").unwrap().len(), 1);
    }

    #[test]
    fn list_shards() {
        let (store, _tmp) = test_store();
        store
            .store_shard(
                "srv1",
                "cid_b",
                0,
                3,
                2,
                100,
                StorageTier::Standard,
                b"b0",
            )
            .unwrap();
        store
            .store_shard(
                "srv1",
                "cid_a",
                0,
                3,
                2,
                100,
                StorageTier::Standard,
                b"a0",
            )
            .unwrap();
        store
            .store_shard(
                "srv1",
                "cid_a",
                1,
                3,
                2,
                100,
                StorageTier::Standard,
                b"a1",
            )
            .unwrap();

        let shards = store.list_shards("srv1").unwrap();
        assert_eq!(shards.len(), 3);
        // Sorted by content_id then shard_index
        assert_eq!(shards[0].content_id, "cid_a");
        assert_eq!(shards[0].shard_index, 0);
        assert_eq!(shards[1].content_id, "cid_a");
        assert_eq!(shards[1].shard_index, 1);
        assert_eq!(shards[2].content_id, "cid_b");
    }

    #[test]
    fn list_content_shards() {
        let (store, _tmp) = test_store();
        for i in 0..3u16 {
            store
                .store_shard(
                    "srv1",
                    "cid1",
                    i,
                    3,
                    2,
                    100,
                    StorageTier::Standard,
                    &[i as u8; 5],
                )
                .unwrap();
        }
        store
            .store_shard(
                "srv1",
                "cid2",
                0,
                3,
                2,
                100,
                StorageTier::Standard,
                b"other",
            )
            .unwrap();

        let shards = store.list_content_shards("srv1", "cid1").unwrap();
        assert_eq!(shards.len(), 3);
        assert_eq!(shards[0].shard_index, 0);
        assert_eq!(shards[1].shard_index, 1);
        assert_eq!(shards[2].shard_index, 2);
    }

    #[test]
    fn total_storage_used() {
        let (store, _tmp) = test_store();
        store
            .store_shard(
                "srv1",
                "cid1",
                0,
                3,
                2,
                100,
                StorageTier::Standard,
                &[0u8; 100],
            )
            .unwrap();
        store
            .store_shard(
                "srv1",
                "cid1",
                1,
                3,
                2,
                100,
                StorageTier::Standard,
                &[0u8; 200],
            )
            .unwrap();

        assert_eq!(store.total_storage_used("srv1").unwrap(), 300);
    }

    #[test]
    fn total_storage_used_empty() {
        let (store, _tmp) = test_store();
        assert_eq!(store.total_storage_used("srv1").unwrap(), 0);
    }

    #[test]
    fn has_shard_true_false() {
        let (store, _tmp) = test_store();
        let key = store
            .store_shard(
                "srv1",
                "cid1",
                0,
                3,
                2,
                100,
                StorageTier::Standard,
                b"data",
            )
            .unwrap();

        assert!(store.has_shard(&key).unwrap());
        assert!(!store.has_shard("nonexistent").unwrap());
    }

    #[test]
    fn store_overwrites() {
        let (store, _tmp) = test_store();
        let key = store
            .store_shard(
                "srv1",
                "cid1",
                0,
                3,
                2,
                100,
                StorageTier::Standard,
                b"original",
            )
            .unwrap();
        // Re-store with different data
        let key2 = store
            .store_shard(
                "srv1",
                "cid1",
                0,
                3,
                2,
                100,
                StorageTier::Standard,
                b"updated",
            )
            .unwrap();
        assert_eq!(key, key2);

        let data = store.read_shard("srv1", &key).unwrap();
        assert_eq!(data, b"updated");
    }

    #[test]
    fn mark_verified() {
        let (store, _tmp) = test_store();
        let key = store
            .store_shard(
                "srv1",
                "cid1",
                0,
                3,
                2,
                100,
                StorageTier::Standard,
                b"data",
            )
            .unwrap();

        // Initially no last_verified
        let record = store.get_shard_record(&key).unwrap().unwrap();
        assert!(record.last_verified.is_none());

        store.mark_verified(&key).unwrap();

        let record = store.get_shard_record(&key).unwrap().unwrap();
        assert!(record.last_verified.is_some());
    }

    #[test]
    fn get_shard_record_some_none() {
        let (store, _tmp) = test_store();
        assert!(store.get_shard_record("nonexistent").unwrap().is_none());

        let key = store
            .store_shard(
                "srv1",
                "cid1",
                2,
                5,
                3,
                999,
                StorageTier::Low,
                b"data",
            )
            .unwrap();

        let record = store.get_shard_record(&key).unwrap().unwrap();
        assert_eq!(record.shard_key, key);
        assert_eq!(record.server_id, "srv1");
        assert_eq!(record.content_id, "cid1");
        assert_eq!(record.shard_index, 2);
        assert_eq!(record.k, 5);
        assert_eq!(record.m, 3);
        assert_eq!(record.total_data_size, 999);
        assert_eq!(record.storage_tier, StorageTier::Low);
    }

    #[test]
    fn verify_server_shards_all_good() {
        let (store, _tmp) = test_store();
        for i in 0..3u16 {
            store
                .store_shard(
                    "srv1",
                    "cid1",
                    i,
                    3,
                    2,
                    100,
                    StorageTier::Standard,
                    &[i as u8; 20],
                )
                .unwrap();
        }
        let failed = store.verify_server_shards("srv1").unwrap();
        assert!(failed.is_empty());
    }

    #[test]
    fn verify_server_shards_one_corrupt() {
        let (store, _tmp) = test_store();
        let mut keys = Vec::new();
        for i in 0..3u16 {
            let key = store
                .store_shard(
                    "srv1",
                    "cid1",
                    i,
                    3,
                    2,
                    100,
                    StorageTier::Standard,
                    &[i as u8; 20],
                )
                .unwrap();
            keys.push(key);
        }

        // Corrupt shard 1
        let path = store.shard_path("srv1", &keys[1]);
        std::fs::write(&path, b"garbage").unwrap();

        let failed = store.verify_server_shards("srv1").unwrap();
        assert_eq!(failed.len(), 1);
        assert_eq!(failed[0], keys[1]);
    }

    #[test]
    fn server_isolation() {
        let (store, _tmp) = test_store();
        store
            .store_shard(
                "srv1",
                "cid1",
                0,
                3,
                2,
                100,
                StorageTier::Standard,
                &[0u8; 50],
            )
            .unwrap();
        store
            .store_shard(
                "srv2",
                "cid2",
                0,
                3,
                2,
                100,
                StorageTier::Standard,
                &[0u8; 80],
            )
            .unwrap();

        assert_eq!(store.list_shards("srv1").unwrap().len(), 1);
        assert_eq!(store.list_shards("srv2").unwrap().len(), 1);
        assert_eq!(store.total_storage_used("srv1").unwrap(), 50);
        assert_eq!(store.total_storage_used("srv2").unwrap(), 80);
        assert_eq!(store.total_storage_used_all().unwrap(), 130);
    }

    // ── Placement DB tests ───────────────────────────────────

    #[test]
    fn save_and_load_placement() {
        let (store, _tmp) = test_store();
        let placements = vec![
            crate::vault::placement::ShardPlacement {
                shard_index: 0,
                target_peer: "peer_a".to_string(),
                shard_key: "sk0".to_string(),
            },
            crate::vault::placement::ShardPlacement {
                shard_index: 1,
                target_peer: "peer_b".to_string(),
                shard_key: "sk1".to_string(),
            },
        ];
        store.save_placements("srv1", "cid1", &placements).unwrap();

        let loaded = store.load_placements("cid1").unwrap();
        assert_eq!(loaded.len(), 2);
        assert_eq!(loaded[0].shard_index, 0);
        assert_eq!(loaded[0].target_peer, "peer_a");
        assert_eq!(loaded[0].server_id, "srv1");
        assert!(!loaded[0].confirmed);
        assert_eq!(loaded[1].shard_index, 1);
        assert_eq!(loaded[1].target_peer, "peer_b");
    }

    #[test]
    fn confirm_placement_test() {
        let (store, _tmp) = test_store();
        let placements = vec![crate::vault::placement::ShardPlacement {
            shard_index: 0,
            target_peer: "peer_a".to_string(),
            shard_key: "sk0".to_string(),
        }];
        store.save_placements("srv1", "cid1", &placements).unwrap();
        assert_eq!(store.unconfirmed_placement_count("cid1").unwrap(), 1);

        store.confirm_placement("cid1", 0).unwrap();
        let loaded = store.load_placements("cid1").unwrap();
        assert!(loaded[0].confirmed);
        assert_eq!(store.unconfirmed_placement_count("cid1").unwrap(), 0);
    }

    #[test]
    fn delete_placement_test() {
        let (store, _tmp) = test_store();
        let placements = vec![
            crate::vault::placement::ShardPlacement {
                shard_index: 0,
                target_peer: "peer_a".to_string(),
                shard_key: "sk0".to_string(),
            },
            crate::vault::placement::ShardPlacement {
                shard_index: 1,
                target_peer: "peer_b".to_string(),
                shard_key: "sk1".to_string(),
            },
        ];
        store.save_placements("srv1", "cid1", &placements).unwrap();
        assert_eq!(store.load_placements("cid1").unwrap().len(), 2);

        let deleted = store.delete_placements("cid1").unwrap();
        assert_eq!(deleted, 2);
        assert!(store.load_placements("cid1").unwrap().is_empty());
    }
}
