use std::sync::{Mutex, OnceLock};

use flutter_rust_bridge::frb;
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
    MessageReceived { from_peer: String, text: String, timestamp: i64, message_id: String, reply_to_mid: String },
    ChannelMessageReceived { server_id: String, channel_id: String, from_peer: String, text: String, timestamp: i64, message_id: String, reply_to_mid: String },
    MessageSent { to_peer: String },
    MessageSendFailed { to_peer: String, error: String },
    SessionEstablished { peer_id: String },
    Error { message: String },
    // -- CRDT events (Phase 3) --
    ServerCreated { server_id: String, name: String },
    ServerUpdated { server_id: String },
    ChannelAdded { server_id: String, channel_id: String, name: String, channel_type: String },
    ChannelRemoved { server_id: String, channel_id: String },
    ChannelRenamed { server_id: String, channel_id: String, new_name: String },
    ServerDeleted { server_id: String },
    MemberJoined { server_id: String, peer_id: String },
    MemberLeft { server_id: String, peer_id: String },
    SyncCompleted { server_id: String, ops_applied: u32 },
    ServerJoined { server_id: String, name: String },
    ServerJoinFailed { server_id: String, reason: String },
    MessageSyncStarted { server_id: String, peer_id: String },
    MessageSyncCompleted { server_id: String, new_message_count: u32 },
    MessageSyncFailed { server_id: String, error: String },
    MessageSyncProgress { server_id: String, channel_id: String, received_count: u32, total_count: u32 },
    RoleChanged { server_id: String, peer_id: String, new_role: String },
    DmSyncCompleted { peer_id: String, new_message_count: u32 },
    // -- Profile events (Phase 3.5) --
    ProfileUpdated { peer_id: String },
    // -- Message editing events (Phase 3.5) --
    ChannelMessageEdited { server_id: String, channel_id: String, message_id: String, new_text: String, edited_at: i64 },
    DmMessageEdited { peer_id: String, message_id: String, new_text: String, edited_at: i64 },
    // -- Message deletion events (Phase 3.5) --
    ChannelMessageDeleted { server_id: String, channel_id: String, message_id: String, deleted_at: i64 },
    DmMessageDeleted { peer_id: String, message_id: String, deleted_at: i64 },
    // -- Emoji reaction events (Phase 3.5) --
    ChannelReactionAdded { server_id: String, channel_id: String, message_id: String, emoji: String, reactor: String, added_at: i64 },
    DmReactionAdded { peer_id: String, message_id: String, emoji: String, reactor: String, added_at: i64 },
    ChannelReactionRemoved { server_id: String, channel_id: String, message_id: String, emoji: String, reactor: String, removed_at: i64 },
    DmReactionRemoved { peer_id: String, message_id: String, emoji: String, reactor: String, removed_at: i64 },
    // -- Friend events (Phase 3.5) --
    FriendRequestReceived { peer_id: String },
    FriendRequestAccepted { peer_id: String },
    FriendRequestRejected { peer_id: String },
    FriendRemoved { peer_id: String },
    // -- Typing indicator events (Phase 3.5) --
    TypingStarted { peer_id: String, server_id: String, channel_id: String },
    // -- Pinned message events (Phase 3.5) --
    MessagePinned { server_id: String, channel_id: String, message_id: String },
    MessageUnpinned { server_id: String, channel_id: String, message_id: String },
    // -- File transfer events (Phase 3.5) --
    FileHeaderReceived {
        file_id: String,
        file_name: String,
        size_bytes: u64,
        is_image: bool,
        width: Option<u32>,
        height: Option<u32>,
        message_id: String,
        sender_id: String,
        server_id: String,
        channel_id: String,
    },
    FileProgress {
        file_id: String,
        chunks_received: u32,
        total_chunks: u32,
    },
    FileCompleted {
        file_id: String,
        disk_path: String,
    },
    FileFailed {
        file_id: String,
        error: String,
    },
    // -- Vault shard events (Phase 4) --
    ShardStored { server_id: String, content_id: String, shard_index: u16, from_peer: String },
    ShardStoreAckReceived { server_id: String, content_id: String, shard_index: u16, success: bool, error: String },
    ShardStoreFailed { server_id: String, content_id: String, shard_index: u16, target_peer: String, error: String },
    ShardDeleted { server_id: String, content_id: String },
    ShardReceived { server_id: String, content_id: String, shard_index: u16, from_peer: String },
    ShardRequestFailed { server_id: String, content_id: String, shard_index: u16, error: String },
    // -- Vault upload pipeline events (Phase 4) --
    VaultUploadProgress { server_id: String, content_id: String, phase: String, progress: f32 },
    VaultUploadComplete { server_id: String, content_id: String, channel_id: String },
    VaultUploadFailed { server_id: String, content_id: String, error: String },
    // -- Vault download pipeline events (Phase 4) --
    VaultDownloadProgress { server_id: String, content_id: String, phase: String, progress: f32 },
    VaultDownloadComplete { server_id: String, content_id: String, disk_path: String },
    VaultDownloadFailed { server_id: String, content_id: String, error: String },
    // -- Vault rebalancing events (Phase 4) --
    RebalanceStarted { server_id: String, shards_to_move: u32 },
    RebalanceProgress { server_id: String, moved: u32, total: u32 },
    RebalanceCompleted { server_id: String },
    // -- Vault guard events --
    VaultUploadReplicationFallback { server_id: String, content_id: String, online: usize, needed: usize },
    // -- Connection status events --
    KeyExchangeStarted { peer_id: String },
    KeyExchangeProgress { peer_id: String, stage: String },
    // -- WebRTC events (Phase 5A) --
    /// Forward incoming WebRTC signaling message to Dart.
    WebRtcSignal { peer_id: String, signal_type: String, payload: String, conn_id: String },
    /// Tell Dart to send a file over WebRTC data channel.
    WebRtcSendFile { peer_id: String, transfer_id: String, file_path: String, total_size: u64, kind: String, shard_index: u16 },
    // -- Voice call events (Phase 5B) --
    /// Forward incoming voice call signaling message to Dart.
    CallSignal { peer_id: String, signal_type: String, payload: String },
    // -- Voice channel events (Phase 5C) --
    VoiceChannelJoined { server_id: String, channel_id: String, peer_id: String },
    VoiceChannelLeft { server_id: String, channel_id: String, peer_id: String },
    VoiceChannelSignal { server_id: String, channel_id: String, peer_id: String, signal_type: String, payload: String },
    // -- Gossip relay tree events (Phase 5D) --
    GossipConnect { peer_id: String },
    GossipDisconnect { peer_id: String },
    GossipRelayFile {
        broadcast_id: String,
        ttl: u8,
        origin_peer_id: String,
        file_path: String,
        total_size: u64,
        kind: String,
        shard_index: u16,
        exclude_peer_id: String,
        server_id: String,
        channel_id: String,
    },
    VoiceChannelModeChanged {
        server_id: String,
        channel_id: String,
        mode: String,
        gossip_neighbors: Vec<String>,
    },
    /// MLS epoch changed — SFrame key for voice E2EE.
    MlsEpochChanged {
        server_id: String,
        epoch: u64,
        sframe_key: Vec<u8>,
    },
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
        node::NetworkEvent::Error { message } => hollow_log!("[HOLLOW] {message}"),
        node::NetworkEvent::PeerDiscovered { peer } => {
            hollow_log!("[HOLLOW] Peer discovered: {} at {:?}", peer.peer_id, peer.addresses);
        }
        node::NetworkEvent::PeerDisconnected { peer_id } => {
            hollow_log!("[HOLLOW] Peer disconnected: {peer_id}");
        }
        node::NetworkEvent::Listening { address } => {
            hollow_log!("[HOLLOW] Listening: {address}");
        }
        node::NetworkEvent::SessionEstablished { peer_id } => {
            hollow_log!("[HOLLOW] Session established: {peer_id}");
        }
        node::NetworkEvent::MessageReceived { from_peer, .. } => {
            hollow_log!("[HOLLOW] Message received from: {from_peer}");
        }
        node::NetworkEvent::ChannelMessageReceived { server_id, channel_id, from_peer, .. } => {
            hollow_log!("[HOLLOW] Channel message from {from_peer} in {channel_id} ({server_id})");
        }
        node::NetworkEvent::MessageSent { to_peer } => {
            hollow_log!("[HOLLOW] Message sent to: {to_peer}");
        }
        node::NetworkEvent::MessageSendFailed { to_peer, error } => {
            hollow_log!("[HOLLOW] Message send failed to {to_peer}: {error}");
        }
        node::NetworkEvent::ServerCreated { server_id, name } => {
            hollow_log!("[HOLLOW] Server created: {name} ({server_id})");
        }
        node::NetworkEvent::ServerUpdated { server_id } => {
            hollow_log!("[HOLLOW] Server updated: {server_id}");
        }
        node::NetworkEvent::ChannelAdded { server_id, channel_id, name, .. } => {
            hollow_log!("[HOLLOW] Channel added: {name} ({channel_id}) in {server_id}");
        }
        node::NetworkEvent::ChannelRemoved { server_id, channel_id } => {
            hollow_log!("[HOLLOW] Channel removed: {channel_id} in {server_id}");
        }
        node::NetworkEvent::ChannelRenamed { server_id, channel_id, new_name } => {
            hollow_log!("[HOLLOW] Channel renamed: {channel_id} to '{new_name}' in {server_id}");
        }
        node::NetworkEvent::ServerDeleted { server_id } => {
            hollow_log!("[HOLLOW] Server deleted: {server_id}");
        }
        node::NetworkEvent::MemberJoined { server_id, peer_id } => {
            hollow_log!("[HOLLOW] Member joined: {peer_id} in {server_id}");
        }
        node::NetworkEvent::MemberLeft { server_id, peer_id } => {
            hollow_log!("[HOLLOW] Member left: {peer_id} in {server_id}");
        }
        node::NetworkEvent::SyncCompleted { server_id, ops_applied } => {
            hollow_log!("[HOLLOW] Sync completed for {server_id}: {ops_applied} ops applied");
        }
        node::NetworkEvent::ServerJoined { server_id, name } => {
            hollow_log!("[HOLLOW] Server joined: {name} ({server_id})");
        }
        node::NetworkEvent::ServerJoinFailed { server_id, reason } => {
            hollow_log!("[HOLLOW] Server join failed: {server_id} — {reason}");
        }
        node::NetworkEvent::MessageSyncStarted { server_id, peer_id } => {
            hollow_log!("[HOLLOW] Message sync started for {server_id} with {peer_id}");
        }
        node::NetworkEvent::MessageSyncCompleted { server_id, new_message_count } => {
            hollow_log!("[HOLLOW] Message sync completed for {server_id}: {new_message_count} new messages");
        }
        node::NetworkEvent::MessageSyncFailed { server_id, error } => {
            hollow_log!("[HOLLOW] Message sync failed for {server_id}: {error}");
        }
        node::NetworkEvent::MessageSyncProgress { server_id, channel_id, received_count, total_count } => {
            hollow_log!("[HOLLOW] Sync progress for {channel_id} in {server_id}: {received_count}/{total_count}");
        }
        node::NetworkEvent::RoleChanged { server_id, peer_id, new_role } => {
            hollow_log!("[HOLLOW] Role changed: {peer_id} is now {new_role} in {server_id}");
        }
        node::NetworkEvent::DmSyncCompleted { peer_id, new_message_count } => {
            hollow_log!("[HOLLOW] DM sync completed for {peer_id}: {new_message_count} new messages");
        }
        node::NetworkEvent::ProfileUpdated { peer_id } => {
            hollow_log!("[HOLLOW] Profile updated for {peer_id}");
        }
        node::NetworkEvent::ChannelMessageEdited { server_id, channel_id, message_id, .. } => {
            hollow_log!("[HOLLOW] Channel message {message_id} edited in {server_id}/{channel_id}");
        }
        node::NetworkEvent::DmMessageEdited { peer_id, message_id, .. } => {
            hollow_log!("[HOLLOW] DM message {message_id} edited for {peer_id}");
        }
        node::NetworkEvent::ChannelMessageDeleted { server_id, channel_id, message_id, .. } => {
            hollow_log!("[HOLLOW] Channel message {message_id} deleted in {server_id}/{channel_id}");
        }
        node::NetworkEvent::DmMessageDeleted { peer_id, message_id, .. } => {
            hollow_log!("[HOLLOW] DM message {message_id} deleted for {peer_id}");
        }
        node::NetworkEvent::ChannelReactionAdded { server_id, channel_id, message_id, emoji, reactor, .. } => {
            hollow_log!("[HOLLOW] Reaction {emoji} added on {message_id} by {reactor} in {server_id}/{channel_id}");
        }
        node::NetworkEvent::DmReactionAdded { peer_id, message_id, emoji, reactor, .. } => {
            hollow_log!("[HOLLOW] Reaction {emoji} added on DM {message_id} by {reactor} for {peer_id}");
        }
        node::NetworkEvent::ChannelReactionRemoved { server_id, channel_id, message_id, emoji, reactor, .. } => {
            hollow_log!("[HOLLOW] Reaction {emoji} removed on {message_id} by {reactor} in {server_id}/{channel_id}");
        }
        node::NetworkEvent::DmReactionRemoved { peer_id, message_id, emoji, reactor, .. } => {
            hollow_log!("[HOLLOW] Reaction {emoji} removed on DM {message_id} by {reactor} for {peer_id}");
        }
        node::NetworkEvent::FriendRequestReceived { peer_id } => {
            hollow_log!("[HOLLOW] Friend request received from {peer_id}");
        }
        node::NetworkEvent::FriendRequestAccepted { peer_id } => {
            hollow_log!("[HOLLOW] Friend request accepted by {peer_id}");
        }
        node::NetworkEvent::FriendRequestRejected { peer_id } => {
            hollow_log!("[HOLLOW] Friend request rejected by {peer_id}");
        }
        node::NetworkEvent::FriendRemoved { peer_id } => {
            hollow_log!("[HOLLOW] Friend removed: {peer_id}");
        }
        node::NetworkEvent::TypingStarted { peer_id, server_id, .. } => {
            hollow_log!("[HOLLOW] Typing started: {peer_id} in {server_id}");
        }
        node::NetworkEvent::MessagePinned { server_id, channel_id, message_id } => {
            hollow_log!("[HOLLOW] Message {message_id} pinned in {server_id}/{channel_id}");
        }
        node::NetworkEvent::MessageUnpinned { server_id, channel_id, message_id } => {
            hollow_log!("[HOLLOW] Message {message_id} unpinned in {server_id}/{channel_id}");
        }
        node::NetworkEvent::KeyExchangeStarted { peer_id } => {
            hollow_log!("[HOLLOW] Key exchange started: {peer_id}");
        }
        node::NetworkEvent::KeyExchangeProgress { peer_id, stage } => {
            hollow_log!("[HOLLOW] Key exchange: {peer_id} stage={stage}");
        }
        node::NetworkEvent::WebRtcSignal { peer_id, signal_type, .. } => {
            hollow_log!("[HOLLOW-WEBRTC] Signal {signal_type} from {peer_id}");
        }
        node::NetworkEvent::WebRtcSendFile { peer_id, transfer_id, total_size, .. } => {
            hollow_log!("[HOLLOW-WEBRTC] SendFile {transfer_id} to {peer_id} ({total_size} bytes)");
        }
        node::NetworkEvent::CallSignal { peer_id, signal_type, .. } => {
            hollow_log!("[HOLLOW-CALL] Signal {signal_type} from {peer_id}");
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
        node::NetworkEvent::MessageReceived { from_peer, text, timestamp, message_id, reply_to_mid } => {
            NetworkEvent::MessageReceived { from_peer, text, timestamp, message_id, reply_to_mid }
        }
        node::NetworkEvent::ChannelMessageReceived { server_id, channel_id, from_peer, text, timestamp, message_id, reply_to_mid } => {
            NetworkEvent::ChannelMessageReceived { server_id, channel_id, from_peer, text, timestamp, message_id, reply_to_mid }
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
        node::NetworkEvent::ChannelAdded { server_id, channel_id, name, channel_type } => {
            NetworkEvent::ChannelAdded { server_id, channel_id, name, channel_type }
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
        node::NetworkEvent::ServerJoinFailed { server_id, reason } => {
            NetworkEvent::ServerJoinFailed { server_id, reason }
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
        node::NetworkEvent::MessageSyncProgress { server_id, channel_id, received_count, total_count } => {
            NetworkEvent::MessageSyncProgress { server_id, channel_id, received_count, total_count }
        }
        node::NetworkEvent::RoleChanged { server_id, peer_id, new_role } => {
            NetworkEvent::RoleChanged { server_id, peer_id, new_role }
        }
        node::NetworkEvent::DmSyncCompleted { peer_id, new_message_count } => {
            NetworkEvent::DmSyncCompleted { peer_id, new_message_count }
        }
        node::NetworkEvent::ProfileUpdated { peer_id } => {
            NetworkEvent::ProfileUpdated { peer_id }
        }
        node::NetworkEvent::ChannelMessageEdited { server_id, channel_id, message_id, new_text, edited_at } => {
            NetworkEvent::ChannelMessageEdited { server_id, channel_id, message_id, new_text, edited_at }
        }
        node::NetworkEvent::DmMessageEdited { peer_id, message_id, new_text, edited_at } => {
            NetworkEvent::DmMessageEdited { peer_id, message_id, new_text, edited_at }
        }
        node::NetworkEvent::ChannelMessageDeleted { server_id, channel_id, message_id, deleted_at } => {
            NetworkEvent::ChannelMessageDeleted { server_id, channel_id, message_id, deleted_at }
        }
        node::NetworkEvent::DmMessageDeleted { peer_id, message_id, deleted_at } => {
            NetworkEvent::DmMessageDeleted { peer_id, message_id, deleted_at }
        }
        node::NetworkEvent::ChannelReactionAdded { server_id, channel_id, message_id, emoji, reactor, added_at } => {
            NetworkEvent::ChannelReactionAdded { server_id, channel_id, message_id, emoji, reactor, added_at }
        }
        node::NetworkEvent::DmReactionAdded { peer_id, message_id, emoji, reactor, added_at } => {
            NetworkEvent::DmReactionAdded { peer_id, message_id, emoji, reactor, added_at }
        }
        node::NetworkEvent::ChannelReactionRemoved { server_id, channel_id, message_id, emoji, reactor, removed_at } => {
            NetworkEvent::ChannelReactionRemoved { server_id, channel_id, message_id, emoji, reactor, removed_at }
        }
        node::NetworkEvent::DmReactionRemoved { peer_id, message_id, emoji, reactor, removed_at } => {
            NetworkEvent::DmReactionRemoved { peer_id, message_id, emoji, reactor, removed_at }
        }
        node::NetworkEvent::FriendRequestReceived { peer_id } => {
            NetworkEvent::FriendRequestReceived { peer_id }
        }
        node::NetworkEvent::FriendRequestAccepted { peer_id } => {
            NetworkEvent::FriendRequestAccepted { peer_id }
        }
        node::NetworkEvent::FriendRequestRejected { peer_id } => {
            NetworkEvent::FriendRequestRejected { peer_id }
        }
        node::NetworkEvent::FriendRemoved { peer_id } => {
            NetworkEvent::FriendRemoved { peer_id }
        }
        node::NetworkEvent::TypingStarted { peer_id, server_id, channel_id } => {
            NetworkEvent::TypingStarted { peer_id, server_id, channel_id }
        }
        node::NetworkEvent::MessagePinned { server_id, channel_id, message_id } => {
            NetworkEvent::MessagePinned { server_id, channel_id, message_id }
        }
        node::NetworkEvent::MessageUnpinned { server_id, channel_id, message_id } => {
            NetworkEvent::MessageUnpinned { server_id, channel_id, message_id }
        }
        // -- File transfer events --
        node::NetworkEvent::FileHeaderReceived { file_id, file_name, size_bytes, is_image, width, height, message_id, sender_id, server_id, channel_id } => {
            NetworkEvent::FileHeaderReceived { file_id, file_name, size_bytes, is_image, width, height, message_id, sender_id, server_id, channel_id }
        }
        node::NetworkEvent::FileProgress { file_id, chunks_received, total_chunks } => {
            NetworkEvent::FileProgress { file_id, chunks_received, total_chunks }
        }
        node::NetworkEvent::FileCompleted { file_id, disk_path } => {
            NetworkEvent::FileCompleted { file_id, disk_path }
        }
        node::NetworkEvent::FileFailed { file_id, error } => {
            NetworkEvent::FileFailed { file_id, error }
        }
        // -- Vault shard events (Phase 4) --
        node::NetworkEvent::ShardStored { server_id, content_id, shard_index, from_peer } => {
            NetworkEvent::ShardStored { server_id, content_id, shard_index, from_peer }
        }
        node::NetworkEvent::ShardStoreAckReceived { server_id, content_id, shard_index, success, error } => {
            NetworkEvent::ShardStoreAckReceived { server_id, content_id, shard_index, success, error }
        }
        node::NetworkEvent::ShardStoreFailed { server_id, content_id, shard_index, target_peer, error } => {
            NetworkEvent::ShardStoreFailed { server_id, content_id, shard_index, target_peer, error }
        }
        node::NetworkEvent::ShardDeleted { server_id, content_id } => {
            NetworkEvent::ShardDeleted { server_id, content_id }
        }
        node::NetworkEvent::ShardReceived { server_id, content_id, shard_index, from_peer } => {
            NetworkEvent::ShardReceived { server_id, content_id, shard_index, from_peer }
        }
        node::NetworkEvent::ShardRequestFailed { server_id, content_id, shard_index, error } => {
            NetworkEvent::ShardRequestFailed { server_id, content_id, shard_index, error }
        }
        // -- Vault upload pipeline events --
        node::NetworkEvent::VaultUploadProgress { server_id, content_id, phase, progress } => {
            NetworkEvent::VaultUploadProgress { server_id, content_id, phase, progress }
        }
        node::NetworkEvent::VaultUploadComplete { server_id, content_id, channel_id } => {
            NetworkEvent::VaultUploadComplete { server_id, content_id, channel_id }
        }
        node::NetworkEvent::VaultUploadFailed { server_id, content_id, error } => {
            NetworkEvent::VaultUploadFailed { server_id, content_id, error }
        }
        // -- Vault download pipeline events --
        node::NetworkEvent::VaultDownloadProgress { server_id, content_id, phase, progress } => {
            NetworkEvent::VaultDownloadProgress { server_id, content_id, phase, progress }
        }
        node::NetworkEvent::VaultDownloadComplete { server_id, content_id, disk_path } => {
            NetworkEvent::VaultDownloadComplete { server_id, content_id, disk_path }
        }
        node::NetworkEvent::VaultDownloadFailed { server_id, content_id, error } => {
            NetworkEvent::VaultDownloadFailed { server_id, content_id, error }
        }
        // -- Vault rebalancing events --
        node::NetworkEvent::RebalanceStarted { server_id, shards_to_move } => {
            NetworkEvent::RebalanceStarted { server_id, shards_to_move }
        }
        node::NetworkEvent::RebalanceProgress { server_id, moved, total } => {
            NetworkEvent::RebalanceProgress { server_id, moved, total }
        }
        node::NetworkEvent::RebalanceCompleted { server_id } => {
            NetworkEvent::RebalanceCompleted { server_id }
        }
        node::NetworkEvent::VaultUploadReplicationFallback { server_id, content_id, online, needed } => {
            NetworkEvent::VaultUploadReplicationFallback { server_id, content_id, online, needed }
        }
        node::NetworkEvent::KeyExchangeStarted { peer_id } => {
            NetworkEvent::KeyExchangeStarted { peer_id }
        }
        node::NetworkEvent::KeyExchangeProgress { peer_id, stage } => {
            NetworkEvent::KeyExchangeProgress { peer_id, stage }
        }
        // -- WebRTC events (Phase 5A) --
        node::NetworkEvent::WebRtcSignal { peer_id, signal_type, payload, conn_id } => {
            NetworkEvent::WebRtcSignal { peer_id, signal_type, payload, conn_id }
        }
        node::NetworkEvent::WebRtcSendFile { peer_id, transfer_id, file_path, total_size, kind, shard_index } => {
            NetworkEvent::WebRtcSendFile { peer_id, transfer_id, file_path, total_size, kind, shard_index }
        }
        // -- Voice call events (Phase 5B) --
        node::NetworkEvent::CallSignal { peer_id, signal_type, payload } => {
            NetworkEvent::CallSignal { peer_id, signal_type, payload }
        }
        // -- Voice channel events (Phase 5C) --
        node::NetworkEvent::VoiceChannelJoined { server_id, channel_id, peer_id } => {
            NetworkEvent::VoiceChannelJoined { server_id, channel_id, peer_id }
        }
        node::NetworkEvent::VoiceChannelLeft { server_id, channel_id, peer_id } => {
            NetworkEvent::VoiceChannelLeft { server_id, channel_id, peer_id }
        }
        node::NetworkEvent::VoiceChannelSignal { server_id, channel_id, peer_id, signal_type, payload } => {
            NetworkEvent::VoiceChannelSignal { server_id, channel_id, peer_id, signal_type, payload }
        }
        // -- Gossip relay tree events (Phase 5D) --
        node::NetworkEvent::GossipConnect { peer_id } => {
            NetworkEvent::GossipConnect { peer_id }
        }
        node::NetworkEvent::GossipDisconnect { peer_id } => {
            NetworkEvent::GossipDisconnect { peer_id }
        }
        node::NetworkEvent::GossipRelayFile { broadcast_id, ttl, origin_peer_id, file_path, total_size, kind, shard_index, exclude_peer_id, server_id, channel_id } => {
            NetworkEvent::GossipRelayFile { broadcast_id, ttl, origin_peer_id, file_path, total_size, kind, shard_index, exclude_peer_id, server_id, channel_id }
        }
        node::NetworkEvent::VoiceChannelModeChanged { server_id, channel_id, mode, gossip_neighbors } => {
            NetworkEvent::VoiceChannelModeChanged { server_id, channel_id, mode, gossip_neighbors }
        }
        node::NetworkEvent::MlsEpochChanged { server_id, epoch, sframe_key } => {
            NetworkEvent::MlsEpochChanged { server_id, epoch, sframe_key }
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
    hollow_log!("[HOLLOW] === Node starting ===");

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
    let hollow_dir = crate::identity::data_dir()?;
    std::fs::create_dir_all(&hollow_dir)
        .map_err(|e| format!("Failed to create data dir: {e}"))?;
    let db_path = hollow_dir
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

    let cmd_tx_clone = cmd_tx.clone();
    let (peer_id_str, handle) = rt
        .block_on(node::spawn_node(id.keypair, event_tx, cmd_rx, cmd_tx_clone, olm, crypto_store))
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
            hollow_log!("[HOLLOW] Event stream sink closed, stopping forwarding");
            break;
        }
    }
    hollow_log!("[HOLLOW] Event channel closed, stream ending");
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
pub fn send_message(peer_id: String, text: String, message_id: String, reply_to_mid: Option<String>) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;

    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state
            .cmd_tx
            .send(node::NodeCommand::SendMessage { peer_id, text, message_id, reply_to_mid }),
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
    message_id: String,
    reply_to_mid: Option<String>,
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
            message_id,
            reply_to_mid,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Edit a channel message. Broadcasts the edit to all server members.
#[frb]
pub fn edit_channel_message(
    server_id: String,
    channel_id: String,
    message_id: String,
    new_text: String,
) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::EditChannelMessage {
            server_id,
            channel_id,
            message_id,
            new_text,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Edit a DM message. Sends the edit to the DM peer.
#[frb]
pub fn edit_dm_message(
    peer_id: String,
    message_id: String,
    new_text: String,
) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let peer = peer_id;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::EditDmMessage {
            peer_id: peer,
            message_id,
            new_text,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Delete (hide) a channel message. Broadcasts the deletion to all server members.
/// The message stays in the DB (Rat Files evidence) but is hidden from UI.
#[frb]
pub fn delete_channel_message(
    server_id: String,
    channel_id: String,
    message_id: String,
) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::DeleteChannelMessage {
            server_id,
            channel_id,
            message_id,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Delete (hide) a DM message. Sends the deletion to the DM peer.
#[frb]
pub fn delete_dm_message(
    peer_id: String,
    message_id: String,
) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let peer = peer_id;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::DeleteDmMessage {
            peer_id: peer,
            message_id,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Add an emoji reaction to a channel message.
#[frb]
pub fn add_channel_reaction(
    server_id: String,
    channel_id: String,
    message_id: String,
    emoji: String,
) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::AddChannelReaction {
            server_id,
            channel_id,
            message_id,
            emoji,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Remove an emoji reaction from a channel message.
#[frb]
pub fn remove_channel_reaction(
    server_id: String,
    channel_id: String,
    message_id: String,
    emoji: String,
) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::RemoveChannelReaction {
            server_id,
            channel_id,
            message_id,
            emoji,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Add an emoji reaction to a DM message.
#[frb]
pub fn add_dm_reaction(
    peer_id: String,
    message_id: String,
    emoji: String,
) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let peer = peer_id;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::AddDmReaction {
            peer_id: peer,
            message_id,
            emoji,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Remove an emoji reaction from a DM message.
#[frb]
pub fn remove_dm_reaction(
    peer_id: String,
    message_id: String,
    emoji: String,
) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let peer = peer_id;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::RemoveDmReaction {
            peer_id: peer,
            message_id,
            emoji,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Send a friend request to a peer.
#[frb]
pub fn send_friend_request(peer_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let peer = peer_id;

    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::SendFriendRequest { peer_id: peer }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Accept a friend request from a peer.
#[frb]
pub fn accept_friend_request(peer_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let peer = peer_id;

    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::AcceptFriendRequest { peer_id: peer }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Reject a friend request from a peer.
#[frb]
pub fn reject_friend_request(peer_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let peer = peer_id;

    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::RejectFriendRequest { peer_id: peer }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Remove a friend.
#[frb]
pub fn remove_friend(peer_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let peer = peer_id;

    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::RemoveFriend { peer_id: peer }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Send a typing indicator to peers. Ephemeral, not stored.
/// For DMs: server_id = "", channel_id = peer ID.
/// For channels: server_id and channel_id as normal.
#[frb]
pub fn send_typing_indicator(server_id: String, channel_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::SendTypingIndicator {
            server_id,
            channel_id,
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
/// Update our display name, status, about me, and optionally avatar/banner —
/// saves to DB and broadcasts to all connected peers.
#[frb]
pub fn update_profile(
    display_name: String,
    status: String,
    about_me: String,
    avatar_bytes: Option<Vec<u8>>,
    banner_bytes: Option<Vec<u8>>,
) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state.cmd_tx.send(node::NodeCommand::UpdateProfile {
            display_name,
            status,
            about_me,
            avatar_bytes,
            banner_bytes,
        }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Process a raw image into avatar format (128x128 WebP). Returns processed bytes.
#[frb]
pub fn process_avatar(raw_bytes: Vec<u8>) -> Result<Vec<u8>, String> {
    crate::node::image_convert::process_avatar_image(&raw_bytes)
}

/// Process a raw image into banner format (600x200 WebP). Returns processed bytes.
#[frb]
pub fn process_banner(raw_bytes: Vec<u8>) -> Result<Vec<u8>, String> {
    crate::node::image_convert::process_banner_image(&raw_bytes)
}

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

// ── File sharing FFI ────────────────────────────────────────────

/// Send a file to a DM peer or server channel.
/// `peer_id`: target peer (for DMs, empty for channels).
/// `server_id` + `channel_id`: target channel (for servers, empty for DMs).
#[frb]
pub fn send_file(
    peer_id: Option<String>,
    server_id: Option<String>,
    channel_id: Option<String>,
    file_path: String,
    message_id: String,
    message_text: String,
) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let peer = peer_id.filter(|id| !id.is_empty());

    let rt = get_runtime();
    rt.block_on(
        state
            .cmd_tx
            .send(node::NodeCommand::SendFile {
                peer_id: peer,
                server_id,
                channel_id,
                file_path,
                message_id,
                message_text,
            }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Request file chunks from a specific peer.
#[frb]
pub fn request_file_from_peer(
    file_id: String,
    peer_id: String,
    chunks: Vec<u32>,
) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;

    let rt = get_runtime();
    rt.block_on(
        state
            .cmd_tx
            .send(node::NodeCommand::RequestFile {
                file_id,
                peer_id,
                chunks,
            }),
    )
    .map_err(|e| format!("Failed to send command: {e}"))?;

    Ok(())
}

/// Convert a WebP image file to another format (PNG/JPEG).
/// Used for "Save As" functionality.
#[frb]
pub fn convert_image_format(
    source_path: String,
    target_format: String,
) -> Result<Vec<u8>, String> {
    let data = std::fs::read(&source_path)
        .map_err(|e| format!("Failed to read source file: {e}"))?;
    crate::node::image_convert::convert_from_webp(&data, &target_format)
}

/// Get the files directory path.
#[frb]
pub fn get_files_dir() -> String {
    crate::node::file_transfer::files_dir()
        .to_string_lossy()
        .to_string()
}

/// Log a message from Dart to hollow_debug.log (visible in release builds).
#[frb]
pub fn log_from_dart(message: String) {
    hollow_log!("{message}");
}

// -- WebRTC FFI functions (Phase 5A) --

/// Notify Rust that a WebRTC data channel is established with a peer.
#[frb]
pub fn webrtc_peer_connected(peer_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;
    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::WebRtcPeerConnected { peer_id }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Notify Rust that a WebRTC data channel has been closed for a peer.
#[frb]
pub fn webrtc_peer_disconnected(peer_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;
    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::WebRtcPeerDisconnected { peer_id }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Send a WebRTC signaling message (SDP offer/answer or ICE candidate) to a peer.
/// Rust routes it through the WSS relay to the target peer.
#[frb]
pub fn webrtc_send_signal(
    peer_id: String,
    signal_type: String,
    payload: String,
    conn_id: String,
) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;
    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::WebRtcSendSignal {
        peer_id, signal_type, payload, conn_id,
    }))
    .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Notify Rust that a WebRTC file transfer completed (receiver side).
/// Rust will decrypt and process the received file.
#[frb]
pub fn webrtc_transfer_complete(
    transfer_id: String,
    temp_path: String,
    sender_peer_id: String,
    kind: String,
    shard_index: u16,
) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;
    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::WebRtcTransferComplete {
        transfer_id, temp_path, sender_peer_id, kind, shard_index,
    }))
    .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Notify Rust that a WebRTC file send completed (sender side).
/// Rust cleans up the temp encrypted file.
#[frb]
pub fn webrtc_send_complete(transfer_id: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;
    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::WebRtcSendComplete { transfer_id }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Notify Rust that a WebRTC transfer failed. Triggers WSS relay fallback.
#[frb]
pub fn webrtc_transfer_failed(
    transfer_id: String,
    peer_id: String,
    error: String,
) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;
    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::WebRtcTransferFailed {
        transfer_id, peer_id, error,
    }))
    .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Send a voice call signaling message to a peer (Phase 5B).
#[frb]
pub fn call_send_signal(
    peer_id: String,
    signal_type: String,
    payload: String,
) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;
    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::CallSendSignal {
        peer_id, signal_type, payload,
    }))
    .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Join a voice channel in a server (Phase 5C).
#[frb]
pub fn voice_channel_join(
    server_id: String,
    channel_id: String,
) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;
    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::VoiceChannelJoin {
        server_id, channel_id,
    }))
    .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Leave a voice channel in a server (Phase 5C).
#[frb]
pub fn voice_channel_leave(
    server_id: String,
    channel_id: String,
) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;
    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::VoiceChannelLeave {
        server_id, channel_id,
    }))
    .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Send a voice channel signaling message (SDP/ICE) to a specific peer (Phase 5C).
#[frb]
pub fn voice_channel_send_signal(
    server_id: String,
    channel_id: String,
    peer_id: String,
    signal_type: String,
    payload: String,
) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;
    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::VoiceChannelSendSignal {
        server_id, channel_id, peer_id, signal_type, payload,
    }))
    .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

// -- Gossip relay tree FFI (Phase 5D) --

/// Report data channel keepalive RTT for gossip peer scoring.
#[frb]
pub fn webrtc_ping_report(peer_id: String, rtt_ms: u32) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;
    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::WebRtcPingReport {
        peer_id, rtt_ms,
    }))
    .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Notify Rust that a broadcast file was received via gossip data channel.
#[frb]
pub fn webrtc_broadcast_received(
    transfer_id: String,
    broadcast_id: String,
    ttl: u8,
    origin_peer_id: String,
    sender_peer_id: String,
    temp_path: String,
    total_size: u64,
    kind: String,
    shard_index: u16,
) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;
    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::WebRtcBroadcastReceived {
        transfer_id, broadcast_id, ttl, origin_peer_id, sender_peer_id,
        temp_path, total_size, kind, shard_index,
    }))
    .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}
