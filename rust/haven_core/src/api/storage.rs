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
}

// Global message store: None = not opened, Some = ready.
static STORE: OnceLock<Mutex<Option<MessageStore>>> = OnceLock::new();

fn get_store() -> &'static Mutex<Option<MessageStore>> {
    STORE.get_or_init(|| Mutex::new(None))
}

/// Derive a hex encryption key from the Ed25519 keypair on disk.
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

    let data_dir = dirs::data_dir().ok_or("Could not find app data directory")?;
    let haven_dir = data_dir.join("haven");
    std::fs::create_dir_all(&haven_dir)
        .map_err(|e| format!("Failed to create data dir: {e}"))?;
    let db_path = haven_dir.join("messages.db");

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
    ms.insert(&peer_id, &text, is_mine, timestamp, signature.as_deref(), public_key.as_deref(), None, None)
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
        })
        .collect())
}

/// A user profile returned to Dart.
pub struct UserProfile {
    pub peer_id: String,
    pub display_name: String,
    pub status: String,
    pub about_me: String,
    pub updated_at: i64,
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
        })
        .collect())
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
    ms.insert_channel_message(&server_id, &channel_id, &sender_id, &text, is_mine, timestamp, signature.as_deref(), public_key.as_deref(), None, None)
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
        })
        .collect())
}
