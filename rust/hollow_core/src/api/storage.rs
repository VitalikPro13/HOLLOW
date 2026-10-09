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
    /// Album this message renders grouped into, `None` when standalone.
    pub album_id: Option<String>,
}

// Global message store: None = not opened, Some = ready.
static STORE: OnceLock<Mutex<Option<MessageStore>>> = OnceLock::new();

pub(crate) fn get_store() -> &'static Mutex<Option<MessageStore>> {
    STORE.get_or_init(|| Mutex::new(None))
}

/// Install a store into the process-global slot so a unit test can drive the `#[frb]`
/// functions that read it. Pair every use with [`store_test_lock`]: `STORE` is
/// process-wide and `cargo test` runs test functions in parallel threads.
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
    // The first 32 bytes of the protobuf-encoded keypair, deterministic per identity.
    let key_bytes = &proto[..32.min(proto.len())];
    Ok(hex::encode(key_bytes))
}

/// Open the encrypted message database, once at app start after the identity loads.
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
    let path = db_path.to_str().ok_or("Invalid path encoding")?;
    let ms = MessageStore::open(path, &passphrase).inspect_err(|e| note_store_refusal(&hollow_dir, e))?;
    // Dart can open the store before the node starts, and it reads attachments
    // through the key ring the moment it has one.
    if let Err(e) = crate::node::at_rest::init(path, &passphrase) {
        hollow_log!("[HOLLOW-ATREST] key ring unavailable: {e}");
    }

    *guard = Some(ms);
    Ok(())
}

/// A database that will not open stops the app before the node opens the log, so the
/// reason and which of the identity's files are there go into it here.
fn note_store_refusal(root: &std::path::Path, e: &str) {
    crate::log::init();
    let files: Vec<String> = IDENTITY_SET
        .iter()
        .chain([LANDING_STAGE, LANDING_ASIDE].iter())
        .filter_map(|name| {
            let meta = std::fs::symlink_metadata(root.join(name)).ok()?;
            Some(format!("{name}={}", meta.len()))
        })
        .collect();
    hollow_log!("[HOLLOW-STORE] The database would not open with this identity: {e} (files: {})", files.join(" "));
}

// `save_message` / `save_channel_message` are deliberately absent: both were
// Dart-callable inserts taking an OPTIONAL signature and no message_id, so they
// could write a row no peer will accept through sync and the mid-based dedup
// cannot reconcile. Message rows are written by the node's own signing paths.

/// The ids among `message_ids` (at most 500 are read) whose message was deleted,
/// so a reply can say so instead of looking like one to older history.
#[frb]
pub fn deleted_message_ids(message_ids: Vec<String>) -> Result<Vec<String>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    let capped = &message_ids[..message_ids.len().min(500)];
    ms.deleted_message_ids(capped)
}

/// Load recent messages for a peer, oldest-first, up to `limit`.
#[frb]
pub fn load_messages(peer_id: String, limit: i32) -> Result<Vec<StoredMessage>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;

    let rows = ms.load_for_peer(&peer_id, limit)?;
    drop(guard);
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
            album_id: r.album_id,
        })
        .collect())
}

/// Load ALL DM messages for a peer including hidden ones, oldest-first and unlimited,
/// for the archive viewer.
#[frb]
pub fn load_all_dm_messages(peer_id: String) -> Result<Vec<StoredMessage>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;

    let rows = ms.load_all_dm_messages(&peer_id)?;
    drop(guard);
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
            album_id: r.album_id,
        })
        .collect())
}

/// Load ALL channel messages including hidden ones, oldest-first and unlimited, for
/// the archive viewer.
#[frb]
pub fn load_all_channel_messages(server_id: String, channel_id: String) -> Result<Vec<StoredChannelMessage>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;

    let rows = ms.load_all_channel_messages(&server_id, &channel_id)?;
    drop(guard);
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
            album_id: r.album_id,
        })
        .collect())
}

/// Load edit history for a batch of message IDs, flat and sorted by edited_at.
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

/// Count all visible DM messages across every conversation, the Home card's honest
/// multi-device comparison number: DMs fully converge across a person's devices,
/// while lazy-paged channel messages would diverge.
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
    /// Avatar frame ID (issue #54): `""` = none, `"b:<hue>"` = built-in, 64-hex = an
    /// asset-rail blob hash pulled on demand.
    pub avatar_frame: String,
    /// Asset-rail hash of this person's ANIMATED avatar, `""` = still only.
    /// `avatar_bytes` above is the STILL companion the animation is painted over.
    pub avatar_anim: String,
    /// Asset-rail hash of this person's ANIMATED banner; `""` = still only.
    pub banner_anim: String,
    /// Support credentials: the verified JSON array as stored, `""` for none. A renderer
    /// lights a mark next to art whose hash is in an entry's `parts` and is worn.
    pub support_creds: String,
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
            support_creds: p.support_creds,
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
            support_creds: p.support_creds,
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
            support_creds: p.support_creds,
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
            support_creds: p.support_creds,
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
    // A pending friend shows its card thumb until the full avatar lands.
    ms.load_avatar_for_display(&peer_id)
}

/// Get only the banner bytes for a peer (lazy load for profile card/DM header).
#[frb]
pub fn get_banner(peer_id: String) -> Result<Option<Vec<u8>>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.load_banner(&peer_id)
}

// ── Call records ──────────────────────────────────────────────

/// One ended DM call, as this device saw it. Local only: it never rides the wire,
/// and it lives outside the message table so no sync, count or export reads it.
pub struct CallRecord {
    pub call_id: String,
    /// The conversation's MASTER id.
    pub peer_id: String,
    pub outgoing: bool,
    pub video: bool,
    /// How it ended: answered, missed, declined, cancelled, unanswered, failed.
    pub outcome: String,
    /// When it began ringing, in milliseconds.
    pub started_at: i64,
    /// When it connected; `None` for a call that never did.
    pub connected_at: Option<i64>,
    pub ended_at: i64,
}

fn call_record_from_row(r: crate::storage::CallRecordRow) -> CallRecord {
    CallRecord {
        call_id: r.call_id,
        peer_id: r.peer_id,
        outgoing: r.outgoing,
        video: r.video,
        outcome: r.outcome,
        started_at: r.started_at,
        connected_at: r.connected_at,
        ended_at: r.ended_at,
    }
}

/// Stores an ended DM call. A call id already stored is left unchanged.
#[frb]
pub fn record_dm_call(record: CallRecord) -> Result<(), String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.record_dm_call(&crate::storage::CallRecordRow {
        call_id: record.call_id,
        peer_id: record.peer_id,
        outgoing: record.outgoing,
        video: record.video,
        outcome: record.outcome,
        started_at: record.started_at,
        connected_at: record.connected_at,
        ended_at: record.ended_at,
    })
}

/// The newest `limit` calls with `peer_id` (a MASTER id), oldest first.
#[frb]
pub fn load_dm_call_records(peer_id: String, limit: u32) -> Result<Vec<CallRecord>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    Ok(ms
        .load_dm_call_records(&peer_id, limit)?
        .into_iter()
        .map(call_record_from_row)
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

/// A single settings row for the batched prefix load.
pub struct SettingEntry {
    pub key: String,
    pub value: String,
}

/// Load ALL settings whose key starts with `prefix` in ONE call, replacing the
/// per-key startup scans that cost one FFI round-trip per server, channel and DM.
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

/// One read pointer a sibling reported, as Dart hands it back to the store.
pub struct RemoteReadMarker {
    pub key: String,
    pub ts: i64,
}

/// A read pointer that moved: Dart adopts `message_id` as the seen pointer for
/// `key` and recounts that conversation.
pub struct AppliedReadMarker {
    pub key: String,
    pub message_id: String,
}

/// Adopt sibling read pointers (#80). Each advances by time and never regresses;
/// only the ones that moved come back. Malformed keys are skipped, not fatal.
#[frb]
pub fn apply_remote_read_markers(markers: Vec<RemoteReadMarker>) -> Result<Vec<AppliedReadMarker>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    Ok(markers
        .into_iter()
        .filter_map(|m| {
            let mid = ms.apply_remote_read_marker(&m.key, m.ts).ok().flatten()?;
            Some(AppliedReadMarker { key: m.key, message_id: mid })
        })
        .collect())
}

// Verified peers live in `api::verification` so every entry point resolves device to
// master in one auditable place: a verified flag stored under a device id stops
// applying the moment that contact links a device.

/// Count unread, non-hidden DM messages newer than the last-seen message ID.
#[frb]
pub fn count_unread_dm(peer_id: String, last_seen_message_id: String) -> Result<u32, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    Ok(ms.count_unread_dm(&peer_id, &last_seen_message_id))
}

/// Count unread, non-hidden channel messages newer than the last-seen message ID.
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

/// Block an identity (MASTER-keyed): persists the row and warms the in-memory set the
/// Rust ingest guards read, so it takes effect immediately. Purely local, so the
/// blocked peer learns nothing. Any of their ids works; it is collapsed to the master.
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
    // A node that is not running has no room to leave, and its next start joins none.
    let _ = crate::api::network::send_node_command(crate::node::NodeCommand::BlockChanged { master, blocked: true });
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
    let _ = crate::api::network::send_node_command(crate::node::NodeCommand::BlockChanged { master, blocked: false });
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
    let found = ms.search_channel_messages(&server_id, &channel_id, &query, limit);
    drop(guard);
    found
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
                    album_id: m.album_id,
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
    let found = ms.search_dm_messages(&peer_id, &query, limit);
    drop(guard);
    found
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
                    album_id: m.album_id,
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
    /// Album this message renders grouped into, `None` when standalone.
    pub album_id: Option<String>,
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
    drop(guard);
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
            album_id: r.album_id,
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
    /// Back-reference to the vault-stored video this file is a thumbnail for, which the
    /// UI uses to draw the play overlay and start the vault download on tap.
    pub video_thumb: Option<crate::api::network::VideoThumbRef>,
    /// Persisted share swarm root hash for share-backed (>34 MB) files —
    /// lets a manual download rejoin the share after a restart (issue #41).
    pub share_root_hash: Option<String>,
    /// Persisted share AES key (hex) paired with `share_root_hash`.
    pub share_key_hex: Option<String>,
    /// Tiny base64 WebP placeholder, rendered blurred under the Download button while
    /// the real bytes are gated or undownloaded.
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
        thumb_b64: f
            .thumb_b64
            .and_then(|t| crate::node::image_convert::peer_thumb_for_display(&t))
            .map(|(b64, _, _)| b64),
    }
}

/// Get file metadata by file ID.
#[frb]
pub fn get_file_metadata(file_id: String) -> Result<Option<StoredFileInfo>, String> {
    let row = {
        let store = get_store();
        let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        let ms = guard.as_ref().ok_or("Message store is not open")?;
        ms.get_file_metadata(&file_id)?
    };
    Ok(row.map(stored_file_to_ffi))
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
    let rows = {
        let store = get_store();
        let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        let ms = guard.as_ref().ok_or("Message store is not open")?;
        ms.get_files_for_message(&message_id)?
    };
    Ok(rows.into_iter().map(stored_file_to_ffi).collect())
}

/// One image or video of a conversation, for the media viewer.
pub struct MediaListItem {
    pub file: StoredFileInfo,
    /// Milliseconds. The owning message's time, else the file's `created_at`.
    pub ts: i64,
    pub content_id: Option<String>,
    pub album_id: Option<String>,
}

/// Images and videos of one conversation, newest first, for the media viewer.
///
/// `before_ts` and `after_ts` are exclusive millisecond bounds, so a caller pages
/// both ways from the item it opened. `limit` is clamped to 1..=200.
#[frb]
pub fn list_media_for_context(
    context_type: String,
    context_id: String,
    before_ts: Option<i64>,
    after_ts: Option<i64>,
    limit: u32,
) -> Result<Vec<MediaListItem>, String> {
    let rows = {
        let store = get_store();
        let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        let ms = guard.as_ref().ok_or("Message store is not open")?;
        ms.list_media_for_context(&context_type, &context_id, before_ts, after_ts, limit)?
    };
    Ok(rows
        .into_iter()
        .map(|m| MediaListItem {
            file: stored_file_to_ffi(m.file),
            ts: m.ts,
            content_id: m.content_id,
            album_id: m.album_id,
        })
        .collect())
}

/// Get all incomplete files (for sync resume).
#[frb]
pub fn get_incomplete_files() -> Result<Vec<StoredFileInfo>, String> {
    let rows = {
        let store = get_store();
        let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        let ms = guard.as_ref().ok_or("Message store is not open")?;
        ms.get_incomplete_files()?
    };
    Ok(rows.into_iter().map(stored_file_to_ffi).collect())
}

/// Mark a file as complete with its disk path (used for share-backed files). A
/// committed file's bytes must be the ones its id commits to; the hash runs with the
/// store unlocked, since a share download can be gigabytes.
#[frb]
pub fn mark_file_complete(file_id: String, disk_path: String) -> Result<(), String> {
    use crate::node::file_commit;
    let store = get_store();
    if file_commit::is_committed_id(&file_id) {
        let row = {
            let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
            let ms = guard.as_ref().ok_or("Message store is not open")?;
            ms.get_file_metadata(&file_id)?
        };
        let refusal = match (row, file_commit::hash_at_rest(std::path::Path::new(&disk_path))) {
            (Some(row), Some((len, sha256))) => file_commit::content_refused(&row, len, &sha256),
            (None, _) => Some("no file card to check the bytes against"),
            (_, None) => Some("the bytes on disk could not be read"),
        };
        if let Some(reason) = refusal {
            hollow_log!("[HOLLOW-SECURITY] REFUSED to complete {file_id} from {disk_path}: {reason}");
            return Err(crate::node::file_handler::FORGED_FILE_ERROR.to_string());
        }
    }
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.mark_file_complete(&file_id, &disk_path)
}

/// file_ids from messages with no completed file on disk, for post-sync downloads.
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

/// Sum the byte sizes of regular files directly inside `dir`; files/ and vault_cache/
/// are flat. Skips transient sender-side stream temps so an in-flight send does not
/// inflate the reported usage.
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

/// Every asset hash still referenced by a personal set or replicated CRDT state.
/// Eviction and "clear" must never drop these: a personal emote or a server's active
/// emote would go blank until re-pulled, and WE may be the only online holder for a
/// server we own.
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
            // These settings carry a blob hash; cleared values are not hex and are skipped.
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
    // OUR OWN avatar frame and animated avatar/banner, pinned because other people's
    // are re-pullable from their owner while ours has no other holder until somebody
    // who has seen them comes online. Mirrored into settings because this function
    // has no identity to look the profile row up by.
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
    // Art bought from the artist shop, worn or not: a `.hollowpack` import is the one
    // thing on the rail with no peer to re-pull it from and a receipt behind it, so
    // evicting it would destroy something somebody paid for. Every owned hash is
    // pinned, stills and unused halves included.
    if let Ok(owned) = ms.owned_art_hashes() {
        keep.extend(owned);
    }
    keep
}

/// `app_settings` key mirroring our own `UserProfile.avatar_frame`, so the
/// asset evictor can pin it without resolving our identity.
pub(crate) const MY_AVATAR_FRAME_SETTING: &str = "my_avatar_frame";

/// `app_settings` keys mirroring our own animated avatar/banner hashes, so the asset
/// evictor can pin them without resolving our identity.
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
            if crate::node::at_rest::remove(path).is_ok() {
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
            if crate::node::at_rest::remove(path).is_ok() {
                freed += meta.len();
            }
        }
    }
    // Also sweep any orphan files in files/ not tracked by a row.
    let files_dir = crate::vault::pipeline::files_dir();
    if let Ok(entries) = std::fs::read_dir(&files_dir) {
        for entry in entries.flatten() {
            if let Ok(meta) = entry.metadata() {
                if meta.is_file() && crate::node::at_rest::remove(&entry.path()).is_ok() {
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
                if meta.is_file() && crate::node::at_rest::remove(&entry.path()).is_ok() {
                    freed += meta.len();
                }
            }
        }
    }
    Ok(freed)
}

/// Enforce the cache caps (files/, vault_cache/ and the asset blob cache) after a
/// download completes, so the user-set sliders are actually honoured. Returns bytes
/// freed.
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

/// Check if an identity key file exists on disk.
#[frb]
pub fn has_identity() -> Result<bool, String> {
    let dir = crate::identity::data_dir()?;
    Ok(dir.join("identity.key").exists())
}

/// Delete the on-disk identity and local DB so the next launch shows a fresh Welcome.
/// Used to discard the THROWAWAY identity of a cancelled "Link a device" flow.
/// DESTRUCTIVE: only call on a throwaway with no real data, and restart afterwards,
/// because the live DB handle is still open.
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

/// Build the plaintext snapshot ZIP in memory: `identity.key` plus a WAL-checkpointed
/// `messages.db`, optionally `vault/` shards and `files/` downloads.
///
/// The shared core of both the on-disk backup (wrapped in Argon2id+AES) and the
/// multi-device link snapshot (wrapped in a one-time random AES key). Returns the raw
/// zip bytes.
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
            // Always export the PLAINTEXT keypair: the wrapping layer provides the
            // encryption, and loading transparently decrypts a protected file.
            let id = crate::identity::load_or_create_identity()?;
            let data = id.keypair.to_protobuf_encoding()
                .map_err(|e| format!("Failed to encode keypair: {e}"))?;
            zip.start_file("identity.key", options).map_err(|e| format!("Zip error: {e}"))?;
            zip.write_all(&data).map_err(|e| format!("Zip write error: {e}"))?;
        }

        let db_path = data_dir.join("messages.db");
        if db_path.exists() {
            let data = scrubbed_db_copy(&data_dir, &db_path)?;
            zip.start_file("messages.db", options).map_err(|e| format!("Zip error: {e}"))?;
            zip.write_all(&data).map_err(|e| format!("Zip write error: {e}"))?;
        }

        if include_vault {
            let vault_dir = data_dir.join("vault");
            if vault_dir.exists() && vault_dir.is_dir() {
                for entry in std::fs::read_dir(&vault_dir).map_err(|e| format!("Failed to read vault dir: {e}"))? {
                    if let Ok(entry) = entry {
                        let path = entry.path();
                        let leaf = entry.file_name().to_string_lossy().into_owned();
                        if path.is_file() && snapshot_leaf(&leaf) {
                            let name = format!("vault/{leaf}");
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
                        let leaf = entry.file_name().to_string_lossy().into_owned();
                        if path.is_file() && snapshot_leaf(&leaf) {
                            let name = format!("files/{leaf}");
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

// What a snapshot may unpack to. A real one is nearly all ciphertext (the database,
// at-rest files) and barely compresses, so a generous multiple of its own size, with a
// floor for a small account: a link or backup of any size still lands. Every entry also
// pays for the file it lands as, so a flood of empty entries is bounded too.
const SNAPSHOT_MIN_UNPACKED: u64 = 64 << 20;
const SNAPSHOT_UNPACK_RATIO: u64 = 32;
const SNAPSHOT_ENTRY_COST: u64 = 4096;

/// A transfer's reassembly or send temp (`.ws_recv_*.tmp`, `.stream_send_*.tmp`, ...),
/// never content.
fn transfer_temp(leaf: &str) -> bool {
    leaf.starts_with('.') && leaf.ends_with(".tmp")
}

/// A file of `vault/` or `files/` a snapshot carries.
fn snapshot_leaf(leaf: &str) -> bool {
    !transfer_temp(leaf) && crate::node::share_handler::is_inert_file_name(leaf)
}

/// Where a snapshot entry lands under the data folder; `None` for a transfer temp an
/// older export carried. Only what `build_snapshot_bytes` writes lands: any other entry
/// (a path out of the folder, a key file, a marker, the profile registry) refuses the
/// whole snapshot.
fn snapshot_landing(entry: &zip::read::ZipFile<'_>) -> Result<Option<std::path::PathBuf>, String> {
    let foreign = || "This backup holds a file Hollow never puts in a backup, so nothing was restored.".to_string();
    let path = entry.enclosed_name().filter(|_| entry.is_file()).ok_or_else(foreign)?;
    let parts: Option<Vec<&str>> = path
        .components()
        .map(|c| match c {
            std::path::Component::Normal(part) => part.to_str(),
            _ => None,
        })
        .collect();
    match parts.as_deref() {
        Some(["identity.key"] | ["messages.db"]) => Ok(Some(path.clone())),
        Some(["vault" | "files", leaf]) if transfer_temp(leaf) => Ok(None),
        Some([dir @ ("vault" | "files"), leaf]) if snapshot_leaf(leaf) => Ok(Some([dir, leaf].iter().collect())),
        _ => Err(foreign()),
    }
}

/// A snapshot every entry of which was judged and measured: `(index, landing, bytes)`.
struct CheckedSnapshot<'a> {
    archive: zip::ZipArchive<std::io::Cursor<&'a [u8]>>,
    landings: Vec<(usize, std::path::PathBuf, u64)>,
}

/// Judge every entry and unpack it into nothing, so a snapshot that holds anything it
/// should not, unpacks past its budget or holds no identity costs the data folder nothing.
fn check_snapshot(zip_bytes: &[u8]) -> Result<CheckedSnapshot<'_>, String> {
    use std::io::Read;
    let too_big = || "This backup unpacks to far more than its size, so nothing was restored.".to_string();
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(zip_bytes))
        .map_err(|e| format!("Invalid snapshot data: {e}"))?;
    let mut left = (zip_bytes.len() as u64)
        .saturating_mul(SNAPSHOT_UNPACK_RATIO)
        .max(SNAPSHOT_MIN_UNPACKED);
    let mut landings = Vec::new();
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i).map_err(|e| format!("Zip read error: {e}"))?;
        let landing = snapshot_landing(&entry)?;
        left = left.checked_sub(SNAPSHOT_ENTRY_COST).ok_or_else(too_big)?;
        let Some(path) = landing else { continue };
        let size = std::io::copy(&mut (&mut entry).take(left.saturating_add(1)), &mut std::io::sink())
            .map_err(|e| format!("Failed to read zip entry: {e}"))?;
        left = left.checked_sub(size).ok_or_else(too_big)?;
        landings.push((i, path, size));
    }
    if !landings.iter().any(|(_, path, _)| path.as_os_str() == "identity.key") {
        return Err("Snapshot does not contain identity.key".into());
    }
    Ok(CheckedSnapshot { archive, landings })
}

/// The database as it may leave this device: a copy with this device's Olm and MLS
/// identities and any stored recovery phrase removed. The live database is untouched.
fn scrubbed_db_copy(data_dir: &std::path::Path, db_path: &std::path::Path) -> Result<Vec<u8>, String> {
    let db_passphrase = derive_db_key()?;
    if let Ok(store) = crate::storage::MessageStore::open(
        db_path.to_str().unwrap_or_default(), &db_passphrase,
    ) {
        let _ = store.wal_checkpoint();
    }
    let copy = data_dir.join("export_scrub.db");
    let _ = std::fs::remove_file(&copy);
    std::fs::copy(db_path, &copy).map_err(|e| format!("Failed to copy messages.db: {e}"))?;
    let scrubbed = (|| {
        let store = crate::storage::MessageStore::open(copy.to_str().unwrap_or_default(), &db_passphrase)?;
        store.scrub_device_secrets()?;
        drop(store);
        std::fs::read(&copy).map_err(|e| format!("Failed to read the scrubbed copy: {e}"))
    })();
    for leftover in ["export_scrub.db", "export_scrub.db-wal", "export_scrub.db-shm"] {
        let _ = std::fs::remove_file(data_dir.join(leftover));
    }
    scrubbed
}

/// Extract a plaintext snapshot ZIP into the data directory, replacing the identity and
/// its database as one. Shared core of `import_backup` and the link-snapshot import.
pub(crate) fn import_snapshot_bytes(zip_bytes: &[u8]) -> Result<(), String> {
    land_snapshot(check_snapshot(zip_bytes)?, None)
}

/// Set once a link or a restore lands an identity: the app offers a lock at its next
/// start and clears it (Dart `kProtectionOfferDueKey`).
pub(crate) const PROTECTION_OFFER_DUE: &str = "protection_offer_due";

// ── Landing: an identity and its database change together ─────────────────────
//
// A key beside another identity's database, or beside that database's WAL, opens
// nothing ("file is not a database" at every launch). So a landing writes the new set
// to a stage, moves the whole old set aside, and only then moves the new one in; a
// step that fails puts the old set back. Windows refuses to move a file another
// program holds, so the move aside also proves nothing holds the old set.

/// Everything that belongs to one identity. The database goes first: it is the file
/// another program may hold, and nothing else has moved when it refuses.
const IDENTITY_SET: [&str; 5] = [
    "messages.db",
    "messages.db-wal",
    "messages.db-shm",
    "identity.device",
    "identity.key",
];
const LANDING_STAGE: &str = ".landing";
const LANDING_ASIDE: &str = ".replaced";
/// In the aside folder once the whole old set is in it.
const ASIDE_MOVED: &str = "moved";
/// In the root from the moment the whole new set is in place until every leftover of
/// the landing is gone. It sits outside the folders the cleanup deletes, so no partial
/// delete can make a finished landing look unfinished.
const LANDED: &str = ".landed";

/// What any start-up refusal says, a pending wipe's included: nothing on screen may
/// tell that a wipe ran.
pub(crate) const IDENTITY_NOT_READY: &str = "Hollow is still starting up. Try again in a moment.";

/// How long a landing or a boot wipe waits for a file something else holds, such as
/// a scanner that opened the database a moment ago.
#[cfg(not(test))]
const HELD_FILE_WAIT: std::time::Duration = std::time::Duration::from_secs(3);
#[cfg(test)]
const HELD_FILE_WAIT: std::time::Duration = std::time::Duration::from_millis(300);

/// Test hook: the commit fails at this file, as a full disk would.
#[cfg(test)]
static FAIL_COMMIT_AT: Mutex<Option<&'static str>> = Mutex::new(None);
/// Test hook: the process dies at this file, so nothing after it runs.
#[cfg(test)]
static CRASH_COMMIT_AT: Mutex<Option<&'static str>> = Mutex::new(None);
#[cfg(test)]
static COMMIT_SAW_LANDING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
/// Test hook: the process dies at this step of a finished landing's cleanup.
#[cfg(test)]
static CRASH_CLEANUP_AT: Mutex<Option<&'static str>> = Mutex::new(None);

#[cfg(test)]
fn cleanup_crash_point(step: &'static str) {
    if *CRASH_CLEANUP_AT.lock().unwrap_or_else(|e| e.into_inner()) == Some(step) {
        panic!("the process died at the cleanup's {step} step");
    }
}

/// Set from the moment the old set starts moving until the new one is in place:
/// a missing `identity.key` then is no reason to mint one.
static LANDING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

pub(crate) fn landing_in_progress() -> bool {
    LANDING.load(std::sync::atomic::Ordering::Acquire)
}

struct LandingFlag;

impl LandingFlag {
    fn raise() -> Self {
        LANDING.store(true, std::sync::atomic::Ordering::Release);
        LandingFlag
    }
}

impl Drop for LandingFlag {
    fn drop(&mut self) {
        LANDING.store(false, std::sync::atomic::Ordering::Release);
    }
}

fn present(path: &std::path::Path) -> bool {
    std::fs::symlink_metadata(path).is_ok()
}

/// A rename that tries again while the source is held, until `deadline`.
fn rename_when_free(
    from: &std::path::Path,
    to: &std::path::Path,
    deadline: std::time::Instant,
) -> std::io::Result<()> {
    loop {
        match std::fs::rename(from, to) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound && std::time::Instant::now() < deadline => {
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            done => return done,
        }
    }
}

/// Writes the snapshot's files into `stage`, plus the device key a link installs.
fn stage_new_set(
    archive: &mut zip::ZipArchive<std::io::Cursor<&[u8]>>,
    landings: &[(usize, std::path::PathBuf, u64)],
    stage: &std::path::Path,
    device: Option<&[u8]>,
) -> Result<u64, String> {
    use std::io::{Read, Write};

    std::fs::create_dir_all(stage).map_err(|e| format!("Failed to create dir: {e}"))?;
    let mut landed = 0u64;
    for (i, rel, size) in landings {
        let mut entry = archive.by_index(*i).map_err(|e| format!("Zip read error: {e}"))?;
        let out_path = stage.join(rel);
        if let Some(parent) = out_path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| format!("Failed to create dir: {e}"))?;
        }
        let mut out = std::fs::File::create(&out_path)
            .map_err(|e| format!("Failed to write {}: {e}", rel.display()))?;
        std::io::copy(&mut (&mut entry).take(*size), &mut out)
            .map_err(|e| format!("Failed to write {}: {e}", rel.display()))?;
        // A power cut after the rename must not leave an empty key or database.
        out.sync_all().map_err(|e| format!("Failed to write {}: {e}", rel.display()))?;
        landed = landed.saturating_add(*size);
    }
    if let Some(device) = device {
        let mut out = std::fs::File::create(stage.join("identity.device"))
            .map_err(|e| format!("Failed to install the new device key: {e}"))?;
        out.write_all(device)
            .and_then(|()| out.sync_all())
            .map_err(|e| format!("Failed to install the new device key: {e}"))?;
    }
    Ok(landed)
}

/// Moves every file of the old set into `aside`, then marks it moved.
fn set_aside_old_set(
    root: &std::path::Path,
    aside: &std::path::Path,
    deadline: std::time::Instant,
) -> Result<(), String> {
    std::fs::create_dir_all(aside).map_err(|e| format!("Failed to make room for the old identity: {e}"))?;
    for name in IDENTITY_SET {
        let from = root.join(name);
        if !present(&from) {
            continue;
        }
        rename_when_free(&from, &aside.join(name), deadline)
            .map_err(|e| format!("{name} is in use by another program ({e})"))?;
    }
    std::fs::write(aside.join(ASIDE_MOVED), b"")
        .map_err(|e| format!("Failed to mark the old identity moved: {e}"))
}

/// Moves the staged identity and database into the root, then marks the landing done.
fn commit_new_set(root: &std::path::Path, stage: &std::path::Path) -> Result<(), String> {
    for name in ["identity.key", "identity.device", "messages.db"] {
        let from = stage.join(name);
        if !present(&from) {
            continue;
        }
        #[cfg(test)]
        if *FAIL_COMMIT_AT.lock().unwrap_or_else(|e| e.into_inner()) == Some(name) {
            COMMIT_SAW_LANDING.store(landing_in_progress(), std::sync::atomic::Ordering::Release);
            return Err(format!("Failed to place {name}: test fault"));
        }
        #[cfg(test)]
        if *CRASH_COMMIT_AT.lock().unwrap_or_else(|e| e.into_inner()) == Some(name) {
            panic!("the process died placing {name}");
        }
        std::fs::rename(&from, root.join(name)).map_err(|e| format!("Failed to place {name}: {e}"))?;
    }
    let marked = std::fs::File::create(root.join(LANDED)).and_then(|mark| mark.sync_all());
    #[cfg(test)]
    if *FAIL_COMMIT_AT.lock().unwrap_or_else(|e| e.into_inner()) == Some(LANDED) {
        return Err("Failed to mark the new identity placed: test fault".to_string());
    }
    marked.map_err(|e| format!("Failed to mark the new identity placed: {e}"))
}

/// Undoes a landing that did not finish. The landed mark goes first, so a crash
/// partway never leaves the old set aside under a mark that calls it replaced. Once
/// the whole old set was moved, whatever stands in its place is new and goes; the
/// moved mark goes before anything returns, so a second pass never takes the old set
/// for new. Nothing is put back over a file already in the root.
fn roll_back_landing(root: &std::path::Path, aside: &std::path::Path) -> Result<(), String> {
    let landed = root.join(LANDED);
    if present(&landed) {
        std::fs::remove_file(&landed).map_err(|e| format!("Failed to clear the landed mark: {e}"))?;
    }
    if !present(aside) {
        return Ok(());
    }
    let moved = aside.join(ASIDE_MOVED);
    if present(&moved) {
        for name in IDENTITY_SET {
            let p = root.join(name);
            if present(&p) {
                std::fs::remove_file(&p).map_err(|e| format!("Failed to remove the new {name}: {e}"))?;
            }
        }
        std::fs::remove_file(&moved).map_err(|e| format!("Failed to clear the moved mark: {e}"))?;
    }
    let back: Vec<&str> = IDENTITY_SET.into_iter().filter(|name| present(&aside.join(name))).collect();
    if let Some(taken) = back.iter().find(|name| present(&root.join(name))) {
        return Err(format!("{taken} is in place already, so the old set stays aside"));
    }
    for name in back {
        std::fs::rename(aside.join(name), root.join(name)).map_err(|e| format!("Failed to put back {name}: {e}"))?;
    }
    std::fs::remove_dir_all(aside).map_err(|e| format!("Failed to clear the old identity's folder: {e}"))
}

/// Clears what a finished landing leaves behind, and returns how many content files
/// would not go into place. The landed mark goes last, so what a crash or a held file
/// leaves still reads as finished and goes at a later launch.
fn finish_landing(root: &std::path::Path) -> (usize, Result<(), String>) {
    #[cfg(test)]
    cleanup_crash_point("content");
    let stage = root.join(LANDING_STAGE);
    let misplaced = place_content(&stage, root);
    (misplaced, clear_landing_leftovers(root, &stage))
}

fn clear_landing_leftovers(root: &std::path::Path, stage: &std::path::Path) -> Result<(), String> {
    if present(stage) {
        std::fs::remove_dir_all(stage).map_err(|e| format!("Failed to clear the landing's stage: {e}"))?;
    }
    let aside = root.join(LANDING_ASIDE);
    #[cfg(test)]
    cleanup_crash_point("moved");
    // Before the old set: should the landed mark ever be lost, what is left aside
    // still never reads as a commit cut short.
    let moved = aside.join(ASIDE_MOVED);
    if present(&moved) {
        std::fs::remove_file(&moved).map_err(|e| format!("Failed to clear the moved mark: {e}"))?;
    }
    #[cfg(test)]
    cleanup_crash_point("aside");
    if present(&aside) {
        std::fs::remove_dir_all(&aside).map_err(|e| format!("Failed to clear the replaced identity: {e}"))?;
    }
    #[cfg(test)]
    cleanup_crash_point("landed");
    let landed = root.join(LANDED);
    if present(&landed) {
        std::fs::remove_file(&landed).map_err(|e| format!("Failed to clear the landed mark: {e}"))?;
    }
    Ok(())
}

/// Finishes what a landing a crash cut short left behind: a finished one loses its
/// leftovers, an unfinished one is undone. Runs before every landing and at every
/// launch (`has_pending_link`), so a stale journal never meets a later identity.
fn recover_interrupted_landing(root: &std::path::Path) -> Result<(), String> {
    // A pending wipe owns the root and takes the leftovers with it; nothing may be
    // put back into a root it is emptying.
    if present(&root.join(PENDING_WIPE_MARKER)) {
        return Ok(());
    }
    if present(&root.join(LANDED)) {
        return finish_landing(root).1;
    }
    let stage = root.join(LANDING_STAGE);
    if present(&stage) {
        std::fs::remove_dir_all(&stage).map_err(|e| format!("Failed to clear an old landing: {e}"))?;
    }
    let aside = root.join(LANDING_ASIDE);
    if !present(&aside) {
        return Ok(());
    }
    let undone = roll_back_landing(root, &aside);
    crate::log::init();
    hollow_log!("[HOLLOW-LINK] Undid a landing that did not finish: {undone:?}");
    undone
}

/// Moves the staged `vault/` and `files/` into the root; returns how many would not go.
fn place_content(stage: &std::path::Path, root: &std::path::Path) -> usize {
    let mut misplaced = 0;
    for dir in ["vault", "files"] {
        let Ok(entries) = std::fs::read_dir(stage.join(dir)) else { continue };
        let target = root.join(dir);
        if std::fs::create_dir_all(&target).is_err() {
            misplaced += 1;
            continue;
        }
        for entry in entries.flatten() {
            if std::fs::rename(entry.path(), target.join(entry.file_name())).is_err() {
                misplaced += 1;
            }
        }
    }
    misplaced
}

fn land_snapshot(snapshot: CheckedSnapshot<'_>, device: Option<&[u8]>) -> Result<(), String> {
    let CheckedSnapshot { mut archive, landings } = snapshot;
    let data_dir = crate::identity::data_dir()?;
    // The next launch's wipe would take whatever lands now.
    if present(&data_dir.join(PENDING_WIPE_MARKER)) {
        return Err(IDENTITY_NOT_READY.to_string());
    }
    recover_interrupted_landing(&data_dir)?;

    let stage = data_dir.join(LANDING_STAGE);
    let landed = match stage_new_set(&mut archive, &landings, &stage, device) {
        Ok(landed) => landed,
        Err(e) => {
            let _ = std::fs::remove_dir_all(&stage);
            return Err(e);
        }
    };

    // This process lets go of the old database before it moves.
    if let Ok(mut guard) = get_store().lock() {
        let _ = guard.take();
    }
    crate::node::at_rest::forget_stores();

    let aside = data_dir.join(LANDING_ASIDE);
    let deadline = std::time::Instant::now() + HELD_FILE_WAIT;
    let flag = LandingFlag::raise();
    let swapped = set_aside_old_set(&data_dir, &aside, deadline)
        .and_then(|()| commit_new_set(&data_dir, &stage));
    if let Err(e) = swapped {
        let undone = roll_back_landing(&data_dir, &aside);
        drop(flag);
        let _ = std::fs::remove_dir_all(&stage);
        return Err(match undone {
            Ok(()) => e,
            Err(u) => format!("{e}; the old identity is not back yet ({u})"),
        });
    }
    drop(flag);

    crate::log::init();
    let (misplaced, cleared) = finish_landing(&data_dir);
    if let Err(e) = cleared {
        hollow_log!("[HOLLOW-LINK] The replaced identity's files go at a later launch: {e}");
    }
    hollow_log!(
        "[HOLLOW-LINK] Import wrote {} file(s), {landed} bytes, {misplaced} content file(s) not placed",
        landings.len()
    );

    // messages.db was just replaced, so the key ring must re-register against the
    // IMPORTED database rather than the one that is gone.
    crate::node::at_rest::forget_stores();

    // A restored or linked device is a NEW device: it mints its own Olm and MLS
    // identities. An older snapshot still carries its source's, and its phrase.
    if let Ok(passphrase) = derive_db_key() {
        let db_path = data_dir.join("messages.db");
        if let Ok(store) = crate::storage::MessageStore::open(db_path.to_str().unwrap_or_default(), &passphrase) {
            if let Err(e) = store.scrub_device_secrets() {
                hollow_log!("[HOLLOW-LINK] Could not clear the source device's secrets: {e}");
            }
            // The keys landed unprotected whatever the source used (C-IDENTITY-15).
            let _ = store.save_setting(PROTECTION_OFFER_DUE, "1");
        }
    }

    // Log what the imported identity resolves to: the master peer_id MUST match the
    // source device's, and the next launch derives the DB passphrase from this key.
    match crate::identity::load_or_create_identity() {
        Ok(id) => {
            hollow_log!(
                "[HOLLOW-LINK] Import OK — imported identity peer_id={} device_peer_id={}",
                id.peer_id, id.device_peer_id
            );
            // What the source device was told about our own devices happened before
            // this one joined: no news here (C-IDENTITY-09).
            if let Ok(passphrase) = derive_db_key()
                && let Ok(store) = crate::storage::MessageStore::open(
                    data_dir.join("messages.db").to_str().unwrap_or_default(),
                    &passphrase,
                )
            {
                let _ = store.acknowledge_security_alerts_for_peer(&id.peer_id);
            }
        }
        Err(e) => hollow_log!("[HOLLOW-LINK] Import WARNING — imported identity failed to load: {e}"),
    }

    Ok(())
}

/// A compact summary of local DB state, used by multi-device linking to decide which
/// device is populated and which is empty. Not a user-facing feature on its own.
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

/// Build a passphrase-encrypted `.hollow` backup blob IN MEMORY, the same format
/// `export_backup` writes: `[magic:6][salt:16][nonce:12][ciphertext]`, Argon2id-derived
/// AES-256-GCM. The multi-device link transfer uses the link CODE as the passphrase,
/// so the receiver imports through the identical pipeline.
pub(crate) fn export_backup_bytes(passphrase: &str, include_vault: bool, include_files: bool) -> Result<Vec<u8>, String> {
    use aes_gcm::{Aes256Gcm, KeyInit, aead::Aead};
    use aes_gcm::Nonce;

    let zip_bytes = build_snapshot_bytes(include_vault, include_files)?;

    let mut salt = [0u8; 16];
    getrandom::fill(&mut salt).map_err(|e| format!("RNG error: {e}"))?;
    let params = argon2::Params::new(65536, 3, 1, Some(32))
        .map_err(|e| format!("Argon2 params error: {e}"))?;
    let argon = argon2::Argon2::new(argon2::Algorithm::Argon2id, argon2::Version::V0x13, params);
    let mut key = [0u8; 32];
    argon.hash_password_into(passphrase.as_bytes(), &salt, &mut key)
        .map_err(|e| format!("Argon2 hash error: {e}"))?;

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

/// The shortest passphrase a new `.hollow` file is sealed with. The file holds the
/// master key and the whole history and can be attacked offline, so the passphrase is
/// all that guards it; twelve characters is a few words, well beyond a search at
/// Argon2id's 64 MiB a guess. Opening an older file asks nothing of its passphrase.
const MIN_BACKUP_PASSPHRASE_CHARS: usize = 12;

#[frb]
pub fn export_backup(output_path: String, include_vault: bool, include_files: bool, passphrase: String) -> Result<u64, String> {
    if passphrase.trim().chars().count() < MIN_BACKUP_PASSPHRASE_CHARS {
        return Err(format!(
            "Use a passphrase of at least {MIN_BACKUP_PASSPHRASE_CHARS} characters."
        ));
    }
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
    import_snapshot_bytes(&decrypt_backup_bytes(blob, passphrase)?)
}

/// Open a `.hollow` blob to its snapshot zip without touching the data directory.
pub(crate) fn decrypt_backup_bytes(blob: &[u8], passphrase: &str) -> Result<Vec<u8>, String> {
    use aes_gcm::{Aes256Gcm, KeyInit, aead::Aead};
    use aes_gcm::Nonce;

    if blob.len() < 6 + 16 + 12 + 16 || &blob[..6] != b"HOLLOW" {
        return Err("Invalid backup file (not a Hollow backup)".into());
    }

    let salt = &blob[6..22];
    let nonce_bytes = &blob[22..34];
    let ciphertext = &blob[34..];

    let params = argon2::Params::new(65536, 3, 1, Some(32))
        .map_err(|e| format!("Argon2 params error: {e}"))?;
    let argon = argon2::Argon2::new(argon2::Algorithm::Argon2id, argon2::Version::V0x13, params);
    let mut key = [0u8; 32];
    argon.hash_password_into(passphrase.as_bytes(), salt, &mut key)
        .map_err(|e| format!("Argon2 hash error: {e}"))?;

    let cipher = Aes256Gcm::new_from_slice(&key)
        .map_err(|e| format!("Cipher init error: {e}"))?;
    let nonce = Nonce::from_slice(nonce_bytes);
    cipher.decrypt(nonce, ciphertext)
        .map_err(|_| "Wrong passphrase or corrupted backup".to_string())
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
fn pending_link_device_path() -> Result<std::path::PathBuf, String> {
    Ok(crate::identity::data_dir()?.join("pending_link.device"))
}

/// (Receiver) Stash an encrypted `.hollow` link blob, its one-time passphrase and the
/// device key this install will run as, to be imported on the NEXT launch before the
/// node starts, the same window a manual "Restore from backup" uses.
pub(crate) fn stash_pending_link(blob: &[u8], passphrase: &str, device: &[u8]) -> Result<(), String> {
    // A new link gets all its tries, whatever an earlier one spent.
    let tries = pending_link_tries_path()?;
    if present(&tries) {
        std::fs::remove_file(&tries).map_err(|e| format!("Failed to reset the link's tries: {e}"))?;
    }
    std::fs::write(pending_link_blob_path()?, blob)
        .map_err(|e| format!("Failed to stash link blob: {e}"))?;
    std::fs::write(pending_link_code_path()?, passphrase.as_bytes())
        .map_err(|e| format!("Failed to stash link key: {e}"))?;
    std::fs::write(pending_link_device_path()?, device)
        .map_err(|e| format!("Failed to stash the new device key: {e}"))?;
    Ok(())
}

/// True if a pending link blob is waiting to be imported on launch.
///
/// Dart asks this first at every launch, before anything reads the identity, so it
/// also finishes or undoes a landing a crash cut short.
#[frb]
pub fn has_pending_link() -> Result<bool, String> {
    if let Err(e) = recover_interrupted_landing(&crate::identity::data_dir()?) {
        hollow_log!("[HOLLOW-LINK] A landing that did not finish is still in the way: {e}");
    }
    Ok(pending_link_blob_path()?.exists() && pending_link_code_path()?.exists())
}

fn pending_link_tries_path() -> Result<std::path::PathBuf, String> {
    Ok(crate::identity::data_dir()?.join("pending_link.tries"))
}

/// How many launches try a link whose files would not move before it is dropped.
const LINK_LANDING_TRIES: u32 = 3;

/// Why a stashed link did not land.
enum LinkImportFailure {
    /// The stash itself is unusable; trying again changes nothing.
    Refused(String),
    /// The old identity could not move out of the way; the next launch tries again.
    NotLanded(String),
}

/// The code goes first: without it the stash no longer counts as pending.
fn drop_pending_link() {
    for path in [
        pending_link_code_path(),
        pending_link_blob_path(),
        pending_link_device_path(),
        pending_link_tries_path(),
    ]
    .into_iter()
    .flatten()
    {
        if present(&path) && std::fs::remove_file(&path).is_err() {
            hollow_log!("[HOLLOW-LINK] Could not clear part of the link stash");
        }
    }
}

/// Counts one more launch that could not land the stash; true once it has had them all.
fn spend_link_try() -> bool {
    let Ok(path) = pending_link_tries_path() else { return true };
    let spent = std::fs::read_to_string(&path)
        .ok()
        .and_then(|t| t.trim().parse::<u32>().ok())
        .unwrap_or(0)
        .saturating_add(1);
    std::fs::write(&path, spent.to_string()).is_err() || spent >= LINK_LANDING_TRIES
}

fn land_stashed_link(blob: &[u8], code: &str, device: &[u8]) -> Result<(), LinkImportFailure> {
    use LinkImportFailure::{NotLanded, Refused};
    // The presenter vouched for exactly this key, so nothing else may run here.
    crate::identity::native_identity::NativeKeypair::from_protobuf_encoding(device)
        .map_err(|_| Refused("The link didn't finish on this device. Link it again.".to_string()))?;
    // Opened and checked BEFORE anything moves: a snapshot that does not decrypt, or
    // that the check refuses, must cost the throwaway identity nothing.
    let zip_bytes = decrypt_backup_bytes(blob, code.trim()).map_err(Refused)?;
    let snapshot = check_snapshot(&zip_bytes).map_err(Refused)?;
    land_snapshot(snapshot, Some(device)).map_err(NotLanded)
}

/// (Receiver, at launch BEFORE start_node) Import a stashed link blob through the same
/// pipeline as a manual `.hollow` restore, then clean up the stash. After this the
/// bootstrap proceeds as a normal restored launch. A link that could not land leaves
/// the throwaway identity whole and its stash for the next launch.
#[frb]
pub fn import_pending_link() -> Result<(), String> {
    // Its lines reach the debug log, which otherwise opens only when the node starts.
    crate::log::init();
    let blob = std::fs::read(pending_link_blob_path()?)
        .map_err(|e| format!("Failed to read pending link blob: {e}"))?;
    let code = zeroize::Zeroizing::new(
        std::fs::read_to_string(pending_link_code_path()?)
            .map_err(|e| format!("Failed to read pending link key: {e}"))?,
    );
    let device = zeroize::Zeroizing::new(std::fs::read(pending_link_device_path()?).unwrap_or_default());

    match land_stashed_link(&blob, &code, &device) {
        Ok(()) => {
            drop_pending_link();
            hollow_log!("[HOLLOW-LINK] Pending link imported via backup pipeline ({} bytes)", blob.len());
            Ok(())
        }
        Err(LinkImportFailure::Refused(e)) => {
            drop_pending_link();
            hollow_log!("[HOLLOW-LINK] Pending link import FAILED, link dropped: {e}");
            Err(e)
        }
        Err(LinkImportFailure::NotLanded(e)) => {
            if spend_link_try() {
                drop_pending_link();
                hollow_log!("[HOLLOW-LINK] Pending link import FAILED for the last time, link dropped: {e}");
            } else {
                hollow_log!("[HOLLOW-LINK] Pending link import FAILED, the next launch tries again: {e}");
            }
            Err(e)
        }
    }
}

// ── Pending data-dir wipe: next-boot clean slate ─────────────────────────────
//
// Used by the "Link a device" cancel flow, which created a THROWAWAY identity to
// connect. The DB files cannot be deleted in-process: the running node holds open
// SQLCipher handles and Windows refuses to remove an open file, which would leave
// messages.db encrypted with the throwaway passphrase and unopenable. So the wipe is
// marked, the app relaunches, and the dir is nuked BEFORE the node starts.

const PENDING_WIPE_MARKER: &str = "pending_wipe.marker";

fn pending_wipe_marker_path() -> Result<std::path::PathBuf, String> {
    Ok(crate::identity::data_dir()?.join(PENDING_WIPE_MARKER))
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

/// (At launch, BEFORE start_node) Delete every file and directory in the data dir so
/// the next Welcome starts from a clean slate, keeping only the wipe marker (removed
/// last), any single-instance lock and the profile registry, and what Hollow wrote
/// beside the dir. The same sweep as the wipe itself. Idempotent.
///
/// True when it finished a destroy, which ends the profile (Dart's profile list then
/// forgets it); false for a cancelled link's throwaway, or while the wipe is unfinished.
#[frb]
pub fn perform_pending_wipe() -> Result<bool, String> {
    let marker = pending_wipe_marker_path()?;
    let data_dir = crate::identity::data_dir()?;
    std::fs::read_dir(&data_dir).map_err(|e| format!("Failed to read data dir for wipe: {e}"))?;
    let destroyed = std::fs::read(&marker).is_ok_and(|m| m == crate::api::wipe::DESTROY_MARK);
    crate::api::wipe::sweep_root(&data_dir);
    crate::api::wipe::clear_beside(&data_dir);
    // The marker stays while any of the identity's own files survived, a landing's
    // leftovers included: without it the next identity is minted beside a database it
    // can never open, or an old one is put back. The next launch wipes again. Anything
    // else the sweep left (a recording still held) never blocks.
    if !identity_set_gone(&data_dir, std::time::Instant::now() + HELD_FILE_WAIT) {
        return Ok(false);
    }
    // Last: a crash before this line re-runs the wipe next launch.
    let _ = std::fs::remove_file(&marker);
    Ok(destroyed)
}

/// Removes what is left of the identity set and of any landing, waiting for a held
/// file until `deadline`.
fn identity_set_gone(root: &std::path::Path, deadline: std::time::Instant) -> bool {
    loop {
        let mut gone = true;
        for name in IDENTITY_SET.into_iter().chain([LANDED]) {
            let p = root.join(name);
            if present(&p) && std::fs::remove_file(&p).is_err() {
                gone = false;
            }
        }
        for dir in [LANDING_STAGE, LANDING_ASIDE] {
            let p = root.join(dir);
            if present(&p) && std::fs::remove_dir_all(&p).is_err() {
                gone = false;
            }
        }
        if gone || std::time::Instant::now() >= deadline {
            return gone;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// C-FILES-04: a stored file's thumb reaches Dart re-encoded, or not at all.
    #[test]
    fn a_stored_file_thumb_reaches_dart_only_reencoded() {
        use base64::Engine as _;
        let b64 = |b: &[u8]| base64::engine::general_purpose::STANDARD.encode(b);
        let stored = |thumb: String| crate::storage::messages::StoredFile {
            file_id: "f".into(),
            file_name: "a.mp4".into(),
            file_ext: "mp4".into(),
            mime_type: "video/mp4".into(),
            size_bytes: 1,
            chunk_count: 1,
            chunks_received: 0,
            is_image: false,
            width: None,
            height: None,
            message_id: None,
            context_type: "dm".into(),
            context_id: "p".into(),
            sender_id: "p".into(),
            is_mine: false,
            created_at: 0,
            completed_at: None,
            disk_path: None,
            hidden_at: None,
            expired_at: None,
            video_thumb: None,
            share_ref: None,
            thumb_b64: Some(thumb),
            sha256: None,
        };
        let img = image::RgbaImage::from_fn(96, 54, |x, y| image::Rgba([x as u8, y as u8, 9, 255]));
        let mut png = Vec::new();
        image::DynamicImage::ImageRgba8(img)
            .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
            .unwrap();
        let poster = crate::node::image_convert::convert_to_webp_preview(&png, 400).unwrap().0;

        let theirs = b64(&poster);
        let ours = stored_file_to_ffi(stored(theirs.clone())).thumb_b64;
        assert!(ours.is_some_and(|t| t != theirs), "the stored bytes were handed on as they came");
        assert!(stored_file_to_ffi(stored(b64(&poster[..40]))).thumb_b64.is_none());
    }

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

    /// Art bought from the artist shop is PINNED against the asset evictor: everything
    /// else on the rail has a peer behind it, while a `.hollowpack` import has a receipt
    /// and nobody to re-pull it from.
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

    /// HOL-SEC-076: a backup or link snapshot carries none of this device's Olm or MLS
    /// identity and no stored phrase, and an import clears an older snapshot's, so
    /// every restored device mints its own.
    #[test]
    fn snapshots_leave_device_secrets_behind_both_ways() {
        use std::io::{Read, Write};
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", tmp.path()) };
        crate::identity::encryption::clear_session_key();
        let master = crate::identity::native_identity::NativeKeypair::from_secret_bytes(&[0x61; 32]);
        let key_bytes = master.to_protobuf_encoding().unwrap();
        std::fs::write(tmp.path().join("identity.key"), &key_bytes).unwrap();
        let pass = derive_db_key().unwrap();
        let db = tmp.path().join("messages.db");
        let open = |path: &std::path::Path| crate::storage::MessageStore::open(path.to_str().unwrap(), &pass).unwrap();
        crate::storage::MessageStore::migrate_auto_vacuum_once(db.to_str().unwrap(), &pass).unwrap();
        {
            let store = open(&db);
            store.save_olm_account("{\"account\":1}").unwrap();
            store.save_olm_session("peer", "{\"session\":1}", 1, 0).unwrap();
            store.save_mls_identity(b"signer", b"credential", b"storage").unwrap();
            store.save_setting("recovery_mnemonic", "abandon abandon about").unwrap();
            store.save_setting("kept", "yes").unwrap();
            store.wal_checkpoint().unwrap();
        }
        let secrets = |path: &std::path::Path| {
            let store = open(path);
            let mut left = Vec::new();
            if store.load_olm_account().unwrap().is_some() {
                left.push("olm account");
            }
            if !store.load_all_olm_sessions().unwrap().is_empty() {
                left.push("olm sessions");
            }
            if store.load_mls_identity().unwrap().is_some() {
                left.push("mls identity");
            }
            if store.load_setting("recovery_mnemonic").unwrap().is_some() {
                left.push("recovery phrase");
            }
            assert_eq!(store.load_setting("kept").unwrap().as_deref(), Some("yes"), "everything else travels");
            left
        };
        let raw_db = std::fs::read(&db).unwrap();

        let zip = build_snapshot_bytes(false, false).unwrap();
        let mut archive = zip::ZipArchive::new(std::io::Cursor::new(zip)).unwrap();
        let mut exported = Vec::new();
        archive.by_name("messages.db").unwrap().read_to_end(&mut exported).unwrap();
        let out = crate::test_tmp::tempdir().unwrap();
        let exported_path = out.path().join("exported.db");
        std::fs::write(&exported_path, exported).unwrap();
        assert_eq!(secrets(&exported_path), Vec::<&str>::new(), "the export carries device secrets");
        assert_eq!(secrets(&db).len(), 4, "the live database keeps its own");

        // A transfer's temp file never travels, and what does an import takes back whole.
        std::fs::create_dir_all(tmp.path().join("files")).unwrap();
        std::fs::write(tmp.path().join("files").join("ab12.png"), b"HFE1").unwrap();
        std::fs::write(tmp.path().join("files").join(".stream_send_ab12.tmp"), b"half").unwrap();
        let with_files = build_snapshot_bytes(false, true).unwrap();
        let names: Vec<String> = zip::ZipArchive::new(std::io::Cursor::new(&with_files[..]))
            .unwrap()
            .file_names()
            .map(str::to_string)
            .collect();
        assert!(names.contains(&"files/ab12.png".to_string()), "{names:?}");
        assert!(!names.iter().any(|n| n.ends_with(".tmp")), "a temp file travels: {names:?}");
        assert!(check_snapshot(&with_files).is_ok(), "an import refuses what an export writes");

        // An older snapshot, made before exports were scrubbed.
        let mut old = std::io::Cursor::new(Vec::new());
        {
            let mut z = zip::ZipWriter::new(&mut old);
            let options = zip::write::SimpleFileOptions::default();
            z.start_file("identity.key", options).unwrap();
            z.write_all(&key_bytes).unwrap();
            z.start_file("messages.db", options).unwrap();
            z.write_all(&raw_db).unwrap();
            z.finish().unwrap();
        }
        import_snapshot_bytes(&old.into_inner()).unwrap();
        assert_eq!(secrets(&db), Vec::<&str>::new(), "the import keeps the source device's secrets");
    }

    /// A data folder of its own under a fresh temp dir, set as `HOLLOW_DATA_DIR`. The
    /// caller holds the resolver and store test locks.
    fn snapshot_target() -> (crate::test_tmp::TestDir, std::path::PathBuf) {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let data = tmp.path().join("data");
        std::fs::create_dir_all(&data).unwrap();
        // SAFETY: serialized by the caller's locks.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", &data) };
        crate::identity::encryption::clear_session_key();
        (tmp, data)
    }

    pub(super) fn zip_of(entries: &[(&str, &[u8])]) -> Vec<u8> {
        use std::io::Write;
        let mut out = std::io::Cursor::new(Vec::new());
        let mut z = zip::ZipWriter::new(&mut out);
        for (name, bytes) in entries {
            z.start_file(*name, zip::write::SimpleFileOptions::default()).unwrap();
            z.write_all(bytes).unwrap();
        }
        z.finish().unwrap();
        out.into_inner()
    }

    /// C-IDENTITY-01. A snapshot (a link presenter's or a backup file someone handed
    /// over) lands only what `build_snapshot_bytes` writes. A name out of the data
    /// folder, absolute or relative, or a file Hollow keeps beside the identity refuses
    /// it whole, before anything lands.
    #[test]
    fn a_snapshot_lands_only_what_a_snapshot_holds() {
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let (tmp, data) = snapshot_target();
        let key = crate::identity::native_identity::NativeKeypair::from_secret_bytes(&[0x65; 32])
            .to_protobuf_encoding()
            .unwrap();
        let absolute = tmp.path().join("absolute.txt");
        let absolute_name = absolute.to_str().unwrap().to_string();
        for hostile in [
            "../escaped.txt",
            absolute_name.as_str(),
            "files/../../escaped.txt",
            "files/../escaped.txt",
            "identity.duress",
            "identity.device",
            "pending_wipe.marker",
            "roster_bootstrap.json",
            "pending_link.hollow",
            "profiles.json",
            "files/nested/x.bin",
            "files/x.bin:stream",
            "files/CON",
            "audio_cache/x.bin",
        ] {
            let zip = zip_of(&[("identity.key", &key), (hostile, b"planted")]);
            assert!(import_snapshot_bytes(&zip).is_err(), "{hostile} was accepted");
            assert!(!tmp.path().join("escaped.txt").exists(), "{hostile} wrote out of the data folder");
            assert!(!absolute.exists(), "{hostile} wrote to an absolute path");
            let landed: Vec<_> = std::fs::read_dir(&data).unwrap().flatten().map(|e| e.file_name()).collect();
            assert!(landed.is_empty(), "{hostile}: a refused snapshot left {landed:?}");
        }

        let mut link = std::io::Cursor::new(Vec::new());
        {
            use std::io::Write;
            let mut z = zip::ZipWriter::new(&mut link);
            z.start_file("identity.key", zip::write::SimpleFileOptions::default()).unwrap();
            z.write_all(&key).unwrap();
            z.add_symlink("files/link.png", absolute_name.as_str(), zip::write::SimpleFileOptions::default()).unwrap();
            z.finish().unwrap();
        }
        assert!(import_snapshot_bytes(&link.into_inner()).is_err(), "a link entry was accepted");

        let zip = zip_of(&[
            ("identity.key", &key),
            ("files/ab12.png", b"HFE1"),
            ("files/.ws_recv_ab12.0.tmp", b"half a transfer"),
            ("vault/cd34", b"shard"),
        ]);
        import_snapshot_bytes(&zip).unwrap();
        assert_eq!(std::fs::read(data.join("files").join("ab12.png")).unwrap(), b"HFE1");
        assert_eq!(std::fs::read(data.join("vault").join("cd34")).unwrap(), b"shard");
        assert!(!data.join("files").join(".ws_recv_ab12.0.tmp").exists(), "a transfer's temp file landed");
    }

    /// C-IDENTITY-01. A snapshot unpacks to no more than a real one could from its
    /// size, whatever its entries declare, so a small file never fills the disk.
    #[test]
    fn a_snapshot_that_unpacks_past_its_size_is_refused() {
        use std::io::Write;
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let (_tmp, data) = snapshot_target();
        let key = crate::identity::native_identity::NativeKeypair::from_secret_bytes(&[0x66; 32])
            .to_protobuf_encoding()
            .unwrap();
        let zeros = {
            let mut one = std::io::Cursor::new(Vec::new());
            let mut z = zip::ZipWriter::new(&mut one);
            z.start_file("z", zip::write::SimpleFileOptions::default()).unwrap();
            z.write_all(&vec![0u8; 4 << 20]).unwrap();
            z.finish().unwrap();
            one.into_inner()
        };
        let mut src = zip::ZipArchive::new(std::io::Cursor::new(zeros)).unwrap();
        let mut bomb = std::io::Cursor::new(Vec::new());
        {
            let mut z = zip::ZipWriter::new(&mut bomb);
            z.start_file("identity.key", zip::write::SimpleFileOptions::default()).unwrap();
            z.write_all(&key).unwrap();
            for i in 0..40 {
                z.raw_copy_file_rename(src.by_index(0).unwrap(), format!("files/z{i}.bin")).unwrap();
            }
            z.finish().unwrap();
        }
        let bomb = bomb.into_inner();
        assert!(bomb.len() < 1 << 20, "the test bomb is {} bytes", bomb.len());
        assert!(import_snapshot_bytes(&bomb).is_err(), "160 MiB unpacked from a small snapshot");
        assert!(!data.join("files").exists() && !data.join("identity.key").exists(), "a refused snapshot wrote files");

        // Empty entries cost nothing to store but a file each to land.
        let names: Vec<String> = (0..20_000).map(|i| format!("files/e{i}")).collect();
        let mut entries: Vec<(&str, &[u8])> = vec![("identity.key", &key)];
        entries.extend(names.iter().map(|n| (n.as_str(), &b""[..])));
        assert!(import_snapshot_bytes(&zip_of(&entries)).is_err(), "twenty thousand empty files landed");
        assert!(!data.join("files").exists());
    }

    /// HOL-SEC-002: a link's stash installs the device key the presenter vouched for,
    /// so the linked device runs as exactly that device, never as a fresh one.
    #[test]
    fn a_pending_link_installs_the_device_key_it_was_made_for() {
        use crate::identity::native_identity::NativeKeypair;
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", tmp.path()) };
        crate::identity::encryption::clear_session_key();
        let master = NativeKeypair::from_secret_bytes(&[0x62; 32]);
        std::fs::write(tmp.path().join("identity.key"), master.to_protobuf_encoding().unwrap()).unwrap();
        let pass = derive_db_key().unwrap();
        let db = tmp.path().join("messages.db");
        crate::storage::MessageStore::migrate_auto_vacuum_once(db.to_str().unwrap(), &pass).unwrap();
        crate::storage::MessageStore::open(db.to_str().unwrap(), &pass).unwrap().save_setting("kept", "yes").unwrap();
        let key = "ab".repeat(32);
        let blob = export_backup_bytes(&key, false, false).unwrap();

        // The throwaway identity the link ran on, and the key minted for the link.
        let throwaway = NativeKeypair::from_secret_bytes(&[0x64; 32]);
        std::fs::write(tmp.path().join("identity.device"), throwaway.to_protobuf_encoding().unwrap()).unwrap();
        let linked = NativeKeypair::from_secret_bytes(&[0x63; 32]);
        stash_pending_link(&blob, &key, &linked.to_protobuf_encoding().unwrap()).unwrap();

        import_pending_link().unwrap();
        let installed = NativeKeypair::from_protobuf_encoding(&std::fs::read(tmp.path().join("identity.device")).unwrap())
            .expect("a device key is installed");
        assert_eq!(installed.peer_id(), linked.peer_id());
        for stash in ["pending_link.hollow", "pending_link.code", "pending_link.device"] {
            assert!(!tmp.path().join(stash).exists(), "{stash} outlived the import");
        }
    }

    /// C-IDENTITY-15. A link and a restore each land the identity unprotected, so each
    /// leaves the lock offer due in the database it lands, whatever the source's copy said.
    /// C-IDENTITY-09: what the source was told about our own devices came before the new
    /// device joined, so it lands already seen.
    #[test]
    fn a_link_or_a_restore_leaves_a_lock_offer_due() {
        use crate::identity::native_identity::NativeKeypair;
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let out_dir = crate::test_tmp::tempdir().unwrap();
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", tmp.path()) };
        crate::identity::encryption::clear_session_key();
        let master = NativeKeypair::from_secret_bytes(&[0x66; 32]);
        std::fs::write(tmp.path().join("identity.key"), master.to_protobuf_encoding().unwrap()).unwrap();
        let pass = derive_db_key().unwrap();
        let db = tmp.path().join("messages.db");
        crate::storage::MessageStore::migrate_auto_vacuum_once(db.to_str().unwrap(), &pass).unwrap();
        let due = || {
            crate::storage::MessageStore::open(db.to_str().unwrap(), &derive_db_key().unwrap())
                .unwrap()
                .load_setting(PROTECTION_OFFER_DUE)
                .unwrap()
        };
        let shown = || {
            crate::storage::MessageStore::open(db.to_str().unwrap(), &derive_db_key().unwrap())
                .unwrap()
                .save_setting(PROTECTION_OFFER_DUE, "")
                .unwrap()
        };
        shown();
        let own_news = || {
            crate::storage::MessageStore::open(db.to_str().unwrap(), &derive_db_key().unwrap())
                .unwrap()
                .get_security_alerts()
                .unwrap()
                .into_iter()
                .filter(|a| a.kind == crate::node::security_alerts::KIND_OWN_DEVICE_ADDED)
                .collect::<Vec<_>>()
        };
        {
            let store = crate::storage::MessageStore::open(db.to_str().unwrap(), &pass).unwrap();
            crate::node::security_alerts::record_own_device_added(&store, &master.peer_id(), "devC", "devA").unwrap();
        }
        let key = "cd".repeat(32);
        let blob = export_backup_bytes(&key, false, false).unwrap();
        let linked = NativeKeypair::from_secret_bytes(&[0x67; 32]);
        stash_pending_link(&blob, &key, &linked.to_protobuf_encoding().unwrap()).unwrap();
        import_pending_link().unwrap();
        assert_eq!(due().as_deref(), Some("1"), "a link left no lock offer");
        let news = own_news();
        assert!(!news.is_empty() && news.iter().all(|a| a.acknowledged_at.is_some()), "the source's own-device news came along unread: {news:?}");

        shown();
        let out = out_dir.path().join("restore.hollow").to_string_lossy().to_string();
        export_backup(out.clone(), false, false, "a long enough passphrase".into()).unwrap();
        import_backup(out, "a long enough passphrase".into()).unwrap();
        assert_eq!(due().as_deref(), Some("1"), "a restore left no lock offer");
    }
}

#[cfg(test)]
mod backup_passphrase_tests {
    use super::*;

    /// A `.hollow` file carries the master key and the whole history, so a new
    /// export refuses a short passphrase, while a file made under one still opens.
    #[test]
    fn a_backup_needs_a_long_passphrase_and_an_old_short_one_still_opens() {
        use crate::identity::native_identity::NativeKeypair;
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let out_dir = crate::test_tmp::tempdir().unwrap();
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", tmp.path()) };
        crate::identity::encryption::clear_session_key();
        let master = NativeKeypair::from_secret_bytes(&[0x72; 32]);
        std::fs::write(tmp.path().join("identity.key"), master.to_protobuf_encoding().unwrap()).unwrap();
        let pass = derive_db_key().unwrap();
        let db = tmp.path().join("messages.db");
        crate::storage::MessageStore::migrate_auto_vacuum_once(db.to_str().unwrap(), &pass).unwrap();
        crate::storage::MessageStore::open(db.to_str().unwrap(), &pass).unwrap().save_setting("kept", "yes").unwrap();

        let out = out_dir.path().join("backup.hollow");
        let out_str = out.to_string_lossy().to_string();
        for short in ["hunter2", "eleven char", "   padded   "] {
            let err = export_backup(out_str.clone(), false, false, short.into())
                .expect_err("a short passphrase is refused");
            assert!(err.contains("12 characters"), "unexpected message: {err}");
            assert!(!out.exists(), "a refused export writes nothing");
        }
        export_backup(out_str, false, false, "correct horse battery".into())
            .expect("a long passphrase exports");
        assert!(out.exists());

        let old = export_backup_bytes("hunter2", false, false).unwrap();
        assert!(decrypt_backup_bytes(&old, "hunter2").is_ok(), "an old short-passphrase file opens");
    }
}

#[cfg(test)]
mod landing_tests {
    use super::*;
    use super::tests::zip_of;
    use crate::identity::native_identity::NativeKeypair;
    use crate::storage::MessageStore;

    /// Points the data root at `root` with the identity `seed` and a database of its
    /// own holding `who`, and returns that database's key.
    fn identity_in(root: &std::path::Path, seed: u8, who: &str) -> String {
        std::fs::create_dir_all(root).unwrap();
        // SAFETY: serialized by the callers' locks.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", root) };
        crate::identity::encryption::clear_session_key();
        let master = NativeKeypair::from_secret_bytes(&[seed; 32]);
        std::fs::write(root.join("identity.key"), master.to_protobuf_encoding().unwrap()).unwrap();
        let pass = derive_db_key().unwrap();
        let db = root.join("messages.db");
        MessageStore::migrate_auto_vacuum_once(db.to_str().unwrap(), &pass).unwrap();
        MessageStore::open(db.to_str().unwrap(), &pass).unwrap().save_setting("who", who).unwrap();
        pass
    }

    /// Who the database in the root says it belongs to, opened with the key the
    /// identity in the root derives; an error when the two do not belong together.
    fn pair_in_root() -> Result<String, String> {
        let db = crate::identity::data_dir()?.join("messages.db");
        let store = MessageStore::open(db.to_str().unwrap(), &derive_db_key()?)?;
        Ok(store.load_setting("who")?.unwrap_or_default())
    }

    /// A link blob of the identity `seed`, made in a folder of its own, and the root
    /// pointed back at `root`.
    fn link_blob(tmp: &std::path::Path, seed: u8, code: &str) -> Vec<u8> {
        identity_in(&tmp.join("source"), seed, "linked");
        export_backup_bytes(code, false, false).unwrap()
    }

    /// The incident behind this test: a desktop linked to a phone and then could not
    /// open its identity ("file is not a database"). Whatever holds the old database
    /// while the import runs, the identity in the root and the database beside it
    /// must still belong together, and a link that could not land is tried again.
    #[test]
    fn a_link_never_lands_beside_a_database_something_holds() {
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let code = "ef".repeat(32);
        let blob = link_blob(tmp.path(), 0x71, &code);
        let root = tmp.path().join("data");
        let throwaway = identity_in(&root, 0x72, "throwaway");

        // Holds the database the way a second SQLite connection does, with a write
        // still in its WAL.
        let holder = MessageStore::open(root.join("messages.db").to_str().unwrap(), &throwaway).unwrap();
        holder.save_setting("late", "write").unwrap();

        let device = NativeKeypair::from_secret_bytes(&[0x73; 32]).to_protobuf_encoding().unwrap();
        stash_pending_link(&blob, &code, &device).unwrap();
        let first = import_pending_link();
        assert!(pair_in_root().is_ok(), "while held: {:?} after {first:?}", pair_in_root());
        drop(holder);
        assert!(pair_in_root().is_ok(), "once let go: {:?} after {first:?}", pair_in_root());

        if first.is_err() {
            assert_eq!(pair_in_root().as_deref(), Ok("throwaway"), "a refused landing kept nothing old");
            assert!(has_pending_link().unwrap(), "a link that could not land was dropped");
            import_pending_link().expect("the retry lands");
        }
        assert_eq!(pair_in_root().as_deref(), Ok("linked"));
        assert!(!has_pending_link().unwrap());
        for left in [LANDING_STAGE, LANDING_ASIDE, LANDED] {
            assert!(!root.join(left).exists(), "{left} outlived the landing");
        }
    }

    /// The incident's exact error: a program that opens the old database without
    /// sharing writes (a scanner, a backup tool) used to leave the new identity beside
    /// the old database, "file is not a database" at the next open.
    #[cfg(windows)]
    #[test]
    fn a_link_never_lands_beside_a_database_another_program_holds() {
        use std::os::windows::fs::OpenOptionsExt;
        const FILE_SHARE_READ: u32 = 1;
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let code = "cd".repeat(32);
        let blob = link_blob(tmp.path(), 0x78, &code);
        let root = tmp.path().join("data");
        identity_in(&root, 0x79, "throwaway");
        let scanner = std::fs::OpenOptions::new()
            .read(true)
            .share_mode(FILE_SHARE_READ)
            .open(root.join("messages.db"))
            .unwrap();

        let device = NativeKeypair::from_secret_bytes(&[0x7a; 32]).to_protobuf_encoding().unwrap();
        stash_pending_link(&blob, &code, &device).unwrap();
        let first = import_pending_link();
        assert!(pair_in_root().is_ok(), "while held: {:?} after {first:?}", pair_in_root());
        assert!(first.is_err() && has_pending_link().unwrap(), "{first:?}");
        drop(scanner);
        import_pending_link().expect("the retry lands");
        assert_eq!(pair_in_root().as_deref(), Ok("linked"));
    }

    /// A scanner that holds the database a moment is waited out, by the landing and by
    /// the boot wipe alike.
    #[cfg(windows)]
    #[test]
    fn a_file_held_a_moment_is_waited_out() {
        use std::os::windows::fs::OpenOptionsExt;
        const FILE_SHARE_READ: u32 = 1;
        let hold_briefly = |db: std::path::PathBuf| {
            let scanner = std::fs::OpenOptions::new().read(true).share_mode(FILE_SHARE_READ).open(db).unwrap();
            std::thread::spawn(move || {
                std::thread::sleep(std::time::Duration::from_millis(100));
                drop(scanner);
            })
        };
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let code = "5e".repeat(32);
        let blob = link_blob(tmp.path(), 0x85, &code);
        let root = tmp.path().join("data");
        identity_in(&root, 0x86, "throwaway");
        let _ = blob;
        // No Argon2 in front of the landing, so the hold is still on when it moves the set.
        let source = tmp.path().join("source");
        let zip = zip_of(&[
            ("identity.key", &std::fs::read(source.join("identity.key")).unwrap()),
            ("messages.db", &std::fs::read(source.join("messages.db")).unwrap()),
        ]);
        let released = hold_briefly(root.join("messages.db"));
        import_snapshot_bytes(&zip).expect("the landing waited for the scanner");
        released.join().unwrap();
        assert_eq!(pair_in_root().as_deref(), Ok("linked"));

        stash_pending_wipe().unwrap();
        let released = hold_briefly(root.join("messages.db"));
        perform_pending_wipe().unwrap();
        released.join().unwrap();
        assert!(!has_pending_wipe().unwrap(), "the wipe gave up on a file held a moment");
    }

    /// A wipe that could not take the database must not let the next identity be
    /// minted beside it: the marker stays until the database is gone.
    #[test]
    fn a_boot_wipe_keeps_its_marker_while_the_database_survives() {
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        let pass = identity_in(&root, 0x74, "cancelled link");
        let holder = MessageStore::open(root.join("messages.db").to_str().unwrap(), &pass).unwrap();
        holder.save_setting("late", "write").unwrap();
        stash_pending_wipe().unwrap();

        perform_pending_wipe().unwrap();
        let survived = ["messages.db", "messages.db-wal", "messages.db-shm"]
            .into_iter()
            .filter(|n| root.join(n).exists())
            .collect::<Vec<_>>();
        if !survived.is_empty() {
            assert!(has_pending_wipe().unwrap(), "{survived:?} outlived the wipe and its marker went");
            assert!(
                crate::identity::load_or_create_identity().is_err(),
                "an identity was minted beside {survived:?}",
            );
        }
        drop(holder);
        perform_pending_wipe().unwrap();
        assert!(!has_pending_wipe().unwrap());
        for name in ["identity.key", "messages.db", "messages.db-wal", "messages.db-shm"] {
            assert!(!root.join(name).exists(), "{name} outlived the second wipe");
        }
    }

    /// A field failure of the import must leave a trace: its lines reach the debug
    /// log, which used to open only when the node started, after the import.
    #[test]
    fn a_link_import_writes_its_outcome_to_the_debug_log() {
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let code = "ab".repeat(32);
        let blob = link_blob(tmp.path(), 0x75, &code);
        let throwaway = identity_in(&tmp.path().join("data"), 0x76, "throwaway");
        // This process's own store on the old database never stands in the way.
        let db = tmp.path().join("data").join("messages.db");
        set_test_store(MessageStore::open(db.to_str().unwrap(), &throwaway).unwrap());
        crate::log::erase();
        let device = NativeKeypair::from_secret_bytes(&[0x77; 32]).to_protobuf_encoding().unwrap();
        stash_pending_link(&blob, &code, &device).unwrap();
        import_pending_link().unwrap();
        let log = crate::log::open_path().expect("the import ran with no log open");
        let text = std::fs::read_to_string(&log).unwrap_or_default();
        crate::log::erase();
        assert!(text.contains("[HOLLOW-LINK] Pending link imported"), "the outcome is not in the log: {text}");
    }

    /// A refused stash says why in the log too, and a restore onto a root with no
    /// identity yet logs once its identity has landed.
    #[test]
    fn a_refused_link_and_a_first_restore_write_to_the_debug_log() {
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let blob = link_blob(tmp.path(), 0x82, "a long enough passphrase");
        identity_in(&tmp.path().join("data"), 0x83, "throwaway");
        crate::log::erase();
        let device = NativeKeypair::from_secret_bytes(&[0x84; 32]).to_protobuf_encoding().unwrap();
        stash_pending_link(b"HOLLOW-but-not-decryptable-at-all-000000000000000000", "", &device).unwrap();
        assert!(import_pending_link().is_err());
        let log = crate::log::open_path().expect("a refused link left no log");
        let text = std::fs::read_to_string(&log).unwrap_or_default();
        crate::log::erase();
        assert!(text.contains("Pending link import FAILED"), "the refusal is not in the log");

        let empty = tmp.path().join("empty");
        std::fs::create_dir_all(&empty).unwrap();
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", &empty) };
        import_backup_bytes(&blob, "a long enough passphrase").unwrap();
        let log = crate::log::open_path().expect("a first restore left no log");
        let text = std::fs::read_to_string(&log).unwrap_or_default();
        crate::log::erase();
        assert!(text.contains("[HOLLOW-LINK] Import wrote"), "the restore is not in the log");
    }

    /// A landing that fails after the old set moved puts the old pair back and keeps
    /// the stash for the next launch, a few launches at most.
    #[test]
    fn a_landing_that_fails_halfway_puts_the_old_pair_back() {
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let code = "9a".repeat(32);
        let blob = link_blob(tmp.path(), 0x7b, &code);
        let root = tmp.path().join("data");
        identity_in(&root, 0x7c, "throwaway");
        let device = NativeKeypair::from_secret_bytes(&[0x7d; 32]).to_protobuf_encoding().unwrap();
        stash_pending_link(&blob, &code, &device).unwrap();

        *FAIL_COMMIT_AT.lock().unwrap() = Some("messages.db");
        let mut kept = Vec::new();
        for _ in 0..LINK_LANDING_TRIES {
            // The old set has no device key, so one after the failure would be the new one.
            std::fs::remove_file(root.join("identity.device")).unwrap();
            assert!(import_pending_link().is_err());
            assert!(!root.join("identity.device").exists(), "the new device key stayed beside the old identity");
            assert_eq!(pair_in_root().as_deref(), Ok("throwaway"), "the old pair did not come back");
            kept.push(has_pending_link().unwrap());
        }
        *FAIL_COMMIT_AT.lock().unwrap() = None;
        assert!(COMMIT_SAW_LANDING.load(std::sync::atomic::Ordering::Acquire), "the commit ran with no landing flag up");
        assert!(!landing_in_progress(), "a failed landing left its flag up");
        assert_eq!(kept, [true, true, false], "the stash outlived or missed its tries");
        for left in [LANDING_STAGE, LANDING_ASIDE, LANDED] {
            assert!(!root.join(left).exists(), "{left} outlived the failed landing");
        }
    }

    /// A crash mid-landing leaves a journal: before the old set was all moved, or
    /// before the new one was all in place, the old pair comes back; once the new one
    /// was in place, only the leftovers go.
    #[test]
    fn a_landing_a_crash_cut_short_is_finished_at_the_next_launch() {
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let new_root = tmp.path().join("new");
        identity_in(&new_root, 0x7e, "new");
        let root = tmp.path().join("data");
        let aside = root.join(LANDING_ASIDE);
        let copy = |from: &std::path::Path, to: &std::path::Path, names: &[&str]| {
            std::fs::create_dir_all(to).unwrap();
            for name in names {
                std::fs::copy(from.join(name), to.join(name)).unwrap();
            }
        };

        // Cut short while the new pair was going in.
        identity_in(&root, 0x7f, "old");
        copy(&root, &aside, &["identity.key", "messages.db"]);
        std::fs::write(aside.join(ASIDE_MOVED), b"").unwrap();
        copy(&new_root, &root, &["identity.key", "messages.db"]);
        has_pending_link().unwrap();
        assert_eq!(pair_in_root().as_deref(), Ok("old"), "mid-commit");
        assert!(!aside.exists());

        // Cut short while the old pair was moving out.
        std::fs::create_dir_all(&aside).unwrap();
        std::fs::rename(root.join("messages.db"), aside.join("messages.db")).unwrap();
        has_pending_link().unwrap();
        assert_eq!(pair_in_root().as_deref(), Ok("old"), "mid-set-aside");
        assert!(!aside.exists());

        // Cut short after the new pair was in place.
        copy(&root, &aside, &["identity.key", "messages.db"]);
        std::fs::write(aside.join(ASIDE_MOVED), b"").unwrap();
        copy(&new_root, &root, &["identity.key", "messages.db"]);
        std::fs::write(root.join(LANDED), b"").unwrap();
        has_pending_link().unwrap();
        assert_eq!(pair_in_root().as_deref(), Ok("new"), "after the commit");
        assert!(!aside.exists() && !root.join(LANDED).exists());
    }

    /// A landing never starts over the leftovers of an earlier one: a stale "done" mark
    /// would let a crash mid-commit pass for a finished landing and lose the old pair.
    #[test]
    fn a_landing_clears_an_earlier_ones_leftovers_before_it_starts() {
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        identity_in(&tmp.path().join("source"), 0x88, "linked");
        let source = tmp.path().join("source");
        let zip = zip_of(&[
            ("identity.key", &std::fs::read(source.join("identity.key")).unwrap()),
            ("messages.db", &std::fs::read(source.join("messages.db")).unwrap()),
        ]);
        let root = tmp.path().join("data");
        identity_in(&root, 0x89, "throwaway");
        std::fs::write(root.join(LANDED), b"").unwrap();

        *CRASH_COMMIT_AT.lock().unwrap() = Some("messages.db");
        let crashed = std::panic::catch_unwind(|| import_snapshot_bytes(&zip));
        *CRASH_COMMIT_AT.lock().unwrap() = None;
        assert!(crashed.is_err(), "the simulated crash did not happen");
        assert!(!landing_in_progress());

        has_pending_link().unwrap();
        assert_eq!(pair_in_root().as_deref(), Ok("throwaway"), "the crash cost the old pair");
    }

    /// The incident left no trace: a database that will not open with the identity
    /// beside it now says so in the log, with which of the identity's files are there.
    #[test]
    fn a_database_that_will_not_open_says_so_in_the_log() {
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        identity_in(&root, 0x8a, "someone else's");
        let other = NativeKeypair::from_secret_bytes(&[0x8b; 32]);
        std::fs::write(root.join("identity.key"), other.to_protobuf_encoding().unwrap()).unwrap();
        crate::log::erase();
        let _ = get_store().lock().unwrap_or_else(|e| e.into_inner()).take();
        assert!(open_message_store().is_err());
        let log = crate::log::open_path().expect("the refusal left no log");
        let text = std::fs::read_to_string(&log).unwrap_or_default();
        crate::log::erase();
        assert!(text.contains("[HOLLOW-STORE] The database would not open"), "{text}");
        assert!(text.contains("messages.db=") && text.contains("identity.key="), "{text}");
    }

    /// Nothing mints an identity while a landing has the old one moved out.
    #[test]
    fn no_identity_is_minted_while_a_landing_runs() {
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", tmp.path()) };
        crate::identity::encryption::clear_session_key();
        {
            let _landing = LandingFlag::raise();
            assert!(crate::identity::load_or_create_identity().is_err());
            assert!(!tmp.path().join("identity.key").exists(), "a key was minted mid-landing");
        }
        assert!(crate::identity::load_or_create_identity().is_ok());
    }

    /// The restore from a backup file lands through the same swap as a link.
    #[cfg(windows)]
    #[test]
    fn a_restore_never_lands_beside_a_database_another_program_holds() {
        use std::os::windows::fs::OpenOptionsExt;
        const FILE_SHARE_READ: u32 = 1;
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let blob = link_blob(tmp.path(), 0x80, "a long enough passphrase");
        let root = tmp.path().join("data");
        identity_in(&root, 0x81, "before the restore");
        let scanner = std::fs::OpenOptions::new()
            .read(true)
            .share_mode(FILE_SHARE_READ)
            .open(root.join("messages.db"))
            .unwrap();
        assert!(import_backup_bytes(&blob, "a long enough passphrase").is_err());
        assert_eq!(pair_in_root().as_deref(), Ok("before the restore"));
        drop(scanner);
        import_backup_bytes(&blob, "a long enough passphrase").unwrap();
        assert_eq!(pair_in_root().as_deref(), Ok("linked"));
    }

    // t1-review

    /// Builds the state right after a finished commit: the new pair in the root, the
    /// old pair in `.replaced` with its moved mark, the cleanup not begun.
    fn review_committed_state(tmp: &std::path::Path) -> std::path::PathBuf {
        landed_then_died_at(tmp, "content")
    }

    /// A crash while the cleanup deletes `.replaced` (after its first entries went,
    /// before `moved` and the old database did) must not undo a finished landing.
    #[test]
    fn t1_review_a_crash_mid_cleanup_never_undoes_a_finished_landing() {
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = review_committed_state(tmp.path());
        let aside = root.join(LANDING_ASIDE);
        // What remove_dir_all leaves when cut short after its first entries.
        std::fs::remove_file(aside.join("identity.key")).unwrap();
        has_pending_link().unwrap();
        assert_eq!(pair_in_root().as_deref(), Ok("new"), "the next launch undid a finished landing");
    }

    /// The same state, made by the real cleanup: a file in `.replaced` that another
    /// program holds stops remove_dir_all after it took the `committed` mark.
    #[cfg(windows)]
    #[test]
    fn t1_review_a_held_replaced_file_never_undoes_a_finished_landing() {
        use std::os::windows::fs::OpenOptionsExt;
        const FILE_SHARE_READ: u32 = 1;
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = review_committed_state(tmp.path());
        let aside = root.join(LANDING_ASIDE);
        let scanner = std::fs::OpenOptions::new()
            .read(true)
            .share_mode(FILE_SHARE_READ)
            .open(aside.join("messages.db"))
            .unwrap();
        let _ = has_pending_link();
        let left: Vec<String> = std::fs::read_dir(&aside)
            .map(|rd| rd.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect())
            .unwrap_or_default();
        drop(scanner);
        has_pending_link().unwrap();
        assert_eq!(
            pair_in_root().as_deref(),
            Ok("new"),
            "the next launch undid a finished landing; the held cleanup left {left:?}",
        );
    }

    /// A new link's stash starts with all its tries, whatever an earlier one spent.
    #[test]
    fn t1_review_a_fresh_link_gets_all_its_tries() {
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let code = "9b".repeat(32);
        let blob = link_blob(tmp.path(), 0x93, &code);
        let root = tmp.path().join("data");
        identity_in(&root, 0x94, "throwaway");
        let device = NativeKeypair::from_secret_bytes(&[0x95; 32]).to_protobuf_encoding().unwrap();
        *FAIL_COMMIT_AT.lock().unwrap() = Some("messages.db");
        stash_pending_link(&blob, &code, &device).unwrap();
        for _ in 0..LINK_LANDING_TRIES - 1 {
            let _ = std::fs::remove_file(root.join("identity.device"));
            assert!(import_pending_link().is_err());
        }
        // The person links again: a new stash.
        stash_pending_link(&blob, &code, &device).unwrap();
        let _ = std::fs::remove_file(root.join("identity.device"));
        assert!(import_pending_link().is_err());
        let kept = has_pending_link().unwrap();
        *FAIL_COMMIT_AT.lock().unwrap() = None;
        assert!(kept, "a fresh link was dropped after its first failed launch");
    }

    /// After a destroy (or a duress code) whose database something still holds at the
    /// next launch, what the person sees on "Create" must not say a wipe ran.
    #[cfg(windows)]
    #[test]
    fn t1_review_a_held_boot_wipe_never_names_a_wipe() {
        use std::os::windows::fs::OpenOptionsExt;
        const FILE_SHARE_READ: u32 = 1;
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        identity_in(&root, 0x96, "destroyed");
        std::fs::write(root.join("pending_wipe.marker"), crate::api::wipe::DESTROY_MARK).unwrap();
        let scanner = std::fs::OpenOptions::new()
            .read(true)
            .share_mode(FILE_SHARE_READ)
            .open(root.join("messages.db"))
            .unwrap();
        let finished = perform_pending_wipe().unwrap();
        let shown = crate::identity::load_or_create_identity().err().unwrap_or_default();
        drop(scanner);
        assert!(!finished);
        assert!(!shown.to_lowercase().contains("wipe"), "the next launch shows: {shown}");
    }

    // t1-linkimport-2

    const CLEANUP_STEPS: [&str; 4] = ["content", "moved", "aside", "landed"];

    /// A landing of the identity "new", with a content file, over the identity "old"
    /// in `tmp/data`, cut short by a crash at the cleanup's `step`; returns the root.
    fn landed_then_died_at(tmp: &std::path::Path, step: &'static str) -> std::path::PathBuf {
        let source = tmp.join("new");
        identity_in(&source, 0x91, "new");
        let zip = zip_of(&[
            ("identity.key", &std::fs::read(source.join("identity.key")).unwrap()),
            ("messages.db", &std::fs::read(source.join("messages.db")).unwrap()),
            ("files/ab12.png", b"HFE1"),
        ]);
        let root = tmp.join("data");
        identity_in(&root, 0x92, "old");
        *CRASH_CLEANUP_AT.lock().unwrap_or_else(|e| e.into_inner()) = Some(step);
        let crashed = std::panic::catch_unwind(|| import_snapshot_bytes(&zip));
        *CRASH_CLEANUP_AT.lock().unwrap_or_else(|e| e.into_inner()) = None;
        assert!(crashed.is_err(), "the simulated crash at {step} did not happen");
        assert_eq!(pair_in_root().as_deref(), Ok("new"), "the commit did not finish before {step}");
        root
    }

    fn no_landing_left(root: &std::path::Path) -> Vec<&'static str> {
        [LANDING_STAGE, LANDING_ASIDE, LANDED].into_iter().filter(|n| root.join(n).exists()).collect()
    }

    /// A crash at any step of a finished landing's cleanup: the next launch keeps the
    /// new pair, places the content and clears every leftover.
    #[test]
    fn a_finished_landing_survives_a_crash_at_every_cleanup_step() {
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        for step in CLEANUP_STEPS {
            let tmp = crate::test_tmp::tempdir().unwrap();
            let root = landed_then_died_at(tmp.path(), step);
            has_pending_link().unwrap();
            assert_eq!(pair_in_root().as_deref(), Ok("new"), "a crash at {step} undid the landing");
            assert!(no_landing_left(&root).is_empty(), "after {step}: {:?}", no_landing_left(&root));
            assert!(root.join("files").join("ab12.png").exists(), "a crash at {step} lost the content");
        }
    }

    /// Whatever part of the replaced set a cut-short delete took, a finished landing
    /// stays finished.
    #[test]
    fn a_finished_landing_survives_any_partial_delete_of_what_it_replaced() {
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let entries = [ASIDE_MOVED, "identity.key", "messages.db"];
        for taken in 0..(1u8 << entries.len()) {
            let tmp = crate::test_tmp::tempdir().unwrap();
            let root = landed_then_died_at(tmp.path(), "moved");
            let gone: Vec<&str> = entries.iter().enumerate().filter(|(i, _)| taken & (1 << i) != 0).map(|(_, n)| *n).collect();
            for name in &gone {
                std::fs::remove_file(root.join(LANDING_ASIDE).join(name)).unwrap();
            }
            has_pending_link().unwrap();
            assert_eq!(pair_in_root().as_deref(), Ok("new"), "with {gone:?} gone from the replaced set");
            assert!(no_landing_left(&root).is_empty(), "with {gone:?} gone: {:?}", no_landing_left(&root));
        }
    }

    /// Should the landed mark ever be lost once the cleanup began, what is left aside
    /// still never displaces the new pair.
    #[test]
    fn a_finished_landing_that_lost_its_mark_is_never_undone() {
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        for step in ["aside", "landed"] {
            let tmp = crate::test_tmp::tempdir().unwrap();
            let root = landed_then_died_at(tmp.path(), step);
            let _ = std::fs::remove_file(root.join(LANDED));
            let _ = has_pending_link();
            assert_eq!(pair_in_root().as_deref(), Ok("new"), "lost at {step}");
        }
    }

    /// Without the moved mark, nothing aside is put back over a file in the root: that
    /// file is not one the landing put there.
    #[test]
    fn a_put_back_never_lands_on_a_file_already_in_the_root() {
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let old = tmp.path().join("old");
        identity_in(&old, 0x97, "old");
        let root = tmp.path().join("data");
        identity_in(&root, 0x98, "new");
        let aside = root.join(LANDING_ASIDE);
        std::fs::create_dir_all(&aside).unwrap();
        for name in ["identity.key", "messages.db"] {
            std::fs::copy(old.join(name), aside.join(name)).unwrap();
        }
        assert!(has_pending_link().is_ok());
        assert_eq!(pair_in_root().as_deref(), Ok("new"));
    }

    /// A held leftover of a finished landing is retried quietly at each launch, a later
    /// landing waits for it, and once let go it goes.
    #[cfg(windows)]
    #[test]
    fn a_held_leftover_of_a_finished_landing_goes_at_a_later_launch() {
        use std::os::windows::fs::OpenOptionsExt;
        const FILE_SHARE_READ: u32 = 1;
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        for step in CLEANUP_STEPS {
            let tmp = crate::test_tmp::tempdir().unwrap();
            let root = landed_then_died_at(tmp.path(), step);
            let old_db = root.join(LANDING_ASIDE).join("messages.db");
            let scanner = old_db.exists().then(|| {
                std::fs::OpenOptions::new().read(true).share_mode(FILE_SHARE_READ).open(&old_db).unwrap()
            });
            assert!(has_pending_link().is_ok());
            assert_eq!(pair_in_root().as_deref(), Ok("new"), "held after {step}");
            if scanner.is_some() {
                assert!(root.join(LANDED).exists(), "the mark went before the held file, after {step}");
                let source = tmp.path().join("new");
                let zip = zip_of(&[
                    ("identity.key", &std::fs::read(source.join("identity.key")).unwrap()),
                    ("messages.db", &std::fs::read(source.join("messages.db")).unwrap()),
                ]);
                assert!(import_snapshot_bytes(&zip).is_err(), "a landing started over a held leftover");
                assert_eq!(pair_in_root().as_deref(), Ok("new"));
            }
            drop(scanner);
            assert!(has_pending_link().is_ok());
            assert_eq!(pair_in_root().as_deref(), Ok("new"), "released after {step}");
            assert!(no_landing_left(&root).is_empty(), "after {step}: {:?}", no_landing_left(&root));
        }
    }

    /// A landing whose mark failed is undone with the mark: nothing calls the old set
    /// replaced.
    #[test]
    fn a_landing_whose_mark_failed_leaves_no_mark() {
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        identity_in(&tmp.path().join("source"), 0x99, "linked");
        let source = tmp.path().join("source");
        let zip = zip_of(&[
            ("identity.key", &std::fs::read(source.join("identity.key")).unwrap()),
            ("messages.db", &std::fs::read(source.join("messages.db")).unwrap()),
        ]);
        let root = tmp.path().join("data");
        identity_in(&root, 0x9a, "throwaway");
        *FAIL_COMMIT_AT.lock().unwrap_or_else(|e| e.into_inner()) = Some(LANDED);
        let landed = import_snapshot_bytes(&zip);
        *FAIL_COMMIT_AT.lock().unwrap_or_else(|e| e.into_inner()) = None;
        assert!(landed.is_err());
        assert!(no_landing_left(&root).is_empty(), "{:?}", no_landing_left(&root));
        assert_eq!(pair_in_root().as_deref(), Ok("throwaway"));
    }

    /// A wipe the next launch finishes owns the root: no landing starts in it and
    /// nothing a landing left is put back into it.
    #[test]
    fn a_pending_wipe_takes_a_landings_leftovers_and_starts_none() {
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        identity_in(&tmp.path().join("source"), 0x9b, "linked");
        let source = tmp.path().join("source");
        let zip = zip_of(&[
            ("identity.key", &std::fs::read(source.join("identity.key")).unwrap()),
            ("messages.db", &std::fs::read(source.join("messages.db")).unwrap()),
        ]);
        let root = tmp.path().join("data");
        identity_in(&root, 0x9c, "cancelled link");
        std::fs::write(root.join(PENDING_WIPE_MARKER), b"1").unwrap();
        assert_eq!(import_snapshot_bytes(&zip), Err(IDENTITY_NOT_READY.to_string()));
        assert_eq!(pair_in_root().as_deref(), Ok("cancelled link"), "a landing ran over a pending wipe");

        // A landing cut short mid-commit, and then a wipe that took the root's files.
        let aside = root.join(LANDING_ASIDE);
        std::fs::create_dir_all(&aside).unwrap();
        for name in ["identity.key", "messages.db"] {
            std::fs::rename(root.join(name), aside.join(name)).unwrap();
        }
        std::fs::write(aside.join(ASIDE_MOVED), b"").unwrap();
        let _ = has_pending_link();
        for name in ["identity.key", "messages.db"] {
            assert!(!root.join(name).exists(), "{name} was put back into a root being wiped");
        }
        perform_pending_wipe().unwrap();
        assert!(!has_pending_wipe().unwrap());
        assert!(no_landing_left(&root).is_empty(), "{:?}", no_landing_left(&root));
    }

    /// A boot wipe keeps its marker while a landing's leftover is held.
    #[cfg(windows)]
    #[test]
    fn a_boot_wipe_keeps_its_marker_while_a_landings_leftover_is_held() {
        use std::os::windows::fs::OpenOptionsExt;
        const FILE_SHARE_READ: u32 = 1;
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = landed_then_died_at(tmp.path(), "content");
        let scanner = std::fs::OpenOptions::new()
            .read(true)
            .share_mode(FILE_SHARE_READ)
            .open(root.join(LANDING_ASIDE).join("messages.db"))
            .unwrap();
        stash_pending_wipe().unwrap();
        assert!(!perform_pending_wipe().unwrap());
        assert!(has_pending_wipe().unwrap(), "the marker went while the leftover was held");
        drop(scanner);
        perform_pending_wipe().unwrap();
        assert!(!has_pending_wipe().unwrap());
        assert!(no_landing_left(&root).is_empty(), "{:?}", no_landing_left(&root));
    }

    /// While a wipe is pending, what a person sees is the very refusal a landing
    /// gives, which names no wipe.
    #[test]
    fn a_pending_wipe_refuses_in_the_words_a_landing_uses() {
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", tmp.path()) };
        crate::identity::encryption::clear_session_key();
        let landing = {
            let _landing = LandingFlag::raise();
            crate::identity::load_or_create_identity().err()
        };
        stash_pending_wipe().unwrap();
        let wiping = crate::identity::load_or_create_identity().err();
        assert!(!tmp.path().join("identity.key").exists(), "a key was minted while a wipe was pending");
        assert_eq!(wiping, landing);
        assert_eq!(wiping.as_deref(), Some(IDENTITY_NOT_READY));
        assert!(!IDENTITY_NOT_READY.to_lowercase().contains("wipe"));
    }

    /// A new link's stash starts its tries over even when the earlier count sits there.
    #[test]
    fn a_new_link_stash_clears_the_spent_tries() {
        let _g = crate::node::resolver::test_lock();
        let _s = store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", tmp.path()) };
        std::fs::write(tmp.path().join("pending_link.tries"), (LINK_LANDING_TRIES - 1).to_string()).unwrap();
        stash_pending_link(b"blob", "code", b"device").unwrap();
        assert!(!spend_link_try(), "a new link inherited an earlier one's spent tries");
    }
}
