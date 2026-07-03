# SQLCipher Database and Identity System

Source files: `rust/hollow_core/src/storage/messages.rs` (3154 lines), `rust/hollow_core/src/identity/native_identity.rs`, `rust/hollow_core/src/identity/keys.rs`

The `MessageStore` is the sole local persistence layer. It wraps a single `rusqlite::Connection` to an encrypted SQLCipher database. The `PRAGMA key` is set as hex before any table creation. All schema DDL lives in `MessageStore::init_schema()` with incremental `ALTER TABLE ADD COLUMN` migrations that silently ignore already-existing columns via `.unwrap_or(())`.

## MessageStore Initialization and Encryption

`messages.rs:MessageStore::open(path, passphrase)` opens the SQLCipher DB and sets the encryption key using hex format: `PRAGMA key = "x'{hex_passphrase}'"`. Returns `MessageStore { conn }`.

**Schema-once gate (2026-07 perf):** the ~25 CREATE TABLE + ~40 ALTER + indexes + FTS triggers used to replay on EVERY open (~139 transient call sites, milliseconds per message). `open()` now runs `init_schema()` once per process per DB path — a static `Mutex<HashSet<String>>` memo PLUS a one-row `sqlite_master` probe for the `messages` table (the probe catches a wipe/test that deletes the DB file and re-opens the same path; the memo alone skipped DDL on the fresh file and broke 7 unit tests). A fresh process after an app update still self-heals new columns on first open. Subsequent opens are just key + pragmas.

**Batched settings read:** `load_settings_with_prefix(prefix)` returns all `app_settings` rows in `[prefix, prefix||0xff)` via one indexed range query; FFI `loadSettingsWithPrefix` — startup hydration of `notif:*` and `seen:*` is 2 calls instead of one serial `loadSetting` per server/channel/DM.

The passphrase is derived from the user's Ed25519 secret key (see identity section). The DB file lives at `{data_dir}/messages.db`.

## Table: messages (DM Messages)

```sql
CREATE TABLE IF NOT EXISTS messages (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    peer_id   TEXT    NOT NULL,
    text      TEXT    NOT NULL,
    is_mine   INTEGER NOT NULL,
    timestamp INTEGER NOT NULL
)
-- Migrated columns (ALTER TABLE ADD COLUMN, nullable):
--   signature TEXT
--   public_key TEXT
--   message_id TEXT
--   edited_at INTEGER
--   hidden_at INTEGER
--   reply_to_mid TEXT
--   file_id TEXT
--   link_preview_json TEXT
```

Indexes:
- `idx_messages_peer_ts ON messages (peer_id, timestamp)` -- per-peer lookups
- `idx_messages_dedup ON messages (peer_id, timestamp, text, is_mine)` UNIQUE -- dedup for DM sync via INSERT OR IGNORE
- `idx_messages_msg_id ON messages (message_id)` -- fast edit/delete lookups

### DM Message Operations

- `messages.rs:insert()` -- `INSERT OR IGNORE INTO messages`. Params: peer_id, text, is_mine, timestamp, signature, public_key, message_id, reply_to_mid, file_id. Returns row ID or 0 if duplicate.
- `messages.rs:update_link_preview()` -- `UPDATE messages SET link_preview_json = ?1 WHERE message_id = ?2`. No-op if no match.
- `messages.rs:load_for_peer()` -- Loads recent DMs for a peer. `WHERE peer_id = ?1 AND hidden_at IS NULL ORDER BY timestamp DESC, id DESC LIMIT ?2`. Result is reversed to oldest-first for display. Returns `Vec<StoredMessage>`.
- `messages.rs:get_latest_dm_timestamp()` -- `SELECT MAX(timestamp) FROM messages WHERE peer_id = ?1 AND is_mine = 0`. Only received messages (is_mine=0) because the one-directional friend sync sends the other peer's sent messages.
- `messages.rs:get_latest_dm_timestamp_any()` -- `SELECT MAX(timestamp) FROM messages WHERE peer_id = ?1` (NO is_mine filter, both directions). Used by a MULTI-DEVICE requester so its high-water spans its OWN sends too (Step 5 sibling backfill + the 2026-06-18 friend peer-fallback).
- `messages.rs:get_dm_messages_since()` -- `WHERE peer_id = ?1 AND (timestamp >= ?2 OR updated_at >= ?2) AND is_mine = 1 ORDER BY timestamp ASC LIMIT ?3`. Returns our sent messages for the one-directional friend sync. Uses `>=` (inclusive) with INSERT OR IGNORE dedup. Includes hidden messages (Rat Files evidence must sync).
- `messages.rs:get_dm_messages_for_sibling()` -- same as above but **BOTH directions** (`(timestamp > ?2 OR updated_at >= ?2)`, no is_mine filter; `is_mine` carried through). Used by the sibling backfill responder AND (since 2026-06-18) the `DmSyncRequest{both_directions}` friend peer-fallback. NOTE: `is_mine` here is the RESPONDER's perspective — the friend-path receiver INVERTS it (a friend's sent = our received). Has unit tests `sibling_serve_returns_both_directions_unlike_friend_serve` + `latest_any_spans_both_directions`.
- `messages.rs:search_dm_messages()` -- FTS5 indexed search. JOINs `messages_fts` on rowid, uses `MATCH` instead of `LIKE`. Query wrapped in `"escaped_query"` for phrase matching. Result reversed to chronological.
- `messages.rs:load_all_dm_messages()` -- Archive export. No limit, includes hidden/deleted. `ORDER BY timestamp ASC, id ASC`.
- `messages.rs:count_dm_messages()` -- `SELECT COUNT(*) FROM messages WHERE peer_id = ?1`. Includes hidden.
- `messages.rs:count_unread_dm()` -- Finds autoincrement ID of `last_seen_message_id`, then counts rows with `id > threshold AND hidden_at IS NULL AND is_mine = 0`.
- `messages.rs:count_all_unread_dm()` -- For never-opened DMs: `SELECT COUNT(*) FROM messages WHERE peer_id = ?1 AND hidden_at IS NULL AND is_mine = 0`.
- `messages.rs:get_dm_peer_ids()` -- `SELECT DISTINCT peer_id FROM messages`. Returns all peers with DM history.
- `messages.rs:get_dm_message_is_mine()` -- `SELECT is_mine FROM messages WHERE message_id = ?1`. Ownership check for edit/delete authorization.
- `messages.rs:get_dm_message_text()` -- `SELECT text FROM messages WHERE message_id = ?1`. Used for deletion signing payload.

## Table: channel_messages (Server Channel Messages)

```sql
CREATE TABLE IF NOT EXISTS channel_messages (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    server_id  TEXT    NOT NULL,
    channel_id TEXT    NOT NULL,
    sender_id  TEXT    NOT NULL,
    text       TEXT    NOT NULL,
    is_mine    INTEGER NOT NULL,
    timestamp  INTEGER NOT NULL,
    UNIQUE(server_id, channel_id, sender_id, timestamp, text)
)
-- Migrated columns:
--   signature TEXT
--   public_key TEXT
--   message_id TEXT
--   edited_at INTEGER
--   hidden_at INTEGER
--   reply_to_mid TEXT
--   file_id TEXT
--   link_preview_json TEXT
```

Indexes:
- `idx_channel_msgs ON channel_messages (server_id, channel_id, timestamp)` -- per-channel lookups
- `idx_channel_msgs_unique ON channel_messages (server_id, channel_id, sender_id, timestamp, text)` UNIQUE -- dedup
- `idx_channel_msgs_msg_id ON channel_messages (message_id)` -- edit/delete lookups

Migration note: The UNIQUE constraint and index are enforced at open time. If duplicates exist, a cleanup DELETE runs first (keeping MIN(id) per group), then the unique index is created.

### Channel Message Operations

- `messages.rs:insert_channel_message()` -- `INSERT OR IGNORE INTO channel_messages`. Returns rows inserted (0=duplicate, 1=new).
- `messages.rs:update_channel_link_preview()` -- `UPDATE channel_messages SET link_preview_json = ?1 WHERE message_id = ?2`.
- `messages.rs:load_channel_messages()` -- `WHERE server_id = ?1 AND channel_id = ?2 AND hidden_at IS NULL ORDER BY timestamp DESC, sender_id DESC, id DESC LIMIT ?3`. Reversed to oldest-first.
- `messages.rs:get_latest_channel_timestamp()` -- `SELECT MAX(timestamp) FROM channel_messages WHERE server_id = ?1 AND channel_id = ?2`.
- `messages.rs:get_channel_messages_since()` -- `WHERE server_id = ?1 AND channel_id = ?2 AND timestamp > ?3 ORDER BY timestamp ASC LIMIT ?4`. Includes hidden (Rat Files). Note: uses `>` (exclusive), unlike DM sync which uses `>=`.
- `messages.rs:search_channel_messages()` -- FTS5 indexed search. JOINs `channel_messages_fts` on rowid, uses `MATCH` instead of `LIKE`. Filters by server_id + channel_id + hidden_at. Result reversed to chronological.
- `messages.rs:load_all_channel_messages()` -- Archive export. No limit, includes hidden. `ORDER BY timestamp ASC, id ASC`.
- `messages.rs:count_channel_messages()` -- `SELECT COUNT(*) ... WHERE server_id = ?1 AND channel_id = ?2`.
- `messages.rs:count_channel_messages_since()` -- `SELECT COUNT(*) ... WHERE server_id = ?1 AND channel_id = ?2 AND timestamp > ?3`.
- `messages.rs:count_unread_channel()` -- Same pattern as DM: find autoincrement ID of `last_seen_message_id`, count rows above it with `hidden_at IS NULL AND is_mine = 0`.
- `messages.rs:count_all_unread_channel()` -- For never-opened channels: all non-hidden, non-mine messages.
- `messages.rs:get_channel_message_sender()` -- `SELECT sender_id FROM channel_messages WHERE message_id = ?1`. Ownership check.
- `messages.rs:get_channel_message_text()` -- `SELECT text FROM channel_messages WHERE message_id = ?1`. Deletion signing payload.

### Per-Sender Sync (Gap Fill)

Advanced sync method that fills gaps per-sender rather than a single global timestamp watermark.

- `messages.rs:get_per_sender_timestamps()` -- `SELECT sender_id, MAX(timestamp) FROM channel_messages WHERE server_id = ?1 AND channel_id = ?2 GROUP BY sender_id`. Returns `HashMap<sender_id, max_timestamp>`.
- `messages.rs:get_channel_messages_since_per_sender()` -- Builds dynamic SQL. For each known sender: `(sender_id = ?N AND timestamp >= ?M)`. For unknown senders (not in the map): `sender_id NOT IN (...)` to get ALL their messages. Uses `>=` inclusive with INSERT OR IGNORE dedup. Falls back to `get_channel_messages_since(0)` if map is empty.
- `messages.rs:count_channel_messages_since_per_sender()` -- Same dynamic SQL but `SELECT COUNT(*)` instead of full rows.

## Table: message_edits (Edit History / Rat Files)

```sql
CREATE TABLE IF NOT EXISTS message_edits (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    message_id  TEXT    NOT NULL,
    old_text    TEXT    NOT NULL,
    new_text    TEXT    NOT NULL,
    edited_at   INTEGER NOT NULL,
    signature   TEXT,
    public_key  TEXT
    -- Migrated columns:
    --   prev_signature TEXT
    --   prev_public_key TEXT
    --   prev_timestamp INTEGER
)
```

Index: `idx_edits_msg_id ON message_edits (message_id)`

Stores every text change for Rat Files evidence. The `prev_signature`, `prev_public_key`, and `prev_timestamp` columns preserve the signature chain so edits can be cryptographically verified back to the original message.

### Edit Operations

- `messages.rs:edit_channel_message()` -- Three-step: (1) read current text + signature/public_key/timestamp via `SELECT text, signature, public_key, COALESCE(edited_at, timestamp)`, (2) insert into `message_edits` with old text and previous signature chain, (3) `UPDATE channel_messages SET text, edited_at, signature, public_key`. Returns false if message not found or text unchanged.
- `messages.rs:edit_dm_message()` -- Identical three-step pattern for DM messages table.
- `messages.rs:load_edits_for_messages()` -- Batch load: dynamic `IN (...)` clause. Returns `HashMap<message_id, Vec<(old_text, new_text, edited_at, signature, public_key, prev_signature, prev_public_key, prev_timestamp)>>`. Ordered by `edited_at ASC`.

## Table: message_deletions (Deletion Evidence / Rat Files)

```sql
CREATE TABLE IF NOT EXISTS message_deletions (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    message_id  TEXT    NOT NULL,
    deleted_text TEXT   NOT NULL,
    deleted_at  INTEGER NOT NULL,
    signature   TEXT,
    public_key  TEXT
)
```

Index: `idx_deletions_msg_id ON message_deletions (message_id)`

Messages are never truly deleted. Deletion sets `hidden_at` on the message row and preserves text in this table.

### Deletion Operations

- `messages.rs:hide_channel_message()` -- Three-step: (1) read current text, (2) insert into `message_deletions`, (3) `UPDATE channel_messages SET hidden_at`. Returns false if not found.
- `messages.rs:hide_dm_message()` -- Same pattern for DM messages.
- `messages.rs:set_channel_message_hidden()` -- Lightweight setter for sync. Only sets `hidden_at`, does NOT create deletion evidence (original deleter already did). Used when syncing to late joiners.
- `messages.rs:set_dm_message_hidden()` -- Same lightweight setter for DM sync.
- `messages.rs:load_deletions_for_messages()` -- Batch load: dynamic `IN (...)`. Returns `HashMap<message_id, Vec<(deleted_text, deleted_at, signature, public_key)>>`.

## Table: message_reactions (Emoji Reactions)

```sql
CREATE TABLE IF NOT EXISTS message_reactions (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    message_id TEXT    NOT NULL,
    emoji      TEXT    NOT NULL,
    peer_id    TEXT    NOT NULL,
    added_at   INTEGER NOT NULL,
    signature  TEXT,
    public_key TEXT,
    UNIQUE(message_id, emoji, peer_id)
)
```

Index: `idx_reactions_msg_id ON message_reactions (message_id)`

Enforces 3 distinct emojis per user per message (checked in application code before insert).

### Reaction Operations

- `messages.rs:add_reaction()` -- First checks `SELECT COUNT(DISTINCT emoji) ... WHERE message_id = ?1 AND peer_id = ?2 AND emoji != ?3`. If count >= 3, returns false (limit). Otherwise `INSERT OR IGNORE`. Returns true if new.
- `messages.rs:remove_reaction()` -- `DELETE FROM message_reactions WHERE message_id AND emoji AND peer_id`. If rows > 0, records in `reaction_removals`.
- `messages.rs:load_reactions_for_messages()` -- Batch load with dynamic `IN (...)`. Returns `HashMap<message_id, Vec<(emoji, peer_id, added_at)>>`. `ORDER BY added_at ASC`.
- `messages.rs:load_reactions_for_sync()` -- Same but includes signature/public_key. Returns `HashMap<message_id, Vec<(emoji, peer_id, added_at, signature, public_key)>>`.

## Table: reaction_removals (Reaction Removal Evidence / Rat Files)

```sql
CREATE TABLE IF NOT EXISTS reaction_removals (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    message_id TEXT    NOT NULL,
    emoji      TEXT    NOT NULL,
    peer_id    TEXT    NOT NULL,
    removed_at INTEGER NOT NULL,
    signature  TEXT,
    public_key TEXT
)
```

No dedicated index. Written by `remove_reaction()` after successful DELETE.

- `messages.rs:load_reaction_removals_for_messages()` -- Batch load with dynamic `IN (...)`. Returns `HashMap<message_id, Vec<(emoji, peer_id, removed_at, signature, public_key)>>`.

## Table: olm_account (Olm DM Encryption State)

```sql
CREATE TABLE IF NOT EXISTS olm_account (
    id     INTEGER PRIMARY KEY CHECK (id = 1),
    pickle TEXT NOT NULL
)
```

Singleton row (id=1 enforced by CHECK constraint). Stores the vodozemac Olm account pickle as JSON.

- `messages.rs:save_olm_account()` -- Upsert: `INSERT ... ON CONFLICT(id) DO UPDATE SET pickle`.
- `messages.rs:load_olm_account()` -- `SELECT pickle FROM olm_account WHERE id = 1`. Returns `Option<String>`.

## Table: olm_sessions (Per-Peer Olm Sessions)

```sql
CREATE TABLE IF NOT EXISTS olm_sessions (
    peer_id TEXT PRIMARY KEY,
    pickle  TEXT NOT NULL
)
```

One session per peer. Pickle is JSON.

- `messages.rs:save_olm_session()` -- Upsert by peer_id.
- `messages.rs:load_olm_session()` -- `SELECT pickle WHERE peer_id = ?1`. Returns `Option<String>`.
- `messages.rs:load_all_olm_sessions()` -- `SELECT peer_id, pickle FROM olm_sessions`. Returns `Vec<(String, String)>`.

## Table: mls_identity (MLS Group Encryption)

```sql
CREATE TABLE IF NOT EXISTS mls_identity (
    id              INTEGER PRIMARY KEY CHECK (id = 1),
    signer_data     BLOB NOT NULL,
    credential_data BLOB NOT NULL,
    storage_data    BLOB
)
```

Singleton row. Stores OpenMLS signer, credential, and provider storage as binary blobs.

- `messages.rs:save_mls_identity()` -- Upsert all three blobs.
- `messages.rs:load_mls_identity()` -- Returns `Option<(Vec<u8>, Vec<u8>, Option<Vec<u8>>)>`.

## Table: servers (CRDT Server State)

```sql
CREATE TABLE IF NOT EXISTS servers (
    server_id  TEXT PRIMARY KEY,
    state_json TEXT NOT NULL,
    updated_at INTEGER NOT NULL
)
```

Stores the full `ServerState` as JSON per server.

- `messages.rs:save_server_state()` -- Upsert with current timestamp. `ON CONFLICT(server_id) DO UPDATE SET state_json, updated_at`.
- `messages.rs:load_server_state()` -- `SELECT state_json WHERE server_id = ?1`.
- `messages.rs:load_all_servers()` -- `SELECT server_id, state_json FROM servers`. Used at startup to restore all joined servers.
- `messages.rs:delete_server_state()` -- Deletes from both `servers` and `crdt_ops` tables for the given server_id.

## Table: crdt_ops (CRDT Operation Log)

```sql
CREATE TABLE IF NOT EXISTS crdt_ops (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    server_id   TEXT NOT NULL,
    hlc_ms      INTEGER NOT NULL,
    hlc_counter INTEGER NOT NULL,
    author      TEXT NOT NULL,
    op_json     TEXT NOT NULL,
    UNIQUE(server_id, hlc_ms, hlc_counter, author)
)
```

Index: `idx_crdt_ops_server ON crdt_ops (server_id, hlc_ms)`

Each CRDT operation is serialized as JSON. UNIQUE constraint enables INSERT OR IGNORE dedup.

- `messages.rs:insert_crdt_op()` -- Serializes `CrdtOp` to JSON, `INSERT OR IGNORE`.
- `messages.rs:load_ops_for_server()` -- `SELECT op_json WHERE server_id = ?1 ORDER BY hlc_ms, hlc_counter, author`. Deserializes each row back to `CrdtOp`.

## Table: hlc_state (Hybrid Logical Clock)

```sql
CREATE TABLE IF NOT EXISTS hlc_state (
    id          INTEGER PRIMARY KEY CHECK (id = 1),
    physical_ms INTEGER NOT NULL,
    counter     INTEGER NOT NULL,
    actor       TEXT NOT NULL
)
```

Singleton row. Persists the HLC so the clock survives restarts without regression.

- `messages.rs:save_hlc_state()` -- Upsert physical_ms (u64), counter (u32), actor (String).
- `messages.rs:load_hlc_state()` -- Returns `Option<(u64, u32, String)>`.

## Table: user_profiles

```sql
CREATE TABLE IF NOT EXISTS user_profiles (
    peer_id      TEXT PRIMARY KEY,
    display_name TEXT NOT NULL DEFAULT '',
    status       TEXT NOT NULL DEFAULT '',
    about_me     TEXT NOT NULL DEFAULT '',
    updated_at   INTEGER NOT NULL DEFAULT 0
    -- Migrated columns:
    --   avatar BLOB
    --   banner BLOB
)
```

Stores profiles for both the local user and all known peers. Avatar/banner are raw binary blobs (WebP images).

- `messages.rs:save_profile()` -- Upsert with complex COALESCE logic for avatar/banner: `None` = preserve existing, `Some(empty)` = clear to NULL, `Some(data)` = overwrite. The UPDATE only fires if `excluded.updated_at >= user_profiles.updated_at` OR the difference is within 86400000ms (24h tolerance for clock skew). Clearing avatar/banner requires a separate `UPDATE SET avatar = NULL` after the main upsert because COALESCE cannot set NULL.
- `messages.rs:load_profile()` -- `SELECT ... FROM user_profiles WHERE peer_id = ?1`. Returns `Option<StoredProfile>` with `avatar_bytes` and `banner_bytes`.
- `messages.rs:load_all_profiles()` -- `SELECT ... FROM user_profiles`. Returns `Vec<StoredProfile>`.

## Table: friends

```sql
CREATE TABLE IF NOT EXISTS friends (
    peer_id      TEXT PRIMARY KEY,
    status       TEXT NOT NULL,
    direction    TEXT NOT NULL DEFAULT '',
    requested_at INTEGER NOT NULL DEFAULT 0,
    updated_at   INTEGER NOT NULL DEFAULT 0
)
```

Status values: "accepted", "pending", "blocked", etc. Direction: "outgoing"/"incoming"/empty.

- `messages.rs:save_friend()` -- Upsert: `ON CONFLICT(peer_id) DO UPDATE SET status, direction, updated_at`.
- `messages.rs:remove_friend()` -- `DELETE FROM friends WHERE peer_id = ?1`.
- `messages.rs:load_friends()` -- Optional status filter. `ORDER BY updated_at DESC`. Returns `Vec<(peer_id, status, direction, requested_at, updated_at)>`.
- `messages.rs:get_friend_status()` -- `SELECT status FROM friends WHERE peer_id = ?1`. Returns `Option<String>`.

## Table: app_settings (Key-Value Store)

```sql
CREATE TABLE IF NOT EXISTS app_settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
)
```

General-purpose KV store for app settings (license key, layout mode, last-seen message IDs, etc.).

- `messages.rs:save_setting()` -- `INSERT ... ON CONFLICT(key) DO UPDATE SET value`.
- `messages.rs:load_setting()` -- `SELECT value FROM app_settings WHERE key = ?1`. Returns `Option<String>`.

## Table: verified_peers (RAT Files Identity Verification)

```sql
CREATE TABLE IF NOT EXISTS verified_peers (
    peer_id     TEXT PRIMARY KEY,
    verified_at INTEGER NOT NULL
)
```

Tracks which peers have had their Ed25519 fingerprint manually verified.

- `messages.rs:set_peer_verified()` -- Upsert with current timestamp.
- `messages.rs:remove_peer_verified()` -- `DELETE FROM verified_peers WHERE peer_id = ?1`.
- `messages.rs:is_peer_verified()` -- `SELECT COUNT(*) ... WHERE peer_id = ?1`. Returns bool.
- `messages.rs:get_verified_peers()` -- `SELECT peer_id, verified_at ... ORDER BY verified_at DESC`. Returns `Vec<(String, i64)>`.

## Table: files (File Metadata)

```sql
CREATE TABLE IF NOT EXISTS files (
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
    context_type    TEXT NOT NULL,    -- "dm" or "channel"
    context_id      TEXT NOT NULL,    -- peer_id for DM, "server_id:channel_id" for channel
    sender_id       TEXT NOT NULL,
    is_mine         INTEGER NOT NULL DEFAULT 0,
    created_at      INTEGER NOT NULL,
    completed_at    INTEGER,
    disk_path       TEXT,
    hidden_at       INTEGER
    -- Migrated columns:
    --   video_thumb_json TEXT   -- JSON VideoThumbRef for vault video thumbnails
    --   expired_at INTEGER     -- non-null = file data deleted from disk by retention timer
    --   content_id TEXT        -- vault content_id link
)
```

Indexes:
- `idx_files_message ON files (message_id)`
- `idx_files_context ON files (context_type, context_id)`

### File Operations

- `messages.rs:insert_file_metadata()` -- `INSERT OR IGNORE INTO files`. Serializes `VideoThumbRef` to JSON if present.
- `messages.rs:mark_chunk_received()` -- `INSERT OR IGNORE INTO file_chunks`, then `UPDATE files SET chunks_received = (SELECT COUNT(*) FROM file_chunks WHERE file_id = ?1)`. Returns new count.
- `messages.rs:mark_file_complete()` -- `UPDATE files SET completed_at = now, disk_path = ?`.
- `messages.rs:get_file_metadata()` -- Full SELECT by file_id. Deserializes `video_thumb_json` via `parse_video_thumb_json()`. Returns `Option<StoredFile>`.
- `messages.rs:get_files_for_message()` -- `SELECT ... FROM files WHERE message_id = ?1`. Returns `Vec<StoredFile>`.
- `messages.rs:get_incomplete_files()` -- `WHERE completed_at IS NULL AND hidden_at IS NULL`. For sync resume.
- `messages.rs:get_missing_chunks()` -- Loads file metadata, queries `file_chunks` for received indices, computes missing set `0..chunk_count` minus received. Returns `Vec<u32>`.
- `messages.rs:get_missing_file_ids()` -- UNION query across `channel_messages` and `messages`: finds `file_id` values not in `files WHERE completed_at IS NOT NULL`. Used post-sync to identify files needing download.
- `messages.rs:get_missing_image_file_ids_for_server()` -- `JOIN files f ON cm.file_id = f.file_id WHERE cm.server_id = ?1 AND f.is_image = 1 AND f.completed_at IS NULL`. For late-joiner image sync in 6+ member servers (non-image files use vault).
- `messages.rs:reset_stale_file_paths()` -- Scans all completed files with `disk_path IS NOT NULL`, checks `Path::exists()` on each. Resets stale entries: `SET disk_path = NULL, completed_at = NULL`. Returns count.
- `messages.rs:total_file_storage_for_server()` -- `SELECT COALESCE(SUM(size_bytes), 0) FROM files WHERE context_type = 'channel' AND context_id LIKE '{server_id}:%' AND completed_at IS NOT NULL`.
- `messages.rs:total_message_storage_for_server()` -- `SELECT COALESCE(SUM(LENGTH(text)), 0) FROM channel_messages WHERE server_id = ?1`.
- `messages.rs:set_file_content_id()` -- `UPDATE files SET content_id = ?1 WHERE message_id = ?2`. Links vault content_id.
- `messages.rs:get_content_id_for_file()` -- `SELECT content_id FROM files WHERE file_id = ?1`. Returns `Option<String>`.

## Table: file_chunks (Per-Chunk Receipt Tracking)

```sql
CREATE TABLE IF NOT EXISTS file_chunks (
    file_id     TEXT    NOT NULL,
    chunk_index INTEGER NOT NULL,
    received_at INTEGER NOT NULL,
    PRIMARY KEY (file_id, chunk_index)
)
```

Tracks individual chunk receipt for resumable file transfers. Used by `mark_chunk_received()` and `get_missing_chunks()`.

## Table: shares (Hollow Share / Phase 7A)

```sql
CREATE TABLE IF NOT EXISTS shares (
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
    -- Migrated columns:
    --   save_dir TEXT       (also in CREATE, migration is idempotent)
    --   server_id TEXT
    --   context_type TEXT
)
```

Indexes:
- `idx_shares_state ON shares(state)`
- `idx_shares_seeding ON shares(seeding)`

One row per share. `encryption_key` is the AES-256-GCM key from the share link. If the user loses the link and the row is deleted, the file is unrecoverable.

### Share Operations

- `messages.rs:upsert_share()` -- `INSERT OR REPLACE INTO shares`. Preserves existing `bytes_uploaded` and `completed_at` via COALESCE subselect on conflict.
- `messages.rs:set_share_save_dir()` -- `UPDATE shares SET save_dir = ?2 WHERE root_hash = ?1`.
- `messages.rs:load_share()` -- Full SELECT by root_hash. Uses `stored_share_from_row()` helper. Returns `Option<StoredShare>`.
- `messages.rs:load_shares()` -- `SELECT ... FROM shares ORDER BY created_at DESC`. Returns `Vec<StoredShare>`.
- `messages.rs:mark_share_complete()` -- `UPDATE shares SET state = 'completed', disk_path, completed_at`.
- `messages.rs:update_share_disk_path()` -- `UPDATE shares SET disk_path = ?2`.
- `messages.rs:set_share_state()` -- `UPDATE shares SET state = ?2`.
- `messages.rs:set_share_seeding()` -- `UPDATE shares SET seeding = ?2`.
- `messages.rs:add_share_bytes_uploaded()` -- `UPDATE shares SET bytes_uploaded = bytes_uploaded + ?2`. Atomic increment.
- `messages.rs:delete_share()` -- Deletes from both `share_chunks` and `shares` for the root_hash.

## Table: share_chunks (Download Resume Bitmap)

```sql
CREATE TABLE IF NOT EXISTS share_chunks (
    root_hash    TEXT PRIMARY KEY,
    bitmap_blob  BLOB NOT NULL,
    updated_at   INTEGER NOT NULL
)
```

Persists little-endian-packed bit bitmap for paused/resumed share downloads.

- `messages.rs:save_chunk_bitmap()` -- `INSERT OR REPLACE INTO share_chunks`.
- `messages.rs:load_chunk_bitmap()` -- `SELECT bitmap_blob WHERE root_hash = ?1`. Returns `Option<Vec<u8>>`.

## Stored Structs

### StoredMessage
Fields: id (i64), peer_id, text, is_mine (bool), timestamp (i64), signature (Option), public_key (Option), message_id (Option), edited_at (Option<i64>), hidden_at (Option<i64>), reply_to_mid (Option), file_id (Option), link_preview (Option<LinkPreviewRef> -- deserialized from link_preview_json column).

### StoredChannelMessage
Same as StoredMessage plus: server_id, channel_id, sender_id (replaces peer_id/is_mine split).

### StoredFile
Fields: file_id, file_name, file_ext, mime_type, size_bytes (u64), chunk_count (u32), chunks_received (u32), is_image (bool), width/height (Option<u32>), message_id (Option), context_type ("dm"/"channel"), context_id (peer_id or "server_id:channel_id"), sender_id, is_mine (bool), created_at (i64), completed_at (Option<i64>), disk_path (Option), hidden_at (Option<i64>), expired_at (Option<i64>), video_thumb (Option<VideoThumbRef> -- deserialized from video_thumb_json).

### StoredProfile
Fields: peer_id, display_name, status, about_me, updated_at (i64), avatar_bytes (Option<Vec<u8>>), banner_bytes (Option<Vec<u8>>).

### StoredShare
Fields: root_hash, file_name, file_ext, mime, total_size (u64), chunk_size (u32), chunk_count (u32), manifest_json, encryption_key (Vec<u8>), share_link, state, seeding (bool), disk_path (Option), bytes_uploaded (u64), created_at (i64), completed_at (Option<i64>), save_dir (Option), server_id (Option), context_type (Option).

## Pagination Patterns

Two patterns are used:

1. **LIMIT + reverse** -- `ORDER BY timestamp DESC LIMIT N`, then `messages.reverse()` in Rust. Used by `load_for_peer()`, `load_channel_messages()`, `search_channel_messages()`, `search_dm_messages()`. Gets the N most recent messages but presents them oldest-first.

2. **Since-timestamp** -- `WHERE timestamp > ?` or `WHERE timestamp >= ?` with `ORDER BY timestamp ASC LIMIT N`. Used by sync methods (`get_channel_messages_since()`, `get_dm_messages_since()`). Channel sync uses `>` (exclusive), DM sync uses `>=` (inclusive) -- both rely on INSERT OR IGNORE for dedup at the receiving end.

3. **Unread counting via autoincrement threshold** -- `count_unread_dm()` and `count_unread_channel()` find the autoincrement `id` of the last-seen `message_id`, then count rows with `id > threshold`. This avoids timestamp comparison issues and correctly handles same-millisecond messages.

## Migration Strategy

All schema migrations use `ALTER TABLE ADD COLUMN` wrapped in `.unwrap_or(())` -- the operation silently fails if the column already exists. This is safe because SQLite only supports adding nullable columns with ALTER TABLE. All migrated columns are nullable (no NOT NULL constraint).

Tables created in `MessageStore::open()` constructor order:
1. messages (base schema)
2. olm_account
3. olm_sessions
4. channel_messages (with dedup migration)
5. servers
6. crdt_ops
7. hlc_state
8. Signature columns migration (messages, channel_messages)
9. DM dedup index migration
10. user_profiles
11. message_id + edited_at migration
12. message_edits
13. hidden_at migration
14. message_deletions
15. reply_to_mid migration
16. message_reactions
17. reaction_removals
18. friends
19. app_settings
20. mls_identity
21. files + file_chunks
22. video_thumb_json, expired_at, content_id migrations on files
23. file_id migration on messages/channel_messages
24. link_preview_json migration on messages/channel_messages
25. avatar/banner migration on user_profiles
26. verified_peers
27. shares + share_chunks

---

## Identity System: NativeKeypair

Source: `rust/hollow_core/src/identity/native_identity.rs`

`NativeKeypair` wraps `ed25519_dalek::SigningKey` with a cached `cached_peer_id: String` field. PeerId is computed once at construction via `compute_peer_id()` and returned by `peer_id()` as a clone. Replaces the removed libp2p identity module while producing identical PeerId strings and signatures.

### Construction

- `native_identity.rs:NativeKeypair::from_mnemonic(mnemonic)` -- Takes a `bip39::Mnemonic`, calls `mnemonic.to_seed("")` (empty passphrase), uses first 32 bytes as the Ed25519 secret key.
- `native_identity.rs:NativeKeypair::from_secret_bytes(bytes)` -- Direct construction from raw 32-byte secret.
- `native_identity.rs:NativeKeypair::from_protobuf_encoding(bytes)` -- Decodes libp2p-compatible protobuf format. Expected 68 bytes: `[0x08, 0x01, 0x12, 0x40, secret(32), public(32)]`. Verifies derived public key matches the encoded one.

### Serialization

- `native_identity.rs:NativeKeypair::to_protobuf_encoding()` -- Encodes to 68-byte libp2p-compatible protobuf: `[0x08, 0x01, 0x12, 0x40, secret(32), public(32)]`. Returns `Result<Vec<u8>, String>` (never fails in practice).
- `native_identity.rs:NativeKeypair::public_key_protobuf()` -- 36-byte format: `[0x08, 0x01, 0x12, 0x20, public(32)]`. Used for signaling registration and WS auth.

### PeerId Derivation

`native_identity.rs:NativeKeypair::peer_id()` -- Returns the cached `cached_peer_id: String` (clone). The PeerId is computed once at construction by `compute_peer_id()`:
1. Get 36-byte public key protobuf: `[0x08, 0x01, 0x12, 0x20, public(32)]`
2. Wrap in identity multihash: `[0x00, 0x24, ...36_bytes]` (code 0x00 = identity, 0x24 = length 36)
3. Base58 encode with Bitcoin alphabet

The identity multihash is used because the 36-byte protobuf-encoded public key is <= 42 bytes (the libp2p inline threshold).

### Signing and Verification

- `native_identity.rs:NativeKeypair::sign(msg)` -- Ed25519 sign. Returns 64-byte signature as `Vec<u8>`.
- `native_identity.rs:NativeKeypair::verify_peer_signature(pubkey_protobuf, signature, payload)` -- Static method. Takes 36-byte protobuf public key, 64-byte signature, payload bytes. Extracts raw 32-byte pubkey from protobuf, constructs `VerifyingKey`, calls `verify()`. Returns `Result<bool, String>`.

### Raw Key Access

- `native_identity.rs:NativeKeypair::public_key_bytes()` -- Raw 32-byte public key.
- `native_identity.rs:NativeKeypair::secret_key_bytes()` -- Raw 32-byte secret key.

### Test Coverage

Tests verify:
- PeerId derivation matches known-good libp2p value for "abandon...about" mnemonic: `12D3KooWP7CwQswqLKZbwvYd9wrEynnL9F2aKVP1X9huNASBTuqj`
- Protobuf round-trip (encode -> decode -> same keys/PeerId)
- Loading protobuf-encoded keypair files (backward compat)
- Sign + verify cycle (valid signature passes, tampered message fails)
- Public key protobuf format (36 bytes, correct header)

- `native_identity.rs:NativeKeypair::peer_id_from_pubkey_protobuf(pubkey)` -- Static. Derives a `12D3KooW…` PeerId from a 36-byte public-key protobuf alone (no private key). Used to bind a signature's pubkey to a claimed peer_id (message verify + multi-device device-list verify). Returns `Option<String>`.

---

## Multi-Device Foundation (Phase 6 — Steps 1–8 LIVE, incl. revocation + Devices panel)

Sources: `identity/device_key.rs`, `node/resolver.rs`, `node/crypto_handler.rs` (device-list helpers + publish/ingest), `node/social.rs` (profile publish), `node/swarm.rs` (spawn_node key routing + ingest call sites + DM attribution), `node/types.rs` (`SignedDeviceList`), `storage/messages.rs` (`device_lists`/`device_links`), `api/network.rs` (`identity_for`/`get_device_links`), `lib/src/core/providers/device_link_provider.dart`.

The multi-device epic gives each physical device its OWN random Ed25519 key while the mnemonic-derived MASTER key stays the cross-device identity. **Step 1 (Tasks 1-9) is fully code-complete and live-verified** (host + phone + VM, same mnemonic → distinct device peer_ids, simultaneous relay sockets, profile synced, no self-friend-request, single-device unchanged). Behavior-neutral for single-device installs via the migration keystone. Steps 2-6 (UI collapse, Olm fan-out, QR snapshot, backfill, MLS leaves) remain. Authoritative status: `reports/MULTI_DEVICE_IMPLEMENTATION_TRACKER.md` + memory `project_multi_device_sync`.

### Key-routing architecture (LOCKED — the load-bearing decision)
The **device key drives the WS relay auth + the signaling register ONLY** (so each physical device gets its own distinct relay socket). EVERYTHING else stays MASTER: the event loop's `local_peer_str`, `bundle_keypair`, MLS/server membership, permission lookups, message-content signing, and the DB passphrase. The rooms a device joins are MASTER-derived (`inbox:{master}`, `dm_room_code` resolves both ends to masters, `server_id`), so a device authenticates as itself yet sits in its identity's rooms; the relay reports DEVICE ids in `RoomMembers`/`PeerJoined`, and the resolver maps them back to masters. **Consequence:** the dozens of `member == &local_peer { continue }` self-skips and `has_permission(&local_peer, …)` lookups need NO resolver call (both sides are masters) — which is why Step 7 is small. See the `node/resolver.rs` module header for the full rationale.

- **`spawn_node(native_keypair, device_keypair, …)`** (`swarm.rs`): master drives `run_event_loop` (returns the MASTER peer_id to Dart as "my peer id"); device drives `ws_client` auth + `spawn_signaling_task`. `run_event_loop` also takes `device_peer_id` and exposes `master_keypair`/`master_peer_str` aliases.

### Components
- **Per-device key (`device_key.rs`):** `load_or_create_device_keypair(master)` loads/creates `identity.device` (sibling of `identity.key`, same SESSION_KEY encryption). Existing install with no device file → SEEDS FROM MASTER (migration keystone: device peer_id == master == legacy peer_id, no orphaning). Brand-new/restore → fresh random key (distinct peer_id). **CRITICAL for testing: a true 2nd device must RESTORE-FROM-MNEMONIC on a clean install — copying the data dir clones `identity.device` and reproduces the OLD same-peer_id collision.** `rewrite_device_key_protection()` keeps the device file's at-rest protection in lockstep with the 6 identity-protection FFIs.
- **Signed device list (`crypto_handler.rs`):** `SignedDeviceList { master_pubkey_b64, master_peer_id, devices (sorted), revoked (sorted, Step 7 tombstones), version, sig_b64 }`. `build_signed_device_list()` signs `hollow-devices:{master_peer_id}:{version}:{sorted_devices_csv}:{sorted_revoked_csv}` (the trailing revoked segment is present even when empty; a revoked id is stripped from `devices`); `verify_device_list()` checks the pubkey→master_peer_id binding + signature over BOTH sorted arrays. Rides both `ProfileUpdate` wire variants as `#[serde(default)] device_list: Option<SignedDeviceList>`. Monotonic `version` = replay protection AND tombstone authority (max-version-wins: a higher-version list may add AND un-revoke; a replayed lower-version list can never shrink the revoked set).
- **Publish (`crypto_handler::build_local_device_list`):** reads our persisted device set+version, ensures THIS device is in the set (bumps version if it had to add it), re-signs with the master key, persists monotonically (`save_device_list`), and `seed_self`s the resolver. Called from `social::handle_update_profile` + `send_own_profile_to_peer` (both populate `device_list:` on the outbound profile). On DB error returns `None` → profile sent listless (back-compat).
- **Ingest (`crypto_handler::ingest_device_list`):** verifies signature; a list for OUR OWN master (a sibling holding the same mnemonic) is delegated to `ingest_sibling_device_list` (UNION-merge, never reject-on-stale — two devices each seed v1, so a naive replay guard drops the 2nd). A friend's list is UNION-merged MINUS the tombstoned `revoked` set into whatever we already hold, keeping the highest version. Persists, `resolver::forget_many(revoked)` then `update_many`, emits `DeviceListUpdated`. **Returns `IngestOutcome { our_devices_grew, newly_revoked }`** (was a bare `bool`): `our_devices_grew` → caller re-announces our profile so friends converge; `newly_revoked` → caller (which holds `&mut olm`/`&mut mls`) runs `swarm::enforce_device_revocations` (drop Olm session + erase persisted session + coordinator-only single-leaf MLS removal via `pending_mls_removals`). Called from both `ProfileUpdate` receive handlers (envelope + bare `HavenMessage`).
- **Revocation (Step 7 — ✅ LIVE 2026-06-18):** `NodeCommand::RevokeDevice { device_peer_id }` (FFI `revoke_device`) → `sync_handler::handle_revoke_device` → `crypto_handler::revoke_own_device` (bumps version, removes target from `devices`, adds to `revoked`, re-signs, persists, `resolver::forget` + `mark_revoked`). Manual-only (any device-you-control revokes another; all devices hold the master key so there's no "promotion"). Guards: self-revoke refused; own-device-only (`resolve(target)==our master`). The new list is sent **TO THE REVOKED DEVICE FIRST** (before the relay drops it from rooms via MLS removal), then to all other room peers — so the revoked device's own ingest fires `NetworkEvent::SelfRevoked` → Dart `event_provider._selfNuke()` wipes the data dir (`stash_pending_wipe` FIRST, then a best-effort `overlayState` toast — never the plain `HollowToast.show(ctx)` which throws from a navigator-key context) + relaunches to a clean Welcome. **Phantom-chat guard:** `resolver::mark_revoked`/`is_revoked` (process-global set, cleared on `clear_all`) lets the DM + typing receive paths in swarm.rs DROP messages from a revoked-but-still-alive device until it self-nukes/disconnects — without it, after `forget` the lingering device's id resolves-to-self and spawns a standalone "unknown peer" conversation. See memory `feedback_ghost_device_fanout`.
- **Sibling sync + presence collapse (Step 2/2.5 — ✅ live-verified 2026-06-14):** two devices of one identity meet in the shared `inbox:{master}` room. A peer joining our OWN inbox is, by definition, our sibling (the **inbox-proof**, `swarm.rs` PeerJoined) — used directly instead of `same_identity` (which needs the device list already exchanged, a chicken-and-egg). On the inbox-proof we: (1) **merge the proven sibling's device id into our own list** via `crypto_handler::merge_sibling_device_id` (union + re-sign + bump + persist + `seed_self`, returns "grew") — this does NOT require a ProfileUpdate, fixing the bug where a profile-less fresh device never got merged; (2) on a grow, **re-announce our profile (carrying BOTH devices) to every room peer** so a friend already in our DM room converges on the full set while we're online; (3) **push our friend list** (`FriendListSync`) + **pull theirs** (`FriendListRequest`) so a fresh device learns the identity's friends and joins their DM rooms (presence flows both ways). The friend-list-backfill announce builds the device-list ProfileUpdate **even with no local profile** (empty profile fields + populated `device_list`) — device-list convergence must never depend on profile content existing. Proof logs: AL `Ingested device list … (v2, 2 devices, +2 new)`; substitute device keeps the identity online when the original quits. `reset_device_lists()` FFI clears `device_lists`+`device_links`+resolver for a clean test slate (ghosts accumulate because union never removes — Step 7).
- **Resolver wiring (Step 8):** `dm_room_code(a,b)` resolves BOTH ends to masters (one DM thread spans all devices — covers all 8 call sites at once). DM receive attributes to the sender's master (`convo_peer = resolve(peer_str)`) for the thread key, DB key, and signature context (signature is master-keyed, so verify expects the master signer). `is_mine` (×3, channel + sync + message_ops) via `same_identity`. Friend-request self-guards (send + receive) via `same_identity`. DM edit/delete/reaction conversation-key + reactor → master. `peer_is_reachable` made resolver-aware (a master is reachable if any of its devices is in a room; fast exact-match path first, no resolver cost single-device).
- **DB (`messages.rs`):** `device_lists(master_peer_id PK, json, version, updated_at)` + `device_links(device_peer_id PK, master_peer_id)` reverse index. `save_device_list()` (version-gated upsert + link rebuild), `device_list_version()`, `load_device_list()` (read our own back), `get_all_device_links()` (resolver warmup).
- **Resolver (`node/resolver.rs`):** process-global `OnceLock<RwLock<HashMap>>` (links) + a second `OnceLock<RwLock<HashSet>>` (revoked, Step 7). `resolve(peer_id)` → master, **unknown → itself** (backward-compat). `same_identity(a,b)` replaces `a == b` self/friend checks. `seed_self()`/`warm_from_links()` at startup (BEFORE the event loop runs — hazard R4), `update()`/`update_many()` on ingest, `all_links()` for the FFI. **`forget`/`forget_many`** (Step 7) remove a revoked device→master link (the map is otherwise insert-only — without this a revoked device keeps resolving to its master until restart). **`mark_revoked`/`is_revoked`** track revoked ids for the receive-path phantom-chat guard; `clear_all`/`clear_for_test` clear both maps. Lock-poison-safe (degrades to identity-passthrough).
- **Dart attribution (Step 9):** FFI `identity_for(peer_id) -> String` + `get_device_links() -> Vec<DeviceLink>` (`api/network.rs`). `device_link_provider.dart` mirrors the resolver into a `Map<device→master>` with `identityOf()`/`sameIdentity()`; warmed on node start + refreshed on `DeviceListUpdated` (both in `event_provider.dart`). On single-device the map is empty → no-op.

### Profile attribution (multi-device — ✅ live-verified both sides, real-time)
Profiles are per-person state a friend reads, so — like the device list — they MUST be keyed by MASTER, not the raw sender DEVICE id. `social::save_incoming_profile(sender, …)` resolves to `resolver::resolve(sender)` = master and persists there; both `ProfileUpdate` receive handlers (bare `HavenMessage` in swarm.rs + MLS-envelope in social.rs) use it, and the `ProfileUpdated` event + server-member rename + Dart cache invalidation (`reloadProfile`/`avatarProvider.invalidate`/`bannerProvider`) all key on the master. **Empty-profile guard:** a freshly-imported device holds the master KEY but none of the master's profile CONTENT, so it broadcasts a blank — `save_incoming_profile` SKIPS the write when the incoming display_name is empty AND a populated master profile already exists (never blank a good row). **Sibling profile sync:** in the inbox-proof block, a device whose own identity profile is empty/absent sends its sibling a `ProfileRequest`; the reply resolves to its own master (== local_peer_str) so it ADOPTS the real name/avatar and can broadcast it onward. Single-device: master == sender → no-op rename. General rule: any per-person state a friend reads is keyed by MASTER, and a content-less device must never overwrite populated master state with blanks (same shape as the device-list merge).

### Current-state limits (each owned by a LATER step, NOT bugs)
Presence collapse AND profile (name/avatar) now WORK — a friend sees ONE online dot with the correct profile, and the identity stays online with the right name/avatar via any device, syncing in real time. **NOT an Olm failure** (sessions are confirmed bidirectional in all logs). Step 3 (Olm sender-side DM fan-out) and Step 4 (device linking) are DONE+live. Remaining: Step 5 (offline backfill), Step 6 (MLS per-device leaves — servers still single-leaf).

### Device linking + snapshot sync (Step 4 — ✅ LIVE-VERIFIED 2026-06-15, Pixel master → VM subdevice)
Sources: `api/storage.rs` (`export_backup_bytes`/`import_backup_bytes`/`build_snapshot_bytes`/`stash_pending_link`/`has_pending_link`/`import_pending_link`/`stash_pending_wipe`/`has_pending_wipe`/`perform_pending_wipe`), `node/link_handler.rs` (orchestration), `node/ws_stream_transfer.rs` (`StreamKind::LinkSnapshot`), `node/file_handler.rs` (completion→stash+ack), `relay-uws/src/ws_handler.cpp` (`link_code` verbs), `lib/src/core/providers/device_link_sync_provider.dart`, `lib/src/ui/dialogs/device_link_dialog.dart`, `lib/src/ui/shell/hollow_shell.dart` (`_bootstrap` wipe/import + go-back relaunch).

A new (empty) device pulls the FULL identity+DB from an online (populated) one via a **6-char code** (QR was cut — codes only). **THE LOAD-BEARING DESIGN: the transfer REUSES the `.hollow` backup pipeline end-to-end and imports at NEXT LAUNCH (pre-node-start), never in-place.**

- **Pairing:** populated device claims a 6-char code on the relay (a clone of the temporary-nickname RAM map — `linkcode_to_peer`/`peer_to_linkcode`/`linkcode_expiry`, 5-min TTL, one-shot consume) and joins a `link:{code}` rendezvous room. The empty device (a THROWAWAY identity, created just to get a relay socket) resolves the code, joins `link:{code}`, and sends `HavenMessage::LinkSnapshotRequest`. Populated device shows a Confirm (`SiblingLinkAvailable` event → `device_link_dialog`), then `AcceptLinkPush`.
- **Transfer:** sender `storage::export_backup_bytes(code, vault, files)` produces the EXACT `.hollow` bytes (`[HOLLOW][salt:16][nonce:12][AES-256-GCM]`, Argon2id key from the passphrase = the link CODE) and streams them as `StreamKind::LinkSnapshot` (reuses the chunked-binary `ws_stream_transfer` + real-byte `stream_progress()` bar). `LinkSnapshotKey` carries only the `link_id` (no AES key — the receiver already knows the code). The receiver's typed code lives in a `link_handler` process-global (`set_my_link_code`/`my_link_code`) so the deep `LinkSnapshotKey` handler in `handle_incoming_request` can read it.
- **Import (the fix that made it work):** the receiver's completion arm calls `storage::stash_pending_link(blob, code)` → writes `pending_link.hollow` + `pending_link.code` to the data dir → sends a `HavenMessage::LinkSnapshotAck { link_id }` back to the sender → emits `LinkComplete` → the UI auto-restarts (~1.8s). On NEXT launch `_bootstrap` (FIRST, before `hasIdentity()`) runs `has_pending_wipe()`→`perform_pending_wipe()` then `has_pending_link()` → `import_pending_link()`, which deletes the throwaway identity files then `import_backup_bytes(blob, code)` — the IDENTICAL path as a manual "Restore from backup". Then bootstrap proceeds as a normal restored launch.
- **Push completion is RECEIVER-ACKED.** The sender used to emit `LinkPushComplete` the instant `ws_stream_send_bytes` returned — but that only means chunks are QUEUED into the local WS channel, not received, so it flashed "Data sent" while the receiver was just starting. Now the sender stays on its "Sending your data" spinner and only flips to `pushDone` when the `LinkSnapshotAck` arrives (dispatch arm in `swarm.rs` → `LinkPushComplete`). The receiver sends the ack right after a successful stash, BEFORE its own `LinkComplete`, so it flushes within the pre-restart window. ALSO: `device_link_sync_provider.onDisconnected()` preserves in-flight `waiting/receiving/importing/sending` phases across a transient relay blip (the link handshake churns the connection) — clearing them was the "dialog reverted to the enter-code screen mid-link" bug.
- **Enter-code error/back nav + go-back data wipe:** `_failed` view on the enter-code flow shows "Try again" (`reset()`→idle re-renders enter-code in place, recoverable) + "Back" (pops `true`→Welcome). The shell's go-back path does NOT `delete_identity()` in-process (the live node holds open SQLCipher handles; on Windows `remove_file` on the open `messages.db` fails → it survives encrypted with the throwaway passphrase → next identity can't open it → infinite loading). Instead it `stash_pending_wipe()` (writes `pending_wipe.marker`) + relaunches (spawn fresh process, not bare `exit(0)`); `_bootstrap` runs `perform_pending_wipe()` BEFORE node start (no open handles), removing every data-dir entry except the marker (removed last) + `*.lock`.
- **Why NOT in-place:** the original `import_snapshot_bytes` ran while the node was LIVE on the throwaway → fought the open SQLCipher connection + its WAL (checkpointing back over the import) + a protection-mismatched leftover throwaway `identity.device` ("Device key is encrypted" → `load_or_create_identity` throws → "Loading… forever"). `import_backup` works ONLY because it runs pre-node-start with no live DB/identity. `export_backup`/`import_backup` now delegate to the `_bytes` cores. See memory `feedback_link_import_identity_device`.
- **Mnemonic path (B6):** an empty mnemonic-imported device auto-requests a snapshot from an online sibling on inbox-proof; passphrase = the shared master peer_id (both siblings know it).
- **Servers caveat:** the snapshot copies server membership + history ROWS (they appear), but live server messaging needs Step 6 (MLS per-device leaves). UI labels it "Servers & history copied", not "synced".
- **First-sibling-DM mirror (RESOLVED 2026-06-17):** the FIRST DM a freshly-linked device sent to a friend didn't mirror to its sibling. Root cause was NOT fan-out targeting (the echo WAS dispatched) but an Olm ratchet desync during the link handshake — the first DM encrypted on a locally-"confirmed" but peer-dead session and the online send branch never queued for retry. Fixed by also queuing in the online branch (see `rust_message_ops.md` fan-out). See memory `feedback_dm_online_branch_retry_queue`.

---

## Identity System: keys.rs (Key Management)

Source: `rust/hollow_core/src/identity/keys.rs`, `identity/encryption.rs`, `identity/platform_keystore.rs`

### Data Dir

`keys.rs:data_dir()` -- Resolves the Hollow data directory:
1. Checks `DATA_DIR_OVERRIDE` OnceLock (set by `set_data_dir()` FFI from Dart on Android/iOS)
2. Checks `HOLLOW_DATA_DIR` env var (for multi-instance testing)
3. Falls back to `dirs::data_dir()` / `hollow` (= `%APPDATA%/hollow` on Windows)
4. Creates directory if missing via `fs::create_dir_all()`

Keypair stored at `{data_dir}/identity.key`.

### IdentityData

Struct returned by all identity functions: `{ keypair: NativeKeypair, peer_id: String, mnemonic: Option<String> }`. Mnemonic is only `Some` on generation/restore, `None` on load (one-time backup).

### Identity Lifecycle

- `keys.rs:generate_new_identity()` -- Generates 32 bytes of entropy via `getrandom`, creates 24-word BIP-39 mnemonic (256 bits), derives keypair, saves to disk (encrypted if session key active). Returns IdentityData with mnemonic.
- `keys.rs:restore_identity_from_mnemonic(phrase)` -- Parses mnemonic phrase, derives keypair, saves to disk. Returns IdentityData with mnemonic.
- `keys.rs:load_or_create_identity()` -- Checks if `identity.key` exists. If yes: detects format (plaintext protobuf or HKEYV1 encrypted), decrypts via session key if encrypted, returns without mnemonic. If no: calls `generate_new_identity()`.
- `keys.rs:save_keypair(keypair)` -- Internal helper. Encodes keypair to protobuf. If session wrapping key is active, re-encrypts as HKEYV1 envelope preserving current flags. Otherwise writes plaintext.

### Storage Format

Two formats detected by `encryption::detect_format()`:
1. **Plaintext (legacy):** 68-byte protobuf (`[0x08, 0x01, 0x12, 0x40, secret(32), public(32)]`). Loaded directly. Plaintext identities are never silently auto-encrypted.
2. **Encrypted (HKEYV1):** 119-byte envelope: `[magic:6 "HKEYV1"][flags:1][salt:16][nonce:12][ciphertext:84]`. Flags: `0x01`=password only (ask on launch), `0x02`=OS keychain only, `0x03`=password + keychain (password encrypts, keychain caches key for silent unlock).

### At-Rest Protection (encryption.rs + platform_keystore.rs)

**Session wrapping key:** Held in `OnceLock<Mutex<Option<[u8; 32]>>>` static. Set by `unlock_identity()` FFI, cleared by `lock_identity()`. All `load_or_create_identity()` calls use it transparently.

**Password protection (flags=0x01 or 0x03):** Argon2id (memory=64MB, iterations=3, parallelism=1) derives 32-byte wrapping key from password + random 16-byte salt. AES-256-GCM encrypts the 68-byte protobuf. When `require_on_launch=false` (flags=0x03), the derived key is also stored in OS keychain for silent unlock — identity file is encrypted but app opens normally on the same device.

**OS Keychain / Device Protection (flags=0x02):** Random 32-byte wrapping key stored in platform credential store. Standalone option when no password is set. `flags=0x02`.

**Windows dual storage:** `platform_keystore.rs` uses Windows Credential Manager (`CredWriteW`/`CredReadW` via `windows-sys`) as primary, DPAPI blob (`identity.dpapi`) as fallback. `store_key()` writes to both. `retrieve_key()` tries Credential Manager first, falls back to DPAPI, auto-migrates on success. macOS uses `security-framework` Keychain. Linux: not available.

**Unlock logic (flags=0x03):** `unlock_identity()` tries OS keychain first for silent unlock. If keychain key is missing or stale, falls back to password prompt. This ensures the toggle works: password always works as recovery even if device credentials are lost.

**FFI functions (api/identity.rs):** `unlock_identity(password?)`, `lock_identity()`, `enable_password_protection(password, require_on_launch)`, `change_password(old, new)`, `remove_password_protection(password)`, `set_require_password_on_launch(require)`, `enable_os_keychain_protection()`, `disable_os_keychain_protection()`, `get_identity_protection_status()`, `is_identity_unlocked()`.

**Dart bootstrap flow:** `_bootstrap()` in `hollow_shell.dart` calls `_unlockIdentity()` before `identityProvider.load()`. Silent unlock for plaintext/keychain/flags=0x03. Full-screen password dialog for flags=0x01. Full-screen recovery dialog for keychain failure (flags=0x02 on different machine).

**Settings UI:** Security tab in `user_settings_dialog.dart` has "APP LOCK" section (password + "Ask for password on launch" toggle) and "DEVICE PROTECTION" section (standalone keychain, hidden when password is active).

## Dedup indexes, unread counts, sync lookback (2026-07-03)

- **Content UNIQUE indexes are LEGACY-ONLY:** `idx_messages_dedup_legacy` + `idx_channel_msgs_unique_legacy` are partial (`WHERE message_id IS NULL`). The old full-table versions dropped DISTINCT identical-text same-millisecond messages via INSERT OR IGNORE. Rows with a mid dedup via `dm_message_exists`/`channel_message_exists` pre-checks at every insert site. The channel migration cleanup DELETE is scoped to `message_id IS NULL`.
- **Unread counts are millisecond-granular:** `count_unread_dm` / `count_unread_channel` / `count_unread_channel_with_mentions` count rows with `timestamp >` the seen row's timestamp (seen resolved by message_id; missing seen → 0). Never rowid (backfill rows have higher rowids), never the full order_us tuple (Dart marks seen from a ms-sorted `.last`). Regression test: `unread_counts_are_millisecond_granular`.
- **`SYNC_LOOKBACK_MS` (30 min):** `get_per_sender_timestamps` subtracts it (channels), and the 4 DM sync request sites subtract it from `get_latest_dm_timestamp[_any]` — a plain high-watermark permanently skipped messages missed while a newer one arrived. Overlap is mid-deduped on receipt.
- **`reconcile_dm_by_timestamp`** only matches rows with NULL mid OR (different mid AND different TEXT) — identical-text same-ms rows are distinct messages; grafting merged them permanently.
