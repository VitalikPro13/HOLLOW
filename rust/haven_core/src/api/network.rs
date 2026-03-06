use std::sync::{Mutex, OnceLock};

use flutter_rust_bridge::frb;
use libp2p::PeerId;
use tokio::sync::mpsc;

use crate::crypto::{CryptoStore, OlmManager};
use crate::frb_generated::StreamSink;
use crate::identity;
use crate::node;
use crate::storage::MessageStore;

/// A discovered peer on the local network.
pub struct DiscoveredPeer {
    pub peer_id: String,
    pub addresses: Vec<String>,
}

/// Events emitted by the network node.
pub enum NetworkEvent {
    PeerDiscovered { peer: DiscoveredPeer },
    PeerExpired { peer_id: String },
    PeerDisconnected { peer_id: String },
    RoomCleared,
    Listening { address: String },
    MessageReceived { from_peer: String, text: String },
    ChannelMessageReceived { server_id: String, channel_id: String, from_peer: String, text: String, timestamp: i64 },
    MessageSent { to_peer: String },
    MessageSendFailed { to_peer: String, error: String },
    SessionEstablished { peer_id: String },
    Error { message: String },
    // -- CRDT events (Phase 3) --
    ServerCreated { server_id: String, name: String },
    ServerUpdated { server_id: String },
    ChannelAdded { server_id: String, channel_id: String, name: String },
    ChannelRemoved { server_id: String, channel_id: String },
    ChannelRenamed { server_id: String, channel_id: String, new_name: String },
    ServerDeleted { server_id: String },
    MemberJoined { server_id: String, peer_id: String },
    MemberLeft { server_id: String, peer_id: String },
    SyncCompleted { server_id: String, ops_applied: u32 },
    ServerJoined { server_id: String, name: String },
    MessageSyncStarted { server_id: String, peer_id: String },
    MessageSyncCompleted { server_id: String, new_message_count: u32 },
    MessageSyncFailed { server_id: String, error: String },
}

/// Holds all mutable state for the running node.
pub(crate) struct NodeState {
    pub(crate) local_peer_id: String,
    pub(crate) cmd_tx: mpsc::Sender<node::NodeCommand>,
    handle: tokio::task::JoinHandle<()>,
    olm_fingerprint: String,
}

// The node state: None = not running, Some = running.
static NODE: OnceLock<Mutex<Option<NodeState>>> = OnceLock::new();
static TOKIO_RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();

// Event receiver — stored separately so watch_network_events() can take ownership.
static EVENT_RX: OnceLock<Mutex<Option<mpsc::Receiver<node::NetworkEvent>>>> = OnceLock::new();

fn get_event_rx() -> &'static Mutex<Option<mpsc::Receiver<node::NetworkEvent>>> {
    EVENT_RX.get_or_init(|| Mutex::new(None))
}

pub(crate) fn get_node() -> &'static Mutex<Option<NodeState>> {
    NODE.get_or_init(|| Mutex::new(None))
}

pub(crate) fn get_runtime() -> &'static tokio::runtime::Runtime {
    TOKIO_RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("Failed to create tokio runtime")
    })
}

/// Convert internal event to FFI event. Also logs Error events to the debug log file.
fn to_ffi_event(event: node::NetworkEvent) -> NetworkEvent {
    // Log all events to the debug log file so release builds have diagnostics.
    match &event {
        node::NetworkEvent::Error { message } => haven_log!("[HAVEN] {message}"),
        node::NetworkEvent::PeerDiscovered { peer } => {
            haven_log!("[HAVEN] Peer discovered: {} at {:?}", peer.peer_id, peer.addresses);
        }
        node::NetworkEvent::PeerDisconnected { peer_id } => {
            haven_log!("[HAVEN] Peer disconnected: {peer_id}");
        }
        node::NetworkEvent::Listening { address } => {
            haven_log!("[HAVEN] Listening: {address}");
        }
        node::NetworkEvent::SessionEstablished { peer_id } => {
            haven_log!("[HAVEN] Session established: {peer_id}");
        }
        node::NetworkEvent::MessageReceived { from_peer, .. } => {
            haven_log!("[HAVEN] Message received from: {from_peer}");
        }
        node::NetworkEvent::ChannelMessageReceived { server_id, channel_id, from_peer, .. } => {
            haven_log!("[HAVEN] Channel message from {from_peer} in {channel_id} ({server_id})");
        }
        node::NetworkEvent::MessageSent { to_peer } => {
            haven_log!("[HAVEN] Message sent to: {to_peer}");
        }
        node::NetworkEvent::MessageSendFailed { to_peer, error } => {
            haven_log!("[HAVEN] Message send failed to {to_peer}: {error}");
        }
        node::NetworkEvent::ServerCreated { server_id, name } => {
            haven_log!("[HAVEN] Server created: {name} ({server_id})");
        }
        node::NetworkEvent::ServerUpdated { server_id } => {
            haven_log!("[HAVEN] Server updated: {server_id}");
        }
        node::NetworkEvent::ChannelAdded { server_id, channel_id, name } => {
            haven_log!("[HAVEN] Channel added: {name} ({channel_id}) in {server_id}");
        }
        node::NetworkEvent::ChannelRemoved { server_id, channel_id } => {
            haven_log!("[HAVEN] Channel removed: {channel_id} in {server_id}");
        }
        node::NetworkEvent::ChannelRenamed { server_id, channel_id, new_name } => {
            haven_log!("[HAVEN] Channel renamed: {channel_id} to '{new_name}' in {server_id}");
        }
        node::NetworkEvent::ServerDeleted { server_id } => {
            haven_log!("[HAVEN] Server deleted: {server_id}");
        }
        node::NetworkEvent::MemberJoined { server_id, peer_id } => {
            haven_log!("[HAVEN] Member joined: {peer_id} in {server_id}");
        }
        node::NetworkEvent::MemberLeft { server_id, peer_id } => {
            haven_log!("[HAVEN] Member left: {peer_id} in {server_id}");
        }
        node::NetworkEvent::SyncCompleted { server_id, ops_applied } => {
            haven_log!("[HAVEN] Sync completed for {server_id}: {ops_applied} ops applied");
        }
        node::NetworkEvent::ServerJoined { server_id, name } => {
            haven_log!("[HAVEN] Server joined: {name} ({server_id})");
        }
        node::NetworkEvent::MessageSyncStarted { server_id, peer_id } => {
            haven_log!("[HAVEN] Message sync started for {server_id} with {peer_id}");
        }
        node::NetworkEvent::MessageSyncCompleted { server_id, new_message_count } => {
            haven_log!("[HAVEN] Message sync completed for {server_id}: {new_message_count} new messages");
        }
        node::NetworkEvent::MessageSyncFailed { server_id, error } => {
            haven_log!("[HAVEN] Message sync failed for {server_id}: {error}");
        }
        _ => {}
    }
    match event {
        node::NetworkEvent::PeerDiscovered { peer } => NetworkEvent::PeerDiscovered {
            peer: DiscoveredPeer {
                peer_id: peer.peer_id,
                addresses: peer.addresses,
            },
        },
        node::NetworkEvent::PeerExpired { peer_id } => NetworkEvent::PeerExpired { peer_id },
        node::NetworkEvent::PeerDisconnected { peer_id } => {
            NetworkEvent::PeerDisconnected { peer_id }
        }
        node::NetworkEvent::RoomCleared => NetworkEvent::RoomCleared,
        node::NetworkEvent::Listening { address } => NetworkEvent::Listening { address },
        node::NetworkEvent::MessageReceived { from_peer, text } => {
            NetworkEvent::MessageReceived { from_peer, text }
        }
        node::NetworkEvent::ChannelMessageReceived { server_id, channel_id, from_peer, text, timestamp } => {
            NetworkEvent::ChannelMessageReceived { server_id, channel_id, from_peer, text, timestamp }
        }
        node::NetworkEvent::MessageSent { to_peer } => NetworkEvent::MessageSent { to_peer },
        node::NetworkEvent::MessageSendFailed { to_peer, error } => {
            NetworkEvent::MessageSendFailed { to_peer, error }
        }
        node::NetworkEvent::SessionEstablished { peer_id } => {
            NetworkEvent::SessionEstablished { peer_id }
        }
        node::NetworkEvent::Error { message } => NetworkEvent::Error { message },
        node::NetworkEvent::ServerCreated { server_id, name } => {
            NetworkEvent::ServerCreated { server_id, name }
        }
        node::NetworkEvent::ServerUpdated { server_id } => {
            NetworkEvent::ServerUpdated { server_id }
        }
        node::NetworkEvent::ChannelAdded { server_id, channel_id, name } => {
            NetworkEvent::ChannelAdded { server_id, channel_id, name }
        }
        node::NetworkEvent::ChannelRemoved { server_id, channel_id } => {
            NetworkEvent::ChannelRemoved { server_id, channel_id }
        }
        node::NetworkEvent::ChannelRenamed { server_id, channel_id, new_name } => {
            NetworkEvent::ChannelRenamed { server_id, channel_id, new_name }
        }
        node::NetworkEvent::ServerDeleted { server_id } => {
            NetworkEvent::ServerDeleted { server_id }
        }
        node::NetworkEvent::MemberJoined { server_id, peer_id } => {
            NetworkEvent::MemberJoined { server_id, peer_id }
        }
        node::NetworkEvent::MemberLeft { server_id, peer_id } => {
            NetworkEvent::MemberLeft { server_id, peer_id }
        }
        node::NetworkEvent::SyncCompleted { server_id, ops_applied } => {
            NetworkEvent::SyncCompleted { server_id, ops_applied }
        }
        node::NetworkEvent::ServerJoined { server_id, name } => {
            NetworkEvent::ServerJoined { server_id, name }
        }
        node::NetworkEvent::MessageSyncStarted { server_id, peer_id } => {
            NetworkEvent::MessageSyncStarted { server_id, peer_id }
        }
        node::NetworkEvent::MessageSyncCompleted { server_id, new_message_count } => {
            NetworkEvent::MessageSyncCompleted { server_id, new_message_count }
        }
        node::NetworkEvent::MessageSyncFailed { server_id, error } => {
            NetworkEvent::MessageSyncFailed { server_id, error }
        }
    }
}

/// Start the libp2p node with mDNS peer discovery and E2EE.
/// Uses the persistent identity from disk.
/// Returns the local peer ID as a string.
#[frb]
pub fn start_node() -> Result<String, String> {
    let node = get_node();
    let mut guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;

    if guard.is_some() {
        return Err("Node is already running".to_string());
    }

    // Initialize debug log file (writes next to executable, works in release builds).
    crate::log::init();
    haven_log!("[HAVEN] === Node starting ===");

    // Load the persistent identity (or create one if first run).
    let id = identity::load_or_create_identity()?;

    // Derive the DB encryption key (same as storage module).
    let proto = id
        .keypair
        .to_protobuf_encoding()
        .map_err(|e| format!("Failed to encode keypair: {e}"))?;
    let key_bytes = &proto[..32.min(proto.len())];
    let passphrase = hex::encode(key_bytes);

    // Get DB path.
    let data_dir = dirs::data_dir().ok_or("Could not find app data directory")?;
    let haven_dir = data_dir.join("haven");
    std::fs::create_dir_all(&haven_dir)
        .map_err(|e| format!("Failed to create data dir: {e}"))?;
    let db_path = haven_dir
        .join("messages.db")
        .to_str()
        .ok_or("Invalid path encoding")?
        .to_string();

    // Load Olm state from DB (synchronous, on FFI thread).
    let olm = {
        let store = MessageStore::open(&db_path, &passphrase)?;
        match store.load_olm_account()? {
            Some(account_json) => {
                let sessions = store.load_all_olm_sessions()?;
                OlmManager::from_pickles(&account_json, sessions)?
            }
            None => {
                // First time — create fresh Olm account and persist it.
                let mgr = OlmManager::new();
                let pickle = mgr.account_pickle_json()?;
                store.save_olm_account(&pickle)?;
                mgr
            }
        }
    };

    // Extract fingerprint before moving OlmManager into the swarm task.
    let olm_fingerprint = olm.identity_key_base64();

    // Open the CryptoStore persistence actor (runs in its own blocking thread).
    let rt = get_runtime();
    let crypto_store = rt.block_on(async {
        CryptoStore::open(db_path, passphrase)
    })?;

    let (event_tx, event_rx) = mpsc::channel::<node::NetworkEvent>(100);
    let (cmd_tx, cmd_rx) = mpsc::channel::<node::NodeCommand>(100);

    let (peer_id_str, handle) = rt
        .block_on(node::spawn_node(id.keypair, event_tx, cmd_rx, olm, crypto_store))
        .map_err(|e| format!("Failed to start node: {e}"))?;

    // Store event receiver separately so watch_network_events() can take it.
    *get_event_rx().lock().map_err(|e| format!("Lock poisoned: {e}"))? = Some(event_rx);

    *guard = Some(NodeState {
        local_peer_id: peer_id_str.clone(),
        cmd_tx,
        handle,
        olm_fingerprint,
    });

    Ok(peer_id_str)
}

/// Stream network events to Dart in real time.
/// Must be called after `start_node()`. Can only be called once per node lifetime.
#[frb]
pub fn watch_network_events(sink: StreamSink<NetworkEvent>) -> Result<(), String> {
    let rx = get_event_rx()
        .lock()
        .map_err(|e| format!("Lock poisoned: {e}"))?
        .take()
        .ok_or("No event receiver available (node not started or stream already active)")?;

    let rt = get_runtime();
    rt.spawn(async move {
        event_forwarding_task(rx, sink).await;
    });

    Ok(())
}

async fn event_forwarding_task(
    mut rx: mpsc::Receiver<node::NetworkEvent>,
    sink: StreamSink<NetworkEvent>,
) {
    while let Some(event) = rx.recv().await {
        let ffi_event = to_ffi_event(event);
        if sink.add(ffi_event).is_err() {
            haven_log!("[HAVEN] Event stream sink closed, stopping forwarding");
            break;
        }
    }
    haven_log!("[HAVEN] Event channel closed, stream ending");
}

/// Poll for the next network event. Returns None if no event is available.
/// Fallback for when streaming is not active.
#[frb]
pub fn poll_network_event() -> Option<NetworkEvent> {
    let rx_lock = get_event_rx();
    let mut guard = rx_lock.lock().ok()?;
    let rx = guard.as_mut()?;
    rx.try_recv().ok().map(to_ffi_event)
}

/// Get the local peer ID. Returns None if the node hasn't started.
#[frb]
pub fn get_local_peer_id() -> Option<String> {
    let node = get_node();
    let guard = node.lock().ok()?;
    guard.as_ref().map(|s| s.local_peer_id.clone())
}

/// Get the Olm identity fingerprint (Curve25519 base64).
/// Returns None if the node hasn't started.
#[frb]
pub fn get_olm_fingerprint() -> Option<String> {
    let node = get_node();
    let guard = node.lock().ok()?;
    guard.as_ref().map(|s| s.olm_fingerprint.clone())
}

/// Send a text message to a peer. The peer must be reachable (discovered via mDNS).
#[frb]
pub fn send_message(peer_id: String, text: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;

    let state = guard.as_ref().ok_or("Node is not running")?;

    let peer: PeerId = peer_id
        .parse()
        .map_err(|e| format!("Invalid peer ID: {e}"))?;

    let rt = get_runtime();
    rt.block_on(
        state
            .cmd_tx
            .send(node::NodeCommand::SendMessage { peer_id: peer, text }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Send a text message to a server channel.
/// The message will be encrypted and sent to all connected server members.
#[frb]
pub fn send_channel_message(
    server_id: String,
    channel_id: String,
    text: String,
) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::SendChannelMessage {
            server_id,
            channel_id,
            text,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Request message sync for a specific channel from all connected server members.
/// Called when the user opens a channel to catch up on missed messages.
#[frb]
pub fn request_channel_sync(server_id: String, channel_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::RequestChannelSync {
            server_id,
            channel_id,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Notify all connected peers that we're shutting down gracefully.
/// Call this before closing the app so peers can immediately update their state.
#[frb]
pub fn notify_shutdown() -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::NotifyShutdown),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Join a room via the signaling service.
/// Registers our addresses and bootstraps from other peers in the room.
#[frb]
pub fn join_room(room_code: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;

    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state
            .cmd_tx
            .send(node::NodeCommand::JoinRoom { room_code }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Stop the running node.
#[frb]
pub fn stop_node() -> Result<(), String> {
    let node = get_node();
    let mut guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;

    // Clear any unconsumed event receiver.
    if let Ok(mut rx_guard) = get_event_rx().lock() {
        *rx_guard = None;
    }

    match guard.take() {
        Some(state) => {
            state.handle.abort();
            Ok(())
        }
        None => Err("Node is not running".to_string()),
    }
}
