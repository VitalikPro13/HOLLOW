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
        })
        .collect();

    Ok(members)
}
