use std::collections::HashMap;

use rusqlite::{params, Connection};

use crate::crdt::operations::CrdtOp;

/// A user profile stored locally (ours or a peer's).
pub(crate) struct StoredProfile {
    pub peer_id: String,
    pub display_name: String,
    pub status: String,
    pub about_me: String,
    pub updated_at: i64,
    pub avatar_bytes: Option<Vec<u8>>,
    pub banner_bytes: Option<Vec<u8>>,
    pub twitch_username: String,
}

/// A stored chat message.
pub(crate) struct StoredMessage {
    pub id: i64,
    pub peer_id: String,
    pub text: String,
    pub is_mine: bool,
    pub timestamp: i64,
    pub signature: Option<String>,
    pub public_key: Option<String>,
    pub message_id: Option<String>,
    pub edited_at: Option<i64>,
    pub hidden_at: Option<i64>,
    pub reply_to_mid: Option<String>,
    pub file_id: Option<String>,
    /// Link preview for the first URL in the message (Phase 6.75).
    /// Persisted as JSON in the `link_preview_json` column. None for
    /// messages with no previewable URL.
    pub link_preview: Option<crate::node::LinkPreviewRef>,
}

/// A stored channel message.
pub(crate) struct StoredChannelMessage {
    pub id: i64,
    pub server_id: String,
    pub channel_id: String,
    pub sender_id: String,
    pub text: String,
    pub is_mine: bool,
    pub timestamp: i64,
    pub signature: Option<String>,
    pub public_key: Option<String>,
    pub message_id: Option<String>,
    pub edited_at: Option<i64>,
    pub hidden_at: Option<i64>,
    pub reply_to_mid: Option<String>,
    pub file_id: Option<String>,
    /// Link preview for the first URL in the message (Phase 6.75).
    /// Persisted as JSON in the `link_preview_json` column. None for
    /// messages with no previewable URL.
    pub link_preview: Option<crate::node::LinkPreviewRef>,
}

/// A stored file metadata entry.
pub(crate) struct StoredFile {
    pub file_id: String,
    pub file_name: String,
    pub file_ext: String,
    pub mime_type: String,
    pub size_bytes: u64,
    pub chunk_count: u32,
    pub chunks_received: u32,
    pub is_image: bool,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub message_id: Option<String>,
    pub context_type: String,  // "dm" or "channel"
    pub context_id: String,    // peer_id for DM, "server_id:channel_id" for channel
    pub sender_id: String,
    pub is_mine: bool,
    pub created_at: i64,
    pub completed_at: Option<i64>,
    pub disk_path: Option<String>,
    pub hidden_at: Option<i64>,
    pub expired_at: Option<i64>,
    /// Video thumbnail back-reference (Phase 6.75 video preview).
    /// When this file is a thumbnail image for a vault-stored video, this field
    /// holds the link back to the underlying video. Persisted as JSON in the
    /// `video_thumb_json` column. None for regular files and images.
    pub video_thumb: Option<crate::node::VideoThumbRef>,
}

/// Encrypted SQLite message store.
pub(crate) struct MessageStore {
    conn: Connection,
}

impl MessageStore {
    /// Open (or create) an encrypted database at `path` using `passphrase`.
    pub fn open(path: &str, passphrase: &str) -> Result<Self, String> {
        let conn =
            Connection::open(path).map_err(|e| format!("Failed to open database: {e}"))?;

        // Set encryption key BEFORE any other operations.
        // Use x'' hex key format to avoid SQL injection and quoting issues.
        conn.execute_batch(&format!("PRAGMA key = \"x'{}'\";", passphrase))
            .map_err(|e| format!("Failed to set encryption key: {e}"))?;

        // Create messages table if it doesn't exist.
        conn.execute(
            "CREATE TABLE IF NOT EXISTS messages (
                id        INTEGER PRIMARY KEY AUTOINCREMENT,
                peer_id   TEXT    NOT NULL,
                text      TEXT    NOT NULL,
                is_mine   INTEGER NOT NULL,
                timestamp INTEGER NOT NULL
            )",
            [],
        )
        .map_err(|e| format!("Failed to create messages table: {e}"))?;

        // Index for fast per-peer lookups.
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_messages_peer_ts ON messages (peer_id, timestamp)",
            [],
        )
        .map_err(|e| format!("Failed to create index: {e}"))?;

        // Olm account pickle (singleton row, id=1).
        conn.execute(
            "CREATE TABLE IF NOT EXISTS olm_account (
                id     INTEGER PRIMARY KEY CHECK (id = 1),
                pickle TEXT NOT NULL
            )",
            [],
        )
        .map_err(|e| format!("Failed to create olm_account table: {e}"))?;

        // Olm sessions, one per peer.
        conn.execute(
            "CREATE TABLE IF NOT EXISTS olm_sessions (
                peer_id TEXT PRIMARY KEY,
                pickle  TEXT NOT NULL
            )",
            [],
        )
        .map_err(|e| format!("Failed to create olm_sessions table: {e}"))?;

        // Channel messages table.
        conn.execute(
            "CREATE TABLE IF NOT EXISTS channel_messages (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                server_id  TEXT    NOT NULL,
                channel_id TEXT    NOT NULL,
                sender_id  TEXT    NOT NULL,
                text       TEXT    NOT NULL,
                is_mine    INTEGER NOT NULL,
                timestamp  INTEGER NOT NULL,
                UNIQUE(server_id, channel_id, sender_id, timestamp, text)
            )",
            [],
        )
        .map_err(|e| format!("Failed to create channel_messages table: {e}"))?;

        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_channel_msgs ON channel_messages (server_id, channel_id, timestamp)",
            [],
        )
        .map_err(|e| format!("Failed to create channel_messages index: {e}"))?;

        // Migration: add UNIQUE constraint to existing channel_messages tables.
        // SQLite can't ALTER constraints, so we create a unique index instead.
        // This also deduplicates existing rows (OR IGNORE skips dupes).
        conn.execute_batch(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_channel_msgs_unique
             ON channel_messages (server_id, channel_id, sender_id, timestamp, text);
             DELETE FROM channel_messages WHERE id NOT IN (
                SELECT MIN(id) FROM channel_messages
                GROUP BY server_id, channel_id, sender_id, timestamp, text
             );"
        ).unwrap_or_else(|e| {
            // If index creation fails because dupes exist, clean up first.
            eprintln!("[HOLLOW] Deduplicating channel_messages: {e}");
            let _ = conn.execute_batch(
                "DELETE FROM channel_messages WHERE id NOT IN (
                    SELECT MIN(id) FROM channel_messages
                    GROUP BY server_id, channel_id, sender_id, timestamp, text
                 );
                 CREATE UNIQUE INDEX IF NOT EXISTS idx_channel_msgs_unique
                 ON channel_messages (server_id, channel_id, sender_id, timestamp, text);"
            );
        });

        // -- CRDT tables (Phase 3) --

        conn.execute(
            "CREATE TABLE IF NOT EXISTS servers (
                server_id  TEXT PRIMARY KEY,
                state_json TEXT NOT NULL,
                updated_at INTEGER NOT NULL
            )",
            [],
        )
        .map_err(|e| format!("Failed to create servers table: {e}"))?;

        conn.execute(
            "CREATE TABLE IF NOT EXISTS crdt_ops (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                server_id   TEXT NOT NULL,
                hlc_ms      INTEGER NOT NULL,
                hlc_counter INTEGER NOT NULL,
                author      TEXT NOT NULL,
                op_json     TEXT NOT NULL,
                UNIQUE(server_id, hlc_ms, hlc_counter, author)
            )",
            [],
        )
        .map_err(|e| format!("Failed to create crdt_ops table: {e}"))?;

        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_crdt_ops_server ON crdt_ops (server_id, hlc_ms)",
            [],
        )
        .map_err(|e| format!("Failed to create crdt_ops index: {e}"))?;

        conn.execute(
            "CREATE TABLE IF NOT EXISTS hlc_state (
                id          INTEGER PRIMARY KEY CHECK (id = 1),
                physical_ms INTEGER NOT NULL,
                counter     INTEGER NOT NULL,
                actor       TEXT NOT NULL
            )",
            [],
        )
        .map_err(|e| format!("Failed to create hlc_state table: {e}"))?;

        // -- Migration: Ed25519 signature columns --
        // ALTER TABLE ADD COLUMN is safe for nullable columns in SQLite.
        // Silently ignore if columns already exist.
        conn.execute_batch(
            "ALTER TABLE channel_messages ADD COLUMN signature TEXT;"
        ).unwrap_or(());
        conn.execute_batch(
            "ALTER TABLE channel_messages ADD COLUMN public_key TEXT;"
        ).unwrap_or(());
        conn.execute_batch(
            "ALTER TABLE messages ADD COLUMN signature TEXT;"
        ).unwrap_or(());
        conn.execute_batch(
            "ALTER TABLE messages ADD COLUMN public_key TEXT;"
        ).unwrap_or(());

        // -- Migration: DM deduplication unique index --
        // Allows INSERT OR IGNORE for DM sync (like channel_messages).
        conn.execute_batch(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_dedup
             ON messages (peer_id, timestamp, text, is_mine);"
        ).unwrap_or(());

        // -- User profiles (Phase 3.5) --
        conn.execute(
            "CREATE TABLE IF NOT EXISTS user_profiles (
                peer_id      TEXT PRIMARY KEY,
                display_name TEXT NOT NULL DEFAULT '',
                status       TEXT NOT NULL DEFAULT '',
                about_me     TEXT NOT NULL DEFAULT '',
                updated_at   INTEGER NOT NULL DEFAULT 0
            )",
            [],
        )
        .map_err(|e| format!("Failed to create user_profiles table: {e}"))?;

        // -- Migration: message_id + edited_at columns (Phase 3.5 editing) --
        conn.execute_batch(
            "ALTER TABLE messages ADD COLUMN message_id TEXT;"
        ).unwrap_or(());
        conn.execute_batch(
            "ALTER TABLE messages ADD COLUMN edited_at INTEGER;"
        ).unwrap_or(());
        conn.execute_batch(
            "ALTER TABLE channel_messages ADD COLUMN message_id TEXT;"
        ).unwrap_or(());
        conn.execute_batch(
            "ALTER TABLE channel_messages ADD COLUMN edited_at INTEGER;"
        ).unwrap_or(());

        // Index on message_id for fast edit lookups.
        conn.execute_batch(
            "CREATE INDEX IF NOT EXISTS idx_messages_msg_id ON messages (message_id);"
        ).unwrap_or(());
        conn.execute_batch(
            "CREATE INDEX IF NOT EXISTS idx_channel_msgs_msg_id ON channel_messages (message_id);"
        ).unwrap_or(());

        // Edit history table — preserves previous text for Rat Files evidence.
        conn.execute(
            "CREATE TABLE IF NOT EXISTS message_edits (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                message_id  TEXT    NOT NULL,
                old_text    TEXT    NOT NULL,
                new_text    TEXT    NOT NULL,
                edited_at   INTEGER NOT NULL,
                signature   TEXT,
                public_key  TEXT
            )",
            [],
        )
        .map_err(|e| format!("Failed to create message_edits table: {e}"))?;

        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_edits_msg_id ON message_edits (message_id)",
            [],
        )
        .map_err(|e| format!("Failed to create message_edits index: {e}"))?;

        // -- Migration: prev_signature/prev_public_key/prev_timestamp for edit chain provenance --
        conn.execute_batch(
            "ALTER TABLE message_edits ADD COLUMN prev_signature TEXT;"
        ).unwrap_or(());
        conn.execute_batch(
            "ALTER TABLE message_edits ADD COLUMN prev_public_key TEXT;"
        ).unwrap_or(());
        conn.execute_batch(
            "ALTER TABLE message_edits ADD COLUMN prev_timestamp INTEGER;"
        ).unwrap_or(());

        // -- Migration: hidden_at column for message deletion/hiding (Phase 3.5) --
        conn.execute_batch(
            "ALTER TABLE messages ADD COLUMN hidden_at INTEGER;"
        ).unwrap_or(());
        conn.execute_batch(
            "ALTER TABLE channel_messages ADD COLUMN hidden_at INTEGER;"
        ).unwrap_or(());

        // Deletion evidence table — preserves text at time of deletion for Rat Files.
        conn.execute(
            "CREATE TABLE IF NOT EXISTS message_deletions (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                message_id  TEXT    NOT NULL,
                deleted_text TEXT   NOT NULL,
                deleted_at  INTEGER NOT NULL,
                signature   TEXT,
                public_key  TEXT
            )",
            [],
        )
        .map_err(|e| format!("Failed to create message_deletions table: {e}"))?;

        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_deletions_msg_id ON message_deletions (message_id)",
            [],
        )
        .map_err(|e| format!("Failed to create message_deletions index: {e}"))?;

        // -- Migration: reply_to_mid column for reply chains (Phase 3.5) --
        conn.execute_batch(
            "ALTER TABLE messages ADD COLUMN reply_to_mid TEXT;"
        ).unwrap_or(());
        conn.execute_batch(
            "ALTER TABLE channel_messages ADD COLUMN reply_to_mid TEXT;"
        ).unwrap_or(());

        // -- Emoji reactions (Phase 3.5) --
        conn.execute(
            "CREATE TABLE IF NOT EXISTS message_reactions (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                message_id TEXT    NOT NULL,
                emoji      TEXT    NOT NULL,
                peer_id    TEXT    NOT NULL,
                added_at   INTEGER NOT NULL,
                signature  TEXT,
                public_key TEXT,
                UNIQUE(message_id, emoji, peer_id)
            )",
            [],
        )
        .map_err(|e| format!("Failed to create message_reactions table: {e}"))?;

        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_reactions_msg_id ON message_reactions (message_id)",
            [],
        )
        .map_err(|e| format!("Failed to create reactions index: {e}"))?;

        // Reaction removal history (Rat Files evidence).
        conn.execute(
            "CREATE TABLE IF NOT EXISTS reaction_removals (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                message_id TEXT    NOT NULL,
                emoji      TEXT    NOT NULL,
                peer_id    TEXT    NOT NULL,
                removed_at INTEGER NOT NULL,
                signature  TEXT,
                public_key TEXT
            )",
            [],
        )
        .map_err(|e| format!("Failed to create reaction_removals table: {e}"))?;

        // -- App settings (key-value, general purpose) --
        conn.execute(
            "CREATE TABLE IF NOT EXISTS friends (
                peer_id      TEXT PRIMARY KEY,
                status       TEXT NOT NULL,
                direction    TEXT NOT NULL DEFAULT '',
                requested_at INTEGER NOT NULL DEFAULT 0,
                updated_at   INTEGER NOT NULL DEFAULT 0
            )",
            [],
        )
        .map_err(|e| format!("Failed to create friends table: {e}"))?;

        conn.execute(
            "CREATE TABLE IF NOT EXISTS app_settings (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )",
            [],
        )
        .map_err(|e| format!("Failed to create app_settings table: {e}"))?;

        // -- MLS identity (singleton row, id=1) --
        conn.execute(
            "CREATE TABLE IF NOT EXISTS mls_identity (
                id              INTEGER PRIMARY KEY CHECK (id = 1),
                signer_data     BLOB NOT NULL,
                credential_data BLOB NOT NULL,
                storage_data    BLOB
            )",
            [],
        )
        .map_err(|e| format!("Failed to create mls_identity table: {e}"))?;

        // -- File sharing (Phase 3.5) --
        conn.execute(
            "CREATE TABLE IF NOT EXISTS files (
                file_id         TEXT PRIMARY KEY,
                file_name       TEXT NOT NULL,
                file_ext        TEXT NOT NULL,
                mime_type       TEXT NOT NULL,
                size_bytes      INTEGER NOT NULL,
                chunk_count     INTEGER NOT NULL,
                chunks_received INTEGER NOT NULL DEFAULT 0,
                is_image        INTEGER NOT NULL DEFAULT 0,
                width           INTEGER,
                height          INTEGER,
                message_id      TEXT,
                context_type    TEXT NOT NULL,
                context_id      TEXT NOT NULL,
                sender_id       TEXT NOT NULL,
                is_mine         INTEGER NOT NULL DEFAULT 0,
                created_at      INTEGER NOT NULL,
                completed_at    INTEGER,
                disk_path       TEXT,
                hidden_at       INTEGER
            )",
            [],
        )
        .map_err(|e| format!("Failed to create files table: {e}"))?;

        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_files_message ON files (message_id)",
            [],
        )
        .map_err(|e| format!("Failed to create files message_id index: {e}"))?;

        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_files_context ON files (context_type, context_id)",
            [],
        )
        .map_err(|e| format!("Failed to create files context index: {e}"))?;

        // -- Migration: video_thumb_json column (Phase 6.75 video preview).
        // Stores a JSON-encoded VideoThumbRef when this file is a thumbnail
        // for a vault-stored video. Wrapped in unwrap_or to handle re-runs.
        conn.execute_batch(
            "ALTER TABLE files ADD COLUMN video_thumb_json TEXT;"
        ).unwrap_or(());

        // Timestamp when the file was expired by the retention timer.
        // NULL = not expired. Non-null = file data deleted from disk, row kept as placeholder.
        conn.execute_batch(
            "ALTER TABLE files ADD COLUMN expired_at INTEGER;"
        ).unwrap_or(());

        conn.execute(
            "CREATE TABLE IF NOT EXISTS file_chunks (
                file_id     TEXT    NOT NULL,
                chunk_index INTEGER NOT NULL,
                received_at INTEGER NOT NULL,
                PRIMARY KEY (file_id, chunk_index)
            )",
            [],
        )
        .map_err(|e| format!("Failed to create file_chunks table: {e}"))?;

        // -- Migration: file_id column on messages --
        conn.execute_batch(
            "ALTER TABLE messages ADD COLUMN file_id TEXT;"
        ).unwrap_or(());
        conn.execute_batch(
            "ALTER TABLE channel_messages ADD COLUMN file_id TEXT;"
        ).unwrap_or(());

        // -- Migration: link_preview_json column (Phase 6.75 link previews).
        // Stores a JSON-encoded LinkPreviewRef for messages that previewed a URL.
        // Populated by update_link_preview / update_channel_link_preview after
        // the message row is inserted.
        conn.execute_batch(
            "ALTER TABLE messages ADD COLUMN link_preview_json TEXT;"
        ).unwrap_or(());
        conn.execute_batch(
            "ALTER TABLE channel_messages ADD COLUMN link_preview_json TEXT;"
        ).unwrap_or(());

        // -- Migration: avatar/banner BLOB columns on user_profiles --
        conn.execute_batch(
            "ALTER TABLE user_profiles ADD COLUMN avatar BLOB;"
        ).unwrap_or(());
        conn.execute_batch(
            "ALTER TABLE user_profiles ADD COLUMN banner BLOB;"
        ).unwrap_or(());
        conn.execute_batch(
            "ALTER TABLE user_profiles ADD COLUMN twitch_username TEXT NOT NULL DEFAULT '';"
        ).unwrap_or(());

        // -- Migration: content_id column on files (vault ↔ file_id link) --
        conn.execute_batch(
            "ALTER TABLE files ADD COLUMN content_id TEXT;"
        ).unwrap_or(());

        // -- Verified peers (RAT Files — peer identity verification) --
        conn.execute(
            "CREATE TABLE IF NOT EXISTS verified_peers (
                peer_id     TEXT PRIMARY KEY,
                verified_at INTEGER NOT NULL
            )",
            [],
        )
        .map_err(|e| format!("Failed to create verified_peers table: {e}"))?;

        // -- Hollow Share (Phase 7A) --
        // One row per share we've created, opened, or downloaded. The encryption_key
        // is the AES-256-GCM key from the share link; if the user loses the link
        // and the row is gone, the file is unrecoverable (which is the point).
        conn.execute(
            "CREATE TABLE IF NOT EXISTS shares (
                root_hash       TEXT PRIMARY KEY,
                file_name       TEXT NOT NULL,
                file_ext        TEXT NOT NULL,
                mime            TEXT NOT NULL,
                total_size      INTEGER NOT NULL,
                chunk_size      INTEGER NOT NULL,
                chunk_count     INTEGER NOT NULL,
                manifest_json   TEXT NOT NULL,
                encryption_key  BLOB NOT NULL,
                share_link      TEXT NOT NULL,
                state           TEXT NOT NULL,
                seeding         INTEGER NOT NULL DEFAULT 1,
                disk_path       TEXT,
                save_dir        TEXT,
                bytes_uploaded  INTEGER NOT NULL DEFAULT 0,
                created_at      INTEGER NOT NULL,
                completed_at    INTEGER
            )",
            [],
        )
        .map_err(|e| format!("Failed to create shares table: {e}"))?;
        // Idempotent migrations for existing dbs.
        conn.execute_batch("ALTER TABLE shares ADD COLUMN save_dir TEXT;").unwrap_or(());
        conn.execute_batch("ALTER TABLE shares ADD COLUMN server_id TEXT;").unwrap_or(());
        conn.execute_batch("ALTER TABLE shares ADD COLUMN context_type TEXT;").unwrap_or(());
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_shares_state ON shares(state)",
            [],
        ).map_err(|e| format!("Failed to create idx_shares_state: {e}"))?;
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_shares_seeding ON shares(seeding)",
            [],
        ).map_err(|e| format!("Failed to create idx_shares_seeding: {e}"))?;

        // Have-bitmap per share, persisted so paused/restarted downloads resume
        // without re-fetching. bitmap_blob is little-endian-packed bits.
        conn.execute(
            "CREATE TABLE IF NOT EXISTS share_chunks (
                root_hash    TEXT PRIMARY KEY,
                bitmap_blob  BLOB NOT NULL,
                updated_at   INTEGER NOT NULL
            )",
            [],
        )
        .map_err(|e| format!("Failed to create share_chunks table: {e}"))?;

        Ok(MessageStore { conn })
    }

    /// Insert a message. Returns the row ID.
    pub fn insert(
        &self,
        peer_id: &str,
        text: &str,
        is_mine: bool,
        timestamp: i64,
        signature: Option<&str>,
        public_key: Option<&str>,
        message_id: Option<&str>,
        reply_to_mid: Option<&str>,
        file_id: Option<&str>,
    ) -> Result<i64, String> {
        let rows = self.conn
            .execute(
                "INSERT OR IGNORE INTO messages (peer_id, text, is_mine, timestamp, signature, public_key, message_id, reply_to_mid, file_id) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![peer_id, text, is_mine as i32, timestamp, signature, public_key, message_id, reply_to_mid, file_id],
            )
            .map_err(|e| format!("Failed to insert message: {e}"))?;
        if rows > 0 {
            Ok(self.conn.last_insert_rowid())
        } else {
            Ok(0) // Duplicate — ignored.
        }
    }

    /// Set the link preview JSON for a DM row identified by `message_id`.
    /// No-op if no row matches. Phase 6.75.
    pub fn update_link_preview(&self, message_id: &str, link_preview_json: &str) -> Result<(), String> {
        self.conn
            .execute(
                "UPDATE messages SET link_preview_json = ?1 WHERE message_id = ?2",
                params![link_preview_json, message_id],
            )
            .map_err(|e| format!("Failed to update link preview: {e}"))?;
        Ok(())
    }

    /// Set the link preview JSON for a channel message row identified by `message_id`.
    /// No-op if no row matches. Phase 6.75.
    pub fn update_channel_link_preview(&self, message_id: &str, link_preview_json: &str) -> Result<(), String> {
        self.conn
            .execute(
                "UPDATE channel_messages SET link_preview_json = ?1 WHERE message_id = ?2",
                params![link_preview_json, message_id],
            )
            .map_err(|e| format!("Failed to update channel link preview: {e}"))?;
        Ok(())
    }

    // -- Olm persistence --

    /// Save (upsert) the Olm account pickle.
    pub fn save_olm_account(&self, pickle_json: &str) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO olm_account (id, pickle) VALUES (1, ?1)
                 ON CONFLICT(id) DO UPDATE SET pickle = excluded.pickle",
                params![pickle_json],
            )
            .map_err(|e| format!("Failed to save olm account: {e}"))?;
        Ok(())
    }

    /// Load the Olm account pickle, if one exists.
    pub fn load_olm_account(&self) -> Result<Option<String>, String> {
        let mut stmt = self
            .conn
            .prepare("SELECT pickle FROM olm_account WHERE id = 1")
            .map_err(|e| format!("Failed to prepare olm_account query: {e}"))?;
        let mut rows = stmt
            .query_map([], |row| row.get(0))
            .map_err(|e| format!("Failed to query olm_account: {e}"))?;
        match rows.next() {
            Some(Ok(pickle)) => Ok(Some(pickle)),
            Some(Err(e)) => Err(format!("Failed to read olm_account row: {e}")),
            None => Ok(None),
        }
    }

    /// Save (upsert) an Olm session pickle for a peer.
    pub fn save_olm_session(&self, peer_id: &str, pickle_json: &str) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO olm_sessions (peer_id, pickle) VALUES (?1, ?2)
                 ON CONFLICT(peer_id) DO UPDATE SET pickle = excluded.pickle",
                params![peer_id, pickle_json],
            )
            .map_err(|e| format!("Failed to save olm session: {e}"))?;
        Ok(())
    }

    /// Load an Olm session pickle for a specific peer.
    #[allow(dead_code)]
    pub fn load_olm_session(&self, peer_id: &str) -> Result<Option<String>, String> {
        let mut stmt = self
            .conn
            .prepare("SELECT pickle FROM olm_sessions WHERE peer_id = ?1")
            .map_err(|e| format!("Failed to prepare olm_sessions query: {e}"))?;
        let mut rows = stmt
            .query_map(params![peer_id], |row| row.get(0))
            .map_err(|e| format!("Failed to query olm_sessions: {e}"))?;
        match rows.next() {
            Some(Ok(pickle)) => Ok(Some(pickle)),
            Some(Err(e)) => Err(format!("Failed to read olm_sessions row: {e}")),
            None => Ok(None),
        }
    }

    /// Load all Olm session pickles (peer_id, pickle_json) pairs.
    pub fn load_all_olm_sessions(&self) -> Result<Vec<(String, String)>, String> {
        let mut stmt = self
            .conn
            .prepare("SELECT peer_id, pickle FROM olm_sessions")
            .map_err(|e| format!("Failed to prepare olm_sessions query: {e}"))?;
        let rows = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .map_err(|e| format!("Failed to query olm_sessions: {e}"))?;
        let mut result = Vec::new();
        for row in rows {
            result.push(row.map_err(|e| format!("Failed to read olm_sessions row: {e}"))?);
        }
        Ok(result)
    }

    /// Load recent messages for a peer, ordered oldest-first.
    /// Hidden (deleted) messages are excluded.
    pub fn load_for_peer(
        &self,
        peer_id: &str,
        limit: i32,
    ) -> Result<Vec<StoredMessage>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, peer_id, text, is_mine, timestamp, signature, public_key, message_id, edited_at, hidden_at, reply_to_mid, file_id, link_preview_json
                 FROM messages
                 WHERE peer_id = ?1 AND hidden_at IS NULL
                 ORDER BY timestamp DESC, id DESC
                 LIMIT ?2",
            )
            .map_err(|e| format!("Failed to prepare query: {e}"))?;

        let rows = stmt
            .query_map(params![peer_id, limit], |row| {
                Ok(StoredMessage {
                    id: row.get(0)?,
                    peer_id: row.get(1)?,
                    text: row.get(2)?,
                    is_mine: row.get::<_, i32>(3)? != 0,
                    timestamp: row.get(4)?,
                    signature: row.get(5)?,
                    public_key: row.get(6)?,
                    message_id: row.get(7)?,
                    edited_at: row.get(8)?,
                    hidden_at: row.get(9)?,
                    reply_to_mid: row.get(10)?,
                    file_id: row.get(11)?,
                    link_preview: row.get::<_, Option<String>>(12)?
                        .and_then(|s| serde_json::from_str(&s).ok()),
                })
            })
            .map_err(|e| format!("Failed to query messages: {e}"))?;

        let mut messages = Vec::new();
        for row in rows {
            messages.push(row.map_err(|e| format!("Failed to read row: {e}"))?);
        }
        messages.reverse(); // Oldest first for display.
        Ok(messages)
    }

    /// Get the latest DM timestamp for a peer (for DM sync requests).
    /// Only considers received messages (is_mine=0) since sync only sends
    /// the other peer's sent messages (their is_mine=1 = our is_mine=0).
    pub fn get_latest_dm_timestamp(
        &self,
        peer_id: &str,
    ) -> Result<Option<i64>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT MAX(timestamp) FROM messages WHERE peer_id = ?1 AND is_mine = 0",
            )
            .map_err(|e| format!("Failed to prepare dm latest timestamp query: {e}"))?;
        let mut rows = stmt
            .query_map(params![peer_id], |row| row.get::<_, Option<i64>>(0))
            .map_err(|e| format!("Failed to query dm latest timestamp: {e}"))?;
        match rows.next() {
            Some(Ok(ts)) => Ok(ts),
            Some(Err(e)) => Err(format!("Failed to read dm latest timestamp: {e}")),
            None => Ok(None),
        }
    }

    /// Get DM messages **we sent** newer than or equal to a given timestamp (for DM sync responses).
    /// Only returns `is_mine = 1` — the requesting peer already has messages they sent.
    /// Uses `>=` (inclusive) — INSERT OR IGNORE dedup handles overlap.
    /// Includes hidden (deleted) messages — evidence must sync to all peers (Rat Files).
    pub fn get_dm_messages_since(
        &self,
        peer_id: &str,
        since_timestamp: i64,
        limit: i32,
    ) -> Result<Vec<StoredMessage>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, peer_id, text, is_mine, timestamp, signature, public_key, message_id, edited_at, hidden_at, reply_to_mid, file_id, link_preview_json
                 FROM messages
                 WHERE peer_id = ?1 AND timestamp >= ?2 AND is_mine = 1
                 ORDER BY timestamp ASC
                 LIMIT ?3",
            )
            .map_err(|e| format!("Failed to prepare dm_messages_since query: {e}"))?;

        let rows = stmt
            .query_map(params![peer_id, since_timestamp, limit], |row| {
                Ok(StoredMessage {
                    id: row.get(0)?,
                    peer_id: row.get(1)?,
                    text: row.get(2)?,
                    is_mine: row.get::<_, i32>(3)? != 0,
                    timestamp: row.get(4)?,
                    signature: row.get(5)?,
                    public_key: row.get(6)?,
                    message_id: row.get(7)?,
                    edited_at: row.get(8)?,
                    hidden_at: row.get(9)?,
                    reply_to_mid: row.get(10)?,
                    file_id: row.get(11)?,
                    link_preview: row.get::<_, Option<String>>(12)?
                        .and_then(|s| serde_json::from_str(&s).ok()),
                })
            })
            .map_err(|e| format!("Failed to query dm_messages_since: {e}"))?;

        let mut messages = Vec::new();
        for row in rows {
            messages.push(row.map_err(|e| format!("Failed to read dm_messages_since row: {e}"))?);
        }
        Ok(messages)
    }

    // -- CRDT persistence methods --

    /// Save (upsert) a server's full CRDT state as JSON.
    pub fn save_server_state(&self, server_id: &str, state_json: &str) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        self.conn
            .execute(
                "INSERT INTO servers (server_id, state_json, updated_at) VALUES (?1, ?2, ?3)
                 ON CONFLICT(server_id) DO UPDATE SET state_json = excluded.state_json, updated_at = excluded.updated_at",
                params![server_id, state_json, now],
            )
            .map_err(|e| format!("Failed to save server state: {e}"))?;
        Ok(())
    }

    /// Load a server's CRDT state JSON.
    pub fn load_server_state(&self, server_id: &str) -> Result<Option<String>, String> {
        let mut stmt = self
            .conn
            .prepare("SELECT state_json FROM servers WHERE server_id = ?1")
            .map_err(|e| format!("Failed to prepare servers query: {e}"))?;
        let mut rows = stmt
            .query_map(params![server_id], |row| row.get(0))
            .map_err(|e| format!("Failed to query servers: {e}"))?;
        match rows.next() {
            Some(Ok(json)) => Ok(Some(json)),
            Some(Err(e)) => Err(format!("Failed to read servers row: {e}")),
            None => Ok(None),
        }
    }

    /// Load all server states as (server_id, state_json) pairs.
    pub fn load_all_servers(&self) -> Result<Vec<(String, String)>, String> {
        let mut stmt = self
            .conn
            .prepare("SELECT server_id, state_json FROM servers")
            .map_err(|e| format!("Failed to prepare servers query: {e}"))?;
        let rows = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .map_err(|e| format!("Failed to query servers: {e}"))?;
        let mut result = Vec::new();
        for row in rows {
            result.push(row.map_err(|e| format!("Failed to read servers row: {e}"))?);
        }
        Ok(result)
    }

    /// Delete a server's CRDT state and all its CRDT ops from the database.
    pub fn delete_server_state(&self, server_id: &str) -> Result<(), String> {
        self.conn
            .execute("DELETE FROM servers WHERE server_id = ?1", params![server_id])
            .map_err(|e| format!("Failed to delete server state: {e}"))?;
        self.conn
            .execute("DELETE FROM crdt_ops WHERE server_id = ?1", params![server_id])
            .map_err(|e| format!("Failed to delete server ops: {e}"))?;
        Ok(())
    }

    /// Insert a CRDT operation. Uses INSERT OR IGNORE for dedup via UNIQUE constraint.
    pub fn insert_crdt_op(&self, op: &CrdtOp) -> Result<(), String> {
        let op_json =
            serde_json::to_string(op).map_err(|e| format!("Failed to serialize CrdtOp: {e}"))?;
        self.conn
            .execute(
                "INSERT OR IGNORE INTO crdt_ops (server_id, hlc_ms, hlc_counter, author, op_json)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![
                    op.server_id,
                    op.hlc.physical_ms as i64,
                    op.hlc.counter as i64,
                    op.author,
                    op_json,
                ],
            )
            .map_err(|e| format!("Failed to insert crdt_op: {e}"))?;
        Ok(())
    }

    /// Load all CRDT ops for a server, ordered by HLC.
    pub fn load_ops_for_server(&self, server_id: &str) -> Result<Vec<CrdtOp>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT op_json FROM crdt_ops WHERE server_id = ?1 ORDER BY hlc_ms, hlc_counter, author",
            )
            .map_err(|e| format!("Failed to prepare crdt_ops query: {e}"))?;
        let rows = stmt
            .query_map(params![server_id], |row| row.get::<_, String>(0))
            .map_err(|e| format!("Failed to query crdt_ops: {e}"))?;
        let mut ops = Vec::new();
        for row in rows {
            let json = row.map_err(|e| format!("Failed to read crdt_ops row: {e}"))?;
            let op: CrdtOp = serde_json::from_str(&json)
                .map_err(|e| format!("Failed to deserialize CrdtOp: {e}"))?;
            ops.push(op);
        }
        Ok(ops)
    }

    /// Save (upsert) HLC state.
    pub fn save_hlc_state(
        &self,
        physical_ms: u64,
        counter: u32,
        actor: &str,
    ) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO hlc_state (id, physical_ms, counter, actor) VALUES (1, ?1, ?2, ?3)
                 ON CONFLICT(id) DO UPDATE SET physical_ms = excluded.physical_ms, counter = excluded.counter, actor = excluded.actor",
                params![physical_ms as i64, counter as i64, actor],
            )
            .map_err(|e| format!("Failed to save hlc_state: {e}"))?;
        Ok(())
    }

    // -- Channel message methods --

    /// Insert a channel message. Returns number of rows inserted (0 if duplicate, 1 if new).
    pub fn insert_channel_message(
        &self,
        server_id: &str,
        channel_id: &str,
        sender_id: &str,
        text: &str,
        is_mine: bool,
        timestamp: i64,
        signature: Option<&str>,
        public_key: Option<&str>,
        message_id: Option<&str>,
        reply_to_mid: Option<&str>,
        file_id: Option<&str>,
    ) -> Result<usize, String> {
        let rows = self.conn
            .execute(
                "INSERT OR IGNORE INTO channel_messages (server_id, channel_id, sender_id, text, is_mine, timestamp, signature, public_key, message_id, reply_to_mid, file_id)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                params![server_id, channel_id, sender_id, text, is_mine as i32, timestamp, signature, public_key, message_id, reply_to_mid, file_id],
            )
            .map_err(|e| format!("Failed to insert channel message: {e}"))?;
        Ok(rows)
    }

    /// Load recent messages for a channel, ordered oldest-first.
    /// Hidden (deleted) messages are excluded.
    pub fn load_channel_messages(
        &self,
        server_id: &str,
        channel_id: &str,
        limit: i32,
    ) -> Result<Vec<StoredChannelMessage>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, server_id, channel_id, sender_id, text, is_mine, timestamp, signature, public_key, message_id, edited_at, hidden_at, reply_to_mid, file_id, link_preview_json
                 FROM channel_messages
                 WHERE server_id = ?1 AND channel_id = ?2 AND hidden_at IS NULL
                 ORDER BY timestamp DESC, sender_id DESC, id DESC
                 LIMIT ?3",
            )
            .map_err(|e| format!("Failed to prepare channel_messages query: {e}"))?;

        let rows = stmt
            .query_map(params![server_id, channel_id, limit], |row| {
                Ok(StoredChannelMessage {
                    id: row.get(0)?,
                    server_id: row.get(1)?,
                    channel_id: row.get(2)?,
                    sender_id: row.get(3)?,
                    text: row.get(4)?,
                    is_mine: row.get::<_, i32>(5)? != 0,
                    timestamp: row.get(6)?,
                    signature: row.get(7)?,
                    public_key: row.get(8)?,
                    message_id: row.get(9)?,
                    edited_at: row.get(10)?,
                    hidden_at: row.get(11)?,
                    reply_to_mid: row.get(12)?,
                    file_id: row.get(13)?,
                    link_preview: row.get::<_, Option<String>>(14)?
                        .and_then(|s| serde_json::from_str(&s).ok()),
                })
            })
            .map_err(|e| format!("Failed to query channel_messages: {e}"))?;

        let mut messages = Vec::new();
        for row in rows {
            messages.push(row.map_err(|e| format!("Failed to read channel_messages row: {e}"))?);
        }
        messages.reverse(); // Oldest first for display.
        Ok(messages)
    }

    /// Get the most recent message timestamp for a channel (for sync requests).
    pub fn get_latest_channel_timestamp(
        &self,
        server_id: &str,
        channel_id: &str,
    ) -> Result<Option<i64>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT MAX(timestamp) FROM channel_messages
                 WHERE server_id = ?1 AND channel_id = ?2",
            )
            .map_err(|e| format!("Failed to prepare latest timestamp query: {e}"))?;
        let mut rows = stmt
            .query_map(params![server_id, channel_id], |row| {
                row.get::<_, Option<i64>>(0)
            })
            .map_err(|e| format!("Failed to query latest timestamp: {e}"))?;
        match rows.next() {
            Some(Ok(ts)) => Ok(ts),
            Some(Err(e)) => Err(format!("Failed to read latest timestamp: {e}")),
            None => Ok(None),
        }
    }

    /// Get channel messages newer than a given timestamp (for sync responses).
    /// Includes hidden (deleted) messages — evidence must sync to all peers (Rat Files).
    pub fn get_channel_messages_since(
        &self,
        server_id: &str,
        channel_id: &str,
        since_timestamp: i64,
        limit: i32,
    ) -> Result<Vec<StoredChannelMessage>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, server_id, channel_id, sender_id, text, is_mine, timestamp, signature, public_key, message_id, edited_at, hidden_at, reply_to_mid, file_id, link_preview_json
                 FROM channel_messages
                 WHERE server_id = ?1 AND channel_id = ?2 AND timestamp > ?3
                 ORDER BY timestamp ASC
                 LIMIT ?4",
            )
            .map_err(|e| format!("Failed to prepare messages_since query: {e}"))?;

        let rows = stmt
            .query_map(
                params![server_id, channel_id, since_timestamp, limit],
                |row| {
                    Ok(StoredChannelMessage {
                        id: row.get(0)?,
                        server_id: row.get(1)?,
                        channel_id: row.get(2)?,
                        sender_id: row.get(3)?,
                        text: row.get(4)?,
                        is_mine: row.get::<_, i32>(5)? != 0,
                        timestamp: row.get(6)?,
                        signature: row.get(7)?,
                        public_key: row.get(8)?,
                        message_id: row.get(9)?,
                        edited_at: row.get(10)?,
                        hidden_at: row.get(11)?,
                        reply_to_mid: row.get(12)?,
                        file_id: row.get(13)?,
                        link_preview: row.get::<_, Option<String>>(14)?
                            .and_then(|s| serde_json::from_str(&s).ok()),
                    })
                },
            )
            .map_err(|e| format!("Failed to query messages_since: {e}"))?;

        let mut messages = Vec::new();
        for row in rows {
            messages.push(
                row.map_err(|e| format!("Failed to read messages_since row: {e}"))?,
            );
        }
        Ok(messages)
    }

    /// Total message count for a channel (for health check comparison).
    /// Count all DM messages for a peer (including hidden/deleted). Used by archive sidebar.
    pub fn count_dm_messages(&self, peer_id: &str) -> u32 {
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM messages WHERE peer_id = ?1",
                params![peer_id],
                |row| row.get::<_, i64>(0),
            )
            .unwrap_or(0) as u32
    }

    pub fn count_channel_messages(
        &self,
        server_id: &str,
        channel_id: &str,
    ) -> u32 {
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM channel_messages WHERE server_id = ?1 AND channel_id = ?2",
                params![server_id, channel_id],
                |row| row.get::<_, i64>(0),
            )
            .unwrap_or(0) as u32
    }

    /// Count channel messages newer than a given timestamp (for sync progress indication).
    pub fn count_channel_messages_since(
        &self,
        server_id: &str,
        channel_id: &str,
        since_timestamp: i64,
    ) -> Result<u32, String> {
        let count: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM channel_messages
                 WHERE server_id = ?1 AND channel_id = ?2 AND timestamp > ?3",
                params![server_id, channel_id, since_timestamp],
                |row| row.get(0),
            )
            .map_err(|e| format!("Failed to count messages: {e}"))?;
        Ok(count as u32)
    }

    /// Count unread DM messages: messages with autoincrement id greater than
    /// the row matching `last_seen_message_id`. Returns 0 if not found.
    pub fn count_unread_dm(&self, peer_id: &str, last_seen_message_id: &str) -> u32 {
        // Find the autoincrement id of the last-seen message.
        let seen_id: Option<i64> = self
            .conn
            .query_row(
                "SELECT id FROM messages WHERE peer_id = ?1 AND message_id = ?2",
                params![peer_id, last_seen_message_id],
                |row| row.get(0),
            )
            .ok();

        let threshold = seen_id.unwrap_or(0);
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM messages
                 WHERE peer_id = ?1 AND id > ?2 AND hidden_at IS NULL AND is_mine = 0",
                params![peer_id, threshold],
                |row| row.get::<_, i64>(0),
            )
            .unwrap_or(0) as u32
    }

    /// Count unread channel messages: messages with autoincrement id greater than
    /// the row matching `last_seen_message_id`. Returns 0 if not found.
    pub fn count_unread_channel(
        &self,
        server_id: &str,
        channel_id: &str,
        last_seen_message_id: &str,
    ) -> u32 {
        // Find the autoincrement id of the last-seen message.
        let seen_id: Option<i64> = self
            .conn
            .query_row(
                "SELECT id FROM channel_messages
                 WHERE server_id = ?1 AND channel_id = ?2 AND message_id = ?3",
                params![server_id, channel_id, last_seen_message_id],
                |row| row.get(0),
            )
            .ok();

        let threshold = seen_id.unwrap_or(0);
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM channel_messages
                 WHERE server_id = ?1 AND channel_id = ?2 AND id > ?3
                   AND hidden_at IS NULL AND is_mine = 0",
                params![server_id, channel_id, threshold],
                |row| row.get::<_, i64>(0),
            )
            .unwrap_or(0) as u32
    }

    /// Count ALL non-hidden messages from others in a DM (for never-opened DMs).
    pub fn count_all_unread_dm(&self, peer_id: &str) -> u32 {
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM messages
                 WHERE peer_id = ?1 AND hidden_at IS NULL AND is_mine = 0",
                params![peer_id],
                |row| row.get::<_, i64>(0),
            )
            .unwrap_or(0) as u32
    }

    /// Count ALL non-hidden messages from others in a channel (for never-opened channels).
    pub fn count_all_unread_channel(&self, server_id: &str, channel_id: &str) -> u32 {
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM channel_messages
                 WHERE server_id = ?1 AND channel_id = ?2
                   AND hidden_at IS NULL AND is_mine = 0",
                params![server_id, channel_id],
                |row| row.get::<_, i64>(0),
            )
            .unwrap_or(0) as u32
    }

    /// Get all distinct peer IDs that have DM messages.
    pub fn get_dm_peer_ids(&self) -> Vec<String> {
        let mut stmt = self
            .conn
            .prepare("SELECT DISTINCT peer_id FROM messages")
            .unwrap();
        let rows = stmt
            .query_map([], |row| row.get::<_, String>(0))
            .unwrap();
        rows.filter_map(|r| r.ok()).collect()
    }

    /// Get the latest timestamp per sender for a channel (for per-sender sync).
    /// Returns a map of `{ sender_id → max_timestamp }`.
    pub fn get_per_sender_timestamps(
        &self,
        server_id: &str,
        channel_id: &str,
    ) -> Result<HashMap<String, i64>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT sender_id, MAX(timestamp) FROM channel_messages
                 WHERE server_id = ?1 AND channel_id = ?2
                 GROUP BY sender_id",
            )
            .map_err(|e| format!("Failed to prepare per_sender_timestamps query: {e}"))?;
        let rows = stmt
            .query_map(params![server_id, channel_id], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
            })
            .map_err(|e| format!("Failed to query per_sender_timestamps: {e}"))?;
        let mut map = HashMap::new();
        for row in rows {
            let (sender, ts) = row.map_err(|e| format!("Failed to read per_sender row: {e}"))?;
            map.insert(sender, ts);
        }
        Ok(map)
    }

    /// Get channel messages filling gaps from per-sender timestamps.
    /// For each known sender, returns messages with `timestamp >= sender_ts`.
    /// For unknown senders (not in the map), returns ALL their messages.
    pub fn get_channel_messages_since_per_sender(
        &self,
        server_id: &str,
        channel_id: &str,
        sender_timestamps: &HashMap<String, i64>,
        limit: i32,
    ) -> Result<Vec<StoredChannelMessage>, String> {
        if sender_timestamps.is_empty() {
            // No known senders — return everything.
            return self.get_channel_messages_since(server_id, channel_id, 0, limit);
        }

        // Build dynamic SQL: for each known sender, filter by their timestamp.
        // Unknown senders get all messages.
        // Uses `>=` (inclusive) to catch same-millisecond messages; INSERT OR IGNORE dedup handles overlap.
        let mut conditions = Vec::new();
        let mut param_values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();
        param_values.push(Box::new(server_id.to_string()));
        param_values.push(Box::new(channel_id.to_string()));

        let known_senders: Vec<&String> = sender_timestamps.keys().collect();
        let mut param_idx = 3;

        // Condition for each known sender: messages newer than or equal to their latest.
        for (sender, ts) in sender_timestamps {
            conditions.push(format!("(sender_id = ?{} AND timestamp >= ?{})", param_idx, param_idx + 1));
            param_values.push(Box::new(sender.clone()));
            param_values.push(Box::new(*ts));
            param_idx += 2;
        }

        // Condition for unknown senders: all their messages.
        if !known_senders.is_empty() {
            let placeholders: Vec<String> = known_senders.iter().enumerate().map(|(i, _)| {
                let idx = param_idx + i;
                format!("?{idx}")
            }).collect();
            conditions.push(format!("(sender_id NOT IN ({}))", placeholders.join(",")));
            for s in &known_senders {
                param_values.push(Box::new(s.to_string()));
            }
        }

        let where_clause = conditions.join(" OR ");
        let sql = format!(
            "SELECT id, server_id, channel_id, sender_id, text, is_mine, timestamp, signature, public_key, message_id, edited_at, hidden_at, reply_to_mid, file_id, link_preview_json
             FROM channel_messages
             WHERE server_id = ?1 AND channel_id = ?2 AND ({where_clause})
             ORDER BY timestamp ASC
             LIMIT ?{}",
            param_values.len() + 1,
        );
        param_values.push(Box::new(limit));

        let params_ref: Vec<&dyn rusqlite::types::ToSql> = param_values.iter().map(|p| p.as_ref()).collect();

        let mut stmt = self.conn.prepare(&sql)
            .map_err(|e| format!("Failed to prepare per_sender_since query: {e}"))?;
        let rows = stmt
            .query_map(params_ref.as_slice(), |row| {
                Ok(StoredChannelMessage {
                    id: row.get(0)?,
                    server_id: row.get(1)?,
                    channel_id: row.get(2)?,
                    sender_id: row.get(3)?,
                    text: row.get(4)?,
                    is_mine: row.get::<_, i32>(5)? != 0,
                    timestamp: row.get(6)?,
                    signature: row.get(7)?,
                    public_key: row.get(8)?,
                    message_id: row.get(9)?,
                    edited_at: row.get(10)?,
                    hidden_at: row.get(11)?,
                    reply_to_mid: row.get(12)?,
                    file_id: row.get(13)?,
                    link_preview: row.get::<_, Option<String>>(14)?
                        .and_then(|s| serde_json::from_str(&s).ok()),
                })
            })
            .map_err(|e| format!("Failed to query per_sender_since: {e}"))?;

        let mut messages = Vec::new();
        for row in rows {
            messages.push(row.map_err(|e| format!("Failed to read per_sender row: {e}"))?);
        }
        Ok(messages)
    }

    /// Count channel messages that would be returned by per-sender sync.
    pub fn count_channel_messages_since_per_sender(
        &self,
        server_id: &str,
        channel_id: &str,
        sender_timestamps: &HashMap<String, i64>,
    ) -> Result<u32, String> {
        if sender_timestamps.is_empty() {
            return self.count_channel_messages_since(server_id, channel_id, 0);
        }

        let mut conditions = Vec::new();
        let mut param_values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();
        param_values.push(Box::new(server_id.to_string()));
        param_values.push(Box::new(channel_id.to_string()));

        let known_senders: Vec<&String> = sender_timestamps.keys().collect();
        let mut param_idx = 3;

        for (sender, ts) in sender_timestamps {
            conditions.push(format!("(sender_id = ?{} AND timestamp >= ?{})", param_idx, param_idx + 1));
            param_values.push(Box::new(sender.clone()));
            param_values.push(Box::new(*ts));
            param_idx += 2;
        }

        if !known_senders.is_empty() {
            let placeholders: Vec<String> = known_senders.iter().enumerate().map(|(i, _)| {
                let idx = param_idx + i;
                format!("?{idx}")
            }).collect();
            conditions.push(format!("(sender_id NOT IN ({}))", placeholders.join(",")));
            for s in &known_senders {
                param_values.push(Box::new(s.to_string()));
            }
        }

        let where_clause = conditions.join(" OR ");
        let sql = format!(
            "SELECT COUNT(*) FROM channel_messages
             WHERE server_id = ?1 AND channel_id = ?2 AND ({where_clause})",
        );

        let params_ref: Vec<&dyn rusqlite::types::ToSql> = param_values.iter().map(|p| p.as_ref()).collect();

        let count: i64 = self.conn.query_row(&sql, params_ref.as_slice(), |row| row.get(0))
            .map_err(|e| format!("Failed to count per_sender messages: {e}"))?;
        Ok(count as u32)
    }

    /// Load HLC state, if saved.
    pub fn load_hlc_state(&self) -> Result<Option<(u64, u32, String)>, String> {
        let mut stmt = self
            .conn
            .prepare("SELECT physical_ms, counter, actor FROM hlc_state WHERE id = 1")
            .map_err(|e| format!("Failed to prepare hlc_state query: {e}"))?;
        let mut rows = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, i64>(0)? as u64,
                    row.get::<_, i64>(1)? as u32,
                    row.get::<_, String>(2)?,
                ))
            })
            .map_err(|e| format!("Failed to query hlc_state: {e}"))?;
        match rows.next() {
            Some(Ok(tuple)) => Ok(Some(tuple)),
            Some(Err(e)) => Err(format!("Failed to read hlc_state row: {e}")),
            None => Ok(None),
        }
    }

    // ── MLS Identity Persistence ──

    /// Save MLS identity (signer + credential + storage blob). Upsert singleton row.
    pub fn save_mls_identity(
        &self,
        signer_data: &[u8],
        credential_data: &[u8],
        storage_data: &[u8],
    ) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO mls_identity (id, signer_data, credential_data, storage_data)
                 VALUES (1, ?1, ?2, ?3)
                 ON CONFLICT(id) DO UPDATE SET
                    signer_data = excluded.signer_data,
                    credential_data = excluded.credential_data,
                    storage_data = excluded.storage_data",
                params![signer_data, credential_data, storage_data],
            )
            .map_err(|e| format!("Failed to save MLS identity: {e}"))?;
        Ok(())
    }

    /// Load MLS identity. Returns (signer_data, credential_data, storage_data) if exists.
    pub fn load_mls_identity(&self) -> Result<Option<(Vec<u8>, Vec<u8>, Option<Vec<u8>>)>, String> {
        let mut stmt = self
            .conn
            .prepare("SELECT signer_data, credential_data, storage_data FROM mls_identity WHERE id = 1")
            .map_err(|e| format!("Failed to prepare mls_identity query: {e}"))?;
        let mut rows = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, Vec<u8>>(0)?,
                    row.get::<_, Vec<u8>>(1)?,
                    row.get::<_, Option<Vec<u8>>>(2)?,
                ))
            })
            .map_err(|e| format!("Failed to query mls_identity: {e}"))?;
        match rows.next() {
            Some(Ok(tuple)) => Ok(Some(tuple)),
            Some(Err(e)) => Err(format!("Failed to read mls_identity row: {e}")),
            None => Ok(None),
        }
    }

    // ── User Profile Persistence (Phase 3.5) ──

    /// Upsert a user profile (ours or a peer's).
    /// `avatar` and `banner` are optional: `None` preserves the existing image, `Some(bytes)` overwrites
    /// (pass empty slice to clear).
    pub fn save_profile(
        &self,
        peer_id: &str,
        display_name: &str,
        status: &str,
        about_me: &str,
        updated_at: i64,
        avatar: Option<&[u8]>,
        banner: Option<&[u8]>,
        twitch_username: &str,
    ) -> Result<(), String> {
        // For avatar/banner: None = no change (use COALESCE), Some(empty) = clear (store NULL), Some(data) = set.
        // Normalize Some(empty) to an explicit NULL for SQL.
        let avatar_val: Option<&[u8]> = avatar.and_then(|b| if b.is_empty() { None } else { Some(b) });
        let banner_val: Option<&[u8]> = banner.and_then(|b| if b.is_empty() { None } else { Some(b) });
        let avatar_is_clear = avatar.is_some() && avatar.unwrap().is_empty();
        let banner_is_clear = banner.is_some() && banner.unwrap().is_empty();

        self.conn
            .execute(
                "INSERT INTO user_profiles (peer_id, display_name, status, about_me, updated_at, avatar, banner, twitch_username)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                 ON CONFLICT(peer_id) DO UPDATE SET
                    display_name = excluded.display_name,
                    status = excluded.status,
                    about_me = excluded.about_me,
                    updated_at = excluded.updated_at,
                    avatar = COALESCE(excluded.avatar, user_profiles.avatar),
                    banner = COALESCE(excluded.banner, user_profiles.banner),
                    twitch_username = excluded.twitch_username
                 WHERE excluded.updated_at >= user_profiles.updated_at
                    OR (excluded.updated_at < user_profiles.updated_at
                        AND ABS(excluded.updated_at - user_profiles.updated_at) < 86400000)",
                params![peer_id, display_name, status, about_me, updated_at, avatar_val, banner_val, twitch_username],
            )
            .map_err(|e| format!("Failed to save profile: {e}"))?;

        // Explicitly clear avatar/banner if requested (COALESCE can't set NULL).
        if avatar_is_clear {
            self.conn.execute(
                "UPDATE user_profiles SET avatar = NULL WHERE peer_id = ?1",
                params![peer_id],
            ).map_err(|e| format!("Failed to clear avatar: {e}"))?;
        }
        if banner_is_clear {
            self.conn.execute(
                "UPDATE user_profiles SET banner = NULL WHERE peer_id = ?1",
                params![peer_id],
            ).map_err(|e| format!("Failed to clear banner: {e}"))?;
        }
        Ok(())
    }

    /// Load a profile for a specific peer.
    pub fn load_profile(&self, peer_id: &str) -> Result<Option<StoredProfile>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT peer_id, display_name, status, about_me, updated_at, avatar, banner, twitch_username
                 FROM user_profiles WHERE peer_id = ?1",
            )
            .map_err(|e| format!("Failed to prepare profile query: {e}"))?;
        let mut rows = stmt
            .query_map(params![peer_id], |row| {
                Ok(StoredProfile {
                    peer_id: row.get(0)?,
                    display_name: row.get(1)?,
                    status: row.get(2)?,
                    about_me: row.get(3)?,
                    updated_at: row.get(4)?,
                    avatar_bytes: row.get(5)?,
                    banner_bytes: row.get(6)?,
                    twitch_username: row.get::<_, String>(7).unwrap_or_default(),
                })
            })
            .map_err(|e| format!("Failed to query profile: {e}"))?;
        match rows.next() {
            Some(Ok(profile)) => Ok(Some(profile)),
            Some(Err(e)) => Err(format!("Failed to read profile row: {e}")),
            None => Ok(None),
        }
    }

    /// Load all stored profiles.
    pub fn load_all_profiles(&self) -> Result<Vec<StoredProfile>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT peer_id, display_name, status, about_me, updated_at, avatar, banner, twitch_username
                 FROM user_profiles",
            )
            .map_err(|e| format!("Failed to prepare all profiles query: {e}"))?;
        let rows = stmt
            .query_map([], |row| {
                Ok(StoredProfile {
                    peer_id: row.get(0)?,
                    display_name: row.get(1)?,
                    status: row.get(2)?,
                    about_me: row.get(3)?,
                    updated_at: row.get(4)?,
                    avatar_bytes: row.get(5)?,
                    banner_bytes: row.get(6)?,
                    twitch_username: row.get::<_, String>(7).unwrap_or_default(),
                })
            })
            .map_err(|e| format!("Failed to query all profiles: {e}"))?;
        let mut profiles = Vec::new();
        for row in rows {
            profiles.push(row.map_err(|e| format!("Failed to read profile row: {e}"))?);
        }
        Ok(profiles)
    }

    // ── Message Editing (Phase 3.5) ──

    /// Edit a channel message by message_id. Preserves old text in message_edits table.
    /// Returns true if the message was found and updated.
    /// Returns the sender_id for a channel message, if found.
    pub fn get_channel_message_sender(&self, message_id: &str) -> Option<String> {
        self.conn
            .query_row(
                "SELECT sender_id FROM channel_messages WHERE message_id = ?1",
                params![message_id],
                |row| row.get(0),
            )
            .ok()
    }

    /// Returns whether a DM message is mine (true) or from the peer (false).
    pub fn get_dm_message_is_mine(&self, message_id: &str) -> Option<bool> {
        self.conn
            .query_row(
                "SELECT is_mine FROM messages WHERE message_id = ?1",
                params![message_id],
                |row| row.get::<_, i32>(0).map(|v| v != 0),
            )
            .ok()
    }

    /// Returns the current text of a channel message by message_id.
    /// Used when signing deletions so the canonical payload reflects the
    /// text at deletion time (rather than the ad-hoc "delete:..." format).
    pub fn get_channel_message_text(&self, message_id: &str) -> Option<String> {
        self.conn
            .query_row(
                "SELECT text FROM channel_messages WHERE message_id = ?1",
                params![message_id],
                |row| row.get(0),
            )
            .ok()
    }

    /// Returns the current text of a DM message by message_id.
    /// Used when signing deletions so the canonical payload reflects the
    /// text at deletion time (rather than the ad-hoc "delete:..." format).
    pub fn get_dm_message_text(&self, message_id: &str) -> Option<String> {
        self.conn
            .query_row(
                "SELECT text FROM messages WHERE message_id = ?1",
                params![message_id],
                |row| row.get(0),
            )
            .ok()
    }

    pub fn edit_channel_message(
        &self,
        message_id: &str,
        new_text: &str,
        edited_at: i64,
        signature: Option<&str>,
        public_key: Option<&str>,
    ) -> Result<bool, String> {
        // 1. Read the current text + signature/public_key/timestamp before overwriting.
        let row: Option<(String, Option<String>, Option<String>, i64)> = self
            .conn
            .query_row(
                "SELECT text, signature, public_key, COALESCE(edited_at, timestamp) FROM channel_messages WHERE message_id = ?1",
                params![message_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .ok();

        let Some((old_text, prev_sig, prev_pk, prev_ts)) = row else {
            return Ok(false); // Message not found.
        };

        if old_text == new_text {
            return Ok(false); // No change.
        }

        // 2. Preserve the old text + previous signature in message_edits.
        self.conn
            .execute(
                "INSERT INTO message_edits (message_id, old_text, new_text, edited_at, signature, public_key, prev_signature, prev_public_key, prev_timestamp)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![message_id, old_text, new_text, edited_at, signature, public_key, prev_sig, prev_pk, prev_ts],
            )
            .map_err(|e| format!("Failed to insert edit history: {e}"))?;

        // 3. Update the message text, edited_at, and overwrite the main-row
        // signature/public_key so the canonical payload (built from the new
        // text + edited_at) matches the stored signature on cold loads.
        // The full edit chain with prior signatures still lives in message_edits.
        let rows = self
            .conn
            .execute(
                "UPDATE channel_messages SET text = ?1, edited_at = ?2, signature = ?3, public_key = ?4 WHERE message_id = ?5",
                params![new_text, edited_at, signature, public_key, message_id],
            )
            .map_err(|e| format!("Failed to update channel message: {e}"))?;

        Ok(rows > 0)
    }

    /// Edit a DM message by message_id. Preserves old text in message_edits table.
    /// Returns true if the message was found and updated.
    pub fn edit_dm_message(
        &self,
        message_id: &str,
        new_text: &str,
        edited_at: i64,
        signature: Option<&str>,
        public_key: Option<&str>,
    ) -> Result<bool, String> {
        // 1. Read the current text + signature/public_key/timestamp before overwriting.
        let row: Option<(String, Option<String>, Option<String>, i64)> = self
            .conn
            .query_row(
                "SELECT text, signature, public_key, COALESCE(edited_at, timestamp) FROM messages WHERE message_id = ?1",
                params![message_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .ok();

        let Some((old_text, prev_sig, prev_pk, prev_ts)) = row else {
            return Ok(false);
        };

        if old_text == new_text {
            return Ok(false);
        }

        // 2. Preserve old text + previous signature.
        self.conn
            .execute(
                "INSERT INTO message_edits (message_id, old_text, new_text, edited_at, signature, public_key, prev_signature, prev_public_key, prev_timestamp)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![message_id, old_text, new_text, edited_at, signature, public_key, prev_sig, prev_pk, prev_ts],
            )
            .map_err(|e| format!("Failed to insert edit history: {e}"))?;

        // 3. Update the message. Overwrite the main-row signature/public_key
        // alongside text+edited_at so the canonical payload matches the
        // stored signature on cold loads. Prior signatures stay in message_edits.
        let rows = self
            .conn
            .execute(
                "UPDATE messages SET text = ?1, edited_at = ?2, signature = ?3, public_key = ?4 WHERE message_id = ?5",
                params![new_text, edited_at, signature, public_key, message_id],
            )
            .map_err(|e| format!("Failed to update DM message: {e}"))?;

        Ok(rows > 0)
    }

    // ── Message Deletion / Hiding (Phase 3.5) ──

    /// Hide a channel message by message_id. Preserves text in message_deletions table.
    /// The message stays in the DB (Rat Files evidence) but is hidden from UI queries.
    /// Returns true if the message was found and hidden.
    pub fn hide_channel_message(
        &self,
        message_id: &str,
        deleted_at: i64,
        signature: Option<&str>,
        public_key: Option<&str>,
    ) -> Result<bool, String> {
        // 1. Read the current text for evidence preservation.
        let text: Option<String> = self
            .conn
            .query_row(
                "SELECT text FROM channel_messages WHERE message_id = ?1",
                params![message_id],
                |row| row.get(0),
            )
            .ok();

        let Some(text) = text else {
            return Ok(false); // Message not found.
        };

        // 2. Preserve the text in message_deletions (Rat Files evidence).
        self.conn
            .execute(
                "INSERT INTO message_deletions (message_id, deleted_text, deleted_at, signature, public_key)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![message_id, text, deleted_at, signature, public_key],
            )
            .map_err(|e| format!("Failed to insert deletion record: {e}"))?;

        // 3. Set hidden_at — message stays in DB but is filtered out of queries.
        let rows = self
            .conn
            .execute(
                "UPDATE channel_messages SET hidden_at = ?1 WHERE message_id = ?2",
                params![deleted_at, message_id],
            )
            .map_err(|e| format!("Failed to hide channel message: {e}"))?;

        Ok(rows > 0)
    }

    /// Hide a DM message by message_id. Preserves text in message_deletions table.
    /// Returns true if the message was found and hidden.
    pub fn hide_dm_message(
        &self,
        message_id: &str,
        deleted_at: i64,
        signature: Option<&str>,
        public_key: Option<&str>,
    ) -> Result<bool, String> {
        // 1. Read the current text.
        let text: Option<String> = self
            .conn
            .query_row(
                "SELECT text FROM messages WHERE message_id = ?1",
                params![message_id],
                |row| row.get(0),
            )
            .ok();

        let Some(text) = text else {
            return Ok(false);
        };

        // 2. Preserve evidence.
        self.conn
            .execute(
                "INSERT INTO message_deletions (message_id, deleted_text, deleted_at, signature, public_key)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![message_id, text, deleted_at, signature, public_key],
            )
            .map_err(|e| format!("Failed to insert deletion record: {e}"))?;

        // 3. Hide it.
        let rows = self
            .conn
            .execute(
                "UPDATE messages SET hidden_at = ?1 WHERE message_id = ?2",
                params![deleted_at, message_id],
            )
            .map_err(|e| format!("Failed to hide DM message: {e}"))?;

        Ok(rows > 0)
    }

    /// Lightweight hidden_at setter for channel messages during sync.
    /// Unlike hide_channel_message(), this does NOT preserve evidence in message_deletions
    /// (the original deleter already did that). Used when syncing deleted messages to late joiners.
    pub fn set_channel_message_hidden(&self, message_id: &str, hidden_at: i64) -> Result<(), String> {
        self.conn
            .execute(
                "UPDATE channel_messages SET hidden_at = ?1 WHERE message_id = ?2",
                params![hidden_at, message_id],
            )
            .map_err(|e| format!("Failed to set channel message hidden_at: {e}"))?;
        Ok(())
    }

    /// Lightweight hidden_at setter for DM messages during sync.
    pub fn set_dm_message_hidden(&self, message_id: &str, hidden_at: i64) -> Result<(), String> {
        self.conn
            .execute(
                "UPDATE messages SET hidden_at = ?1 WHERE message_id = ?2",
                params![hidden_at, message_id],
            )
            .map_err(|e| format!("Failed to set DM message hidden_at: {e}"))?;
        Ok(())
    }

    // ── Emoji Reactions (Phase 3.5) ──────────────────────────────

    /// Add a reaction to a message. INSERT OR IGNORE handles duplicates via UNIQUE constraint.
    /// Enforces a limit of 3 distinct emojis per user per message.
    /// Returns true if a new reaction was inserted (false if already exists or limit reached).
    pub fn add_reaction(
        &self,
        message_id: &str,
        emoji: &str,
        peer_id: &str,
        added_at: i64,
        signature: Option<&str>,
        public_key: Option<&str>,
    ) -> Result<bool, String> {
        // Check how many distinct emojis this peer already has on this message.
        let count: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(DISTINCT emoji) FROM message_reactions WHERE message_id = ?1 AND peer_id = ?2 AND emoji != ?3",
                params![message_id, peer_id, emoji],
                |row| row.get(0),
            )
            .unwrap_or(0);

        if count >= 3 {
            return Ok(false); // Limit reached.
        }

        let rows = self
            .conn
            .execute(
                "INSERT OR IGNORE INTO message_reactions (message_id, emoji, peer_id, added_at, signature, public_key)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![message_id, emoji, peer_id, added_at, signature, public_key],
            )
            .map_err(|e| format!("Failed to add reaction: {e}"))?;
        Ok(rows > 0)
    }

    /// Remove a reaction. Records evidence in reaction_removals (Rat Files).
    /// Returns true if the reaction existed and was removed.
    pub fn remove_reaction(
        &self,
        message_id: &str,
        emoji: &str,
        peer_id: &str,
        removed_at: i64,
        signature: Option<&str>,
        public_key: Option<&str>,
    ) -> Result<bool, String> {
        let rows = self
            .conn
            .execute(
                "DELETE FROM message_reactions WHERE message_id = ?1 AND emoji = ?2 AND peer_id = ?3",
                params![message_id, emoji, peer_id],
            )
            .map_err(|e| format!("Failed to remove reaction: {e}"))?;

        if rows > 0 {
            // Record removal evidence (Rat Files).
            self.conn
                .execute(
                    "INSERT INTO reaction_removals (message_id, emoji, peer_id, removed_at, signature, public_key)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                    params![message_id, emoji, peer_id, removed_at, signature, public_key],
                )
                .map_err(|e| format!("Failed to insert reaction removal record: {e}"))?;
        }

        Ok(rows > 0)
    }

    /// Load all reactions for a set of message IDs.
    /// Returns a map: message_id → Vec<(emoji, peer_id, added_at)>.
    pub fn load_reactions_for_messages(
        &self,
        message_ids: &[String],
    ) -> Result<HashMap<String, Vec<(String, String, i64)>>, String> {
        if message_ids.is_empty() {
            return Ok(HashMap::new());
        }

        // Build placeholder list for IN clause.
        let placeholders: Vec<String> = message_ids.iter().enumerate().map(|(i, _)| format!("?{}", i + 1)).collect();
        let sql = format!(
            "SELECT message_id, emoji, peer_id, added_at FROM message_reactions WHERE message_id IN ({}) ORDER BY added_at ASC",
            placeholders.join(", ")
        );

        let mut stmt = self.conn.prepare(&sql).map_err(|e| format!("Failed to prepare reactions query: {e}"))?;

        let params_vec: Vec<&dyn rusqlite::types::ToSql> = message_ids.iter().map(|s| s as &dyn rusqlite::types::ToSql).collect();
        let rows = stmt
            .query_map(params_vec.as_slice(), |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                ))
            })
            .map_err(|e| format!("Failed to query reactions: {e}"))?;

        let mut result: HashMap<String, Vec<(String, String, i64)>> = HashMap::new();
        for row in rows {
            let (mid, emoji, peer_id, added_at) = row.map_err(|e| format!("Failed to read reaction row: {e}"))?;
            result.entry(mid).or_default().push((emoji, peer_id, added_at));
        }
        Ok(result)
    }

    /// Load all reactions with signatures for sync.
    /// Returns: message_id → Vec<(emoji, peer_id, added_at, signature, public_key)>.
    pub fn load_reactions_for_sync(
        &self,
        message_ids: &[String],
    ) -> Result<HashMap<String, Vec<(String, String, i64, Option<String>, Option<String>)>>, String> {
        if message_ids.is_empty() {
            return Ok(HashMap::new());
        }

        let placeholders: Vec<String> = message_ids.iter().enumerate().map(|(i, _)| format!("?{}", i + 1)).collect();
        let sql = format!(
            "SELECT message_id, emoji, peer_id, added_at, signature, public_key FROM message_reactions WHERE message_id IN ({}) ORDER BY added_at ASC",
            placeholders.join(", ")
        );

        let mut stmt = self.conn.prepare(&sql).map_err(|e| format!("Failed to prepare reactions sync query: {e}"))?;
        let params_vec: Vec<&dyn rusqlite::types::ToSql> = message_ids.iter().map(|s| s as &dyn rusqlite::types::ToSql).collect();
        let rows = stmt
            .query_map(params_vec.as_slice(), |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, Option<String>>(4)?,
                    row.get::<_, Option<String>>(5)?,
                ))
            })
            .map_err(|e| format!("Failed to query reactions for sync: {e}"))?;

        let mut result: HashMap<String, Vec<(String, String, i64, Option<String>, Option<String>)>> = HashMap::new();
        for row in rows {
            let (mid, emoji, peer_id, added_at, sig, pk) = row.map_err(|e| format!("Failed to read reaction sync row: {e}"))?;
            result.entry(mid).or_default().push((emoji, peer_id, added_at, sig, pk));
        }
        Ok(result)
    }

    // ── Archive queries ─────────────────────────────────────────

    /// Load ALL DM messages for a peer, including soft-deleted (hidden_at set).
    /// No limit, ordered oldest-first. Used by the archive exporter.
    pub fn load_all_dm_messages(
        &self,
        peer_id: &str,
    ) -> Result<Vec<StoredMessage>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, peer_id, text, is_mine, timestamp, signature, public_key, message_id, edited_at, hidden_at, reply_to_mid, file_id, link_preview_json
                 FROM messages
                 WHERE peer_id = ?1
                 ORDER BY timestamp ASC, id ASC",
            )
            .map_err(|e| format!("Failed to prepare load_all_dm_messages query: {e}"))?;

        let rows = stmt
            .query_map(params![peer_id], |row| {
                Ok(StoredMessage {
                    id: row.get(0)?,
                    peer_id: row.get(1)?,
                    text: row.get(2)?,
                    is_mine: row.get::<_, i32>(3)? != 0,
                    timestamp: row.get(4)?,
                    signature: row.get(5)?,
                    public_key: row.get(6)?,
                    message_id: row.get(7)?,
                    edited_at: row.get(8)?,
                    hidden_at: row.get(9)?,
                    reply_to_mid: row.get(10)?,
                    file_id: row.get(11)?,
                    link_preview: row.get::<_, Option<String>>(12)?
                        .and_then(|s| serde_json::from_str(&s).ok()),
                })
            })
            .map_err(|e| format!("Failed to query all DM messages: {e}"))?;

        let mut messages = Vec::new();
        for row in rows {
            messages.push(row.map_err(|e| format!("Failed to read DM message row: {e}"))?);
        }
        Ok(messages)
    }

    /// Load ALL channel messages, including soft-deleted (hidden_at set).
    /// No limit, ordered oldest-first. Used by the archive exporter.
    pub fn load_all_channel_messages(
        &self,
        server_id: &str,
        channel_id: &str,
    ) -> Result<Vec<StoredChannelMessage>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, server_id, channel_id, sender_id, text, is_mine, timestamp, signature, public_key, message_id, edited_at, hidden_at, reply_to_mid, file_id, link_preview_json
                 FROM channel_messages
                 WHERE server_id = ?1 AND channel_id = ?2
                 ORDER BY timestamp ASC, id ASC",
            )
            .map_err(|e| format!("Failed to prepare load_all_channel_messages query: {e}"))?;

        let rows = stmt
            .query_map(params![server_id, channel_id], |row| {
                Ok(StoredChannelMessage {
                    id: row.get(0)?,
                    server_id: row.get(1)?,
                    channel_id: row.get(2)?,
                    sender_id: row.get(3)?,
                    text: row.get(4)?,
                    is_mine: row.get::<_, i32>(5)? != 0,
                    timestamp: row.get(6)?,
                    signature: row.get(7)?,
                    public_key: row.get(8)?,
                    message_id: row.get(9)?,
                    edited_at: row.get(10)?,
                    hidden_at: row.get(11)?,
                    reply_to_mid: row.get(12)?,
                    file_id: row.get(13)?,
                    link_preview: row.get::<_, Option<String>>(14)?
                        .and_then(|s| serde_json::from_str(&s).ok()),
                })
            })
            .map_err(|e| format!("Failed to query all channel messages: {e}"))?;

        let mut messages = Vec::new();
        for row in rows {
            messages.push(row.map_err(|e| format!("Failed to read channel message row: {e}"))?);
        }
        Ok(messages)
    }

    /// Load edit history for a batch of message IDs.
    /// Returns a map of message_id → Vec<(old_text, new_text, edited_at, signature, public_key)>.
    pub fn load_edits_for_messages(
        &self,
        message_ids: &[String],
    ) -> Result<HashMap<String, Vec<(String, String, i64, Option<String>, Option<String>, Option<String>, Option<String>, Option<i64>)>>, String> {
        if message_ids.is_empty() {
            return Ok(HashMap::new());
        }

        let placeholders: Vec<String> = message_ids.iter().enumerate().map(|(i, _)| format!("?{}", i + 1)).collect();
        let sql = format!(
            "SELECT message_id, old_text, new_text, edited_at, signature, public_key, prev_signature, prev_public_key, prev_timestamp FROM message_edits WHERE message_id IN ({}) ORDER BY edited_at ASC",
            placeholders.join(", ")
        );

        let mut stmt = self.conn.prepare(&sql).map_err(|e| format!("Failed to prepare edits query: {e}"))?;
        let params_vec: Vec<&dyn rusqlite::types::ToSql> = message_ids.iter().map(|s| s as &dyn rusqlite::types::ToSql).collect();
        let rows = stmt
            .query_map(params_vec.as_slice(), |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, Option<String>>(4)?,
                    row.get::<_, Option<String>>(5)?,
                    row.get::<_, Option<String>>(6)?,
                    row.get::<_, Option<String>>(7)?,
                    row.get::<_, Option<i64>>(8)?,
                ))
            })
            .map_err(|e| format!("Failed to query edits: {e}"))?;

        let mut result: HashMap<String, Vec<(String, String, i64, Option<String>, Option<String>, Option<String>, Option<String>, Option<i64>)>> = HashMap::new();
        for row in rows {
            let (mid, old_text, new_text, edited_at, sig, pk, prev_sig, prev_pk, prev_ts) = row.map_err(|e| format!("Failed to read edit row: {e}"))?;
            result.entry(mid).or_default().push((old_text, new_text, edited_at, sig, pk, prev_sig, prev_pk, prev_ts));
        }
        Ok(result)
    }

    /// Load deletion evidence for a batch of message IDs.
    /// Returns a map of message_id → Vec<(deleted_text, deleted_at, signature, public_key)>.
    pub fn load_deletions_for_messages(
        &self,
        message_ids: &[String],
    ) -> Result<HashMap<String, Vec<(String, i64, Option<String>, Option<String>)>>, String> {
        if message_ids.is_empty() {
            return Ok(HashMap::new());
        }

        let placeholders: Vec<String> = message_ids.iter().enumerate().map(|(i, _)| format!("?{}", i + 1)).collect();
        let sql = format!(
            "SELECT message_id, deleted_text, deleted_at, signature, public_key FROM message_deletions WHERE message_id IN ({}) ORDER BY deleted_at ASC",
            placeholders.join(", ")
        );

        let mut stmt = self.conn.prepare(&sql).map_err(|e| format!("Failed to prepare deletions query: {e}"))?;
        let params_vec: Vec<&dyn rusqlite::types::ToSql> = message_ids.iter().map(|s| s as &dyn rusqlite::types::ToSql).collect();
        let rows = stmt
            .query_map(params_vec.as_slice(), |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, Option<String>>(3)?,
                    row.get::<_, Option<String>>(4)?,
                ))
            })
            .map_err(|e| format!("Failed to query deletions: {e}"))?;

        let mut result: HashMap<String, Vec<(String, i64, Option<String>, Option<String>)>> = HashMap::new();
        for row in rows {
            let (mid, deleted_text, deleted_at, sig, pk) = row.map_err(|e| format!("Failed to read deletion row: {e}"))?;
            result.entry(mid).or_default().push((deleted_text, deleted_at, sig, pk));
        }
        Ok(result)
    }

    /// Load reaction removal evidence for a batch of message IDs.
    /// Returns a map of message_id → Vec<(emoji, peer_id, removed_at, signature, public_key)>.
    pub fn load_reaction_removals_for_messages(
        &self,
        message_ids: &[String],
    ) -> Result<HashMap<String, Vec<(String, String, i64, Option<String>, Option<String>)>>, String> {
        if message_ids.is_empty() {
            return Ok(HashMap::new());
        }

        let placeholders: Vec<String> = message_ids.iter().enumerate().map(|(i, _)| format!("?{}", i + 1)).collect();
        let sql = format!(
            "SELECT message_id, emoji, peer_id, removed_at, signature, public_key FROM reaction_removals WHERE message_id IN ({}) ORDER BY removed_at ASC",
            placeholders.join(", ")
        );

        let mut stmt = self.conn.prepare(&sql).map_err(|e| format!("Failed to prepare reaction removals query: {e}"))?;
        let params_vec: Vec<&dyn rusqlite::types::ToSql> = message_ids.iter().map(|s| s as &dyn rusqlite::types::ToSql).collect();
        let rows = stmt
            .query_map(params_vec.as_slice(), |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, Option<String>>(4)?,
                    row.get::<_, Option<String>>(5)?,
                ))
            })
            .map_err(|e| format!("Failed to query reaction removals: {e}"))?;

        let mut result: HashMap<String, Vec<(String, String, i64, Option<String>, Option<String>)>> = HashMap::new();
        for row in rows {
            let (mid, emoji, peer_id, removed_at, sig, pk) = row.map_err(|e| format!("Failed to read reaction removal row: {e}"))?;
            result.entry(mid).or_default().push((emoji, peer_id, removed_at, sig, pk));
        }
        Ok(result)
    }

    // ── App Settings ──────────────────────────────────────────────

    /// Save a key-value setting (insert or update).
    // ── Search ────────────────────────────────────────────────────

    /// Search channel messages by text content. Returns matching messages.
    pub fn search_channel_messages(
        &self,
        server_id: &str,
        channel_id: &str,
        query: &str,
        limit: i32,
    ) -> Result<Vec<StoredChannelMessage>, String> {
        let pattern = format!("%{}%", query);
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, server_id, channel_id, sender_id, text, is_mine, timestamp, signature, public_key, message_id, edited_at, hidden_at, reply_to_mid, file_id, link_preview_json
                 FROM channel_messages
                 WHERE server_id = ?1 AND channel_id = ?2 AND hidden_at IS NULL AND text LIKE ?3
                 ORDER BY id DESC
                 LIMIT ?4",
            )
            .map_err(|e| format!("Failed to prepare search query: {e}"))?;

        let rows = stmt
            .query_map(params![server_id, channel_id, pattern, limit], |row| {
                Ok(StoredChannelMessage {
                    id: row.get(0)?,
                    server_id: row.get(1)?,
                    channel_id: row.get(2)?,
                    sender_id: row.get(3)?,
                    text: row.get(4)?,
                    is_mine: row.get::<_, i32>(5)? != 0,
                    timestamp: row.get(6)?,
                    signature: row.get(7)?,
                    public_key: row.get(8)?,
                    message_id: row.get(9)?,
                    edited_at: row.get(10)?,
                    hidden_at: row.get(11)?,
                    reply_to_mid: row.get(12)?,
                    file_id: row.get(13)?,
                    link_preview: row.get::<_, Option<String>>(14)?
                        .and_then(|s| serde_json::from_str(&s).ok()),
                })
            })
            .map_err(|e| format!("Failed to search messages: {e}"))?;

        let mut messages = Vec::new();
        for row in rows {
            messages.push(row.map_err(|e| format!("Failed to read search row: {e}"))?);
        }
        messages.reverse();
        Ok(messages)
    }

    /// Search DM messages by text content.
    pub fn search_dm_messages(
        &self,
        peer_id: &str,
        query: &str,
        limit: i32,
    ) -> Result<Vec<StoredMessage>, String> {
        let pattern = format!("%{}%", query);
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, peer_id, text, is_mine, timestamp, signature, public_key, message_id, edited_at, hidden_at, reply_to_mid, file_id, link_preview_json
                 FROM messages
                 WHERE peer_id = ?1 AND hidden_at IS NULL AND text LIKE ?2
                 ORDER BY id DESC
                 LIMIT ?3",
            )
            .map_err(|e| format!("Failed to prepare DM search query: {e}"))?;

        let rows = stmt
            .query_map(params![peer_id, pattern, limit], |row| {
                Ok(StoredMessage {
                    id: row.get(0)?,
                    peer_id: row.get(1)?,
                    text: row.get(2)?,
                    is_mine: row.get::<_, i32>(3)? != 0,
                    timestamp: row.get(4)?,
                    signature: row.get(5)?,
                    public_key: row.get(6)?,
                    message_id: row.get(7)?,
                    edited_at: row.get(8)?,
                    hidden_at: row.get(9)?,
                    reply_to_mid: row.get(10)?,
                    file_id: row.get(11)?,
                    link_preview: row.get::<_, Option<String>>(12)?
                        .and_then(|s| serde_json::from_str(&s).ok()),
                })
            })
            .map_err(|e| format!("Failed to search DM messages: {e}"))?;

        let mut messages = Vec::new();
        for row in rows {
            messages.push(row.map_err(|e| format!("Failed to read DM search row: {e}"))?);
        }
        messages.reverse();
        Ok(messages)
    }

    // ── Friends ───────────────────────────────────────────────────

    /// Save or update a friend entry.
    pub fn save_friend(
        &self,
        peer_id: &str,
        status: &str,
        direction: &str,
        requested_at: i64,
    ) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        self.conn
            .execute(
                "INSERT INTO friends (peer_id, status, direction, requested_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(peer_id) DO UPDATE SET status = ?2, direction = ?3, updated_at = ?5",
                params![peer_id, status, direction, requested_at, now],
            )
            .map_err(|e| format!("Failed to save friend: {e}"))?;
        Ok(())
    }

    /// Remove a friend entry entirely.
    pub fn remove_friend(&self, peer_id: &str) -> Result<(), String> {
        self.conn
            .execute("DELETE FROM friends WHERE peer_id = ?1", params![peer_id])
            .map_err(|e| format!("Failed to remove friend: {e}"))?;
        Ok(())
    }

    /// Load all friends, optionally filtered by status.
    /// Returns Vec<(peer_id, status, direction, requested_at, updated_at)>.
    pub fn load_friends(
        &self,
        status_filter: Option<&str>,
    ) -> Result<Vec<(String, String, String, i64, i64)>, String> {
        let (sql, params_vec): (String, Vec<Box<dyn rusqlite::types::ToSql>>) = if let Some(s) = status_filter {
            (
                "SELECT peer_id, status, direction, requested_at, updated_at FROM friends WHERE status = ?1 ORDER BY updated_at DESC".into(),
                vec![Box::new(s.to_string())],
            )
        } else {
            (
                "SELECT peer_id, status, direction, requested_at, updated_at FROM friends ORDER BY updated_at DESC".into(),
                vec![],
            )
        };

        let params_refs: Vec<&dyn rusqlite::types::ToSql> = params_vec.iter().map(|p| p.as_ref()).collect();
        let mut stmt = self.conn.prepare(&sql).map_err(|e| format!("Failed to prepare friends query: {e}"))?;
        let rows = stmt
            .query_map(params_refs.as_slice(), |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, i64>(4)?,
                ))
            })
            .map_err(|e| format!("Failed to query friends: {e}"))?;

        let mut result = Vec::new();
        for row in rows {
            result.push(row.map_err(|e| format!("Failed to read friend row: {e}"))?);
        }
        Ok(result)
    }

    /// Check if a peer is a friend (any status).
    pub fn get_friend_status(&self, peer_id: &str) -> Result<Option<String>, String> {
        let result = self.conn.query_row(
            "SELECT status FROM friends WHERE peer_id = ?1",
            params![peer_id],
            |row| row.get(0),
        );
        match result {
            Ok(s) => Ok(Some(s)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(format!("Failed to check friend status: {e}")),
        }
    }

    // ── App Settings ──────────────────────────────────────────────

    pub fn save_setting(&self, key: &str, value: &str) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO app_settings (key, value) VALUES (?1, ?2)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![key, value],
            )
            .map_err(|e| format!("Failed to save setting: {e}"))?;
        Ok(())
    }

    /// Load a setting by key. Returns None if not set.
    pub fn load_setting(&self, key: &str) -> Result<Option<String>, String> {
        let mut stmt = self
            .conn
            .prepare("SELECT value FROM app_settings WHERE key = ?1")
            .map_err(|e| format!("Failed to prepare setting query: {e}"))?;
        let mut rows = stmt
            .query_map(params![key], |row| row.get::<_, String>(0))
            .map_err(|e| format!("Failed to query setting: {e}"))?;
        match rows.next() {
            Some(Ok(val)) => Ok(Some(val)),
            Some(Err(e)) => Err(format!("Failed to read setting: {e}")),
            None => Ok(None),
        }
    }

    // ── Verified Peers (RAT Files) ─────────────────────────────────

    /// Mark a peer as identity-verified (fingerprint confirmed).
    pub fn set_peer_verified(&self, peer_id: &str) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        self.conn
            .execute(
                "INSERT INTO verified_peers (peer_id, verified_at) VALUES (?1, ?2)
                 ON CONFLICT(peer_id) DO UPDATE SET verified_at = excluded.verified_at",
                params![peer_id, now],
            )
            .map_err(|e| format!("Failed to set peer verified: {e}"))?;
        Ok(())
    }

    /// Remove verified status from a peer.
    pub fn remove_peer_verified(&self, peer_id: &str) -> Result<(), String> {
        self.conn
            .execute(
                "DELETE FROM verified_peers WHERE peer_id = ?1",
                params![peer_id],
            )
            .map_err(|e| format!("Failed to remove peer verified: {e}"))?;
        Ok(())
    }

    /// Check if a peer is verified.
    pub fn is_peer_verified(&self, peer_id: &str) -> Result<bool, String> {
        let count: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM verified_peers WHERE peer_id = ?1",
                params![peer_id],
                |row| row.get(0),
            )
            .map_err(|e| format!("Failed to check peer verified: {e}"))?;
        Ok(count > 0)
    }

    /// Get all verified peers (peer_id, verified_at_ms).
    pub fn get_verified_peers(&self) -> Result<Vec<(String, i64)>, String> {
        let mut stmt = self
            .conn
            .prepare("SELECT peer_id, verified_at FROM verified_peers ORDER BY verified_at DESC")
            .map_err(|e| format!("Failed to prepare verified_peers query: {e}"))?;
        let rows = stmt
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))
            .map_err(|e| format!("Failed to query verified_peers: {e}"))?;
        let mut result = Vec::new();
        for row in rows {
            if let Ok(r) = row {
                result.push(r);
            }
        }
        Ok(result)
    }

    // ── File sharing storage ────────────────────────────────────────

    /// Insert file metadata (called when FileHeader is received or file is sent).
    #[allow(clippy::too_many_arguments)]
    pub fn insert_file_metadata(
        &self,
        file_id: &str,
        file_name: &str,
        file_ext: &str,
        mime_type: &str,
        size_bytes: u64,
        chunk_count: u32,
        is_image: bool,
        width: Option<u32>,
        height: Option<u32>,
        message_id: Option<&str>,
        context_type: &str,
        context_id: &str,
        sender_id: &str,
        is_mine: bool,
        created_at: i64,
        video_thumb: Option<&crate::node::VideoThumbRef>,
    ) -> Result<(), String> {
        let vthumb_json = video_thumb
            .and_then(|v| serde_json::to_string(v).ok());
        self.conn
            .execute(
                "INSERT OR IGNORE INTO files
                 (file_id, file_name, file_ext, mime_type, size_bytes,
                  chunk_count, is_image, width, height, message_id,
                  context_type, context_id, sender_id, is_mine, created_at,
                  video_thumb_json)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)",
                params![
                    file_id, file_name, file_ext, mime_type,
                    size_bytes as i64, chunk_count, is_image as i32,
                    width.map(|w| w as i64), height.map(|h| h as i64),
                    message_id, context_type, context_id, sender_id,
                    is_mine as i32, created_at, vthumb_json,
                ],
            )
            .map_err(|e| format!("Failed to insert file metadata: {e}"))?;
        Ok(())
    }

    /// Helper: deserialize a VideoThumbRef JSON blob from the DB. Returns None
    /// on null or parse failure (forward-compat).
    fn parse_video_thumb_json(json: Option<String>) -> Option<crate::node::VideoThumbRef> {
        json.and_then(|s| serde_json::from_str(&s).ok())
    }

    /// Mark a chunk as received. Returns the new chunks_received count.
    pub fn mark_chunk_received(
        &self,
        file_id: &str,
        chunk_index: u32,
    ) -> Result<u32, String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        self.conn
            .execute(
                "INSERT OR IGNORE INTO file_chunks (file_id, chunk_index, received_at)
                 VALUES (?1, ?2, ?3)",
                params![file_id, chunk_index, now],
            )
            .map_err(|e| format!("Failed to insert file chunk: {e}"))?;

        // Update the counter on the files table.
        self.conn
            .execute(
                "UPDATE files SET chunks_received = (
                     SELECT COUNT(*) FROM file_chunks WHERE file_id = ?1
                 ) WHERE file_id = ?1",
                params![file_id],
            )
            .map_err(|e| format!("Failed to update chunks_received: {e}"))?;

        // Return current count.
        let count: u32 = self
            .conn
            .query_row(
                "SELECT chunks_received FROM files WHERE file_id = ?1",
                params![file_id],
                |row| row.get(0),
            )
            .map_err(|e| format!("Failed to read chunks_received: {e}"))?;
        Ok(count)
    }

    /// Mark a file as fully received.
    pub fn mark_file_complete(
        &self,
        file_id: &str,
        disk_path: &str,
    ) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        self.conn
            .execute(
                "UPDATE files SET completed_at = ?1, disk_path = ?2 WHERE file_id = ?3",
                params![now, disk_path, file_id],
            )
            .map_err(|e| format!("Failed to mark file complete: {e}"))?;
        Ok(())
    }

    /// Get file metadata by file_id.
    pub fn get_file_metadata(&self, file_id: &str) -> Result<Option<StoredFile>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT file_id, file_name, file_ext, mime_type, size_bytes,
                        chunk_count, chunks_received, is_image, width, height,
                        message_id, context_type, context_id, sender_id, is_mine,
                        created_at, completed_at, disk_path, hidden_at,
                        video_thumb_json, expired_at
                 FROM files WHERE file_id = ?1",
            )
            .map_err(|e| format!("Failed to prepare file query: {e}"))?;

        let result = stmt
            .query_row(params![file_id], |row| {
                Ok(StoredFile {
                    file_id: row.get(0)?,
                    file_name: row.get(1)?,
                    file_ext: row.get(2)?,
                    mime_type: row.get(3)?,
                    size_bytes: row.get::<_, i64>(4)? as u64,
                    chunk_count: row.get::<_, u32>(5)?,
                    chunks_received: row.get::<_, u32>(6)?,
                    is_image: row.get::<_, i32>(7)? != 0,
                    width: row.get::<_, Option<i64>>(8)?.map(|v| v as u32),
                    height: row.get::<_, Option<i64>>(9)?.map(|v| v as u32),
                    message_id: row.get(10)?,
                    context_type: row.get(11)?,
                    context_id: row.get(12)?,
                    sender_id: row.get(13)?,
                    is_mine: row.get::<_, i32>(14)? != 0,
                    created_at: row.get(15)?,
                    completed_at: row.get(16)?,
                    disk_path: row.get(17)?,
                    hidden_at: row.get(18)?,
                    expired_at: row.get(20)?,
                    video_thumb: Self::parse_video_thumb_json(row.get::<_, Option<String>>(19)?),
                })
            })
            .ok();

        Ok(result)
    }

    /// Get all files attached to a specific message.
    pub fn get_files_for_message(&self, message_id: &str) -> Result<Vec<StoredFile>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT file_id, file_name, file_ext, mime_type, size_bytes,
                        chunk_count, chunks_received, is_image, width, height,
                        message_id, context_type, context_id, sender_id, is_mine,
                        created_at, completed_at, disk_path, hidden_at,
                        video_thumb_json, expired_at
                 FROM files WHERE message_id = ?1",
            )
            .map_err(|e| format!("Failed to prepare files query: {e}"))?;

        let rows = stmt
            .query_map(params![message_id], |row| {
                Ok(StoredFile {
                    file_id: row.get(0)?,
                    file_name: row.get(1)?,
                    file_ext: row.get(2)?,
                    mime_type: row.get::<_, String>(3)?,
                    size_bytes: row.get::<_, i64>(4)? as u64,
                    chunk_count: row.get::<_, u32>(5)?,
                    chunks_received: row.get::<_, u32>(6)?,
                    is_image: row.get::<_, i32>(7)? != 0,
                    width: row.get::<_, Option<i64>>(8)?.map(|v| v as u32),
                    height: row.get::<_, Option<i64>>(9)?.map(|v| v as u32),
                    message_id: row.get(10)?,
                    context_type: row.get(11)?,
                    context_id: row.get(12)?,
                    sender_id: row.get(13)?,
                    is_mine: row.get::<_, i32>(14)? != 0,
                    created_at: row.get(15)?,
                    completed_at: row.get(16)?,
                    disk_path: row.get(17)?,
                    hidden_at: row.get(18)?,
                    expired_at: row.get(20)?,
                    video_thumb: Self::parse_video_thumb_json(row.get::<_, Option<String>>(19)?),
                })
            })
            .map_err(|e| format!("Failed to query files: {e}"))?;

        let mut files = Vec::new();
        for row in rows {
            files.push(row.map_err(|e| format!("Failed to read file row: {e}"))?);
        }
        Ok(files)
    }

    /// Get all incomplete files (for sync resume).
    pub fn get_incomplete_files(&self) -> Result<Vec<StoredFile>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT file_id, file_name, file_ext, mime_type, size_bytes,
                        chunk_count, chunks_received, is_image, width, height,
                        message_id, context_type, context_id, sender_id, is_mine,
                        created_at, completed_at, disk_path, hidden_at,
                        video_thumb_json, expired_at
                 FROM files WHERE completed_at IS NULL AND hidden_at IS NULL",
            )
            .map_err(|e| format!("Failed to prepare incomplete files query: {e}"))?;

        let rows = stmt
            .query_map([], |row| {
                Ok(StoredFile {
                    file_id: row.get(0)?,
                    file_name: row.get(1)?,
                    file_ext: row.get(2)?,
                    mime_type: row.get::<_, String>(3)?,
                    size_bytes: row.get::<_, i64>(4)? as u64,
                    chunk_count: row.get::<_, u32>(5)?,
                    chunks_received: row.get::<_, u32>(6)?,
                    is_image: row.get::<_, i32>(7)? != 0,
                    width: row.get::<_, Option<i64>>(8)?.map(|v| v as u32),
                    height: row.get::<_, Option<i64>>(9)?.map(|v| v as u32),
                    message_id: row.get(10)?,
                    context_type: row.get(11)?,
                    context_id: row.get(12)?,
                    sender_id: row.get(13)?,
                    is_mine: row.get::<_, i32>(14)? != 0,
                    created_at: row.get(15)?,
                    completed_at: row.get(16)?,
                    disk_path: row.get(17)?,
                    hidden_at: row.get(18)?,
                    expired_at: row.get(20)?,
                    video_thumb: Self::parse_video_thumb_json(row.get::<_, Option<String>>(19)?),
                })
            })
            .map_err(|e| format!("Failed to query incomplete files: {e}"))?;

        let mut files = Vec::new();
        for row in rows {
            files.push(row.map_err(|e| format!("Failed to read file row: {e}"))?);
        }
        Ok(files)
    }

    /// Get total file storage used for a server (sum of size_bytes for completed files).
    /// context_id for channel files is "server_id:channel_id", so we match with LIKE 'server_id:%'.
    pub fn total_file_storage_for_server(&self, server_id: &str) -> Result<u64, String> {
        let pattern = format!("{server_id}:%");
        let result: i64 = self
            .conn
            .query_row(
                "SELECT COALESCE(SUM(size_bytes), 0) FROM files
                 WHERE context_type = 'channel' AND context_id LIKE ?1
                 AND completed_at IS NOT NULL",
                [&pattern],
                |row| row.get(0),
            )
            .map_err(|e| format!("Failed to sum file storage: {e}"))?;
        Ok(result.max(0) as u64)
    }

    /// Sum the byte-length of all message text for a server (across all channels).
    pub fn total_message_storage_for_server(&self, server_id: &str) -> Result<u64, String> {
        let result: i64 = self
            .conn
            .query_row(
                "SELECT COALESCE(SUM(LENGTH(text)), 0) FROM channel_messages WHERE server_id = ?1",
                params![server_id],
                |row| row.get(0),
            )
            .map_err(|e| format!("Failed to sum message storage: {e}"))?;
        Ok(result.max(0) as u64)
    }

    /// Get missing chunk indices for a file.
    pub fn get_missing_chunks(&self, file_id: &str) -> Result<Vec<u32>, String> {
        let file = self.get_file_metadata(file_id)?;
        let file = match file {
            Some(f) => f,
            None => return Err(format!("File not found: {file_id}")),
        };

        let mut stmt = self
            .conn
            .prepare(
                "SELECT chunk_index FROM file_chunks WHERE file_id = ?1",
            )
            .map_err(|e| format!("Failed to prepare chunks query: {e}"))?;

        let received: std::collections::HashSet<u32> = stmt
            .query_map(params![file_id], |row| row.get::<_, u32>(0))
            .map_err(|e| format!("Failed to query chunks: {e}"))?
            .filter_map(|r| r.ok())
            .collect();

        let missing: Vec<u32> = (0..file.chunk_count)
            .filter(|i| !received.contains(i))
            .collect();

        Ok(missing)
    }

    /// Get file_ids from messages that have a file_id but no completed file entry.
    /// Used to find files that need downloading after message sync.
    pub fn get_missing_file_ids(&self) -> Result<Vec<String>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT DISTINCT cm.file_id FROM channel_messages cm
                 WHERE cm.file_id IS NOT NULL
                 AND cm.file_id NOT IN (SELECT file_id FROM files WHERE completed_at IS NOT NULL)
                 UNION
                 SELECT DISTINCT m.file_id FROM messages m
                 WHERE m.file_id IS NOT NULL
                 AND m.file_id NOT IN (SELECT file_id FROM files WHERE completed_at IS NOT NULL)",
            )
            .map_err(|e| format!("Failed to prepare missing files query: {e}"))?;

        let rows = stmt
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|e| format!("Failed to query missing files: {e}"))?;

        let mut ids = Vec::new();
        for row in rows {
            if let Ok(id) = row {
                ids.push(id);
            }
        }
        Ok(ids)
    }

    /// Scan completed files for stale disk_paths (file no longer exists on disk).
    /// Resets those entries to incomplete so they get re-requested from peers.
    /// Returns the number of entries reset.
    pub fn reset_stale_file_paths(&self) -> Result<u32, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT file_id, disk_path FROM files
                 WHERE completed_at IS NOT NULL AND disk_path IS NOT NULL",
            )
            .map_err(|e| format!("Failed to prepare stale files query: {e}"))?;

        let rows = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                ))
            })
            .map_err(|e| format!("Failed to query completed files: {e}"))?;

        let mut stale_ids = Vec::new();
        for row in rows {
            if let Ok((file_id, disk_path)) = row {
                if !std::path::Path::new(&disk_path).exists() {
                    stale_ids.push(file_id);
                }
            }
        }

        if stale_ids.is_empty() {
            return Ok(0);
        }

        let count = stale_ids.len() as u32;
        for file_id in &stale_ids {
            self.conn
                .execute(
                    "UPDATE files SET disk_path = NULL, completed_at = NULL WHERE file_id = ?1",
                    rusqlite::params![file_id],
                )
                .map_err(|e| format!("Failed to reset stale file {file_id}: {e}"))?;
        }

        Ok(count)
    }

    /// Get file_ids for missing *image* files in a specific server.
    /// Used for late-joiner image sync in 6+ member servers where non-image files
    /// use vault erasure shards instead of P2P streaming.
    pub fn get_missing_image_file_ids_for_server(&self, server_id: &str) -> Result<Vec<String>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT DISTINCT cm.file_id FROM channel_messages cm
                 JOIN files f ON cm.file_id = f.file_id
                 WHERE cm.server_id = ?1
                 AND f.is_image = 1
                 AND f.completed_at IS NULL",
            )
            .map_err(|e| format!("Failed to prepare missing image files query: {e}"))?;

        let rows = stmt
            .query_map([server_id], |row| row.get::<_, String>(0))
            .map_err(|e| format!("Failed to query missing image files: {e}"))?;

        let mut ids = Vec::new();
        for row in rows {
            if let Ok(id) = row {
                ids.push(id);
            }
        }
        Ok(ids)
    }

    /// Link a vault content_id to a file record via its message_id.
    /// Used when VaultUploadFile completes (sender) or VaultManifestBroadcast arrives (receiver).
    pub fn set_file_content_id(&self, message_id: &str, content_id: &str) -> Result<(), String> {
        self.conn
            .execute(
                "UPDATE files SET content_id = ?1 WHERE message_id = ?2",
                params![content_id, message_id],
            )
            .map_err(|e| format!("Failed to set file content_id: {e}"))?;
        Ok(())
    }

    /// Get the vault content_id for a file by its file_id.
    /// Returns None if the file doesn't have a vault content_id (e.g. DM files, <6 member files).
    pub fn get_content_id_for_file(&self, file_id: &str) -> Result<Option<String>, String> {
        self.conn
            .query_row(
                "SELECT content_id FROM files WHERE file_id = ?1",
                params![file_id],
                |row| row.get::<_, Option<String>>(0),
            )
            .map_err(|e| format!("Failed to query content_id: {e}"))
    }

    // -- Hollow Share (Phase 7A) --

    /// Insert or replace a share row. Used both at create-time (we made the share)
    /// and at open-link-time (we received the link, manifest will arrive later).
    #[allow(clippy::too_many_arguments)]
    pub fn upsert_share(
        &self,
        root_hash: &str,
        file_name: &str,
        file_ext: &str,
        mime: &str,
        total_size: u64,
        chunk_size: u32,
        chunk_count: u32,
        manifest_json: &str,
        encryption_key: &[u8],
        share_link: &str,
        state: &str,
        seeding: bool,
        disk_path: Option<&str>,
        save_dir: Option<&str>,
        created_at: i64,
        server_id: Option<&str>,
        context_type: Option<&str>,
    ) -> Result<(), String> {
        self.conn.execute(
            "INSERT OR REPLACE INTO shares (
                root_hash, file_name, file_ext, mime, total_size, chunk_size, chunk_count,
                manifest_json, encryption_key, share_link, state, seeding, disk_path, save_dir,
                bytes_uploaded, created_at, completed_at, server_id, context_type
            ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,
                COALESCE((SELECT bytes_uploaded FROM shares WHERE root_hash = ?1), 0),
                ?15,
                (SELECT completed_at FROM shares WHERE root_hash = ?1),
                ?16, ?17
            )",
            params![
                root_hash, file_name, file_ext, mime,
                total_size as i64, chunk_size as i64, chunk_count as i64,
                manifest_json, encryption_key, share_link, state, seeding as i32,
                disk_path, save_dir, created_at, server_id, context_type,
            ],
        ).map_err(|e| format!("Failed to upsert share: {e}"))?;
        Ok(())
    }

    /// Update only the save_dir for a share. Used by share_start when the
    /// caller passes a new download location.
    pub fn set_share_save_dir(&self, root_hash: &str, save_dir: &str) -> Result<(), String> {
        self.conn.execute(
            "UPDATE shares SET save_dir = ?2 WHERE root_hash = ?1",
            params![root_hash, save_dir],
        ).map_err(|e| format!("Failed to set save_dir: {e}"))?;
        Ok(())
    }

    pub fn load_share(&self, root_hash: &str) -> Result<Option<StoredShare>, String> {
        let mut stmt = self.conn.prepare(
            "SELECT root_hash, file_name, file_ext, mime, total_size, chunk_size, chunk_count,
                    manifest_json, encryption_key, share_link, state, seeding, disk_path,
                    bytes_uploaded, created_at, completed_at, save_dir, server_id, context_type
             FROM shares WHERE root_hash = ?1",
        ).map_err(|e| format!("Failed to prepare load_share: {e}"))?;
        let mut rows = stmt.query(params![root_hash])
            .map_err(|e| format!("Failed to query share: {e}"))?;
        if let Some(row) = rows.next().map_err(|e| format!("Row error: {e}"))? {
            Ok(Some(stored_share_from_row(row)?))
        } else {
            Ok(None)
        }
    }

    pub fn load_shares(&self) -> Result<Vec<StoredShare>, String> {
        let mut stmt = self.conn.prepare(
            "SELECT root_hash, file_name, file_ext, mime, total_size, chunk_size, chunk_count,
                    manifest_json, encryption_key, share_link, state, seeding, disk_path,
                    bytes_uploaded, created_at, completed_at, save_dir, server_id, context_type
             FROM shares ORDER BY created_at DESC",
        ).map_err(|e| format!("Failed to prepare load_shares: {e}"))?;
        let mut rows = stmt.query([])
            .map_err(|e| format!("Failed to query shares: {e}"))?;
        let mut out = Vec::new();
        while let Some(row) = rows.next().map_err(|e| format!("Row error: {e}"))? {
            out.push(stored_share_from_row(row)?);
        }
        Ok(out)
    }

    pub fn mark_share_complete(&self, root_hash: &str, disk_path: &str, completed_at: i64) -> Result<(), String> {
        self.conn.execute(
            "UPDATE shares SET state = 'completed', disk_path = ?2, completed_at = ?3 WHERE root_hash = ?1",
            params![root_hash, disk_path, completed_at],
        ).map_err(|e| format!("Failed to mark share complete: {e}"))?;
        Ok(())
    }

    pub fn update_share_disk_path(&self, root_hash: &str, disk_path: &str) -> Result<(), String> {
        self.conn.execute(
            "UPDATE shares SET disk_path = ?2 WHERE root_hash = ?1",
            params![root_hash, disk_path],
        ).map_err(|e| format!("Failed to update share disk_path: {e}"))?;
        Ok(())
    }

    pub fn set_share_state(&self, root_hash: &str, state: &str) -> Result<(), String> {
        self.conn.execute(
            "UPDATE shares SET state = ?2 WHERE root_hash = ?1",
            params![root_hash, state],
        ).map_err(|e| format!("Failed to set share state: {e}"))?;
        Ok(())
    }

    pub fn set_share_seeding(&self, root_hash: &str, seeding: bool) -> Result<(), String> {
        self.conn.execute(
            "UPDATE shares SET seeding = ?2 WHERE root_hash = ?1",
            params![root_hash, seeding as i32],
        ).map_err(|e| format!("Failed to set share seeding: {e}"))?;
        Ok(())
    }

    pub fn add_share_bytes_uploaded(&self, root_hash: &str, delta: u64) -> Result<(), String> {
        self.conn.execute(
            "UPDATE shares SET bytes_uploaded = bytes_uploaded + ?2 WHERE root_hash = ?1",
            params![root_hash, delta as i64],
        ).map_err(|e| format!("Failed to add share bytes_uploaded: {e}"))?;
        Ok(())
    }

    pub fn delete_share(&self, root_hash: &str) -> Result<(), String> {
        self.conn.execute(
            "DELETE FROM share_chunks WHERE root_hash = ?1",
            params![root_hash],
        ).map_err(|e| format!("Failed to delete share_chunks row: {e}"))?;
        self.conn.execute(
            "DELETE FROM shares WHERE root_hash = ?1",
            params![root_hash],
        ).map_err(|e| format!("Failed to delete share row: {e}"))?;
        Ok(())
    }

    pub fn save_chunk_bitmap(&self, root_hash: &str, bitmap: &[u8], updated_at: i64) -> Result<(), String> {
        self.conn.execute(
            "INSERT OR REPLACE INTO share_chunks (root_hash, bitmap_blob, updated_at) VALUES (?1, ?2, ?3)",
            params![root_hash, bitmap, updated_at],
        ).map_err(|e| format!("Failed to save chunk bitmap: {e}"))?;
        Ok(())
    }

    pub fn load_chunk_bitmap(&self, root_hash: &str) -> Result<Option<Vec<u8>>, String> {
        self.conn
            .query_row(
                "SELECT bitmap_blob FROM share_chunks WHERE root_hash = ?1",
                params![root_hash],
                |row| row.get::<_, Vec<u8>>(0),
            )
            .map(Some)
            .or_else(|e| match e {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                other => Err(format!("Failed to load chunk bitmap: {other}")),
            })
    }
}

/// Persisted share row.
pub struct StoredShare {
    pub root_hash: String,
    pub file_name: String,
    pub file_ext: String,
    pub mime: String,
    pub total_size: u64,
    pub chunk_size: u32,
    pub chunk_count: u32,
    pub manifest_json: String,
    pub encryption_key: Vec<u8>,
    pub share_link: String,
    pub state: String,
    pub seeding: bool,
    pub disk_path: Option<String>,
    pub bytes_uploaded: u64,
    pub created_at: i64,
    pub completed_at: Option<i64>,
    pub save_dir: Option<String>,
    pub server_id: Option<String>,
    pub context_type: Option<String>,
}

fn stored_share_from_row(row: &rusqlite::Row<'_>) -> Result<StoredShare, String> {
    Ok(StoredShare {
        root_hash:      row.get(0).map_err(|e| format!("col 0: {e}"))?,
        file_name:      row.get(1).map_err(|e| format!("col 1: {e}"))?,
        file_ext:       row.get(2).map_err(|e| format!("col 2: {e}"))?,
        mime:           row.get(3).map_err(|e| format!("col 3: {e}"))?,
        total_size:     row.get::<_, i64>(4).map_err(|e| format!("col 4: {e}"))? as u64,
        chunk_size:     row.get::<_, i64>(5).map_err(|e| format!("col 5: {e}"))? as u32,
        chunk_count:    row.get::<_, i64>(6).map_err(|e| format!("col 6: {e}"))? as u32,
        manifest_json:  row.get(7).map_err(|e| format!("col 7: {e}"))?,
        encryption_key: row.get(8).map_err(|e| format!("col 8: {e}"))?,
        share_link:     row.get(9).map_err(|e| format!("col 9: {e}"))?,
        state:          row.get(10).map_err(|e| format!("col 10: {e}"))?,
        seeding:        row.get::<_, i32>(11).map_err(|e| format!("col 11: {e}"))? != 0,
        disk_path:      row.get::<_, Option<String>>(12).map_err(|e| format!("col 12: {e}"))?,
        bytes_uploaded: row.get::<_, i64>(13).map_err(|e| format!("col 13: {e}"))? as u64,
        created_at:     row.get(14).map_err(|e| format!("col 14: {e}"))?,
        completed_at:   row.get::<_, Option<i64>>(15).map_err(|e| format!("col 15: {e}"))?,
        save_dir:       row.get::<_, Option<String>>(16).map_err(|e| format!("col 16: {e}"))?,
        server_id:      row.get::<_, Option<String>>(17).unwrap_or(None),
        context_type:   row.get::<_, Option<String>>(18).unwrap_or(None),
    })
}
