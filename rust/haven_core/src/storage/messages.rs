use rusqlite::{params, Connection};

use crate::crdt::operations::CrdtOp;

/// A stored chat message.
pub(crate) struct StoredMessage {
    pub id: i64,
    pub peer_id: String,
    pub text: String,
    pub is_mine: bool,
    pub timestamp: i64,
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

        Ok(MessageStore { conn })
    }

    /// Insert a message. Returns the row ID.
    pub fn insert(
        &self,
        peer_id: &str,
        text: &str,
        is_mine: bool,
        timestamp: i64,
    ) -> Result<i64, String> {
        self.conn
            .execute(
                "INSERT INTO messages (peer_id, text, is_mine, timestamp) VALUES (?1, ?2, ?3, ?4)",
                params![peer_id, text, is_mine as i32, timestamp],
            )
            .map_err(|e| format!("Failed to insert message: {e}"))?;
        Ok(self.conn.last_insert_rowid())
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
    pub fn load_for_peer(
        &self,
        peer_id: &str,
        limit: i32,
    ) -> Result<Vec<StoredMessage>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, peer_id, text, is_mine, timestamp
                 FROM messages
                 WHERE peer_id = ?1
                 ORDER BY timestamp DESC
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
}
