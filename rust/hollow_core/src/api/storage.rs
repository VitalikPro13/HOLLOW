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

/// Save a message to the local database.
#[frb]
pub fn save_message(
    peer_id: String,
    text: String,
    is_mine: bool,
    timestamp: i64,
    signature: Option<String>,
    public_key: Option<String>,
) -> Result<i64, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.insert(&peer_id, &text, is_mine, timestamp, signature.as_deref(), public_key.as_deref(), None, None, None)
}

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

// ── Verified Peers (RAT Files) ──────────────────────────────────

/// Mark a peer as identity-verified (fingerprint confirmed in person).
#[frb]
pub fn set_peer_verified(peer_id: String) -> Result<(), String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.set_peer_verified(&peer_id)
}

/// Remove verified status from a peer.
#[frb]
pub fn remove_peer_verified(peer_id: String) -> Result<(), String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.remove_peer_verified(&peer_id)
}

/// Check if a peer is identity-verified.
#[frb]
pub fn is_peer_verified(peer_id: String) -> Result<bool, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.is_peer_verified(&peer_id)
}

/// Get all verified peers as (peer_id, verified_at_ms) pairs.
#[frb]
pub fn get_verified_peers() -> Result<Vec<(String, i64)>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.get_verified_peers()
}

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

/// Save a channel message to the local database.
#[frb]
pub fn save_channel_message(
    server_id: String,
    channel_id: String,
    sender_id: String,
    text: String,
    is_mine: bool,
    timestamp: i64,
    signature: Option<String>,
    public_key: Option<String>,
) -> Result<i64, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.insert_channel_message(&server_id, &channel_id, &sender_id, &text, is_mine, timestamp, signature.as_deref(), public_key.as_deref(), None, None, None)
        .map(|n| n as i64)
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

/// Reset completed files whose disk_path no longer exists on disk.
/// Returns the count of reset entries. They'll be re-requested from peers.
#[frb]
pub fn reset_stale_files() -> Result<u32, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.reset_stale_file_paths()
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

    match &result {
        Ok(()) => hollow_log!("[HOLLOW-LINK] Pending link imported via backup pipeline ({} bytes)", blob.len()),
        Err(e) => hollow_log!("[HOLLOW-LINK] Pending link import FAILED: {e}"),
    }
    result
}
