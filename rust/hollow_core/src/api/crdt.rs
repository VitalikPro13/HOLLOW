use flutter_rust_bridge::frb;

use super::network::{get_node, get_runtime};
use crate::node;

/// Server info for FFI (Dart-visible).
pub struct ServerFfi {
    pub server_id: String,
    pub name: String,
    pub member_count: u32,
    pub channel_count: u32,
}

/// A join that has not completed yet, for the pending tile.
///
/// `state` is `pending` or `rejected` (`reason` says which gate refused), and
/// `last_deposited_at` is when the request was last written into the server room's
/// join ring, 0 while the join is still live.
pub struct PendingJoinFfi {
    pub server_id: String,
    pub requested_at: i64,
    pub state: String,
    pub reason: String,
    pub last_deposited_at: i64,
}

/// Channel info for FFI (Dart-visible).
///
/// `me_can_see` / `me_can_post` are computed HERE with the full Rust predicate (tier
/// ladder, label gates, unexpired grants, SEND_MESSAGES bit) so Dart never
/// re-implements the access ladder. Mute is NOT folded into `me_can_post`: it stays
/// a separate signal.
pub struct ChannelFfi {
    pub channel_id: String,
    pub name: String,
    pub category: Option<String>,
    pub channel_type: String,
    pub visibility: String,
    pub posting: String,
    pub is_public: bool,
    pub slow_mode: u32,
    pub media_only: bool,
    pub visibility_labels: Vec<String>,
    pub posting_labels: Vec<String>,
    pub me_can_see: bool,
    pub me_can_post: bool,
}

/// A temporary channel access grant for FFI (Dart-visible). `permanent` =
/// until revoked; otherwise `expires_at_ms` is the epoch-ms expiry. Mirrors
/// [MutedMemberFfi].
pub struct ChannelGrantFfi {
    pub peer_id: String,
    pub expires_at_ms: i64,
    pub permanent: bool,
}

/// A muted member for FFI (Dart-visible). `permanent` = no expiry;
/// otherwise `expires_at_ms` is the epoch-ms expiry.
pub struct MutedMemberFfi {
    pub peer_id: String,
    pub expires_at_ms: i64,
    pub permanent: bool,
}

/// Member info for FFI (Dart-visible).
pub struct MemberFfi {
    pub peer_id: String,
    pub display_name: String,
    pub role: String,
    pub nickname: String,
    pub twitch_username: String,
    pub labels: Vec<LabelFfi>,
}

/// Label info for FFI (Dart-visible). `access` labels gate channels and are
/// assigned only by MANAGE_ROLES holders (never self-service).
pub struct LabelFfi {
    pub label_id: String,
    pub name: String,
    pub color: String,
    pub access: bool,
}

/// Storage stats for a server, returned to Dart via FFI.
pub struct StorageStatsFfi {
    pub total_pledged_bytes: u64,
    pub total_used_bytes: u64,
    pub my_pledge_bytes: u64,
    pub my_used_bytes: u64,
    pub member_count: u32,
    pub min_pledge_mb: u64,
}

/// Status of a single vault file (erasure-coded), returned to Dart for the
/// Archive tab's shard status indicator.
pub struct VaultFileStatusFfi {
    pub content_id: String,
    pub file_name: String,
    pub original_size: u64,
    pub k: u16,
    pub m: u16,
    pub local_shard_count: u16,
    pub is_reconstructable: bool,
    pub channel_id: String,
    pub created_at: i64,
}

/// Create a new server. Returns the server_id.
#[frb]
pub fn create_server(name: String) -> Result<String, String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state
            .cmd_tx
            .send(node::NodeCommand::CreateServer { name }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok("pending".to_string())
}

/// Create a channel in a server. Returns the NEW channel's id.
///
/// The id is minted here rather than inside the handler because the caller needs it
/// in the same breath: "create a channel in this category" writes the layout before
/// any event comes back, and a placeholder id left a dangling layout entry.
///
/// The channel itself is still created asynchronously and a permission failure drops
/// the whole thing, so a caller that stores this id must tolerate one that never
/// materialises. Layout normalisation does: it drops references to missing channels.
/// references to channels that do not exist.
#[frb]
pub fn create_channel(
    server_id: String,
    name: String,
    category: Option<String>,
    channel_type: String,
) -> Result<String, String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    // Drop the mutex before the send: holding it across block_on(send) serializes
    // every other FFI call.
    drop(guard);

    let channel_id = node::new_channel_id(&server_id);
    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::CreateChannel {
            server_id,
            channel_id: channel_id.clone(),
            name,
            category,
            channel_type,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(channel_id)
}

/// Remove a channel from a server.
#[frb]
pub fn remove_channel(server_id: String, channel_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::RemoveChannel {
            server_id,
            channel_id,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Get all servers the user has joined. Reads from the local DB.
#[frb]
pub fn get_joined_servers() -> Result<Vec<ServerFfi>, String> {
    let store_guard = super::storage::get_store().lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let store = store_guard.as_ref().ok_or("Message store is not open")?;
    let servers = store.load_all_servers()?;

    // Our MASTER id, since memberships are master-keyed. If the identity cannot load
    // (locked), skip the membership filter rather than hiding everything.
    let local_master = crate::identity::load_existing_identity()
        .ok()
        .flatten()
        .map(|id| id.keypair.peer_id());

    let mut result = Vec::new();
    for (server_id, state_json) in servers {
        if let Ok(state) =
            serde_json::from_str::<crate::crdt::server_state::ServerState>(&state_json)
        {
            // Hide tombstoned servers — the node retains the shell to serve the
            // deletion op to reconnecting peers, but the UI must not list it.
            if state.is_deleted() { continue; }
            // Hide servers we LEFT or were kicked from whose shell survived. Never hide a
            // server with no members at all: that is a fresh state mid-bootstrap.
            if let Some(ref me) = local_master {
                if !state.members.is_empty() && !state.is_member(me) { continue; }
            }
            result.push(ServerFfi {
                server_id,
                name: state.name().to_string(),
                member_count: state.members.len() as u32,
                channel_count: state.channels.len() as u32,
            });
        }
    }
    Ok(result)
}

/// Every join still waiting for an answer, plus the ones a member rejected.
///
/// Reads the local DB like [get_joined_servers]: these rows are written by the node's
/// CrdtStore actor and only ever read here, so a snapshot on the FRB thread is
/// exactly the tile's data source.
#[frb]
pub fn list_pending_joins() -> Result<Vec<PendingJoinFfi>, String> {
    let store_guard = super::storage::get_store().lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let store = store_guard.as_ref().ok_or("Message store is not open")?;
    Ok(store
        .load_pending_joins()?
        .into_iter()
        .map(|r| PendingJoinFfi {
            server_id: r.server_id,
            requested_at: r.requested_at,
            state: r.state,
            reason: r.reason,
            last_deposited_at: r.last_deposited_at,
        })
        .collect())
}

/// Drop a pending or rejected join. Deletes the row, forgets the in-memory
/// entry and leaves the server room, so a late admission can never complete a
/// join the user walked away from.
#[frb]
pub fn discard_pending_join(server_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    get_runtime()
        .block_on(cmd_tx.send(node::NodeCommand::DiscardPendingJoin { server_id }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Ask again, reusing the row's stored NSFW consent and Twitch proof under a
/// fresh nonce. Same code path as the original request.
#[frb]
pub fn retry_pending_join(server_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    get_runtime()
        .block_on(cmd_tx.send(node::NodeCommand::RequestPendingJoinAgain { server_id }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Get channels for a specific server.
///
/// Prefers a LIVE clone of the event loop's in-memory state, the copy that ENFORCES:
/// the CrdtStore flush is async fire-and-forget and `ServerUpdated` fires BEFORE it
/// lands, so a DB-snapshot read racing a fresh toggle returned the PREVIOUS value and
/// reverted optimistic UI. Falls back to the persisted snapshot when the node is not
/// running, so early-startup callers keep working.
#[frb]
pub fn get_server_channels(server_id: String) -> Result<Vec<ChannelFfi>, String> {
    if let Some(state) = live_server_state(&server_id) {
        return Ok(channels_from_state(&state));
    }
    let store_guard = super::storage::get_store().lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let store = store_guard.as_ref().ok_or("Message store is not open")?;
    let state_json = store
        .load_server_state(&server_id)?
        .ok_or(format!("Server {server_id} not found"))?;

    let state =
        serde_json::from_str::<crate::crdt::server_state::ServerState>(&state_json)
            .map_err(|e| format!("Failed to parse server state: {e}"))?;
    Ok(channels_from_state(&state))
}

/// Live in-memory `ServerState` clone from the running event loop, or `None`
/// when the node is down, the server is unknown, or the reply doesn't arrive
/// within 3s (a wedged loop must degrade to the DB read, not hang the UI).
fn live_server_state(server_id: &str) -> Option<crate::crdt::server_state::ServerState> {
    let node = get_node();
    let cmd_tx = {
        let guard = node.lock().ok()?;
        guard.as_ref()?.cmd_tx.clone()
        // The guard is dropped before the blocking send: never hold the global node
        // mutex across block_on.
    };
    let (reply_tx, reply_rx) = tokio::sync::oneshot::channel();
    let rt = get_runtime();
    rt.block_on(async {
        cmd_tx
            .send(node::NodeCommand::GetServerStateSnapshot {
                server_id: server_id.to_string(),
                reply: reply_tx,
            })
            .await
            .ok()?;
        tokio::time::timeout(std::time::Duration::from_secs(3), reply_rx)
            .await
            .ok()?
            .ok()?
    })
}

/// Shared `ServerState` → `Vec<ChannelFfi>` mapping for the live and
/// DB-snapshot paths of [`get_server_channels`].
fn channels_from_state(state: &crate::crdt::server_state::ServerState) -> Vec<ChannelFfi> {
    // Local master for the me_can_see/me_can_post computation; no identity fails closed.
    let me = crate::identity::load_existing_identity()
        .ok()
        .flatten()
        .map(|id| id.keypair.peer_id());
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;

    state
        .channels_list()
        .into_iter()
        .map(|ch| {
            use crate::crdt::server_state::{ChannelType, ChannelVisibility, ChannelPosting};
            ChannelFfi {
                channel_id: ch.channel_id.clone(),
                name: ch.name.clone(),
                category: ch.category.clone(),
                channel_type: match ch.channel_type {
                    ChannelType::Voice => "voice".to_string(),
                    _ => "text".to_string(),
                },
                visibility: match ch.visibility {
                    ChannelVisibility::Everyone => "everyone".to_string(),
                    ChannelVisibility::ModeratorPlus => "moderator".to_string(),
                    ChannelVisibility::AdminPlus => "admin".to_string(),
                },
                posting: match ch.posting {
                    ChannelPosting::Everyone => "everyone".to_string(),
                    ChannelPosting::ModeratorPlus => "moderator".to_string(),
                    ChannelPosting::AdminPlus => "admin".to_string(),
                },
                // EFFECTIVE flag: voice channels are never public (#44), so a stale CRDT
                // `is_public` on one never reaches Dart.
                is_public: ch.effective_public(),
                slow_mode: ch.slow_mode,
                media_only: ch.media_only,
                visibility_labels: ch.visibility_labels.clone(),
                posting_labels: ch.posting_labels.clone(),
                me_can_see: me.as_deref()
                    .map(|m| state.can_see_channel_at(m, &ch.channel_id, now_ms))
                    .unwrap_or(false),
                me_can_post: me.as_deref()
                    .map(|m| state.can_post_in_channel_at(m, &ch.channel_id, now_ms))
                    .unwrap_or(false),
            }
        })
        .collect()
}

/// Get members for a specific server. Reads from the local DB.
#[frb]
pub fn get_server_members(server_id: String) -> Result<Vec<MemberFfi>, String> {
    let store_guard = super::storage::get_store().lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let store = store_guard.as_ref().ok_or("Message store is not open")?;
    let state_json = store
        .load_server_state(&server_id)?
        .ok_or(format!("Server {server_id} not found"))?;

    let state =
        serde_json::from_str::<crate::crdt::server_state::ServerState>(&state_json)
            .map_err(|e| format!("Failed to parse server state: {e}"))?;

    let members = state
        .members_list()
        .into_iter()
        .map(|m| MemberFfi {
            peer_id: m.peer_id.clone(),
            display_name: m.display_name.clone(),
            role: state.get_role(&m.peer_id).as_str().to_string(),
            nickname: state.get_nickname(&m.peer_id),
            twitch_username: state.get_twitch_username(&m.peer_id),
            labels: state.get_member_labels(&m.peer_id)
                .into_iter()
                .map(|l| LabelFfi {
                    label_id: l.label_id.clone(),
                    name: l.name.clone(),
                    color: l.color.clone(),
                    access: l.access,
                })
                .collect(),
        })
        .collect();

    Ok(members)
}

/// Get a server setting value by key. Returns empty string if not set.
#[frb]
pub fn get_server_setting(server_id: String, key: String) -> Result<String, String> {
    let store_guard = super::storage::get_store().lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let store = store_guard.as_ref().ok_or("Message store is not open")?;
    let state_json = store
        .load_server_state(&server_id)?
        .ok_or(format!("Server {server_id} not found"))?;

    let state =
        serde_json::from_str::<crate::crdt::server_state::ServerState>(&state_json)
            .map_err(|e| format!("Failed to parse server state: {e}"))?;

    Ok(state
        .settings
        .get(&key)
        .map(|reg| reg.read().clone())
        .unwrap_or_default())
}

/// Rename a server.
#[frb]
pub fn rename_server(server_id: String, new_name: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::RenameServer {
            server_id,
            new_name,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Rename a channel in a server.
#[frb]
pub fn rename_channel(server_id: String, channel_id: String, new_name: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::RenameChannel {
            server_id,
            channel_id,
            new_name,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Update a server setting (key-value pair).
#[frb]
pub fn update_server_setting(server_id: String, key: String, value: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::UpdateServerSetting {
            server_id,
            key,
            value,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Set a server avatar. Processes the raw image to a still 128x128 WebP stored base64
/// in `settings["server_avatar"]`, which old clients and the public sync thumb read.
/// An ANIMATED source additionally produces a 128px animated WebP cached
/// content-addressed, with only its HASH in `settings["server_avatar_anim"]`.
#[frb]
pub fn set_server_avatar(server_id: String, raw_bytes: Vec<u8>) -> Result<(), String> {
    // SERVER_ICON_DIM, not a person's AVATAR_DIM: this still is base64 INSIDE the
    // CRDT, so it replicates to every member.
    let processed = crate::node::image_convert::process_still_avatar(
        &raw_bytes,
        crate::node::image_convert::SERVER_ICON_DIM,
    )?;

    let anim_hash = if crate::node::image_convert::is_animated_image(&raw_bytes) {
        let anim = crate::node::image_convert::process_server_avatar_anim(&raw_bytes)?;
        let hash = {
            use sha2::{Digest, Sha256};
            hex::encode(Sha256::digest(&anim))
        };
        let store = super::storage::get_store();
        let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        let ms = guard.as_ref().ok_or("Message store is not open")?;
        ms.save_asset_blob(&hash, &anim, true, "avatar")?;
        hash
    } else {
        // A still upload replaces any previous animated icon.
        String::new()
    };

    // Anim hash first, so the still write that drives UI reloads lands with its
    // companion already in place.
    update_server_setting(server_id.clone(), "server_avatar_anim".into(), anim_hash)?;
    use base64::Engine;
    let b64 = base64::engine::general_purpose::STANDARD.encode(&processed);
    update_server_setting(server_id, "server_avatar".into(), b64)
}

/// Clear a server avatar (both the still base64 and any animated-icon hash).
#[frb]
pub fn clear_server_avatar(server_id: String) -> Result<(), String> {
    update_server_setting(server_id.clone(), "server_avatar_anim".into(), String::new())?;
    update_server_setting(server_id, "server_avatar".into(), String::new())
}

/// Get a server avatar as raw bytes. Returns None if no avatar set.
#[frb]
pub fn get_server_avatar(server_id: String) -> Result<Option<Vec<u8>>, String> {
    let b64 = get_server_setting(server_id, "server_avatar".into())?;
    if b64.is_empty() {
        return Ok(None);
    }
    use base64::Engine;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(&b64)
        .map_err(|e| format!("Invalid server avatar base64: {e}"))?;
    Ok(Some(bytes))
}

/// Animated server icon as seen locally. The CRDT carries only the hash; the bytes
/// live in the content-addressed asset store and replicate via the asset rail, never
/// through the CRDT. The still icon is separate.
pub struct ServerAvatarAnimData {
    /// 64-hex SHA-256 of the processed animated WebP bytes.
    pub hash: String,
    /// Cached blob bytes, if we hold them. `None` = pull via
    /// `request_assets(kind: "avatar")` and re-read on `EmoteAssetsReceived`.
    pub bytes: Option<Vec<u8>>,
}

/// Get the animated server icon. `None` = the server has no animated icon
/// (still-only, or cleared); `bytes` is `None` when the hash is known but
/// the blob hasn't been pulled yet.
#[frb]
pub fn get_server_avatar_anim(server_id: String) -> Result<Option<ServerAvatarAnimData>, String> {
    let hash = get_server_setting(server_id, "server_avatar_anim".into())?;
    // "" = still-only; anything non-hex is not a usable reference either way.
    if !crate::crdt::valid_emote_hash(&hash) {
        return Ok(None);
    }
    let bytes = {
        let store = super::storage::get_store();
        let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        let ms = guard.as_ref().ok_or("Message store is not open")?;
        ms.load_emote_blob(&hash)?
    };
    Ok(Some(ServerAvatarAnimData { hash, bytes }))
}

/// Server banner as seen locally. The CRDT carries only the hash; the bytes live in
/// the content-addressed asset store and replicate via the asset rail.
pub struct ServerBannerData {
    /// 64-hex SHA-256 of the processed WebP bytes.
    pub hash: String,
    pub animated: bool,
    /// Cached blob bytes, if we hold them. `None` = pull via
    /// `request_assets(kind: "banner")` and re-read on `EmoteAssetsReceived`.
    pub bytes: Option<Vec<u8>>,
}

/// Set a server banner (issue #25). Processes the raw image (3:1 center
/// crop → 960x320 WebP, animated allowed), caches the blob content-addressed
/// with kind='banner', and writes ONLY the hash into CRDT settings.
#[frb]
pub fn set_server_banner(server_id: String, raw_bytes: Vec<u8>) -> Result<(), String> {
    let (processed, animated) =
        crate::node::image_convert::process_server_banner_image(&raw_bytes)?;
    let hash = {
        use sha2::{Digest, Sha256};
        hex::encode(Sha256::digest(&processed))
    };
    {
        let store = super::storage::get_store();
        let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        let ms = guard.as_ref().ok_or("Message store is not open")?;
        ms.save_asset_blob(&hash, &processed, animated, "banner")?;
    }
    // Animated flag first, so the hash write that drives UI reloads lands with its
    // companion already in place.
    update_server_setting(
        server_id.clone(),
        "server_banner_animated".into(),
        if animated { "1".into() } else { String::new() },
    )?;
    update_server_setting(server_id, "server_banner".into(), hash)
}

/// Clear a server banner. The blob stays cached until asset-cache eviction
/// collects it (it drops out of `referenced_asset_hashes`).
#[frb]
pub fn clear_server_banner(server_id: String) -> Result<(), String> {
    update_server_setting(server_id.clone(), "server_banner_animated".into(), String::new())?;
    update_server_setting(server_id, "server_banner".into(), String::new())
}

/// Get the server banner. `None` = no banner set (or cleared); `bytes` is
/// `None` when the hash is known but the blob hasn't been pulled yet.
#[frb]
pub fn get_server_banner(server_id: String) -> Result<Option<ServerBannerData>, String> {
    let hash = get_server_setting(server_id.clone(), "server_banner".into())?;
    // "" = cleared; anything non-hex is not a usable reference either way.
    if !crate::crdt::valid_emote_hash(&hash) {
        return Ok(None);
    }
    let animated = get_server_setting(server_id, "server_banner_animated".into())? == "1";
    let bytes = {
        let store = super::storage::get_store();
        let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        let ms = guard.as_ref().ok_or("Message store is not open")?;
        ms.load_emote_blob(&hash)?
    };
    Ok(Some(ServerBannerData { hash, animated, bytes }))
}

/// Join a server via invite link. Connects to the server's signaling room and
/// requests membership from existing members.
#[frb]
pub fn join_server(
    server_id: String,
    twitch_proof_json: Option<String>,
    nsfw_confirmed: bool,
) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state
            .cmd_tx
            .send(node::NodeCommand::JoinServer { server_id, twitch_proof_json, nsfw_confirmed }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Get the local user's role in a server.
/// Returns "owner", "admin", "moderator", or "member".
#[frb]
pub fn get_my_role(server_id: String) -> Result<String, String> {
    let store_guard = super::storage::get_store().lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let store = store_guard.as_ref().ok_or("Message store is not open")?;
    let state_json = store
        .load_server_state(&server_id)?
        .ok_or(format!("Server {server_id} not found"))?;

    let state =
        serde_json::from_str::<crate::crdt::server_state::ServerState>(&state_json)
            .map_err(|e| format!("Failed to parse server state: {e}"))?;

    let peer_id = super::storage::get_peer_id()?;
    Ok(state.get_role(peer_id).as_str().to_string())
}

/// Get the local user's permissions bitmask in a server.
#[frb]
pub fn get_my_permissions(server_id: String) -> Result<u32, String> {
    let store_guard = super::storage::get_store().lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let store = store_guard.as_ref().ok_or("Message store is not open")?;
    let state_json = store
        .load_server_state(&server_id)?
        .ok_or(format!("Server {server_id} not found"))?;

    let state =
        serde_json::from_str::<crate::crdt::server_state::ServerState>(&state_json)
            .map_err(|e| format!("Failed to parse server state: {e}"))?;

    let peer_id = super::storage::get_peer_id()?;
    Ok(state.get_permissions(peer_id))
}

/// Change a member's role in a server.
/// Requires MANAGE_ROLES permission and must outrank the target.
#[frb]
pub fn change_member_role(server_id: String, peer_id: String, new_role: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::ChangeRole {
            server_id,
            peer_id,
            new_role,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Kick a member from a server.
/// Requires KICK_MEMBERS permission and must outrank the target.
#[frb]
pub fn kick_member(server_id: String, peer_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::KickMember {
            server_id,
            peer_id,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Set a member's server nickname. Pass an empty string to clear.
#[frb]
pub fn set_nickname(server_id: String, peer_id: String, nickname: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::SetNickname {
            server_id,
            peer_id,
            nickname,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

#[frb]
pub fn set_twitch_username(server_id: String, peer_id: String, twitch_username: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::SetTwitchUsername {
            server_id,
            peer_id,
            twitch_username,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Update the channel layout (ordering/categories) for a server.
/// layout_json is a JSON array of ChannelLayoutItem objects.
#[frb]
pub fn update_channel_layout(server_id: String, layout_json: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::UpdateChannelLayout {
            server_id,
            layout_json,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Get the channel layout for a server. Returns a JSON array of ChannelLayoutItem.
#[frb]
pub fn get_channel_layout(server_id: String) -> Result<String, String> {
    let store_guard = super::storage::get_store().lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let store = store_guard.as_ref().ok_or("Message store is not open")?;
    let state_json = store
        .load_server_state(&server_id)?
        .ok_or(format!("Server {server_id} not found"))?;

    let state =
        serde_json::from_str::<crate::crdt::server_state::ServerState>(&state_json)
            .map_err(|e| format!("Failed to parse server state: {e}"))?;

    let layout_json = serde_json::to_string(&state.channel_layout)
        .map_err(|e| format!("Failed to serialize layout: {e}"))?;
    hollow_log!("[HOLLOW-LAYOUT] get_channel_layout({server_id}): {} items, json={layout_json}", state.channel_layout.len());
    Ok(layout_json)
}

/// Pin a message in a channel. Requires MANAGE_CHANNELS permission.
#[frb]
pub fn pin_message(server_id: String, channel_id: String, message_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::PinMessage {
            server_id,
            channel_id,
            message_id,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Unpin a message from a channel. Requires MANAGE_CHANNELS permission.
#[frb]
pub fn unpin_message(server_id: String, channel_id: String, message_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::UnpinMessage {
            server_id,
            channel_id,
            message_id,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Get pinned message IDs for a channel.
#[frb]
pub fn get_pinned_messages(server_id: String, channel_id: String) -> Result<Vec<String>, String> {
    let store_guard = super::storage::get_store().lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let store = store_guard.as_ref().ok_or("Message store is not open")?;
    let state_json = store
        .load_server_state(&server_id)?
        .ok_or(format!("Server {server_id} not found"))?;

    let state =
        serde_json::from_str::<crate::crdt::server_state::ServerState>(&state_json)
            .map_err(|e| format!("Failed to parse server state: {e}"))?;

    Ok(state.get_pinned_messages(&channel_id))
}

/// Delete a server entirely (removes from local DB and memory).
#[frb]
pub fn delete_server(server_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::DeleteServer {
            server_id,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Create a new label in a server. `access: true` makes it an access label
/// (gates channels, never self-assignable).
#[frb]
pub fn create_label(server_id: String, name: String, color: String, access: bool) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);
    let rt = get_runtime();
    rt.block_on(cmd_tx.send(node::NodeCommand::CreateLabel { server_id, name, color, access }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Delete a label from a server.
#[frb]
pub fn delete_label(server_id: String, label_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);
    let rt = get_runtime();
    rt.block_on(cmd_tx.send(node::NodeCommand::DeleteLabel { server_id, label_id }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Update a label's name, color and access flag.
#[frb]
pub fn update_label(server_id: String, label_id: String, name: String, color: String, access: bool) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);
    let rt = get_runtime();
    rt.block_on(cmd_tx.send(node::NodeCommand::UpdateLabel { server_id, label_id, name, color, access }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Assign a label to a member.
#[frb]
pub fn assign_label(server_id: String, label_id: String, peer_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);
    let rt = get_runtime();
    rt.block_on(cmd_tx.send(node::NodeCommand::AssignLabel { server_id, label_id, peer_id }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Remove a label from a member.
#[frb]
pub fn unassign_label(server_id: String, label_id: String, peer_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);
    let rt = get_runtime();
    rt.block_on(cmd_tx.send(node::NodeCommand::UnassignLabel { server_id, label_id, peer_id }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Get all labels defined in a server.
#[frb]
pub fn get_server_labels(server_id: String) -> Result<Vec<LabelFfi>, String> {
    let store_guard = super::storage::get_store().lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let store = store_guard.as_ref().ok_or("Message store is not open")?;
    let state_json = store.load_server_state(&server_id)?.ok_or(format!("Server {server_id} not found"))?;
    let state = serde_json::from_str::<crate::crdt::server_state::ServerState>(&state_json)
        .map_err(|e| format!("Failed to parse server state: {e}"))?;

    Ok(state.labels_list().into_iter().map(|l| LabelFfi {
        label_id: l.label_id.clone(),
        name: l.name.clone(),
        color: l.color.clone(),
        access: l.access,
    }).collect())
}

/// Set (or clear, empty vec) the visibility label gate for a channel. The
/// Rust handler also stamps the legacy tier to Admin+ when the gate turns
/// on (old-client fail-closed fallback).
#[frb]
pub fn set_channel_visibility_labels(server_id: String, channel_id: String, labels: Vec<String>) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);
    let rt = get_runtime();
    rt.block_on(cmd_tx.send(node::NodeCommand::SetChannelVisibilityLabels { server_id, channel_id, labels }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Set (or clear, empty vec) the posting label gate for a channel.
#[frb]
pub fn set_channel_posting_labels(server_id: String, channel_id: String, labels: Vec<String>) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);
    let rt = get_runtime();
    rt.block_on(cmd_tx.send(node::NodeCommand::SetChannelPostingLabels { server_id, channel_id, labels }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Grant a member temporary access to a channel. `duration_secs <= 0` =
/// until revoked (same convention as mute_member).
#[frb]
pub fn grant_channel_access(server_id: String, channel_id: String, peer_id: String, duration_secs: i64) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let expires_at: u64 = if duration_secs <= 0 {
        u64::MAX
    } else {
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;
        now_ms.saturating_add((duration_secs as u64).saturating_mul(1000))
    };

    let rt = get_runtime();
    rt.block_on(cmd_tx.send(node::NodeCommand::GrantChannelAccess { server_id, channel_id, peer_id, expires_at }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Revoke a member's temporary channel access.
#[frb]
pub fn revoke_channel_access(server_id: String, channel_id: String, peer_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);
    let rt = get_runtime();
    rt.block_on(cmd_tx.send(node::NodeCommand::RevokeChannelAccess { server_id, channel_id, peer_id }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Active temporary grants for a channel (expired entries filtered out).
#[frb]
pub fn get_channel_grants(server_id: String, channel_id: String) -> Result<Vec<ChannelGrantFfi>, String> {
    let store_guard = super::storage::get_store().lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let store = store_guard.as_ref().ok_or("Message store is not open")?;
    let state_json = store.load_server_state(&server_id)?.ok_or(format!("Server {server_id} not found"))?;
    let state = serde_json::from_str::<crate::crdt::server_state::ServerState>(&state_json)
        .map_err(|e| format!("Failed to parse server state: {e}"))?;

    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;

    Ok(state
        .channel_grants_list(&channel_id, now_ms)
        .into_iter()
        .map(|(peer_id, expires_at)| {
            let permanent = expires_at == u64::MAX;
            ChannelGrantFfi {
                peer_id,
                expires_at_ms: if permanent { 0 } else { expires_at as i64 },
                permanent,
            }
        })
        .collect())
}

/// Set the visibility mode for a channel (everyone/moderator/admin).
#[frb]
pub fn set_channel_visibility(server_id: String, channel_id: String, visibility: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::SetChannelVisibility {
            server_id,
            channel_id,
            visibility,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Set the posting mode for a channel (everyone/moderator/admin).
#[frb]
pub fn set_channel_posting(server_id: String, channel_id: String, posting: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::SetChannelPosting {
            server_id,
            channel_id,
            posting,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Toggle public access for a channel.
#[frb]
pub fn set_channel_public(server_id: String, channel_id: String, is_public: bool) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::SetChannelPublic {
            server_id,
            channel_id,
            is_public,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Request the public channel list from a server (guest mode).
/// Joins the WS room and broadcasts a list request to online members.
#[frb]
pub fn request_public_channels(server_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::RequestPublicChannels { server_id }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Request message history for a public channel (guest mode).
#[frb]
pub fn request_public_channel_sync(
    server_id: String,
    channel_id: String,
    before_timestamp: Option<i64>,
) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::RequestPublicChannelSync {
            server_id,
            channel_id,
            before_timestamp,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Guest download of a PUBLIC-channel file (guest mode): asks one room peer
/// for the bytes. Progress/completion arrive via the normal FileProgress /
/// FileCompleted events keyed by `file_id`.
#[frb]
pub fn request_public_file(
    server_id: String,
    file_id: String,
    peer_hint: Option<String>,
) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::RequestPublicFile {
            server_id,
            file_id,
            peer_hint,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Leave a guest-mode WS room.
#[frb]
pub fn leave_guest_room(server_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::LeaveGuestRoom { server_id }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Ban a member from the server. Prevents rejoin.
#[frb]
pub fn ban_member(server_id: String, peer_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::BanMember {
            server_id,
            peer_id,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Unban a member, allowing them to rejoin.
#[frb]
pub fn unban_member(server_id: String, peer_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::UnbanMember {
            server_id,
            peer_id,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Get the list of banned peer IDs for a server.
#[frb]
pub fn get_banned_members(server_id: String) -> Result<Vec<String>, String> {
    let store_guard = super::storage::get_store().lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let store = store_guard.as_ref().ok_or("Message store is not open")?;
    let state_json = store
        .load_server_state(&server_id)?
        .ok_or(format!("Server {server_id} not found"))?;

    let state =
        serde_json::from_str::<crate::crdt::server_state::ServerState>(&state_json)
            .map_err(|e| format!("Failed to parse server state: {e}"))?;

    Ok(state.banned_list())
}

/// Mute a member server-wide (read-only: they can't post in any channel).
/// `duration_secs <= 0` = permanent mute; otherwise the mute expires
/// `duration_secs` from now.
#[frb]
pub fn mute_member(server_id: String, peer_id: String, duration_secs: i64) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let expires_at = if duration_secs <= 0 {
        u64::MAX
    } else {
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;
        now_ms.saturating_add(duration_secs as u64 * 1000)
    };

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::MuteMember {
            server_id,
            peer_id,
            expires_at,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Unmute a member.
#[frb]
pub fn unmute_member(server_id: String, peer_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::UnmuteMember {
            server_id,
            peer_id,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Get the currently active mutes for a server.
#[frb]
pub fn get_muted_members(server_id: String) -> Result<Vec<MutedMemberFfi>, String> {
    let store_guard = super::storage::get_store().lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let store = store_guard.as_ref().ok_or("Message store is not open")?;
    let state_json = store
        .load_server_state(&server_id)?
        .ok_or(format!("Server {server_id} not found"))?;

    let state =
        serde_json::from_str::<crate::crdt::server_state::ServerState>(&state_json)
            .map_err(|e| format!("Failed to parse server state: {e}"))?;

    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;

    Ok(state
        .muted_list(now_ms)
        .into_iter()
        .map(|(peer_id, expires_at)| MutedMemberFfi {
            peer_id,
            permanent: expires_at == u64::MAX,
            expires_at_ms: if expires_at == u64::MAX { 0 } else { expires_at as i64 },
        })
        .collect())
}

/// Set a channel's slow-mode interval in seconds (0 = off). Moderator+ exempt.
#[frb]
pub fn set_channel_slow_mode(server_id: String, channel_id: String, seconds: u32) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::SetChannelSlowMode {
            server_id,
            channel_id,
            seconds,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Toggle a channel's media-only mode (only images/GIFs/videos may be posted).
#[frb]
pub fn set_channel_media_only(server_id: String, channel_id: String, media_only: bool) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::SetChannelMediaOnly {
            server_id,
            channel_id,
            media_only,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Change the permissions bitmask for a role. Owner-only.
#[frb]
pub fn change_role_permissions(server_id: String, role: String, permissions: u32) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::ChangeRolePermissions {
            server_id,
            role,
            permissions,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Get the permissions bitmask for a role (custom or default).
#[frb]
pub fn get_role_permissions(server_id: String, role: String) -> Result<u32, String> {
    let store_guard = super::storage::get_store().lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let store = store_guard.as_ref().ok_or("Message store is not open")?;
    let state_json = store
        .load_server_state(&server_id)?
        .ok_or(format!("Server {server_id} not found"))?;

    let state =
        serde_json::from_str::<crate::crdt::server_state::ServerState>(&state_json)
            .map_err(|e| format!("Failed to parse server state: {e}"))?;

    Ok(state.get_role_permissions(&role))
}

/// Default permissions bitmask for a role name, the single source of truth for the
/// Dart Roles UIs. Pure function: "owner" gets ALL, unknown strings fall back to
/// Member.
#[frb(sync)]
pub fn default_role_permissions(role: String) -> u32 {
    crate::crdt::operations::MemberRole::from_str(&role).default_permissions()
}

/// Leave a server. The local user is removed from the server.
/// Owner cannot leave — must delete or transfer ownership first.
#[frb]
pub fn leave_server(server_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::LeaveServer {
            server_id,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Set the local user's storage pledge for a server (in bytes).
#[frb]
pub fn set_storage_pledge(server_id: String, pledge_bytes: u64) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::SetStoragePledge {
            server_id,
            pledge_bytes,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Get storage stats for a server (pledges from CRDT state, usage from vault_shards table).
#[frb]
pub fn get_storage_stats(server_id: String) -> Result<StorageStatsFfi, String> {
    let store_guard = super::storage::get_store().lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let store = store_guard.as_ref().ok_or("Message store is not open")?;
    let state_json = store
        .load_server_state(&server_id)?
        .ok_or(format!("Server {server_id} not found"))?;

    let state =
        serde_json::from_str::<crate::crdt::server_state::ServerState>(&state_json)
            .map_err(|e| format!("Failed to parse server state: {e}"))?;

    let peer_id = super::storage::get_peer_id()?;
    let total_pledged_bytes = state.total_pledged_bytes();
    let my_pledge_bytes = state.get_storage_pledge(peer_id);
    let member_count = state.members.len() as u32;
    let min_pledge_mb = state.min_pledge_mb();

    let hollow_dir = crate::identity::data_dir()?;
    let db_path = hollow_dir.join("messages.db").to_str().ok_or("Invalid path")?.to_string();
    let passphrase = super::storage::derive_db_key_public()?;
    let vault_dir = hollow_dir.join("vault");
    let (server_total, my_local) = if let Ok(content_store) =
        crate::vault::content_store::ContentStore::open(&db_path, &passphrase, &vault_dir)
    {
        let manifest_total = content_store.total_manifest_size(&server_id).unwrap_or(0);
        let local_shards = content_store.total_storage_used(&server_id).unwrap_or(0);
        (manifest_total, local_shards)
    } else {
        (0, 0)
    };

    let file_used = store.total_file_storage_for_server(&server_id).unwrap_or(0);
    let msg_used = store.total_message_storage_for_server(&server_id).unwrap_or(0);

    // Manifest total when the vault has data, otherwise the P2P file total, so nothing
    // is double-counted. Message text is always added on top.
    let total_server = if server_total > 0 { server_total + msg_used } else { file_used + msg_used };

    Ok(StorageStatsFfi {
        total_pledged_bytes,
        total_used_bytes: total_server,
        my_pledge_bytes,
        my_used_bytes: my_local + file_used + msg_used,
        member_count,
        min_pledge_mb,
    })
}

/// Get vault file statuses for a server — shows which erasure-coded files
/// exist, how many shards are held locally, and whether each is reconstructable.
/// Used by the Archive tab's shard status indicator (Evidence Recovery).
#[frb]
pub fn get_vault_file_statuses(server_id: String) -> Result<Vec<VaultFileStatusFfi>, String> {
    let hollow_dir = crate::identity::data_dir()?;
    let db_path = hollow_dir.join("messages.db").to_str().ok_or("Invalid path")?.to_string();
    let passphrase = super::storage::derive_db_key_public()?;
    let vault_dir = hollow_dir.join("vault");
    let content_store =
        crate::vault::content_store::ContentStore::open(&db_path, &passphrase, &vault_dir)
            .map_err(|e| format!("Failed to open content store: {e}"))?;

    let manifests = content_store
        .list_manifests(&server_id)
        .unwrap_or_default();

    let mut result = Vec::new();
    for manifest in manifests {
        // Skip full-replication files (k=0, m=0) — those are fully P2P replicated.
        if manifest.k == 0 && manifest.m == 0 {
            continue;
        }
        let local_shards = content_store
            .list_content_shards(&server_id, &manifest.content_id)
            .unwrap_or_default();
        let local_count = local_shards.len() as u16;

        result.push(VaultFileStatusFfi {
            content_id: manifest.content_id,
            file_name: manifest.file_name,
            original_size: manifest.original_size,
            k: manifest.k,
            m: manifest.m,
            local_shard_count: local_count,
            is_reconstructable: local_count >= manifest.k,
            channel_id: manifest.channel_id,
            created_at: manifest.created_at,
        });
    }

    Ok(result)
}

// ── Recovery pool commands (Evidence Recovery) ──────────────────

/// Initiate a recovery pool for a server. Generates a random token,
/// joins the WSS relay room, and returns the invite link.
#[frb]
pub fn initiate_recovery_pool(server_id: String) -> Result<String, String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let mut token_bytes = [0u8; 8];
    getrandom::fill(&mut token_bytes)
        .map_err(|e| format!("Failed to generate token: {e}"))?;
    let token = hex::encode(token_bytes);

    let invite_link = format!("hollow://recovery?server={}&token={}", server_id, token);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::InitiateRecoveryPool {
            server_id,
            token,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(invite_link)
}

/// Join an existing recovery pool via invite link.
/// Link format: `hollow://recovery?server={server_id}&token={token}`
#[frb]
pub fn join_recovery_pool(invite_link: String) -> Result<(), String> {
    let server_id = invite_link
        .split("server=")
        .nth(1)
        .and_then(|s| s.split('&').next())
        .ok_or("Invalid invite link: missing server")?
        .to_string();
    let token = invite_link
        .split("token=")
        .nth(1)
        .and_then(|s| s.split('&').next())
        .ok_or("Invalid invite link: missing token")?
        .to_string();

    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::JoinRecoveryPool {
            server_id,
            token,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Stop an active recovery pool.
#[frb]
pub fn stop_recovery_pool(server_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::StopRecoveryPool {
            server_id,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Delete vault content from a server (admin-only, requires MANAGE_SERVER).
/// Broadcasts ShardDelete to all connected members and removes local shards.
#[frb]
pub fn delete_vault_content(server_id: String, content_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::DeleteVaultContent {
            server_id,
            content_id,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Upload a file to the vault. Encrypts with AES-256-GCM, computes content_id,
/// then sends to swarm for erasure coding + distribution + manifest broadcast.
/// Returns the content_id immediately.
#[frb]
pub fn vault_upload_file(
    server_id: String,
    channel_id: String,
    file_path: String,
    message_id: String,
) -> Result<String, String> {
    let file_data =
        std::fs::read(&file_path).map_err(|e| format!("Failed to read file: {e}"))?;
    let original_size = file_data.len() as u64;

    let path = std::path::Path::new(&file_path);
    let file_name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("unknown")
        .to_string();
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();
    let mime_type = crate::vault::pipeline::mime_from_ext(&ext);

    let encrypted = crate::vault::pipeline::aes_encrypt(&file_data)
        .map_err(|e| format!("Encryption failed: {e}"))?;

    let content_id = crate::vault::content_store::content_id(&encrypted.ciphertext);

    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state
            .cmd_tx
            .send(node::NodeCommand::VaultUploadFile(Box::new(node::VaultUploadFilePayload {
                server_id,
                channel_id,
                file_name,
                mime_type,
                message_id,
                ciphertext: encrypted.ciphertext,
                aes_key: encrypted.key.to_vec(),
                aes_nonce: encrypted.nonce.to_vec(),
                original_size,
                content_id: content_id.clone(),
            }))),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(content_id)
}

/// Download a vault file. Checks local cache first, then attempts local reconstruction.
/// Returns the disk path if the file is available locally (cache hit or reconstructable
/// from local shards). Returns empty string if async network fetch is needed (Dart
/// watches VaultDownloadComplete event for the disk_path).
#[frb]
pub fn vault_download_file(server_id: String, content_id: String) -> Result<String, String> {
    let hollow_dir = crate::identity::data_dir()?;
    let db_path = hollow_dir.join("messages.db").to_str().ok_or("Invalid path")?.to_string();
    let passphrase = super::storage::derive_db_key_public()?;
    let vault_dir = hollow_dir.join("vault");

    if let Ok(cs) = crate::vault::content_store::ContentStore::open(&db_path, &passphrase, &vault_dir) {
        if let Ok(Some(manifest)) = cs.load_manifest(&content_id) {
            let ext = crate::vault::pipeline::ext_from_filename(&manifest.file_name);
            if let Some(cached_path) = crate::vault::pipeline::check_cache(&content_id, &ext) {
                return Ok(cached_path.to_string_lossy().to_string());
            }
        }
    }

    // Not in cache: the swarm reconstructs it.
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);

    let rt = get_runtime();
    rt.block_on(
        cmd_tx.send(node::NodeCommand::VaultDownloadFile {
            server_id,
            content_id,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(String::new()) // Async — Dart watches VaultDownloadComplete event
}


