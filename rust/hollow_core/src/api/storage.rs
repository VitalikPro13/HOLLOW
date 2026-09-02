use std::sync::{Mutex, OnceLock};

use flutter_rust_bridge::frb;

use crate::identity;
use crate::storage::MessageStore;

/// A message returned to Dart from the local database.
pub struct StoredMessage {
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
    /// Link preview for the first URL in this message (Phase 6.75).
    pub link_preview: Option<crate::api::network::LinkPreviewRef>,
}

// Global message store: None = not opened, Some = ready.
static STORE: OnceLock<Mutex<Option<MessageStore>>> = OnceLock::new();

pub(crate) fn get_store() -> &'static Mutex<Option<MessageStore>> {
    STORE.get_or_init(|| Mutex::new(None))
}

/// Install a store into the process-global slot so a unit test can drive the
/// `#[frb]` functions that read it. Pair every use with [`store_test_lock`] —
/// `STORE` is process-wide and `cargo test` runs test functions in parallel
/// threads (the `api::gifs::settings_lock` precedent).
#[cfg(test)]
pub(crate) fn set_test_store(ms: MessageStore) {
    let store = get_store();
    let mut guard = store.lock().unwrap_or_else(|e| e.into_inner());
    *guard = Some(ms);
}

/// Serializes every test that swaps the process-global store.
#[cfg(test)]
pub(crate) fn store_test_lock() -> std::sync::MutexGuard<'static, ()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|e| e.into_inner())
}

static CACHED_PEER_ID: OnceLock<String> = OnceLock::new();

pub(crate) fn get_peer_id() -> Result<&'static str, String> {
    if let Some(pid) = CACHED_PEER_ID.get() {
        return Ok(pid.as_str());
    }
    let id = identity::load_or_create_identity()?;
    Ok(CACHED_PEER_ID.get_or_init(|| id.peer_id))
}

pub(crate) fn derive_db_key_public() -> Result<String, String> {
    derive_db_key()
}

fn derive_db_key() -> Result<String, String> {
    let id = identity::load_or_create_identity()?;
    let proto = id
        .keypair
        .to_protobuf_encoding()
        .map_err(|e| format!("Failed to encode keypair: {e}"))?;
    // Use the first 32 bytes of the protobuf-encoded keypair as key material.
    // This is deterministic for the same identity.
    let key_bytes = &proto[..32.min(proto.len())];
    Ok(hex::encode(key_bytes))
}

/// Open the encrypted message database. Must be called after identity is loaded.
/// Typically called once at app start (after `load_or_create_identity`).
#[frb]
pub fn open_message_store() -> Result<(), String> {
    let store = get_store();
    let mut guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;

    if guard.is_some() {
        return Ok(()); // Already open.
    }

    let hollow_dir = crate::identity::data_dir()?;
    std::fs::create_dir_all(&hollow_dir)
        .map_err(|e| format!("Failed to create data dir: {e}"))?;
    let db_path = hollow_dir.join("messages.db");

    let passphrase = derive_db_key()?;
    let ms = MessageStore::open(
        db_path.to_str().ok_or("Invalid path encoding")?,
        &passphrase,
    )?;

    *guard = Some(ms);
    Ok(())
}

// REMOVED in 0.8.5: `save_message` / `save_channel_message`.
//
// Both were Dart-callable inserts that took an OPTIONAL signature and no
// message_id — i.e. they could write a row that no peer will ever accept
// through sync (`REQUIRE_SIGNED_BACKFILL`) and that the mid-based dedup cannot
// reconcile. Neither had a call site outside a `storage_service.dart` wrapper
// that nothing called. Message rows are written by the node's own send/receive
// paths, which sign; leaving an unsigned-insert entry point exported was a
// loaded gun with no user.

/// Load recent messages for a peer from the local database.
/// Returns messages ordered oldest-first, up to `limit`.
#[frb]
pub fn load_messages(peer_id: String, limit: i32) -> Result<Vec<StoredMessage>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;

    let rows = ms.load_for_peer(&peer_id, limit)?;
    Ok(rows
        .into_iter()
        .map(|r| StoredMessage {
            id: r.id,
            peer_id: r.peer_id,
            text: r.text,
            is_mine: r.is_mine,
            timestamp: r.timestamp,
            signature: r.signature,
            public_key: r.public_key,
            message_id: r.message_id,
            edited_at: r.edited_at,
            hidden_at: r.hidden_at,
            reply_to_mid: r.reply_to_mid,
            file_id: r.file_id,
            link_preview: r.link_preview.map(Into::into),
        })
        .collect())
}

/// Load ALL DM messages for a peer, including soft-deleted (hidden_at set).
/// No limit, ordered oldest-first. Used by the archive "My Data" viewer.
#[frb]
pub fn load_all_dm_messages(peer_id: String) -> Result<Vec<StoredMessage>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;

    let rows = ms.load_all_dm_messages(&peer_id)?;
    Ok(rows
        .into_iter()
        .map(|r| StoredMessage {
            id: r.id,
            peer_id: r.peer_id,
            text: r.text,
            is_mine: r.is_mine,
            timestamp: r.timestamp,
            signature: r.signature,
            public_key: r.public_key,
            message_id: r.message_id,
            edited_at: r.edited_at,
            hidden_at: r.hidden_at,
            reply_to_mid: r.reply_to_mid,
            file_id: r.file_id,
            link_preview: r.link_preview.map(Into::into),
        })
        .collect())
}

/// Load ALL channel messages, including soft-deleted (hidden_at set).
/// No limit, ordered oldest-first. Used by the archive "My Data" viewer.
#[frb]
pub fn load_all_channel_messages(server_id: String, channel_id: String) -> Result<Vec<StoredChannelMessage>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;

    let rows = ms.load_all_channel_messages(&server_id, &channel_id)?;
    Ok(rows
        .into_iter()
        .map(|r| StoredChannelMessage {
            id: r.id,
            server_id: r.server_id,
            channel_id: r.channel_id,
            sender_id: r.sender_id,
            text: r.text,
            is_mine: r.is_mine,
            timestamp: r.timestamp,
            signature: r.signature,
            public_key: r.public_key,
            message_id: r.message_id,
            edited_at: r.edited_at,
            hidden_at: r.hidden_at,
            reply_to_mid: r.reply_to_mid,
            file_id: r.file_id,
            link_preview: r.link_preview.map(Into::into),
        })
        .collect())
}

/// Load edit history for a batch of message IDs.
/// Returns a flat list of edits sorted by edited_at ASC.
#[frb]
pub fn load_message_edits(message_ids: Vec<String>) -> Result<Vec<StoredMessageEdit>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;

    let edits_map = ms.load_edits_for_messages(&message_ids)?;
    let mut all_edits: Vec<StoredMessageEdit> = Vec::new();
    for (mid, rows) in edits_map {
        for (old_text, new_text, edited_at, signature, public_key, prev_signature, prev_public_key, prev_timestamp) in rows {
            all_edits.push(StoredMessageEdit {
                message_id: mid.clone(),
                old_text,
                new_text,
                edited_at,
                signature,
                public_key,
                prev_signature,
                prev_public_key,
                prev_timestamp,
            });
        }
    }
    all_edits.sort_by_key(|e| e.edited_at);
    Ok(all_edits)
}

/// A single edit history entry.
pub struct StoredMessageEdit {
    pub message_id: String,
    pub old_text: String,
    pub new_text: String,
    pub edited_at: i64,
    pub signature: Option<String>,
    pub public_key: Option<String>,
    pub prev_signature: Option<String>,
    pub prev_public_key: Option<String>,
    pub prev_timestamp: Option<i64>,
}

/// Count all DM messages for a peer (including hidden/deleted).
#[frb]
pub fn count_dm_messages(peer_id: String) -> Result<u32, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    Ok(ms.count_dm_messages(&peer_id))
}

/// Count all visible DM messages across every conversation. Drives the Home
/// stats card — an honest multi-device sync-comparison number (DMs fully
/// converge across a person's devices; channel messages are lazy-paged and
/// would diverge, so they are deliberately not counted there).
#[frb]
pub fn count_all_dm_messages() -> Result<u32, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    Ok(ms.count_all_dm_messages())
}

/// Count all channel messages (including hidden/deleted).
#[frb]
pub fn count_channel_messages_ffi(server_id: String, channel_id: String) -> Result<u32, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    Ok(ms.count_channel_messages(&server_id, &channel_id))
}

/// A user profile returned to Dart.
pub struct UserProfile {
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
    /// Avatar frame ID (issue #54). `""` = none, `"b:<hue>"` = a built-in
    /// procedural frame, 64-hex = an asset-rail blob hash whose bytes are
    /// pulled on demand via `request_assets(kind: "frame")`.
    pub avatar_frame: String,
    /// Asset-rail hash of this person's ANIMATED avatar; `""` = still only.
    /// `avatar_bytes` above is the STILL companion — the animation is pulled
    /// via `request_assets(kind: "profile")` and painted over it when held.
    pub avatar_anim: String,
    /// Asset-rail hash of this person's ANIMATED banner; `""` = still only.
    pub banner_anim: String,
}

/// Get a profile for a specific peer (or ourselves). Returns None if no profile stored.
#[frb]
pub fn get_profile(peer_id: String) -> Result<Option<UserProfile>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;

    match ms.load_profile(&peer_id)? {
        Some(p) => Ok(Some(UserProfile {
            peer_id: p.peer_id,
            display_name: p.display_name,
            status: p.status,
            about_me: p.about_me,
            updated_at: p.updated_at,
            avatar_bytes: p.avatar_bytes,
            banner_bytes: p.banner_bytes,
            twitch_username: p.twitch_username,
            showcase_board: p.showcase_board,
            avatar_frame: p.avatar_frame,
            avatar_anim: p.avatar_anim,
            banner_anim: p.banner_anim,
        })),
        None => Ok(None),
    }
}

/// Get all stored profiles (for populating the profile cache on startup).
#[frb]
pub fn get_all_profiles() -> Result<Vec<UserProfile>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;

    let profiles = ms.load_all_profiles()?;
    Ok(profiles
        .into_iter()
        .map(|p| UserProfile {
            peer_id: p.peer_id,
            display_name: p.display_name,
            status: p.status,
            about_me: p.about_me,
            updated_at: p.updated_at,
            avatar_bytes: p.avatar_bytes,
            banner_bytes: p.banner_bytes,
            twitch_username: p.twitch_username,
            showcase_board: p.showcase_board,
            avatar_frame: p.avatar_frame,
            avatar_anim: p.avatar_anim,
            banner_anim: p.banner_anim,
        })
        .collect())
}

/// Get all stored profiles WITHOUT avatar/banner blobs (fast startup load).
#[frb]
pub fn get_all_profiles_light() -> Result<Vec<UserProfile>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;

    let profiles = ms.load_all_profiles_light()?;
    Ok(profiles
        .into_iter()
        .map(|p| UserProfile {
            peer_id: p.peer_id,
            display_name: p.display_name,
            status: p.status,
            about_me: p.about_me,
            updated_at: p.updated_at,
            avatar_bytes: None,
            banner_bytes: None,
            twitch_username: p.twitch_username,
            showcase_board: p.showcase_board,
            avatar_frame: p.avatar_frame,
            avatar_anim: p.avatar_anim,
            banner_anim: p.banner_anim,
        })
        .collect())
}

/// Get a single profile WITHOUT avatar/banner blobs (light reload on update).
#[frb]
pub fn get_profile_light(peer_id: String) -> Result<Option<UserProfile>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;

    match ms.load_profile_light(&peer_id)? {
        Some(p) => Ok(Some(UserProfile {
            peer_id: p.peer_id,
            display_name: p.display_name,
            status: p.status,
            about_me: p.about_me,
            updated_at: p.updated_at,
            avatar_bytes: None,
            banner_bytes: None,
            twitch_username: p.twitch_username,
            showcase_board: p.showcase_board,
            avatar_frame: p.avatar_frame,
            avatar_anim: p.avatar_anim,
            banner_anim: p.banner_anim,
        })),
        None => Ok(None),
    }
}

/// Get only the avatar bytes for a peer (lazy load for HollowAvatar).
#[frb]
pub fn get_avatar(peer_id: String) -> Result<Option<Vec<u8>>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.load_avatar(&peer_id)
}

/// Get only the banner bytes for a peer (lazy load for profile card/DM header).
#[frb]
pub fn get_banner(peer_id: String) -> Result<Option<Vec<u8>>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.load_banner(&peer_id)
}

// ── App Settings ──────────────────────────────────────────────

/// Save a key-value setting to the local database.
#[frb]
pub fn save_setting(key: String, value: String) -> Result<(), String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.save_setting(&key, &value)
}

/// Load a setting by key. Returns None if not set.
#[frb]
pub fn load_setting(key: String) -> Result<Option<String>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.load_setting(&key)
}

/// A single settings row for the batched prefix load.
pub struct SettingEntry {
    pub key: String,
    pub value: String,
}

/// Load ALL settings whose key starts with `prefix` in ONE call — replaces
/// the per-key startup scans (`notif:*`, `seen:*`) that cost one FFI
/// round-trip per server/channel/DM.
#[frb]
pub fn load_settings_with_prefix(prefix: String) -> Result<Vec<SettingEntry>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    Ok(ms
        .load_settings_with_prefix(&prefix)?
        .into_iter()
        .map(|(key, value)| SettingEntry { key, value })
        .collect())
}

// Verified peers moved to `api::verification` (Issue 1-D) so every entry point
// resolves device → master in one auditable place. A verified flag stored under
// a device id stops applying the moment that contact links a device.

/// Count unread DM messages newer than the given last-seen message ID.
/// Only counts non-hidden messages from the other peer (is_mine = 0).
#[frb]
pub fn count_unread_dm(peer_id: String, last_seen_message_id: String) -> Result<u32, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    Ok(ms.count_unread_dm(&peer_id, &last_seen_message_id))
}

/// Count unread channel messages newer than the given last-seen message ID.
/// Only counts non-hidden messages from other members (is_mine = 0).
#[frb]
pub fn count_unread_channel(
    server_id: String,
    channel_id: String,
    last_seen_message_id: String,
) -> Result<u32, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    Ok(ms.count_unread_channel(&server_id, &channel_id, &last_seen_message_id))
}

/// Count ALL non-hidden messages from others in a DM (for never-opened DMs).
#[frb]
pub fn count_all_unread_dm(peer_id: String) -> Result<u32, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    Ok(ms.count_all_unread_dm(&peer_id))
}

/// Count ALL non-hidden messages from others in a channel (for never-opened channels).
#[frb]
pub fn count_all_unread_channel(server_id: String, channel_id: String) -> Result<u32, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    Ok(ms.count_all_unread_channel(&server_id, &channel_id))
}

/// Unread + mention counts returned from the database.
pub struct UnreadMentionCount {
    pub total: u32,
    pub mentions: u32,
}

/// Count unread and mention-containing messages for a channel.
/// `mention_patterns` should include `@everyone`, `@DisplayName`, `@Nickname`.
#[frb]
pub fn count_unread_channel_with_mentions(
    server_id: String,
    channel_id: String,
    last_seen_message_id: Option<String>,
    mention_patterns: Vec<String>,
) -> Result<UnreadMentionCount, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    let (total, mentions) = ms.count_unread_channel_with_mentions(
        &server_id,
        &channel_id,
        last_seen_message_id.as_deref(),
        &mention_patterns,
    );
    hollow_log!("[HOLLOW-UNREAD] countWithMentions {channel_id} in {server_id}: total={total} mentions={mentions} lastSeen={last_seen_message_id:?} patterns={mention_patterns:?}");
    Ok(UnreadMentionCount { total, mentions })
}

/// Get all distinct peer IDs that have DM messages in the local database.
#[frb]
pub fn get_dm_peer_ids() -> Result<Vec<String>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    Ok(ms.get_dm_peer_ids())
}

/// A friend entry returned to Dart.
pub struct FriendFfi {
    pub peer_id: String,
    pub status: String,
    pub direction: String,
    pub requested_at: i64,
    pub updated_at: i64,
}

/// Load all friends, optionally filtered by status.
#[frb]
pub fn load_friends(status: Option<String>) -> Result<Vec<FriendFfi>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    let rows = ms.load_friends(status.as_deref())?;
    Ok(rows
        .into_iter()
        .map(|(peer_id, status, direction, requested_at, updated_at)| FriendFfi {
            peer_id,
            status,
            direction,
            requested_at,
            updated_at,
        })
        .collect())
}

/// Block an identity (MASTER-keyed). Persists the row and warms the in-memory
/// set the Rust ingest guards read, so it takes effect immediately. Purely
/// local — the blocked peer learns nothing. Pass any of the peer's ids; it is
/// collapsed to the master via the resolver.
#[frb]
pub fn block_peer(peer_id: String) -> Result<(), String> {
    let master = crate::node::resolver::resolve(&peer_id);
    {
        let store = get_store();
        let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        let ms = guard.as_ref().ok_or("Message store is not open")?;
        ms.block_peer(&master)?;
    }
    crate::node::blocklist::block(&master);
    Ok(())
}

/// Unblock a previously blocked identity.
#[frb]
pub fn unblock_peer(peer_id: String) -> Result<(), String> {
    let master = crate::node::resolver::resolve(&peer_id);
    {
        let store = get_store();
        let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        let ms = guard.as_ref().ok_or("Message store is not open")?;
        ms.unblock_peer(&master)?;
    }
    crate::node::blocklist::unblock(&master);
    Ok(())
}

/// All blocked master peer_ids, newest first.
#[frb]
pub fn load_blocked_peers() -> Result<Vec<String>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.load_blocked_peers()
}

/// A single reaction on a message, returned to Dart.
/// Search channel messages by text.
#[frb]
pub fn search_channel_messages(
    server_id: String,
    channel_id: String,
    query: String,
    limit: i32,
) -> Result<Vec<StoredChannelMessage>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.search_channel_messages(&server_id, &channel_id, &query, limit)
        .map(|rows| {
            rows.into_iter()
                .map(|m| StoredChannelMessage {
                    id: m.id,
                    server_id: m.server_id,
                    channel_id: m.channel_id,
                    sender_id: m.sender_id,
                    text: m.text,
                    is_mine: m.is_mine,
                    timestamp: m.timestamp,
                    signature: m.signature,
                    public_key: m.public_key,
                    message_id: m.message_id,
                    edited_at: m.edited_at,
                    hidden_at: m.hidden_at,
                    reply_to_mid: m.reply_to_mid,
                    file_id: m.file_id,
                    link_preview: m.link_preview.map(Into::into),
                })
                .collect()
        })
}

/// Search DM messages by text.
#[frb]
pub fn search_dm_messages(
    peer_id: String,
    query: String,
    limit: i32,
) -> Result<Vec<StoredMessage>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.search_dm_messages(&peer_id, &query, limit)
        .map(|rows| {
            rows.into_iter()
                .map(|m| StoredMessage {
                    id: m.id,
                    peer_id: m.peer_id,
                    text: m.text,
                    is_mine: m.is_mine,
                    timestamp: m.timestamp,
                    signature: m.signature,
                    public_key: m.public_key,
                    message_id: m.message_id,
                    edited_at: m.edited_at,
                    hidden_at: m.hidden_at,
                    reply_to_mid: m.reply_to_mid,
                    file_id: m.file_id,
                    link_preview: m.link_preview.map(Into::into),
                })
                .collect()
        })
}

pub struct StoredReaction {
    pub message_id: String,
    pub emoji: String,
    pub peer_id: String,
    pub added_at: i64,
}

/// Load all reactions for a list of message IDs.
/// Returns reactions grouped by message_id for efficient bulk loading.
#[frb]
pub fn load_reactions(message_ids: Vec<String>) -> Result<Vec<StoredReaction>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;

    let reactions_map = ms.load_reactions_for_messages(&message_ids)?;
    let mut result = Vec::new();
    for (mid, reactions) in reactions_map {
        for (emoji, peer_id, added_at) in reactions {
            result.push(StoredReaction {
                message_id: mid.clone(),
                emoji,
                peer_id,
                added_at,
            });
        }
    }
    Ok(result)
}

/// A channel message returned to Dart from the local database.
pub struct StoredChannelMessage {
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
    /// Link preview for the first URL in this message (Phase 6.75).
    pub link_preview: Option<crate::api::network::LinkPreviewRef>,
}

/// Load recent channel messages from the local database.
/// Returns messages ordered oldest-first, up to `limit`.
#[frb]
pub fn load_channel_messages(
    server_id: String,
    channel_id: String,
    limit: i32,
) -> Result<Vec<StoredChannelMessage>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;

    let rows = ms.load_channel_messages(&server_id, &channel_id, limit)?;
    Ok(rows
        .into_iter()
        .map(|r| StoredChannelMessage {
            id: r.id,
            server_id: r.server_id,
            channel_id: r.channel_id,
            sender_id: r.sender_id,
            text: r.text,
            is_mine: r.is_mine,
            timestamp: r.timestamp,
            signature: r.signature,
            public_key: r.public_key,
            message_id: r.message_id,
            edited_at: r.edited_at,
            hidden_at: r.hidden_at,
            reply_to_mid: r.reply_to_mid,
            file_id: r.file_id,
            link_preview: r.link_preview.map(Into::into),
        })
        .collect())
}

// ── File sharing storage FFI ────────────────────────────────────

/// File metadata returned to Dart.
pub struct StoredFileInfo {
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
    pub context_type: String,
    pub context_id: String,
    pub sender_id: String,
    pub is_mine: bool,
    pub created_at: i64,
    pub completed_at: Option<i64>,
    pub disk_path: Option<String>,
    pub expired_at: Option<i64>,
    /// Video thumbnail back-reference (Phase 6.75 video preview).
    /// When non-null, this file is a thumbnail image for a vault-stored video.
    /// The Dart UI uses this to render a play button overlay and trigger the
    /// vault download on tap.
    pub video_thumb: Option<crate::api::network::VideoThumbRef>,
    /// Persisted share swarm root hash for share-backed (>34 MB) files —
    /// lets a manual download rejoin the share after a restart (issue #41).
    pub share_root_hash: Option<String>,
    /// Persisted share AES key (hex) paired with `share_root_hash`.
    pub share_key_hex: Option<String>,
    /// Tiny base64 WebP placeholder thumbnail — rendered blurred under the
    /// Download button while the real bytes are gated/undownloaded (issue #41
    /// carry-over).
    pub thumb_b64: Option<String>,
}

fn stored_file_to_ffi(f: crate::storage::messages::StoredFile) -> StoredFileInfo {
    StoredFileInfo {
        file_id: f.file_id,
        file_name: f.file_name,
        file_ext: f.file_ext,
        mime_type: f.mime_type,
        size_bytes: f.size_bytes,
        chunk_count: f.chunk_count,
        chunks_received: f.chunks_received,
        is_image: f.is_image,
        width: f.width,
        height: f.height,
        message_id: f.message_id,
        context_type: f.context_type,
        context_id: f.context_id,
        sender_id: f.sender_id,
        is_mine: f.is_mine,
        created_at: f.created_at,
        completed_at: f.completed_at,
        disk_path: f.disk_path,
        expired_at: f.expired_at,
        video_thumb: f.video_thumb.map(crate::api::network::VideoThumbRef::from),
        share_root_hash: f.share_ref.as_ref().map(|s| s.root_hash.clone()),
        share_key_hex: f.share_ref.map(|s| s.key),
        thumb_b64: f.thumb_b64,
    }
}

/// Get file metadata by file ID.
#[frb]
pub fn get_file_metadata(file_id: String) -> Result<Option<StoredFileInfo>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    Ok(ms.get_file_metadata(&file_id)?.map(stored_file_to_ffi))
}

/// Get the vault content_id linked to a file by its file_id.
/// Returns None if no vault content_id is set (e.g. DM files, <6 member files).
#[frb]
pub fn get_content_id_for_file(file_id: String) -> Result<Option<String>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.get_content_id_for_file(&file_id)
}

/// Get all files attached to a message.
#[frb]
pub fn get_files_for_message(message_id: String) -> Result<Vec<StoredFileInfo>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    Ok(ms.get_files_for_message(&message_id)?
        .into_iter()
        .map(stored_file_to_ffi)
        .collect())
}

/// Get all incomplete files (for sync resume).
#[frb]
pub fn get_incomplete_files() -> Result<Vec<StoredFileInfo>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    Ok(ms.get_incomplete_files()?
        .into_iter()
        .map(stored_file_to_ffi)
        .collect())
}

/// Mark a file as complete with its disk path (used for share-backed files).
#[frb]
pub fn mark_file_complete(file_id: String, disk_path: String) -> Result<(), String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.mark_file_complete(&file_id, &disk_path);
    Ok(())
}

/// Get file_ids from messages that have no completed file on disk.
/// Used to find files that need downloading after message sync.
#[frb]
pub fn get_missing_file_ids() -> Result<Vec<String>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.get_missing_file_ids()
}

/// Missing file_ids scoped to ONE DM conversation (friend's MASTER peer id).
/// The chat-open sweep must never re-request account-wide ids from a DM peer.
#[frb]
pub fn get_missing_file_ids_for_dm(peer_id: String) -> Result<Vec<String>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.get_missing_file_ids_for_dm(&peer_id)
}

/// Missing file_ids scoped to ONE server's channels.
#[frb]
pub fn get_missing_file_ids_for_server(server_id: String) -> Result<Vec<String>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.get_missing_file_ids_for_server(&server_id)
}

/// Reset completed files whose disk_path no longer exists on disk.
/// Returns the count of reset entries. They'll be re-requested from peers.
#[frb]
pub fn reset_stale_files() -> Result<u32, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.reset_stale_file_paths()
}

// ── Storage Manager (disk usage breakdown + reclaim) ────────────────────────

/// Per-conversation/server disk usage of downloaded files.
pub struct StorageContextUsage {
    /// "dm" or "channel".
    pub context_type: String,
    /// DM = sender MASTER peer id; channel = "server_id:channel_id".
    pub context_id: String,
    /// Sum of `size_bytes` for completed-on-disk files in this context (from DB).
    pub bytes_db: u64,
    pub file_count: u32,
}

/// Full storage picture for the Storage Manager UI.
pub struct StorageBreakdown {
    /// Sum of size_bytes across all completed-on-disk files (from DB).
    pub total_db_bytes: u64,
    /// Actual `du` of the `files/` directory on disk (catches orphans/partials).
    pub total_disk_bytes: u64,
    /// Actual `du` of the `vault_cache/` directory.
    pub vault_cache_bytes: u64,
    /// Actual `du` of the `vault/` (held erasure shards) directory.
    pub vault_shard_bytes: u64,
    /// Content-addressed asset blob cache (emotes, stickers, GIFs, banners)
    /// inside the encrypted DB.
    pub asset_blob_bytes: u64,
    pub asset_blob_count: u32,
    pub contexts: Vec<StorageContextUsage>,
}

/// Sum the byte sizes of regular files directly inside `dir` (non-recursive,
/// matching how files/ and vault_cache/ are laid out — flat directories).
/// Skips transient sender-side stream temps (`.stream_send_*`, `.stream_shard_*`)
/// so an in-flight send doesn't inflate the reported usage.
fn dir_size_bytes(dir: &std::path::Path) -> u64 {
    let mut total = 0u64;
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name.starts_with(".stream_send_") || name.starts_with(".stream_shard_") {
                continue;
            }
            if let Ok(meta) = entry.metadata() {
                if meta.is_file() {
                    total += meta.len();
                }
            }
        }
    }
    total
}

/// Get the storage usage breakdown for the Storage Manager UI.
#[frb]
pub fn get_storage_breakdown() -> Result<StorageBreakdown, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;

    let rows = ms.storage_breakdown()?;
    let mut total_db_bytes = 0u64;
    let mut contexts = Vec::with_capacity(rows.len());
    for (context_type, context_id, bytes_db, file_count) in rows {
        total_db_bytes += bytes_db;
        contexts.push(StorageContextUsage {
            context_type,
            context_id,
            bytes_db,
            file_count,
        });
    }

    let total_disk_bytes = dir_size_bytes(&crate::vault::pipeline::files_dir());
    let vault_cache_bytes = dir_size_bytes(&crate::vault::pipeline::vault_cache_dir());
    let vault_shard_bytes = {
        let dir = crate::identity::data_dir()?.join("vault");
        dir_size_bytes(&dir)
    };
    let (asset_blob_bytes, asset_blob_count) = ms.asset_blob_usage()?;

    Ok(StorageBreakdown {
        total_db_bytes,
        total_disk_bytes,
        vault_cache_bytes,
        vault_shard_bytes,
        asset_blob_bytes,
        asset_blob_count,
        contexts,
    })
}

/// Every asset hash still referenced by a personal set or replicated CRDT
/// state — eviction and "clear" must never drop these (a personal emote or
/// a server's active emote/banner would go blank until re-pulled; worse, WE
/// may be the only online holder for a server we own).
fn referenced_asset_hashes(ms: &crate::storage::MessageStore) -> std::collections::HashSet<String> {
    let mut keep = std::collections::HashSet::new();
    if let Ok(personal) = ms.list_personal_emotes() {
        for (_, hash, _, _) in personal {
            keep.insert(hash);
        }
    }
    if let Ok(stickers) = ms.list_personal_stickers() {
        for row in stickers {
            keep.insert(row.hash);
        }
    }
    if let Ok(servers) = ms.load_all_servers() {
        for (_, state_json) in servers {
            let Ok(state) =
                serde_json::from_str::<crate::crdt::server_state::ServerState>(&state_json)
            else {
                continue;
            };
            for emote in state.emotes.values() {
                keep.insert(emote.hash.clone());
            }
            for sticker in state.stickers.values() {
                keep.insert(sticker.hash.clone());
            }
            // Server banner + animated server icon: these settings carry a
            // blob hash; absent/cleared values are not hex and are skipped.
            for key in ["server_banner", "server_avatar_anim"] {
                if let Some(reg) = state.settings.get(key) {
                    let v = reg.read().clone();
                    if crate::crdt::valid_emote_hash(&v) {
                        keep.insert(v);
                    }
                }
            }
        }
    }
    // OUR OWN avatar frame (issue #54). Only ours: other people's frames are
    // decoration and are meant to be the first thing evicted, then re-pulled
    // from their owner. Ours has no other holder to pull it back from until
    // somebody who has seen it comes online, so it stays pinned. Mirrored
    // into a setting by `set_my_avatar_frame` because this function has no
    // identity to look the profile row up by. A sibling device that inherited
    // the frame over the wire re-pulls it like anyone else.
    // OUR OWN avatar frame and animated avatar/banner. Same rule, same
    // reason: other people's are re-pullable from their owner, ours has no
    // other holder until somebody who has seen it comes online.
    for key in [
        MY_AVATAR_FRAME_SETTING,
        MY_AVATAR_ANIM_SETTING,
        MY_BANNER_ANIM_SETTING,
    ] {
        if let Ok(Some(hash)) = ms.load_setting(key)
            && crate::crdt::valid_emote_hash(&hash)
        {
            keep.insert(hash);
        }
    }
    // Art bought from the artist shop, worn or not. A `.hollowpack` import is
    // the one thing on the rail with no peer to re-pull it from and a receipt
    // behind it: evicting it would silently destroy something somebody paid
    // for, and re-importing means finding the file again. Every owned hash is
    // pinned, including the stills and the halves of a pair the wearer is not
    // currently using.
    if let Ok(owned) = ms.owned_art_hashes() {
        keep.extend(owned);
    }
    keep
}

/// `app_settings` key mirroring our own `UserProfile.avatar_frame`, so the
/// asset evictor can pin it without resolving our identity.
pub(crate) const MY_AVATAR_FRAME_SETTING: &str = "my_avatar_frame";

/// `app_settings` keys mirroring our own animated avatar/banner hashes, so
/// the asset evictor can pin them without resolving our identity — same
/// reason as [`MY_AVATAR_FRAME_SETTING`].
pub(crate) const MY_AVATAR_ANIM_SETTING: &str = "my_avatar_anim";
pub(crate) const MY_BANNER_ANIM_SETTING: &str = "my_banner_anim";

/// Delete every cached asset blob not referenced by a personal set or a
/// server's CRDT state (Storage Manager "clear" action). Returns bytes freed.
#[frb]
pub fn clear_unreferenced_asset_blobs() -> Result<u64, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    let keep = referenced_asset_hashes(ms);
    ms.clear_asset_blobs_except(&keep)
}

/// Delete the file bytes for a single conversation/server (keep the signed
/// FileHeader rows so messages render as re-downloadable). Returns bytes freed.
#[frb]
pub fn clear_file_bytes_for_context(context_type: String, context_id: String) -> Result<u64, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;

    let paths = ms.disk_paths_for_context(&context_type, &context_id)?;
    let mut freed = 0u64;
    for p in &paths {
        let path = std::path::Path::new(p);
        if let Ok(meta) = std::fs::metadata(path) {
            if std::fs::remove_file(path).is_ok() {
                freed += meta.len();
            }
        }
    }
    // Null the rows so they show as not-on-disk (re-downloadable cards).
    let _ = ms.null_disk_path_for_context(&context_type, &context_id)?;
    Ok(freed)
}

/// Delete ALL downloaded file bytes (keep the signed FileHeader rows). Returns
/// bytes freed. Removes every file in `files/` then nulls the matching rows.
#[frb]
pub fn clear_all_file_bytes() -> Result<u64, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;

    let paths = ms.all_on_disk_paths()?;
    let mut freed = 0u64;
    for p in &paths {
        let path = std::path::Path::new(p);
        if let Ok(meta) = std::fs::metadata(path) {
            if std::fs::remove_file(path).is_ok() {
                freed += meta.len();
            }
        }
    }
    // Also sweep any orphan files in files/ not tracked by a row.
    let files_dir = crate::vault::pipeline::files_dir();
    if let Ok(entries) = std::fs::read_dir(&files_dir) {
        for entry in entries.flatten() {
            if let Ok(meta) = entry.metadata() {
                if meta.is_file() && std::fs::remove_file(entry.path()).is_ok() {
                    freed += meta.len();
                }
            }
        }
    }
    let _ = ms.null_disk_path_all()?;
    Ok(freed)
}

/// Enforce the downloaded-files LRU cap (`files/`), evicting oldest bytes until
/// under `cap_mb`. Keeps signed headers; nulls the rows whose bytes were
/// evicted (via `reset_stale_file_paths`). Returns bytes freed.
#[frb]
pub fn evict_files_cache(cap_mb: u64, exempt_paths: Vec<String>) -> Result<u64, String> {
    let exempt: std::collections::HashSet<std::path::PathBuf> =
        exempt_paths.iter().map(std::path::PathBuf::from).collect();
    let (_deleted, freed) = crate::vault::pipeline::evict_dir_if_needed(
        &crate::vault::pipeline::files_dir(),
        cap_mb.saturating_mul(1024 * 1024),
        &exempt,
    )?;
    // Null rows whose disk_path is now gone so cards render re-downloadable.
    if freed > 0 {
        let store = get_store();
        if let Ok(guard) = store.lock() {
            if let Some(ms) = guard.as_ref() {
                let _ = ms.reset_stale_file_paths();
            }
        }
    }
    Ok(freed)
}

/// Clear the entire vault cache (`vault_cache/`) — pure cache, no signed headers
/// live there. Returns bytes freed.
#[frb]
pub fn clear_vault_cache() -> Result<u64, String> {
    let dir = crate::vault::pipeline::vault_cache_dir();
    let mut freed = 0u64;
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for entry in entries.flatten() {
            if let Ok(meta) = entry.metadata() {
                if meta.is_file() && std::fs::remove_file(entry.path()).is_ok() {
                    freed += meta.len();
                }
            }
        }
    }
    Ok(freed)
}

/// Enforce the cache caps (files/ + vault_cache/ + the asset blob cache).
/// Called after a download completes so the user-set caps are actually
/// honored (the sliders were no-ops before this). Returns total bytes freed.
#[frb]
pub fn enforce_storage_caps(
    files_cap_mb: u64,
    vault_cache_cap_mb: u64,
    asset_cap_mb: u64,
    exempt_paths: Vec<String>,
) -> Result<u64, String> {
    let exempt: std::collections::HashSet<std::path::PathBuf> =
        exempt_paths.iter().map(std::path::PathBuf::from).collect();

    let mut freed = 0u64;

    let (_d1, f1) = crate::vault::pipeline::evict_dir_if_needed(
        &crate::vault::pipeline::files_dir(),
        files_cap_mb.saturating_mul(1024 * 1024),
        &exempt,
    )?;
    freed += f1;
    if f1 > 0 {
        let store = get_store();
        if let Ok(guard) = store.lock() {
            if let Some(ms) = guard.as_ref() {
                let _ = ms.reset_stale_file_paths();
            }
        }
    }

    let f2 = crate::vault::pipeline::evict_cache_if_needed(
        vault_cache_cap_mb.saturating_mul(1024 * 1024),
        &exempt,
    )?;
    freed += f2;

    // Asset blob cache (emotes/stickers/GIFs/banners): LRU by added_at,
    // never evicting hashes still referenced by a personal set or CRDT state.
    {
        let store = get_store();
        if let Ok(guard) = store.lock() {
            if let Some(ms) = guard.as_ref() {
                let keep = referenced_asset_hashes(ms);
                freed += ms
                    .evict_asset_blobs(asset_cap_mb.saturating_mul(1024 * 1024), &keep)
                    .unwrap_or(0);
            }
        }
    }

    Ok(freed)
}

/// Get file IDs for missing images in a specific server.
/// Used for late-joiner image sync in 6+ member servers.
#[frb]
pub fn get_missing_image_file_ids_for_server(server_id: String) -> Result<Vec<String>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.get_missing_image_file_ids_for_server(&server_id)
}

/// Save the recovery mnemonic to the database (called once on first identity generation).
#[frb]
pub fn save_mnemonic(mnemonic: String) -> Result<(), String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.save_setting("recovery_mnemonic", &mnemonic)
}

/// Retrieve the stored recovery mnemonic.
#[frb]
pub fn get_mnemonic() -> Result<Option<String>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.load_setting("recovery_mnemonic")
}

/// Check if an identity key file exists on disk.
#[frb]
pub fn has_identity() -> Result<bool, String> {
    let dir = crate::identity::data_dir()?;
    Ok(dir.join("identity.key").exists())
}

/// Delete the on-disk identity + local DB so the next launch shows the Welcome
/// screen fresh. Used to discard a THROWAWAY identity created for the "Link a
/// device" first-run flow when the user cancels it. Best-effort — missing files
/// are ignored. The caller must restart the app afterward (the live DB handle
/// is still open). DESTRUCTIVE: only call on a throwaway with no real data.
#[frb]
pub fn delete_identity() -> Result<(), String> {
    let dir = crate::identity::data_dir()?;
    for name in [
        "identity.key",
        "identity.device",
        "messages.db",
        "messages.db-wal",
        "messages.db-shm",
    ] {
        let p = dir.join(name);
        if p.exists() {
            let _ = std::fs::remove_file(&p);
        }
    }
    Ok(())
}

/// Export account backup as a passphrase-encrypted blob (.hollow file).
/// Includes identity.key + messages.db. Optionally includes vault/ shard data
/// and/or downloaded files from files/.
/// The backup is: [16-byte salt][12-byte nonce][AES-256-GCM ciphertext of zip bytes]
/// Key derived from passphrase via Argon2id (memory=64MB, iterations=3, parallelism=1).
/// Build the plaintext snapshot ZIP in memory (no encryption layer).
///
/// Contents: `identity.key` (plaintext keypair) + `messages.db` (WAL-checkpointed)
/// + optionally `vault/` shards and `files/` downloads. This is the shared core of
/// both the on-disk backup (`export_backup`, wrapped in Argon2id+AES) and the
/// multi-device link snapshot (`api/network` link transfer, wrapped in a one-time
/// random AES key). Returns the raw zip bytes.
pub(crate) fn build_snapshot_bytes(include_vault: bool, include_files: bool) -> Result<Vec<u8>, String> {
    use std::io::Write;

    let data_dir = crate::identity::data_dir()?;

    let mut zip_buf = std::io::Cursor::new(Vec::new());
    {
        let mut zip = zip::ZipWriter::new(&mut zip_buf);
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);

        let key_path = data_dir.join("identity.key");
        if key_path.exists() {
            // Always export the PLAINTEXT keypair — the wrapping layer (backup
            // passphrase or link transfer key) provides encryption. Reading via
            // load_or_create_identity() transparently decrypts if protected.
            let id = crate::identity::load_or_create_identity()?;
            let data = id.keypair.to_protobuf_encoding()
                .map_err(|e| format!("Failed to encode keypair: {e}"))?;
            zip.start_file("identity.key", options).map_err(|e| format!("Zip error: {e}"))?;
            zip.write_all(&data).map_err(|e| format!("Zip write error: {e}"))?;
        }

        let db_path = data_dir.join("messages.db");
        if db_path.exists() {
            let db_passphrase = derive_db_key()?;
            if let Ok(store) = crate::storage::MessageStore::open(
                db_path.to_str().unwrap_or_default(), &db_passphrase,
            ) {
                let _ = store.wal_checkpoint();
            }
            let data = std::fs::read(&db_path).map_err(|e| format!("Failed to read messages.db: {e}"))?;
            zip.start_file("messages.db", options).map_err(|e| format!("Zip error: {e}"))?;
            zip.write_all(&data).map_err(|e| format!("Zip write error: {e}"))?;
        }

        if include_vault {
            let vault_dir = data_dir.join("vault");
            if vault_dir.exists() && vault_dir.is_dir() {
                for entry in std::fs::read_dir(&vault_dir).map_err(|e| format!("Failed to read vault dir: {e}"))? {
                    if let Ok(entry) = entry {
                        let path = entry.path();
                        if path.is_file() {
                            let name = format!("vault/{}", entry.file_name().to_string_lossy());
                            let data = std::fs::read(&path).map_err(|e| format!("Failed to read vault file: {e}"))?;
                            zip.start_file(&name, options).map_err(|e| format!("Zip error: {e}"))?;
                            zip.write_all(&data).map_err(|e| format!("Zip write error: {e}"))?;
                        }
                    }
                }
            }
        }

        if include_files {
            let files_dir = data_dir.join("files");
            if files_dir.exists() && files_dir.is_dir() {
                for entry in std::fs::read_dir(&files_dir).map_err(|e| format!("Failed to read files dir: {e}"))? {
                    if let Ok(entry) = entry {
                        let path = entry.path();
                        if path.is_file() {
                            let name = format!("files/{}", entry.file_name().to_string_lossy());
                            let data = std::fs::read(&path).map_err(|e| format!("Failed to read file: {e}"))?;
                            zip.start_file(&name, options).map_err(|e| format!("Zip error: {e}"))?;
                            zip.write_all(&data).map_err(|e| format!("Zip write error: {e}"))?;
                        }
                    }
                }
            }
        }

        zip.finish().map_err(|e| format!("Failed to finalize zip: {e}"))?;
    }
    Ok(zip_buf.into_inner())
}

/// Extract a plaintext snapshot ZIP into the data directory (REPLACES existing
/// files of the same name). Shared core of `import_backup` and the link-snapshot
/// import. Requires the zip to contain `identity.key`.
pub(crate) fn import_snapshot_bytes(zip_bytes: &[u8]) -> Result<(), String> {
    use std::io::Read;

    let data_dir = crate::identity::data_dir()?;
    let cursor = std::io::Cursor::new(zip_bytes.to_vec());
    let mut archive = zip::ZipArchive::new(cursor)
        .map_err(|e| format!("Invalid snapshot data: {e}"))?;

    let has_key = (0..archive.len()).any(|i| {
        archive.by_index(i).map(|f| f.name() == "identity.key").unwrap_or(false)
    });
    if !has_key {
        return Err("Snapshot does not contain identity.key".into());
    }

    // CRITICAL: the multi-device link import runs while the node is LIVE on a
    // throwaway identity, so the global STORE holds an open SQLCipher connection
    // (with its own WAL). If we just overwrite messages.db, the throwaway's WAL/SHM
    // would later checkpoint back OVER the imported DB, and the live handle reads
    // the stale (empty) DB. So: drop the live connection and delete its WAL/SHM
    // BEFORE writing the imported files. The caller restarts the app afterward,
    // which reopens the real DB with the real (imported-identity) passphrase.
    if let Ok(mut guard) = get_store().lock() {
        let _ = guard.take(); // drops MessageStore → closes the connection
    }
    for stale in ["messages.db-wal", "messages.db-shm"] {
        let p = data_dir.join(stale);
        if p.exists() {
            let _ = std::fs::remove_file(&p);
        }
    }

    // CRITICAL: delete the THROWAWAY identity.device. The snapshot carries only a
    // PLAINTEXT identity.key (no identity.device), so if we keep the throwaway's
    // device file there are two failure modes:
    //   (1) protection mismatch — a keychain/password-protected throwaway device
    //       file (HKEYV1) can't be decrypted after the plaintext master replaces
    //       identity.key (no session key is established), so load_or_create_identity
    //       throws "Device key is encrypted" and the identity never loads ("Loading…"
    //       forever — the exact symptom seen on the VM).
    //   (2) the throwaway device id was minted under the throwaway identity and is
    //       meaningless under the real master.
    // Deleting it makes the next launch generate a FRESH, distinct, plaintext device
    // key under the real master — the correct multi-device shape.
    let dev_path = data_dir.join("identity.device");
    if dev_path.exists() {
        let _ = std::fs::remove_file(&dev_path);
        hollow_log!("[HOLLOW-LINK] Removed throwaway identity.device — fresh device key on restart");
    }

    for i in 0..archive.len() {
        let mut entry = archive.by_index(i).map_err(|e| format!("Zip read error: {e}"))?;
        let name = entry.name().to_string();
        let out_path = data_dir.join(&name);
        hollow_log!("[HOLLOW-LINK] Import writing {name} → {}", out_path.display());

        if let Some(parent) = out_path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| format!("Failed to create dir: {e}"))?;
        }

        if entry.is_file() {
            let mut data = Vec::new();
            entry.read_to_end(&mut data).map_err(|e| format!("Failed to read zip entry: {e}"))?;
            std::fs::write(&out_path, &data).map_err(|e| format!("Failed to write {name}: {e}"))?;
            hollow_log!("[HOLLOW-LINK] Import wrote {name} ({} bytes)", data.len());
        }
    }

    // Sanity-log what the imported identity resolves to, so a post-restart failure
    // is diagnosable: the master peer_id below MUST match the source device's, and
    // the next launch derives the DB passphrase from this same key.
    match crate::identity::load_or_create_identity() {
        Ok(id) => hollow_log!(
            "[HOLLOW-LINK] Import OK — imported identity peer_id={} device_peer_id={}",
            id.peer_id, id.device_peer_id
        ),
        Err(e) => hollow_log!("[HOLLOW-LINK] Import WARNING — imported identity failed to load: {e}"),
    }

    Ok(())
}

/// A compact summary of local DB state, used by multi-device linking to decide
/// data-flow direction (which device is populated vs empty) and for the post-import
/// summary. NOT a user-facing feature on its own.
pub(crate) fn snapshot_state_summary() -> (u32, u32, u32, bool) {
    let store = get_store();
    let Ok(guard) = store.lock() else { return (0, 0, 0, false); };
    let Some(ms) = guard.as_ref() else { return (0, 0, 0, false); };

    let msg_count: u32 = ms
        .get_dm_peer_ids()
        .iter()
        .map(|p| ms.count_dm_messages(p))
        .sum();
    let friend_count = ms
        .load_friends(Some("accepted"))
        .map(|f| f.len() as u32)
        .unwrap_or(0);
    let server_count = ms
        .load_all_servers()
        .map(|s| s.len() as u32)
        .unwrap_or(0);
    let has_profile = match get_peer_id() {
        Ok(pid) => ms
            .load_profile(pid)
            .ok()
            .flatten()
            .map(|p| !p.display_name.is_empty())
            .unwrap_or(false),
        Err(_) => false,
    };

    (msg_count, friend_count, server_count, has_profile)
}

/// Build a passphrase-encrypted `.hollow` backup blob IN MEMORY — the exact same
/// format `export_backup` writes to disk: `[magic:6][salt:16][nonce:12][ciphertext]`,
/// Argon2id-derived AES-256-GCM. Shared by the on-disk export AND the multi-device
/// link transfer (which uses the link CODE as the passphrase and streams the blob,
/// so the receiver imports via the identical `import_backup` pipeline).
pub(crate) fn export_backup_bytes(passphrase: &str, include_vault: bool, include_files: bool) -> Result<Vec<u8>, String> {
    use aes_gcm::{Aes256Gcm, KeyInit, aead::Aead};
    use aes_gcm::Nonce;

    let zip_bytes = build_snapshot_bytes(include_vault, include_files)?;

    // Derive encryption key from passphrase via Argon2id.
    let mut salt = [0u8; 16];
    getrandom::fill(&mut salt).map_err(|e| format!("RNG error: {e}"))?;
    let params = argon2::Params::new(65536, 3, 1, Some(32))
        .map_err(|e| format!("Argon2 params error: {e}"))?;
    let argon = argon2::Argon2::new(argon2::Algorithm::Argon2id, argon2::Version::V0x13, params);
    let mut key = [0u8; 32];
    argon.hash_password_into(passphrase.as_bytes(), &salt, &mut key)
        .map_err(|e| format!("Argon2 hash error: {e}"))?;

    // Encrypt zip with AES-256-GCM.
    let mut nonce_bytes = [0u8; 12];
    getrandom::fill(&mut nonce_bytes).map_err(|e| format!("RNG error: {e}"))?;
    let cipher = Aes256Gcm::new_from_slice(&key)
        .map_err(|e| format!("Cipher init error: {e}"))?;
    let nonce = Nonce::from_slice(&nonce_bytes);
    let ciphertext = cipher.encrypt(nonce, zip_bytes.as_slice())
        .map_err(|_| "Encryption failed".to_string())?;

    // [magic:6][salt:16][nonce:12][ciphertext...]
    let mut output = Vec::with_capacity(6 + 16 + 12 + ciphertext.len());
    output.extend_from_slice(b"HOLLOW"); // magic header
    output.extend_from_slice(&salt);
    output.extend_from_slice(&nonce_bytes);
    output.extend_from_slice(&ciphertext);
    Ok(output)
}

#[frb]
pub fn export_backup(output_path: String, include_vault: bool, include_files: bool, passphrase: String) -> Result<u64, String> {
    let output = export_backup_bytes(&passphrase, include_vault, include_files)?;
    std::fs::write(&output_path, &output)
        .map_err(|e| format!("Failed to write backup: {e}"))?;
    Ok(output.len() as u64)
}

/// Decrypt a `.hollow` backup blob (in memory) and extract it into the data
/// directory. Shared by `import_backup` (file) and `import_pending_link` (the
/// multi-device link blob stashed for next-boot import). Same Argon2id+AES scheme
/// as `export_backup_bytes`.
pub(crate) fn import_backup_bytes(blob: &[u8], passphrase: &str) -> Result<(), String> {
    use aes_gcm::{Aes256Gcm, KeyInit, aead::Aead};
    use aes_gcm::Nonce;

    // Validate magic header.
    if blob.len() < 6 + 16 + 12 + 16 || &blob[..6] != b"HOLLOW" {
        return Err("Invalid backup file (not a Hollow backup)".into());
    }

    let salt = &blob[6..22];
    let nonce_bytes = &blob[22..34];
    let ciphertext = &blob[34..];

    // Derive decryption key.
    let params = argon2::Params::new(65536, 3, 1, Some(32))
        .map_err(|e| format!("Argon2 params error: {e}"))?;
    let argon = argon2::Argon2::new(argon2::Algorithm::Argon2id, argon2::Version::V0x13, params);
    let mut key = [0u8; 32];
    argon.hash_password_into(passphrase.as_bytes(), salt, &mut key)
        .map_err(|e| format!("Argon2 hash error: {e}"))?;

    // Decrypt.
    let cipher = Aes256Gcm::new_from_slice(&key)
        .map_err(|e| format!("Cipher init error: {e}"))?;
    let nonce = Nonce::from_slice(nonce_bytes);
    let zip_bytes = cipher.decrypt(nonce, ciphertext)
        .map_err(|_| "Wrong passphrase or corrupted backup".to_string())?;

    // Extract zip to data directory (shared core).
    import_snapshot_bytes(&zip_bytes)
}

/// Import account backup from a passphrase-encrypted .hollow file.
/// Must be called BEFORE start_node() since it overwrites the data directory.
#[frb]
pub fn import_backup(backup_path: String, passphrase: String) -> Result<(), String> {
    let blob = std::fs::read(&backup_path)
        .map_err(|e| format!("Failed to read backup: {e}"))?;
    import_backup_bytes(&blob, &passphrase)
}

// ── Multi-device link: pending-blob stash + next-boot import ──────────────────

fn pending_link_blob_path() -> Result<std::path::PathBuf, String> {
    Ok(crate::identity::data_dir()?.join("pending_link.hollow"))
}
fn pending_link_code_path() -> Result<std::path::PathBuf, String> {
    Ok(crate::identity::data_dir()?.join("pending_link.code"))
}

/// (Receiver) Stash an encrypted `.hollow` link blob + the code that decrypts it,
/// to be imported on the NEXT launch (pre-node-start, the known-good window — the
/// exact same path as a manual "Restore from backup"). Called from the link
/// completion handler. Does NOT import in-place (that was the fragile path).
pub(crate) fn stash_pending_link(blob: &[u8], code: &str) -> Result<(), String> {
    std::fs::write(pending_link_blob_path()?, blob)
        .map_err(|e| format!("Failed to stash link blob: {e}"))?;
    std::fs::write(pending_link_code_path()?, code.as_bytes())
        .map_err(|e| format!("Failed to stash link code: {e}"))?;
    Ok(())
}

/// True if a pending link blob is waiting to be imported on launch.
#[frb]
pub fn has_pending_link() -> Result<bool, String> {
    Ok(pending_link_blob_path()?.exists() && pending_link_code_path()?.exists())
}

/// (Receiver, at launch BEFORE start_node) Import a stashed link blob via the exact
/// same pipeline as a manual `.hollow` restore: delete the throwaway identity,
/// decrypt with the stashed code, extract into the data dir, then clean up the
/// stash. After this the bootstrap proceeds as a normal restored-backup launch.
#[frb]
pub fn import_pending_link() -> Result<(), String> {
    let blob_path = pending_link_blob_path()?;
    let code_path = pending_link_code_path()?;
    let blob = std::fs::read(&blob_path)
        .map_err(|e| format!("Failed to read pending link blob: {e}"))?;
    let code = std::fs::read_to_string(&code_path)
        .map_err(|e| format!("Failed to read pending link code: {e}"))?;

    // Discard the throwaway identity so import lands on a clean slate, exactly like
    // a fresh "Restore from backup" (which runs on first launch with no identity).
    let data_dir = crate::identity::data_dir()?;
    for name in ["identity.key", "identity.device", "messages.db", "messages.db-wal", "messages.db-shm"] {
        let p = data_dir.join(name);
        if p.exists() { let _ = std::fs::remove_file(&p); }
    }

    let result = import_backup_bytes(&blob, code.trim());

    // Clean up the stash regardless of outcome (a failed import shouldn't loop).
    let _ = std::fs::remove_file(&blob_path);
    let _ = std::fs::remove_file(&code_path);

    // Multi-device (Step 6): the imported DB contains the SOURCE device's MLS
    // identity (signer + credential + group leaves). A linked sibling MUST NOT
    // reuse them — two devices sharing one MLS signature key can't both be group
    // leaves (`DuplicateSignatureKey` on add, `CannotDecryptOwnMessage` on
    // receive). Wipe the inherited MLS identity here so the node mints a FRESH,
    // distinct one on first start and re-joins each server's group as its own
    // leaf. (The master-key comparison at startup can't catch this case: a
    // sibling's master EQUALS the source's, so the inherited credential looks
    // legitimate there.) Best-effort: open the just-imported DB with its
    // master-derived passphrase and clear the table.
    if result.is_ok() {
        if let Ok(passphrase) = derive_db_key() {
            let db_path = data_dir.join("messages.db");
            if let Ok(store) = crate::storage::MessageStore::open(
                db_path.to_str().unwrap_or_default(), &passphrase,
            ) {
                match store.clear_mls_identity() {
                    Ok(()) => hollow_log!("[HOLLOW-LINK] Cleared inherited MLS identity — fresh one will be minted on start"),
                    Err(e) => hollow_log!("[HOLLOW-LINK] Failed to clear inherited MLS identity: {e} (startup will still mint if absent)"),
                }
            } else {
                hollow_log!("[HOLLOW-LINK] Could not open imported DB to clear MLS identity (will rely on startup)");
            }
        }
    }

    match &result {
        Ok(()) => hollow_log!("[HOLLOW-LINK] Pending link imported via backup pipeline ({} bytes)", blob.len()),
        Err(e) => hollow_log!("[HOLLOW-LINK] Pending link import FAILED: {e}"),
    }
    result
}

// ── Pending data-dir wipe: next-boot clean slate ─────────────────────────────
//
// Used by the "Link a device" → Back/Cancel flow. That flow creates a THROWAWAY
// identity to connect, so backing out must leave a truly clean data dir for the
// next launch's Welcome (create new / import / link). We CAN'T reliably delete the
// DB files in-process: the running node holds open SQLCipher handles (CrdtStore /
// CryptoStore actor threads + WAL/-shm), and on Windows `remove_file` on an open
// file fails — leaving `messages.db` behind, encrypted with the throwaway
// passphrase, so the next identity can't open it → "infinite loading". So we mark a
// pending wipe, relaunch, and nuke the dir on the NEXT launch BEFORE the node starts
// (no open handles) — the exact same pre-node-start window as the link import above.

fn pending_wipe_marker_path() -> Result<std::path::PathBuf, String> {
    Ok(crate::identity::data_dir()?.join("pending_wipe.marker"))
}

/// Mark the data dir to be wiped clean on the next launch (pre-node-start). Call
/// this, then relaunch — do NOT try to delete the DB in-process while the node runs.
#[frb]
pub fn stash_pending_wipe() -> Result<(), String> {
    std::fs::write(pending_wipe_marker_path()?, b"1")
        .map_err(|e| format!("Failed to stash wipe marker: {e}"))?;
    Ok(())
}

/// True if a pending wipe is queued for this launch.
#[frb]
pub fn has_pending_wipe() -> Result<bool, String> {
    Ok(pending_wipe_marker_path()?.exists())
}

/// (At launch, BEFORE start_node) Delete every file/dir in the data dir so the next
/// Welcome starts from a truly clean slate. Preserves nothing identity-bearing:
/// removes `identity.key`/`identity.device`, `messages.db*`, `device_lists`, any
/// stashed `pending_link.*`, `vault/`, `files/`, etc. Keeps only the wipe marker
/// itself (removed last) and any `*.lock` single-instance guard. Idempotent.
#[frb]
pub fn perform_pending_wipe() -> Result<(), String> {
    let marker = pending_wipe_marker_path()?;
    let data_dir = crate::identity::data_dir()?;
    let marker_name = marker.file_name().map(|n| n.to_os_string());

    let entries = std::fs::read_dir(&data_dir)
        .map_err(|e| format!("Failed to read data dir for wipe: {e}"))?;
    let mut removed = 0u32;
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name();
        // Keep the marker (removed last) + any single-instance lock file.
        if Some(&name) == marker_name.as_ref() { continue; }
        if name.to_string_lossy().ends_with(".lock") { continue; }
        // Keep the profile registry (Settings > Profile switcher): it's
        // app-level config anchored in the default data root, not identity
        // data — erasing the default profile must not forget the others.
        if name.to_string_lossy() == "profiles.json" { continue; }
        let res = if path.is_dir() {
            std::fs::remove_dir_all(&path)
        } else {
            std::fs::remove_file(&path)
        };
        match res {
            Ok(()) => removed += 1,
            Err(e) => hollow_log!("[HOLLOW-WIPE] Failed to remove {}: {e}", path.display()),
        }
    }
    // Remove the marker last so a crash mid-wipe re-runs the wipe next launch.
    let _ = std::fs::remove_file(&marker);
    hollow_log!("[HOLLOW-WIPE] Data dir wiped for clean Welcome ({removed} entries removed)");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Install a fresh in-memory store into the process-global slot and hold
    /// the lock that serializes every test which swaps it.
    fn fresh_store() -> std::sync::MutexGuard<'static, ()> {
        let lock = store_test_lock();
        set_test_store(
            crate::storage::MessageStore::open(":memory:", &"ab".repeat(32))
                .expect("open in-memory store"),
        );
        lock
    }

    fn with_store<T>(body: impl FnOnce(&crate::storage::MessageStore) -> T) -> T {
        let guard = get_store().lock().unwrap_or_else(|e| e.into_inner());
        body(guard.as_ref().expect("store installed"))
    }

    /// Art bought from the artist shop is PINNED against the asset evictor.
    /// Everything else on the rail is a cache entry with a peer behind it; a
    /// `.hollowpack` import has a receipt behind it and nobody to re-pull it
    /// from, so eviction must walk past it and take the ordinary blob instead.
    #[test]
    fn owned_art_is_pinned_against_asset_eviction() {
        let _lock = fresh_store();

        let owned = "aa".repeat(32);
        let cached = "bb".repeat(32);

        with_store(|ms| {
            ms.save_asset_blob(&owned, &vec![7u8; 4096], false, "frame").unwrap();
            ms.save_asset_blob(&cached, &vec![9u8; 4096], false, "profile").unwrap();
            ms.save_owned_art(
                &owned,
                "frame",
                "item1",
                "Gilded frame",
                "Nadia",
                "nadia",
                "https://shop.anonlisten.com/@nadia",
                "Personal use",
            )
            .unwrap();

            // The keep-set names it before anything is deleted.
            assert!(
                referenced_asset_hashes(ms).contains(&owned),
                "owned art must be in the evictor's keep-set",
            );
        });

        // Drive the real eviction path: "clear everything unreferenced".
        let freed = clear_unreferenced_asset_blobs().expect("clear");
        assert_eq!(freed, 4096, "only the unowned blob may be freed");

        with_store(|ms| {
            assert!(
                ms.has_emote_blob(&owned).unwrap(),
                "paid-for art must survive eviction",
            );
            assert!(
                !ms.has_emote_blob(&cached).unwrap(),
                "an ordinary cached blob is still evictable",
            );
        });
    }
}
