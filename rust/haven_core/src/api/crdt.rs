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
}

/// Member info for FFI (Dart-visible).
pub struct MemberFfi {
    pub peer_id: String,
    pub display_name: String,
    pub role: String,
    pub nickname: String,
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
    let data_dir = dirs::data_dir().ok_or("Could not find app data directory")?;
    let haven_dir = data_dir.join("haven");
    let db_path = haven_dir
        .join("messages.db")
        .to_str()
        .ok_or("Invalid path")?
        .to_string();

    // Derive passphrase from identity (same as start_node)
    let id = crate::identity::load_or_create_identity()?;
    let proto = id
        .keypair
        .to_protobuf_encoding()
        .map_err(|e| format!("Failed to encode keypair: {e}"))?;
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);

    let store = crate::storage::MessageStore::open(&db_path, &passphrase)?;
    let servers = store.load_all_servers()?;

    let mut result = Vec::new();
    for (server_id, state_json) in servers {
        if let Ok(state) =
            serde_json::from_str::<crate::crdt::server_state::ServerState>(&state_json)
        {
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
    let data_dir = dirs::data_dir().ok_or("Could not find app data directory")?;
    let haven_dir = data_dir.join("haven");
    let db_path = haven_dir
        .join("messages.db")
        .to_str()
        .ok_or("Invalid path")?
        .to_string();

    let id = crate::identity::load_or_create_identity()?;
    let proto = id
        .keypair
        .to_protobuf_encoding()
        .map_err(|e| format!("Failed to encode keypair: {e}"))?;
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);

    let store = crate::storage::MessageStore::open(&db_path, &passphrase)?;
    let state_json = store
        .load_server_state(&server_id)?
        .ok_or(format!("Server {server_id} not found"))?;

    let state =
        serde_json::from_str::<crate::crdt::server_state::ServerState>(&state_json)
            .map_err(|e| format!("Failed to parse server state: {e}"))?;

    let channels = state
        .channels_list()
        .into_iter()
        .map(|ch| ChannelFfi {
            channel_id: ch.channel_id.clone(),
            name: ch.name.clone(),
            category: ch.category.clone(),
        })
        .collect();

    Ok(channels)
}

/// Get members for a specific server. Reads from the local DB.
#[frb]
pub fn get_server_members(server_id: String) -> Result<Vec<MemberFfi>, String> {
    let data_dir = dirs::data_dir().ok_or("Could not find app data directory")?;
    let haven_dir = data_dir.join("haven");
    let db_path = haven_dir
        .join("messages.db")
        .to_str()
        .ok_or("Invalid path")?
        .to_string();

    let id = crate::identity::load_or_create_identity()?;
    let proto = id
        .keypair
        .to_protobuf_encoding()
        .map_err(|e| format!("Failed to encode keypair: {e}"))?;
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);

    let store = crate::storage::MessageStore::open(&db_path, &passphrase)?;
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
        })
        .collect();

    Ok(members)
}

/// Get a server setting value by key. Returns empty string if not set.
#[frb]
pub fn get_server_setting(server_id: String, key: String) -> Result<String, String> {
    let data_dir = dirs::data_dir().ok_or("Could not find app data directory")?;
    let haven_dir = data_dir.join("haven");
    let db_path = haven_dir
        .join("messages.db")
        .to_str()
        .ok_or("Invalid path")?
        .to_string();

    let id = crate::identity::load_or_create_identity()?;
    let proto = id
        .keypair
        .to_protobuf_encoding()
        .map_err(|e| format!("Failed to encode keypair: {e}"))?;
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);

    let store = crate::storage::MessageStore::open(&db_path, &passphrase)?;
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

/// Join a server via invite link. Connects to the server's signaling room and
/// requests membership from existing members.
#[frb]
pub fn join_server(server_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state
            .cmd_tx
            .send(node::NodeCommand::JoinServer { server_id }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Get the local user's role in a server.
/// Returns "owner", "admin", "moderator", or "member".
#[frb]
pub fn get_my_role(server_id: String) -> Result<String, String> {
    let data_dir = dirs::data_dir().ok_or("Could not find app data directory")?;
    let haven_dir = data_dir.join("haven");
    let db_path = haven_dir
        .join("messages.db")
        .to_str()
        .ok_or("Invalid path")?
        .to_string();

    let id = crate::identity::load_or_create_identity()?;
    let proto = id
        .keypair
        .to_protobuf_encoding()
        .map_err(|e| format!("Failed to encode keypair: {e}"))?;
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);

    let store = crate::storage::MessageStore::open(&db_path, &passphrase)?;
    let state_json = store
        .load_server_state(&server_id)?
        .ok_or(format!("Server {server_id} not found"))?;

    let state =
        serde_json::from_str::<crate::crdt::server_state::ServerState>(&state_json)
            .map_err(|e| format!("Failed to parse server state: {e}"))?;

    let peer_id = id.peer_id.to_string();
    Ok(state.get_role(&peer_id).as_str().to_string())
}

/// Get the local user's permissions bitmask in a server.
#[frb]
pub fn get_my_permissions(server_id: String) -> Result<u32, String> {
    let data_dir = dirs::data_dir().ok_or("Could not find app data directory")?;
    let haven_dir = data_dir.join("haven");
    let db_path = haven_dir
        .join("messages.db")
        .to_str()
        .ok_or("Invalid path")?
        .to_string();

    let id = crate::identity::load_or_create_identity()?;
    let proto = id
        .keypair
        .to_protobuf_encoding()
        .map_err(|e| format!("Failed to encode keypair: {e}"))?;
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);

    let store = crate::storage::MessageStore::open(&db_path, &passphrase)?;
    let state_json = store
        .load_server_state(&server_id)?
        .ok_or(format!("Server {server_id} not found"))?;

    let state =
        serde_json::from_str::<crate::crdt::server_state::ServerState>(&state_json)
            .map_err(|e| format!("Failed to parse server state: {e}"))?;

    let peer_id = id.peer_id.to_string();
    Ok(state.get_permissions(&peer_id))
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
    let data_dir = dirs::data_dir().ok_or("Could not find app data directory")?;
    let haven_dir = data_dir.join("haven");
    let db_path = haven_dir
        .join("messages.db")
        .to_str()
        .ok_or("Invalid path")?
        .to_string();

    let id = crate::identity::load_or_create_identity()?;
    let proto = id
        .keypair
        .to_protobuf_encoding()
        .map_err(|e| format!("Failed to encode keypair: {e}"))?;
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);

    let store = crate::storage::MessageStore::open(&db_path, &passphrase)?;
    let state_json = store
        .load_server_state(&server_id)?
        .ok_or(format!("Server {server_id} not found"))?;

    let state =
        serde_json::from_str::<crate::crdt::server_state::ServerState>(&state_json)
            .map_err(|e| format!("Failed to parse server state: {e}"))?;

    serde_json::to_string(&state.channel_layout)
        .map_err(|e| format!("Failed to serialize layout: {e}"))
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
    let data_dir = dirs::data_dir().ok_or("Could not find app data directory")?;
    let haven_dir = data_dir.join("haven");
    let db_path = haven_dir
        .join("messages.db")
        .to_str()
        .ok_or("Invalid path")?
        .to_string();

    let id = crate::identity::load_or_create_identity()?;
    let proto = id
        .keypair
        .to_protobuf_encoding()
        .map_err(|e| format!("Failed to encode keypair: {e}"))?;
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);

    let store = crate::storage::MessageStore::open(&db_path, &passphrase)?;
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
    let data_dir = dirs::data_dir().ok_or("Could not find app data directory")?;
    let haven_dir = data_dir.join("haven");
    let db_path = haven_dir
        .join("messages.db")
        .to_str()
        .ok_or("Invalid path")?
        .to_string();

    let id = crate::identity::load_or_create_identity()?;
    let proto = id
        .keypair
        .to_protobuf_encoding()
        .map_err(|e| format!("Failed to encode keypair: {e}"))?;
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);

    // Load CRDT state for pledge data
    let store = crate::storage::MessageStore::open(&db_path, &passphrase)?;
    let state_json = store
        .load_server_state(&server_id)?
        .ok_or(format!("Server {server_id} not found"))?;

    let state =
        serde_json::from_str::<crate::crdt::server_state::ServerState>(&state_json)
            .map_err(|e| format!("Failed to parse server state: {e}"))?;

    let peer_id = id.peer_id.to_string();
    let total_pledged_bytes = state.total_pledged_bytes();
    let my_pledge_bytes = state.get_storage_pledge(&peer_id);
    let member_count = state.members.len() as u32;
    let min_pledge_mb = state.min_pledge_mb();

    // Load vault shard usage data
    let vault_dir = haven_dir.join("vault");
    let total_used_bytes = if let Ok(content_store) =
        crate::vault::content_store::ContentStore::open(&db_path, &passphrase, &vault_dir)
    {
        content_store.total_storage_used(&server_id).unwrap_or(0)
    } else {
        0
    };

    Ok(StorageStatsFfi {
        total_pledged_bytes,
        total_used_bytes,
        my_pledge_bytes,
        my_used_bytes: total_used_bytes,
        member_count,
        min_pledge_mb,
    })
}
