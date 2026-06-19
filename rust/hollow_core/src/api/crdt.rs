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

/// Channel info for FFI (Dart-visible).
pub struct ChannelFfi {
    pub channel_id: String,
    pub name: String,
    pub category: Option<String>,
    pub channel_type: String,
    pub visibility: String,
    pub posting: String,
    pub is_public: bool,
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

/// Label info for FFI (Dart-visible).
pub struct LabelFfi {
    pub label_id: String,
    pub name: String,
    pub color: String,
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

/// Create a channel in a server. Returns "pending" (actual channel_id comes via event).
#[frb]
pub fn create_channel(
    server_id: String,
    name: String,
    category: Option<String>,
    channel_type: String,
) -> Result<String, String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::CreateChannel {
            server_id,
            name,
            category,
            channel_type,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok("pending".to_string())
}

/// Remove a channel from a server.
#[frb]
pub fn remove_channel(server_id: String, channel_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::RemoveChannel {
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

    let mut result = Vec::new();
    for (server_id, state_json) in servers {
        if let Ok(state) =
            serde_json::from_str::<crate::crdt::server_state::ServerState>(&state_json)
        {
            // Hide tombstoned servers — the node retains the shell to serve the
            // deletion op to reconnecting peers, but the UI must not list it.
            if state.is_deleted() { continue; }
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

/// Get channels for a specific server. Reads from the local DB.
#[frb]
pub fn get_server_channels(server_id: String) -> Result<Vec<ChannelFfi>, String> {
    let store_guard = super::storage::get_store().lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let store = store_guard.as_ref().ok_or("Message store is not open")?;
    let state_json = store
        .load_server_state(&server_id)?
        .ok_or(format!("Server {server_id} not found"))?;

    let state =
        serde_json::from_str::<crate::crdt::server_state::ServerState>(&state_json)
            .map_err(|e| format!("Failed to parse server state: {e}"))?;

    let channels = state
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
                is_public: ch.is_public,
            }
        })
        .collect();

    Ok(channels)
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
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::RenameServer {
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
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::RenameChannel {
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
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::UpdateServerSetting {
            server_id,
            key,
            value,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Set a server avatar. Processes the raw image to 128x128 WebP and stores via CRDT.
#[frb]
pub fn set_server_avatar(server_id: String, raw_bytes: Vec<u8>) -> Result<(), String> {
    let processed = crate::node::image_convert::process_avatar_image(&raw_bytes)?;
    use base64::Engine;
    let b64 = base64::engine::general_purpose::STANDARD.encode(&processed);
    update_server_setting(server_id, "server_avatar".into(), b64)
}

/// Clear a server avatar.
#[frb]
pub fn clear_server_avatar(server_id: String) -> Result<(), String> {
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

/// Join a server via invite link. Connects to the server's signaling room and
/// requests membership from existing members.
#[frb]
pub fn join_server(server_id: String, twitch_proof_json: Option<String>) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state
            .cmd_tx
            .send(node::NodeCommand::JoinServer { server_id, twitch_proof_json }),
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
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::ChangeRole {
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
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::KickMember {
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
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::SetNickname {
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
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::SetTwitchUsername {
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
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::UpdateChannelLayout {
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
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::PinMessage {
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
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::UnpinMessage {
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
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::DeleteServer {
            server_id,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Create a new label (cosmetic role) in a server.
#[frb]
pub fn create_label(server_id: String, name: String, color: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;
    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::CreateLabel { server_id, name, color }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Delete a label from a server.
#[frb]
pub fn delete_label(server_id: String, label_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;
    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::DeleteLabel { server_id, label_id }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Update a label's name and color.
#[frb]
pub fn update_label(server_id: String, label_id: String, name: String, color: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;
    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::UpdateLabel { server_id, label_id, name, color }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Assign a label to a member.
#[frb]
pub fn assign_label(server_id: String, label_id: String, peer_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;
    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::AssignLabel { server_id, label_id, peer_id }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Remove a label from a member.
#[frb]
pub fn unassign_label(server_id: String, label_id: String, peer_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;
    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::UnassignLabel { server_id, label_id, peer_id }))
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
    }).collect())
}

/// Set the visibility mode for a channel (everyone/moderator/admin).
#[frb]
pub fn set_channel_visibility(server_id: String, channel_id: String, visibility: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::SetChannelVisibility {
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
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::SetChannelPosting {
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
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::SetChannelPublic {
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
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::RequestPublicChannels { server_id }),
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
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::RequestPublicChannelSync {
            server_id,
            channel_id,
            before_timestamp,
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
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::LeaveGuestRoom { server_id }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Ban a member from the server. Prevents rejoin.
#[frb]
pub fn ban_member(server_id: String, peer_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::BanMember {
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
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::UnbanMember {
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

/// Change the permissions bitmask for a role. Owner-only.
#[frb]
pub fn change_role_permissions(server_id: String, role: String, permissions: u32) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::ChangeRolePermissions {
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

/// Leave a server. The local user is removed from the server.
/// Owner cannot leave — must delete or transfer ownership first.
#[frb]
pub fn leave_server(server_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::LeaveServer {
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
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::SetStoragePledge {
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

    // Load storage usage.
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

    // Server Storage: use manifest total if vault has data, otherwise P2P file total.
    // Don't double-count (manifests already represent the file sizes).
    // Message text is always added on top (not part of vault manifests or P2P files).
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
    let state = guard.as_ref().ok_or("Node is not running")?;

    // Generate random 16-char hex token.
    let mut token_bytes = [0u8; 8];
    getrandom::fill(&mut token_bytes)
        .map_err(|e| format!("Failed to generate token: {e}"))?;
    let token = hex::encode(token_bytes);

    let invite_link = format!("hollow://recovery?server={}&token={}", server_id, token);

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::InitiateRecoveryPool {
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
    // Parse the invite link.
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
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::JoinRecoveryPool {
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
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::StopRecoveryPool {
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
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::DeleteVaultContent {
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
    // Read the file
    let file_data =
        std::fs::read(&file_path).map_err(|e| format!("Failed to read file: {e}"))?;
    let original_size = file_data.len() as u64;

    // Extract filename and mime type
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

    // AES-256-GCM encrypt
    let encrypted = crate::vault::pipeline::aes_encrypt(&file_data)
        .map_err(|e| format!("Encryption failed: {e}"))?;

    // Compute content_id
    let content_id = crate::vault::content_store::content_id(&encrypted.ciphertext);

    // Send to swarm handler
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

    // Try to load manifest and check cache
    if let Ok(cs) = crate::vault::content_store::ContentStore::open(&db_path, &passphrase, &vault_dir) {
        if let Ok(Some(manifest)) = cs.load_manifest(&content_id) {
            let ext = crate::vault::pipeline::ext_from_filename(&manifest.file_name);
            if let Some(cached_path) = crate::vault::pipeline::check_cache(&content_id, &ext) {
                return Ok(cached_path.to_string_lossy().to_string());
            }
        }
    }

    // Not in cache — send command to swarm for reconstruction
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::VaultDownloadFile {
            server_id,
            content_id,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(String::new()) // Async — Dart watches VaultDownloadComplete event
}


