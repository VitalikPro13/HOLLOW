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
    ms.insert(&peer_id, &text, is_mine, timestamp, signature.as_deref(), public_key.as_deref())
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
        })
        .collect())
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
    ms.insert_channel_message(&server_id, &channel_id, &sender_id, &text, is_mine, timestamp, signature.as_deref(), public_key.as_deref())
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
        })
        .collect())
}
