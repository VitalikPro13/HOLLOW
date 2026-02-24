use std::sync::{Mutex, OnceLock};

use flutter_rust_bridge::frb;
use libp2p::PeerId;
use tokio::sync::mpsc;

use crate::crypto::{CryptoStore, OlmManager};
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
    Listening { address: String },
    MessageReceived { from_peer: String, text: String },
    MessageSent { to_peer: String },
    MessageSendFailed { to_peer: String, error: String },
    SessionEstablished { peer_id: String },
    Error { message: String },
}

/// Holds all mutable state for the running node.
struct NodeState {
    local_peer_id: String,
    event_rx: mpsc::Receiver<node::NetworkEvent>,
    cmd_tx: mpsc::Sender<node::NodeCommand>,
    handle: tokio::task::JoinHandle<()>,
    olm_fingerprint: String,
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
        node::NetworkEvent::SessionEstablished { peer_id } => {
            NetworkEvent::SessionEstablished { peer_id }
        }
        node::NetworkEvent::Error { message } => NetworkEvent::Error { message },
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

    *guard = Some(NodeState {
        local_peer_id: peer_id_str.clone(),
        event_rx,
        cmd_tx,
        handle,
        olm_fingerprint,
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

    match guard.take() {
        Some(state) => {
            state.handle.abort();
            Ok(())
        }
        None => Err("Node is not running".to_string()),
    }
}
