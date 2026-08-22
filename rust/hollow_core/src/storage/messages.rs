use std::collections::HashMap;

use rusqlite::{params, Connection};

use crate::crdt::operations::CrdtOp;

/// Sync lookback overlap (ms). "Since" watermarks are per-sender/-conversation
/// MAX timestamps, and a plain high-watermark permanently skips a message that
/// was MISSED while a newer one arrived (live topic miss during a
/// subscribe/reconnect window, push-fetch inserting newer rows first, …).
/// Requesters therefore ask from `watermark - SYNC_LOOKBACK_MS`; receivers
/// deduplicate the overlap by message_id, so the only cost is responders
/// re-sending up to this much recent history per sync request.
pub(crate) const SYNC_LOOKBACK_MS: i64 = 30 * 60 * 1000;

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
    /// Showcase board JSON (profile blocks; empty = no board).
    pub showcase_board: String,
    /// Showcase asset bundle blob (game covers/artwork keyed by hash).
    pub showcase_assets: Option<Vec<u8>>,
    /// Avatar frame ID (issue #54). `""` = none, `"b:<hue>"` = a built-in
    /// procedural frame, 64-hex = an asset-rail blob hash. Never bytes: the
    /// art rides the rail so it can be evicted, unlike a profile push.
    pub avatar_frame: String,
    /// The SUBJECT's own signature over the relayable subset of this profile
    /// (`crypto_handler::profile_signing_payload`). Persisted so we can forward
    /// it in a `ProfileRelay` — a relayed profile with no owner signature is
    /// refused by the receiver, so a profile stored without one simply never
    /// gets relayed. Not populated by the light loaders.
    pub profile_sig: Option<String>,
    /// Owner MASTER public key (base64 protobuf) paired with `profile_sig`.
    pub profile_pk: Option<String>,
    /// The avatar hash the signature was made over. Stored rather than derived
    /// from `avatar_bytes`: announces are LIGHT (hash only, no blob), so our
    /// cached blob can lag the owner's current one. Re-hashing a stale blob at
    /// relay time would produce a hash the signature does not cover and every
    /// receiver would reject the relay.
    pub profile_avatar_hash: Option<String>,
}

/// The subject's proof for a profile, moved as one unit because the three parts
/// are only meaningful together (see [`StoredProfile::profile_avatar_hash`]).
/// `None` at a `save_profile` call = "leave the stored proof alone".
#[derive(Clone, Copy)]
pub(crate) struct ProfileProof<'a> {
    pub sig: &'a str,
    pub pk: &'a str,
    pub avatar_hash: &'a str,
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
    /// Microsecond send timestamp for stable ordering (Step 9C/C4). `None` for
    /// legacy rows (predate the column) → callers fall back to `timestamp * 1000`.
    pub order_us: Option<i64>,
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
    /// Microsecond send timestamp for stable ordering (Step 9C/C4). `None` for
    /// legacy rows (predate the column) → callers fall back to `timestamp * 1000`.
    pub order_us: Option<i64>,
}

/// One message row's signature-relevant fields (v2 message signing) — see
/// [`MessageStore::get_dm_message_sig_row`]. Not a display row: only what a
/// signer/verifier needs to build the canonical payload.
pub(crate) struct MessageSigRow {
    pub text: String,
    pub timestamp: i64,
    pub signature: Option<String>,
    pub public_key: Option<String>,
    pub edited_at: Option<i64>,
    pub reply_to_mid: Option<String>,
    pub file_id: Option<String>,
    pub order_us: Option<i64>,
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
    /// Share back-reference for share-backed (>34 MB) files, persisted so a
    /// manual download can rejoin the share swarm after a restart (issue #41).
    pub share_ref: Option<crate::node::ShareRef>,
    /// Tiny base64 WebP placeholder thumbnail riding the FileHeader (issue #41
    /// carry-over) — rendered blurred under the Download button while the real
    /// bytes are gated/undownloaded. `thumb_b64` column.
    pub thumb_b64: Option<String>,
}

/// One sticker of the user's personal vault. `pack` is a free-form group
/// name (`""` = the default, ungrouped pack) and `(pack, hash)` is the row
/// identity — see the `personal_stickers` DDL for why that, and not the name.
#[derive(Clone, Debug)]
pub(crate) struct PersonalStickerRow {
    pub pack: String,
    pub hash: String,
    pub name: String,
    pub animated: bool,
    pub w: u32,
    pub h: u32,
    /// `"upload"` | `"klipy:<id>"` — provenance only, never fetched at
    /// display time (the bytes are already local and content-addressed).
    pub source: String,
    pub added_at: i64,
}

/// Encrypted SQLite message store.
pub(crate) struct MessageStore {
    conn: Connection,
}

/// Run one idempotent DDL statement (CREATE TABLE/INDEX …), mapping failure
/// to a labeled error. Shared with the vault ContentStore schema setup.
pub(crate) fn ddl(conn: &Connection, what: &str, sql: &str) -> Result<(), String> {
    conn.execute(sql, [])
        .map(|_| ())
        .map_err(|e| format!("Failed to create {what}: {e}"))
}

/// Run one idempotent migration statement (ALTER TABLE ADD COLUMN & friends)
/// in its own batch, silently ignoring the "already exists" error a re-run
/// produces. Never batch multiple migrations into one call — the first
/// already-applied statement would abort the rest of the batch.
pub(crate) fn migrate(conn: &Connection, sql: &str) {
    conn.execute_batch(sql).unwrap_or(());
}

/// Drain a mapped-row iterator into a Vec, labeling the first read error.
fn collect_rows<T>(
    rows: impl Iterator<Item = rusqlite::Result<T>>,
    what: &str,
) -> Result<Vec<T>, String> {
    let mut out = Vec::new();
    for row in rows {
        out.push(row.map_err(|e| format!("Failed to read {what} row: {e}"))?);
    }
    Ok(out)
}

/// A signed per-message evidence row: (emoji, peer_id, at_ms, signature,
/// public_key) — shape shared by reaction sync rows and reaction removals.
pub(crate) type SignedEmojiRow = (String, String, i64, Option<String>, Option<String>);

/// Column list every DM-message query selects, in [`dm_message_from_row`] order.
const DM_MSG_COLS: &str = "id, peer_id, text, is_mine, timestamp, signature, public_key, message_id, edited_at, hidden_at, reply_to_mid, file_id, link_preview_json, order_us";

/// Column list every channel-message query selects, in [`channel_message_from_row`] order.
const CHANNEL_MSG_COLS: &str = "id, server_id, channel_id, sender_id, text, is_mine, timestamp, signature, public_key, message_id, edited_at, hidden_at, reply_to_mid, file_id, link_preview_json, order_us";

/// The column tail shared by DM and channel message rows, in select order:
/// text, is_mine, timestamp, signature, public_key, message_id, edited_at,
/// hidden_at, reply_to_mid, file_id, link_preview, order_us.
struct MsgTail {
    text: String,
    is_mine: bool,
    timestamp: i64,
    signature: Option<String>,
    public_key: Option<String>,
    message_id: Option<String>,
    edited_at: Option<i64>,
    hidden_at: Option<i64>,
    reply_to_mid: Option<String>,
    file_id: Option<String>,
    link_preview: Option<crate::node::LinkPreviewRef>,
    order_us: Option<i64>,
}

/// Read the shared message-column tail starting at column index `base`
/// (2 for DM rows after id/peer_id, 4 for channel rows after
/// id/server_id/channel_id/sender_id).
fn msg_tail_from_row(row: &rusqlite::Row<'_>, base: usize) -> rusqlite::Result<MsgTail> {
    Ok(MsgTail {
        text: row.get(base)?,
        is_mine: row.get::<_, i32>(base + 1)? != 0,
        timestamp: row.get(base + 2)?,
        signature: row.get(base + 3)?,
        public_key: row.get(base + 4)?,
        message_id: row.get(base + 5)?,
        edited_at: row.get(base + 6)?,
        hidden_at: row.get(base + 7)?,
        reply_to_mid: row.get(base + 8)?,
        file_id: row.get(base + 9)?,
        link_preview: row.get::<_, Option<String>>(base + 10)?
            .and_then(|s| serde_json::from_str(&s).ok()),
        order_us: row.get(base + 11)?,
    })
}

/// Map one row selected via [`DM_MSG_COLS`] to a StoredMessage.
fn dm_message_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<StoredMessage> {
    let t = msg_tail_from_row(row, 2)?;
    Ok(StoredMessage {
        id: row.get(0)?,
        peer_id: row.get(1)?,
        text: t.text,
        is_mine: t.is_mine,
        timestamp: t.timestamp,
        signature: t.signature,
        public_key: t.public_key,
        message_id: t.message_id,
        edited_at: t.edited_at,
        hidden_at: t.hidden_at,
        reply_to_mid: t.reply_to_mid,
        file_id: t.file_id,
        link_preview: t.link_preview,
        order_us: t.order_us,
    })
}

/// Column list every files query selects, in [`stored_file_from_row`] order.
const FILE_COLS: &str = "file_id, file_name, file_ext, mime_type, size_bytes, chunk_count, chunks_received, is_image, width, height, message_id, context_type, context_id, sender_id, is_mine, created_at, completed_at, disk_path, hidden_at, video_thumb_json, expired_at, share_ref_json, thumb_b64";

/// Map one row selected via [`FILE_COLS`] to a StoredFile.
fn stored_file_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<StoredFile> {
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
        video_thumb: MessageStore::parse_video_thumb_json(row.get::<_, Option<String>>(19)?),
        share_ref: row
            .get::<_, Option<String>>(21)?
            .and_then(|s| serde_json::from_str(&s).ok()),
        thumb_b64: row.get(22)?,
    })
}

/// Map one full profile row (peer_id, display_name, status, about_me,
/// updated_at, avatar, banner, twitch_username, showcase_board,
/// showcase_assets, proof triple, avatar_frame) to a StoredProfile.
fn profile_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<StoredProfile> {
    Ok(StoredProfile {
        peer_id: row.get(0)?,
        display_name: row.get(1)?,
        status: row.get(2)?,
        about_me: row.get(3)?,
        updated_at: row.get(4)?,
        avatar_bytes: row.get(5)?,
        banner_bytes: row.get(6)?,
        twitch_username: row.get::<_, String>(7).unwrap_or_default(),
        showcase_board: row.get::<_, String>(8).unwrap_or_default(),
        showcase_assets: row.get(9).unwrap_or(None),
        profile_sig: row.get(10).unwrap_or(None),
        profile_pk: row.get(11).unwrap_or(None),
        profile_avatar_hash: row.get(12).unwrap_or(None),
        avatar_frame: row.get::<_, String>(13).unwrap_or_default(),
    })
}

/// Map one light profile row (peer_id, display_name, status, about_me,
/// updated_at, twitch_username, showcase_board, avatar_frame — no blobs) to a
/// StoredProfile. The frame is an ID, not bytes, so it rides the light load:
/// every list that renders an avatar needs it.
fn profile_light_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<StoredProfile> {
    Ok(StoredProfile {
        peer_id: row.get(0)?,
        display_name: row.get(1)?,
        status: row.get(2)?,
        about_me: row.get(3)?,
        updated_at: row.get(4)?,
        avatar_bytes: None,
        banner_bytes: None,
        twitch_username: row.get::<_, String>(5).unwrap_or_default(),
        showcase_board: row.get::<_, String>(6).unwrap_or_default(),
        showcase_assets: None,
        // Light loads are for RENDERING; relaying needs `load_profile`.
        profile_sig: None,
        profile_pk: None,
        profile_avatar_hash: None,
        avatar_frame: row.get::<_, String>(7).unwrap_or_default(),
    })
}

/// Map one row selected via [`CHANNEL_MSG_COLS`] to a StoredChannelMessage.
fn channel_message_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<StoredChannelMessage> {
    let t = msg_tail_from_row(row, 4)?;
    Ok(StoredChannelMessage {
        id: row.get(0)?,
        server_id: row.get(1)?,
        channel_id: row.get(2)?,
        sender_id: row.get(3)?,
        text: t.text,
        is_mine: t.is_mine,
        timestamp: t.timestamp,
        signature: t.signature,
        public_key: t.public_key,
        message_id: t.message_id,
        edited_at: t.edited_at,
        hidden_at: t.hidden_at,
        reply_to_mid: t.reply_to_mid,
        file_id: t.file_id,
        link_preview: t.link_preview,
        order_us: t.order_us,
    })
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

        // NOTE: auto_vacuum conversion + incremental reclaim is NOT done here.
        // `open()` is the universal path (~139 transient call sites) and the
        // CrdtStore/CryptoStore actors hold long-lived connections to the SAME
        // WAL file — running `PRAGMA auto_vacuum` (a page-1 read) + `VACUUM` (an
        // exclusive-lock full-file rewrite) on every concurrent open raced the
        // SQLCipher codec and spewed `hmac check failed for pgno=1` to stderr
        // (harmless — swallowed — but noisy in prod + the test harness). The
        // one-time legacy migration now runs ONCE at startup in a single-connection
        // window via `migrate_auto_vacuum_once` (see api/network.rs::start_node).

        // Journal mode: WAL everywhere EXCEPT iOS.
        //
        // On iOS the messages.db lives in the shared App Group container so the
        // Notification Service Extension can open it to fetch+decrypt push
        // messages. WAL keeps a PERSISTENT shared-memory lock file (`-shm`) open;
        // iOS's RunningBoard watchdog kills any app suspended while holding a
        // file lock in a shared container (`EXC_CRASH 0xdead10cc`). Rollback-
        // journal mode (TRUNCATE) only locks DURING a transaction, never
        // persistently, so the app can be suspended safely while the NSE shares
        // the file. The mobile write volume (chat) makes the small WAL-vs-
        // rollback speed difference negligible. Desktop/Android keep WAL.
        #[cfg(target_os = "ios")]
        let journal_pragma = "PRAGMA journal_mode = TRUNCATE;";
        #[cfg(not(target_os = "ios"))]
        let journal_pragma = "PRAGMA journal_mode = WAL;";

        conn.execute_batch(&format!(
            "{journal_pragma}
             PRAGMA synchronous = NORMAL;
             PRAGMA cache_size = -8000;
             PRAGMA temp_store = MEMORY;
             PRAGMA busy_timeout = 4000;"
        )).map_err(|e| format!("Failed to set performance PRAGMAs: {e}"))?;

        // Schema DDL (~25 CREATE TABLE + ~40 ALTER + indexes + FTS triggers)
        // used to replay on EVERY open — real per-call milliseconds on the hot
        // per-message/per-chunk paths (~139 transient call sites). Run it once
        // per process per DB path instead. `IF NOT EXISTS` semantics are
        // unchanged, and a fresh process after an app update still self-heals
        // new columns/tables on its first open. The mutex also serializes the
        // first-open DDL against concurrent opens on a brand-new DB.
        //
        // The path memo alone is NOT enough: a wipe/reset (and the unit tests)
        // can delete the DB file and re-open the SAME path within one process
        // — the fresh file has no tables. Pair the memo with a one-row
        // sqlite_master probe (microseconds) so a schemaless file always gets
        // the DDL regardless of the memo.
        {
            use std::sync::{Mutex as StdMutex, OnceLock};
            static SCHEMA_DONE: OnceLock<StdMutex<std::collections::HashSet<String>>> =
                OnceLock::new();
            let done = SCHEMA_DONE
                .get_or_init(|| StdMutex::new(std::collections::HashSet::new()));
            let mut ready = done
                .lock()
                .map_err(|e| format!("Schema gate lock poisoned: {e}"))?;
            let has_core_table: bool = conn
                .query_row(
                    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='messages' LIMIT 1",
                    [],
                    |_| Ok(()),
                )
                .is_ok();
            if !ready.contains(path) || !has_core_table {
                Self::init_schema(&conn)?;
                ready.insert(path.to_string());
            }
        }

        Ok(MessageStore { conn })
    }

    /// All schema DDL + idempotent data migrations, previously inline in
    /// `open()`. Runs once per process per DB path — see the gate in `open()`.
    fn init_schema(conn: &Connection) -> Result<(), String> {
        // Create messages table if it doesn't exist.
        ddl(conn, "messages table",
            "CREATE TABLE IF NOT EXISTS messages (
                id        INTEGER PRIMARY KEY AUTOINCREMENT,
                peer_id   TEXT    NOT NULL,
                text      TEXT    NOT NULL,
                is_mine   INTEGER NOT NULL,
                timestamp INTEGER NOT NULL
            )")?;

        // Index for fast per-peer lookups.
        ddl(conn, "index",
            "CREATE INDEX IF NOT EXISTS idx_messages_peer_ts ON messages (peer_id, timestamp)")?;

        // Olm account pickle (singleton row, id=1).
        ddl(conn, "olm_account table",
            "CREATE TABLE IF NOT EXISTS olm_account (
                id     INTEGER PRIMARY KEY CHECK (id = 1),
                pickle TEXT NOT NULL
            )")?;

        // Olm sessions, one per peer.
        ddl(conn, "olm_sessions table",
            "CREATE TABLE IF NOT EXISTS olm_sessions (
                peer_id TEXT PRIMARY KEY,
                pickle  TEXT NOT NULL
            )")?;

        // Channel messages table.
        ddl(conn, "channel_messages table",
            "CREATE TABLE IF NOT EXISTS channel_messages (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                server_id  TEXT    NOT NULL,
                channel_id TEXT    NOT NULL,
                sender_id  TEXT    NOT NULL,
                text       TEXT    NOT NULL,
                is_mine    INTEGER NOT NULL,
                timestamp  INTEGER NOT NULL,
                UNIQUE(server_id, channel_id, sender_id, timestamp, text)
            )")?;

        ddl(conn, "channel_messages index",
            "CREATE INDEX IF NOT EXISTS idx_channel_msgs ON channel_messages (server_id, channel_id, timestamp)")?;

        // Migration: add UNIQUE constraint to existing channel_messages tables.
        // SQLite can't ALTER constraints, so we create a unique index instead.
        //
        // The index is PARTIAL (message_id IS NULL): the original full-table
        // content index treated two DISTINCT rapid messages with identical
        // text in the same millisecond as one duplicate and dropped the
        // second (fast channel spam lost messages). Rows carrying a
        // message_id dedup by channel_message_exists() at every insert site;
        // the content index (and the cleanup DELETE) apply only to legacy
        // rows without one — the DELETE must NEVER eat distinct mid rows.
        migrate(conn, "DROP INDEX IF EXISTS idx_channel_msgs_unique;");
        conn.execute_batch(
            "DELETE FROM channel_messages WHERE message_id IS NULL AND id NOT IN (
                SELECT MIN(id) FROM channel_messages WHERE message_id IS NULL
                GROUP BY server_id, channel_id, sender_id, timestamp, text
             );
             CREATE UNIQUE INDEX IF NOT EXISTS idx_channel_msgs_unique_legacy
             ON channel_messages (server_id, channel_id, sender_id, timestamp, text)
             WHERE message_id IS NULL;"
        ).unwrap_or_else(|e| {
            eprintln!("[HOLLOW] channel_messages legacy dedup migration failed: {e}");
        });

        // -- CRDT tables (Phase 3) --

        ddl(conn, "servers table",
            "CREATE TABLE IF NOT EXISTS servers (
                server_id  TEXT PRIMARY KEY,
                state_json TEXT NOT NULL,
                updated_at INTEGER NOT NULL
            )")?;

        ddl(conn, "crdt_ops table",
            "CREATE TABLE IF NOT EXISTS crdt_ops (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                server_id   TEXT NOT NULL,
                hlc_ms      INTEGER NOT NULL,
                hlc_counter INTEGER NOT NULL,
                author      TEXT NOT NULL,
                op_json     TEXT NOT NULL,
                UNIQUE(server_id, hlc_ms, hlc_counter, author)
            )")?;

        ddl(conn, "crdt_ops index",
            "CREATE INDEX IF NOT EXISTS idx_crdt_ops_server ON crdt_ops (server_id, hlc_ms)")?;

        ddl(conn, "hlc_state table",
            "CREATE TABLE IF NOT EXISTS hlc_state (
                id          INTEGER PRIMARY KEY CHECK (id = 1),
                physical_ms INTEGER NOT NULL,
                counter     INTEGER NOT NULL,
                actor       TEXT NOT NULL
            )")?;

        // -- Migration: Ed25519 signature columns --
        // ALTER TABLE ADD COLUMN is safe for nullable columns in SQLite.
        // Silently ignore if columns already exist.
        migrate(conn, "ALTER TABLE channel_messages ADD COLUMN signature TEXT;");
        migrate(conn, "ALTER TABLE channel_messages ADD COLUMN public_key TEXT;");
        migrate(conn, "ALTER TABLE messages ADD COLUMN signature TEXT;");
        migrate(conn, "ALTER TABLE messages ADD COLUMN public_key TEXT;");

        // -- Migration: DM deduplication unique index --
        // Allows INSERT OR IGNORE for DM sync (like channel_messages).
        //
        // The index is PARTIAL (message_id IS NULL): the original full-table
        // content index treated two DISTINCT rapid messages with identical
        // text in the same millisecond as one duplicate — INSERT OR IGNORE
        // silently dropped the second AND its MessageReceived event, so fast
        // identical-text spam lost messages. Rows carrying a message_id dedup
        // by dm_message_exists() at every insert site instead; the content
        // index survives only as a backstop for legacy rows without one.
        migrate(conn, "DROP INDEX IF EXISTS idx_messages_dedup;");
        migrate(conn,
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_dedup_legacy
             ON messages (peer_id, timestamp, text, is_mine)
             WHERE message_id IS NULL;");

        // -- User profiles (Phase 3.5) --
        ddl(conn, "user_profiles table",
            "CREATE TABLE IF NOT EXISTS user_profiles (
                peer_id      TEXT PRIMARY KEY,
                display_name TEXT NOT NULL DEFAULT '',
                status       TEXT NOT NULL DEFAULT '',
                about_me     TEXT NOT NULL DEFAULT '',
                updated_at   INTEGER NOT NULL DEFAULT 0
            )")?;

        // Phase 3.5 block — editing, deletion/hiding, reactions, friends,
        // settings, emotes, MLS identity, file sharing. ORDERED mixed list:
        // an EMPTY label marks a swallowed idempotent migration (own batch,
        // "already exists" ignored — the migrate() contract); a non-empty
        // label is fail-fast DDL. One loop instead of a periodic call run
        // (Sonar CPD self-matches periodic token streams).
        const PHASE35_SCHEMA: &[(&str, &str)] = &[
            // message_id + edited_at columns (Phase 3.5 editing), then the
            // message_id indexes for fast edit lookups.
            ("", "ALTER TABLE messages ADD COLUMN message_id TEXT;"),
            ("", "ALTER TABLE messages ADD COLUMN edited_at INTEGER;"),
            ("", "ALTER TABLE channel_messages ADD COLUMN message_id TEXT;"),
            ("", "ALTER TABLE channel_messages ADD COLUMN edited_at INTEGER;"),
            ("", "CREATE INDEX IF NOT EXISTS idx_messages_msg_id ON messages (message_id);"),
            ("", "CREATE INDEX IF NOT EXISTS idx_channel_msgs_msg_id ON channel_messages (message_id);"),
            // Edit history table — preserves previous text for Rat Files
            // evidence — plus prev_* columns for edit chain provenance.
            ("message_edits table",
             "CREATE TABLE IF NOT EXISTS message_edits (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                message_id  TEXT    NOT NULL,
                old_text    TEXT    NOT NULL,
                new_text    TEXT    NOT NULL,
                edited_at   INTEGER NOT NULL,
                signature   TEXT,
                public_key  TEXT
            )"),
            ("message_edits index",
             "CREATE INDEX IF NOT EXISTS idx_edits_msg_id ON message_edits (message_id)"),
            ("", "ALTER TABLE message_edits ADD COLUMN prev_signature TEXT;"),
            ("", "ALTER TABLE message_edits ADD COLUMN prev_public_key TEXT;"),
            ("", "ALTER TABLE message_edits ADD COLUMN prev_timestamp INTEGER;"),
            // hidden_at column for message deletion/hiding (Phase 3.5) +
            // deletion evidence table (text at deletion time, Rat Files).
            ("", "ALTER TABLE messages ADD COLUMN hidden_at INTEGER;"),
            ("", "ALTER TABLE channel_messages ADD COLUMN hidden_at INTEGER;"),
            ("message_deletions table",
             "CREATE TABLE IF NOT EXISTS message_deletions (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                message_id  TEXT    NOT NULL,
                deleted_text TEXT   NOT NULL,
                deleted_at  INTEGER NOT NULL,
                signature   TEXT,
                public_key  TEXT
            )"),
            ("message_deletions index",
             "CREATE INDEX IF NOT EXISTS idx_deletions_msg_id ON message_deletions (message_id)"),
            // reply_to_mid column for reply chains (Phase 3.5).
            ("", "ALTER TABLE messages ADD COLUMN reply_to_mid TEXT;"),
            ("", "ALTER TABLE channel_messages ADD COLUMN reply_to_mid TEXT;"),
            // Emoji reactions + removal history (Rat Files evidence).
            ("message_reactions table",
             "CREATE TABLE IF NOT EXISTS message_reactions (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                message_id TEXT    NOT NULL,
                emoji      TEXT    NOT NULL,
                peer_id    TEXT    NOT NULL,
                added_at   INTEGER NOT NULL,
                signature  TEXT,
                public_key TEXT,
                UNIQUE(message_id, emoji, peer_id)
            )"),
            ("reactions index",
             "CREATE INDEX IF NOT EXISTS idx_reactions_msg_id ON message_reactions (message_id)"),
            ("reaction_removals table",
             "CREATE TABLE IF NOT EXISTS reaction_removals (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                message_id TEXT    NOT NULL,
                emoji      TEXT    NOT NULL,
                peer_id    TEXT    NOT NULL,
                removed_at INTEGER NOT NULL,
                signature  TEXT,
                public_key TEXT
            )"),
            // Friends + app settings (key-value, general purpose).
            ("friends table",
             "CREATE TABLE IF NOT EXISTS friends (
                peer_id      TEXT PRIMARY KEY,
                status       TEXT NOT NULL,
                direction    TEXT NOT NULL DEFAULT '',
                requested_at INTEGER NOT NULL DEFAULT 0,
                updated_at   INTEGER NOT NULL DEFAULT 0
            )"),
            ("app_settings table",
             "CREATE TABLE IF NOT EXISTS app_settings (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )"),
            // Blocked peers (local block list, MASTER-keyed).
            ("blocked_peers table",
             "CREATE TABLE IF NOT EXISTS blocked_peers (
                peer_id    TEXT PRIMARY KEY,
                blocked_at INTEGER NOT NULL DEFAULT 0
            )"),
            // Custom emotes: content-addressed blob cache (shared across
            // servers/DMs — the same hash is stored once) + the user's own
            // personal emote set (names are local; hashes are global).
            ("emote_blobs table",
             "CREATE TABLE IF NOT EXISTS emote_blobs (
                hash     TEXT PRIMARY KEY,
                bytes    BLOB NOT NULL,
                animated INTEGER NOT NULL DEFAULT 0,
                added_at INTEGER NOT NULL DEFAULT 0
            )"),
            ("personal_emotes table",
             "CREATE TABLE IF NOT EXISTS personal_emotes (
                name     TEXT PRIMARY KEY,
                hash     TEXT NOT NULL,
                animated INTEGER NOT NULL DEFAULT 0,
                source   TEXT NOT NULL DEFAULT '',
                added_at INTEGER NOT NULL DEFAULT 0
            )"),
            // The user's own sticker vault, grouped into named packs. Keyed
            // by (pack, hash) rather than by name the way emotes are: an
            // emote is TYPED as `:name:` so its name has to be unique, while
            // a sticker is only ever picked visually — the name is a label,
            // and adding the same image to a pack twice is a no-op instead of
            // an error. Bytes live in emote_blobs under kind='sticker'.
            ("personal_stickers table",
             "CREATE TABLE IF NOT EXISTS personal_stickers (
                pack     TEXT NOT NULL DEFAULT '',
                hash     TEXT NOT NULL,
                name     TEXT NOT NULL DEFAULT '',
                animated INTEGER NOT NULL DEFAULT 0,
                w        INTEGER NOT NULL DEFAULT 0,
                h        INTEGER NOT NULL DEFAULT 0,
                source   TEXT NOT NULL DEFAULT '',
                added_at INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (pack, hash)
            )"),
            // MLS identity (singleton row, id=1).
            ("mls_identity table",
             "CREATE TABLE IF NOT EXISTS mls_identity (
                id              INTEGER PRIMARY KEY CHECK (id = 1),
                signer_data     BLOB NOT NULL,
                credential_data BLOB NOT NULL,
                storage_data    BLOB
            )"),
            // File sharing (Phase 3.5).
            ("files table",
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
            )"),
            ("files message_id index",
             "CREATE INDEX IF NOT EXISTS idx_files_message ON files (message_id)"),
            ("files context index",
             "CREATE INDEX IF NOT EXISTS idx_files_context ON files (context_type, context_id)"),
        ];
        for (what, sql) in PHASE35_SCHEMA {
            if what.is_empty() {
                migrate(conn, sql);
            } else {
                ddl(conn, what, sql)?;
            }
        }

        // -- Migration: video_thumb_json column (Phase 6.75 video preview).
        // Stores a JSON-encoded VideoThumbRef when this file is a thumbnail
        // for a vault-stored video.
        migrate(conn, "ALTER TABLE files ADD COLUMN video_thumb_json TEXT;");

        // Timestamp when the file was expired by the retention timer.
        // NULL = not expired. Non-null = file data deleted from disk, row kept as placeholder.
        migrate(conn, "ALTER TABLE files ADD COLUMN expired_at INTEGER;");

        // -- Migration: persisted ShareRef for share-backed (>34 MB) files --
        // (issue #41). The share root hash + AES key used to arrive only inside
        // the live FileHeader and were kept in RAM, so a manual download after
        // an app restart (or with auto-download off) had no way back into the
        // share swarm — the fallback FileRequest path re-serves the bytes with
        // share_ref: None and the requester's own 34 MB cap rejects them.
        migrate(conn, "ALTER TABLE files ADD COLUMN share_ref_json TEXT;");

        // -- Migration: tiny base64 WebP placeholder thumbnail riding the
        // FileHeader (issue #41 carry-over) — rendered blurred under the
        // Download button while the real bytes are gated/undownloaded.
        migrate(conn, "ALTER TABLE files ADD COLUMN thumb_b64 TEXT;");

        ddl(conn, "file_chunks table",
            "CREATE TABLE IF NOT EXISTS file_chunks (
                file_id     TEXT    NOT NULL,
                chunk_index INTEGER NOT NULL,
                received_at INTEGER NOT NULL,
                PRIMARY KEY (file_id, chunk_index)
            )")?;

        // -- Migration: file_id column on messages --
        migrate(conn, "ALTER TABLE messages ADD COLUMN file_id TEXT;");
        migrate(conn, "ALTER TABLE channel_messages ADD COLUMN file_id TEXT;");

        // -- Migration: link_preview_json column (Phase 6.75 link previews).
        // Stores a JSON-encoded LinkPreviewRef for messages that previewed a URL.
        // Populated by update_link_preview / update_channel_link_preview after
        // the message row is inserted.
        migrate(conn, "ALTER TABLE messages ADD COLUMN link_preview_json TEXT;");
        migrate(conn, "ALTER TABLE channel_messages ADD COLUMN link_preview_json TEXT;");

        // -- Migration: order_us — microsecond send timestamp for stable ordering --
        // (Step 9C/C4). The display ORDER BY uses this BEFORE sender_id, so a
        // sender's same-millisecond burst stays grouped + in true send order instead
        // of being alternated by the sender_id tiebreaker (the multi-device-backfill
        // "ping-pong" bug). Set by the SENDER (microsecond wall clock), carried over
        // the wire untouched, and NULL for legacy rows / pre-9C peers — those fall
        // back to the old (timestamp, sender_id, id) order.
        migrate(conn, "ALTER TABLE messages ADD COLUMN order_us INTEGER;");
        migrate(conn, "ALTER TABLE channel_messages ADD COLUMN order_us INTEGER;");

        // -- Migration: updated_at column for edit/delete sync (H12+H13 QA fix) --
        // Tracks when a message was last modified (edit or delete) so sync queries
        // can catch edits/deletes to old messages that would otherwise be missed.
        migrate(conn, "ALTER TABLE messages ADD COLUMN updated_at INTEGER;");
        migrate(conn, "ALTER TABLE channel_messages ADD COLUMN updated_at INTEGER;");
        ddl(conn, "idx_messages_peer_updated",
            "CREATE INDEX IF NOT EXISTS idx_messages_peer_updated ON messages (peer_id, updated_at)")?;
        ddl(conn, "idx_channel_msgs_updated",
            "CREATE INDEX IF NOT EXISTS idx_channel_msgs_updated ON channel_messages (server_id, channel_id, updated_at)")?;

        // -- Migration: avatar/banner BLOB columns on user_profiles --
        migrate(conn, "ALTER TABLE user_profiles ADD COLUMN avatar BLOB;");
        migrate(conn, "ALTER TABLE user_profiles ADD COLUMN banner BLOB;");
        migrate(conn, "ALTER TABLE user_profiles ADD COLUMN twitch_username TEXT NOT NULL DEFAULT '';");
        migrate(conn, "ALTER TABLE user_profiles ADD COLUMN showcase_board TEXT NOT NULL DEFAULT '';");
        migrate(conn, "ALTER TABLE user_profiles ADD COLUMN showcase_assets BLOB;");
        // -- 0.8.5: the subject's own signature over the relayable profile
        // subset, so `ProfileRelay` can be authenticated rather than trusted.
        migrate(conn, "ALTER TABLE user_profiles ADD COLUMN profile_sig TEXT;");
        migrate(conn, "ALTER TABLE user_profiles ADD COLUMN profile_pk TEXT;");
        migrate(conn, "ALTER TABLE user_profiles ADD COLUMN profile_avatar_hash TEXT;");
        // -- issue #54: avatar frame ID. "" = none, "b:<hue>" = built-in,
        // 64-hex = an asset-rail blob hash. Never the bytes.
        migrate(conn, "ALTER TABLE user_profiles ADD COLUMN avatar_frame TEXT NOT NULL DEFAULT '';");

        // -- Migration: content_id column on files (vault ↔ file_id link) --
        migrate(conn, "ALTER TABLE files ADD COLUMN content_id TEXT;");

        // -- Migration: asset rail — emote_blobs generalizes to all content-
        // addressed asset kinds ('emote' | 'banner' | 'sticker' | 'gif').
        // The kind is LOCAL bookkeeping (per-kind size caps + eviction
        // grouping); it never rides the wire.
        migrate(conn, "ALTER TABLE emote_blobs ADD COLUMN kind TEXT NOT NULL DEFAULT 'emote';");

        // -- Verified peers (RAT Files — peer identity verification) --
        ddl(conn, "verified_peers table",
            "CREATE TABLE IF NOT EXISTS verified_peers (
                peer_id     TEXT PRIMARY KEY,
                verified_at INTEGER NOT NULL
            )")?;

        // -- Security alerts (Issue 1-C: visible key/device change warnings) --
        // One row per NOTEWORTHY identity event for a contact. `alert_id` is
        // deterministic ("{kind}:{peer}:{detail}") so re-ingesting the same
        // device list — which happens on every reconnect — can never pile up
        // duplicates of a fact the user has already seen.
        // `peer_id` is always the MASTER id: alerts are about a PERSON.
        ddl(conn, "security_alerts table",
            "CREATE TABLE IF NOT EXISTS security_alerts (
                alert_id        TEXT PRIMARY KEY,
                peer_id         TEXT NOT NULL,
                kind            TEXT NOT NULL,
                detail          TEXT NOT NULL DEFAULT '',
                created_at      INTEGER NOT NULL,
                acknowledged_at INTEGER
            )")?;
        ddl(conn, "idx_security_alerts_peer",
            "CREATE INDEX IF NOT EXISTS idx_security_alerts_peer
                ON security_alerts (peer_id, acknowledged_at)")?;

        // -- Olm identity-key pins (Issue 1-C, TOFU) --
        // The Curve25519 identity key we first saw for a DEVICE. Keyed by DEVICE
        // (not master) because the Olm ratchet is per-device: each device of one
        // identity legitimately has its own key, and only a CHANGE within one
        // device id means a reinstall/re-key.
        ddl(conn, "olm_key_pins table",
            "CREATE TABLE IF NOT EXISTS olm_key_pins (
                device_peer_id TEXT PRIMARY KEY,
                identity_key   TEXT NOT NULL,
                pinned_at      INTEGER NOT NULL
            )")?;

        // -- Hollow Share (Phase 7A) --
        // One row per share we've created, opened, or downloaded. The encryption_key
        // is the AES-256-GCM key from the share link; if the user loses the link
        // and the row is gone, the file is unrecoverable (which is the point).
        ddl(conn, "shares table",
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
            )")?;
        // Idempotent migrations for existing dbs.
        migrate(conn, "ALTER TABLE shares ADD COLUMN save_dir TEXT;");
        migrate(conn, "ALTER TABLE shares ADD COLUMN server_id TEXT;");
        migrate(conn, "ALTER TABLE shares ADD COLUMN context_type TEXT;");
        ddl(conn, "idx_shares_state",
            "CREATE INDEX IF NOT EXISTS idx_shares_state ON shares(state)")?;
        ddl(conn, "idx_shares_seeding",
            "CREATE INDEX IF NOT EXISTS idx_shares_seeding ON shares(seeding)")?;

        // -- Server blobs (CrdtStore: large settings like server_avatar) --
        ddl(conn, "server_blobs table",
            "CREATE TABLE IF NOT EXISTS server_blobs (
                server_id TEXT NOT NULL,
                key       TEXT NOT NULL,
                value     TEXT NOT NULL,
                PRIMARY KEY (server_id, key)
            )")?;

        // Have-bitmap per share, persisted so paused/restarted downloads resume
        // without re-fetching. bitmap_blob is little-endian-packed bits.
        ddl(conn, "share_chunks table",
            "CREATE TABLE IF NOT EXISTS share_chunks (
                root_hash    TEXT PRIMARY KEY,
                bitmap_blob  BLOB NOT NULL,
                updated_at   INTEGER NOT NULL
            )")?;

        // -- Conference rooms (host-local; reports/CONFERENCES_PLAN.md) --
        // Durable "my meeting room" objects. access_code_hash is the
        // conf-scoped sha256 derivation, never the plaintext code. co_hosts
        // is a JSON array of master ids (enforced at ingest, phase 2).
        ddl(conn, "conferences table",
            "CREATE TABLE IF NOT EXISTS conferences (
                conf_id          TEXT PRIMARY KEY,
                name             TEXT NOT NULL,
                waiting_room     INTEGER NOT NULL DEFAULT 1,
                access_code_hash TEXT,
                co_hosts         TEXT NOT NULL DEFAULT '[]',
                broadcast_mode   INTEGER NOT NULL DEFAULT 0,
                created_at       INTEGER NOT NULL
            )")?;

        // -- FTS5 full-text search indexes (L4 QA fix) --
        // Content-sync FTS: the FTS table reads from the main table on demand,
        // triggers keep the index in sync on INSERT/DELETE/UPDATE.
        conn.execute_batch(
            "CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
                text, content='messages', content_rowid='id'
            );
            CREATE TRIGGER IF NOT EXISTS messages_fts_ai AFTER INSERT ON messages BEGIN
                INSERT INTO messages_fts(rowid, text) VALUES (new.id, new.text);
            END;
            CREATE TRIGGER IF NOT EXISTS messages_fts_ad AFTER DELETE ON messages BEGIN
                INSERT INTO messages_fts(messages_fts, rowid, text) VALUES('delete', old.id, old.text);
            END;
            CREATE TRIGGER IF NOT EXISTS messages_fts_au AFTER UPDATE ON messages BEGIN
                INSERT INTO messages_fts(messages_fts, rowid, text) VALUES('delete', old.id, old.text);
                INSERT INTO messages_fts(rowid, text) VALUES (new.id, new.text);
            END;

            CREATE VIRTUAL TABLE IF NOT EXISTS channel_messages_fts USING fts5(
                text, content='channel_messages', content_rowid='id'
            );
            CREATE TRIGGER IF NOT EXISTS channel_messages_fts_ai AFTER INSERT ON channel_messages BEGIN
                INSERT INTO channel_messages_fts(rowid, text) VALUES (new.id, new.text);
            END;
            CREATE TRIGGER IF NOT EXISTS channel_messages_fts_ad AFTER DELETE ON channel_messages BEGIN
                INSERT INTO channel_messages_fts(channel_messages_fts, rowid, text) VALUES('delete', old.id, old.text);
            END;
            CREATE TRIGGER IF NOT EXISTS channel_messages_fts_au AFTER UPDATE ON channel_messages BEGIN
                INSERT INTO channel_messages_fts(channel_messages_fts, rowid, text) VALUES('delete', old.id, old.text);
                INSERT INTO channel_messages_fts(rowid, text) VALUES (new.id, new.text);
            END;"
        ).unwrap_or_else(|e| {
            eprintln!("[HOLLOW] FTS5 setup failed (non-fatal): {e}");
        });

        // One-time FTS backfill for databases that existed before FTS was added.
        let fts_done: bool = conn
            .query_row(
                "SELECT 1 FROM app_settings WHERE key = 'fts_backfilled'",
                [],
                |_| Ok(true),
            )
            .unwrap_or(false);
        if !fts_done {
            conn.execute_batch(
                "INSERT OR IGNORE INTO messages_fts(messages_fts) VALUES('rebuild');
                 INSERT OR IGNORE INTO channel_messages_fts(channel_messages_fts) VALUES('rebuild');"
            ).unwrap_or_else(|e| {
                eprintln!("[HOLLOW] FTS5 rebuild failed (non-fatal): {e}");
            });
            let _ = conn.execute(
                "INSERT OR REPLACE INTO app_settings (key, value) VALUES ('fts_backfilled', '1')",
                [],
            );
        }

        // -- Multi-device: signed device lists (Phase 6) --
        // One row per master identity holding its full signed device list JSON +
        // monotonic version (replay protection). `device_links` is the fast
        // reverse index used by the device→master resolver.
        ddl(conn, "device_lists table",
            "CREATE TABLE IF NOT EXISTS device_lists (
                master_peer_id TEXT PRIMARY KEY,
                json           TEXT    NOT NULL,
                version        INTEGER NOT NULL DEFAULT 0,
                updated_at     INTEGER NOT NULL DEFAULT 0
            )")?;

        ddl(conn, "device_links table",
            "CREATE TABLE IF NOT EXISTS device_links (
                device_peer_id TEXT PRIMARY KEY,
                master_peer_id TEXT NOT NULL
            )")?;

        ddl(conn, "device_links index",
            "CREATE INDEX IF NOT EXISTS idx_device_links_master ON device_links (master_peer_id)")?;

        // Local-only, unsigned human labels for devices (Step 8 Devices panel). NOT
        // synced or master-signed — each device names its own view of the device set.
        ddl(conn, "device_labels table",
            "CREATE TABLE IF NOT EXISTS device_labels (
                device_peer_id TEXT PRIMARY KEY,
                label          TEXT NOT NULL DEFAULT ''
            )")?;

        Ok(())
    }

    /// One-time storage hygiene, run ONCE at node startup while the DB is held by
    /// a SINGLE connection — before the CryptoStore/CrdtStore actors and any
    /// transient `open()` calls exist. Converts a legacy database created with
    /// `auto_vacuum=0` to INCREMENTAL (which requires a full `VACUUM` — an
    /// exclusive-lock, whole-file rewrite) and does one incremental reclaim.
    ///
    /// MUST run in a single-connection window: the `VACUUM` takes an exclusive
    /// lock and the page-1 `auto_vacuum` read races any other connection's
    /// SQLCipher codec, producing spurious `hmac check failed for pgno=1` noise.
    /// Idempotent — once converted the DB reads `auto_vacuum=INCREMENTAL` and the
    /// `VACUUM` never runs again. A missing/locked DB is a non-fatal skip (caller
    /// logs); correctness never depends on it (incremental vacuum is pure disk
    /// hygiene, not data integrity).
    pub fn migrate_auto_vacuum_once(path: &str, passphrase: &str) -> Result<(), String> {
        let conn = Connection::open(path)
            .map_err(|e| format!("Failed to open database for migration: {e}"))?;
        conn.execute_batch(&format!("PRAGMA key = \"x'{}'\";", passphrase))
            .map_err(|e| format!("Failed to set encryption key: {e}"))?;

        let auto_vac: i32 = conn
            .query_row("PRAGMA auto_vacuum;", [], |r| r.get(0))
            .unwrap_or(0);
        if auto_vac == 0 {
            conn.execute_batch("PRAGMA auto_vacuum = INCREMENTAL; VACUUM;")
                .map_err(|e| format!("auto_vacuum migration failed: {e}"))?;
        }
        let _ = conn.execute_batch("PRAGMA incremental_vacuum(100);");
        Ok(())
    }

    pub fn wal_checkpoint(&self) -> Result<(), String> {
        self.conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")
            .map_err(|e| format!("WAL checkpoint failed: {e}"))
    }

    pub fn begin_transaction(&self) -> Result<(), String> {
        self.conn.execute_batch("BEGIN IMMEDIATE")
            .map_err(|e| format!("BEGIN failed: {e}"))
    }

    pub fn commit_transaction(&self) -> Result<(), String> {
        self.conn.execute_batch("COMMIT")
            .map_err(|e| format!("COMMIT failed: {e}"))
    }

    /// Reconcile a synced/edited DM against an existing local row that shares the
    /// same (peer_id, timestamp, is_mine=0) but has a NULL or different
    /// message_id. This happens when the original message was delivered via one
    /// path (e.g. offline fetch) and its edit arrives via another (DM sync) — the
    /// mid-based dedup misses, and a naive insert creates a duplicate row.
    ///
    /// If such a row is found, it adopts the canonical `message_id` and applies
    /// the new text/edited_at in place. Returns true if a row was reconciled (so
    /// the caller must NOT insert a new row).
    pub fn reconcile_dm_by_timestamp(
        &self,
        peer_id: &str,
        message_id: &str,
        new_text: &str,
        timestamp: i64,
        edited_at: Option<i64>,
        signature: Option<&str>,
        public_key: Option<&str>,
    ) -> Result<bool, String> {
        // Find a candidate row: same peer + timestamp, received (is_mine=0),
        // whose message_id is NULL or different from the canonical one.
        //
        // A different-mid row only qualifies when its TEXT differs (the
        // edit-delivered-via-another-path case). A different-mid row with
        // IDENTICAL text is a DISTINCT message from a same-millisecond
        // identical-text burst — grafting the incoming mid onto it silently
        // merged two real messages into one row (permanent loss: every later
        // sync then saw the mid as "existing" and never re-inserted it).
        let existing_id: Option<i64> = self
            .conn
            .query_row(
                "SELECT id FROM messages
                 WHERE peer_id = ?1 AND timestamp = ?2 AND is_mine = 0
                   AND (message_id IS NULL
                        OR (message_id != ?3 AND text != ?4))
                 LIMIT 1",
                params![peer_id, timestamp, message_id, new_text],
                |row| row.get(0),
            )
            .ok();

        let Some(row_id) = existing_id else {
            return Ok(false);
        };

        // Adopt the canonical message_id, update text + edit metadata in place.
        let edit_ts = edited_at.unwrap_or(timestamp);
        self.conn
            .execute(
                "UPDATE messages
                 SET message_id = ?1, text = ?2, edited_at = ?3,
                     signature = COALESCE(?4, signature),
                     public_key = COALESCE(?5, public_key),
                     updated_at = ?3
                 WHERE id = ?6",
                params![message_id, new_text, edit_ts, signature, public_key, row_id],
            )
            .map_err(|e| format!("Failed to reconcile DM row: {e}"))?;
        Ok(true)
    }

    /// Check if a DM message with the given message_id exists.
    pub fn dm_message_exists(&self, message_id: &str) -> bool {
        self.conn
            .query_row(
                "SELECT 1 FROM messages WHERE message_id = ?1 LIMIT 1",
                params![message_id],
                |_| Ok(()),
            )
            .is_ok()
    }

    /// Check if a channel message with the given message_id exists.
    pub fn channel_message_exists(&self, message_id: &str) -> bool {
        self.conn
            .query_row(
                "SELECT 1 FROM channel_messages WHERE message_id = ?1 LIMIT 1",
                params![message_id],
                |_| Ok(()),
            )
            .is_ok()
    }

    /// Insert a message. Returns the row ID.
    ///
    /// `order_us` is the SENDER's microsecond send timestamp for stable ordering
    /// (Step 9C/C4); pass `None` at receive/backfill sites that don't carry it —
    /// it defaults to `timestamp * 1000`, which orders identically to the legacy
    /// millisecond `timestamp` so old peers / pre-9C rows are unaffected.
    #[allow(clippy::too_many_arguments)]
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
        order_us: Option<i64>,
    ) -> Result<i64, String> {
        let order_us = order_us.unwrap_or(timestamp.saturating_mul(1000));
        // Lamport chat clock: every persisted stamp (live, backfill, push
        // fetch, our own echo) advances the send clock so our NEXT send stamps
        // after everything we've seen — cross-machine clock skew can no longer
        // sort a reply above the message it answers (see chat_clock.rs).
        crate::chat_clock::observe(order_us.max(timestamp.saturating_mul(1000)));
        let rows = self.conn
            .execute(
                "INSERT OR IGNORE INTO messages (peer_id, text, is_mine, timestamp, signature, public_key, message_id, reply_to_mid, file_id, order_us) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                params![peer_id, text, is_mine as i32, timestamp, signature, public_key, message_id, reply_to_mid, file_id, order_us],
            )
            .map_err(|e| format!("Failed to insert message: {e}"))?;
        if rows > 0 {
            Ok(self.conn.last_insert_rowid())
        } else {
            Ok(0) // Duplicate — ignored.
        }
    }

    /// Overwrite a DM row's text + signature with the caption's ONLY when the
    /// current text is a "[file:...]" sentinel (a captionless-image placeholder).
    /// Used by the push fetch node: an offline captioned image arrives as TWO
    /// frames sharing one message_id — the inlined FileHeader (text "[file:<id>]",
    /// no signature) and the caption DM (carries the real sig/pk over the caption
    /// text). Whichever inserts first wins the INSERT OR IGNORE; if the FileHeader
    /// won, this promotes the row to the real caption AND its signature when the
    /// caption arrives — otherwise the message would render "Unsigned" because the
    /// FileHeader carried no sig. No-op if no row matches or the row already has
    /// real (non-sentinel) text.
    pub fn promote_file_sentinel_to_caption(
        &self,
        message_id: &str,
        text: &str,
        signature: Option<&str>,
        public_key: Option<&str>,
    ) -> Result<bool, String> {
        let rows = self.conn
            .execute(
                "UPDATE messages SET text = ?1, signature = ?2, public_key = ?3 \
                 WHERE message_id = ?4 AND text LIKE '[file:%]'",
                params![text, signature, public_key, message_id],
            )
            .map_err(|e| format!("promote_file_sentinel_to_caption: {e}"))?;
        Ok(rows > 0)
    }

    /// Set the link preview JSON for a DM row identified by `message_id`.
    /// No-op if no row matches. Phase 6.75.
    pub fn update_link_preview(&self, message_id: &str, link_preview_json: &str) -> Result<(), String> {
        self.update_link_preview_in("messages", message_id, link_preview_json)
    }

    /// Set the link preview JSON for a channel message row identified by `message_id`.
    /// No-op if no row matches. Phase 6.75.
    pub fn update_channel_link_preview(&self, message_id: &str, link_preview_json: &str) -> Result<(), String> {
        self.update_link_preview_in("channel_messages", message_id, link_preview_json)
    }

    /// Shared link-preview setter. `table` is a fixed table name, never user input.
    fn update_link_preview_in(&self, table: &str, message_id: &str, link_preview_json: &str) -> Result<(), String> {
        self.conn
            .execute(
                &format!("UPDATE {table} SET link_preview_json = ?1 WHERE message_id = ?2"),
                params![link_preview_json, message_id],
            )
            .map_err(|e| format!("Failed to update {table} link preview: {e}"))?;
        Ok(())
    }

    /// Set (or clear) a DM row's link preview AND its signature together.
    /// Issue #45 — see [`Self::update_link_preview_and_sig_in`].
    pub fn update_link_preview_and_sig(
        &self,
        message_id: &str,
        link_preview_json: Option<&str>,
        signature: Option<&str>,
        public_key: Option<&str>,
    ) -> Result<bool, String> {
        self.update_link_preview_and_sig_in(
            "messages", message_id, link_preview_json, signature, public_key,
        )
    }

    /// Channel twin of [`Self::update_link_preview_and_sig`]. Issue #45.
    pub fn update_channel_link_preview_and_sig(
        &self,
        message_id: &str,
        link_preview_json: Option<&str>,
        signature: Option<&str>,
        public_key: Option<&str>,
    ) -> Result<bool, String> {
        self.update_link_preview_and_sig_in(
            "channel_messages", message_id, link_preview_json, signature, public_key,
        )
    }

    /// Attach (or clear) a card and swap in the re-signature that covers it,
    /// in ONE statement. Returns whether a row matched.
    ///
    /// The pair is inseparable: the v2 signature binds `lp_digest`, so a row
    /// whose preview changed without its signature following would stop
    /// verifying and stop replicating through signed sync backfill. Writing
    /// them apart would leave that inconsistency visible to any concurrent
    /// reader.
    ///
    /// Deliberately does NOT touch `text`, `edited_at`, or `message_edits`:
    /// attaching a late card is not an edit, and the bubble must not sprout
    /// an "(edited)" badge because a fetch finished a second after send.
    /// `table` is a fixed table name, never user input.
    fn update_link_preview_and_sig_in(
        &self,
        table: &str,
        message_id: &str,
        link_preview_json: Option<&str>,
        signature: Option<&str>,
        public_key: Option<&str>,
    ) -> Result<bool, String> {
        let rows = self.conn
            .execute(
                &format!(
                    "UPDATE {table} SET link_preview_json = ?1, signature = ?2, \
                     public_key = ?3 WHERE message_id = ?4"
                ),
                params![link_preview_json, signature, public_key, message_id],
            )
            .map_err(|e| format!("Failed to update {table} link preview + sig: {e}"))?;
        Ok(rows > 0)
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
            .prepare_cached("SELECT pickle FROM olm_account WHERE id = 1")
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
            .prepare_cached("SELECT pickle FROM olm_sessions WHERE peer_id = ?1")
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

    /// Delete a persisted Olm session (Step 7 device revocation — so a revoked
    /// device's session is not resurrected from the DB on restart). Idempotent.
    pub fn delete_olm_session(&self, peer_id: &str) -> Result<(), String> {
        self.conn
            .execute("DELETE FROM olm_sessions WHERE peer_id = ?1", params![peer_id])
            .map_err(|e| format!("Failed to delete olm session: {e}"))?;
        Ok(())
    }

    /// Load all Olm session pickles (peer_id, pickle_json) pairs.
    pub fn load_all_olm_sessions(&self) -> Result<Vec<(String, String)>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT peer_id, pickle FROM olm_sessions")
            .map_err(|e| format!("Failed to prepare olm_sessions query: {e}"))?;
        let rows = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .map_err(|e| format!("Failed to query olm_sessions: {e}"))?;
        collect_rows(rows, "olm_sessions")
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
            .prepare(&format!(
                "SELECT {DM_MSG_COLS}
                 FROM messages
                 WHERE peer_id = ?1 AND hidden_at IS NULL
                 ORDER BY timestamp DESC, COALESCE(order_us, timestamp * 1000) DESC, id DESC
                 LIMIT ?2",
            ))
            .map_err(|e| format!("Failed to prepare query: {e}"))?;

        let rows = stmt
            .query_map(params![peer_id, limit], dm_message_from_row)
            .map_err(|e| format!("Failed to query messages: {e}"))?;

        let mut messages = collect_rows(rows, "messages")?;
        messages.reverse(); // Oldest first for display.
        Ok(messages)
    }

    /// Single-value `MAX(timestamp)`-style query; no row or NULL → Ok(None).
    fn query_opt_ts(
        &self,
        sql: &str,
        params: &[&dyn rusqlite::types::ToSql],
        what: &str,
    ) -> Result<Option<i64>, String> {
        let mut stmt = self
            .conn
            .prepare(sql)
            .map_err(|e| format!("Failed to prepare {what} query: {e}"))?;
        let mut rows = stmt
            .query_map(params, |row| row.get::<_, Option<i64>>(0))
            .map_err(|e| format!("Failed to query {what}: {e}"))?;
        match rows.next() {
            Some(Ok(ts)) => Ok(ts),
            Some(Err(e)) => Err(format!("Failed to read {what}: {e}")),
            None => Ok(None),
        }
    }

    /// Get the latest DM timestamp for a peer (for DM sync requests).
    /// Only considers received messages (is_mine=0) since sync only sends
    /// the other peer's sent messages (their is_mine=1 = our is_mine=0).
    pub fn get_latest_dm_timestamp(
        &self,
        peer_id: &str,
    ) -> Result<Option<i64>, String> {
        self.query_opt_ts(
            "SELECT MAX(timestamp) FROM messages WHERE peer_id = ?1 AND is_mine = 0",
            &[&peer_id],
            "dm latest timestamp",
        )
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
        self.query_dm_messages(
            &format!(
                "SELECT {DM_MSG_COLS}
                 FROM messages
                 WHERE peer_id = ?1 AND is_mine = 1 AND (timestamp >= ?2 OR updated_at >= ?2)
                 ORDER BY timestamp ASC, COALESCE(order_us, timestamp * 1000) ASC
                 LIMIT ?3",
            ),
            &[&peer_id, &since_timestamp, &limit],
            "dm_messages_since",
        )
    }

    /// Run any DM-message query selecting [`DM_MSG_COLS`] and collect the rows.
    fn query_dm_messages(
        &self,
        sql: &str,
        params: &[&dyn rusqlite::types::ToSql],
        what: &str,
    ) -> Result<Vec<StoredMessage>, String> {
        let mut stmt = self
            .conn
            .prepare(sql)
            .map_err(|e| format!("Failed to prepare {what} query: {e}"))?;
        let rows = stmt
            .query_map(params, dm_message_from_row)
            .map_err(|e| format!("Failed to query {what}: {e}"))?;
        collect_rows(rows, what)
    }

    /// Latest DM timestamp in a conversation **regardless of direction** (for
    /// multi-device sibling backfill). The friend-sync `get_latest_dm_timestamp`
    /// filters `is_mine = 0` (a friend only re-serves what THEY sent); a sibling
    /// serves BOTH directions, so the requester's high-water mark must span both
    /// — otherwise we'd re-pull our own already-known sends every reconnect.
    pub fn get_latest_dm_timestamp_any(
        &self,
        peer_id: &str,
    ) -> Result<Option<i64>, String> {
        self.query_opt_ts(
            "SELECT MAX(timestamp) FROM messages WHERE peer_id = ?1",
            &[&peer_id],
            "dm latest-any timestamp",
        )
    }

    /// Get DM messages in a conversation newer than a timestamp, **in BOTH
    /// directions** (for multi-device sibling backfill). Unlike
    /// `get_dm_messages_since` (friend sync: `is_mine = 1` only), a sibling needs
    /// the friend's half of the conversation too. `is_mine` is carried through so
    /// the receiving sibling can render each message on the correct side.
    /// Uses `timestamp > since` (STRICT) for fresh messages so the requester's
    /// high-water-mark message isn't re-sent on every reconnect (the
    /// re-send-the-latest-every-sync waste), but `updated_at >= since`
    /// (inclusive) so an EDIT/REACTION/DELETE stamped on an already-synced
    /// message at/after the high-water still re-syncs it. `INSERT OR IGNORE`
    /// dedup makes any overlap harmless. Includes hidden (deleted) messages —
    /// evidence must sync (Rat Files).
    pub fn get_dm_messages_for_sibling(
        &self,
        peer_id: &str,
        since_timestamp: i64,
        limit: i32,
    ) -> Result<Vec<StoredMessage>, String> {
        self.query_dm_messages(
            &format!(
                "SELECT {DM_MSG_COLS}
                 FROM messages
                 WHERE peer_id = ?1 AND (timestamp > ?2 OR updated_at >= ?2)
                 ORDER BY timestamp ASC, COALESCE(order_us, timestamp * 1000) ASC
                 LIMIT ?3",
            ),
            &[&peer_id, &since_timestamp, &limit],
            "dm_messages_for_sibling",
        )
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
            .prepare_cached("SELECT state_json FROM servers WHERE server_id = ?1")
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
            .prepare_cached("SELECT server_id, state_json FROM servers")
            .map_err(|e| format!("Failed to prepare servers query: {e}"))?;
        let rows = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .map_err(|e| format!("Failed to query servers: {e}"))?;
        collect_rows(rows, "servers")
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

    /// Prune old CRDT ops, keeping the most recent `keep_count` per server.
    pub fn prune_crdt_ops(&self, keep_count: usize) -> Result<usize, String> {
        let deleted = self.conn
            .execute(
                "DELETE FROM crdt_ops WHERE id IN (
                    SELECT id FROM (
                        SELECT id, ROW_NUMBER() OVER (
                            PARTITION BY server_id ORDER BY hlc_ms DESC, hlc_counter DESC
                        ) AS rn FROM crdt_ops
                    ) WHERE rn > ?1
                )",
                params![keep_count as i64],
            )
            .map_err(|e| format!("Failed to prune crdt_ops: {e}"))?;
        Ok(deleted)
    }

    /// Save (upsert) a key-value blob for a server (e.g. server_avatar).
    pub fn save_server_blob(&self, server_id: &str, key: &str, value: &str) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO server_blobs (server_id, key, value) VALUES (?1, ?2, ?3)
                 ON CONFLICT(server_id, key) DO UPDATE SET value = excluded.value",
                params![server_id, key, value],
            )
            .map_err(|e| format!("Failed to save server blob: {e}"))?;
        Ok(())
    }

    /// Load a server blob by key.
    pub fn load_server_blob(&self, server_id: &str, key: &str) -> Result<Option<String>, String> {
        let mut stmt = self.conn
            .prepare_cached("SELECT value FROM server_blobs WHERE server_id = ?1 AND key = ?2")
            .map_err(|e| format!("Failed to prepare server_blobs query: {e}"))?;
        let mut rows = stmt
            .query_map(params![server_id, key], |row| row.get(0))
            .map_err(|e| format!("Failed to query server_blobs: {e}"))?;
        match rows.next() {
            Some(Ok(value)) => Ok(Some(value)),
            Some(Err(e)) => Err(format!("Failed to read server_blobs row: {e}")),
            None => Ok(None),
        }
    }

    /// Delete all blobs for a server.
    pub fn delete_server_blobs(&self, server_id: &str) -> Result<(), String> {
        self.conn
            .execute(
                "DELETE FROM server_blobs WHERE server_id = ?1",
                params![server_id],
            )
            .map_err(|e| format!("Failed to delete server blobs: {e}"))?;
        Ok(())
    }

    /// Load CRDT ops for a server, ordered by HLC — bounded to the NEWEST 1000
    /// (matches ServerState::MAX_OP_LOG). The DB table only prunes on the
    /// 30-min rebalance timer, so an old server could hold far more rows than
    /// the in-memory log would ever keep; loading them all at boot was O(all
    /// history) JSON parsing per server for ops the compactor would discard.
    pub fn load_ops_for_server(&self, server_id: &str) -> Result<Vec<CrdtOp>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT op_json FROM (
                     SELECT op_json, hlc_ms, hlc_counter, author FROM crdt_ops
                     WHERE server_id = ?1
                     ORDER BY hlc_ms DESC, hlc_counter DESC, author DESC LIMIT 1000
                 ) ORDER BY hlc_ms, hlc_counter, author",
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
    ///
    /// `order_us` — see [`Self::insert`]: the sender's microsecond send timestamp for
    /// stable ordering (Step 9C/C4); `None` defaults to `timestamp * 1000` (legacy-equivalent).
    #[allow(clippy::too_many_arguments)]
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
        order_us: Option<i64>,
    ) -> Result<usize, String> {
        let order_us = order_us.unwrap_or(timestamp.saturating_mul(1000));
        // Lamport chat clock — see [`Self::insert`] and chat_clock.rs.
        crate::chat_clock::observe(order_us.max(timestamp.saturating_mul(1000)));
        let rows = self.conn
            .execute(
                "INSERT OR IGNORE INTO channel_messages (server_id, channel_id, sender_id, text, is_mine, timestamp, signature, public_key, message_id, reply_to_mid, file_id, order_us)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
                params![server_id, channel_id, sender_id, text, is_mine as i32, timestamp, signature, public_key, message_id, reply_to_mid, file_id, order_us],
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
            .prepare(&format!(
                "SELECT {CHANNEL_MSG_COLS}
                 FROM channel_messages
                 WHERE server_id = ?1 AND channel_id = ?2 AND hidden_at IS NULL
                 ORDER BY timestamp DESC, COALESCE(order_us, timestamp * 1000) DESC, sender_id DESC, id DESC
                 LIMIT ?3",
            ))
            .map_err(|e| format!("Failed to prepare channel_messages query: {e}"))?;

        let rows = stmt
            .query_map(params![server_id, channel_id, limit], channel_message_from_row)
            .map_err(|e| format!("Failed to query channel_messages: {e}"))?;

        let mut messages = collect_rows(rows, "channel_messages")?;
        messages.reverse(); // Oldest first for display.
        Ok(messages)
    }

    /// Get the most recent message timestamp for a channel (for sync requests).
    pub fn get_latest_channel_timestamp(
        &self,
        server_id: &str,
        channel_id: &str,
    ) -> Result<Option<i64>, String> {
        self.query_opt_ts(
            "SELECT MAX(timestamp) FROM channel_messages
             WHERE server_id = ?1 AND channel_id = ?2",
            &[&server_id, &channel_id],
            "latest timestamp",
        )
    }

    /// Latest timestamp of the LOCAL user's own messages in a channel
    /// (`is_mine = 1`, so it stays correct across the user's linked devices).
    /// Used by the send-side slow-mode gate. Returns None on query failure —
    /// slow mode fails open rather than blocking sends on a DB error.
    pub fn latest_own_channel_ts(&self, server_id: &str, channel_id: &str) -> Option<i64> {
        self.conn
            .query_row(
                "SELECT MAX(timestamp) FROM channel_messages
                 WHERE server_id = ?1 AND channel_id = ?2 AND is_mine = 1",
                params![server_id, channel_id],
                |row| row.get::<_, Option<i64>>(0),
            )
            .ok()
            .flatten()
    }

    /// Highest chat send-stamp (µs) across DMs + channel messages. Seeds the
    /// Lamport chat clock at node start (see chat_clock.rs) so a restart can't
    /// mint stamps below already-stored ones from a peer whose clock runs
    /// ahead of ours — without the seed, our first post-restart reply would
    /// sort above the message it answers until the next inbound bump.
    pub fn max_chat_stamp_us(&self) -> i64 {
        let q = |sql: &str| {
            self.conn
                .query_row(sql, [], |row| row.get::<_, Option<i64>>(0))
                .ok()
                .flatten()
                .unwrap_or(0)
        };
        q("SELECT MAX(COALESCE(order_us, timestamp * 1000)) FROM messages")
            .max(q("SELECT MAX(COALESCE(order_us, timestamp * 1000)) FROM channel_messages"))
    }

    /// Whether `sender_id` already has a channel message in the open interval
    /// (`from_ts`, `to_ts`) (epoch ms). Used by the receive-side slow-mode
    /// gate: a message whose signed timestamp lands within the slow-mode
    /// window of another message from the same sender is dropped.
    pub fn channel_sender_has_msg_in_range(
        &self,
        server_id: &str,
        channel_id: &str,
        sender_id: &str,
        from_ts: i64,
        to_ts: i64,
    ) -> bool {
        self.conn
            .query_row(
                "SELECT EXISTS(
                     SELECT 1 FROM channel_messages
                     WHERE server_id = ?1 AND channel_id = ?2 AND sender_id = ?3
                       AND timestamp > ?4 AND timestamp < ?5
                 )",
                params![server_id, channel_id, sender_id, from_ts, to_ts],
                |row| row.get::<_, bool>(0),
            )
            .unwrap_or(false)
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
            .prepare(&format!(
                "SELECT {CHANNEL_MSG_COLS}
                 FROM channel_messages
                 WHERE server_id = ?1 AND channel_id = ?2 AND (timestamp > ?3 OR updated_at > ?3)
                 ORDER BY timestamp ASC
                 LIMIT ?4",
            ))
            .map_err(|e| format!("Failed to prepare messages_since query: {e}"))?;

        let rows = stmt
            .query_map(
                params![server_id, channel_id, since_timestamp, limit],
                channel_message_from_row,
            )
            .map_err(|e| format!("Failed to query messages_since: {e}"))?;

        collect_rows(rows, "messages_since")
    }

    pub fn get_channel_messages_before(
        &self,
        server_id: &str,
        channel_id: &str,
        before_timestamp: i64,
        limit: i32,
    ) -> Result<Vec<StoredChannelMessage>, String> {
        let mut stmt = self
            .conn
            .prepare(&format!(
                "SELECT {CHANNEL_MSG_COLS}
                 FROM channel_messages
                 WHERE server_id = ?1 AND channel_id = ?2 AND timestamp < ?3
                 ORDER BY timestamp DESC
                 LIMIT ?4",
            ))
            .map_err(|e| format!("Failed to prepare messages_before query: {e}"))?;

        let rows = stmt
            .query_map(
                params![server_id, channel_id, before_timestamp, limit],
                channel_message_from_row,
            )
            .map_err(|e| format!("Failed to query messages_before: {e}"))?;

        let mut messages = collect_rows(rows, "messages_before")?;
        messages.reverse();
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

    /// Count all visible DM messages across every peer. Used by the Home stats
    /// card as a multi-device sync-comparison number: DMs fully converge across a
    /// person's devices (fan-out + sibling backfill), unlike channel messages
    /// which are lazy-paged per device and would diverge. Excludes hidden
    /// (deleted) rows — deletion tombstones are per-device and would skew the
    /// comparison.
    pub fn count_all_dm_messages(&self) -> u32 {
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM messages WHERE hidden_at IS NULL",
                [],
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

    /// Delete DM messages older than `before_timestamp` for a specific peer.
    /// Returns the number of deleted rows.
    pub fn prune_dm_messages_before(&self, peer_id: &str, before_timestamp: i64) -> Result<u32, String> {
        let deleted = self.conn
            .execute(
                "DELETE FROM messages WHERE peer_id = ?1 AND timestamp < ?2",
                params![peer_id, before_timestamp],
            )
            .map_err(|e| format!("Failed to prune DM messages: {e}"))?;
        Ok(deleted as u32)
    }

    /// Delete channel messages in a time range for a specific server.
    /// Only prunes messages with `timestamp >= since AND timestamp < before`.
    /// This ensures forward-only retention: only messages created after the
    /// policy was set are subject to pruning.
    pub fn prune_channel_messages_in_range(&self, server_id: &str, since: i64, before: i64) -> Result<u32, String> {
        let deleted = self.conn
            .execute(
                "DELETE FROM channel_messages WHERE server_id = ?1 AND timestamp >= ?2 AND timestamp < ?3",
                params![server_id, since, before],
            )
            .map_err(|e| format!("Failed to prune channel messages: {e}"))?;
        Ok(deleted as u32)
    }

    /// Count unread DM messages: messages STRICTLY NEWER (millisecond
    /// timestamp) than the `last_seen_message_id` row.
    ///
    /// Deliberately millisecond-granular, NOT rowid and NOT the full display
    /// tuple:
    /// - rowid (`id >`): a sync backfill inserts older-timestamped rows with
    ///   HIGHER rowids — those counted forever ("ghost unread" that no
    ///   reading cleared, because the seen pointer is the newest-by-time
    ///   message while the ghost had the max rowid).
    /// - full tuple (timestamp, order_us, id): Dart marks seen from its
    ///   in-memory list's `.last`, which is millisecond-sorted — in a
    ///   same-millisecond burst that may not be the tuple-max row, so the
    ///   tail of the burst stayed "unread" until the user SENT something.
    /// Same-millisecond messages render together on screen, so treating the
    /// whole millisecond as seen matches what the user actually saw, and any
    /// same-ms seen pointer zeroes the count deterministically.
    /// Returns 0 when the seen row is not found (never a count-everything
    /// degradation — the live event path still increments for new arrivals).
    pub fn count_unread_dm(&self, peer_id: &str, last_seen_message_id: &str) -> u32 {
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM messages m
                 WHERE m.peer_id = ?1
                   AND m.hidden_at IS NULL AND m.is_mine = 0
                   AND m.timestamp >
                       (SELECT s.timestamp FROM messages s
                         WHERE s.peer_id = ?1 AND s.message_id = ?2)",
                params![peer_id, last_seen_message_id],
                |row| row.get::<_, i64>(0),
            )
            .unwrap_or(0) as u32
    }

    /// Count unread channel messages strictly newer (millisecond) than the
    /// seen row — see [`Self::count_unread_dm`] for why neither rowids nor
    /// the full display tuple work here.
    pub fn count_unread_channel(
        &self,
        server_id: &str,
        channel_id: &str,
        last_seen_message_id: &str,
    ) -> u32 {
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM channel_messages m
                 WHERE m.server_id = ?1 AND m.channel_id = ?2
                   AND m.hidden_at IS NULL AND m.is_mine = 0
                   AND m.timestamp >
                       (SELECT s.timestamp FROM channel_messages s
                         WHERE s.server_id = ?1 AND s.channel_id = ?2 AND s.message_id = ?3)",
                params![server_id, channel_id, last_seen_message_id],
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

    /// Count unread messages and mention-containing messages for a channel.
    /// `mention_patterns` should include strings like `@everyone`, `@DisplayName`, `@Nickname`.
    /// A message counts as a mention if it contains any pattern OR has a reply_to.
    pub fn count_unread_channel_with_mentions(
        &self,
        server_id: &str,
        channel_id: &str,
        last_seen_message_id: Option<&str>,
        mention_patterns: &[String],
    ) -> (u32, u32) {
        let mut mention_clauses = Vec::new();
        let mut param_values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();
        param_values.push(Box::new(server_id.to_string()));
        param_values.push(Box::new(channel_id.to_string()));

        let mut param_idx = 3;
        // Strictly newer (millisecond) than the seen row — see
        // count_unread_dm for why neither rowids nor the full display tuple
        // work. When the seen row is missing the comparison is NULL →
        // count 0 (never count-everything).
        let seen_filter = if let Some(mid) = last_seen_message_id {
            param_values.push(Box::new(mid.to_string()));
            let f = format!(
                "AND timestamp >
                     (SELECT s.timestamp FROM channel_messages s
                       WHERE s.server_id = ?1 AND s.channel_id = ?2 AND s.message_id = ?{param_idx})"
            );
            param_idx += 1;
            f
        } else {
            String::new()
        };

        for pattern in mention_patterns {
            mention_clauses.push(format!("text LIKE ?{param_idx}"));
            param_values.push(Box::new(format!("%{pattern}%")));
            param_idx += 1;
        }
        // Any reply counts as a mention — parity with the live path
        // (event_provider.dart treats replyToMid != null as a mention).
        mention_clauses.push("reply_to_mid IS NOT NULL".to_string());

        let mention_expr = mention_clauses.join(" OR ");
        let sql = format!(
            "SELECT COUNT(*), COUNT(CASE WHEN ({mention_expr}) THEN 1 END)
             FROM channel_messages
             WHERE server_id = ?1 AND channel_id = ?2 {seen_filter}
               AND hidden_at IS NULL AND is_mine = 0"
        );

        let params_refs: Vec<&dyn rusqlite::types::ToSql> =
            param_values.iter().map(|p| p.as_ref()).collect();
        self.conn
            .query_row(&sql, params_refs.as_slice(), |row| {
                Ok((
                    row.get::<_, i64>(0).unwrap_or(0) as u32,
                    row.get::<_, i64>(1).unwrap_or(0) as u32,
                ))
            })
            .unwrap_or((0, 0))
    }

    /// Get all distinct peer IDs that have DM messages.
    pub fn get_dm_peer_ids(&self) -> Vec<String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT DISTINCT peer_id FROM messages")
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
            // Lookback overlap: MAX(timestamp) is a high-watermark, and a
            // watermark permanently skips a message that was MISSED while a
            // newer one arrived (live topic miss during a subscribe/reconnect
            // window, push-fetch inserting newer rows first). Asking from
            // `watermark - LOOKBACK` re-covers that hole; the overlap is
            // deduplicated by message_id on receipt, so the only cost is
            // re-sending up to LOOKBACK of recent messages per sync.
            map.insert(sender, (ts - SYNC_LOOKBACK_MS).max(0));
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

        let (where_clause, mut param_values) =
            Self::per_sender_where(server_id, channel_id, sender_timestamps);
        let sql = format!(
            "SELECT {CHANNEL_MSG_COLS}
             FROM channel_messages
             WHERE server_id = ?1 AND channel_id = ?2 AND ({where_clause})
             ORDER BY timestamp ASC, COALESCE(order_us, timestamp * 1000) ASC
             LIMIT ?{}",
            param_values.len() + 1,
        );
        param_values.push(Box::new(limit));

        let params_ref: Vec<&dyn rusqlite::types::ToSql> = param_values.iter().map(|p| p.as_ref()).collect();

        let mut stmt = self.conn.prepare(&sql)
            .map_err(|e| format!("Failed to prepare per_sender_since query: {e}"))?;
        let rows = stmt
            .query_map(params_ref.as_slice(), channel_message_from_row)
            .map_err(|e| format!("Failed to query per_sender_since: {e}"))?;

        collect_rows(rows, "per_sender")
    }

    /// Build the dynamic per-sender WHERE fragment + parameter list shared by
    /// [`Self::get_channel_messages_since_per_sender`] and
    /// [`Self::count_channel_messages_since_per_sender`]: for each known sender,
    /// messages with `timestamp >= their latest` (inclusive — catches
    /// same-millisecond messages; INSERT OR IGNORE dedup handles overlap);
    /// unknown senders match ALL their messages. Params ?1/?2 are
    /// server_id/channel_id.
    fn per_sender_where(
        server_id: &str,
        channel_id: &str,
        sender_timestamps: &HashMap<String, i64>,
    ) -> (String, Vec<Box<dyn rusqlite::types::ToSql>>) {
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

        (conditions.join(" OR "), param_values)
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

        let (where_clause, param_values) =
            Self::per_sender_where(server_id, channel_id, sender_timestamps);
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
            .prepare_cached("SELECT physical_ms, counter, actor FROM hlc_state WHERE id = 1")
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

    /// Delete the persisted MLS identity (signer + credential + group storage).
    /// Multi-device: used when a linked sibling detects it inherited the source
    /// device's MLS identity and must mint a fresh, distinct one.
    pub fn clear_mls_identity(&self) -> Result<(), String> {
        self.conn
            .execute("DELETE FROM mls_identity WHERE id = 1", [])
            .map_err(|e| format!("Failed to clear MLS identity: {e}"))?;
        Ok(())
    }

    /// Load MLS identity. Returns (signer_data, credential_data, storage_data) if exists.
    pub fn load_mls_identity(&self) -> Result<Option<(Vec<u8>, Vec<u8>, Option<Vec<u8>>)>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT signer_data, credential_data, storage_data FROM mls_identity WHERE id = 1")
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

    // ── Multi-device signed device lists (Phase 6) ──

    /// Current stored device-list version for a master, or 0 if none.
    /// Callers use this to enforce monotonic version (replay protection) BEFORE
    /// accepting an incoming list.
    pub fn device_list_version(&self, master_peer_id: &str) -> Result<u64, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT version FROM device_lists WHERE master_peer_id = ?1")
            .map_err(|e| format!("Failed to prepare device_list_version: {e}"))?;
        let mut rows = stmt
            .query_map([master_peer_id], |row| row.get::<_, i64>(0))
            .map_err(|e| format!("Failed to query device_list_version: {e}"))?;
        match rows.next() {
            Some(Ok(v)) => Ok(v.max(0) as u64),
            _ => Ok(0),
        }
    }

    /// Persist a verified device list: upsert the master row and rebuild its
    /// `device_links` reverse-index entries. The caller MUST have cryptographically
    /// verified the list AND confirmed `version` strictly increases (use
    /// `device_list_version`). `devices` is the authoritative member set.
    ///
    /// Stale links from a previous (lower-version) list for this master are
    /// removed so a revoked device no longer resolves to it.
    pub fn save_device_list(
        &self,
        master_peer_id: &str,
        json: &str,
        version: u64,
        devices: &[String],
        updated_at: i64,
    ) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO device_lists (master_peer_id, json, version, updated_at)
                 VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(master_peer_id) DO UPDATE SET
                    json = excluded.json,
                    version = excluded.version,
                    updated_at = excluded.updated_at",
                rusqlite::params![master_peer_id, json, version as i64, updated_at],
            )
            .map_err(|e| format!("Failed to upsert device_lists: {e}"))?;

        // Rebuild reverse index for this master: drop its old links, insert the
        // current device set. A device can only belong to one master, so an
        // INSERT OR REPLACE re-homes any device that moved (shouldn't happen for
        // honest lists, but keeps the index consistent).
        self.conn
            .execute(
                "DELETE FROM device_links WHERE master_peer_id = ?1",
                [master_peer_id],
            )
            .map_err(|e| format!("Failed to clear device_links: {e}"))?;
        for dev in devices {
            self.conn
                .execute(
                    "INSERT OR REPLACE INTO device_links (device_peer_id, master_peer_id)
                     VALUES (?1, ?2)",
                    rusqlite::params![dev, master_peer_id],
                )
                .map_err(|e| format!("Failed to insert device_link: {e}"))?;
        }
        Ok(())
    }

    /// Load the persisted `SignedDeviceList` for a master, if any. Used to read
    /// our OWN list back (devices + version) before re-publishing, and to inspect
    /// a peer's stored list. Returns `Ok(None)` when no row exists or the stored
    /// JSON fails to deserialize (treated as absent, not an error).
    pub fn load_device_list(
        &self,
        master_peer_id: &str,
    ) -> Result<Option<crate::node::SignedDeviceList>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT json FROM device_lists WHERE master_peer_id = ?1")
            .map_err(|e| format!("Failed to prepare load_device_list: {e}"))?;
        let mut rows = stmt
            .query_map([master_peer_id], |row| row.get::<_, String>(0))
            .map_err(|e| format!("Failed to query load_device_list: {e}"))?;
        match rows.next() {
            Some(Ok(json)) => Ok(serde_json::from_str(&json).ok()),
            _ => Ok(None),
        }
    }

    /// Load all (device_peer_id → master_peer_id) links for resolver warmup.
    pub fn get_all_device_links(&self) -> Result<Vec<(String, String)>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT device_peer_id, master_peer_id FROM device_links")
            .map_err(|e| format!("Failed to prepare get_all_device_links: {e}"))?;
        let rows = stmt
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .map_err(|e| format!("Failed to query device_links: {e}"))?;
        collect_rows(rows, "device_link")
    }

    /// Wipe ALL persisted device lists + reverse-index links (multi-device,
    /// Phase 6). Testing/maintenance aid: union-merge never removes a device id,
    /// so repeated wipe+reimport test cycles leave ghost devices accumulating in
    /// our own published list. Clearing lets the set rebuild from currently-live
    /// siblings. (Production cleanup of a single device = Step 7 revocation.)
    pub fn clear_all_device_lists(&self) -> Result<(), String> {
        self.conn
            .execute("DELETE FROM device_links", [])
            .map_err(|e| format!("Failed to clear device_links: {e}"))?;
        self.conn
            .execute("DELETE FROM device_lists", [])
            .map_err(|e| format!("Failed to clear device_lists: {e}"))?;
        Ok(())
    }

    // ── Device labels (Step 8 Devices panel — local-only, unsigned) ──

    /// Set (or clear, when empty) the local human label for a device peer_id.
    pub fn set_device_label(&self, device_peer_id: &str, label: &str) -> Result<(), String> {
        if label.is_empty() {
            self.conn
                .execute(
                    "DELETE FROM device_labels WHERE device_peer_id = ?1",
                    params![device_peer_id],
                )
                .map_err(|e| format!("Failed to clear device label: {e}"))?;
        } else {
            self.conn
                .execute(
                    "INSERT INTO device_labels (device_peer_id, label) VALUES (?1, ?2)
                     ON CONFLICT(device_peer_id) DO UPDATE SET label = excluded.label",
                    params![device_peer_id, label],
                )
                .map_err(|e| format!("Failed to save device label: {e}"))?;
        }
        Ok(())
    }

    /// Load all local device labels (device_peer_id, label).
    pub fn get_all_device_labels(&self) -> Result<Vec<(String, String)>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT device_peer_id, label FROM device_labels")
            .map_err(|e| format!("Failed to prepare device_labels query: {e}"))?;
        let rows = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .map_err(|e| format!("Failed to query device_labels: {e}"))?;
        collect_rows(rows, "device_labels")
    }

    // ── User Profile Persistence (Phase 3.5) ──

    /// Upsert a user profile (ours or a peer's).
    /// `avatar` and `banner` are optional: `None` preserves the existing image, `Some(bytes)` overwrites
    /// (pass empty slice to clear).
    /// `showcase_board` is optional: `None` preserves the existing board (e.g. an update from an
    /// old client that predates boards), `Some("")` clears, `Some(json)` sets.
    /// `avatar_frame` carries the same three-state semantics (issue #54).
    #[allow(clippy::too_many_arguments)]
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
        showcase_board: Option<&str>,
        showcase_assets: Option<&[u8]>,
        // The subject's proof for this profile, or `None` to leave whatever is
        // stored untouched (COALESCE) — a partial update must not orphan an
        // existing signature.
        proof: Option<ProfileProof<'_>>,
        avatar_frame: Option<&str>,
    ) -> Result<(), String> {
        let profile_sig = proof.map(|p| p.sig);
        let profile_pk = proof.map(|p| p.pk);
        let profile_avatar_hash = proof.map(|p| p.avatar_hash);
        // For avatar/banner: None = no change (use COALESCE), Some(empty) = clear (store NULL), Some(data) = set.
        // Normalize Some(empty) to an explicit NULL for SQL.
        let avatar_val: Option<&[u8]> = avatar.and_then(|b| if b.is_empty() { None } else { Some(b) });
        let banner_val: Option<&[u8]> = banner.and_then(|b| if b.is_empty() { None } else { Some(b) });
        let avatar_is_clear = avatar.is_some() && avatar.unwrap().is_empty();
        let banner_is_clear = banner.is_some() && banner.unwrap().is_empty();
        let assets_val: Option<&[u8]> = showcase_assets.and_then(|b| if b.is_empty() { None } else { Some(b) });
        let assets_is_clear = showcase_assets.is_some() && showcase_assets.unwrap().is_empty();

        self.conn
            .execute(
                "INSERT INTO user_profiles (peer_id, display_name, status, about_me, updated_at, avatar, banner, twitch_username, showcase_board, showcase_assets, profile_sig, profile_pk, profile_avatar_hash, avatar_frame)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, COALESCE(?9, ''), ?10, ?11, ?12, ?13, COALESCE(?14, ''))
                 ON CONFLICT(peer_id) DO UPDATE SET
                    display_name = excluded.display_name,
                    status = excluded.status,
                    about_me = excluded.about_me,
                    updated_at = excluded.updated_at,
                    avatar = COALESCE(excluded.avatar, user_profiles.avatar),
                    banner = COALESCE(excluded.banner, user_profiles.banner),
                    twitch_username = excluded.twitch_username,
                    showcase_board = COALESCE(?9, user_profiles.showcase_board),
                    showcase_assets = COALESCE(excluded.showcase_assets, user_profiles.showcase_assets),
                    profile_sig = COALESCE(excluded.profile_sig, user_profiles.profile_sig),
                    profile_pk = COALESCE(excluded.profile_pk, user_profiles.profile_pk),
                    profile_avatar_hash = COALESCE(excluded.profile_avatar_hash, user_profiles.profile_avatar_hash),
                    avatar_frame = COALESCE(?14, user_profiles.avatar_frame)
                 WHERE excluded.updated_at >= user_profiles.updated_at
                    OR (excluded.updated_at < user_profiles.updated_at
                        AND ABS(excluded.updated_at - user_profiles.updated_at) < 86400000)",
                params![peer_id, display_name, status, about_me, updated_at, avatar_val, banner_val, twitch_username, showcase_board, assets_val, profile_sig, profile_pk, profile_avatar_hash, avatar_frame],
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
        if assets_is_clear {
            self.conn.execute(
                "UPDATE user_profiles SET showcase_assets = NULL WHERE peer_id = ?1",
                params![peer_id],
            ).map_err(|e| format!("Failed to clear showcase assets: {e}"))?;
        }
        Ok(())
    }

    /// Load a profile for a specific peer.
    pub fn load_profile(&self, peer_id: &str) -> Result<Option<StoredProfile>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT peer_id, display_name, status, about_me, updated_at, avatar, banner, twitch_username, showcase_board, showcase_assets, profile_sig, profile_pk, profile_avatar_hash, avatar_frame
                 FROM user_profiles WHERE peer_id = ?1",
            )
            .map_err(|e| format!("Failed to prepare profile query: {e}"))?;
        let mut rows = stmt
            .query_map(params![peer_id], profile_from_row)
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
                "SELECT peer_id, display_name, status, about_me, updated_at, avatar, banner, twitch_username, showcase_board, showcase_assets, profile_sig, profile_pk, profile_avatar_hash, avatar_frame
                 FROM user_profiles",
            )
            .map_err(|e| format!("Failed to prepare all profiles query: {e}"))?;
        let rows = stmt
            .query_map([], profile_from_row)
            .map_err(|e| format!("Failed to query all profiles: {e}"))?;
        collect_rows(rows, "profile")
    }

    /// Load all stored profiles WITHOUT avatar/banner blobs (light load for startup).
    pub fn load_all_profiles_light(&self) -> Result<Vec<StoredProfile>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT peer_id, display_name, status, about_me, updated_at, twitch_username, showcase_board, avatar_frame
                 FROM user_profiles",
            )
            .map_err(|e| format!("Failed to prepare light profiles query: {e}"))?;
        let rows = stmt
            .query_map([], profile_light_from_row)
            .map_err(|e| format!("Failed to query light profiles: {e}"))?;
        collect_rows(rows, "profile")
    }

    /// Load a single profile WITHOUT avatar/banner blobs (light load).
    pub fn load_profile_light(&self, peer_id: &str) -> Result<Option<StoredProfile>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT peer_id, display_name, status, about_me, updated_at, twitch_username, showcase_board, avatar_frame
                 FROM user_profiles WHERE peer_id = ?1",
            )
            .map_err(|e| format!("Failed to prepare light profile query: {e}"))?;
        let mut rows = stmt
            .query_map(params![peer_id], profile_light_from_row)
            .map_err(|e| format!("Failed to query light profile: {e}"))?;
        match rows.next() {
            Some(Ok(profile)) => Ok(Some(profile)),
            Some(Err(e)) => Err(format!("Failed to read profile row: {e}")),
            None => Ok(None),
        }
    }

    /// Load only the avatar blob for a peer.
    pub fn load_avatar(&self, peer_id: &str) -> Result<Option<Vec<u8>>, String> {
        self.conn
            .query_row(
                "SELECT avatar FROM user_profiles WHERE peer_id = ?1",
                params![peer_id],
                |row| row.get(0),
            )
            .or_else(|e| match e {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                _ => Err(format!("Failed to load avatar: {e}")),
            })
    }

    /// Load only the showcase asset bundle blob for a peer.
    pub fn load_showcase_assets(&self, peer_id: &str) -> Result<Option<Vec<u8>>, String> {
        self.conn
            .query_row(
                "SELECT showcase_assets FROM user_profiles WHERE peer_id = ?1",
                params![peer_id],
                |row| row.get(0),
            )
            .or_else(|e| match e {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                _ => Err(format!("Failed to load showcase assets: {e}")),
            })
    }

    /// Load only the banner blob for a peer.
    pub fn load_banner(&self, peer_id: &str) -> Result<Option<Vec<u8>>, String> {
        self.conn
            .query_row(
                "SELECT banner FROM user_profiles WHERE peer_id = ?1",
                params![peer_id],
                |row| row.get(0),
            )
            .or_else(|e| match e {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                _ => Err(format!("Failed to load banner: {e}")),
            })
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

    /// Returns the conversation peer_id (the OTHER party's master id) a DM is
    /// filed under. Used by multi-device self fan-out (Phase 6, Step 3): when a
    /// sibling echoes an edit/delete/reaction on a message WE sent, we attribute
    /// the resulting UI event to the right conversation by looking up the row's
    /// peer_id by message_id (the edit/delete/reaction envelopes carry no convo).
    pub fn get_dm_message_peer(&self, message_id: &str) -> Option<String> {
        self.conn
            .query_row(
                "SELECT peer_id FROM messages WHERE message_id = ?1",
                params![message_id],
                |row| row.get(0),
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

    /// One message row's signature-relevant fields (v2 message signing).
    /// Loaded by the edit/delete SIGN sites (the edit signature binds the
    /// row's structural fields), the live edit/delete VERIFY sites (the
    /// receiver reconstructs the same extras from ITS row), and the Message
    /// Proof FFI.
    fn message_sig_row(&self, table: &str, message_id: &str) -> Option<MessageSigRow> {
        self.conn
            .query_row(
                &format!(
                    "SELECT text, timestamp, signature, public_key, edited_at, \
                     reply_to_mid, file_id, order_us, link_preview_json \
                     FROM {table} WHERE message_id = ?1"
                ),
                params![message_id],
                |row| {
                    Ok(MessageSigRow {
                        text: row.get(0)?,
                        timestamp: row.get(1)?,
                        signature: row.get(2)?,
                        public_key: row.get(3)?,
                        edited_at: row.get(4)?,
                        reply_to_mid: row.get(5)?,
                        file_id: row.get(6)?,
                        order_us: row.get(7)?,
                        link_preview: row
                            .get::<_, Option<String>>(8)?
                            .and_then(|json| serde_json::from_str(&json).ok()),
                    })
                },
            )
            .ok()
    }

    /// [`Self::message_sig_row`] for the DM `messages` table.
    pub fn get_dm_message_sig_row(&self, message_id: &str) -> Option<MessageSigRow> {
        self.message_sig_row("messages", message_id)
    }

    /// [`Self::message_sig_row`] for the `channel_messages` table.
    pub fn get_channel_message_sig_row(&self, message_id: &str) -> Option<MessageSigRow> {
        self.message_sig_row("channel_messages", message_id)
    }

    pub fn set_channel_message_edited_at(&self, message_id: &str, edited_at: i64) -> Result<(), String> {
        self.conn.execute(
            "UPDATE channel_messages SET edited_at = ?1 WHERE message_id = ?2 AND edited_at IS NULL",
            params![edited_at, message_id],
        ).map_err(|e| format!("set_channel_message_edited_at: {e}"))?;
        Ok(())
    }

    pub fn edit_channel_message(
        &self,
        message_id: &str,
        new_text: &str,
        edited_at: i64,
        signature: Option<&str>,
        public_key: Option<&str>,
    ) -> Result<bool, String> {
        self.edit_message_in("channel_messages", message_id, new_text, edited_at, signature, public_key)
    }

    /// Shared implementation of [`Self::edit_channel_message`] /
    /// [`Self::edit_dm_message`]. `table` is a fixed table name ("messages" /
    /// "channel_messages"), never user input. Preserves the previous text (and
    /// signature provenance) in message_edits before overwriting, in one
    /// transaction.
    fn edit_message_in(
        &self,
        table: &str,
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
                &format!("SELECT text, signature, public_key, COALESCE(edited_at, timestamp) FROM {table} WHERE message_id = ?1"),
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

        self.conn.execute_batch("BEGIN").map_err(|e| format!("BEGIN: {e}"))?;

        if let Err(e) = self.conn.execute(
            "INSERT INTO message_edits (message_id, old_text, new_text, edited_at, signature, public_key, prev_signature, prev_public_key, prev_timestamp)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![message_id, old_text, new_text, edited_at, signature, public_key, prev_sig, prev_pk, prev_ts],
        ) {
            let _ = self.conn.execute_batch("ROLLBACK");
            return Err(format!("Failed to insert edit history: {e}"));
        }

        let result = self.conn.execute(
            &format!("UPDATE {table} SET text = ?1, edited_at = ?2, signature = ?3, public_key = ?4, updated_at = ?2 WHERE message_id = ?5"),
            params![new_text, edited_at, signature, public_key, message_id],
        );

        match result {
            Ok(rows) => {
                let _ = self.conn.execute_batch("COMMIT");
                Ok(rows > 0)
            }
            Err(e) => {
                let _ = self.conn.execute_batch("ROLLBACK");
                Err(format!("Failed to update {table} row: {e}"))
            }
        }
    }

    /// Repair a channel message's attributed sender + signature material (multi-device
    /// self-heal). A row that was stored before the device→master resolve fix can be
    /// keyed under a sender DEVICE id with signature material that no longer verifies
    /// against the master-id payload. When channel sync later delivers the SAME message
    /// id with a signature that DOES verify (proving authentic sender + text), the
    /// caller overwrites the local row's `sender_id`/`signature`/`public_key`/`is_mine`
    /// with the verified values so the bubble renders the person and the proof verifies.
    /// `INSERT OR IGNORE` blocks re-inserting the corrupt row, so this UPDATE is the only
    /// way to converge it. Returns true if a row was changed.
    pub fn repair_channel_message_sender(
        &self,
        message_id: &str,
        sender_id: &str,
        is_mine: bool,
        signature: Option<&str>,
        public_key: Option<&str>,
    ) -> Result<bool, String> {
        self.conn
            .execute(
                "UPDATE channel_messages SET sender_id = ?1, is_mine = ?2, signature = ?3, public_key = ?4 WHERE message_id = ?5",
                params![sender_id, is_mine as i32, signature, public_key, message_id],
            )
            .map(|rows| rows > 0)
            .map_err(|e| format!("repair_channel_message_sender: {e}"))
    }

    /// Edit a DM message by message_id. Preserves old text in message_edits table.
    /// Returns true if the message was found and updated.
    pub fn set_dm_message_edited_at(&self, message_id: &str, edited_at: i64) -> Result<(), String> {
        self.conn.execute(
            "UPDATE messages SET edited_at = ?1 WHERE message_id = ?2 AND edited_at IS NULL",
            params![edited_at, message_id],
        ).map_err(|e| format!("set_dm_message_edited_at: {e}"))?;
        Ok(())
    }

    pub fn edit_dm_message(
        &self,
        message_id: &str,
        new_text: &str,
        edited_at: i64,
        signature: Option<&str>,
        public_key: Option<&str>,
    ) -> Result<bool, String> {
        self.edit_message_in("messages", message_id, new_text, edited_at, signature, public_key)
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
        self.hide_message_in("channel_messages", message_id, deleted_at, signature, public_key)
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
        self.hide_message_in("messages", message_id, deleted_at, signature, public_key)
    }

    /// Shared implementation of [`Self::hide_channel_message`] /
    /// [`Self::hide_dm_message`]. `table` is a fixed table name ("messages" /
    /// "channel_messages"), never user input.
    fn hide_message_in(
        &self,
        table: &str,
        message_id: &str,
        deleted_at: i64,
        signature: Option<&str>,
        public_key: Option<&str>,
    ) -> Result<bool, String> {
        // 1. Read the current text for evidence preservation.
        let text: Option<String> = self
            .conn
            .query_row(
                &format!("SELECT text FROM {table} WHERE message_id = ?1"),
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
                &format!("UPDATE {table} SET hidden_at = ?1, updated_at = ?1 WHERE message_id = ?2"),
                params![deleted_at, message_id],
            )
            .map_err(|e| format!("Failed to hide {table} row: {e}"))?;

        Ok(rows > 0)
    }

    /// Lightweight hidden_at setter for channel messages during sync.
    /// Unlike hide_channel_message(), this does NOT preserve evidence in message_deletions
    /// (the original deleter already did that). Used when syncing deleted messages to late joiners.
    pub fn set_channel_message_hidden(&self, message_id: &str, hidden_at: i64) -> Result<(), String> {
        self.set_message_hidden_in("channel_messages", message_id, hidden_at)
    }

    /// Lightweight hidden_at setter for DM messages during sync.
    pub fn set_dm_message_hidden(&self, message_id: &str, hidden_at: i64) -> Result<(), String> {
        self.set_message_hidden_in("messages", message_id, hidden_at)
    }

    /// Shared hidden_at setter. `table` is a fixed table name, never user input.
    fn set_message_hidden_in(&self, table: &str, message_id: &str, hidden_at: i64) -> Result<(), String> {
        self.conn
            .execute(
                &format!("UPDATE {table} SET hidden_at = ?1, updated_at = ?1 WHERE message_id = ?2"),
                params![hidden_at, message_id],
            )
            .map_err(|e| format!("Failed to set {table} hidden_at: {e}"))?;
        Ok(())
    }

    /// The stored deletion proof for a message: `(deleted_at, signature,
    /// public_key)` from the latest SIGNED `message_deletions` evidence row.
    /// Sync responders attach this to `hidden_at` items (0.8.4); `None` for
    /// pre-signing legacy deletions — those no longer propagate through sync
    /// (REJECT-ABSENT).
    pub fn load_deletion_proof(&self, message_id: &str) -> Option<(i64, String, String)> {
        self.conn
            .query_row(
                "SELECT deleted_at, signature, public_key FROM message_deletions
                 WHERE message_id = ?1 AND signature IS NOT NULL AND public_key IS NOT NULL
                 ORDER BY id DESC LIMIT 1",
                params![message_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .ok()
    }

    /// `hidden_at` of a channel message row (`None` = visible or no such row).
    pub fn get_channel_message_hidden_at(&self, message_id: &str) -> Option<i64> {
        self.conn
            .query_row(
                "SELECT hidden_at FROM channel_messages WHERE message_id = ?1",
                params![message_id],
                |row| row.get(0),
            )
            .ok()
            .flatten()
    }

    /// `hidden_at` of a DM message row (`None` = visible or no such row).
    pub fn get_dm_message_hidden_at(&self, message_id: &str) -> Option<i64> {
        self.conn
            .query_row(
                "SELECT hidden_at FROM messages WHERE message_id = ?1",
                params![message_id],
                |row| row.get(0),
            )
            .ok()
            .flatten()
    }

    /// Sync-apply setter for a VERIFIED deletion (0.8.4): sets `hidden_at`
    /// like [`Self::set_channel_message_hidden`] AND stores the verified
    /// proof in `message_deletions` (once) so THIS node can re-serve the
    /// deletion with its proof. Without the store-forward, REJECT-ABSENT
    /// would stop deletions from propagating past the first sync hop.
    pub fn set_channel_message_hidden_verified(
        &self,
        message_id: &str,
        hidden_at: i64,
        signature: &str,
        public_key: &str,
    ) -> Result<(), String> {
        self.set_message_hidden_verified_in("channel_messages", message_id, hidden_at, signature, public_key)
    }

    /// DM twin of [`Self::set_channel_message_hidden_verified`].
    pub fn set_dm_message_hidden_verified(
        &self,
        message_id: &str,
        hidden_at: i64,
        signature: &str,
        public_key: &str,
    ) -> Result<(), String> {
        self.set_message_hidden_verified_in("messages", message_id, hidden_at, signature, public_key)
    }

    /// Shared verified-hidden setter. `table` is a fixed table name, never
    /// user input. Idempotent under sync re-apply: the evidence row is only
    /// inserted while no SIGNED one exists for this message.
    fn set_message_hidden_verified_in(
        &self,
        table: &str,
        message_id: &str,
        hidden_at: i64,
        signature: &str,
        public_key: &str,
    ) -> Result<(), String> {
        let have_signed: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM message_deletions WHERE message_id = ?1 AND signature IS NOT NULL",
                params![message_id],
                |row| row.get(0),
            )
            .unwrap_or(0);
        if have_signed == 0 {
            let text: String = self
                .conn
                .query_row(
                    &format!("SELECT text FROM {table} WHERE message_id = ?1"),
                    params![message_id],
                    |row| row.get(0),
                )
                .unwrap_or_default();
            self.conn
                .execute(
                    "INSERT INTO message_deletions (message_id, deleted_text, deleted_at, signature, public_key)
                     VALUES (?1, ?2, ?3, ?4, ?5)",
                    params![message_id, text, hidden_at, signature, public_key],
                )
                .map_err(|e| format!("Failed to store synced deletion proof: {e}"))?;
        }
        self.set_message_hidden_in(table, message_id, hidden_at)
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

    /// Shared batch loader for the per-message evidence tables (reactions,
    /// edits, deletions, removals): runs
    /// `SELECT message_id, <cols> FROM <table> WHERE message_id IN (…) ORDER BY <order_col> ASC`
    /// and groups the mapped rows by message_id. `table`/`cols`/`order_col` are
    /// fixed identifiers, never user input; `map` reads the row STARTING AT
    /// INDEX 1 (index 0 is the message_id).
    fn load_grouped_by_message_id<T>(
        &self,
        table: &str,
        cols: &str,
        order_col: &str,
        message_ids: &[String],
        map: impl Fn(&rusqlite::Row<'_>) -> rusqlite::Result<T>,
    ) -> Result<HashMap<String, Vec<T>>, String> {
        if message_ids.is_empty() {
            return Ok(HashMap::new());
        }

        // Build placeholder list for IN clause.
        let placeholders: Vec<String> = message_ids.iter().enumerate().map(|(i, _)| format!("?{}", i + 1)).collect();
        let sql = format!(
            "SELECT message_id, {cols} FROM {table} WHERE message_id IN ({}) ORDER BY {order_col} ASC",
            placeholders.join(", ")
        );

        let mut stmt = self.conn.prepare(&sql)
            .map_err(|e| format!("Failed to prepare {table} batch query: {e}"))?;
        let params_vec: Vec<&dyn rusqlite::types::ToSql> = message_ids.iter().map(|s| s as &dyn rusqlite::types::ToSql).collect();
        let rows = stmt
            .query_map(params_vec.as_slice(), |row| {
                Ok((row.get::<_, String>(0)?, map(row)?))
            })
            .map_err(|e| format!("Failed to query {table}: {e}"))?;

        let mut result: HashMap<String, Vec<T>> = HashMap::new();
        for row in rows {
            let (mid, item) = row.map_err(|e| format!("Failed to read {table} row: {e}"))?;
            result.entry(mid).or_default().push(item);
        }
        Ok(result)
    }

    /// Load all reactions for a set of message IDs.
    /// Returns a map: message_id → Vec<(emoji, peer_id, added_at)>.
    pub fn load_reactions_for_messages(
        &self,
        message_ids: &[String],
    ) -> Result<HashMap<String, Vec<(String, String, i64)>>, String> {
        self.load_grouped_by_message_id(
            "message_reactions",
            "emoji, peer_id, added_at",
            "added_at",
            message_ids,
            |row| Ok((row.get(1)?, row.get(2)?, row.get(3)?)),
        )
    }

    /// Load all reactions with signatures for sync.
    /// Returns: message_id → Vec<(emoji, peer_id, added_at, signature, public_key)>.
    pub fn load_reactions_for_sync(
        &self,
        message_ids: &[String],
    ) -> Result<HashMap<String, Vec<SignedEmojiRow>>, String> {
        self.load_grouped_by_message_id(
            "message_reactions",
            "emoji, peer_id, added_at, signature, public_key",
            "added_at",
            message_ids,
            |row| Ok((row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?, row.get(5)?)),
        )
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
            .prepare(&format!(
                "SELECT {DM_MSG_COLS}
                 FROM messages
                 WHERE peer_id = ?1
                 ORDER BY timestamp ASC, id ASC",
            ))
            .map_err(|e| format!("Failed to prepare load_all_dm_messages query: {e}"))?;

        let rows = stmt
            .query_map(params![peer_id], dm_message_from_row)
            .map_err(|e| format!("Failed to query all DM messages: {e}"))?;

        collect_rows(rows, "DM message")
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
            .prepare(&format!(
                "SELECT {CHANNEL_MSG_COLS}
                 FROM channel_messages
                 WHERE server_id = ?1 AND channel_id = ?2
                 ORDER BY timestamp ASC, id ASC",
            ))
            .map_err(|e| format!("Failed to prepare load_all_channel_messages query: {e}"))?;

        let rows = stmt
            .query_map(params![server_id, channel_id], channel_message_from_row)
            .map_err(|e| format!("Failed to query all channel messages: {e}"))?;

        collect_rows(rows, "channel message")
    }

    /// Load edit history for a batch of message IDs.
    /// Returns a map of message_id → Vec<(old_text, new_text, edited_at, signature, public_key)>.
    pub fn load_edits_for_messages(
        &self,
        message_ids: &[String],
    ) -> Result<HashMap<String, Vec<(String, String, i64, Option<String>, Option<String>, Option<String>, Option<String>, Option<i64>)>>, String> {
        self.load_grouped_by_message_id(
            "message_edits",
            "old_text, new_text, edited_at, signature, public_key, prev_signature, prev_public_key, prev_timestamp",
            "edited_at",
            message_ids,
            |row| Ok((
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
                row.get(5)?,
                row.get(6)?,
                row.get(7)?,
                row.get(8)?,
            )),
        )
    }

    /// Load deletion evidence for a batch of message IDs.
    /// Returns a map of message_id → Vec<(deleted_text, deleted_at, signature, public_key)>.
    pub fn load_deletions_for_messages(
        &self,
        message_ids: &[String],
    ) -> Result<HashMap<String, Vec<(String, i64, Option<String>, Option<String>)>>, String> {
        self.load_grouped_by_message_id(
            "message_deletions",
            "deleted_text, deleted_at, signature, public_key",
            "deleted_at",
            message_ids,
            |row| Ok((row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
        )
    }

    /// Load reaction removal evidence for a batch of message IDs.
    /// Returns a map of message_id → Vec<(emoji, peer_id, removed_at, signature, public_key)>.
    pub fn load_reaction_removals_for_messages(
        &self,
        message_ids: &[String],
    ) -> Result<HashMap<String, Vec<SignedEmojiRow>>, String> {
        self.load_grouped_by_message_id(
            "reaction_removals",
            "emoji, peer_id, removed_at, signature, public_key",
            "removed_at",
            message_ids,
            |row| Ok((row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?, row.get(5)?)),
        )
    }

    // ── App Settings ──────────────────────────────────────────────

    /// Save a key-value setting (insert or update).
    // ── Search ────────────────────────────────────────────────────

    /// Search channel messages by text content using FTS5 index.
    /// Falls back to LIKE if FTS match fails.
    pub fn search_channel_messages(
        &self,
        server_id: &str,
        channel_id: &str,
        query: &str,
        limit: i32,
    ) -> Result<Vec<StoredChannelMessage>, String> {
        let fts_query = query.replace('"', "\"\"");
        let fts_pattern = format!("\"{}\"", fts_query);
        let mut stmt = self
            .conn
            .prepare(
                "SELECT cm.id, cm.server_id, cm.channel_id, cm.sender_id, cm.text, cm.is_mine, cm.timestamp, cm.signature, cm.public_key, cm.message_id, cm.edited_at, cm.hidden_at, cm.reply_to_mid, cm.file_id, cm.link_preview_json, cm.order_us
                 FROM channel_messages cm
                 JOIN channel_messages_fts fts ON cm.id = fts.rowid
                 WHERE fts.text MATCH ?3 AND cm.server_id = ?1 AND cm.channel_id = ?2 AND cm.hidden_at IS NULL
                 ORDER BY cm.id DESC
                 LIMIT ?4",
            )
            .map_err(|e| format!("Failed to prepare FTS search query: {e}"))?;

        let rows = stmt
            .query_map(params![server_id, channel_id, fts_pattern, limit], channel_message_from_row)
            .map_err(|e| format!("Failed to search messages: {e}"))?;

        let mut messages = collect_rows(rows, "search")?;
        messages.reverse();
        Ok(messages)
    }

    /// Search DM messages by text content using FTS5 index.
    pub fn search_dm_messages(
        &self,
        peer_id: &str,
        query: &str,
        limit: i32,
    ) -> Result<Vec<StoredMessage>, String> {
        let fts_query = query.replace('"', "\"\"");
        let fts_pattern = format!("\"{}\"", fts_query);
        let mut stmt = self
            .conn
            .prepare(
                "SELECT m.id, m.peer_id, m.text, m.is_mine, m.timestamp, m.signature, m.public_key, m.message_id, m.edited_at, m.hidden_at, m.reply_to_mid, m.file_id, m.link_preview_json, m.order_us
                 FROM messages m
                 JOIN messages_fts fts ON m.id = fts.rowid
                 WHERE fts.text MATCH ?2 AND m.peer_id = ?1 AND m.hidden_at IS NULL
                 ORDER BY m.id DESC
                 LIMIT ?3",
            )
            .map_err(|e| format!("Failed to prepare FTS DM search query: {e}"))?;

        let rows = stmt
            .query_map(params![peer_id, fts_pattern, limit], dm_message_from_row)
            .map_err(|e| format!("Failed to search DM messages: {e}"))?;

        let mut messages = collect_rows(rows, "DM search")?;
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

    /// Re-key a friend row from a DEVICE id to its MASTER id once the device→master
    /// mapping is learned (device-list ingest). Friendships must key on the master
    /// (presence/DM/profile all do), but a friend added by TEMPORARY NICKNAME lands
    /// under the friend's DEVICE id (the relay claims nicknames under the WS-auth
    /// device socket), stranding the row. Returns true if a row was migrated.
    ///
    /// Merge rule when a master row already exists: keep `accepted` over `pending`,
    /// keep the earliest non-zero `requested_at`, then delete the device row. No-op
    /// when `device == master` or no device row exists.
    pub fn migrate_friend_to_master(&self, device: &str, master: &str) -> Result<bool, String> {
        if device == master {
            return Ok(false);
        }
        // Load the device row (if any).
        let dev_row: Option<(String, String, i64)> = self
            .conn
            .query_row(
                "SELECT status, direction, requested_at FROM friends WHERE peer_id = ?1",
                params![device],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?)),
            )
            .ok();
        let Some((dev_status, dev_dir, dev_req)) = dev_row else {
            return Ok(false);
        };
        // Load the existing master row (if any) to merge.
        let mas_row: Option<(String, String, i64)> = self
            .conn
            .query_row(
                "SELECT status, direction, requested_at FROM friends WHERE peer_id = ?1",
                params![master],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?)),
            )
            .ok();
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        let (status, direction, requested_at) = match mas_row {
            Some((m_status, m_dir, m_req)) => {
                // Prefer accepted; otherwise keep the master row's status.
                let status = if m_status == "accepted" || dev_status == "accepted" {
                    "accepted".to_string()
                } else {
                    m_status
                };
                let direction = if !m_dir.is_empty() { m_dir } else { dev_dir };
                let requested_at = match (m_req, dev_req) {
                    (0, d) => d,
                    (m, 0) => m,
                    (m, d) => m.min(d),
                };
                (status, direction, requested_at)
            }
            None => (dev_status, dev_dir, dev_req),
        };
        self.conn
            .execute(
                "INSERT INTO friends (peer_id, status, direction, requested_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(peer_id) DO UPDATE SET status = ?2, direction = ?3,
                     requested_at = ?4, updated_at = ?5",
                params![master, status, direction, requested_at, now],
            )
            .map_err(|e| format!("Failed to upsert master friend row: {e}"))?;
        self.conn
            .execute("DELETE FROM friends WHERE peer_id = ?1", params![device])
            .map_err(|e| format!("Failed to delete device friend row: {e}"))?;
        Ok(true)
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

        collect_rows(rows, "friend")
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

    /// Returns `(status, direction)` for a friend row, or `None` if absent.
    /// Used to detect a MUTUAL friend request: an inbound request arriving while
    /// our own row is `("pending", "outgoing")` means both sides requested and
    /// should deterministically converge to friends.
    pub fn get_friend_status_direction(
        &self,
        peer_id: &str,
    ) -> Result<Option<(String, String)>, String> {
        let result = self.conn.query_row(
            "SELECT status, direction FROM friends WHERE peer_id = ?1",
            params![peer_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        );
        match result {
            Ok(sd) => Ok(Some(sd)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(format!("Failed to read friend row: {e}")),
        }
    }

    // ── Blocked peers (local block list, MASTER-keyed) ───────────

    pub fn block_peer(&self, master_peer_id: &str) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        self.conn
            .execute(
                "INSERT INTO blocked_peers (peer_id, blocked_at) VALUES (?1, ?2)
                 ON CONFLICT(peer_id) DO NOTHING",
                params![master_peer_id, now],
            )
            .map_err(|e| format!("Failed to block peer: {e}"))?;
        Ok(())
    }

    pub fn unblock_peer(&self, master_peer_id: &str) -> Result<(), String> {
        self.conn
            .execute(
                "DELETE FROM blocked_peers WHERE peer_id = ?1",
                params![master_peer_id],
            )
            .map_err(|e| format!("Failed to unblock peer: {e}"))?;
        Ok(())
    }

    /// All blocked master peer_ids, newest first.
    pub fn load_blocked_peers(&self) -> Result<Vec<String>, String> {
        let mut stmt = self
            .conn
            .prepare("SELECT peer_id FROM blocked_peers ORDER BY blocked_at DESC")
            .map_err(|e| format!("Failed to prepare blocked query: {e}"))?;
        let rows = stmt
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|e| format!("Failed to query blocked peers: {e}"))?;
        collect_rows(rows, "blocked")
    }

    // ── Conference rooms (host-local; reports/CONFERENCES_PLAN.md) ───

    pub fn upsert_conference(&self, row: &ConferenceRow) -> Result<(), String> {
        self.conn.execute(
            "INSERT INTO conferences (conf_id, name, waiting_room, access_code_hash, co_hosts, broadcast_mode, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT(conf_id) DO UPDATE SET
                name = excluded.name,
                waiting_room = excluded.waiting_room,
                access_code_hash = excluded.access_code_hash,
                co_hosts = excluded.co_hosts,
                broadcast_mode = excluded.broadcast_mode",
            rusqlite::params![
                row.conf_id, row.name, row.waiting_room as i64,
                row.access_code_hash, row.co_hosts, row.broadcast_mode as i64,
                row.created_at,
            ],
        ).map_err(|e| format!("Failed to upsert conference: {e}"))?;
        Ok(())
    }

    pub fn list_conferences(&self) -> Result<Vec<ConferenceRow>, String> {
        let mut stmt = self.conn.prepare(
            "SELECT conf_id, name, waiting_room, access_code_hash, co_hosts, broadcast_mode, created_at
             FROM conferences ORDER BY created_at DESC",
        ).map_err(|e| format!("Failed to prepare conference query: {e}"))?;
        let rows = stmt.query_map([], |row| {
            Ok(ConferenceRow {
                conf_id: row.get(0)?,
                name: row.get(1)?,
                waiting_room: row.get::<_, i64>(2)? != 0,
                access_code_hash: row.get(3)?,
                co_hosts: row.get(4)?,
                broadcast_mode: row.get::<_, i64>(5)? != 0,
                created_at: row.get(6)?,
            })
        }).map_err(|e| format!("Failed to query conferences: {e}"))?;
        collect_rows(rows, "conference")
    }

    pub fn get_conference(&self, conf_id: &str) -> Result<Option<ConferenceRow>, String> {
        Ok(self.list_conferences()?.into_iter().find(|c| c.conf_id == conf_id))
    }

    pub fn delete_conference(&self, conf_id: &str) -> Result<(), String> {
        self.conn.execute(
            "DELETE FROM conferences WHERE conf_id = ?1",
            rusqlite::params![conf_id],
        ).map_err(|e| format!("Failed to delete conference: {e}"))?;
        Ok(())
    }

    // ── Content-addressed asset blobs (emotes, banners, stickers, GIFs)
    //    + the personal emote set ───

    pub fn save_emote_blob(&self, hash: &str, bytes: &[u8], animated: bool) -> Result<(), String> {
        self.save_asset_blob(hash, bytes, animated, "emote")
    }

    /// Cache a content-addressed asset blob. `kind` is one of
    /// `emote | banner | sticker | gif` (see `node/assets.rs::AssetKind`) —
    /// local bookkeeping for per-kind caps and eviction, never wire data.
    pub fn save_asset_blob(
        &self,
        hash: &str,
        bytes: &[u8],
        animated: bool,
        kind: &str,
    ) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        self.conn
            .execute(
                "INSERT INTO emote_blobs (hash, bytes, animated, added_at, kind)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(hash) DO NOTHING",
                params![hash, bytes, animated as i64, now, kind],
            )
            .map_err(|e| format!("Failed to save asset blob: {e}"))?;
        Ok(())
    }

    /// (hash, animated, byte size) of every cached blob of one kind, newest
    /// first. Metadata only — bytes load per-hash via [`load_emote_blob`].
    pub fn list_asset_blobs_by_kind(
        &self,
        kind: &str,
    ) -> Result<Vec<(String, bool, u64)>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT hash, animated, LENGTH(bytes) FROM emote_blobs
                 WHERE kind = ?1 ORDER BY added_at DESC",
            )
            .map_err(|e| format!("Failed to prepare asset list: {e}"))?;
        let rows = stmt
            .query_map(params![kind], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)? != 0,
                    row.get::<_, i64>(2)?.max(0) as u64,
                ))
            })
            .map_err(|e| format!("Failed to list asset blobs: {e}"))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    /// Total bytes + row count of the asset blob cache (all kinds).
    pub fn asset_blob_usage(&self) -> Result<(u64, u32), String> {
        self.conn
            .query_row(
                "SELECT COALESCE(SUM(LENGTH(bytes)), 0), COUNT(*) FROM emote_blobs",
                [],
                |row| Ok((row.get::<_, i64>(0)?.max(0) as u64, row.get::<_, i64>(1)?.max(0) as u32)),
            )
            .map_err(|e| format!("Failed to read asset usage: {e}"))
    }

    /// LRU-evict asset blobs (oldest `added_at` first) until total size is
    /// under `max_bytes * 0.8` (same hysteresis as the file-cache evictor).
    /// Hashes in `keep` are never evicted — the caller passes everything
    /// still referenced by a personal set or replicated CRDT state, so
    /// eviction can only ever drop blobs that would be re-pulled on demand.
    /// Returns bytes freed.
    pub fn evict_asset_blobs(
        &self,
        max_bytes: u64,
        keep: &std::collections::HashSet<String>,
    ) -> Result<u64, String> {
        let (total, _) = self.asset_blob_usage()?;
        if total <= max_bytes {
            return Ok(0);
        }
        let target = (max_bytes as f64 * 0.8) as u64;
        let mut stmt = self
            .conn
            .prepare(
                "SELECT hash, LENGTH(bytes) FROM emote_blobs ORDER BY added_at ASC",
            )
            .map_err(|e| format!("Failed to prepare asset eviction scan: {e}"))?;
        let rows: Vec<(String, u64)> = stmt
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?.max(0) as u64))
            })
            .map_err(|e| format!("Failed to scan asset blobs: {e}"))?
            .filter_map(|r| r.ok())
            .collect();
        drop(stmt);

        let mut remaining = total;
        let mut freed = 0u64;
        for (hash, size) in rows {
            if remaining <= target {
                break;
            }
            if keep.contains(&hash) {
                continue;
            }
            if self
                .conn
                .execute("DELETE FROM emote_blobs WHERE hash = ?1", params![hash])
                .is_ok()
            {
                remaining = remaining.saturating_sub(size);
                freed += size;
            }
        }
        Ok(freed)
    }

    /// Delete every asset blob whose hash is NOT in `keep` (Storage Manager
    /// "clear" action). Returns bytes freed.
    pub fn clear_asset_blobs_except(
        &self,
        keep: &std::collections::HashSet<String>,
    ) -> Result<u64, String> {
        self.evict_asset_blobs(0, keep)
    }

    pub fn load_emote_blob(&self, hash: &str) -> Result<Option<Vec<u8>>, String> {
        let result = self.conn.query_row(
            "SELECT bytes FROM emote_blobs WHERE hash = ?1",
            params![hash],
            |row| row.get::<_, Vec<u8>>(0),
        );
        match result {
            Ok(bytes) => Ok(Some(bytes)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(format!("Failed to read emote blob: {e}")),
        }
    }

    pub fn has_emote_blob(&self, hash: &str) -> Result<bool, String> {
        let count: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM emote_blobs WHERE hash = ?1",
                params![hash],
                |row| row.get(0),
            )
            .map_err(|e| format!("Failed to check emote blob: {e}"))?;
        Ok(count > 0)
    }

    pub fn add_personal_emote(
        &self,
        name: &str,
        hash: &str,
        animated: bool,
        source: &str,
    ) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        self.conn
            .execute(
                "INSERT INTO personal_emotes (name, hash, animated, source, added_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(name) DO UPDATE SET
                     hash = excluded.hash, animated = excluded.animated,
                     source = excluded.source, added_at = excluded.added_at",
                params![name, hash, animated as i64, source, now],
            )
            .map_err(|e| format!("Failed to add personal emote: {e}"))?;
        Ok(())
    }

    pub fn remove_personal_emote(&self, name: &str) -> Result<(), String> {
        self.conn
            .execute(
                "DELETE FROM personal_emotes WHERE name = ?1",
                params![name],
            )
            .map_err(|e| format!("Failed to remove personal emote: {e}"))?;
        Ok(())
    }

    /// All personal emotes as (name, hash, animated, source), newest first.
    pub fn list_personal_emotes(&self) -> Result<Vec<(String, String, bool, String)>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT name, hash, animated, source FROM personal_emotes ORDER BY added_at DESC",
            )
            .map_err(|e| format!("Failed to prepare personal emote query: {e}"))?;
        let rows = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)? != 0,
                    row.get::<_, String>(3)?,
                ))
            })
            .map_err(|e| format!("Failed to query personal emotes: {e}"))?;
        collect_rows(rows, "personal emote")
    }

    // ── Personal sticker vault ────────────────────────────────────

    /// One row of the personal sticker vault.
    /// `(pack, hash, name, animated, w, h, source, added_at)`.
    pub fn add_personal_sticker(&self, row: &PersonalStickerRow) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        self.conn
            .execute(
                "INSERT INTO personal_stickers
                     (pack, hash, name, animated, w, h, source, added_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                 ON CONFLICT(pack, hash) DO UPDATE SET
                     name = excluded.name, animated = excluded.animated,
                     w = excluded.w, h = excluded.h, source = excluded.source",
                params![
                    row.pack,
                    row.hash,
                    row.name,
                    row.animated as i64,
                    row.w as i64,
                    row.h as i64,
                    row.source,
                    now
                ],
            )
            .map_err(|e| format!("Failed to add sticker: {e}"))?;
        Ok(())
    }

    pub fn remove_personal_sticker(&self, pack: &str, hash: &str) -> Result<(), String> {
        self.conn
            .execute(
                "DELETE FROM personal_stickers WHERE pack = ?1 AND hash = ?2",
                params![pack, hash],
            )
            .map_err(|e| format!("Failed to remove sticker: {e}"))?;
        Ok(())
    }

    /// Delete a whole pack. Blobs stay in the cache — they are
    /// content-addressed and may still be referenced by a sent message; the
    /// LRU reclaims them once nothing points at them.
    pub fn remove_personal_sticker_pack(&self, pack: &str) -> Result<(), String> {
        self.conn
            .execute(
                "DELETE FROM personal_stickers WHERE pack = ?1",
                params![pack],
            )
            .map_err(|e| format!("Failed to remove sticker pack: {e}"))?;
        Ok(())
    }

    /// Move every sticker of `from` into `to` (pack rename). Rows already in
    /// `to` with the same hash win, so a rename onto an existing pack merges
    /// instead of failing the unique constraint.
    pub fn rename_personal_sticker_pack(&self, from: &str, to: &str) -> Result<(), String> {
        self.conn
            .execute(
                "UPDATE OR REPLACE personal_stickers SET pack = ?2 WHERE pack = ?1",
                params![from, to],
            )
            .map_err(|e| format!("Failed to rename sticker pack: {e}"))?;
        Ok(())
    }

    /// The whole vault, pack-major and oldest-first inside each pack —
    /// upload order IS pack order, which is what makes a multi-part pack
    /// readable in the picker.
    pub fn list_personal_stickers(&self) -> Result<Vec<PersonalStickerRow>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT pack, hash, name, animated, w, h, source, added_at
                 FROM personal_stickers ORDER BY pack ASC, added_at ASC",
            )
            .map_err(|e| format!("Failed to prepare sticker query: {e}"))?;
        let rows = stmt
            .query_map([], |row| {
                Ok(PersonalStickerRow {
                    pack: row.get::<_, String>(0)?,
                    hash: row.get::<_, String>(1)?,
                    name: row.get::<_, String>(2)?,
                    animated: row.get::<_, i64>(3)? != 0,
                    w: row.get::<_, i64>(4)?.max(0) as u32,
                    h: row.get::<_, i64>(5)?.max(0) as u32,
                    source: row.get::<_, String>(6)?,
                    added_at: row.get::<_, i64>(7)?,
                })
            })
            .map_err(|e| format!("Failed to query stickers: {e}"))?;
        collect_rows(rows, "sticker")
    }

    /// Row count, for the authoring-side vault cap.
    pub fn personal_sticker_count(&self) -> Result<u32, String> {
        self.conn
            .query_row("SELECT COUNT(*) FROM personal_stickers", [], |row| {
                Ok(row.get::<_, i64>(0)?.max(0) as u32)
            })
            .map_err(|e| format!("Failed to count stickers: {e}"))
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

    /// Load ALL settings whose key starts with `prefix` in one query.
    /// Startup used to issue one `load_setting` FFI round-trip per
    /// server/channel/DM (~hundreds, serial) for the `notif:`/`seen:`
    /// namespaces — this replaces that with a single indexed range read.
    pub fn load_settings_with_prefix(
        &self,
        prefix: &str,
    ) -> Result<Vec<(String, String)>, String> {
        let mut stmt = self
            .conn
            .prepare_cached(
                "SELECT key, value FROM app_settings WHERE key >= ?1 AND key < ?1 || x'ff'",
            )
            .map_err(|e| format!("Failed to prepare settings prefix query: {e}"))?;
        let rows = stmt
            .query_map(params![prefix], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .map_err(|e| format!("Failed to query settings by prefix: {e}"))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    /// Load a setting by key. Returns None if not set.
    pub fn load_setting(&self, key: &str) -> Result<Option<String>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT value FROM app_settings WHERE key = ?1")
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
            .prepare_cached("SELECT peer_id, verified_at FROM verified_peers ORDER BY verified_at DESC")
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

    // ── Security alerts (Issue 1-C) ────────────────────────────────

    /// Record a security alert for a contact. Returns `true` if this is a NEW
    /// fact (the row did not exist), `false` if we have already recorded it.
    ///
    /// Callers use the return value to decide whether to emit a live event —
    /// a device list is re-ingested on every reconnect, so emitting
    /// unconditionally would re-raise a warning the user already dismissed.
    ///
    /// `peer_id` MUST be a master id (alerts are about a person, not a socket).
    pub fn record_security_alert(
        &self,
        peer_id: &str,
        kind: &str,
        detail: &str,
        created_at: i64,
    ) -> Result<bool, String> {
        let alert_id = format!("{kind}:{peer_id}:{detail}");
        let changed = self
            .conn
            .execute(
                "INSERT OR IGNORE INTO security_alerts
                    (alert_id, peer_id, kind, detail, created_at, acknowledged_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, NULL)",
                params![alert_id, peer_id, kind, detail, created_at],
            )
            .map_err(|e| format!("Failed to record security alert: {e}"))?;
        Ok(changed > 0)
    }

    /// All security alerts, newest first. `acknowledged_at` is `None` while the
    /// alert is still unread.
    pub fn get_security_alerts(&self) -> Result<Vec<SecurityAlertRow>, String> {
        let mut stmt = self
            .conn
            .prepare_cached(
                "SELECT alert_id, peer_id, kind, detail, created_at, acknowledged_at
                   FROM security_alerts ORDER BY created_at DESC",
            )
            .map_err(|e| format!("Failed to prepare security_alerts query: {e}"))?;
        let rows = stmt
            .query_map([], |row| {
                Ok(SecurityAlertRow {
                    alert_id: row.get(0)?,
                    peer_id: row.get(1)?,
                    kind: row.get(2)?,
                    detail: row.get(3)?,
                    created_at: row.get(4)?,
                    acknowledged_at: row.get(5)?,
                })
            })
            .map_err(|e| format!("Failed to query security_alerts: {e}"))?;
        Ok(rows.flatten().collect())
    }

    /// Mark one alert as read. Idempotent — re-acknowledging keeps the first
    /// timestamp so "when did I dismiss this" stays truthful.
    pub fn acknowledge_security_alert(&self, alert_id: &str) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        self.conn
            .execute(
                "UPDATE security_alerts SET acknowledged_at = ?2
                  WHERE alert_id = ?1 AND acknowledged_at IS NULL",
                params![alert_id, now],
            )
            .map_err(|e| format!("Failed to acknowledge security alert: {e}"))?;
        Ok(())
    }

    /// Mark every outstanding alert for one contact as read (the "Dismiss"
    /// action on the conversation banner, which speaks for all of them).
    pub fn acknowledge_security_alerts_for_peer(&self, peer_id: &str) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        self.conn
            .execute(
                "UPDATE security_alerts SET acknowledged_at = ?2
                  WHERE peer_id = ?1 AND acknowledged_at IS NULL",
                params![peer_id, now],
            )
            .map_err(|e| format!("Failed to acknowledge security alerts: {e}"))?;
        Ok(())
    }

    // ── Olm identity-key pins (Issue 1-C, TOFU) ────────────────────

    /// The Curve25519 identity key previously pinned for `device_peer_id`, or
    /// `None` if we have never completed a key exchange with it.
    pub fn get_olm_key_pin(&self, device_peer_id: &str) -> Result<Option<String>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT identity_key FROM olm_key_pins WHERE device_peer_id = ?1")
            .map_err(|e| format!("Failed to prepare olm_key_pins query: {e}"))?;
        let mut rows = stmt
            .query_map(params![device_peer_id], |row| row.get::<_, String>(0))
            .map_err(|e| format!("Failed to query olm_key_pins: {e}"))?;
        match rows.next() {
            Some(Ok(key)) => Ok(Some(key)),
            Some(Err(e)) => Err(format!("Failed to read olm key pin: {e}")),
            None => Ok(None),
        }
    }

    /// Pin (or re-pin) a device's Olm identity key.
    pub fn set_olm_key_pin(&self, device_peer_id: &str, identity_key: &str) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        self.conn
            .execute(
                "INSERT INTO olm_key_pins (device_peer_id, identity_key, pinned_at)
                 VALUES (?1, ?2, ?3)
                 ON CONFLICT(device_peer_id) DO UPDATE SET
                    identity_key = excluded.identity_key,
                    pinned_at    = excluded.pinned_at",
                params![device_peer_id, identity_key, now],
            )
            .map_err(|e| format!("Failed to set olm key pin: {e}"))?;
        Ok(())
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
        thumb_b64: Option<&str>,
    ) -> Result<(), String> {
        let vthumb_json = video_thumb
            .and_then(|v| serde_json::to_string(v).ok());
        // UPSERT (not INSERT OR IGNORE): the FCM background-fetch node may have
        // already inserted a MINIMAL placeholder row for this file (it only had
        // the file_id from the DM payload — the real FileHeader is never sent to
        // an offline peer, see file_handler.rs). When the real FileHeader later
        // arrives via self-heal, we must FILL IN the true name/ext/size/dimensions,
        // not silently ignore them. We deliberately do NOT touch completed_at,
        // disk_path, or chunks_received here — those are owned by the download
        // path (mark_file_complete / mark_chunk_received) and a re-arriving
        // header must never reset a finished file back to "incomplete".
        self.conn
            .execute(
                "INSERT INTO files
                 (file_id, file_name, file_ext, mime_type, size_bytes,
                  chunk_count, is_image, width, height, message_id,
                  context_type, context_id, sender_id, is_mine, created_at,
                  video_thumb_json, thumb_b64)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)
                 ON CONFLICT(file_id) DO UPDATE SET
                   file_name      = excluded.file_name,
                   file_ext       = excluded.file_ext,
                   mime_type      = excluded.mime_type,
                   size_bytes     = excluded.size_bytes,
                   chunk_count    = excluded.chunk_count,
                   is_image       = excluded.is_image,
                   width          = excluded.width,
                   height         = excluded.height,
                   message_id     = COALESCE(files.message_id, excluded.message_id),
                   video_thumb_json = COALESCE(excluded.video_thumb_json, files.video_thumb_json),
                   thumb_b64      = COALESCE(excluded.thumb_b64, files.thumb_b64)",
                params![
                    file_id, file_name, file_ext, mime_type,
                    size_bytes as i64, chunk_count, is_image as i32,
                    width.map(|w| w as i64), height.map(|h| h as i64),
                    message_id, context_type, context_id, sender_id,
                    is_mine as i32, created_at, vthumb_json, thumb_b64,
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

    /// Persist the ShareRef of a share-backed file (issue #41). Kept out of
    /// `insert_file_metadata` so re-arriving headers WITHOUT a share_ref (e.g.
    /// a FileRequest response) never blank an already-stored one.
    pub fn set_file_share_ref(
        &self,
        file_id: &str,
        share_ref: &crate::node::ShareRef,
    ) -> Result<(), String> {
        let json = serde_json::to_string(share_ref)
            .map_err(|e| format!("Failed to serialize share ref: {e}"))?;
        self.conn
            .execute(
                "UPDATE files SET share_ref_json = ?2 WHERE file_id = ?1",
                params![file_id, json],
            )
            .map_err(|e| format!("Failed to set share ref: {e}"))?;
        Ok(())
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
        let inserted = self.conn
            .execute(
                "INSERT OR IGNORE INTO file_chunks (file_id, chunk_index, received_at)
                 VALUES (?1, ?2, ?3)",
                params![file_id, chunk_index, now],
            )
            .map_err(|e| format!("Failed to insert file chunk: {e}"))?;

        // Increment the counter only when the chunk row was actually new —
        // a full `SELECT COUNT(*)` recount here made receiving a file O(n²)
        // in its chunk count. A duplicate chunk (retry/re-send) is a no-op.
        if inserted > 0 {
            self.conn
                .execute(
                    "UPDATE files SET chunks_received = chunks_received + 1
                     WHERE file_id = ?1",
                    params![file_id],
                )
                .map_err(|e| format!("Failed to update chunks_received: {e}"))?;
        }

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

    /// Re-resolve a completed file's `disk_path` against the CURRENT files
    /// directory.
    ///
    /// The DB stores an absolute `disk_path` captured when the file finished
    /// downloading. On iOS the app's data-container path is NOT stable across
    /// launches/reinstalls (the `Application/<UUID>` segment changes), so a
    /// stored absolute path can point at a now-nonexistent old container even
    /// though the file itself moved with the container and still exists. Files
    /// are stored as `{file_id}.{file_ext}`, so we can deterministically rebuild
    /// the correct current path. If the rebuilt path exists on disk we use it;
    /// otherwise we leave the stored value untouched (desktop paths are stable
    /// and some callers rely on the original string).
    fn resolve_disk_path(file: &mut StoredFile) {
        if file.completed_at.is_none() {
            return;
        }
        let Ok(files_dir) = crate::identity::data_dir().map(|d| d.join("files")) else {
            return;
        };
        let current = files_dir.join(format!("{}.{}", file.file_id, file.file_ext));
        if current.exists() {
            let current_str = current.to_string_lossy().to_string();
            if file.disk_path.as_deref() != Some(current_str.as_str()) {
                file.disk_path = Some(current_str);
            }
        }
    }

    /// Get file metadata by file_id.
    pub fn get_file_metadata(&self, file_id: &str) -> Result<Option<StoredFile>, String> {
        let mut stmt = self
            .conn
            .prepare(&format!("SELECT {FILE_COLS} FROM files WHERE file_id = ?1"))
            .map_err(|e| format!("Failed to prepare file query: {e}"))?;

        let result = stmt
            .query_row(params![file_id], stored_file_from_row)
            .ok();

        let result = result.map(|mut f| {
            Self::resolve_disk_path(&mut f);
            f
        });

        Ok(result)
    }

    pub fn get_file_metadata_batch(&self, file_ids: &[&str]) -> Result<std::collections::HashMap<String, StoredFile>, String> {
        use std::collections::HashMap;
        if file_ids.is_empty() { return Ok(HashMap::new()); }
        let placeholders: String = file_ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
        let sql = format!("SELECT {FILE_COLS} FROM files WHERE file_id IN ({placeholders})");
        let mut stmt = self.conn.prepare(&sql)
            .map_err(|e| format!("Failed to prepare batch file query: {e}"))?;
        let params: Vec<&dyn rusqlite::types::ToSql> = file_ids.iter()
            .map(|id| id as &dyn rusqlite::types::ToSql).collect();
        let rows = stmt.query_map(params.as_slice(), stored_file_from_row)
            .map_err(|e| format!("Failed to query batch file metadata: {e}"))?;
        let mut map = HashMap::new();
        for mut row in rows.flatten() {
            Self::resolve_disk_path(&mut row);
            map.insert(row.file_id.clone(), row);
        }
        Ok(map)
    }

    /// Get all files attached to a specific message.
    pub fn get_files_for_message(&self, message_id: &str) -> Result<Vec<StoredFile>, String> {
        let mut stmt = self
            .conn
            .prepare(&format!("SELECT {FILE_COLS} FROM files WHERE message_id = ?1"))
            .map_err(|e| format!("Failed to prepare files query: {e}"))?;

        let rows = stmt
            .query_map(params![message_id], stored_file_from_row)
            .map_err(|e| format!("Failed to query files: {e}"))?;

        let mut files = collect_rows(rows, "file")?;
        for f in &mut files {
            Self::resolve_disk_path(f);
        }
        Ok(files)
    }

    /// Get all incomplete files (for sync resume).
    pub fn get_incomplete_files(&self) -> Result<Vec<StoredFile>, String> {
        let mut stmt = self
            .conn
            .prepare(&format!(
                "SELECT {FILE_COLS} FROM files WHERE completed_at IS NULL AND hidden_at IS NULL"
            ))
            .map_err(|e| format!("Failed to prepare incomplete files query: {e}"))?;

        let rows = stmt
            .query_map([], stored_file_from_row)
            .map_err(|e| format!("Failed to query incomplete files: {e}"))?;

        collect_rows(rows, "file")
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
    /// Also checks disk — skips files that already exist in ~/.hollow/files/.
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

        Ok(Self::filter_ids_not_on_disk(rows))
    }

    /// Drop file ids whose bytes already exist in the files dir (a stem hit
    /// means the bytes exist regardless of the DB `completed_at` state).
    /// Unreadable rows are silently skipped.
    fn filter_ids_not_on_disk(rows: impl Iterator<Item = rusqlite::Result<String>>) -> Vec<String> {
        let disk_file_ids = Self::disk_file_stems();
        rows.filter_map(|r| r.ok())
            .filter(|id| !disk_file_ids.contains(id))
            .collect()
    }

    /// File-id stems present in the files dir (read dir once). Files are stored
    /// as {file_id}.{ext} — a stem hit means the bytes exist regardless of the
    /// DB `completed_at` state.
    fn disk_file_stems() -> std::collections::HashSet<String> {
        let files_dir = crate::identity::data_dir()
            .unwrap_or_default()
            .join("files");
        std::fs::read_dir(&files_dir)
            .map(|entries| {
                entries.filter_map(|e| e.ok()).filter_map(|e| {
                    let name = e.file_name().to_string_lossy().to_string();
                    name.split('.').next().map(|s| s.to_string())
                }).collect()
            })
            .unwrap_or_default()
    }

    /// Like `get_missing_file_ids`, but scoped to ONE DM conversation (messages
    /// are keyed on the friend's MASTER peer_id). Opening a DM must only
    /// re-request files belonging to that thread — the account-global sweep
    /// re-requested every missing id from the DM peer on every open (bandwidth
    /// leak, and it leaked unrelated file ids to the friend).
    pub fn get_missing_file_ids_for_dm(&self, peer_id: &str) -> Result<Vec<String>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT DISTINCT m.file_id FROM messages m
                 WHERE m.peer_id = ?1
                 AND m.file_id IS NOT NULL
                 AND m.file_id NOT IN (SELECT file_id FROM files WHERE completed_at IS NOT NULL)",
            )
            .map_err(|e| format!("Failed to prepare missing DM files query: {e}"))?;

        let rows = stmt
            .query_map([peer_id], |row| row.get::<_, String>(0))
            .map_err(|e| format!("Failed to query missing DM files: {e}"))?;

        Ok(Self::filter_ids_not_on_disk(rows))
    }

    /// Like `get_missing_file_ids`, but scoped to ONE server's channels.
    pub fn get_missing_file_ids_for_server(&self, server_id: &str) -> Result<Vec<String>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT DISTINCT cm.file_id FROM channel_messages cm
                 WHERE cm.server_id = ?1
                 AND cm.file_id IS NOT NULL
                 AND cm.file_id NOT IN (SELECT file_id FROM files WHERE completed_at IS NOT NULL)",
            )
            .map_err(|e| format!("Failed to prepare missing server files query: {e}"))?;

        let rows = stmt
            .query_map([server_id], |row| row.get::<_, String>(0))
            .map_err(|e| format!("Failed to query missing server files: {e}"))?;

        Ok(Self::filter_ids_not_on_disk(rows))
    }

    /// Scan completed files for stale disk_paths (file no longer exists on disk).
    /// Resets those entries to incomplete so they get re-requested from peers.
    /// Returns the number of entries reset.
    ///
    /// A stale ABSOLUTE path is not proof the bytes are gone: the data dir can
    /// move (iOS container rotation, drive/profile changes) while the file is
    /// still at the CURRENT `data_dir/files/{file_id}.{ext}`. Those rows are
    /// HEALED (disk_path re-pointed) instead of nulled — nulling them marked
    /// perfectly good files "missing" and made chat-open sweeps re-download
    /// bytes we already hold.
    pub fn reset_stale_file_paths(&self) -> Result<u32, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT file_id, file_ext, disk_path FROM files
                 WHERE completed_at IS NOT NULL AND disk_path IS NOT NULL",
            )
            .map_err(|e| format!("Failed to prepare stale files query: {e}"))?;

        let rows = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })
            .map_err(|e| format!("Failed to query completed files: {e}"))?;

        let files_dir = crate::identity::data_dir().ok().map(|d| d.join("files"));
        let mut stale_ids = Vec::new();
        let mut healed: Vec<(String, String)> = Vec::new();
        for row in rows {
            if let Ok((file_id, file_ext, disk_path)) = row {
                if std::path::Path::new(&disk_path).exists() {
                    continue;
                }
                // Stored path is stale — check the current canonical location
                // before declaring the bytes missing.
                let current = files_dir
                    .as_ref()
                    .map(|d| d.join(format!("{file_id}.{file_ext}")));
                match current {
                    Some(p) if p.exists() => {
                        healed.push((file_id, p.to_string_lossy().to_string()));
                    }
                    _ => stale_ids.push(file_id),
                }
            }
        }

        if stale_ids.is_empty() && healed.is_empty() {
            return Ok(0);
        }

        let count = stale_ids.len() as u32;
        self.conn.execute_batch("BEGIN").map_err(|e| format!("BEGIN: {e}"))?;
        for (file_id, new_path) in &healed {
            self.conn
                .execute(
                    "UPDATE files SET disk_path = ?2 WHERE file_id = ?1",
                    rusqlite::params![file_id, new_path],
                )
                .map_err(|e| {
                    let _ = self.conn.execute_batch("ROLLBACK");
                    format!("Failed to heal stale file path {file_id}: {e}")
                })?;
        }
        for file_id in &stale_ids {
            self.conn
                .execute(
                    "UPDATE files SET disk_path = NULL, completed_at = NULL WHERE file_id = ?1",
                    rusqlite::params![file_id],
                )
                .map_err(|e| {
                    let _ = self.conn.execute_batch("ROLLBACK");
                    format!("Failed to reset stale file {file_id}: {e}")
                })?;
        }
        self.conn.execute_batch("COMMIT").map_err(|e| format!("COMMIT: {e}"))?;

        Ok(count)
    }

    // ── Storage Manager (downloaded-file disk usage) ────────────────────────

    /// Per-context disk usage of downloaded files (Storage Manager breakdown).
    /// Returns rows of `(context_type, context_id, total_size_bytes, file_count)`
    /// for files that are completed AND still on disk. Cheap — backed by
    /// `idx_files_context (context_type, context_id)`.
    pub fn storage_breakdown(&self) -> Result<Vec<(String, String, u64, u32)>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT context_type, context_id,
                        COALESCE(SUM(size_bytes), 0) AS bytes,
                        COUNT(*) AS cnt
                 FROM files
                 WHERE completed_at IS NOT NULL AND disk_path IS NOT NULL
                 GROUP BY context_type, context_id",
            )
            .map_err(|e| format!("Failed to prepare storage_breakdown: {e}"))?;

        let rows = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)? as u64,
                    row.get::<_, i64>(3)? as u32,
                ))
            })
            .map_err(|e| format!("Failed to query storage_breakdown: {e}"))?;

        let mut out = Vec::new();
        for row in rows.flatten() {
            out.push(row);
        }
        Ok(out)
    }

    /// Get the on-disk paths of completed files for a single conversation/server.
    pub fn disk_paths_for_context(
        &self,
        context_type: &str,
        context_id: &str,
    ) -> Result<Vec<String>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT disk_path FROM files
                 WHERE context_type = ?1 AND context_id = ?2
                   AND completed_at IS NOT NULL AND disk_path IS NOT NULL",
            )
            .map_err(|e| format!("Failed to prepare disk_paths_for_context: {e}"))?;
        let rows = stmt
            .query_map(rusqlite::params![context_type, context_id], |row| {
                row.get::<_, String>(0)
            })
            .map_err(|e| format!("Failed to query disk_paths_for_context: {e}"))?;
        Ok(rows.flatten().collect())
    }

    /// Get every on-disk path of completed files (all conversations/servers).
    pub fn all_on_disk_paths(&self) -> Result<Vec<String>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT disk_path FROM files
                 WHERE completed_at IS NOT NULL AND disk_path IS NOT NULL",
            )
            .map_err(|e| format!("Failed to prepare all_on_disk_paths: {e}"))?;
        let rows = stmt
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|e| format!("Failed to query all_on_disk_paths: {e}"))?;
        Ok(rows.flatten().collect())
    }

    /// Null the disk_path + completed_at for a single conversation/server's files
    /// (so the message renders as a re-downloadable card). Returns rows affected.
    pub fn null_disk_path_for_context(
        &self,
        context_type: &str,
        context_id: &str,
    ) -> Result<u32, String> {
        let n = self
            .conn
            .execute(
                "UPDATE files SET disk_path = NULL, completed_at = NULL
                 WHERE context_type = ?1 AND context_id = ?2
                   AND completed_at IS NOT NULL",
                rusqlite::params![context_type, context_id],
            )
            .map_err(|e| format!("Failed to null disk paths for context: {e}"))?;
        Ok(n as u32)
    }

    /// Null the disk_path + completed_at for ALL completed files. Returns rows
    /// affected. Used by "Clear all cached file bytes".
    pub fn null_disk_path_all(&self) -> Result<u32, String> {
        let n = self
            .conn
            .execute(
                "UPDATE files SET disk_path = NULL, completed_at = NULL
                 WHERE completed_at IS NOT NULL",
                [],
            )
            .map_err(|e| format!("Failed to null all disk paths: {e}"))?;
        Ok(n as u32)
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

/// A recorded identity event for a contact (Issue 1-C).
///
/// `kind` is one of the [`crate::node::security_alerts`] constants; `detail`
/// carries the device id (`new_device`) or the new Olm identity key
/// (`identity_key_changed`) so the UI can show WHAT changed, not just that
/// something did.
#[derive(Clone, Debug)]
pub struct SecurityAlertRow {
    pub alert_id: String,
    /// MASTER peer_id — an alert is about a person.
    pub peer_id: String,
    pub kind: String,
    pub detail: String,
    pub created_at: i64,
    /// `None` while the alert is still unread.
    pub acknowledged_at: Option<i64>,
}

/// Persisted conference room (host-local; reports/CONFERENCES_PLAN.md).
pub struct ConferenceRow {
    pub conf_id: String,
    pub name: String,
    pub waiting_room: bool,
    /// Conf-scoped sha256 derivation of the access code (never plaintext).
    pub access_code_hash: Option<String>,
    /// JSON array of co-host master ids (phase 2 enforcement).
    pub co_hosts: String,
    pub broadcast_mode: bool,
    pub created_at: i64,
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

#[cfg(test)]
mod tests {
    use super::*;

    /// In-memory SQLCipher store for tests. The passphrase must be valid hex
    /// (interpolated as `x'…'`); a fresh `:memory:` db is created per call.
    fn mem_store() -> MessageStore {
        MessageStore::open(":memory:", &"ab".repeat(32)).expect("open in-memory store")
    }

    /// Locks the multi-device peer-fallback responder branch: a friend serving a
    /// SINGLE-device requester via `get_dm_messages_since` returns ONLY our own
    /// sends (is_mine=1), while serving a MULTI-device requester via
    /// `get_dm_messages_for_sibling` returns BOTH directions — so the requester
    /// recovers its own messages sent from another (offline) device.
    #[test]
    fn sibling_serve_returns_both_directions_unlike_friend_serve() {
        let store = mem_store();
        let convo = "friend_master";
        // Three messages WE sent to the friend, three the friend sent to us.
        store.insert(convo, "mine 1", true, 100, None, None, Some("m1"), None, None, None).unwrap();
        store.insert(convo, "theirs 1", false, 110, None, None, Some("t1"), None, None, None).unwrap();
        store.insert(convo, "mine 2", true, 120, None, None, Some("m2"), None, None, None).unwrap();
        store.insert(convo, "theirs 2", false, 130, None, None, Some("t2"), None, None, None).unwrap();
        store.insert(convo, "mine 3", true, 140, None, None, Some("m3"), None, None, None).unwrap();
        store.insert(convo, "theirs 3", false, 150, None, None, Some("t3"), None, None, None).unwrap();

        // Friend path (one-directional): only the messages WE sent.
        let friend = store.get_dm_messages_since(convo, 0, 200).unwrap();
        assert_eq!(friend.len(), 3, "friend serve must return only is_mine=1");
        assert!(friend.iter().all(|m| m.is_mine), "friend serve leaked received msgs");

        // Sibling/peer-fallback path: BOTH directions.
        let both = store.get_dm_messages_for_sibling(convo, 0, 200).unwrap();
        assert_eq!(both.len(), 6, "peer-fallback serve must return both directions");
        assert_eq!(both.iter().filter(|m| m.is_mine).count(), 3);
        assert_eq!(both.iter().filter(|m| !m.is_mine).count(), 3);
    }

    /// 0.8.4 deletion-proof plumbing: `load_deletion_proof` returns only a
    /// SIGNED evidence row (a legacy bare hide has none to serve), and the
    /// verified sync setter stores the proof exactly once under re-apply.
    #[test]
    fn deletion_proof_load_and_verified_setter_idempotency() {
        let store = mem_store();
        store.insert_channel_message("s", "c", "peer", "msg a", false, 100, None, None, Some("ma"), None, None, None).unwrap();
        store.insert_channel_message("s", "c", "peer", "msg b", false, 110, None, None, Some("mb"), None, None, None).unwrap();

        // A local (real) delete stores the proof; the loader returns it.
        store.hide_channel_message("ma", 200, Some("sig-a"), Some("pk-a")).unwrap();
        assert_eq!(
            store.load_deletion_proof("ma"),
            Some((200, "sig-a".to_string(), "pk-a".to_string())),
        );
        // Legacy bare hide: hidden, but no proof to serve.
        store.set_channel_message_hidden("mb", 210).unwrap();
        assert_eq!(store.get_channel_message_hidden_at("mb"), Some(210));
        assert_eq!(store.load_deletion_proof("mb"), None);

        // Verified sync setter: hides + stores the proof ONCE — a re-apply
        // (sync overlap) must not add a second, competing evidence row.
        store.insert("friend", "dm msg", false, 120, None, None, Some("md"), None, None, None).unwrap();
        store.set_dm_message_hidden_verified("md", 220, "sig-d", "pk-d").unwrap();
        store.set_dm_message_hidden_verified("md", 220, "sig-DIFFERENT", "pk-DIFFERENT").unwrap();
        assert_eq!(store.get_dm_message_hidden_at("md"), Some(220));
        assert_eq!(
            store.load_deletion_proof("md"),
            Some((220, "sig-d".to_string(), "pk-d".to_string())),
            "re-apply must not overwrite or duplicate the stored proof",
        );
    }

    /// A friend added by temporary nickname is stored under the friend's DEVICE
    /// id; once the device→master mapping is learned, `migrate_friend_to_master`
    /// must move the row to the master so presence/DM/profile (all master-keyed)
    /// line up. Covers the plain move, the merge-with-existing-master case
    /// (prefer accepted), and the device==master no-op.
    #[test]
    fn migrate_friend_device_to_master() {
        let device = "12D3KooWdeviceXYZ";
        let master = "12D3KooWmasterABC";

        // (1) Plain move: only a device row exists → it becomes the master row.
        {
            let store = mem_store();
            store.save_friend(device, "accepted", "", 100).unwrap();
            let moved = store.migrate_friend_to_master(device, master).unwrap();
            assert!(moved, "a stranded device row must migrate");
            let friends = store.load_friends(None).unwrap();
            assert_eq!(friends.len(), 1, "device row removed, master row added");
            assert_eq!(friends[0].0, master, "row is now keyed by master");
            assert_eq!(friends[0].1, "accepted");
        }

        // (2) Merge: a pending master row + an accepted device row → accepted wins.
        {
            let store = mem_store();
            store.save_friend(master, "pending", "outgoing", 50).unwrap();
            store.save_friend(device, "accepted", "", 100).unwrap();
            let moved = store.migrate_friend_to_master(device, master).unwrap();
            assert!(moved);
            let friends = store.load_friends(None).unwrap();
            assert_eq!(friends.len(), 1, "the two rows collapse into one master row");
            assert_eq!(friends[0].0, master);
            assert_eq!(friends[0].1, "accepted", "accepted must win over pending");
        }

        // (3) No-op when device == master (a single-device peer).
        {
            let store = mem_store();
            store.save_friend(master, "accepted", "", 100).unwrap();
            let moved = store.migrate_friend_to_master(master, master).unwrap();
            assert!(!moved, "device==master is a no-op");
            assert_eq!(store.load_friends(None).unwrap().len(), 1);
        }

        // (4) No-op when there is no device row to migrate.
        {
            let store = mem_store();
            store.save_friend(master, "accepted", "", 100).unwrap();
            let moved = store.migrate_friend_to_master(device, master).unwrap();
            assert!(!moved, "no device row → nothing to migrate");
        }
    }

    /// `get_latest_dm_timestamp` (friend high-water) ignores our own sends, so a
    /// multi-device requester must use `get_latest_dm_timestamp_any` to ask for
    /// the gap in its OWN outgoing messages too.
    #[test]
    fn latest_any_spans_both_directions() {
        let store = mem_store();
        let convo = "friend_master";
        // Our latest OUTGOING is newer than the latest INCOMING.
        store.insert(convo, "theirs", false, 100, None, None, Some("t1"), None, None, None).unwrap();
        store.insert(convo, "mine newer", true, 200, None, None, Some("m1"), None, None, None).unwrap();

        // is_mine=0-only high-water stops at the incoming message.
        assert_eq!(store.get_latest_dm_timestamp(convo).unwrap(), Some(100));
        // both-direction high-water sees our newer outgoing message.
        assert_eq!(store.get_latest_dm_timestamp_any(convo).unwrap(), Some(200));
    }

    /// Step 9C/C4: a same-MILLISECOND burst from two senders must display grouped
    /// by sender in true send order (order_us), NOT alternated by the sender_id
    /// tiebreaker (the "ping-pong" bug). Pixel sends 3, then AL sends 3, all at the
    /// SAME `timestamp` ms but with strictly increasing `order_us` reflecting true
    /// order. Correct display: P1,P2,P3,A1,A2,A3 (not P,A,P,A,…).
    #[test]
    fn channel_same_ms_burst_orders_by_order_us_not_sender() {
        let store = mem_store();
        let (sid, cid) = ("s1", "c1");
        let ms = 1_000i64;
        // Pixel's master id sorts AFTER AL's so the OLD sender_id-DESC tiebreaker
        // would have put Pixel first and then interleaved — proving the fix.
        let pixel = "zzz_pixel_master";
        let al = "aaa_al_master";
        // True send order: P1,P2,P3 then A1,A2,A3 — strictly increasing order_us.
        let send = |sender: &str, text: &str, mid: &str, ous: i64| {
            store.insert_channel_message(sid, cid, sender, text, false, ms,
                None, None, Some(mid), None, None, Some(ous)).unwrap();
        };
        send(pixel, "P1", "p1", ms * 1000 + 10);
        send(pixel, "P2", "p2", ms * 1000 + 20);
        send(pixel, "P3", "p3", ms * 1000 + 30);
        send(al, "A1", "a1", ms * 1000 + 40);
        send(al, "A2", "a2", ms * 1000 + 50);
        send(al, "A3", "a3", ms * 1000 + 60);

        let order: Vec<String> = store
            .load_channel_messages(sid, cid, 100)
            .unwrap()
            .into_iter()
            .map(|m| m.text)
            .collect();
        assert_eq!(
            order,
            vec!["P1", "P2", "P3", "A1", "A2", "A3"],
            "same-ms burst must group by sender in true send order (order_us), not ping-pong"
        );
    }

    /// C4: legacy rows with NULL order_us still sort deterministically (fall back to
    /// timestamp*1000 then sender_id/id) — backward-compat with pre-9C data.
    #[test]
    fn channel_null_order_us_falls_back_deterministically() {
        let store = mem_store();
        let (sid, cid) = ("s1", "c1");
        // Distinct timestamps, NULL order_us (legacy rows) → ordered by timestamp.
        store.insert_channel_message(sid, cid, "x", "first", false, 100,
            None, None, Some("m1"), None, None, None).unwrap();
        store.insert_channel_message(sid, cid, "y", "second", false, 200,
            None, None, Some("m2"), None, None, None).unwrap();
        let order: Vec<String> = store
            .load_channel_messages(sid, cid, 100)
            .unwrap()
            .into_iter()
            .map(|m| m.text)
            .collect();
        assert_eq!(order, vec!["first", "second"], "legacy NULL rows order by timestamp");
    }

    /// Ghost-unread regression: the unread count is millisecond-granular —
    /// a sync-BACKFILLED older row with a higher rowid must NOT count, and a
    /// same-millisecond burst sibling of the seen row must NOT count (Dart
    /// marks seen from a millisecond-sorted `.last`, which may not be the
    /// intra-ms tuple-max). Only strictly-newer milliseconds are unread.
    #[test]
    fn unread_counts_are_millisecond_granular() {
        let store = mem_store();

        // DM: seen row at ts=1000.
        let peer = "friend_master";
        store.insert(peer, "seen", false, 1000, None, None, Some("seen"), None, None, None).unwrap();
        // Same-ms burst sibling (higher rowid, same millisecond) — NOT unread.
        store.insert(peer, "same-ms", false, 1000, None, None, Some("m2"), None, None, None).unwrap();
        // Sync backfill: OLDER timestamp, higher rowid — NOT unread.
        store.insert(peer, "backfill", false, 500, None, None, Some("m3"), None, None, None).unwrap();
        // Genuinely newer — unread.
        store.insert(peer, "newer", false, 2000, None, None, Some("m4"), None, None, None).unwrap();
        assert_eq!(store.count_unread_dm(peer, "seen"), 1, "only the strictly-newer message is unread");
        // Missing seen row → 0, never count-everything.
        assert_eq!(store.count_unread_dm(peer, "no-such-mid"), 0);

        // Channel: same shape.
        let (sid, cid) = ("s-unread", "c-unread");
        store.insert_channel_message(sid, cid, "al", "seen", false, 1000,
            None, None, Some("ch-seen"), None, None, None).unwrap();
        store.insert_channel_message(sid, cid, "al", "same-ms", false, 1000,
            None, None, Some("ch2"), None, None, None).unwrap();
        store.insert_channel_message(sid, cid, "al", "backfill", false, 500,
            None, None, Some("ch3"), None, None, None).unwrap();
        store.insert_channel_message(sid, cid, "al", "newer", false, 2000,
            None, None, Some("ch4"), None, None, None).unwrap();
        assert_eq!(store.count_unread_channel(sid, cid, "ch-seen"), 1);
        assert_eq!(store.count_unread_channel(sid, cid, "gone"), 0);
        let (total, _) = store.count_unread_channel_with_mentions(sid, cid, Some("ch-seen"), &[]);
        assert_eq!(total, 1);
    }

    // ── Storage Manager ────────────────────────────────────────────────────

    /// Insert a completed-on-disk file row for storage tests.
    fn insert_completed_file(
        store: &MessageStore,
        file_id: &str,
        ctype: &str,
        cid: &str,
        size: u64,
        disk_path: &str,
    ) {
        store
            .insert_file_metadata(
                file_id, file_id, "bin", "application/octet-stream", size,
                1, false, None, None, None, ctype, cid, "sender", false, 1000, None, None,
            )
            .unwrap();
        store.mark_file_complete(file_id, disk_path).unwrap();
    }

    /// `storage_breakdown` groups completed-on-disk files by (context_type,
    /// context_id) and sums their bytes + counts. Incomplete files are excluded.
    #[test]
    fn storage_breakdown_sums_per_context() {
        let store = mem_store();
        insert_completed_file(&store, "f1", "dm", "alice", 100, "/tmp/f1");
        insert_completed_file(&store, "f2", "dm", "alice", 200, "/tmp/f2");
        insert_completed_file(&store, "f3", "channel", "s1:c1", 50, "/tmp/f3");
        // An incomplete file (no mark_file_complete) must NOT count.
        store
            .insert_file_metadata(
                "f4", "f4", "bin", "application/octet-stream", 999,
                1, false, None, None, None, "dm", "alice", "sender", false, 1000, None, None,
            )
            .unwrap();

        let rows = store.storage_breakdown().unwrap();
        let dm = rows.iter().find(|(t, c, _, _)| t == "dm" && c == "alice").unwrap();
        assert_eq!(dm.2, 300, "DM bytes = 100+200, excludes incomplete 999");
        assert_eq!(dm.3, 2, "DM file count = 2 completed");
        let ch = rows.iter().find(|(t, c, _, _)| t == "channel" && c == "s1:c1").unwrap();
        assert_eq!(ch.2, 50);
        assert_eq!(ch.3, 1);
    }

    /// `null_disk_path_for_context` clears disk_path + completed_at for ONE
    /// context only — the conversation's files become re-downloadable while
    /// other contexts are untouched. `disk_paths_for_context` returns the paths
    /// to delete first.
    #[test]
    fn clear_context_nulls_only_that_context() {
        let store = mem_store();
        insert_completed_file(&store, "f1", "dm", "alice", 100, "/tmp/f1");
        insert_completed_file(&store, "f2", "dm", "bob", 200, "/tmp/f2");

        let paths = store.disk_paths_for_context("dm", "alice").unwrap();
        assert_eq!(paths, vec!["/tmp/f1".to_string()]);

        let n = store.null_disk_path_for_context("dm", "alice").unwrap();
        assert_eq!(n, 1);

        // alice now has no completed-on-disk file; bob still does.
        let rows = store.storage_breakdown().unwrap();
        assert!(
            !rows.iter().any(|(t, c, _, _)| t == "dm" && c == "alice"),
            "alice's files were nulled → not in breakdown"
        );
        assert!(
            rows.iter().any(|(t, c, _, _)| t == "dm" && c == "bob"),
            "bob's files untouched"
        );

        // The metadata row survives (re-downloadable card).
        let meta = store.get_file_metadata("f1").unwrap().unwrap();
        assert!(meta.disk_path.is_none() && meta.completed_at.is_none());
    }

    /// `null_disk_path_all` clears every completed file (Clear all cached bytes).
    #[test]
    fn clear_all_nulls_every_context() {
        let store = mem_store();
        insert_completed_file(&store, "f1", "dm", "alice", 100, "/tmp/f1");
        insert_completed_file(&store, "f2", "channel", "s1:c1", 50, "/tmp/f2");

        let n = store.null_disk_path_all().unwrap();
        assert_eq!(n, 2);
        assert!(store.storage_breakdown().unwrap().is_empty());
    }
}
