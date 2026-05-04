# SQLCipher Database and Identity System

Source files: `rust/hollow_core/src/storage/messages.rs` (3154 lines), `rust/hollow_core/src/identity/native_identity.rs`, `rust/hollow_core/src/identity/keys.rs`

The `MessageStore` is the sole local persistence layer. It wraps a single `rusqlite::Connection` to an encrypted SQLCipher database. The `PRAGMA key` is set as hex before any table creation. All tables are created in `MessageStore::open()` with incremental `ALTER TABLE ADD COLUMN` migrations that silently ignore already-existing columns via `.unwrap_or(())`.

## MessageStore Initialization and Encryption

`messages.rs:MessageStore::open(path, passphrase)` opens the SQLCipher DB and sets the encryption key using hex format: `PRAGMA key = "x'{hex_passphrase}'"`. All `CREATE TABLE` and migration `ALTER TABLE` statements execute sequentially in this constructor. Returns `MessageStore { conn }`.

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
- `messages.rs:get_latest_dm_timestamp()` -- `SELECT MAX(timestamp) FROM messages WHERE peer_id = ?1 AND is_mine = 0`. Only received messages (is_mine=0) because sync sends the other peer's sent messages.
- `messages.rs:get_dm_messages_since()` -- `WHERE peer_id = ?1 AND timestamp >= ?2 AND is_mine = 1 ORDER BY timestamp ASC LIMIT ?3`. Returns our sent messages for sync. Uses `>=` (inclusive) with INSERT OR IGNORE dedup. Includes hidden messages (Rat Files evidence must sync).
- `messages.rs:search_dm_messages()` -- `WHERE peer_id = ?1 AND hidden_at IS NULL AND text LIKE ?2 ORDER BY id DESC LIMIT ?3`. LIKE pattern is `%query%`. Result reversed to chronological.
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
- `messages.rs:search_channel_messages()` -- `WHERE server_id = ?1 AND channel_id = ?2 AND hidden_at IS NULL AND text LIKE ?3 ORDER BY id DESC LIMIT ?4`. LIKE `%query%` pattern.
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

`NativeKeypair` is a thin wrapper around `ed25519_dalek::SigningKey`. It replaces the removed libp2p identity module while producing identical PeerId strings and signatures.

### Construction

- `native_identity.rs:NativeKeypair::from_mnemonic(mnemonic)` -- Takes a `bip39::Mnemonic`, calls `mnemonic.to_seed("")` (empty passphrase), uses first 32 bytes as the Ed25519 secret key.
- `native_identity.rs:NativeKeypair::from_secret_bytes(bytes)` -- Direct construction from raw 32-byte secret.
- `native_identity.rs:NativeKeypair::from_protobuf_encoding(bytes)` -- Decodes libp2p-compatible protobuf format. Expected 68 bytes: `[0x08, 0x01, 0x12, 0x40, secret(32), public(32)]`. Verifies derived public key matches the encoded one.

### Serialization

- `native_identity.rs:NativeKeypair::to_protobuf_encoding()` -- Encodes to 68-byte libp2p-compatible protobuf: `[0x08, 0x01, 0x12, 0x40, secret(32), public(32)]`. Returns `Result<Vec<u8>, String>` (never fails in practice).
- `native_identity.rs:NativeKeypair::public_key_protobuf()` -- 36-byte format: `[0x08, 0x01, 0x12, 0x20, public(32)]`. Used for signaling registration and WS auth.

### PeerId Derivation

`native_identity.rs:NativeKeypair::peer_id()` -- Produces libp2p-compatible `12D3KooW...` PeerId strings:
1. Get 36-byte `public_key_protobuf()`
2. Wrap in identity multihash: `[0x00, 0x24, ...36_bytes]` (code 0x00 = identity, 0x24 = length 36)
3. Base58 encode with Bitcoin alphabet

The identity multihash is used because the 36-byte protobuf-encoded public key is <= 42 bytes (the libp2p inline threshold). Keys > 42 bytes would use SHA-256 (code 0x12) instead.

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

---

## Identity System: keys.rs (Key Management)

Source: `rust/hollow_core/src/identity/keys.rs`

### Data Dir

`keys.rs:data_dir()` -- Resolves the Hollow data directory:
1. Checks `HOLLOW_DATA_DIR` env var first (for multi-instance testing)
2. Falls back to `dirs::data_dir()` / `hollow` (= `%APPDATA%/hollow` on Windows)
3. Creates directory if missing via `fs::create_dir_all()`

Keypair stored at `{data_dir}/identity.key` in protobuf encoding.

### IdentityData

Struct returned by all identity functions: `{ keypair: NativeKeypair, peer_id: String, mnemonic: Option<String> }`. Mnemonic is only `Some` on generation/restore, `None` on load (one-time backup).

### Identity Lifecycle

- `keys.rs:generate_new_identity()` -- Generates 32 bytes of entropy via `getrandom`, creates 24-word BIP-39 mnemonic (256 bits), derives keypair, saves to disk. Returns IdentityData with mnemonic.
- `keys.rs:restore_identity_from_mnemonic(phrase)` -- Parses mnemonic phrase, derives keypair, saves to disk. Returns IdentityData with mnemonic.
- `keys.rs:load_or_create_identity()` -- Checks if `identity.key` exists. If yes: loads via `NativeKeypair::from_protobuf_encoding()`, returns without mnemonic. If no: calls `generate_new_identity()`.
- `keys.rs:save_keypair(keypair)` -- Internal helper. Encodes keypair to protobuf, writes to `identity.key`.

### Storage Format

The keypair is persisted as 68-byte protobuf (libp2p-compatible) at `{data_dir}/identity.key`. This format was inherited from the libp2p era and maintained for backward compatibility -- existing users' identity files load without migration.
