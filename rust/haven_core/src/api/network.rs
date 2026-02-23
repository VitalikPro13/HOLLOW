use std::sync::{Mutex, OnceLock};

use flutter_rust_bridge::frb;
use libp2p::PeerId;
use tokio::sync::mpsc;

use crate::identity;
use crate::node;

/// A discovered peer on the local network.
pub struct DiscoveredPeer {
    pub peer_id: String,
    pub addresses: Vec<String>,
}

/// Events emitted by the network node.
pub enum NetworkEvent {
    PeerDiscovered { peer: DiscoveredPeer },
    PeerExpired { peer_id: String },
    Listening { address: String },
    MessageReceived { from_peer: String, text: String },
    MessageSent { to_peer: String },
    MessageSendFailed { to_peer: String, error: String },
    Error { message: String },
}

/// Holds all mutable state for the running node.
struct NodeState {
    local_peer_id: String,
    event_rx: mpsc::Receiver<node::NetworkEvent>,
    cmd_tx: mpsc::Sender<node::NodeCommand>,
    handle: tokio::task::JoinHandle<()>,
}

// The node state: None = not running, Some = running.
static NODE: OnceLock<Mutex<Option<NodeState>>> = OnceLock::new();
static TOKIO_RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();

fn get_node() -> &'static Mutex<Option<NodeState>> {
    NODE.get_or_init(|| Mutex::new(None))
}

fn get_runtime() -> &'static tokio::runtime::Runtime {
    TOKIO_RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("Failed to create tokio runtime")
    })
}

/// Convert internal event to FFI event.
fn to_ffi_event(event: node::NetworkEvent) -> NetworkEvent {
    match event {
        node::NetworkEvent::PeerDiscovered { peer } => NetworkEvent::PeerDiscovered {
            peer: DiscoveredPeer {
                peer_id: peer.peer_id,
                addresses: peer.addresses,
            },
        },
        node::NetworkEvent::PeerExpired { peer_id } => NetworkEvent::PeerExpired { peer_id },
        node::NetworkEvent::Listening { address } => NetworkEvent::Listening { address },
        node::NetworkEvent::MessageReceived { from_peer, text } => {
            NetworkEvent::MessageReceived { from_peer, text }
        }
        node::NetworkEvent::MessageSent { to_peer } => NetworkEvent::MessageSent { to_peer },
        node::NetworkEvent::MessageSendFailed { to_peer, error } => {
            NetworkEvent::MessageSendFailed { to_peer, error }
        }
        node::NetworkEvent::Error { message } => NetworkEvent::Error { message },
    }
}

/// Start the libp2p node with mDNS peer discovery.
/// Uses the persistent identity from disk.
/// Returns the local peer ID as a string.
#[frb]
pub fn start_node() -> Result<String, String> {
    let node = get_node();
    let mut guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;

    if guard.is_some() {
        return Err("Node is already running".to_string());
    }

    // Load the persistent identity (or create one if first run).
    let id = identity::load_or_create_identity()?;

    let (event_tx, event_rx) = mpsc::channel::<node::NetworkEvent>(100);
    let (cmd_tx, cmd_rx) = mpsc::channel::<node::NodeCommand>(100);
    let rt = get_runtime();

    let (peer_id_str, handle) = rt
        .block_on(node::spawn_node(id.keypair, event_tx, cmd_rx))
        .map_err(|e| format!("Failed to start node: {e}"))?;

    *guard = Some(NodeState {
        local_peer_id: peer_id_str.clone(),
        event_rx,
        cmd_tx,
        handle,
    });

    Ok(peer_id_str)
}

/// Poll for the next network event. Returns None if no event is available.
#[frb]
pub fn poll_network_event() -> Option<NetworkEvent> {
    let node = get_node();
    let mut guard = node.lock().ok()?;
    let state = guard.as_mut()?;
    state.event_rx.try_recv().ok().map(to_ffi_event)
}

/// Get the local peer ID. Returns None if the node hasn't started.
#[frb]
pub fn get_local_peer_id() -> Option<String> {
    let node = get_node();
    let guard = node.lock().ok()?;
    guard.as_ref().map(|s| s.local_peer_id.clone())
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

/// Stop the running node.
#[frb]
pub fn stop_node() -> Result<(), String> {
    let node = get_node();
    let mut guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;

    match guard.take() {
        Some(state) => {
            state.handle.abort();
            Ok(())
        }
        None => Err("Node is not running".to_string()),
    }
}
