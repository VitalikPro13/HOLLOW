use std::collections::HashMap;
use std::io;
use std::time::Duration;

use libp2p::futures::StreamExt;
use libp2p::request_response::{self, ProtocolSupport};
use libp2p::{autonat, dcutr, identify, identity, kad, mdns, noise, ping, relay, swarm::SwarmEvent, tcp, tls, yamux, Multiaddr, PeerId, SwarmBuilder};
use base64::Engine;
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

use crate::crdt::hlc::Hlc;
use crate::crdt::operations::{CrdtPayload, Permission};
use crate::crdt::server_state::ServerState;
use crate::crdt::sync::{self as crdt_sync, StateVector};
use crate::crypto::{CryptoStore, MlsManager, OlmManager};
use super::signaling::{self, SignalingCmd, SignalingEvent};

// -- Relay node constants (OVH VPS, Belgium) --
const RELAY_ADDR_TCP: &str = "/ip4/141.227.186.209/tcp/4001";
const RELAY_ADDR_QUIC: &str = "/ip4/141.227.186.209/udp/4001/quic-v1";
const RELAY_ADDR_WSS: &str = "/dns4/relay.anonlisten.com/tcp/443/tls/ws";
const RELAY_PEER_ID: &str = "12D3KooWSN4XSvAZdyKULvTgnsxYqcfr4LEmqCkAcQoTzaotDX8s";

/// Parse the relay PeerId from the hardcoded constant.
/// Returns None if the relay hasn't been configured yet (empty string).
fn relay_peer_id() -> Option<PeerId> {
    if RELAY_PEER_ID.is_empty() {
        return None;
    }
    RELAY_PEER_ID.parse().ok()
}

/// Build the relay multiaddrs including the peer ID suffix.
fn relay_addrs() -> Vec<Multiaddr> {
    if RELAY_PEER_ID.is_empty() {
        return vec![];
    }
    [RELAY_ADDR_TCP, RELAY_ADDR_QUIC, RELAY_ADDR_WSS]
        .iter()
        .filter_map(|base| {
            format!("{base}/p2p/{RELAY_PEER_ID}").parse().ok()
        })
        .collect()
}

/// Like `relay_addrs()`, but when proxy is enabled returns only the local
/// tunnel address (TCP through Shadowsocks). QUIC/WSS can't be tunneled.
fn proxy_aware_relay_addrs(proxy_enabled: bool) -> Vec<Multiaddr> {
    if proxy_enabled {
        if RELAY_PEER_ID.is_empty() {
            return vec![];
        }
        vec![format!("{}/p2p/{RELAY_PEER_ID}", super::tunnel::PROXY_RELAY_ADDR)
            .parse()
            .unwrap()]
    } else {
        relay_addrs()
    }
}

/// Filter addresses for signaling registration.
/// Removes loopback, link-local, and private LAN addresses.
/// Keeps relay circuit addresses and public IPs.
fn is_registerable_address(addr: &str) -> bool {
    // Always keep relay circuit addresses — they're routable from anywhere.
    if addr.contains("p2p-circuit") {
        return true;
    }
    // Exclude loopback.
    if addr.contains("/ip4/127.") || addr.contains("/ip6/::1/") {
        return false;
    }
    // Exclude link-local.
    if addr.contains("/ip4/169.254.") || addr.contains("/ip6/fe80") {
        return false;
    }
    // Exclude private LAN ranges (unreachable from other networks).
    if addr.contains("/ip4/192.168.") || addr.contains("/ip4/10.") {
        return false;
    }
    // 172.16.0.0 - 172.31.255.255
    if let Some(pos) = addr.find("/ip4/172.") {
        let after = &addr[pos + 9..];
        if let Some(dot_pos) = after.find('.') {
            if let Ok(second_octet) = after[..dot_pos].parse::<u8>() {
                if (16..=31).contains(&second_octet) {
                    return false;
                }
            }
        }
    }
    true
}

/// Compute a deterministic DM room code for two peers.
/// Both peers compute the same code so signaling can match them.
/// Uses SHA-256 truncated to 32 hex chars for collision resistance.
fn dm_room_code(peer_a: &str, peer_b: &str) -> String {
    use sha2::{Sha256, Digest};
    let mut sorted = [peer_a, peer_b];
    sorted.sort();
    let combined = format!("dm-{}-{}", sorted[0], sorted[1]);
    let hash = Sha256::digest(combined.as_bytes());
    hex::encode(&hash[..16]) // 128-bit / 32 hex chars
}

/// Extract transport method from a multiaddr string for UI display.
fn transport_method_from_addr(addr: &str) -> &'static str {
    if addr.contains("p2p-circuit") {
        "relay"
    } else if addr.contains("/quic") {
        "quic"
    } else if addr.contains("/ws/") || addr.contains("/wss/") {
        "wss"
    } else if addr.contains("/tcp/") {
        "tcp"
    } else {
        "unknown"
    }
}

/// A discovered peer on the local network.
pub(crate) struct DiscoveredPeer {
    pub peer_id: String,
    pub addresses: Vec<String>,
}

/// Events emitted by the network node.
pub(crate) enum NetworkEvent {
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
        server_id: String,    // empty for DMs
        channel_id: String,   // peer_id for DMs
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
    // -- Connection status events (granular UI) --
    ConnectionAttemptStarted { peer_id: String, method: String },
    ConnectionAttemptFailed { peer_id: String, method: String, reason: String },
    KeyExchangeStarted { peer_id: String },
    KeyExchangeProgress { peer_id: String, stage: String },
    RelayStatusChanged { status: String },
}

/// Commands the FFI layer can send into the swarm event loop.
pub(crate) enum NodeCommand {
    SendMessage { peer_id: PeerId, text: String, message_id: String, reply_to_mid: Option<String> },
    SendChannelMessage { server_id: String, channel_id: String, text: String, message_id: String, reply_to_mid: Option<String> },
    JoinRoom { room_code: String },
    // -- CRDT commands (Phase 3) --
    CreateServer { name: String },
    CreateChannel { server_id: String, name: String, category: Option<String> },
    RemoveChannel { server_id: String, channel_id: String },
    RenameServer { server_id: String, new_name: String },
    RenameChannel { server_id: String, channel_id: String, new_name: String },
    UpdateServerSetting { server_id: String, key: String, value: String },
    DeleteServer { server_id: String },
    JoinServer { server_id: String },
    RequestChannelSync { server_id: String, channel_id: String },
    ChangeRole { server_id: String, peer_id: String, new_role: String },
    KickMember { server_id: String, peer_id: String },
    SetNickname { server_id: String, peer_id: String, nickname: String },
    NotifyShutdown,
    // -- Profile commands (Phase 3.5) --
    UpdateProfile { display_name: String, status: String, about_me: String, avatar_bytes: Option<Vec<u8>>, banner_bytes: Option<Vec<u8>> },
    // -- Message editing (Phase 3.5) --
    EditChannelMessage { server_id: String, channel_id: String, message_id: String, new_text: String },
    EditDmMessage { peer_id: PeerId, message_id: String, new_text: String },
    // -- Message deletion/hiding (Phase 3.5) --
    DeleteChannelMessage { server_id: String, channel_id: String, message_id: String },
    DeleteDmMessage { peer_id: PeerId, message_id: String },
    // -- Emoji reactions (Phase 3.5) --
    AddChannelReaction { server_id: String, channel_id: String, message_id: String, emoji: String },
    AddDmReaction { peer_id: PeerId, message_id: String, emoji: String },
    RemoveChannelReaction { server_id: String, channel_id: String, message_id: String, emoji: String },
    RemoveDmReaction { peer_id: PeerId, message_id: String, emoji: String },
    // -- Friends (Phase 3.5) --
    SendFriendRequest { peer_id: PeerId },
    AcceptFriendRequest { peer_id: PeerId },
    RejectFriendRequest { peer_id: PeerId },
    RemoveFriend { peer_id: PeerId },
    // -- Typing indicators (Phase 3.5) --
    SendTypingIndicator { server_id: String, channel_id: String },
    // -- Channel layout (Phase 3.5) --
    UpdateChannelLayout { server_id: String, layout_json: String },
    // -- Pinned messages (Phase 3.5) --
    PinMessage { server_id: String, channel_id: String, message_id: String },
    UnpinMessage { server_id: String, channel_id: String, message_id: String },
    // -- Storage pledge (Phase 4) --
    SetStoragePledge { server_id: String, pledge_bytes: u64 },
    // -- File sharing (Phase 3.5) --
    SendFile {
        peer_id: Option<PeerId>,          // For DMs (None for channels)
        server_id: Option<String>,         // For channels
        channel_id: Option<String>,        // For channels
        file_path: String,                 // Local path to file
        message_id: String,
        message_text: String,
    },
    RequestFile {
        file_id: String,
        peer_id: PeerId,
        chunks: Vec<u32>,
    },
    // -- Vault shard distribution (Phase 4) --
    VaultDownloadFile { server_id: String, content_id: String },
    VaultUploadFile {
        server_id: String,
        channel_id: String,
        file_name: String,
        mime_type: String,
        message_id: String,
        ciphertext: Vec<u8>,
        aes_key: Vec<u8>,
        aes_nonce: Vec<u8>,
        original_size: u64,
        content_id: String,
    },
    DeleteVaultContent { server_id: String, content_id: String },
    RequestShardFromPeer {
        server_id: String,
        content_id: String,
        shard_index: u16,
        shard_key: String,
        target_peer: String,
    },
    StoreShardOnPeer {
        server_id: String,
        content_id: String,
        shard_index: u16,
        shard_key: String,
        k: u16,
        m: u16,
        total_data_size: u64,
        storage_tier: String,
        data: Vec<u8>,
        target_peer: String,
    },
}

// -- Wire protocol types (v2: encrypted) --

/// Unified message type for the Haven protocol.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
enum HavenMessage {
    #[serde(rename = "key_request")]
    KeyRequest,

    #[serde(rename = "key_bundle")]
    KeyBundle {
        identity_key: String,
        one_time_key: String,
    },

    #[serde(rename = "encrypted")]
    Encrypted {
        message_type: usize,
        body: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        identity_key: Option<String>,
    },

    #[serde(rename = "ack")]
    Ack,

    // -- CRDT sync messages (Phase 3) --

    #[serde(rename = "sync_request")]
    SyncRequest {
        server_id: String,
        state_vector_json: String,
    },

    #[serde(rename = "sync_response")]
    SyncResponse {
        server_id: String,
        ops_json: String,
    },

    #[serde(rename = "crdt_op")]
    CrdtOpBroadcast {
        server_id: String,
        op_json: String,
    },

    #[serde(rename = "join_request")]
    ServerJoinRequest {
        server_id: String,
    },

    #[serde(rename = "server_delete")]
    ServerDeleteBroadcast {
        server_id: String,
    },

    /// Sent to the kicked member so they remove themselves from the server.
    #[serde(rename = "member_kick")]
    MemberKickBroadcast {
        server_id: String,
    },

    #[serde(rename = "ch_sync_req")]
    ChannelSyncRequest {
        server_id: String,
        channel_id: String,
        since_timestamp: i64,
        /// Per-sender latest timestamps for gap-free sync.
        /// Empty = legacy (fall back to since_timestamp).
        #[serde(default)]
        sender_timestamps: HashMap<String, i64>,
    },

    /// DM sync: request missed DMs from a peer.
    #[serde(rename = "dm_sync_req")]
    DmSyncRequest {
        /// Latest DM timestamp the requester has from this peer.
        since_timestamp: i64,
    },

    /// Sent to all connected peers when the app is shutting down.
    #[serde(rename = "disconnecting")]
    PeerDisconnecting,

    // -- MLS group encryption messages --

    /// MLS-encrypted channel message (replaces Olm fan-out for channels).
    #[serde(rename = "mls_msg")]
    MlsChannelMessage {
        server_id: String,
        body: String, // base64 MLS ciphertext
    },

    /// KeyPackage from a peer wanting to join an MLS group.
    #[serde(rename = "mls_kp")]
    MlsKeyPackage {
        server_id: String,
        key_package: String, // base64 serialized KeyPackage
    },

    /// Welcome message sent to a joiner after add_members().
    #[serde(rename = "mls_welcome")]
    MlsWelcome {
        server_id: String,
        welcome: String, // base64 serialized Welcome
    },

    /// Commit message (membership change) from the server owner.
    #[serde(rename = "mls_commit")]
    MlsCommit {
        server_id: String,
        commit: String, // base64 serialized Commit
    },

    /// Request peers to send their KeyPackages for MLS group bootstrap.
    #[serde(rename = "mls_kp_req")]
    MlsKeyPackageRequest {
        server_id: String,
    },

    // -- Profile sync (Phase 3.5) --

    /// Broadcast profile update to connected peers. Plaintext (not sensitive).
    #[serde(rename = "profile_update")]
    ProfileUpdate {
        display_name: String,
        status: String,
        about_me: String,
        updated_at: i64,
        #[serde(default)]
        avatar_b64: String,
        #[serde(default)]
        banner_b64: String,
    },

    // -- Multi-peer fan-out sync (Phase 3.5) --

    /// Lightweight probe: "what's your latest timestamp for this channel?"
    /// Used to skip channels that have no new messages before sending a full sync request.
    #[serde(rename = "ch_sync_probe")]
    ChannelSyncProbe {
        server_id: String,
        channel_id: String,
        /// Our latest timestamp for this channel (so the peer can quickly compare).
        our_latest: i64,
        /// Total message count for health check (catches mid-session drops).
        #[serde(default)]
        msg_count: u32,
    },

    // -- Friends (Phase 3.5) --

    #[serde(rename = "friend_request")]
    FriendRequest {
        requested_at: i64,
    },

    #[serde(rename = "friend_accept")]
    FriendAccept,

    #[serde(rename = "friend_reject")]
    FriendReject,

    #[serde(rename = "friend_remove")]
    FriendRemove,

    // -- Typing indicators (Phase 3.5) --

    /// Ephemeral typing indicator. Not stored, not signed. Fire-and-forget.
    #[serde(rename = "typing")]
    TypingIndicator {
        /// Empty string for DMs.
        server_id: String,
        /// Empty string for DMs.
        channel_id: String,
    },

    /// Response to a sync probe: the peer's latest timestamp for the channel.
    #[serde(rename = "ch_sync_probe_resp")]
    ChannelSyncProbeResponse {
        server_id: String,
        channel_id: String,
        /// Peer's latest timestamp for this channel.
        their_latest: i64,
        /// Total message count the peer has for this channel (for load estimation).
        msg_count: u32,
    },

    // -- File sharing (Phase 3.5) --

    /// Request file chunks from a peer.
    #[serde(rename = "file_req")]
    FileRequest {
        file_id: String,
        /// Which chunks we need (empty = all).
        #[serde(default)]
        chunks: Vec<u32>,
    },

    /// "Do you have this file?"
    #[serde(rename = "file_probe")]
    FileProbe {
        file_id: String,
    },

    /// Response: "I have this file / these chunks."
    #[serde(rename = "file_probe_resp")]
    FileProbeResponse {
        file_id: String,
        has_file: bool,
        #[serde(default)]
        available_chunks: Vec<u32>,
    },
}

/// Envelope for the plaintext body inside an Encrypted message.
/// Legacy DMs are raw text (no JSON). New messages use this envelope.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "t")]
enum MessageEnvelope {
    #[serde(rename = "dm")]
    DirectMessage {
        text: String,
        /// Sender-generated timestamp (millis since epoch).
        #[serde(default)]
        ts: i64,
        /// Ed25519 signature (base64) over canonical payload.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sig: Option<String>,
        /// Sender's Ed25519 public key (base64 protobuf).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pk: Option<String>,
        /// Unique message ID (UUID, sender-generated).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        mid: Option<String>,
        /// Message ID this is replying to (optional).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reply_to: Option<String>,
        /// File attachment ID (optional).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        file_id: Option<String>,
    },
    #[serde(rename = "ch")]
    ChannelMessage {
        sid: String,
        cid: String,
        text: String,
        /// Sender-generated timestamp (millis since epoch).
        ts: i64,
        /// Ed25519 signature (base64) over canonical payload.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sig: Option<String>,
        /// Sender's Ed25519 public key (base64 protobuf).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pk: Option<String>,
        /// Unique message ID (UUID, sender-generated).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        mid: Option<String>,
        /// Message ID this is replying to (optional).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reply_to: Option<String>,
        /// File attachment ID (optional).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        file_id: Option<String>,
    },
    #[serde(rename = "ch_sync")]
    ChannelSyncBatch {
        sid: String,
        cid: String,
        messages: Vec<SyncMessageItem>,
        /// Total messages available since requested timestamp (for progress indication).
        #[serde(default)]
        total: u32,
        /// If true, more messages are available — receiver should send a follow-up request.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        has_more: Option<bool>,
    },
    /// DM sync batch — carries missed DMs from the sender.
    #[serde(rename = "dm_sync")]
    DmSyncBatch {
        messages: Vec<DmSyncItem>,
        /// If true, more DMs are available — receiver should send a follow-up request.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        has_more: Option<bool>,
    },
    /// Edit an existing message (channel or DM).
    #[serde(rename = "edit")]
    EditMessage {
        /// The message_id of the original message.
        mid: String,
        /// New text content.
        text: String,
        /// Edit timestamp (millis since epoch).
        ts: i64,
        /// Ed25519 signature over the edit payload.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sig: Option<String>,
        /// Sender's Ed25519 public key.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pk: Option<String>,
        /// Server ID (present for channel edits, absent for DM edits).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sid: Option<String>,
        /// Channel ID (present for channel edits, absent for DM edits).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cid: Option<String>,
    },
    /// Delete (hide) an existing message (channel or DM).
    #[serde(rename = "delete")]
    DeleteMessage {
        /// The message_id of the message to delete.
        mid: String,
        /// Deletion timestamp (millis since epoch).
        ts: i64,
        /// Ed25519 signature over the deletion payload.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sig: Option<String>,
        /// Sender's Ed25519 public key.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pk: Option<String>,
        /// Server ID (present for channel deletions, absent for DM).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sid: Option<String>,
        /// Channel ID (present for channel deletions, absent for DM).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cid: Option<String>,
    },
    /// Add an emoji reaction to a message.
    #[serde(rename = "reaction")]
    AddReaction {
        /// The message_id being reacted to.
        mid: String,
        /// Unicode emoji string.
        emoji: String,
        /// Timestamp (millis since epoch).
        ts: i64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sig: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pk: Option<String>,
        /// Server ID (present for channel reactions, absent for DM).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sid: Option<String>,
        /// Channel ID (present for channel reactions, absent for DM).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cid: Option<String>,
    },
    /// Remove an emoji reaction from a message.
    #[serde(rename = "unreaction")]
    RemoveReaction {
        mid: String,
        emoji: String,
        ts: i64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sig: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pk: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sid: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cid: Option<String>,
    },

    // -- File sharing (Phase 3.5) --

    /// File metadata header — sent before file chunks.
    #[serde(rename = "file_hdr")]
    FileHeader {
        /// Unique file ID (32-char hex).
        fid: String,
        /// Original file name.
        name: String,
        /// File extension.
        ext: String,
        /// MIME type.
        mime: String,
        /// Total size in bytes.
        size: u64,
        /// Number of chunks (0 for streamed transfers).
        chunks: u32,
        /// Is this an image?
        #[serde(default)]
        img: bool,
        /// Image width (if image).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        w: Option<u32>,
        /// Image height (if image).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        h: Option<u32>,
        /// Message ID this file is attached to.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        mid: Option<String>,
        /// Server ID (for channel files).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sid: Option<String>,
        /// Channel ID (for channel files).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cid: Option<String>,
        ts: i64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sig: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pk: Option<String>,
        /// AES-256-GCM key (hex). Present → file bytes arrive via /hollow/stream/1.0.0.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        aes_key: Option<String>,
        /// AES-256-GCM nonce (hex). Present with aes_key for streamed transfers.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        aes_nonce: Option<String>,
    },

    /// A single file chunk (base64-encoded data).
    #[serde(rename = "file_chunk")]
    FileChunk {
        /// File ID this chunk belongs to.
        fid: String,
        /// 0-based chunk index.
        idx: u32,
        /// Base64-encoded chunk data (up to 256KB decoded).
        data: String,
    },

    // -- Vault shard store (Phase 4) --

    /// Vault shard store request (header + optional inline data).
    #[serde(rename = "shard_store")]
    ShardStore {
        sid: String,
        cid: String,
        si: u16,
        sk: String,
        k: u16,
        m: u16,
        total_size: u64,
        tier: String,
        data: String,
        chunks: u32,
    },

    /// Vault shard chunk (for shards > 256KB).
    #[serde(rename = "shard_chunk")]
    ShardChunk {
        sid: String,
        cid: String,
        si: u16,
        ci: u32,
        data: String,
    },

    /// Vault shard store acknowledgment.
    #[serde(rename = "shard_ack")]
    ShardStoreAck {
        sid: String,
        cid: String,
        si: u16,
        ok: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        err: Option<String>,
    },

    /// Vault shard deletion request (admin-only, MANAGE_SERVER permission).
    #[serde(rename = "shard_delete")]
    ShardDelete {
        sid: String,
        cid: String,
    },

    // -- Vault shard retrieve (Phase 4) --

    /// Request a specific shard from a peer.
    #[serde(rename = "shard_req")]
    ShardRequest {
        sid: String,
        cid: String,
        si: u16,
        sk: String,
    },

    /// Response with shard data (or not-found).
    #[serde(rename = "shard_resp")]
    ShardResponse {
        sid: String,
        cid: String,
        si: u16,
        data: String,
        chunks: u32,
        found: bool,
    },

    /// Chunked shard response (for shards > 256KB).
    #[serde(rename = "shard_resp_chunk")]
    ShardResponseChunk {
        sid: String,
        cid: String,
        si: u16,
        ci: u32,
        data: String,
    },

    /// Probe: ask peer which shards they have for a content item.
    #[serde(rename = "shard_probe")]
    ShardProbe {
        sid: String,
        cid: String,
    },

    /// Probe response: list of shard indices available locally.
    #[serde(rename = "shard_probe_resp")]
    ShardProbeResponse {
        sid: String,
        cid: String,
        shards: Vec<u16>,
    },

    /// Vault manifest broadcast — carries file manifest (contains AES key).
    #[serde(rename = "vault_manifest")]
    VaultManifestBroadcast {
        sid: String,
        cid: String,
        chid: String,
        manifest: String, // manifest JSON
    },

    /// Vault shard migration — proactive move during rebalancing.
    #[serde(rename = "shard_migrate")]
    ShardMigrate {
        sid: String,
        cid: String,
        si: u16,
        sk: String,
        data: String, // base64 shard data
    },

    /// Lightweight encrypted ping sent after creating an inbound session.
    /// Causes the remote peer's outbound session to ratchet (upgrade from
    /// PreKey type 0 to Normal type 1) when they decrypt this message.
    #[serde(rename = "session_ack")]
    SessionAck,
}

/// State for reassembling a chunked vault shard from multiple ShardChunk messages.
struct PendingShardAssembly {
    server_id: String,
    content_id: String,
    shard_index: u16,
    shard_key: String,
    k: u16,
    m: u16,
    total_size: u64,
    tier: String,
    expected_chunks: u32,
    received: std::collections::HashSet<u32>,
    chunk_data: Vec<(u32, Vec<u8>)>,
    sender_peer: String,
    received_at: std::time::Instant,
}

/// Pending streamed file transfer — AES key stored here until stream bytes arrive.
struct PendingFileStream {
    aes_key: String,
    aes_nonce: String,
    file_name: String,
    ext: String,
    sender: String,
    server_id: String,
    channel_id: String,
    message_id: String,
    is_image: bool,
    width: Option<u32>,
    height: Option<u32>,
}

/// Pending streamed shard transfer — metadata stored here until stream bytes arrive.
struct PendingShardStream {
    server_id: String,
    content_id: String,
    shard_index: u16,
    shard_key: String,
    k: u16,
    m: u16,
    total_size: u64,
    tier: String,
}

/// A single message in a sync batch.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct SyncMessageItem {
    /// sender peer ID
    s: String,
    /// message text
    t: String,
    /// timestamp (millis since epoch)
    ts: i64,
    /// Ed25519 signature (base64) over canonical payload.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    sig: Option<String>,
    /// Sender's Ed25519 public key (base64 protobuf).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pk: Option<String>,
    /// Unique message ID (UUID).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    mid: Option<String>,
    /// Edit timestamp (if message was edited).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    edited_at: Option<i64>,
    /// Message ID this is replying to (optional).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    reply_to: Option<String>,
    /// File attachment ID (optional).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    file_id: Option<String>,
    /// Reactions on this message (synced alongside the message).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    reactions: Vec<SyncReactionItem>,
}

/// A single reaction in a sync batch.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct SyncReactionItem {
    e: String,  // emoji
    p: String,  // peer_id
    ts: i64,    // added_at
    #[serde(default, skip_serializing_if = "Option::is_none")]
    sig: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pk: Option<String>,
}

/// A single DM in a DM sync batch.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct DmSyncItem {
    /// message text
    t: String,
    /// timestamp (millis since epoch)
    ts: i64,
    /// true if the sender of this sync batch sent this message
    mine: bool,
    /// Ed25519 signature (base64).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    sig: Option<String>,
    /// Sender's Ed25519 public key (base64 protobuf).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pk: Option<String>,
    /// Unique message ID (UUID).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    mid: Option<String>,
    /// Edit timestamp (if message was edited).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    edited_at: Option<i64>,
    /// Message ID this is replying to (optional).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    reply_to: Option<String>,
    /// File attachment ID (optional).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    file_id: Option<String>,
    /// Reactions on this message (synced alongside the message).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    reactions: Vec<SyncReactionItem>,
}

// ---------------------------------------------------------------------------
// Multi-Peer Fan-Out Sync Coordinator (Phase 3.5)
// ---------------------------------------------------------------------------
//
// Instead of syncing every channel from one peer (ConnectionEstablished),
// the coordinator spreads channel sync across ALL available peers evenly.
//
// Flow:
// 1. ConnectionEstablished → register peer with coordinator
// 2. After 500ms collection window → assign channels to peers round-robin
// 3. Send lightweight ChannelSyncProbe to each assigned peer
// 4. Probe response: if timestamps differ → fire full ChannelSyncRequest
//    If timestamps match → skip (no new messages)
// 5. Result: parallel sync, spread evenly, zero wasted bandwidth

/// Tracks a server that needs sync after reconnection.
struct PendingServerSync {
    /// Peer IDs available for sync (connected members of this server).
    available_peers: Vec<PeerId>,
    /// Channels that need sync: (channel_id, our_latest_timestamp).
    channels: Vec<(String, i64)>,
    /// When the first peer for this server was registered.
    started_at: std::time::Instant,
    /// Whether we've already dispatched probes for this server.
    dispatched: bool,
}

/// Coordinates multi-peer fan-out sync across servers and channels.
struct SyncCoordinator {
    /// Servers waiting for sync: server_id → PendingServerSync.
    pending: HashMap<String, PendingServerSync>,
    /// How long to wait after first peer connects before dispatching probes.
    /// Allows more peers to connect, giving us better spread.
    collection_window: Duration,
}

impl SyncCoordinator {
    fn new() -> Self {
        Self {
            pending: HashMap::new(),
            collection_window: Duration::from_millis(500),
        }
    }

    /// Register a newly connected peer for a server's sync.
    /// Called from ConnectionEstablished instead of directly sending sync requests.
    fn register_peer(
        &mut self,
        server_id: &str,
        peer: PeerId,
        channels_with_timestamps: Vec<(String, i64)>,
    ) {
        let entry = self.pending.entry(server_id.to_string()).or_insert_with(|| {
            PendingServerSync {
                available_peers: Vec::new(),
                channels: channels_with_timestamps.clone(),
                started_at: std::time::Instant::now(),
                dispatched: false,
            }
        });
        if !entry.available_peers.contains(&peer) {
            entry.available_peers.push(peer);
        }
        // Update channels if this registration provides more channels
        // (e.g., server state updated between connections).
        if entry.channels.len() < channels_with_timestamps.len() {
            entry.channels = channels_with_timestamps;
        }
    }

    /// Check which servers are ready to dispatch (collection window elapsed).
    /// Returns: Vec<(server_id, assignments)> where assignments = Vec<(peer_id, Vec<(channel_id, our_latest)>)>
    fn collect_ready(&mut self) -> Vec<(String, Vec<(PeerId, Vec<(String, i64)>)>)> {
        let now = std::time::Instant::now();
        let mut ready = Vec::new();

        for (server_id, sync) in self.pending.iter_mut() {
            if sync.dispatched {
                continue;
            }
            if now.duration_since(sync.started_at) >= self.collection_window
                && !sync.available_peers.is_empty()
                && !sync.channels.is_empty()
            {
                sync.dispatched = true;

                // Assign channels to peers using round-robin.
                // Each channel gets assigned to up to 2 peers (primary + backup)
                // for redundancy, unless we have very few peers.
                let peers = &sync.available_peers;
                let peer_count = peers.len();
                let use_backup = peer_count >= 3; // Only use backup peers if we have enough

                let mut assignments: HashMap<PeerId, Vec<(String, i64)>> = HashMap::new();

                for (i, (cid, ts)) in sync.channels.iter().enumerate() {
                    // Primary peer: round-robin by channel index
                    let primary_idx = i % peer_count;
                    assignments
                        .entry(peers[primary_idx])
                        .or_default()
                        .push((cid.clone(), *ts));

                    // Backup peer: offset by half the peer count for maximum spread
                    if use_backup {
                        let backup_idx = (i + peer_count / 2 + 1) % peer_count;
                        if backup_idx != primary_idx {
                            assignments
                                .entry(peers[backup_idx])
                                .or_default()
                                .push((cid.clone(), *ts));
                        }
                    }
                }

                let assignment_vec: Vec<(PeerId, Vec<(String, i64)>)> =
                    assignments.into_iter().collect();
                ready.push((server_id.clone(), assignment_vec));
            }
        }

        ready
    }

    /// Remove completed servers from the pending map.
    fn remove_server(&mut self, server_id: &str) {
        self.pending.remove(server_id);
    }

    /// Check if any servers are pending dispatch.
    fn has_pending(&self) -> bool {
        self.pending.values().any(|s| !s.dispatched)
    }

    /// Clean up dispatched entries older than 30 seconds (sync should be done by then).
    fn cleanup_stale(&mut self) {
        let now = std::time::Instant::now();
        self.pending.retain(|_, sync| {
            if sync.dispatched {
                now.duration_since(sync.started_at) < Duration::from_secs(30)
            } else {
                true
            }
        });
    }
}

/// JSON codec for the Haven v2 protocol.
#[derive(Debug, Clone, Default)]
struct HavenCodec;

impl request_response::Codec for HavenCodec {
    type Protocol = &'static str;
    type Request = HavenMessage;
    type Response = HavenMessage;

    fn read_request<'life0, 'life1, 'life2, 'async_trait, T>(
        &'life0 mut self,
        _protocol: &'life1 Self::Protocol,
        io: &'life2 mut T,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = io::Result<Self::Request>> + Send + 'async_trait>>
    where
        T: libp2p::futures::AsyncRead + Unpin + Send + 'async_trait,
        'life0: 'async_trait,
        'life1: 'async_trait,
        'life2: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move {
            // SECURITY: Cap message size to 50MB to prevent OOM from malicious peers.
            let mut buf = Vec::new();
            let mut limited = libp2p::futures::AsyncReadExt::take(io, 50 * 1024 * 1024);
            libp2p::futures::AsyncReadExt::read_to_end(&mut limited, &mut buf).await?;
            serde_json::from_slice(&buf)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
        })
    }

    fn read_response<'life0, 'life1, 'life2, 'async_trait, T>(
        &'life0 mut self,
        _protocol: &'life1 Self::Protocol,
        io: &'life2 mut T,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = io::Result<Self::Response>> + Send + 'async_trait>>
    where
        T: libp2p::futures::AsyncRead + Unpin + Send + 'async_trait,
        'life0: 'async_trait,
        'life1: 'async_trait,
        'life2: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move {
            // SECURITY: Cap message size to 50MB to prevent OOM from malicious peers.
            let mut buf = Vec::new();
            let mut limited = libp2p::futures::AsyncReadExt::take(io, 50 * 1024 * 1024);
            libp2p::futures::AsyncReadExt::read_to_end(&mut limited, &mut buf).await?;
            serde_json::from_slice(&buf)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
        })
    }

    fn write_request<'life0, 'life1, 'life2, 'async_trait, T>(
        &'life0 mut self,
        _protocol: &'life1 Self::Protocol,
        io: &'life2 mut T,
        req: Self::Request,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = io::Result<()>> + Send + 'async_trait>>
    where
        T: libp2p::futures::AsyncWrite + Unpin + Send + 'async_trait,
        'life0: 'async_trait,
        'life1: 'async_trait,
        'life2: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move {
            let bytes = serde_json::to_vec(&req)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
            libp2p::futures::AsyncWriteExt::write_all(io, &bytes).await?;
            libp2p::futures::AsyncWriteExt::close(io).await?;
            Ok(())
        })
    }

    fn write_response<'life0, 'life1, 'life2, 'async_trait, T>(
        &'life0 mut self,
        _protocol: &'life1 Self::Protocol,
        io: &'life2 mut T,
        res: Self::Response,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = io::Result<()>> + Send + 'async_trait>>
    where
        T: libp2p::futures::AsyncWrite + Unpin + Send + 'async_trait,
        'life0: 'async_trait,
        'life1: 'async_trait,
        'life2: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move {
            let bytes = serde_json::to_vec(&res)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
            libp2p::futures::AsyncWriteExt::write_all(io, &bytes).await?;
            libp2p::futures::AsyncWriteExt::close(io).await?;
            Ok(())
        })
    }
}

// -- Prekey bundle types for async key exchange via DHT --

const PREKEY_BATCH_SIZE: usize = 10;
const PREKEY_REPUBLISH_SECS: u64 = 240; // 4 minutes

/// A prekey bundle published to the Kademlia DHT for async key exchange.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct PrekeyBundle {
    peer_id: String,
    identity_key: String,
    one_time_keys: Vec<String>,
    timestamp: u64,
    public_key: String,  // Ed25519 public key as base64 protobuf
    signature: String,
}

/// Build the canonical string that gets signed/verified for a prekey bundle.
fn prekey_signing_payload(
    peer_id: &str,
    identity_key: &str,
    otks: &[String],
    timestamp: u64,
) -> String {
    let otks_joined = otks.join(",");
    format!("haven-prekeys:{peer_id}:{identity_key}:{otks_joined}:{timestamp}")
}

/// Verify a prekey bundle's authenticity: signature, PeerId match, freshness, non-empty OTKs.
fn verify_prekey_bundle(bundle: &PrekeyBundle) -> Result<bool, String> {
    // Decode the Ed25519 public key from base64 protobuf.
    let pub_key_bytes = base64::engine::general_purpose::STANDARD
        .decode(&bundle.public_key)
        .map_err(|e| format!("Invalid public key base64: {e}"))?;

    let public_key = identity::PublicKey::try_decode_protobuf(&pub_key_bytes)
        .map_err(|e| format!("Invalid public key protobuf: {e}"))?;

    // Verify the PeerId matches the public key.
    let expected_peer_id = PeerId::from_public_key(&public_key);
    let claimed_peer_id: PeerId = bundle.peer_id.parse()
        .map_err(|e| format!("Invalid peer_id: {e}"))?;
    if expected_peer_id != claimed_peer_id {
        return Ok(false);
    }

    // Verify the Ed25519 signature over the canonical payload.
    let payload = prekey_signing_payload(
        &bundle.peer_id, &bundle.identity_key, &bundle.one_time_keys, bundle.timestamp,
    );
    let sig_bytes = base64::engine::general_purpose::STANDARD
        .decode(&bundle.signature)
        .map_err(|e| format!("Invalid signature base64: {e}"))?;

    if !public_key.verify(payload.as_bytes(), &sig_bytes) {
        return Ok(false);
    }

    // Check freshness (< 10 minutes).
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    if now.saturating_sub(bundle.timestamp) > 600 {
        return Ok(false);
    }

    if bundle.one_time_keys.is_empty() {
        return Ok(false);
    }

    Ok(true)
}

// -- Per-message Ed25519 signing helpers --

/// Build canonical payload for message signing.
/// Format: "haven-msg:{type}:{context}:{sender}:{ts}:{text}"
/// - Channel: type="ch", context="{sid}:{cid}"
/// - DM:      type="dm", context="{recipient_peer_id}"
fn message_signing_payload(
    msg_type: &str,
    context: &str,
    sender: &str,
    ts: i64,
    text: &str,
) -> String {
    format!("haven-msg:{msg_type}:{context}:{sender}:{ts}:{text}")
}

/// Sign a message payload with the local keypair.
/// Returns (signature_base64, public_key_base64).
fn sign_message(
    keypair: &identity::Keypair,
    pub_key_b64: &str,
    payload: &str,
) -> (Option<String>, Option<String>) {
    match keypair.sign(payload.as_bytes()) {
        Ok(sig) => {
            let sig_b64 = base64::engine::general_purpose::STANDARD.encode(&sig);
            (Some(sig_b64), Some(pub_key_b64.to_string()))
        }
        Err(e) => {
            hollow_log!("[HOLLOW-CRYPTO] Failed to sign message: {e}");
            (None, None)
        }
    }
}

/// Verify an Ed25519 signature on a message.
/// Checks: public key decodes, PeerId matches sender, signature is valid.
fn verify_message_signature(
    sender_peer_str: &str,
    sig_b64: Option<&str>,
    pk_b64: Option<&str>,
    payload: &str,
) -> bool {
    let (sig, pk) = match (sig_b64, pk_b64) {
        (Some(s), Some(p)) => (s, p),
        _ => return false,
    };

    let Ok(pk_bytes) = base64::engine::general_purpose::STANDARD.decode(pk) else {
        return false;
    };
    let Ok(public_key) = identity::PublicKey::try_decode_protobuf(&pk_bytes) else {
        return false;
    };

    // Verify PeerId matches the public key.
    let expected_pid = PeerId::from_public_key(&public_key);
    let Ok(claimed_pid) = sender_peer_str.parse::<PeerId>() else {
        return false;
    };
    if expected_pid != claimed_pid {
        return false;
    }

    // Verify the signature.
    let Ok(sig_bytes) = base64::engine::general_purpose::STANDARD.decode(sig) else {
        return false;
    };
    public_key.verify(payload.as_bytes(), &sig_bytes)
}

/// Publish our prekey bundle to the Kademlia DHT.
fn publish_prekey_bundle(
    swarm: &mut libp2p::Swarm<HavenBehaviour>,
    keypair: &identity::Keypair,
    peer_id_str: &str,
    pub_key_b64: &str,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
) -> Result<(), String> {
    let identity_key = olm.identity_key_base64();
    let one_time_keys = olm.generate_one_time_keys_batch(PREKEY_BATCH_SIZE);
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| format!("Clock error: {e}"))?
        .as_secs();

    let payload_str = prekey_signing_payload(peer_id_str, &identity_key, &one_time_keys, timestamp);
    let signature = keypair
        .sign(payload_str.as_bytes())
        .map_err(|e| format!("Signing failed: {e}"))?;
    let sig_b64 = base64::engine::general_purpose::STANDARD.encode(&signature);

    let bundle = PrekeyBundle {
        peer_id: peer_id_str.to_string(),
        identity_key,
        one_time_keys,
        timestamp,
        public_key: pub_key_b64.to_string(),
        signature: sig_b64,
    };

    let value = serde_json::to_vec(&bundle)
        .map_err(|e| format!("Failed to serialize bundle: {e}"))?;

    let record_key = kad::RecordKey::new(&format!("/hollow/prekeys/{}", peer_id_str));
    let record = kad::Record {
        key: record_key,
        value,
        publisher: None,
        expires: None,
    };

    swarm.behaviour_mut().kademlia
        .put_record(record, kad::Quorum::One)
        .map_err(|e| format!("DHT put_record failed: {e}"))?;

    // Persist account state (OTKs were consumed).
    if let Ok(account_json) = olm.account_pickle_json() {
        crypto_store.save_account(account_json);
    }

    Ok(())
}

/// Our libp2p network behaviour — mDNS discovery + encrypted messaging + DHT + NAT traversal.
#[derive(libp2p::swarm::NetworkBehaviour)]
struct HavenBehaviour {
    relay_client: relay::client::Behaviour,
    identify: identify::Behaviour,
    ping: ping::Behaviour,
    kademlia: kad::Behaviour<kad::store::MemoryStore>,
    autonat: autonat::Behaviour,
    dcutr: dcutr::Behaviour,
    mdns: mdns::tokio::Behaviour,
    messaging: request_response::Behaviour<HavenCodec>,
    file_streaming: request_response::Behaviour<super::stream_transfer::FileStreamCodec>,
}

/// Build and spawn the libp2p swarm. Returns the local peer ID and a join handle.
pub(crate) async fn spawn_node(
    keypair: identity::Keypair,
    event_tx: mpsc::Sender<NetworkEvent>,
    cmd_rx: mpsc::Receiver<NodeCommand>,
    olm: OlmManager,
    crypto_store: CryptoStore,
    proxy_enabled: bool,
) -> Result<(String, tokio::task::JoinHandle<()>), String> {
    // Clone keypair for signaling task (it needs to sign register requests).
    let sig_keypair = keypair.clone();
    // Clone keypair for prekey bundle signing in the swarm task.
    let bundle_keypair = keypair.clone();

    let swarm = SwarmBuilder::with_existing_identity(keypair)
        .with_tokio()
        .with_tcp(
            tcp::Config::default(),
            noise::Config::new,
            yamux::Config::default,
        )
        .map_err(|e| format!("TCP setup failed: {e}"))?
        .with_quic_config(|mut config| {
            config.handshake_timeout = Duration::from_secs(10);
            config
        })
        .with_dns()
        .map_err(|e| format!("DNS setup failed: {e}"))?
        .with_websocket(
            (tls::Config::new, noise::Config::new),
            yamux::Config::default,
        )
        .await
        .map_err(|e| format!("WebSocket setup failed: {e}"))?
        .with_relay_client(
            (tls::Config::new, noise::Config::new),
            yamux::Config::default,
        )
        .map_err(|e| format!("Relay client setup failed: {e}"))?
        .with_behaviour(|key, relay_client| {
            let local_peer_id = key.public().to_peer_id();

            let mdns_config = mdns::Config {
                ttl: Duration::from_secs(300),
                query_interval: Duration::from_secs(5),
                enable_ipv6: false,
            };
            let mdns = mdns::tokio::Behaviour::new(mdns_config, local_peer_id)
                .expect("Failed to create mDNS behaviour");

            let messaging = request_response::Behaviour::<HavenCodec>::new(
                [("/hollow/msg/2.0.0", ProtocolSupport::Full)],
                request_response::Config::default(),
            );

            // Streaming binary protocol for large file/shard transfers.
            // Separate from `messaging` — uses ordered substreams, no Olm ratchet.
            let file_streaming = request_response::Behaviour::<super::stream_transfer::FileStreamCodec>::new(
                [("/hollow/stream/1.0.0", ProtocolSupport::Full)],
                request_response::Config::default()
                    .with_request_timeout(Duration::from_secs(300)), // 5 min for large files
            );

            // Kademlia DHT (MemoryStore — records lost on restart, fine for Phase 2)
            let mut kademlia = kad::Behaviour::new(
                local_peer_id,
                kad::store::MemoryStore::new(local_peer_id),
            );
            kademlia.set_mode(Some(kad::Mode::Server));

            // AutoNAT — probes other peers to discover our public address
            let autonat = autonat::Behaviour::new(
                local_peer_id,
                autonat::Config::default(),
            );

            // DCUtR — hole punching via relay-assisted coordination
            let dcutr = dcutr::Behaviour::new(local_peer_id);

            // Identify — required for relay protocol to work.
            let identify = identify::Behaviour::new(identify::Config::new(
                "/hollow/1.0.0".to_string(),
                key.public(),
            ));

            let ping = ping::Behaviour::new(
                ping::Config::new()
                    .with_interval(Duration::from_secs(5))
                    .with_timeout(Duration::from_secs(5)),
            );

            Ok(HavenBehaviour {
                relay_client,
                identify,
                ping,
                kademlia,
                autonat,
                dcutr,
                mdns,
                messaging,
                file_streaming,
            })
        })
        .map_err(|e| format!("Behaviour setup failed: {e}"))?
        .with_swarm_config(|cfg| {
            cfg.with_idle_connection_timeout(Duration::from_secs(u64::MAX))
        })
        .build();

    let peer_id_str = swarm.local_peer_id().to_string();

    // Start Shadowsocks tunnels if proxy mode is enabled.
    let tunnel_handles = if proxy_enabled {
        hollow_log!("[HOLLOW] [PROXY] Proxy mode enabled, starting Shadowsocks tunnels...");
        let handles = super::tunnel::start_tunnels().await?;
        // Brief delay to ensure tunnels are listening before libp2p dials.
        tokio::time::sleep(Duration::from_millis(300)).await;
        Some(handles)
    } else {
        None
    };

    // Spawn the signaling background task.
    let (sig_cmd_tx, sig_event_rx) =
        signaling::spawn_signaling_task(sig_keypair, peer_id_str.clone(), proxy_enabled);

    let handle = tokio::spawn(run_swarm(
        swarm, event_tx, cmd_rx, olm, crypto_store, sig_cmd_tx, sig_event_rx,
        bundle_keypair, proxy_enabled, tunnel_handles,
    ));

    Ok((peer_id_str, handle))
}

/// The main swarm event loop. Runs until the task is aborted.
async fn run_swarm(
    mut swarm: libp2p::Swarm<HavenBehaviour>,
    event_tx: mpsc::Sender<NetworkEvent>,
    mut cmd_rx: mpsc::Receiver<NodeCommand>,
    mut olm: OlmManager,
    crypto_store: CryptoStore,
    sig_cmd_tx: mpsc::Sender<SignalingCmd>,
    mut sig_event_rx: mpsc::Receiver<SignalingEvent>,
    bundle_keypair: identity::Keypair,
    proxy_enabled: bool,
    tunnel_handles: Option<Vec<tokio::task::JoinHandle<()>>>,
) {
    // Precompute public key base64 for prekey bundle signing.
    let pub_key_proto = bundle_keypair.public().encode_protobuf();
    let pub_key_b64 = base64::engine::general_purpose::STANDARD.encode(&pub_key_proto);

    // Listen on all interfaces — TCP and QUIC, random ports.
    let tcp_addr: Multiaddr = "/ip4/0.0.0.0/tcp/0".parse().unwrap();
    if let Err(e) = swarm.listen_on(tcp_addr) {
        let _ = event_tx
            .send(NetworkEvent::Error {
                message: format!("Failed to listen (TCP): {e}"),
            })
            .await;
        return;
    }

    let quic_addr: Multiaddr = "/ip4/0.0.0.0/udp/0/quic-v1".parse().unwrap();
    if let Err(e) = swarm.listen_on(quic_addr) {
        let _ = event_tx
            .send(NetworkEvent::Error {
                message: format!("Failed to listen (QUIC): {e}"),
            })
            .await;
        // QUIC failure is non-fatal — TCP still works as fallback.
    }

    // Dial the relay node and request a reservation (for NAT traversal).
    if let Some(relay_pid) = relay_peer_id() {
        let _ = event_tx
            .send(NetworkEvent::Error {
                message: format!("[DEBUG] Dialing relay {relay_pid}..."),
            })
            .await;
        for addr in proxy_aware_relay_addrs(proxy_enabled) {
            let _ = event_tx
                .send(NetworkEvent::Error {
                    message: format!("[DEBUG] Relay addr: {addr}"),
                })
                .await;
            swarm.add_peer_address(relay_pid, addr.clone());
            swarm.behaviour_mut().kademlia.add_address(&relay_pid, addr);
        }
        let _ = event_tx.send(NetworkEvent::RelayStatusChanged {
            status: "connecting".to_string(),
        }).await;
        if let Err(e) = swarm.dial(relay_pid) {
            let _ = event_tx
                .send(NetworkEvent::Error {
                    message: format!("Failed to dial relay: {e}"),
                })
                .await;
        }
        // NOTE: listen_on for the relay circuit is deferred to
        // ConnectionEstablished — calling it before the relay is
        // connected causes libp2p to immediately close the listener.
    } else {
        let _ = event_tx
            .send(NetworkEvent::Error {
                message: "[DEBUG] No relay configured!".to_string(),
            })
            .await;
    }

    // Decrypt failure cooldown: track last session-kill time per peer.
    // Prevents rapid session thrashing when many in-flight chunks fail decrypt
    // (e.g., 340MB file = 1360 chunks, all fail after session reset).
    let mut decrypt_fail_cooldown: HashMap<String, std::time::Instant> = HashMap::new();
    const REKEY_COOLDOWN: Duration = Duration::from_secs(5);

    // Track outbound request IDs → peer for delivery confirmation.
    let mut pending_requests = HashMap::<request_response::OutboundRequestId, String>::new();

    // Buffer messages while key exchange is in progress.
    let mut pending_messages: HashMap<String, Vec<String>> = HashMap::new();

    // Track which peers have an active key request in flight (avoid duplicate requests).
    let mut key_request_in_flight: std::collections::HashSet<String> = std::collections::HashSet::new();

    // Track our own listen addresses for signaling registration.
    let mut known_addresses: Vec<String> = Vec::new();

    // Track the active room code so we can re-bootstrap after getting a relay circuit address.
    let mut active_room: Option<String> = None;

    // Prekey bundle republish timer (4 min interval).
    let mut prekey_timer = tokio::time::interval(Duration::from_secs(PREKEY_REPUBLISH_SECS));
    prekey_timer.tick().await; // consume immediate first tick
    let mut prekey_published = false;

    // Track pending DHT prekey fetches: query_id → target peer_id string.
    let mut pending_prekey_fetches: HashMap<kad::QueryId, String> = HashMap::new();
    // Peers for whom a DHT prekey fetch is in flight.
    let mut dht_fetch_in_flight: std::collections::HashSet<String> = std::collections::HashSet::new();

    // Track the original message text for outbound encrypted messages so we can
    // re-queue on delivery failure. Maps request_id → (peer_id_str, text).
    let mut outbound_message_text: HashMap<request_response::OutboundRequestId, (String, String)> = HashMap::new();

    // Track which peers have active connections (excludes relay node).
    let mut connected_peers: std::collections::HashSet<PeerId> = std::collections::HashSet::new();

    // Track peers we expect (discovered via signaling, mDNS, or relay inbound circuit).
    // ConnectionEstablished only emits PeerDiscovered for peers in this set,
    // preventing Kademlia routing connections from polluting the peer list.
    let mut expected_peers: std::collections::HashSet<PeerId> = std::collections::HashSet::new();

    // Debounce PeerDisconnected events. When a connection closes with remaining=0,
    // don't emit immediately — wait 2s. If ConnectionEstablished fires for the same
    // peer within that window, cancel the disconnect. This prevents rapid
    // add/remove/add UI churn when libp2p upgrades transports.
    let mut pending_disconnects: HashMap<PeerId, std::time::Instant> = HashMap::new();
    const DISCONNECT_DEBOUNCE: Duration = Duration::from_secs(2);

    // Track peers we've already emitted PeerDiscovered for this session.
    // Prevents flooding the UI with duplicate discovery events from multiple
    // signaling rooms, bootstrap responses, or InboundCircuitEstablished events.
    let mut discovered_peers: std::collections::HashSet<PeerId> = std::collections::HashSet::new();

    // Track peers that disconnected. Prevents ghost peers: if signaling
    // returns a stale peer we already tried and failed, skip it.
    // Cleared on room switch, removed on successful ConnectionEstablished.
    // Track disconnected peers with the time they disconnected.
    // Peers stay here for at least DISCONNECT_COOLDOWN to prevent ghost
    // re-discovery from stale signaling entries.
    let mut disconnected_peers: HashMap<PeerId, std::time::Instant> = HashMap::new();
    const DISCONNECT_COOLDOWN: Duration = Duration::from_secs(180); // 3 min = signaling stale threshold

    // -- Vault shard assembly state (Phase 4) --
    // Tracks chunked shard reassembly. Key = "content_id:shard_index:sender_peer".
    let mut pending_shard_assembly: HashMap<String, PendingShardAssembly> = HashMap::new();

    // -- Pending stream transfer state --
    let mut pending_file_streams: HashMap<String, PendingFileStream> = HashMap::new();
    let mut pending_shard_streams: HashMap<String, PendingShardStream> = HashMap::new();

    // Pending vault downloads waiting for remote shards.
    // Key: content_id, Value: (server_id, shards_needed: k, shards_requested: count)
    let mut pending_vault_downloads: HashMap<String, (String, usize, usize)> = HashMap::new();

    // -- CRDT state (Phase 3) --
    // Server states keyed by server_id. Reload from DB so servers survive restarts.
    let mut server_states: HashMap<String, ServerState> = HashMap::new();
    {
        let data_dir = crate::identity::data_dir().unwrap_or_default();
        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
            match store.load_all_servers() {
                Ok(rows) => {
                    for (server_id, json) in rows {
                        match serde_json::from_str::<ServerState>(&json) {
                            Ok(mut state) => {
                                state.set_hlc(Hlc::new(swarm.local_peer_id().to_string()));
                                server_states.insert(server_id, state);
                            }
                            Err(e) => {
                                hollow_log!("Failed to deserialize server {}: {}", server_id, e);
                            }
                        }
                    }
                    if !server_states.is_empty() {
                        hollow_log!("Loaded {} server(s) from DB", server_states.len());
                    }
                }
                Err(e) => {
                    hollow_log!("Failed to load servers from DB: {}", e);
                }
            }
        }
    }

    // -- MLS state --
    let local_peer_str = swarm.local_peer_id().to_string();
    let mut mls: Option<MlsManager> = {
        let data_dir = crate::identity::data_dir().unwrap_or_default();
        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
            match store.load_mls_identity() {
                Ok(Some((signer_data, credential_data, storage_data))) => {
                    let server_ids: Vec<String> = server_states.keys().cloned().collect();
                    match MlsManager::from_persisted(
                        &signer_data,
                        &credential_data,
                        storage_data.as_deref(),
                        &server_ids,
                    ) {
                        Ok(mgr) => {
                            hollow_log!("[HOLLOW-MLS] Restored MLS identity from DB");
                            Some(mgr)
                        }
                        Err(e) => {
                            hollow_log!("[HOLLOW-MLS] Failed to restore MLS identity: {e}");
                            None
                        }
                    }
                }
                Ok(None) => None,
                Err(e) => {
                    hollow_log!("[HOLLOW-MLS] Failed to load MLS identity: {e}");
                    None
                }
            }
        } else {
            None
        }
    };
    // Create MLS identity if none exists.
    if mls.is_none() {
        match MlsManager::new(&local_peer_str) {
            Ok(mgr) => {
                hollow_log!("[HOLLOW-MLS] Created new MLS identity");
                // Persist immediately.
                if let Ok(signer) = mgr.signer_bytes() {
                    if let Ok(cred) = mgr.credential_bytes() {
                        if let Ok(storage) = mgr.serialize_storage() {
                            let data_dir = crate::identity::data_dir().unwrap_or_default();
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                let _ = store.save_mls_identity(&signer, &cred, &storage);
                            }
                        }
                    }
                }
                mls = Some(mgr);
            }
            Err(e) => {
                hollow_log!("[HOLLOW-MLS] Failed to create MLS identity: {e}");
            }
        }
    }

    // Track server_ids we're trying to join (waiting for SyncResponse from existing members).
    let mut pending_server_joins: std::collections::HashSet<String> = std::collections::HashSet::new();

    // Track failed sync requests per peer — retried after session re-establishment.
    // Maps peer_id_str → Vec<(server_id, channel_id, since_timestamp)>
    let mut pending_sync_requests: HashMap<String, Vec<(String, String, i64)>> = HashMap::new();

    // Track server_ids for which we've already requested MLS bootstrap (KeyPackage sent to owner).
    // Prevents spamming the owner on every MlsChannelMessage for an unknown group.
    let mut mls_bootstrap_requested: std::collections::HashSet<String> = std::collections::HashSet::new();

    // MLS batch addition queue: collect KeyPackages and process them in a single commit.
    let mut pending_mls_key_packages: HashMap<String, Vec<(String, Vec<u8>)>> = HashMap::new();
    let mut mls_batch_timer = tokio::time::interval(Duration::from_secs(2));
    mls_batch_timer.tick().await; // consume immediate first tick

    // MLS decrypt failure counter per server — triggers recovery after 3 consecutive failures.
    let mut mls_decrypt_failures: HashMap<String, u32> = HashMap::new();

    // Multi-peer fan-out sync coordinator.
    // Collects connected peers for 500ms, then assigns channels evenly across peers.
    let mut sync_coordinator = SyncCoordinator::new();

    // Sync coordinator dispatch timer (100ms tick — checks if collection window has elapsed).
    let mut sync_dispatch_timer = tokio::time::interval(Duration::from_millis(100));
    sync_dispatch_timer.tick().await; // consume immediate first tick

    // SECURITY: Per-peer rate limiter — token bucket (100 burst, refill 20/sec).
    // Prevents message flooding from malicious peers.
    let mut peer_rate_tokens: HashMap<PeerId, (u32, std::time::Instant)> = HashMap::new();
    const RATE_LIMIT_BURST: u32 = 100;
    const RATE_LIMIT_REFILL: u32 = 20; // tokens per second

    // Re-bootstrap timer (30 seconds) for mutual peer discovery.
    // Fires unconditionally — BootstrapPeers handler skips connected
    // and disconnected peers, so only genuinely new peers get processed.
    let mut rebootstrap_timer = tokio::time::interval(Duration::from_secs(30));
    rebootstrap_timer.tick().await; // consume immediate first tick

    // Relay health check timer (60 seconds). Detects dropped relay connections
    // and re-dials to restore circuit-based reachability.
    let mut relay_health_timer = tokio::time::interval(Duration::from_secs(60));
    relay_health_timer.tick().await; // consume immediate first tick

    // Debounce timer for pending disconnects (500ms check interval).
    let mut disconnect_debounce_timer = tokio::time::interval(Duration::from_millis(500));
    disconnect_debounce_timer.tick().await; // consume immediate first tick

    // Vault rebalance + retention enforcement timer (30 min).
    let mut rebalance_timer = tokio::time::interval(Duration::from_secs(1800));
    rebalance_timer.tick().await; // consume immediate first tick

    // Stream transfer progress poll timer (500ms) — emits FileProgress events
    // to Dart based on bytes received by the FileStreamCodec.
    let mut stream_progress_timer = tokio::time::interval(Duration::from_millis(500));
    stream_progress_timer.tick().await; // consume immediate first tick

    loop {
        tokio::select! {
            // Handle commands from the FFI layer.
            Some(cmd) = cmd_rx.recv() => {
                match cmd {
                    NodeCommand::JoinRoom { room_code } => {
                        // If switching rooms, unregister from the old room and clear state.
                        if let Some(old_room) = active_room.as_ref().filter(|r| *r != &room_code) {
                            let _ = sig_cmd_tx.send(SignalingCmd::Unregister {
                                room_code: old_room.clone(),
                            }).await;
                            let _ = event_tx.send(NetworkEvent::RoomCleared).await;
                            connected_peers.clear();
                            expected_peers.clear();
                            disconnected_peers.clear();
                            discovered_peers.clear();
                            pending_disconnects.clear();
                        }
                        active_room = Some(room_code.clone());
                        // Register ourselves and bootstrap from the signaling service.
                        // Filter out loopback/link-local/private — only send routable addresses.
                        let addrs: Vec<String> = known_addresses.iter()
                            .filter(|a| is_registerable_address(a))
                            .cloned()
                            .collect();
                        // Only register if we have routable addresses.
                        // If empty (relay circuit not yet established), the
                        // UpdateAddresses flow will register us once it is.
                        if !addrs.is_empty() {
                            let _ = sig_cmd_tx.send(SignalingCmd::Register {
                                room_code: room_code.clone(),
                                addresses: addrs,
                            }).await;
                        }
                        // Always store the room code so UpdateAddresses can
                        // register later, and always bootstrap to find peers.
                        let _ = sig_cmd_tx.send(SignalingCmd::SetRoom {
                            room_code: room_code.clone(),
                        }).await;
                        let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
                            room_code,
                        }).await;
                    }
                    NodeCommand::SendMessage { peer_id, text, message_id, reply_to_mid } => {
                        let peer_id_str = peer_id.to_string();
                        hollow_log!("[HOLLOW-SWARM] SendMessage received for {peer_id_str} mid={message_id}");

                        // Wrap DM in signed envelope.
                        let local_peer = swarm.local_peer_id().to_string();
                        let dm_timestamp = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as i64;
                        let signing_payload = message_signing_payload(
                            "dm", &peer_id_str, &local_peer, dm_timestamp, &text,
                        );
                        let (sig, pk) = sign_message(&bundle_keypair, &pub_key_b64, &signing_payload);
                        let envelope = MessageEnvelope::DirectMessage {
                            text: text.clone(),
                            ts: dm_timestamp,
                            sig: sig.clone(),
                            pk: pk.clone(),
                            mid: Some(message_id.clone()),
                            reply_to: reply_to_mid.clone(),
                            file_id: None,
                        };
                        let envelope_json = serde_json::to_string(&envelope)
                            .unwrap_or_else(|_| text.clone());

                        // Persist sent DM locally with the same Rust-generated timestamp.
                        // This ensures DM sync timestamps are consistent (no Dart DateTime.now() mismatch).
                        {
                            let data_dir = crate::identity::data_dir().unwrap_or_default();
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                let _ = store.insert(
                                    &peer_id_str, &text, true, dm_timestamp,
                                    sig.as_deref(), pk.as_deref(), Some(&message_id),
                                    reply_to_mid.as_deref(), None,
                                );
                            }
                        }

                        if olm.has_session(&peer_id_str) {
                            // Session exists — encrypt and send.
                            send_encrypted_message(
                                &mut swarm,
                                &mut olm,
                                &crypto_store,
                                &mut pending_requests,
                                &mut outbound_message_text,
                                &peer_id,
                                &peer_id_str,
                                &envelope_json,
                                &event_tx,
                            ).await;
                        } else {
                            // No session — queue the signed envelope and try DHT prekey fetch first.
                            pending_messages
                                .entry(peer_id_str.clone())
                                .or_default()
                                .push(envelope_json);

                            if !key_request_in_flight.contains(&peer_id_str)
                                && !dht_fetch_in_flight.contains(&peer_id_str)
                            {
                                // Try DHT prekey fetch before falling back to KeyRequest.
                                hollow_log!("[HOLLOW-SWARM] No session for {peer_id_str}, starting DHT prekey fetch");
                                let record_key = kad::RecordKey::new(
                                    &format!("/hollow/prekeys/{}", peer_id_str),
                                );
                                let query_id = swarm.behaviour_mut().kademlia
                                    .get_record(record_key);
                                pending_prekey_fetches.insert(query_id, peer_id_str.clone());
                                dht_fetch_in_flight.insert(peer_id_str.clone());

                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: format!("[DHT] Fetching prekeys for {peer_id_str}"),
                                }).await;
                            }
                        }
                    }

                    NodeCommand::SendChannelMessage { server_id, channel_id, text, message_id, reply_to_mid } => {
                        hollow_log!("[HOLLOW-SWARM] SendChannelMessage for channel {channel_id} in server {server_id} mid={message_id}");

                        let server = match server_states.get(&server_id) {
                            Some(s) => s,
                            None => {
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: format!("Unknown server {server_id}"),
                                }).await;
                                continue;
                            }
                        };

                        let local_peer = swarm.local_peer_id().to_string();
                        let timestamp = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as i64;

                        // Sign the message before encryption.
                        let signing_payload = message_signing_payload(
                            "ch", &format!("{}:{}", server_id, channel_id),
                            &local_peer, timestamp, &text,
                        );
                        let (sig, pk) = sign_message(&bundle_keypair, &pub_key_b64, &signing_payload);

                        let envelope = MessageEnvelope::ChannelMessage {
                            sid: server_id.clone(),
                            cid: channel_id.clone(),
                            text: text.clone(),
                            ts: timestamp,
                            sig: sig.clone(),
                            pk: pk.clone(),
                            mid: Some(message_id.clone()),
                            reply_to: reply_to_mid.clone(),
                            file_id: None,
                        };
                        let envelope_json = serde_json::to_string(&envelope)
                            .unwrap_or_else(|_| text.clone());

                        // MLS path: encrypt once, send same ciphertext to all members.
                        let use_mls = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
                        if use_mls {
                            let mls_mgr = mls.as_mut().unwrap();
                            match mls_mgr.encrypt(&server_id, envelope_json.as_bytes()) {
                                Ok(ciphertext) => {
                                    let body_b64 = base64::engine::general_purpose::STANDARD.encode(&ciphertext);
                                    persist_mls_state(mls_mgr, &bundle_keypair);
                                    for member_peer_str in server.members.keys() {
                                        if member_peer_str == &local_peer { continue; }
                                        if let Ok(member_pid) = member_peer_str.parse::<PeerId>() {
                                            if connected_peers.contains(&member_pid) {
                                                swarm.behaviour_mut().messaging.send_request(
                                                    &member_pid,
                                                    HavenMessage::MlsChannelMessage {
                                                        server_id: server_id.clone(),
                                                        body: body_b64.clone(),
                                                    },
                                                );
                                            }
                                        }
                                    }
                                }
                                Err(e) => {
                                    hollow_log!("[HOLLOW-MLS] Encrypt failed, falling back to Olm: {e}");
                                    // Fall through to Olm path below.
                                    for member_peer_str in server.members.keys() {
                                        if member_peer_str == &local_peer { continue; }
                                        if let Ok(member_pid) = member_peer_str.parse::<PeerId>() {
                                            if connected_peers.contains(&member_pid) {
                                                send_encrypted_message(
                                                    &mut swarm, &mut olm, &crypto_store,
                                                    &mut pending_requests, &mut outbound_message_text,
                                                    &member_pid, member_peer_str, &envelope_json,
                                                    &event_tx,
                                                ).await;
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            // Legacy Olm fan-out path.
                            for member_peer_str in server.members.keys() {
                                if member_peer_str == &local_peer { continue; }
                                if let Ok(member_pid) = member_peer_str.parse::<PeerId>() {
                                    if connected_peers.contains(&member_pid) {
                                        send_encrypted_message(
                                            &mut swarm, &mut olm, &crypto_store,
                                            &mut pending_requests, &mut outbound_message_text,
                                            &member_pid, member_peer_str, &envelope_json,
                                            &event_tx,
                                        ).await;
                                    }
                                }
                            }
                        }

                        // Persist locally with same timestamp as sent.
                        let data_dir = crate::identity::data_dir().unwrap_or_default();
                        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                            let _ = store.insert_channel_message(
                                &server_id, &channel_id, &local_peer, &text, true, timestamp,
                                sig.as_deref(), pk.as_deref(), Some(&message_id),
                                reply_to_mid.as_deref(), None,
                            );
                        }
                    }

                    // -- CRDT commands (Phase 3) --

                    NodeCommand::CreateServer { name } => {
                        let local_peer = swarm.local_peer_id().to_string();
                        let server_id = hex::encode(&{
                            let mut buf = [0u8; 16];
                            getrandom::fill(&mut buf).expect("system RNG unavailable — cannot generate secure random bytes");
                            buf
                        });
                        hollow_log!("[HOLLOW-CRDT] Creating server '{name}' id={server_id}");

                        let mut state = ServerState::new(
                            server_id.clone(),
                            name.clone(),
                            local_peer.clone(),
                        );

                        // Create the initial ServerCreated op and apply it
                        let op = state.create_op(CrdtPayload::ServerCreated {
                            name: name.clone(),
                            owner_peer_id: local_peer,
                        });
                        let _ = state.apply_op(&op);

                        // Persist
                        if let Ok(json) = serde_json::to_string(&state) {
                            // Save via direct DB call (initial creation)
                            let _ = event_tx.send(NetworkEvent::Error {
                                message: format!("[CRDT] Server state saved: {server_id}"),
                            }).await;
                            // We'll persist through the storage API
                            let data_dir = crate::identity::data_dir().unwrap_or_default();
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                let _ = store.save_server_state(&server_id, &json);
                                let _ = store.insert_crdt_op(&op);
                            }
                        }

                        server_states.insert(server_id.clone(), state);

                        // Auto-pledge default storage (512 MB) for the owner
                        if let Some(state) = server_states.get_mut(&server_id) {
                            let owner_peer = swarm.local_peer_id().to_string();
                            let default_pledge = 512u64 * 1024 * 1024;
                            let pledge_op = state.create_op(CrdtPayload::StoragePledgeChanged {
                                peer_id: owner_peer,
                                pledge_bytes: default_pledge,
                            });
                            let _ = state.apply_op(&pledge_op);

                            // Re-persist with pledge included
                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = crate::identity::data_dir().unwrap_or_default();
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let _ = store.save_server_state(&server_id, &json);
                                    let _ = store.insert_crdt_op(&pledge_op);
                                }
                            }
                        }

                        // Create MLS group for this server (owner is sole member).
                        if let Some(ref mut mls_mgr) = mls {
                            match mls_mgr.create_group(&server_id) {
                                Ok(()) => persist_mls_state(mls_mgr, &bundle_keypair),
                                Err(e) => hollow_log!("[HOLLOW-MLS] Failed to create MLS group: {e}"),
                            }
                        }

                        let _ = event_tx.send(NetworkEvent::ServerCreated {
                            server_id: server_id.clone(),
                            name,
                        }).await;

                        // Register in signaling room for this server so joiners can discover us.
                        let reg_addrs: Vec<String> = known_addresses.iter()
                            .filter(|a| is_registerable_address(a))
                            .cloned()
                            .collect();
                        if !reg_addrs.is_empty() {
                            let _ = sig_cmd_tx.send(SignalingCmd::Register {
                                room_code: server_id.clone(),
                                addresses: reg_addrs,
                            }).await;
                        }

                        // No broadcast needed for CreateServer — the server only has
                        // one member (the creator) at this point. New members will
                        // receive full state via SyncResponse when they join.
                    }

                    NodeCommand::CreateChannel { server_id, name, category } => {
                        if let Some(state) = server_states.get_mut(&server_id) {
                            let local_peer = swarm.local_peer_id().to_string();
                            if !state.has_permission(&local_peer, Permission::MANAGE_CHANNELS) {
                                hollow_log!("[HOLLOW-CRDT] Permission denied: cannot create channel in {server_id}");
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: "Permission denied: cannot manage channels".to_string(),
                                }).await;
                                continue;
                            }
                            let channel_id = format!("{}-{}", &server_id[..8.min(server_id.len())], hex::encode(&{
                                let mut buf = [0u8; 4];
                                getrandom::fill(&mut buf).expect("system RNG unavailable — cannot generate secure random bytes");
                                buf
                            }));
                            hollow_log!("[HOLLOW-CRDT] Creating channel '{name}' id={channel_id} in server {server_id}");

                            let op = state.create_op(CrdtPayload::ChannelAdded {
                                channel_id: channel_id.clone(),
                                name: name.clone(),
                                category: category.clone(),
                            });
                            let _ = state.apply_op(&op);

                            // Persist
                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = crate::identity::data_dir().unwrap_or_default();
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let _ = store.save_server_state(&server_id, &json);
                                    let _ = store.insert_crdt_op(&op);
                                }
                            }

                            let _ = event_tx.send(NetworkEvent::ChannelAdded {
                                server_id: server_id.clone(),
                                channel_id,
                                name,
                            }).await;

                            // Broadcast to connected server members only.
                            if let Ok(op_json) = serde_json::to_string(&op) {
                                let local_peer = swarm.local_peer_id().to_string();
                                for member_peer_str in state.members.keys() {
                                    if member_peer_str == &local_peer { continue; }
                                    if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                        if connected_peers.contains(&pid) {
                                            swarm.behaviour_mut().messaging.send_request(
                                                &pid,
                                                HavenMessage::CrdtOpBroadcast {
                                                    server_id: server_id.clone(),
                                                    op_json: op_json.clone(),
                                                },
                                            );
                                        }
                                    }
                                }
                            }
                        } else {
                            let _ = event_tx.send(NetworkEvent::Error {
                                message: format!("[CRDT] Server {server_id} not found"),
                            }).await;
                        }
                    }

                    NodeCommand::RemoveChannel { server_id, channel_id } => {
                        if let Some(state) = server_states.get_mut(&server_id) {
                            let local_peer = swarm.local_peer_id().to_string();
                            if !state.has_permission(&local_peer, Permission::MANAGE_CHANNELS) {
                                hollow_log!("[HOLLOW-CRDT] Permission denied: cannot remove channel in {server_id}");
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: "Permission denied: cannot manage channels".to_string(),
                                }).await;
                                continue;
                            }
                            hollow_log!("[HOLLOW-CRDT] Removing channel {channel_id} from server {server_id}");

                            let op = state.create_op(CrdtPayload::ChannelRemoved {
                                channel_id: channel_id.clone(),
                            });
                            let _ = state.apply_op(&op);

                            // Persist
                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = crate::identity::data_dir().unwrap_or_default();
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let _ = store.save_server_state(&server_id, &json);
                                    let _ = store.insert_crdt_op(&op);
                                }
                            }

                            let _ = event_tx.send(NetworkEvent::ChannelRemoved {
                                server_id: server_id.clone(),
                                channel_id,
                            }).await;

                            // Broadcast to connected server members only.
                            if let Ok(op_json) = serde_json::to_string(&op) {
                                let local_peer = swarm.local_peer_id().to_string();
                                for member_peer_str in state.members.keys() {
                                    if member_peer_str == &local_peer { continue; }
                                    if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                        if connected_peers.contains(&pid) {
                                            swarm.behaviour_mut().messaging.send_request(
                                                &pid,
                                                HavenMessage::CrdtOpBroadcast {
                                                    server_id: server_id.clone(),
                                                    op_json: op_json.clone(),
                                                },
                                            );
                                        }
                                    }
                                }
                            }
                        }
                    }

                    NodeCommand::RenameServer { server_id, new_name } => {
                        if let Some(state) = server_states.get_mut(&server_id) {
                            let local_peer = swarm.local_peer_id().to_string();
                            if !state.has_permission(&local_peer, Permission::MANAGE_SERVER) {
                                hollow_log!("[HOLLOW-CRDT] Permission denied: cannot rename server {server_id}");
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: "Permission denied: cannot manage server".to_string(),
                                }).await;
                                continue;
                            }
                            hollow_log!("[HOLLOW-CRDT] Renaming server {server_id} to '{new_name}'");

                            let op = state.create_op(CrdtPayload::ServerRenamed {
                                new_name: new_name.clone(),
                            });
                            let _ = state.apply_op(&op);

                            // Persist
                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = crate::identity::data_dir().unwrap_or_default();
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let _ = store.save_server_state(&server_id, &json);
                                    let _ = store.insert_crdt_op(&op);
                                }
                            }

                            let _ = event_tx.send(NetworkEvent::ServerUpdated {
                                server_id: server_id.clone(),
                            }).await;

                            // Broadcast to connected server members only.
                            if let Ok(op_json) = serde_json::to_string(&op) {
                                let local_peer = swarm.local_peer_id().to_string();
                                for member_peer_str in state.members.keys() {
                                    if member_peer_str == &local_peer { continue; }
                                    if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                        if connected_peers.contains(&pid) {
                                            swarm.behaviour_mut().messaging.send_request(
                                                &pid,
                                                HavenMessage::CrdtOpBroadcast {
                                                    server_id: server_id.clone(),
                                                    op_json: op_json.clone(),
                                                },
                                            );
                                        }
                                    }
                                }
                            }
                        }
                    }

                    NodeCommand::RenameChannel { server_id, channel_id, new_name } => {
                        if let Some(state) = server_states.get_mut(&server_id) {
                            let local_peer = swarm.local_peer_id().to_string();
                            if !state.has_permission(&local_peer, Permission::MANAGE_CHANNELS) {
                                hollow_log!("[HOLLOW-CRDT] Permission denied: cannot rename channel in {server_id}");
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: "Permission denied: cannot manage channels".to_string(),
                                }).await;
                                continue;
                            }
                            hollow_log!("[HOLLOW-CRDT] Renaming channel {channel_id} to '{new_name}' in server {server_id}");

                            let op = state.create_op(CrdtPayload::ChannelRenamed {
                                channel_id: channel_id.clone(),
                                new_name: new_name.clone(),
                            });
                            let _ = state.apply_op(&op);

                            // Persist
                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = crate::identity::data_dir().unwrap_or_default();
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let _ = store.save_server_state(&server_id, &json);
                                    let _ = store.insert_crdt_op(&op);
                                }
                            }

                            let _ = event_tx.send(NetworkEvent::ChannelRenamed {
                                server_id: server_id.clone(),
                                channel_id,
                                new_name,
                            }).await;

                            // Broadcast to connected server members only.
                            if let Ok(op_json) = serde_json::to_string(&op) {
                                let local_peer = swarm.local_peer_id().to_string();
                                for member_peer_str in state.members.keys() {
                                    if member_peer_str == &local_peer { continue; }
                                    if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                        if connected_peers.contains(&pid) {
                                            swarm.behaviour_mut().messaging.send_request(
                                                &pid,
                                                HavenMessage::CrdtOpBroadcast {
                                                    server_id: server_id.clone(),
                                                    op_json: op_json.clone(),
                                                },
                                            );
                                        }
                                    }
                                }
                            }
                        }
                    }

                    NodeCommand::UpdateServerSetting { server_id, key, value } => {
                        if let Some(state) = server_states.get_mut(&server_id) {
                            hollow_log!("[HOLLOW-CRDT] Updating setting '{key}'='{value}' in server {server_id}");

                            let op = state.create_op(CrdtPayload::ServerSettingChanged {
                                key: key.clone(),
                                value: value.clone(),
                            });
                            let _ = state.apply_op(&op);

                            // Persist
                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = crate::identity::data_dir().unwrap_or_default();
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let _ = store.save_server_state(&server_id, &json);
                                    let _ = store.insert_crdt_op(&op);
                                }
                            }

                            let _ = event_tx.send(NetworkEvent::ServerUpdated {
                                server_id: server_id.clone(),
                            }).await;

                            // Broadcast to connected server members only.
                            if let Ok(op_json) = serde_json::to_string(&op) {
                                let local_peer = swarm.local_peer_id().to_string();
                                for member_peer_str in state.members.keys() {
                                    if member_peer_str == &local_peer { continue; }
                                    if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                        if connected_peers.contains(&pid) {
                                            swarm.behaviour_mut().messaging.send_request(
                                                &pid,
                                                HavenMessage::CrdtOpBroadcast {
                                                    server_id: server_id.clone(),
                                                    op_json: op_json.clone(),
                                                },
                                            );
                                        }
                                    }
                                }
                            }
                        }
                    }

                    NodeCommand::DeleteServer { server_id } => {
                        // Only owner can delete a server.
                        if let Some(state) = server_states.get(&server_id) {
                            let local_peer = swarm.local_peer_id().to_string();
                            if !state.has_permission(&local_peer, Permission::MANAGE_SERVER) {
                                hollow_log!("[HOLLOW-CRDT] Permission denied: cannot delete server {server_id}");
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: "Permission denied: only the owner can delete the server".to_string(),
                                }).await;
                                continue;
                            }
                        }

                        hollow_log!("[HOLLOW-CRDT] Deleting server {server_id}");

                        // Broadcast deletion to all connected server members.
                        if let Some(state) = server_states.get(&server_id) {
                            let local_peer = swarm.local_peer_id().to_string();
                            for member_peer_str in state.members.keys() {
                                if member_peer_str == &local_peer { continue; }
                                if let Ok(member_pid) = member_peer_str.parse::<PeerId>() {
                                    if connected_peers.contains(&member_pid) {
                                        swarm.behaviour_mut().messaging.send_request(
                                            &member_pid,
                                            HavenMessage::ServerDeleteBroadcast {
                                                server_id: server_id.clone(),
                                            },
                                        );
                                    }
                                }
                            }
                        }

                        server_states.remove(&server_id);

                        // Clean up MLS group.
                        if let Some(ref mut mls_mgr) = mls {
                            mls_mgr.remove_group(&server_id);
                            persist_mls_state(mls_mgr, &bundle_keypair);
                        }

                        // Unregister from signaling room for this server.
                        let _ = sig_cmd_tx.send(SignalingCmd::Unregister {
                            room_code: server_id.clone(),
                        }).await;

                        // Remove from DB
                        let data_dir = crate::identity::data_dir().unwrap_or_default();
                        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                            let _ = store.delete_server_state(&server_id);
                        }

                        let _ = event_tx.send(NetworkEvent::ServerDeleted {
                            server_id,
                        }).await;
                    }

                    NodeCommand::JoinServer { server_id } => {
                        hollow_log!("[HOLLOW-CRDT] Joining server {server_id}");
                        pending_server_joins.insert(server_id.clone());

                        // Join the signaling room with room_code = server_id.
                        let addrs: Vec<String> = known_addresses.iter()
                            .filter(|a| is_registerable_address(a))
                            .cloned()
                            .collect();
                        if !addrs.is_empty() {
                            let _ = sig_cmd_tx.send(SignalingCmd::Register {
                                room_code: server_id.clone(),
                                addresses: addrs,
                            }).await;
                        }
                        let _ = sig_cmd_tx.send(SignalingCmd::SetRoom {
                            room_code: server_id.clone(),
                        }).await;
                        let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
                            room_code: server_id.clone(),
                        }).await;

                        // Generate MLS KeyPackage to send alongside join request.
                        let mls_kp_b64 = mls.as_ref().and_then(|m| {
                            match m.generate_key_package() {
                                Ok(kp) => Some(base64::engine::general_purpose::STANDARD.encode(&kp)),
                                Err(e) => { hollow_log!("[HOLLOW-MLS] Failed to generate KeyPackage: {e}"); None }
                            }
                        });

                        // Send join requests to any peers we're already connected to.
                        for &peer_id in &connected_peers {
                            swarm.behaviour_mut().messaging.send_request(
                                &peer_id,
                                HavenMessage::ServerJoinRequest {
                                    server_id: server_id.clone(),
                                },
                            );
                            // Also send MLS KeyPackage if available.
                            if let Some(ref kp) = mls_kp_b64 {
                                swarm.behaviour_mut().messaging.send_request(
                                    &peer_id,
                                    HavenMessage::MlsKeyPackage {
                                        server_id: server_id.clone(),
                                        key_package: kp.clone(),
                                    },
                                );
                            }
                        }
                    }

                    NodeCommand::ChangeRole { server_id, peer_id, new_role } => {
                        if let Some(state) = server_states.get_mut(&server_id) {
                            let local_peer = swarm.local_peer_id().to_string();
                            let new_member_role = crate::crdt::operations::MemberRole::from_str(&new_role);

                            // Permission check: can the local user change this peer's role?
                            if !state.can_change_role(&local_peer, &peer_id, &new_member_role) {
                                hollow_log!("[HOLLOW-CRDT] Permission denied: cannot change {peer_id} to {new_role} in {server_id}");
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: format!("Permission denied: cannot change role to {new_role}"),
                                }).await;
                                continue;
                            }

                            hollow_log!("[HOLLOW-CRDT] Changing role of {peer_id} to {new_role} in {server_id}");
                            // Use the author's (local user's) role priority, not the target role's.
                            // This ensures demotions work: an Owner(3) demoting Admin(2)→Member
                            // sends priority 3, which beats the existing priority 2 in AdminLwwReg.
                            let author_role = state.get_role(&local_peer);
                            let op = state.create_op(CrdtPayload::RoleChanged {
                                peer_id: peer_id.clone(),
                                role: new_member_role.clone(),
                                priority: author_role.priority(),
                            });
                            let _ = state.apply_op(&op);

                            // Persist
                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = crate::identity::data_dir().unwrap_or_default();
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let _ = store.save_server_state(&server_id, &json);
                                    let _ = store.insert_crdt_op(&op);
                                }
                            }

                            let _ = event_tx.send(NetworkEvent::RoleChanged {
                                server_id: server_id.clone(),
                                peer_id: peer_id.clone(),
                                new_role: new_role.clone(),
                            }).await;

                            // Broadcast to connected server members only.
                            if let Ok(op_json) = serde_json::to_string(&op) {
                                for member_peer_str in state.members.keys() {
                                    if member_peer_str == &local_peer { continue; }
                                    if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                        if connected_peers.contains(&pid) {
                                            swarm.behaviour_mut().messaging.send_request(
                                                &pid,
                                                HavenMessage::CrdtOpBroadcast {
                                                    server_id: server_id.clone(),
                                                    op_json: op_json.clone(),
                                                },
                                            );
                                        }
                                    }
                                }
                            }
                        }
                    }

                    NodeCommand::KickMember { server_id, peer_id } => {
                        if let Some(state) = server_states.get_mut(&server_id) {
                            let local_peer = swarm.local_peer_id().to_string();

                            // Permission check
                            if !state.can_kick(&local_peer, &peer_id) {
                                hollow_log!("[HOLLOW-CRDT] Permission denied: cannot kick {peer_id} from {server_id}");
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: "Permission denied: cannot kick this member".to_string(),
                                }).await;
                                continue;
                            }

                            hollow_log!("[HOLLOW-CRDT] Kicking member {peer_id} from {server_id}");
                            let op = state.create_op(CrdtPayload::MemberRemoved {
                                peer_id: peer_id.clone(),
                            });

                            // Collect broadcast targets BEFORE apply_op removes the member.
                            let broadcast_targets: Vec<String> = state.members.keys()
                                .filter(|m| *m != &local_peer)
                                .cloned()
                                .collect();

                            let _ = state.apply_op(&op);

                            // Persist
                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = crate::identity::data_dir().unwrap_or_default();
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let _ = store.save_server_state(&server_id, &json);
                                    let _ = store.insert_crdt_op(&op);
                                }
                            }

                            let _ = event_tx.send(NetworkEvent::MemberLeft {
                                server_id: server_id.clone(),
                                peer_id: peer_id.clone(),
                            }).await;

                            // Broadcast CRDT op to remaining members (collected before removal).
                            if let Ok(op_json) = serde_json::to_string(&op) {
                                for member_peer_str in &broadcast_targets {
                                    if member_peer_str == &peer_id { continue; } // Kicked peer gets MemberKickBroadcast instead
                                    if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                        if connected_peers.contains(&pid) {
                                            swarm.behaviour_mut().messaging.send_request(
                                                &pid,
                                                HavenMessage::CrdtOpBroadcast {
                                                    server_id: server_id.clone(),
                                                    op_json: op_json.clone(),
                                                },
                                            );
                                        }
                                    }
                                }
                            }

                            // Send kick notification directly to the kicked peer
                            // so they remove themselves from the server.
                            if let Ok(pid) = peer_id.parse::<PeerId>() {
                                if connected_peers.contains(&pid) {
                                    swarm.behaviour_mut().messaging.send_request(
                                        &pid,
                                        HavenMessage::MemberKickBroadcast {
                                            server_id: server_id.clone(),
                                        },
                                    );
                                }
                            }

                            // MLS: remove member from group (epoch rotation for forward secrecy).
                            if let Some(ref mut mls_mgr) = mls {
                                if mls_mgr.has_group(&server_id) {
                                    match mls_mgr.remove_member(&server_id, &peer_id) {
                                        Ok(commit_bytes) => {
                                            match mls_mgr.merge_pending_commit(&server_id) {
                                                Ok(()) => {
                                                    persist_mls_state(mls_mgr, &bundle_keypair);
                                                    let commit_b64 = base64::engine::general_purpose::STANDARD.encode(&commit_bytes);
                                                    // Broadcast MLS commit to remaining members.
                                                    for member_peer_str in &broadcast_targets {
                                                        if member_peer_str == &peer_id { continue; }
                                                        if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                                            if connected_peers.contains(&pid) {
                                                                swarm.behaviour_mut().messaging.send_request(
                                                                    &pid,
                                                                    HavenMessage::MlsCommit {
                                                                        server_id: server_id.clone(),
                                                                        commit: commit_b64.clone(),
                                                                    },
                                                                );
                                                            }
                                                        }
                                                    }
                                                    hollow_log!("[HOLLOW-MLS] Removed {peer_id} from MLS group, epoch rotated");
                                                }
                                                Err(e) => hollow_log!("[HOLLOW-MLS] Failed to merge remove commit: {e}"),
                                            }
                                        }
                                        Err(e) => hollow_log!("[HOLLOW-MLS] Failed to remove member from MLS group: {e}"),
                                    }
                                }
                            }
                        }
                    }

                    NodeCommand::SetNickname { server_id, peer_id, nickname } => {
                        if let Some(state) = server_states.get_mut(&server_id) {
                            let local_peer = swarm.local_peer_id().to_string();

                            // Members can set their own nickname. Admins+ can set others'.
                            if peer_id != local_peer && !state.has_permission(&local_peer, crate::crdt::operations::Permission::MANAGE_ROLES) {
                                hollow_log!("[HOLLOW-CRDT] Permission denied: cannot set nickname for {peer_id}");
                                continue;
                            }

                            hollow_log!("[HOLLOW-CRDT] Setting nickname for {peer_id} to '{nickname}' in {server_id}");
                            let op = state.create_op(CrdtPayload::NicknameChanged {
                                peer_id: peer_id.clone(),
                                nickname: nickname.clone(),
                            });
                            let _ = state.apply_op(&op);

                            // Persist
                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = crate::identity::data_dir().unwrap_or_default();
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let _ = store.save_server_state(&server_id, &json);
                                    let _ = store.insert_crdt_op(&op);
                                }
                            }

                            // Emit event so Dart refreshes member list
                            let _ = event_tx.send(NetworkEvent::MemberJoined {
                                server_id: server_id.clone(),
                                peer_id: peer_id.clone(),
                            }).await;

                            // Broadcast to connected server members
                            if let Ok(op_json) = serde_json::to_string(&op) {
                                for member_peer_str in state.members.keys() {
                                    if member_peer_str == &local_peer { continue; }
                                    if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                        if connected_peers.contains(&pid) {
                                            swarm.behaviour_mut().messaging.send_request(
                                                &pid,
                                                HavenMessage::CrdtOpBroadcast {
                                                    server_id: server_id.clone(),
                                                    op_json: op_json.clone(),
                                                },
                                            );
                                        }
                                    }
                                }
                            }
                        }
                    }

                    NodeCommand::RequestChannelSync { server_id, channel_id } => {
                        // On-demand sync when user opens a channel.
                        if let Some(state) = server_states.get(&server_id) {
                            let data_dir = crate::identity::data_dir().unwrap_or_default();
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let since = store
                                        .get_latest_channel_timestamp(&server_id, &channel_id)
                                        .unwrap_or(None)
                                        .unwrap_or(0);
                                    let sender_ts = store
                                        .get_per_sender_timestamps(&server_id, &channel_id)
                                        .unwrap_or_default();
                                    let local_peer = swarm.local_peer_id().to_string();
                                    for member_peer_str in state.members.keys() {
                                        if member_peer_str == &local_peer { continue; }
                                        if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                            if connected_peers.contains(&pid) {
                                                swarm.behaviour_mut().messaging.send_request(
                                                    &pid,
                                                    HavenMessage::ChannelSyncRequest {
                                                        server_id: server_id.clone(),
                                                        channel_id: channel_id.clone(),
                                                        since_timestamp: since,
                                                        sender_timestamps: sender_ts.clone(),
                                                    },
                                                );
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    NodeCommand::UpdateProfile { display_name, status, about_me, avatar_bytes, banner_bytes } => {
                        let now = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as i64;

                        use base64::Engine;
                        // None = no change → empty string. Some(empty) = clear → "CLEAR". Some(data) = base64.
                        let avatar_b64 = match &avatar_bytes {
                            None => String::new(),
                            Some(b) if b.is_empty() => "CLEAR".to_string(),
                            Some(b) => base64::engine::general_purpose::STANDARD.encode(b),
                        };
                        let banner_b64 = match &banner_bytes {
                            None => String::new(),
                            Some(b) if b.is_empty() => "CLEAR".to_string(),
                            Some(b) => base64::engine::general_purpose::STANDARD.encode(b),
                        };

                        // Save our own profile to DB.
                        {
                            let data_dir = crate::identity::data_dir().unwrap_or_default();
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                            if let Ok(db) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                if let Err(e) = db.save_profile(
                                    &local_peer_str, &display_name, &status, &about_me, now,
                                    avatar_bytes.as_deref(), banner_bytes.as_deref(),
                                ) {
                                    hollow_log!("[HOLLOW-SWARM] Failed to save own profile: {e}");
                                }
                            }
                        }

                        // Broadcast to all connected peers.
                        let msg = HavenMessage::ProfileUpdate {
                            display_name: display_name.clone(),
                            status: status.clone(),
                            about_me: about_me.clone(),
                            updated_at: now,
                            avatar_b64: avatar_b64.clone(),
                            banner_b64: banner_b64.clone(),
                        };
                        hollow_log!("[HOLLOW-SWARM] Broadcasting profile update to {} peers", connected_peers.len());
                        for pid in connected_peers.iter() {
                            if relay_peer_id() == Some(*pid) { continue; }
                            swarm.behaviour_mut().messaging.send_request(pid, msg.clone());
                        }

                        // Emit event so Dart updates UI.
                        let _ = event_tx.send(NetworkEvent::ProfileUpdated {
                            peer_id: local_peer_str.clone(),
                        }).await;
                    }

                    NodeCommand::EditChannelMessage { server_id, channel_id, message_id, new_text } => {
                        hollow_log!("[HOLLOW-SWARM] EditChannelMessage {message_id} in {server_id}/{channel_id}");

                        let server = match server_states.get(&server_id) {
                            Some(s) => s,
                            None => {
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: format!("Unknown server {server_id}"),
                                }).await;
                                continue;
                            }
                        };

                        let local_peer = swarm.local_peer_id().to_string();
                        let edit_timestamp = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as i64;

                        // Sign the edit.
                        let signing_payload = format!("edit:{}:{}:{}", message_id, new_text, edit_timestamp);
                        let (sig, pk) = sign_message(&bundle_keypair, &pub_key_b64, &signing_payload);

                        // Update local DB (preserves old text in message_edits table).
                        {
                            let data_dir = crate::identity::data_dir().unwrap_or_default();
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                let _ = store.edit_channel_message(
                                    &message_id, &new_text, edit_timestamp,
                                    sig.as_deref(), pk.as_deref(),
                                );
                            }
                        }

                        // Broadcast edit to all server members.
                        let envelope = MessageEnvelope::EditMessage {
                            mid: message_id.clone(),
                            text: new_text.clone(),
                            ts: edit_timestamp,
                            sig: sig.clone(),
                            pk: pk.clone(),
                            sid: Some(server_id.clone()),
                            cid: Some(channel_id.clone()),
                        };
                        let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();

                        let use_mls = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
                        if use_mls {
                            let mls_mgr = mls.as_mut().unwrap();
                            match mls_mgr.encrypt(&server_id, envelope_json.as_bytes()) {
                                Ok(ciphertext) => {
                                    let body_b64 = base64::engine::general_purpose::STANDARD.encode(&ciphertext);
                                    persist_mls_state(mls_mgr, &bundle_keypair);
                                    for member_peer_str in server.members.keys() {
                                        if member_peer_str == &local_peer { continue; }
                                        if let Ok(member_pid) = member_peer_str.parse::<PeerId>() {
                                            if connected_peers.contains(&member_pid) {
                                                swarm.behaviour_mut().messaging.send_request(
                                                    &member_pid,
                                                    HavenMessage::MlsChannelMessage {
                                                        server_id: server_id.clone(),
                                                        body: body_b64.clone(),
                                                    },
                                                );
                                            }
                                        }
                                    }
                                }
                                Err(e) => {
                                    hollow_log!("[HOLLOW-MLS] Edit encrypt failed, falling back to Olm: {e}");
                                    for member_peer_str in server.members.keys() {
                                        if member_peer_str == &local_peer { continue; }
                                        if let Ok(member_pid) = member_peer_str.parse::<PeerId>() {
                                            if connected_peers.contains(&member_pid) {
                                                send_encrypted_message(
                                                    &mut swarm, &mut olm, &crypto_store,
                                                    &mut pending_requests, &mut outbound_message_text,
                                                    &member_pid, member_peer_str, &envelope_json,
                                                    &event_tx,
                                                ).await;
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            // Olm fan-out fallback.
                            for member_peer_str in server.members.keys() {
                                if member_peer_str == &local_peer { continue; }
                                if let Ok(member_pid) = member_peer_str.parse::<PeerId>() {
                                    if connected_peers.contains(&member_pid) {
                                        send_encrypted_message(
                                            &mut swarm, &mut olm, &crypto_store,
                                            &mut pending_requests, &mut outbound_message_text,
                                            &member_pid, member_peer_str, &envelope_json,
                                            &event_tx,
                                        ).await;
                                    }
                                }
                            }
                        }

                        // Emit event so Dart updates UI.
                        let _ = event_tx.send(NetworkEvent::ChannelMessageEdited {
                            server_id,
                            channel_id,
                            message_id,
                            new_text,
                            edited_at: edit_timestamp,
                        }).await;
                    }

                    NodeCommand::EditDmMessage { peer_id, message_id, new_text } => {
                        let peer_id_str = peer_id.to_string();
                        hollow_log!("[HOLLOW-SWARM] EditDmMessage {message_id} for {peer_id_str}");

                        let edit_timestamp = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as i64;

                        // Sign the edit.
                        let signing_payload = format!("edit:{}:{}:{}", message_id, new_text, edit_timestamp);
                        let (sig, pk) = sign_message(&bundle_keypair, &pub_key_b64, &signing_payload);

                        // Update local DB.
                        {
                            let data_dir = crate::identity::data_dir().unwrap_or_default();
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                let _ = store.edit_dm_message(
                                    &message_id, &new_text, edit_timestamp,
                                    sig.as_deref(), pk.as_deref(),
                                );
                            }
                        }

                        // Send edit to the DM peer.
                        let envelope = MessageEnvelope::EditMessage {
                            mid: message_id.clone(),
                            text: new_text.clone(),
                            ts: edit_timestamp,
                            sig: sig.clone(),
                            pk: pk.clone(),
                            sid: None,
                            cid: None,
                        };
                        let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();

                        if olm.has_session(&peer_id_str) {
                            send_encrypted_message(
                                &mut swarm, &mut olm, &crypto_store,
                                &mut pending_requests, &mut outbound_message_text,
                                &peer_id, &peer_id_str, &envelope_json,
                                &event_tx,
                            ).await;
                        }

                        // Emit event so Dart updates UI.
                        let _ = event_tx.send(NetworkEvent::DmMessageEdited {
                            peer_id: peer_id_str,
                            message_id,
                            new_text,
                            edited_at: edit_timestamp,
                        }).await;
                    }

                    NodeCommand::DeleteChannelMessage { server_id, channel_id, message_id } => {
                        hollow_log!("[HOLLOW-SWARM] DeleteChannelMessage {message_id} in {server_id}/{channel_id}");

                        let server = match server_states.get(&server_id) {
                            Some(s) => s,
                            None => {
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: format!("Unknown server {server_id}"),
                                }).await;
                                continue;
                            }
                        };

                        let local_peer = swarm.local_peer_id().to_string();
                        let delete_timestamp = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as i64;

                        // Sign the deletion.
                        let signing_payload = format!("delete:{}:{}", message_id, delete_timestamp);
                        let (sig, pk) = sign_message(&bundle_keypair, &pub_key_b64, &signing_payload);

                        // Hide in local DB (preserves text in message_deletions table).
                        {
                            let data_dir = crate::identity::data_dir().unwrap_or_default();
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                let _ = store.hide_channel_message(
                                    &message_id, delete_timestamp,
                                    sig.as_deref(), pk.as_deref(),
                                );
                            }
                        }

                        // Broadcast deletion to all server members.
                        let envelope = MessageEnvelope::DeleteMessage {
                            mid: message_id.clone(),
                            ts: delete_timestamp,
                            sig: sig.clone(),
                            pk: pk.clone(),
                            sid: Some(server_id.clone()),
                            cid: Some(channel_id.clone()),
                        };
                        let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();

                        let use_mls = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
                        if use_mls {
                            let mls_mgr = mls.as_mut().unwrap();
                            match mls_mgr.encrypt(&server_id, envelope_json.as_bytes()) {
                                Ok(ciphertext) => {
                                    let body_b64 = base64::engine::general_purpose::STANDARD.encode(&ciphertext);
                                    persist_mls_state(mls_mgr, &bundle_keypair);
                                    for member_peer_str in server.members.keys() {
                                        if member_peer_str == &local_peer { continue; }
                                        if let Ok(member_pid) = member_peer_str.parse::<PeerId>() {
                                            if connected_peers.contains(&member_pid) {
                                                swarm.behaviour_mut().messaging.send_request(
                                                    &member_pid,
                                                    HavenMessage::MlsChannelMessage {
                                                        server_id: server_id.clone(),
                                                        body: body_b64.clone(),
                                                    },
                                                );
                                            }
                                        }
                                    }
                                }
                                Err(e) => {
                                    hollow_log!("[HOLLOW-MLS] Delete encrypt failed, falling back to Olm: {e}");
                                    for member_peer_str in server.members.keys() {
                                        if member_peer_str == &local_peer { continue; }
                                        if let Ok(member_pid) = member_peer_str.parse::<PeerId>() {
                                            if connected_peers.contains(&member_pid) {
                                                send_encrypted_message(
                                                    &mut swarm, &mut olm, &crypto_store,
                                                    &mut pending_requests, &mut outbound_message_text,
                                                    &member_pid, member_peer_str, &envelope_json,
                                                    &event_tx,
                                                ).await;
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            // Olm fan-out fallback.
                            for member_peer_str in server.members.keys() {
                                if member_peer_str == &local_peer { continue; }
                                if let Ok(member_pid) = member_peer_str.parse::<PeerId>() {
                                    if connected_peers.contains(&member_pid) {
                                        send_encrypted_message(
                                            &mut swarm, &mut olm, &crypto_store,
                                            &mut pending_requests, &mut outbound_message_text,
                                            &member_pid, member_peer_str, &envelope_json,
                                            &event_tx,
                                        ).await;
                                    }
                                }
                            }
                        }

                        // Emit event so Dart updates UI.
                        let _ = event_tx.send(NetworkEvent::ChannelMessageDeleted {
                            server_id,
                            channel_id,
                            message_id,
                            deleted_at: delete_timestamp,
                        }).await;
                    }

                    NodeCommand::DeleteDmMessage { peer_id, message_id } => {
                        let peer_id_str = peer_id.to_string();
                        hollow_log!("[HOLLOW-SWARM] DeleteDmMessage {message_id} for {peer_id_str}");

                        let delete_timestamp = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as i64;

                        // Sign the deletion.
                        let signing_payload = format!("delete:{}:{}", message_id, delete_timestamp);
                        let (sig, pk) = sign_message(&bundle_keypair, &pub_key_b64, &signing_payload);

                        // Hide in local DB.
                        {
                            let data_dir = crate::identity::data_dir().unwrap_or_default();
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                let _ = store.hide_dm_message(
                                    &message_id, delete_timestamp,
                                    sig.as_deref(), pk.as_deref(),
                                );
                            }
                        }

                        // Send deletion to the DM peer.
                        let envelope = MessageEnvelope::DeleteMessage {
                            mid: message_id.clone(),
                            ts: delete_timestamp,
                            sig: sig.clone(),
                            pk: pk.clone(),
                            sid: None,
                            cid: None,
                        };
                        let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();

                        if olm.has_session(&peer_id_str) {
                            send_encrypted_message(
                                &mut swarm, &mut olm, &crypto_store,
                                &mut pending_requests, &mut outbound_message_text,
                                &peer_id, &peer_id_str, &envelope_json,
                                &event_tx,
                            ).await;
                        }

                        // Emit event so Dart updates UI.
                        let _ = event_tx.send(NetworkEvent::DmMessageDeleted {
                            peer_id: peer_id_str,
                            message_id,
                            deleted_at: delete_timestamp,
                        }).await;
                    }

                    NodeCommand::AddChannelReaction { server_id, channel_id, message_id, emoji } => {
                        hollow_log!("[HOLLOW-SWARM] AddChannelReaction {emoji} on {message_id} in {server_id}/{channel_id}");

                        let server = match server_states.get(&server_id) {
                            Some(s) => s,
                            None => {
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: format!("Unknown server {server_id}"),
                                }).await;
                                continue;
                            }
                        };

                        let local_peer = swarm.local_peer_id().to_string();
                        let reaction_ts = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as i64;

                        let signing_payload = format!("reaction:{}:{}:{}", message_id, emoji, reaction_ts);
                        let (sig, pk) = sign_message(&bundle_keypair, &pub_key_b64, &signing_payload);

                        // Save to local DB.
                        {
                            let data_dir = crate::identity::data_dir().unwrap_or_default();
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                let _ = store.add_reaction(
                                    &message_id, &emoji, &local_peer, reaction_ts,
                                    sig.as_deref(), pk.as_deref(),
                                );
                            }
                        }

                        // Broadcast to all server members.
                        let envelope = MessageEnvelope::AddReaction {
                            mid: message_id.clone(),
                            emoji: emoji.clone(),
                            ts: reaction_ts,
                            sig: sig.clone(),
                            pk: pk.clone(),
                            sid: Some(server_id.clone()),
                            cid: Some(channel_id.clone()),
                        };
                        let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();

                        let use_mls = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
                        if use_mls {
                            let mls_mgr = mls.as_mut().unwrap();
                            match mls_mgr.encrypt(&server_id, envelope_json.as_bytes()) {
                                Ok(ciphertext) => {
                                    let body_b64 = base64::engine::general_purpose::STANDARD.encode(&ciphertext);
                                    persist_mls_state(mls_mgr, &bundle_keypair);
                                    for member_peer_str in server.members.keys() {
                                        if member_peer_str == &local_peer { continue; }
                                        if let Ok(member_pid) = member_peer_str.parse::<PeerId>() {
                                            if connected_peers.contains(&member_pid) {
                                                swarm.behaviour_mut().messaging.send_request(
                                                    &member_pid,
                                                    HavenMessage::MlsChannelMessage {
                                                        server_id: server_id.clone(),
                                                        body: body_b64.clone(),
                                                    },
                                                );
                                            }
                                        }
                                    }
                                }
                                Err(e) => {
                                    hollow_log!("[HOLLOW-MLS] Reaction encrypt failed, falling back to Olm: {e}");
                                    for member_peer_str in server.members.keys() {
                                        if member_peer_str == &local_peer { continue; }
                                        if let Ok(member_pid) = member_peer_str.parse::<PeerId>() {
                                            if connected_peers.contains(&member_pid) {
                                                send_encrypted_message(
                                                    &mut swarm, &mut olm, &crypto_store,
                                                    &mut pending_requests, &mut outbound_message_text,
                                                    &member_pid, member_peer_str, &envelope_json,
                                                    &event_tx,
                                                ).await;
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            for member_peer_str in server.members.keys() {
                                if member_peer_str == &local_peer { continue; }
                                if let Ok(member_pid) = member_peer_str.parse::<PeerId>() {
                                    if connected_peers.contains(&member_pid) {
                                        send_encrypted_message(
                                            &mut swarm, &mut olm, &crypto_store,
                                            &mut pending_requests, &mut outbound_message_text,
                                            &member_pid, member_peer_str, &envelope_json,
                                            &event_tx,
                                        ).await;
                                    }
                                }
                            }
                        }

                        let _ = event_tx.send(NetworkEvent::ChannelReactionAdded {
                            server_id,
                            channel_id,
                            message_id,
                            emoji,
                            reactor: local_peer,
                            added_at: reaction_ts,
                        }).await;
                    }

                    NodeCommand::AddDmReaction { peer_id, message_id, emoji } => {
                        let peer_id_str = peer_id.to_string();
                        hollow_log!("[HOLLOW-SWARM] AddDmReaction {emoji} on {message_id} for {peer_id_str}");

                        let local_peer = swarm.local_peer_id().to_string();
                        let reaction_ts = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as i64;

                        let signing_payload = format!("reaction:{}:{}:{}", message_id, emoji, reaction_ts);
                        let (sig, pk) = sign_message(&bundle_keypair, &pub_key_b64, &signing_payload);

                        // Save to local DB.
                        {
                            let data_dir = crate::identity::data_dir().unwrap_or_default();
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                let _ = store.add_reaction(
                                    &message_id, &emoji, &local_peer, reaction_ts,
                                    sig.as_deref(), pk.as_deref(),
                                );
                            }
                        }

                        // Send to DM peer.
                        let envelope = MessageEnvelope::AddReaction {
                            mid: message_id.clone(),
                            emoji: emoji.clone(),
                            ts: reaction_ts,
                            sig: sig.clone(),
                            pk: pk.clone(),
                            sid: None,
                            cid: None,
                        };
                        let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();

                        if olm.has_session(&peer_id_str) {
                            send_encrypted_message(
                                &mut swarm, &mut olm, &crypto_store,
                                &mut pending_requests, &mut outbound_message_text,
                                &peer_id, &peer_id_str, &envelope_json,
                                &event_tx,
                            ).await;
                        }

                        let _ = event_tx.send(NetworkEvent::DmReactionAdded {
                            peer_id: peer_id_str,
                            message_id,
                            emoji,
                            reactor: local_peer,
                            added_at: reaction_ts,
                        }).await;
                    }

                    NodeCommand::RemoveChannelReaction { server_id, channel_id, message_id, emoji } => {
                        hollow_log!("[HOLLOW-SWARM] RemoveChannelReaction {emoji} on {message_id} in {server_id}/{channel_id}");

                        let server = match server_states.get(&server_id) {
                            Some(s) => s,
                            None => {
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: format!("Unknown server {server_id}"),
                                }).await;
                                continue;
                            }
                        };

                        let local_peer = swarm.local_peer_id().to_string();
                        let remove_ts = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as i64;

                        let signing_payload = format!("unreaction:{}:{}:{}", message_id, emoji, remove_ts);
                        let (sig, pk) = sign_message(&bundle_keypair, &pub_key_b64, &signing_payload);

                        // Remove from local DB.
                        {
                            let data_dir = crate::identity::data_dir().unwrap_or_default();
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                let _ = store.remove_reaction(
                                    &message_id, &emoji, &local_peer, remove_ts,
                                    sig.as_deref(), pk.as_deref(),
                                );
                            }
                        }

                        // Broadcast to all server members.
                        let envelope = MessageEnvelope::RemoveReaction {
                            mid: message_id.clone(),
                            emoji: emoji.clone(),
                            ts: remove_ts,
                            sig: sig.clone(),
                            pk: pk.clone(),
                            sid: Some(server_id.clone()),
                            cid: Some(channel_id.clone()),
                        };
                        let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();

                        let use_mls = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
                        if use_mls {
                            let mls_mgr = mls.as_mut().unwrap();
                            match mls_mgr.encrypt(&server_id, envelope_json.as_bytes()) {
                                Ok(ciphertext) => {
                                    let body_b64 = base64::engine::general_purpose::STANDARD.encode(&ciphertext);
                                    persist_mls_state(mls_mgr, &bundle_keypair);
                                    for member_peer_str in server.members.keys() {
                                        if member_peer_str == &local_peer { continue; }
                                        if let Ok(member_pid) = member_peer_str.parse::<PeerId>() {
                                            if connected_peers.contains(&member_pid) {
                                                swarm.behaviour_mut().messaging.send_request(
                                                    &member_pid,
                                                    HavenMessage::MlsChannelMessage {
                                                        server_id: server_id.clone(),
                                                        body: body_b64.clone(),
                                                    },
                                                );
                                            }
                                        }
                                    }
                                }
                                Err(e) => {
                                    hollow_log!("[HOLLOW-MLS] Remove reaction encrypt failed, Olm fallback: {e}");
                                    for member_peer_str in server.members.keys() {
                                        if member_peer_str == &local_peer { continue; }
                                        if let Ok(member_pid) = member_peer_str.parse::<PeerId>() {
                                            if connected_peers.contains(&member_pid) {
                                                send_encrypted_message(
                                                    &mut swarm, &mut olm, &crypto_store,
                                                    &mut pending_requests, &mut outbound_message_text,
                                                    &member_pid, member_peer_str, &envelope_json,
                                                    &event_tx,
                                                ).await;
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            for member_peer_str in server.members.keys() {
                                if member_peer_str == &local_peer { continue; }
                                if let Ok(member_pid) = member_peer_str.parse::<PeerId>() {
                                    if connected_peers.contains(&member_pid) {
                                        send_encrypted_message(
                                            &mut swarm, &mut olm, &crypto_store,
                                            &mut pending_requests, &mut outbound_message_text,
                                            &member_pid, member_peer_str, &envelope_json,
                                            &event_tx,
                                        ).await;
                                    }
                                }
                            }
                        }

                        let _ = event_tx.send(NetworkEvent::ChannelReactionRemoved {
                            server_id,
                            channel_id,
                            message_id,
                            emoji,
                            reactor: local_peer,
                            removed_at: remove_ts,
                        }).await;
                    }

                    NodeCommand::RemoveDmReaction { peer_id, message_id, emoji } => {
                        let peer_id_str = peer_id.to_string();
                        hollow_log!("[HOLLOW-SWARM] RemoveDmReaction {emoji} on {message_id} for {peer_id_str}");

                        let local_peer = swarm.local_peer_id().to_string();
                        let remove_ts = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as i64;

                        let signing_payload = format!("unreaction:{}:{}:{}", message_id, emoji, remove_ts);
                        let (sig, pk) = sign_message(&bundle_keypair, &pub_key_b64, &signing_payload);

                        // Remove from local DB.
                        {
                            let data_dir = crate::identity::data_dir().unwrap_or_default();
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                let _ = store.remove_reaction(
                                    &message_id, &emoji, &local_peer, remove_ts,
                                    sig.as_deref(), pk.as_deref(),
                                );
                            }
                        }

                        // Send to DM peer.
                        let envelope = MessageEnvelope::RemoveReaction {
                            mid: message_id.clone(),
                            emoji: emoji.clone(),
                            ts: remove_ts,
                            sig: sig.clone(),
                            pk: pk.clone(),
                            sid: None,
                            cid: None,
                        };
                        let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();

                        if olm.has_session(&peer_id_str) {
                            send_encrypted_message(
                                &mut swarm, &mut olm, &crypto_store,
                                &mut pending_requests, &mut outbound_message_text,
                                &peer_id, &peer_id_str, &envelope_json,
                                &event_tx,
                            ).await;
                        }

                        let _ = event_tx.send(NetworkEvent::DmReactionRemoved {
                            peer_id: peer_id_str,
                            message_id,
                            emoji,
                            reactor: local_peer,
                            removed_at: remove_ts,
                        }).await;
                    }

                    NodeCommand::SendFriendRequest { peer_id } => {
                        let peer_id_str = peer_id.to_string();
                        hollow_log!("[HOLLOW-FRIENDS] Sending friend request to {peer_id_str}");

                        let now = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as i64;

                        // Save as pending outgoing.
                        {
                            let data_dir = crate::identity::data_dir().unwrap_or_default();
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                let _ = store.save_friend(&peer_id_str, "pending", "outgoing", now);
                            }
                        }

                        // Register DM room code immediately so signaling can help
                        // discover the peer even before they accept.
                        let local_peer = swarm.local_peer_id().to_string();
                        let room = dm_room_code(&local_peer, &peer_id_str);
                        let addrs: Vec<String> = known_addresses.iter()
                            .filter(|a| is_registerable_address(a))
                            .cloned()
                            .collect();
                        if !addrs.is_empty() {
                            let _ = sig_cmd_tx.send(SignalingCmd::Register {
                                room_code: room.clone(),
                                addresses: addrs,
                            }).await;
                        }
                        let _ = sig_cmd_tx.send(SignalingCmd::SetRoom {
                            room_code: room.clone(),
                        }).await;
                        let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
                            room_code: room,
                        }).await;

                        // Send to peer if connected.
                        if connected_peers.contains(&peer_id) {
                            swarm.behaviour_mut().messaging.send_request(
                                &peer_id,
                                HavenMessage::FriendRequest { requested_at: now },
                            );
                        }

                        let _ = event_tx.send(NetworkEvent::FriendRequestReceived {
                            peer_id: peer_id_str,
                        }).await;
                    }

                    NodeCommand::AcceptFriendRequest { peer_id } => {
                        let peer_id_str = peer_id.to_string();
                        hollow_log!("[HOLLOW-FRIENDS] Accepting friend request from {peer_id_str}");

                        // Update to accepted.
                        {
                            let data_dir = crate::identity::data_dir().unwrap_or_default();
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                let now = std::time::SystemTime::now()
                                    .duration_since(std::time::UNIX_EPOCH)
                                    .unwrap_or_default()
                                    .as_millis() as i64;
                                let _ = store.save_friend(&peer_id_str, "accepted", "", now);
                            }
                        }

                        // Send acceptance to peer.
                        if connected_peers.contains(&peer_id) {
                            swarm.behaviour_mut().messaging.send_request(
                                &peer_id,
                                HavenMessage::FriendAccept,
                            );
                        }

                        // Register DM room code with signaling for internet discovery.
                        let local_peer = swarm.local_peer_id().to_string();
                        let room = dm_room_code(&local_peer, &peer_id_str);
                        let addrs: Vec<String> = known_addresses.iter()
                            .filter(|a| is_registerable_address(a))
                            .cloned()
                            .collect();
                        if !addrs.is_empty() {
                            let _ = sig_cmd_tx.send(SignalingCmd::Register {
                                room_code: room.clone(),
                                addresses: addrs,
                            }).await;
                        }
                        let _ = sig_cmd_tx.send(SignalingCmd::SetRoom {
                            room_code: room.clone(),
                        }).await;
                        let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
                            room_code: room,
                        }).await;

                        let _ = event_tx.send(NetworkEvent::FriendRequestAccepted {
                            peer_id: peer_id_str,
                        }).await;
                    }

                    NodeCommand::RejectFriendRequest { peer_id } => {
                        let peer_id_str = peer_id.to_string();
                        hollow_log!("[HOLLOW-FRIENDS] Rejecting friend request from {peer_id_str}");

                        // Remove from friends table.
                        {
                            let data_dir = crate::identity::data_dir().unwrap_or_default();
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                let _ = store.remove_friend(&peer_id_str);
                            }
                        }

                        if connected_peers.contains(&peer_id) {
                            swarm.behaviour_mut().messaging.send_request(
                                &peer_id,
                                HavenMessage::FriendReject,
                            );
                        }

                        let _ = event_tx.send(NetworkEvent::FriendRequestRejected {
                            peer_id: peer_id_str,
                        }).await;
                    }

                    NodeCommand::RemoveFriend { peer_id } => {
                        let peer_id_str = peer_id.to_string();
                        hollow_log!("[HOLLOW-FRIENDS] Removing friend {peer_id_str}");

                        {
                            let data_dir = crate::identity::data_dir().unwrap_or_default();
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                let _ = store.remove_friend(&peer_id_str);
                            }
                        }

                        if connected_peers.contains(&peer_id) {
                            swarm.behaviour_mut().messaging.send_request(
                                &peer_id,
                                HavenMessage::FriendRemove,
                            );
                        }

                        let _ = event_tx.send(NetworkEvent::FriendRemoved {
                            peer_id: peer_id_str,
                        }).await;
                    }

                    NodeCommand::SendTypingIndicator { server_id, channel_id } => {
                        let msg = HavenMessage::TypingIndicator {
                            server_id: server_id.clone(),
                            channel_id: channel_id.clone(),
                        };

                        if server_id.is_empty() {
                            // DM typing: channel_id is actually the peer ID.
                            if let Ok(pid) = channel_id.parse::<PeerId>() {
                                if connected_peers.contains(&pid) {
                                    swarm.behaviour_mut().messaging.send_request(&pid, msg);
                                }
                            }
                        } else {
                            // Channel typing: broadcast to all connected server members.
                            let local_peer = swarm.local_peer_id().to_string();
                            if let Some(server) = server_states.get(&server_id) {
                                for member_peer_str in server.members.keys() {
                                    if member_peer_str == &local_peer { continue; }
                                    if let Ok(member_pid) = member_peer_str.parse::<PeerId>() {
                                        if connected_peers.contains(&member_pid) {
                                            swarm.behaviour_mut().messaging.send_request(
                                                &member_pid,
                                                msg.clone(),
                                            );
                                        }
                                    }
                                }
                            }
                        }
                    }

                    NodeCommand::UpdateChannelLayout { server_id, layout_json } => {
                        if let Some(state) = server_states.get_mut(&server_id) {
                            let local_peer = swarm.local_peer_id().to_string();

                            if !state.has_permission(&local_peer, crate::crdt::operations::Permission::MANAGE_CHANNELS) {
                                hollow_log!("[HOLLOW-CRDT] Permission denied: cannot update channel layout in {server_id}");
                                continue;
                            }

                            hollow_log!("[HOLLOW-CRDT] Updating channel layout in {server_id}");
                            let op = state.create_op(CrdtPayload::ChannelLayoutUpdated {
                                layout_json: layout_json.clone(),
                            });
                            let _ = state.apply_op(&op);

                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = crate::identity::data_dir().unwrap_or_default();
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let _ = store.save_server_state(&server_id, &json);
                                    let _ = store.insert_crdt_op(&op);
                                }
                            }

                            let _ = event_tx.send(NetworkEvent::ServerUpdated {
                                server_id: server_id.clone(),
                            }).await;

                            if let Ok(op_json) = serde_json::to_string(&op) {
                                for member_peer_str in state.members.keys() {
                                    if member_peer_str == &local_peer { continue; }
                                    if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                        if connected_peers.contains(&pid) {
                                            swarm.behaviour_mut().messaging.send_request(
                                                &pid,
                                                HavenMessage::CrdtOpBroadcast {
                                                    server_id: server_id.clone(),
                                                    op_json: op_json.clone(),
                                                },
                                            );
                                        }
                                    }
                                }
                            }
                        }
                    }

                    NodeCommand::PinMessage { server_id, channel_id, message_id } => {
                        if let Some(state) = server_states.get_mut(&server_id) {
                            let local_peer = swarm.local_peer_id().to_string();

                            if !state.has_permission(&local_peer, crate::crdt::operations::Permission::MANAGE_CHANNELS) {
                                hollow_log!("[HOLLOW-CRDT] Permission denied: cannot pin in {server_id}");
                                continue;
                            }

                            hollow_log!("[HOLLOW-CRDT] Pinning message {message_id} in {server_id}/{channel_id}");
                            let op = state.create_op(CrdtPayload::MessagePinned {
                                channel_id: channel_id.clone(),
                                message_id: message_id.clone(),
                            });
                            let _ = state.apply_op(&op);

                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = crate::identity::data_dir().unwrap_or_default();
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let _ = store.save_server_state(&server_id, &json);
                                    let _ = store.insert_crdt_op(&op);
                                }
                            }

                            let _ = event_tx.send(NetworkEvent::MessagePinned {
                                server_id: server_id.clone(),
                                channel_id: channel_id.clone(),
                                message_id: message_id.clone(),
                            }).await;

                            if let Ok(op_json) = serde_json::to_string(&op) {
                                for member_peer_str in state.members.keys() {
                                    if member_peer_str == &local_peer { continue; }
                                    if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                        if connected_peers.contains(&pid) {
                                            swarm.behaviour_mut().messaging.send_request(
                                                &pid,
                                                HavenMessage::CrdtOpBroadcast {
                                                    server_id: server_id.clone(),
                                                    op_json: op_json.clone(),
                                                },
                                            );
                                        }
                                    }
                                }
                            }
                        }
                    }

                    NodeCommand::UnpinMessage { server_id, channel_id, message_id } => {
                        if let Some(state) = server_states.get_mut(&server_id) {
                            let local_peer = swarm.local_peer_id().to_string();

                            if !state.has_permission(&local_peer, crate::crdt::operations::Permission::MANAGE_CHANNELS) {
                                hollow_log!("[HOLLOW-CRDT] Permission denied: cannot unpin in {server_id}");
                                continue;
                            }

                            hollow_log!("[HOLLOW-CRDT] Unpinning message {message_id} in {server_id}/{channel_id}");
                            let op = state.create_op(CrdtPayload::MessageUnpinned {
                                channel_id: channel_id.clone(),
                                message_id: message_id.clone(),
                            });
                            let _ = state.apply_op(&op);

                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = crate::identity::data_dir().unwrap_or_default();
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let _ = store.save_server_state(&server_id, &json);
                                    let _ = store.insert_crdt_op(&op);
                                }
                            }

                            let _ = event_tx.send(NetworkEvent::MessageUnpinned {
                                server_id: server_id.clone(),
                                channel_id: channel_id.clone(),
                                message_id: message_id.clone(),
                            }).await;

                            if let Ok(op_json) = serde_json::to_string(&op) {
                                for member_peer_str in state.members.keys() {
                                    if member_peer_str == &local_peer { continue; }
                                    if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                        if connected_peers.contains(&pid) {
                                            swarm.behaviour_mut().messaging.send_request(
                                                &pid,
                                                HavenMessage::CrdtOpBroadcast {
                                                    server_id: server_id.clone(),
                                                    op_json: op_json.clone(),
                                                },
                                            );
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // -- Storage pledge (Phase 4) --
                    NodeCommand::SetStoragePledge { server_id, pledge_bytes } => {
                        if let Some(state) = server_states.get_mut(&server_id) {
                            let local_peer = swarm.local_peer_id().to_string();

                            hollow_log!("[HOLLOW-VAULT] Setting storage pledge to {pledge_bytes} bytes in {server_id}");
                            let op = state.create_op(CrdtPayload::StoragePledgeChanged {
                                peer_id: local_peer.clone(),
                                pledge_bytes,
                            });
                            let _ = state.apply_op(&op);

                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = crate::identity::data_dir().unwrap_or_default();
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let _ = store.save_server_state(&server_id, &json);
                                    let _ = store.insert_crdt_op(&op);
                                }
                            }

                            let _ = event_tx.send(NetworkEvent::ServerUpdated {
                                server_id: server_id.clone(),
                            }).await;

                            if let Ok(op_json) = serde_json::to_string(&op) {
                                for member_peer_str in state.members.keys() {
                                    if member_peer_str == &local_peer { continue; }
                                    if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                        if connected_peers.contains(&pid) {
                                            swarm.behaviour_mut().messaging.send_request(
                                                &pid,
                                                HavenMessage::CrdtOpBroadcast {
                                                    server_id: server_id.clone(),
                                                    op_json: op_json.clone(),
                                                },
                                            );
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // -- Vault shard distribution (Phase 4) --
                    NodeCommand::VaultDownloadFile { server_id, content_id } => {
                        hollow_log!("[HOLLOW-VAULT] VaultDownloadFile: cid={content_id} in {server_id}");

                        let data_dir = crate::identity::data_dir().unwrap_or_default();
                        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                        let vault_dir = data_dir.join("vault");
                        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);

                        let result: Result<String, String> = (|| {
                            let cs = crate::vault::content_store::ContentStore::open(&db_path, &passphrase, &vault_dir)?;

                            // Load manifest
                            let manifest = cs.load_manifest(&content_id)?
                                .ok_or_else(|| format!("Manifest not found for {content_id}"))?;

                            let ext = crate::vault::pipeline::ext_from_filename(&manifest.file_name);

                            // Check cache first
                            if let Some(cached_path) = crate::vault::pipeline::check_cache(&content_id, &ext) {
                                return Ok(cached_path.to_string_lossy().to_string());
                            }

                            // Collect local shards
                            let local_shards = cs.list_content_shards(&server_id, &content_id)?;

                            if manifest.k == 0 && manifest.m == 0 {
                                // Replication mode — need just one shard (the full ciphertext)
                                if let Some(record) = local_shards.first() {
                                    let shard_data = cs.read_shard_unchecked(&server_id, &record.shard_key)?;
                                    let packed: Vec<Option<Vec<u8>>> = vec![Some(shard_data)];
                                    let plaintext = crate::vault::pipeline::reconstruct_file(&manifest, &packed)?;
                                    let path = crate::vault::pipeline::write_to_cache(&content_id, &ext, &plaintext)?;
                                    return Ok(path.to_string_lossy().to_string());
                                }
                                Err("No local shard available for replicated content".into())
                            } else {
                                // Erasure mode — need k of k+m shards
                                let k = manifest.k as usize;
                                let m = manifest.m as usize;
                                let n = k + m;
                                let mut packed: Vec<Option<Vec<u8>>> = vec![None; n];

                                for record in &local_shards {
                                    let idx = record.shard_index as usize;
                                    if idx < n {
                                        if let Ok(data) = cs.read_shard_unchecked(&server_id, &record.shard_key) {
                                            packed[idx] = Some(data);
                                        }
                                    }
                                }

                                let available = packed.iter().filter(|s| s.is_some()).count();
                                if available >= k {
                                    let plaintext = crate::vault::pipeline::reconstruct_file(&manifest, &packed)?;
                                    let path = crate::vault::pipeline::write_to_cache(&content_id, &ext, &plaintext)?;
                                    Ok(path.to_string_lossy().to_string())
                                } else {
                                    // Not enough local shards — collect placement info for network fetch.
                                    // Try saved placements first; if empty (non-uploader), recompute deterministically.
                                    let mut placements = cs.load_placements(&content_id).unwrap_or_default();
                                    if placements.is_empty() {
                                        // Recompute from server state using the same deterministic algorithm
                                        if let Some(state) = server_states.get(&server_id) {
                                            let members: Vec<String> = state.members_list().iter().map(|m| m.peer_id.clone()).collect();
                                            let pledges: std::collections::HashMap<String, u64> = members.iter()
                                                .map(|pid| (pid.clone(), state.get_storage_pledge(pid)))
                                                .collect();
                                            let mode = crate::vault::adaptive::compute_adaptive_params(members.len());
                                            let computed = crate::vault::placement::place(&content_id, &mode, &members, &pledges);
                                            placements = computed.iter().map(|sp| crate::vault::content_store::PlacementRecord {
                                                content_id: content_id.clone(),
                                                shard_index: sp.shard_index,
                                                target_peer: sp.target_peer.clone(),
                                                server_id: server_id.clone(),
                                                shard_key: sp.shard_key.clone(),
                                                stored_at: 0,
                                                confirmed: false,
                                            }).collect();
                                        }
                                    }
                                    let missing_indices: Vec<usize> = (0..n)
                                        .filter(|i| packed[*i].is_none())
                                        .collect();
                                    // Encode placement info into error string for post-closure processing
                                    let placement_info: Vec<String> = missing_indices.iter()
                                        .filter_map(|idx| {
                                            placements.iter()
                                                .find(|p| p.shard_index as usize == *idx)
                                                .map(|p| format!("{}:{}:{}", idx, p.target_peer, p.shard_key))
                                        })
                                        .collect();
                                    Err(format!("__NEED_SHARDS__:{}:{}:{}", available, k, placement_info.join("|")))
                                }
                            }
                        })();

                        match result {
                            Ok(disk_path) => {
                                hollow_log!("[HOLLOW-VAULT] Download complete: {disk_path}");
                                let _ = event_tx.send(NetworkEvent::VaultDownloadComplete {
                                    server_id, content_id, disk_path,
                                }).await;
                            }
                            Err(e) if e.starts_with("__NEED_SHARDS__:") => {
                                // Parse placement info and request shards from connected peers
                                let parts: Vec<&str> = e.splitn(4, ':').collect();
                                if parts.len() >= 4 {
                                    let available: usize = parts[1].parse().unwrap_or(0);
                                    let k: usize = parts[2].parse().unwrap_or(3);
                                    let needed = k - available;
                                    let placement_entries: Vec<&str> = parts[3].split('|').filter(|s| !s.is_empty()).collect();

                                    let mut requested = 0usize;
                                    for entry in &placement_entries {
                                        if requested >= needed { break; }
                                        let ep: Vec<&str> = entry.splitn(3, ':').collect();
                                        if ep.len() == 3 {
                                            let si: u16 = ep[0].parse().unwrap_or(0);
                                            let target_peer = ep[1];
                                            let shard_key = ep[2];
                                            if let Ok(pid) = target_peer.parse::<PeerId>() {
                                                if connected_peers.contains(&pid) && olm.has_session(target_peer) {
                                                    let envelope = MessageEnvelope::ShardRequest {
                                                        sid: server_id.clone(),
                                                        cid: content_id.clone(),
                                                        si,
                                                        sk: shard_key.to_string(),
                                                    };
                                                    let json = serde_json::to_string(&envelope).unwrap_or_default();
                                                    send_encrypted_message(
                                                        &mut swarm, &mut olm, &crypto_store,
                                                        &mut pending_requests, &mut outbound_message_text,
                                                        &pid, target_peer, &json, &event_tx,
                                                    ).await;
                                                    hollow_log!("[HOLLOW-VAULT] Requested shard si={si} from {target_peer}");
                                                    requested += 1;
                                                }
                                            }
                                        }
                                    }

                                    if requested > 0 {
                                        pending_vault_downloads.insert(
                                            content_id.clone(),
                                            (server_id.clone(), k, requested),
                                        );
                                        hollow_log!("[HOLLOW-VAULT] Requested {requested} shards for {content_id} (have {available}, need {k})");
                                        let _ = event_tx.send(NetworkEvent::VaultDownloadProgress {
                                            server_id, content_id,
                                            phase: "Fetching shards from peers...".into(),
                                            progress: 0.1,
                                        }).await;
                                    } else {
                                        let _ = event_tx.send(NetworkEvent::VaultDownloadFailed {
                                            server_id, content_id,
                                            error: format!("Not enough shards: have {available}, need {k}. No connected peers have the missing shards."),
                                        }).await;
                                    }
                                }
                            }
                            Err(e) => {
                                hollow_log!("[HOLLOW-VAULT] Download failed: {e}");
                                let _ = event_tx.send(NetworkEvent::VaultDownloadFailed {
                                    server_id, content_id, error: e,
                                }).await;
                            }
                        }
                    }

                    NodeCommand::VaultUploadFile {
                        server_id, channel_id, file_name, mime_type, message_id,
                        ciphertext, aes_key, aes_nonce, original_size, content_id,
                    } => {
                        hollow_log!("[HOLLOW-VAULT] VaultUploadFile: {file_name} cid={content_id} in {server_id}/{channel_id}");

                        let aes_key_copy = aes_key.clone();
                        let aes_nonce_copy = aes_nonce.clone();

                        let upload_result: Result<(), String> = (|| {
                            let state = server_states.get(&server_id)
                                .ok_or_else(|| format!("Server {server_id} not found"))?;
                            let local_peer = swarm.local_peer_id().to_string();

                            // Build members + pledges from server state
                            let members: Vec<String> = state.members.keys().cloned().collect();
                            let pledges: std::collections::HashMap<String, u64> = state.storage_pledges
                                .iter()
                                .map(|(k, v)| (k.clone(), *v.read()))
                                .collect();

                            // Prepare upload plan
                            let key: [u8; 32] = aes_key.try_into().map_err(|_| "Invalid AES key length")?;
                            let nonce: [u8; 12] = aes_nonce.try_into().map_err(|_| "Invalid AES nonce length")?;
                            let plan = crate::vault::pipeline::prepare_upload(
                                &ciphertext, &content_id, &key, &nonce,
                                &file_name, &mime_type, &channel_id,
                                original_size, &local_peer,
                                &members, &pledges,
                            )?;

                            // Open ContentStore for local operations
                            let data_dir = crate::identity::data_dir().unwrap_or_default();
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            let vault_dir = data_dir.join("vault");
                            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                            let cs = crate::vault::content_store::ContentStore::open(&db_path, &passphrase, &vault_dir)?;

                            // Store local shards
                            let tier = crate::vault::content_store::StorageTier::from_str(&plan.manifest.storage_tier);
                            for placement in &plan.placements {
                                if placement.target_peer == local_peer {
                                    if let Some((_, shard_data)) = plan.shards.iter().find(|(idx, _)| *idx == placement.shard_index) {
                                        let _ = cs.store_shard(
                                            &server_id, &content_id, placement.shard_index,
                                            plan.manifest.k, plan.manifest.m, plan.manifest.original_size,
                                            tier, shard_data,
                                        );
                                    }
                                }
                            }

                            // Save placements + manifest
                            let _ = cs.save_placements(&server_id, &content_id, &plan.placements);
                            let _ = cs.save_manifest(&server_id, &channel_id, &plan.manifest);

                            Ok(plan)
                        })().map(|_| ());

                        match upload_result {
                            Err(e) => {
                                hollow_log!("[HOLLOW-VAULT] Upload failed: {e}");
                                let _ = event_tx.send(NetworkEvent::VaultUploadFailed {
                                    server_id, content_id, error: e,
                                }).await;
                            }
                            Ok(()) => {
                                // Re-prepare plan for shard distribution (need the data again)
                                if let Some(state) = server_states.get(&server_id) {
                                    let local_peer = swarm.local_peer_id().to_string();
                                    let members: Vec<String> = state.members.keys().cloned().collect();
                                    let pledges: std::collections::HashMap<String, u64> = state.storage_pledges
                                        .iter().map(|(k, v)| (k.clone(), *v.read())).collect();

                                    let key: [u8; 32] = aes_key_copy.try_into().unwrap_or([0u8; 32]);
                                    let nonce: [u8; 12] = aes_nonce_copy.try_into().unwrap_or([0u8; 12]);
                                    if let Ok(plan) = crate::vault::pipeline::prepare_upload(
                                        &ciphertext, &content_id, &key, &nonce,
                                        &file_name, &mime_type, &channel_id,
                                        original_size, &local_peer, &members, &pledges,
                                    ) {
                                        // Send remote shards via streaming
                                        for placement in &plan.placements {
                                            if placement.target_peer != local_peer {
                                                if let Some((_, shard_data)) = plan.shards.iter().find(|(idx, _)| *idx == placement.shard_index) {
                                                    if let Ok(pid) = placement.target_peer.parse::<PeerId>() {
                                                        if connected_peers.contains(&pid) && olm.has_session(&placement.target_peer) {
                                                            // Send ShardStore metadata via Olm (no data, just metadata).
                                                            let envelope = MessageEnvelope::ShardStore {
                                                                sid: server_id.clone(), cid: content_id.clone(),
                                                                si: placement.shard_index, sk: placement.shard_key.clone(),
                                                                k: plan.manifest.k, m: plan.manifest.m,
                                                                total_size: plan.manifest.original_size,
                                                                tier: plan.manifest.storage_tier.clone(),
                                                                data: String::new(), // empty — data comes via stream
                                                                chunks: 0,
                                                            };
                                                            let json = serde_json::to_string(&envelope).unwrap_or_default();
                                                            send_encrypted_message(
                                                                &mut swarm, &mut olm, &crypto_store,
                                                                &mut pending_requests, &mut outbound_message_text,
                                                                &pid, &placement.target_peer, &json, &event_tx,
                                                            ).await;

                                                            // Stream shard bytes via /hollow/stream/1.0.0.
                                                            if let Ok(stream_req) = super::stream_transfer::shard_stream_request(
                                                                &content_id, placement.shard_index, shard_data,
                                                            ) {
                                                                swarm.behaviour_mut().file_streaming.send_request(
                                                                    &pid, stream_req,
                                                                );
                                                                hollow_log!("[HOLLOW-VAULT] Streaming shard si={} ({} bytes) to {}", placement.shard_index, shard_data.len(), placement.target_peer);
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        // Broadcast manifest via Olm to all connected members
                                        let manifest_json = serde_json::to_string(&plan.manifest).unwrap_or_default();
                                        let manifest_envelope = MessageEnvelope::VaultManifestBroadcast {
                                            sid: server_id.clone(),
                                            cid: content_id.clone(),
                                            chid: channel_id.clone(),
                                            manifest: manifest_json,
                                        };
                                        let manifest_env_json = serde_json::to_string(&manifest_envelope).unwrap_or_default();
                                        for member_peer_str in state.members.keys() {
                                            if member_peer_str == &local_peer { continue; }
                                            if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                                if connected_peers.contains(&pid) && olm.has_session(member_peer_str) {
                                                    send_encrypted_message(
                                                        &mut swarm, &mut olm, &crypto_store,
                                                        &mut pending_requests, &mut outbound_message_text,
                                                        &pid, member_peer_str, &manifest_env_json, &event_tx,
                                                    ).await;
                                                }
                                            }
                                        }
                                    }

                                    hollow_log!("[HOLLOW-VAULT] Upload complete: cid={content_id}");
                                    let _ = event_tx.send(NetworkEvent::VaultUploadComplete {
                                        server_id, content_id, channel_id,
                                    }).await;
                                }
                            }
                        }
                    }

                    NodeCommand::DeleteVaultContent { server_id, content_id } => {
                        if let Some(state) = server_states.get(&server_id) {
                            let local_peer = swarm.local_peer_id().to_string();
                            if !state.has_permission(&local_peer, crate::crdt::operations::Permission::MANAGE_SERVER) {
                                hollow_log!("[HOLLOW-VAULT] Permission denied: cannot delete vault content in {server_id}");
                                continue;
                            }

                            hollow_log!("[HOLLOW-VAULT] Deleting vault content {content_id} in {server_id}");

                            // Delete local shards and placements
                            let data_dir = crate::identity::data_dir().unwrap_or_default();
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            let vault_dir = data_dir.join("vault");
                            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                            if let Ok(cs) = crate::vault::content_store::ContentStore::open(&db_path, &passphrase, &vault_dir) {
                                let _ = cs.delete_content(&server_id, &content_id);
                                let _ = cs.delete_placements(&content_id);
                            }

                            // Broadcast ShardDelete to connected server members
                            let delete_envelope = MessageEnvelope::ShardDelete {
                                sid: server_id.clone(),
                                cid: content_id.clone(),
                            };
                            let delete_json = serde_json::to_string(&delete_envelope).unwrap_or_default();
                            for member_peer_str in state.members.keys() {
                                if member_peer_str == &local_peer { continue; }
                                if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                    if connected_peers.contains(&pid) && olm.has_session(member_peer_str) {
                                        send_encrypted_message(
                                            &mut swarm, &mut olm, &crypto_store,
                                            &mut pending_requests, &mut outbound_message_text,
                                            &pid, member_peer_str, &delete_json, &event_tx,
                                        ).await;
                                    }
                                }
                            }

                            let _ = event_tx.send(NetworkEvent::ShardDeleted {
                                server_id,
                                content_id,
                            }).await;
                        }
                    }

                    NodeCommand::RequestShardFromPeer { server_id, content_id, shard_index, shard_key, target_peer } => {
                        hollow_log!("[HOLLOW-VAULT] RequestShardFromPeer: cid={content_id} si={shard_index} from {target_peer}");
                        if let Ok(pid) = target_peer.parse::<PeerId>() {
                            if !connected_peers.contains(&pid) || !olm.has_session(&target_peer) {
                                hollow_log!("[HOLLOW-VAULT] Cannot request shard: peer {target_peer} not connected or no Olm session");
                                let _ = event_tx.send(NetworkEvent::ShardRequestFailed {
                                    server_id, content_id, shard_index,
                                    error: "Peer not connected or no Olm session".into(),
                                }).await;
                            } else {
                                let envelope = MessageEnvelope::ShardRequest {
                                    sid: server_id,
                                    cid: content_id,
                                    si: shard_index,
                                    sk: shard_key,
                                };
                                let json = serde_json::to_string(&envelope).unwrap_or_default();
                                send_encrypted_message(
                                    &mut swarm, &mut olm, &crypto_store,
                                    &mut pending_requests, &mut outbound_message_text,
                                    &pid, &target_peer, &json, &event_tx,
                                ).await;
                            }
                        }
                    }

                    NodeCommand::StoreShardOnPeer {
                        server_id, content_id, shard_index, shard_key,
                        k, m, total_data_size, storage_tier, data, target_peer,
                    } => {
                        let local_peer = swarm.local_peer_id().to_string();
                        hollow_log!("[HOLLOW-VAULT] StoreShardOnPeer: cid={content_id} si={shard_index} -> {target_peer}");

                        if let Ok(pid) = target_peer.parse::<PeerId>() {
                            if !connected_peers.contains(&pid) || !olm.has_session(&target_peer) {
                                hollow_log!("[HOLLOW-VAULT] Cannot store shard: peer {target_peer} not connected or no Olm session");
                                let _ = event_tx.send(NetworkEvent::ShardStoreFailed {
                                    server_id: server_id.clone(),
                                    content_id: content_id.clone(),
                                    shard_index,
                                    target_peer: target_peer.clone(),
                                    error: "Peer not connected or no Olm session".into(),
                                }).await;
                            } else {
                                // Send ShardStore metadata via Olm (no data — stream follows).
                                let envelope = MessageEnvelope::ShardStore {
                                    sid: server_id.clone(),
                                    cid: content_id.clone(),
                                    si: shard_index,
                                    sk: shard_key.clone(),
                                    k,
                                    m,
                                    total_size: total_data_size,
                                    tier: storage_tier.clone(),
                                    data: String::new(),
                                    chunks: 0,
                                };
                                let json = serde_json::to_string(&envelope).unwrap_or_default();
                                send_encrypted_message(
                                    &mut swarm, &mut olm, &crypto_store,
                                    &mut pending_requests, &mut outbound_message_text,
                                    &pid, &target_peer, &json, &event_tx,
                                ).await;

                                // Stream shard bytes via /hollow/stream/1.0.0.
                                if let Ok(stream_req) = super::stream_transfer::shard_stream_request(
                                    &content_id, shard_index, &data,
                                ) {
                                    swarm.behaviour_mut().file_streaming.send_request(
                                        &pid, stream_req,
                                    );
                                    hollow_log!("[HOLLOW-VAULT] Streaming shard si={shard_index} ({} bytes) to {target_peer}", data.len());
                                }
                            }
                        } else {
                            hollow_log!("[HOLLOW-VAULT] Invalid target_peer: {target_peer}");
                        }
                    }

                    // -- File sharing (Phase 3.5) --
                    NodeCommand::SendFile { peer_id, server_id, channel_id, file_path, message_id, message_text } => {
                        use crate::node::file_transfer;
                        use crate::node::image_convert;

                        hollow_log!("[HOLLOW-FILE] SendFile: {file_path} mid={message_id}");

                        // 1. Read file from disk.
                        let file_data = match std::fs::read(&file_path) {
                            Ok(d) => d,
                            Err(e) => {
                                hollow_log!("[HOLLOW-FILE] Failed to read file: {e}");
                                let _ = event_tx.send(NetworkEvent::FileFailed {
                                    file_id: message_id.clone(),
                                    error: format!("Failed to read file: {e}"),
                                }).await;
                                continue;
                            }
                        };

                        // 2. Extract filename and extension.
                        let path = std::path::Path::new(&file_path);
                        let original_name = path.file_name()
                            .unwrap_or_default()
                            .to_string_lossy()
                            .to_string();
                        let original_ext = path.extension()
                            .unwrap_or_default()
                            .to_string_lossy()
                            .to_lowercase();

                        // 3. Check size limit (34MB default).
                        let max_size = if let Some(ref sid) = server_id {
                            server_states.get(sid)
                                .and_then(|s| s.settings.get("max_file_size_mb"))
                                .and_then(|reg| reg.read().parse::<u64>().ok())
                                .unwrap_or(34) * 1024 * 1024
                        } else {
                            file_transfer::DEFAULT_MAX_FILE_SIZE
                        };

                        if file_data.len() as u64 > max_size {
                            hollow_log!("[HOLLOW-FILE] File too large: {} > {}", file_data.len(), max_size);
                            let _ = event_tx.send(NetworkEvent::FileFailed {
                                file_id: message_id.clone(),
                                error: format!("File too large ({}MB limit)", max_size / 1024 / 1024),
                            }).await;
                            continue;
                        }

                        // 4. Convert to WebP if image.
                        let mime = file_transfer::mime_from_ext(&original_ext);
                        let is_image = file_transfer::is_image_mime(&mime);
                        let (final_data, final_ext, width, height) = if is_image && image_convert::should_convert_to_webp(&original_ext) {
                            match image_convert::convert_to_webp_lossless(&file_data) {
                                Ok((webp_data, w, h)) => {
                                    hollow_log!("[HOLLOW-FILE] Converted to WebP: {}KB -> {}KB ({}x{})",
                                        file_data.len() / 1024, webp_data.len() / 1024, w, h);
                                    (webp_data, "webp".to_string(), Some(w), Some(h))
                                }
                                Err(e) => {
                                    hollow_log!("[HOLLOW-FILE] WebP conversion failed, sending original: {e}");
                                    let dims = image_convert::get_image_dimensions(&file_data).ok();
                                    (file_data.clone(), original_ext.clone(), dims.map(|d| d.0), dims.map(|d| d.1))
                                }
                            }
                        } else if is_image && original_ext == "webp" {
                            let dims = image_convert::get_image_dimensions(&file_data).ok();
                            (file_data.clone(), original_ext.clone(), dims.map(|d| d.0), dims.map(|d| d.1))
                        } else {
                            (file_data.clone(), original_ext.clone(), None, None)
                        };

                        // 5. Generate file ID.
                        let file_id = file_transfer::generate_file_id();
                        let file_size = final_data.len() as u64;
                        let total_chunks = 0u32; // 0 = streamed transfer
                        let final_mime = file_transfer::mime_from_ext(&final_ext);

                        hollow_log!("[HOLLOW-FILE] File {file_id}: {original_name} -> {file_size} bytes (streamed)");

                        // 6. Store file locally.
                        let final_path = file_transfer::final_file_path(&file_id, &final_ext);
                        if let Err(e) = std::fs::write(&final_path, &final_data) {
                            hollow_log!("[HOLLOW-FILE] Failed to save local file: {e}");
                        }

                        let local_peer = swarm.local_peer_id().to_string();
                        let timestamp = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as i64;

                        // 7. Save file metadata to DB.
                        let ctx_type;
                        let ctx_id;
                        if let Some(ref sid) = server_id {
                            ctx_type = "channel";
                            ctx_id = format!("{}:{}", sid, channel_id.as_deref().unwrap_or(""));
                        } else {
                            ctx_type = "dm";
                            ctx_id = peer_id.map(|p| p.to_string()).unwrap_or_default();
                        }

                        {
                            let data_dir = crate::identity::data_dir().unwrap_or_default();
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                let _ = store.insert_file_metadata(
                                    &file_id, &original_name, &final_ext, &final_mime,
                                    file_size, total_chunks, is_image,
                                    width, height,
                                    Some(&message_id), ctx_type, &ctx_id,
                                    &local_peer, true, timestamp,
                                );
                                let _ = store.mark_file_complete(
                                    &file_id,
                                    &final_path.to_string_lossy(),
                                );
                            }
                        }

                        // 8. Build and send the message with file_id.
                        let signing_payload_text = if message_text.is_empty() {
                            format!("[file:{}]", file_id)
                        } else {
                            message_text.clone()
                        };

                        let (sig, pk) = sign_message(&bundle_keypair, &pub_key_b64, &signing_payload_text);

                        if let Some(target_peer) = peer_id {
                            // DM path
                            let peer_str = target_peer.to_string();
                            let envelope = MessageEnvelope::DirectMessage {
                                text: signing_payload_text.clone(),
                                ts: timestamp,
                                sig: sig.clone(),
                                pk: pk.clone(),
                                mid: Some(message_id.clone()),
                                reply_to: None,
                                file_id: Some(file_id.clone()),
                            };
                            let envelope_json = serde_json::to_string(&envelope)
                                .unwrap_or_else(|_| signing_payload_text.clone());

                            // Store the text message.
                            {
                                let data_dir = crate::identity::data_dir().unwrap_or_default();
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let _ = store.insert(
                                        &peer_str, &signing_payload_text, true, timestamp,
                                        sig.as_deref(), pk.as_deref(), Some(&message_id),
                                        None, Some(&file_id),
                                    );
                                }
                            }

                            // Encrypt and send the message + FileHeader + FileChunks via Olm.
                            if olm.has_session(&peer_str) {
                                // Send message envelope.
                                send_encrypted_message(
                                    &mut swarm, &mut olm, &crypto_store,
                                    &mut pending_requests, &mut outbound_message_text,
                                    &target_peer, &peer_str, &envelope_json, &event_tx,
                                ).await;

                                // Only send file data if peer is connected right now.
                                // If offline, the file_id is in the message — sync will request it later.
                                if connected_peers.contains(&target_peer) {

                                // AES-encrypt the file, write ciphertext to temp file.
                                let encrypted = crate::vault::pipeline::aes_encrypt(&final_data);
                                if let Ok(enc) = encrypted {
                                    let temp_path = file_transfer::files_dir().join(format!(".stream_send_{file_id}.tmp"));
                                    if let Ok(()) = std::fs::write(&temp_path, &enc.ciphertext) {
                                        let aes_key_hex = hex::encode(enc.key);
                                        let aes_nonce_hex = hex::encode(enc.nonce);

                                        // Send FileHeader via Olm (carries AES key — tiny, secure).
                                        let header = MessageEnvelope::FileHeader {
                                            fid: file_id.clone(),
                                            name: original_name.clone(),
                                            ext: final_ext.clone(),
                                            mime: final_mime.clone(),
                                            size: file_size,
                                            chunks: 0, // 0 = streamed transfer
                                            img: is_image,
                                            w: width,
                                            h: height,
                                            mid: Some(message_id.clone()),
                                            sid: None,
                                            cid: None,
                                            ts: timestamp,
                                            sig: None,
                                            pk: None,
                                            aes_key: Some(aes_key_hex),
                                            aes_nonce: Some(aes_nonce_hex),
                                        };
                                        let header_json = serde_json::to_string(&header).unwrap_or_default();
                                        send_encrypted_message(
                                            &mut swarm, &mut olm, &crypto_store,
                                            &mut pending_requests, &mut outbound_message_text,
                                            &target_peer, &peer_str, &header_json, &event_tx,
                                        ).await;

                                        // Stream encrypted file bytes via /hollow/stream/1.0.0.
                                        let stream_req = super::stream_transfer::file_stream_request(
                                            &file_id, temp_path, enc.ciphertext.len() as u64,
                                        );
                                        swarm.behaviour_mut().file_streaming.send_request(
                                            &target_peer, stream_req,
                                        );
                                        hollow_log!("[HOLLOW-FILE] Streaming {file_id} ({} bytes) to DM {peer_str}", enc.ciphertext.len());
                                    }
                                }
                                } // if connected_peers (file data only)
                            }

                            hollow_log!("[HOLLOW-FILE] Sent {total_chunks} chunks for {file_id} to DM {peer_str}");

                        } else if let (Some(sid), Some(cid)) = (server_id, channel_id) {
                            // Channel path — broadcast via MLS.
                            let envelope = MessageEnvelope::ChannelMessage {
                                sid: sid.clone(),
                                cid: cid.clone(),
                                text: signing_payload_text.clone(),
                                ts: timestamp,
                                sig: sig.clone(),
                                pk: pk.clone(),
                                mid: Some(message_id.clone()),
                                reply_to: None,
                                file_id: Some(file_id.clone()),
                            };
                            let envelope_json = serde_json::to_string(&envelope)
                                .unwrap_or_else(|_| signing_payload_text.clone());

                            // Store the text message.
                            {
                                let data_dir = crate::identity::data_dir().unwrap_or_default();
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let _ = store.insert_channel_message(
                                        &sid, &cid, &local_peer, &signing_payload_text, true, timestamp,
                                        sig.as_deref(), pk.as_deref(), Some(&message_id),
                                        None, Some(&file_id),
                                    );
                                }
                            }

                            // Send the TEXT MESSAGE via MLS (for proper sync/queue to offline peers).
                            // Only one MLS encrypt call — no SecretReuseError risk.
                            if let Some(ref mut mls_mgr) = mls {
                                if let Ok(ct) = mls_mgr.encrypt(&sid, envelope_json.as_bytes()) {
                                    let mls_msg = HavenMessage::MlsChannelMessage {
                                        server_id: sid.clone(),
                                        body: base64::engine::general_purpose::STANDARD.encode(&ct),
                                    };
                                    if let Some(state) = server_states.get(&sid) {
                                        for member_peer_str in state.members.keys() {
                                            if member_peer_str == &local_peer { continue; }
                                            if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                                if connected_peers.contains(&pid) {
                                                    swarm.behaviour_mut().messaging.send_request(
                                                        &pid, mls_msg.clone(),
                                                    );
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            // Send FileHeader + file bytes via stream to connected peers.
                            // Skip full-file streaming in erasure coding mode (6+ members) —
                            // vault shards are distributed separately via VaultUploadFile.
                            let member_count = server_states.get(&sid)
                                .map(|s| s.members.len())
                                .unwrap_or(0);
                            let use_vault_only = member_count >= 6;

                            let encrypted = crate::vault::pipeline::aes_encrypt(&final_data);
                            if let Ok(enc) = encrypted {
                                let aes_key_hex = hex::encode(&enc.key);
                                let aes_nonce_hex = hex::encode(&enc.nonce);

                                let header = MessageEnvelope::FileHeader {
                                    fid: file_id.clone(),
                                    name: original_name.clone(),
                                    ext: final_ext.clone(),
                                    mime: final_mime.clone(),
                                    size: file_size,
                                    chunks: 0,
                                    img: is_image,
                                    w: width,
                                    h: height,
                                    mid: Some(message_id.clone()),
                                    sid: Some(sid.clone()),
                                    cid: Some(cid.clone()),
                                    ts: timestamp,
                                    sig: None,
                                    pk: None,
                                    aes_key: Some(aes_key_hex),
                                    aes_nonce: Some(aes_nonce_hex),
                                };
                                let header_json = serde_json::to_string(&header).unwrap_or_default();

                                // Write ciphertext to temp file (shared across all members).
                                let temp_path = file_transfer::files_dir().join(format!(".stream_send_{file_id}.tmp"));
                                let _ = std::fs::write(&temp_path, &enc.ciphertext);
                                let ct_size = enc.ciphertext.len() as u64;

                                if let Some(state) = server_states.get(&sid) {
                                    if use_vault_only {
                                        // Erasure coding mode: send only the message metadata (FileHeader)
                                        // via Olm so peers know a file exists, but do NOT stream full bytes.
                                        // Vault shards handle actual data distribution.
                                        for member_peer_str in state.members.keys() {
                                            if member_peer_str == &local_peer { continue; }
                                            if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                                if connected_peers.contains(&pid) && olm.has_session(member_peer_str) {
                                                    send_encrypted_message(
                                                        &mut swarm, &mut olm, &crypto_store,
                                                        &mut pending_requests, &mut outbound_message_text,
                                                        &pid, member_peer_str, &header_json, &event_tx,
                                                    ).await;
                                                }
                                            }
                                        }
                                        hollow_log!("[HOLLOW-FILE] Erasure coding active ({member_count} members) — skipping full-file streaming, vault handles shard distribution");
                                    } else {
                                    // Full replication: stream entire encrypted file to each member.
                                    for member_peer_str in state.members.keys() {
                                        if member_peer_str == &local_peer { continue; }
                                        if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                            if connected_peers.contains(&pid) && olm.has_session(member_peer_str) {
                                                // Send FileHeader via Olm (carries AES key).
                                                send_encrypted_message(
                                                    &mut swarm, &mut olm, &crypto_store,
                                                    &mut pending_requests, &mut outbound_message_text,
                                                    &pid, member_peer_str, &header_json, &event_tx,
                                                ).await;

                                                // Stream encrypted file bytes via /hollow/stream/1.0.0.
                                                let stream_req = super::stream_transfer::file_stream_request(
                                                    &file_id, temp_path.clone(), ct_size,
                                                );
                                                swarm.behaviour_mut().file_streaming.send_request(
                                                    &pid, stream_req,
                                                );
                                            }
                                        }
                                    }
                                    }
                                }
                            }

                            hollow_log!("[HOLLOW-FILE] Streamed {file_id} to channel {cid}");
                        }
                    }

                    NodeCommand::RequestFile { file_id, peer_id, chunks } => {
                        // Send a FileRequest HavenMessage to the remote peer,
                        // asking them to send us the file data.
                        hollow_log!("[HOLLOW-FILE] Requesting file {file_id} from peer {peer_id}");
                        if connected_peers.contains(&peer_id) {
                            swarm.behaviour_mut().messaging.send_request(
                                &peer_id,
                                HavenMessage::FileRequest {
                                    file_id,
                                    chunks,
                                },
                            );
                        }
                    }

                    NodeCommand::NotifyShutdown => {
                        // Broadcast graceful disconnect to all connected peers.
                        hollow_log!("[HOLLOW-SWARM] Notifying {} peers of shutdown", connected_peers.len());
                        for pid in connected_peers.iter() {
                            if relay_peer_id() == Some(*pid) { continue; }
                            swarm.behaviour_mut().messaging.send_request(
                                pid,
                                HavenMessage::PeerDisconnecting,
                            );
                        }

                        // Unregister from signaling server so peers don't see us as online.
                        if let Some(room) = active_room.as_ref() {
                            let _ = sig_cmd_tx.send(SignalingCmd::Unregister {
                                room_code: room.clone(),
                            }).await;
                        }
                        for sid in server_states.keys() {
                            let _ = sig_cmd_tx.send(SignalingCmd::Unregister {
                                room_code: sid.clone(),
                            }).await;
                        }
                    }
                }
            }
            // Handle swarm events.
            event = swarm.select_next_some() => {
                match event {
                    SwarmEvent::NewListenAddr { address, .. } => {
                        let addr_str = address.to_string();
                        let is_new = !known_addresses.contains(&addr_str);
                        let is_circuit = addr_str.contains("p2p-circuit");
                        if is_new {
                            known_addresses.push(addr_str.clone());

                            // Push updated addresses to signaling so relay circuit
                            // addresses get registered for other peers to find us.
                            let registerable: Vec<String> = known_addresses.iter()
                                .filter(|a| is_registerable_address(a))
                                .cloned()
                                .collect();
                            let _ = sig_cmd_tx.send(SignalingCmd::UpdateAddresses {
                                addresses: registerable,
                            }).await;

                            // When a relay circuit address appears, bootstrap to
                            // discover peers that registered before us.
                            if is_circuit {
                                if let Some(room) = &active_room {
                                    let _ = event_tx
                                        .send(NetworkEvent::Error {
                                            message: "[DEBUG] Relay circuit up — bootstrapping...".to_string(),
                                        })
                                        .await;
                                    let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
                                        room_code: room.clone(),
                                    }).await;
                                }

                                // Register + bootstrap in all server signaling rooms.
                                let reg_addrs: Vec<String> = known_addresses.iter()
                                    .filter(|a| is_registerable_address(a))
                                    .cloned()
                                    .collect();
                                for sid in server_states.keys() {
                                    let _ = sig_cmd_tx.send(SignalingCmd::Register {
                                        room_code: sid.clone(),
                                        addresses: reg_addrs.clone(),
                                    }).await;
                                    let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
                                        room_code: sid.clone(),
                                    }).await;
                                }

                                // Register + bootstrap DM room codes for all accepted friends.
                                {
                                    let data_dir = crate::identity::data_dir().unwrap_or_default();
                                    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                    if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                            if let Ok(friends) = store.load_friends(None) {
                                                let local_peer = swarm.local_peer_id().to_string();
                                                hollow_log!("[HOLLOW-FRIENDS] Registering {} friend DM room codes", friends.len());
                                                for (friend_pid, _, _, _, _) in &friends {
                                                    let room = dm_room_code(&local_peer, friend_pid);
                                                    let _ = sig_cmd_tx.send(SignalingCmd::Register {
                                                        room_code: room.clone(),
                                                        addresses: reg_addrs.clone(),
                                                    }).await;
                                                    let _ = sig_cmd_tx.send(SignalingCmd::SetRoom {
                                                        room_code: room.clone(),
                                                    }).await;
                                                    let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
                                                        room_code: room,
                                                    }).await;
                                                }
                                            }
                                        }
                                    }
                                }

                                // Publish prekey bundle to DHT now that we're routable.
                                let peer_id_str = swarm.local_peer_id().to_string();
                                match publish_prekey_bundle(
                                    &mut swarm, &bundle_keypair, &peer_id_str, &pub_key_b64,
                                    &mut olm, &crypto_store,
                                ) {
                                    Ok(()) => {
                                        prekey_published = true;
                                        let _ = event_tx.send(NetworkEvent::Error {
                                            message: "[DHT] Prekey bundle published".to_string(),
                                        }).await;
                                    }
                                    Err(e) => {
                                        let _ = event_tx.send(NetworkEvent::Error {
                                            message: format!("[DHT] Prekey publish failed: {e}"),
                                        }).await;
                                    }
                                }
                            }
                        }
                        let _ = event_tx
                            .send(NetworkEvent::Listening {
                                address: addr_str,
                            })
                            .await;
                    }
                    SwarmEvent::Behaviour(HavenBehaviourEvent::Mdns(mdns::Event::Discovered(peers))) => {
                        for (peer_id, addr) in peers {
                            swarm.add_peer_address(peer_id, addr.clone());
                            // Seed Kademlia DHT from LAN peers discovered via mDNS.
                            swarm.behaviour_mut().kademlia.add_address(&peer_id, addr.clone());
                            expected_peers.insert(peer_id);
                            let _ = event_tx.send(NetworkEvent::ConnectionAttemptStarted {
                                peer_id: peer_id.to_string(),
                                method: "mdns".to_string(),
                            }).await;
                            // Dedup: only emit PeerDiscovered once per session.
                            if discovered_peers.insert(peer_id) {
                                let peer_id_str = peer_id.to_string();
                                let _ = event_tx
                                    .send(NetworkEvent::PeerDiscovered {
                                        peer: DiscoveredPeer {
                                            peer_id: peer_id_str.clone(),
                                            addresses: vec![addr.to_string()],
                                        },
                                    })
                                    .await;
                                if olm.has_session(&peer_id_str) {
                                    let _ = event_tx
                                        .send(NetworkEvent::SessionEstablished {
                                            peer_id: peer_id_str,
                                        })
                                        .await;
                                }
                            }
                        }
                    }
                    SwarmEvent::Behaviour(HavenBehaviourEvent::Mdns(mdns::Event::Expired(peers))) => {
                        for (peer_id, _addr) in peers {
                            let _ = event_tx
                                .send(NetworkEvent::PeerExpired {
                                    peer_id: peer_id.to_string(),
                                })
                                .await;
                        }
                    }
                    SwarmEvent::Behaviour(HavenBehaviourEvent::Messaging(event)) => {
                        match event {
                            request_response::Event::Message { peer, message, .. } => {
                                match message {
                                    request_response::Message::Request { request, channel, .. } => {
                                        // SECURITY: Per-peer rate limiting.
                                        {
                                            let (tokens, last_refill) = peer_rate_tokens
                                                .entry(peer)
                                                .or_insert((RATE_LIMIT_BURST, std::time::Instant::now()));
                                            let elapsed = last_refill.elapsed().as_secs_f64();
                                            let refill = (elapsed * RATE_LIMIT_REFILL as f64) as u32;
                                            if refill > 0 {
                                                *tokens = (*tokens + refill).min(RATE_LIMIT_BURST);
                                                *last_refill = std::time::Instant::now();
                                            }
                                            if *tokens == 0 {
                                                hollow_log!("[HOLLOW-SECURITY] Rate limited peer {peer} — dropping message");
                                                let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);
                                                continue;
                                            }
                                            *tokens -= 1;
                                        }
                                        handle_incoming_request(
                                            &mut swarm,
                                            &mut olm,
                                            &crypto_store,
                                            &event_tx,
                                            &mut pending_requests,
                                            &mut outbound_message_text,
                                            &mut pending_messages,
                                            &mut key_request_in_flight,
                                            &mut server_states,
                                            &bundle_keypair,
                                            &mut connected_peers,
                                            &mut pending_server_joins,
                                            &mut pending_sync_requests,
                                            &mut mls,
                                            &mut discovered_peers,
                                            &mut disconnected_peers,
                                            &mut pending_disconnects,
                                            &mut mls_bootstrap_requested,
                                            &sig_cmd_tx,
                                            &known_addresses,
                                            &mut pending_shard_assembly,
                                            &mut pending_file_streams,
                                            &mut pending_shard_streams,
                                            &mut decrypt_fail_cooldown,
                                            &mut pending_mls_key_packages,
                                            &mut mls_decrypt_failures,
                                            peer,
                                            request,
                                            channel,
                                        ).await;
                                    }
                                    request_response::Message::Response { request_id, response, .. } => {
                                        handle_incoming_response(
                                            &mut swarm,
                                            &mut olm,
                                            &crypto_store,
                                            &event_tx,
                                            &mut pending_requests,
                                            &mut outbound_message_text,
                                            &mut pending_messages,
                                            &mut key_request_in_flight,
                                            &mut pending_sync_requests,
                                            &bundle_keypair,
                                            request_id,
                                            response,
                                        ).await;
                                    }
                                }
                            }
                            request_response::Event::OutboundFailure { request_id, error, .. } => {
                                if let Some(to_peer) = pending_requests.remove(&request_id) {
                                    key_request_in_flight.remove(&to_peer);

                                    // If this was an encrypted message, re-queue the original
                                    // text so it can be retried when the connection is established.
                                    if let Some((_peer_str, original_text)) = outbound_message_text.remove(&request_id) {
                                        hollow_log!("[HOLLOW-SWARM] OutboundFailure for {to_peer}, re-queuing message for retry");
                                        pending_messages
                                            .entry(to_peer.clone())
                                            .or_default()
                                            .push(original_text);
                                        // Don't remove the Olm session here — transport failures
                                        // (relay timeout, connection drop) don't mean the crypto
                                        // session is broken. Removing it causes a dual-outbound
                                        // race on reconnect where both peers create new sessions
                                        // from DHT prekeys and neither can decrypt the other's.
                                    } else {
                                        // Not a message send (was a KeyRequest or similar) — report failure.
                                        let _ = event_tx
                                            .send(NetworkEvent::MessageSendFailed {
                                                to_peer,
                                                error: format!("{error:?}"),
                                            })
                                            .await;
                                    }
                                }
                            }
                            _ => {}
                        }
                    }

                    // -- File streaming events (/hollow/stream/1.0.0) --
                    SwarmEvent::Behaviour(HavenBehaviourEvent::FileStreaming(event)) => {
                        match event {
                            request_response::Event::Message { peer, message, .. } => {
                                match message {
                                    request_response::Message::Request { request, channel, .. } => {
                                        // Inbound stream transfer completed — codec wrote data to temp file.
                                        use crate::node::file_transfer;
                                        use super::stream_transfer::StreamKind;

                                        let peer_str = peer.to_string();

                                        match request.kind {
                                            StreamKind::File => {
                                                let file_id = request.id.clone();
                                                hollow_log!("[HOLLOW-STREAM] Inbound file stream: {file_id} ({} bytes)", request.size);

                                                // Look up the pending file stream (registered by FileHeader).
                                                if let Some(pfs) = pending_file_streams.remove(&file_id) {
                                                    // Decrypt the temp file with AES key from FileHeader.
                                                    if let Ok(ciphertext) = std::fs::read(&request.temp_path) {
                                                        let key_bytes = hex::decode(&pfs.aes_key).unwrap_or_default();
                                                        let nonce_bytes = hex::decode(&pfs.aes_nonce).unwrap_or_default();
                                                        if key_bytes.len() == 32 && nonce_bytes.len() == 12 {
                                                            let key: [u8; 32] = key_bytes.try_into().unwrap();
                                                            let nonce: [u8; 12] = nonce_bytes.try_into().unwrap();
                                                            match crate::vault::pipeline::aes_decrypt(&ciphertext, &key, &nonce) {
                                                                Ok(plaintext) => {
                                                                    let final_path = file_transfer::final_file_path(&file_id, &pfs.ext);
                                                                    if let Ok(()) = std::fs::write(&final_path, &plaintext) {
                                                                        // Update DB.
                                                                        let data_dir = crate::identity::data_dir().unwrap_or_default();
                                                                        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                                                        if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                                                                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                                                            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                                                                let disk_path = final_path.to_string_lossy().to_string();
                                                                                let _ = store.mark_file_complete(&file_id, &disk_path);
                                                                            }
                                                                        }
                                                                        let disk_path = final_path.to_string_lossy().to_string();
                                                                        hollow_log!("[HOLLOW-STREAM] File {file_id} complete: {disk_path}");
                                                                        let _ = event_tx.send(NetworkEvent::FileCompleted {
                                                                            file_id,
                                                                            disk_path,
                                                                        }).await;
                                                                    } else {
                                                                        hollow_log!("[HOLLOW-STREAM] Failed to write decrypted file {file_id}");
                                                                    }
                                                                }
                                                                Err(e) => {
                                                                    hollow_log!("[HOLLOW-STREAM] AES decrypt failed for {file_id}: {e}");
                                                                    let _ = event_tx.send(NetworkEvent::FileFailed {
                                                                        file_id,
                                                                        error: format!("Decrypt failed: {e}"),
                                                                    }).await;
                                                                }
                                                            }
                                                        }
                                                    }
                                                    // Clean up temp file.
                                                    let _ = std::fs::remove_file(&request.temp_path);
                                                } else {
                                                    hollow_log!("[HOLLOW-STREAM] No pending FileHeader for stream {file_id} — ignoring");
                                                    let _ = std::fs::remove_file(&request.temp_path);
                                                }
                                            }
                                            StreamKind::Shard { shard_index } => {
                                                let content_id = request.id.clone();
                                                let key = format!("{content_id}:{shard_index}");
                                                hollow_log!("[HOLLOW-STREAM] Inbound shard stream: cid={content_id} si={shard_index} ({} bytes)", request.size);

                                                if let Some(pss) = pending_shard_streams.remove(&key) {
                                                    if let Ok(shard_bytes) = std::fs::read(&request.temp_path) {
                                                        let data_dir = crate::identity::data_dir().unwrap_or_default();
                                                        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                                        let vault_dir = data_dir.join("vault");
                                                        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                                        if let Ok(content_store) = crate::vault::content_store::ContentStore::open(&db_path, &passphrase, &vault_dir) {
                                                            let tier = crate::vault::content_store::StorageTier::from_str(&pss.tier);
                                                            let _ = content_store.store_shard(
                                                                &pss.server_id, &pss.content_id, pss.shard_index,
                                                                pss.k, pss.m, pss.total_size, tier, &shard_bytes,
                                                            );
                                                            hollow_log!("[HOLLOW-STREAM] Shard stored: cid={content_id} si={shard_index}");
                                                            let _ = event_tx.send(NetworkEvent::ShardStored {
                                                                server_id: pss.server_id.clone(),
                                                                content_id: content_id.clone(),
                                                                shard_index,
                                                                from_peer: peer_str.clone(),
                                                            }).await;

                                                            // Check if a pending download can now be completed
                                                            if let Some((dl_server_id, dl_k, _)) = pending_vault_downloads.remove(&content_id) {
                                                                hollow_log!("[HOLLOW-VAULT] Shard arrived for pending download — attempting reconstruction: {content_id}");
                                                                // Re-check local shards and attempt reconstruction
                                                                if let Ok(manifest) = content_store.load_manifest(&content_id) {
                                                                    if let Some(manifest) = manifest {
                                                                        let n = dl_k + manifest.m as usize;
                                                                        let local_shards = content_store.list_content_shards(&dl_server_id, &content_id).unwrap_or_default();
                                                                        let mut packed: Vec<Option<Vec<u8>>> = vec![None; n];
                                                                        for record in &local_shards {
                                                                            let idx = record.shard_index as usize;
                                                                            if idx < n {
                                                                                if let Ok(data) = content_store.read_shard_unchecked(&dl_server_id, &record.shard_key) {
                                                                                    packed[idx] = Some(data);
                                                                                }
                                                                            }
                                                                        }
                                                                        let avail = packed.iter().filter(|s| s.is_some()).count();
                                                                        if avail >= dl_k {
                                                                            let ext = crate::vault::pipeline::ext_from_filename(&manifest.file_name);
                                                                            match crate::vault::pipeline::reconstruct_file(&manifest, &packed) {
                                                                                Ok(plaintext) => {
                                                                                    if let Ok(path) = crate::vault::pipeline::write_to_cache(&content_id, &ext, &plaintext) {
                                                                                        let disk_path = path.to_string_lossy().to_string();
                                                                                        hollow_log!("[HOLLOW-VAULT] Download reconstructed: {disk_path}");
                                                                                        let _ = event_tx.send(NetworkEvent::VaultDownloadComplete {
                                                                                            server_id: dl_server_id, content_id: content_id.clone(), disk_path,
                                                                                        }).await;
                                                                                    }
                                                                                }
                                                                                Err(e) => {
                                                                                    hollow_log!("[HOLLOW-VAULT] Reconstruction failed: {e}");
                                                                                    let _ = event_tx.send(NetworkEvent::VaultDownloadFailed {
                                                                                        server_id: dl_server_id, content_id: content_id.clone(), error: e,
                                                                                    }).await;
                                                                                }
                                                                            }
                                                                        } else {
                                                                            // Still not enough — put back in pending
                                                                            pending_vault_downloads.insert(content_id.clone(), (dl_server_id, dl_k, 0));
                                                                            hollow_log!("[HOLLOW-VAULT] Still need more shards: have {avail}, need {dl_k}");
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                    let _ = std::fs::remove_file(&request.temp_path);
                                                } else {
                                                    hollow_log!("[HOLLOW-STREAM] No pending ShardStore for stream {key} — ignoring");
                                                    let _ = std::fs::remove_file(&request.temp_path);
                                                }
                                            }
                                        }

                                        // Send ack response.
                                        let _ = swarm.behaviour_mut().file_streaming.send_response(
                                            channel,
                                            super::stream_transfer::StreamResponse { ok: true },
                                        );
                                    }
                                    request_response::Message::Response { .. } => {
                                        // Outbound stream completed — clean up temp files.
                                        hollow_log!("[HOLLOW-STREAM] Outbound stream transfer completed");
                                    }
                                }
                            }
                            request_response::Event::OutboundFailure { request_id, error, .. } => {
                                hollow_log!("[HOLLOW-STREAM] Stream transfer failed: {error:?}");
                            }
                            _ => {}
                        }
                    }

                    // -- Kademlia DHT events --
                    SwarmEvent::Behaviour(HavenBehaviourEvent::Kademlia(event)) => {
                        match event {
                            kad::Event::RoutingUpdated { peer, addresses, .. } => {
                                // A peer was added/updated in the routing table.
                                for addr in addresses.iter() {
                                    swarm.add_peer_address(peer, addr.clone());
                                }
                            }
                            kad::Event::OutboundQueryProgressed { id, result, .. } => {
                                match result {
                                    kad::QueryResult::Bootstrap(Ok(_)) => {
                                        // Bootstrap completed — DHT routing table populated.
                                    }
                                    kad::QueryResult::Bootstrap(Err(e)) => {
                                        let _ = event_tx
                                            .send(NetworkEvent::Error {
                                                message: format!("Kademlia bootstrap failed: {e:?}"),
                                            })
                                            .await;
                                    }
                                    kad::QueryResult::PutRecord(Ok(_)) => {
                                        let _ = event_tx.send(NetworkEvent::Error {
                                            message: "[DHT] put_record succeeded".to_string(),
                                        }).await;
                                    }
                                    kad::QueryResult::PutRecord(Err(e)) => {
                                        let _ = event_tx.send(NetworkEvent::Error {
                                            message: format!("[DHT] put_record failed: {e:?}"),
                                        }).await;
                                    }
                                    kad::QueryResult::GetRecord(Ok(
                                        kad::GetRecordOk::FoundRecord(kad::PeerRecord { record, .. })
                                    )) => {
                                        // Check if this is a prekey fetch we initiated.
                                        hollow_log!("[HOLLOW-SWARM] GetRecord FoundRecord for query {:?}", id);
                                        if let Some(target_peer) = pending_prekey_fetches.remove(&id) {
                                            hollow_log!("[HOLLOW-SWARM] Found prekey record for {target_peer}");
                                            dht_fetch_in_flight.remove(&target_peer);
                                            let _ = event_tx.send(NetworkEvent::KeyExchangeProgress {
                                                peer_id: target_peer.clone(),
                                                stage: "prekey_found".to_string(),
                                            }).await;

                                            let mut used = false;
                                            if let Ok(bundle) = serde_json::from_slice::<PrekeyBundle>(&record.value)
                                                && bundle.peer_id == target_peer
                                            {
                                                match verify_prekey_bundle(&bundle) {
                                                    Ok(true) => {
                                                        // Pick a random OTK to reduce collisions.
                                                        let idx = (std::time::SystemTime::now()
                                                            .duration_since(std::time::UNIX_EPOCH)
                                                            .unwrap_or_default()
                                                            .subsec_nanos() as usize)
                                                            % bundle.one_time_keys.len();
                                                        let otk = &bundle.one_time_keys[idx];

                                                        // Guard: don't overwrite an existing session
                                                        // (e.g. inbound session from peer's PreKey that
                                                        // arrived while our DHT fetch was in flight).
                                                        if olm.has_session(&target_peer) {
                                                            hollow_log!("[HOLLOW-SWARM] Session already exists for {target_peer}, skipping DHT prekey session creation");
                                                            used = true;
                                                        } else {
                                                        let _ = event_tx.send(NetworkEvent::KeyExchangeProgress {
                                                            peer_id: target_peer.clone(),
                                                            stage: "establishing_session".to_string(),
                                                        }).await;
                                                        match olm.create_outbound_session(
                                                            &target_peer,
                                                            &bundle.identity_key,
                                                            otk,
                                                        ) {
                                                            Ok(()) => {
                                                                persist_crypto_state(&olm, &crypto_store, &target_peer);
                                                                let _ = event_tx.send(NetworkEvent::KeyExchangeProgress {
                                                                    peer_id: target_peer.clone(),
                                                                    stage: "session_created".to_string(),
                                                                }).await;
                                                                let _ = event_tx.send(NetworkEvent::SessionEstablished {
                                                                    peer_id: target_peer.clone(),
                                                                }).await;
                                                                let _ = event_tx.send(NetworkEvent::Error {
                                                                    message: format!("[DHT] Session established from prekey for {target_peer}"),
                                                                }).await;

                                                                // Flush pending messages.
                                                                if let Some(queued) = pending_messages.remove(&target_peer)
                                                                    && let Ok(pid) = target_peer.parse::<PeerId>()
                                                                {
                                                                    for text in queued {
                                                                        send_encrypted_message(
                                                                            &mut swarm, &mut olm, &crypto_store,
                                                                            &mut pending_requests, &mut outbound_message_text,
                                                                            &pid, &target_peer, &text, &event_tx,
                                                                        ).await;
                                                                    }
                                                                }
                                                                // Retry failed sync batches after re-key.
                                                                if let Ok(pid) = target_peer.parse::<PeerId>() {
                                                                    flush_pending_sync_requests(
                                                                        &mut pending_sync_requests, &target_peer, &pid,
                                                                        &mut swarm, &mut olm, &crypto_store,
                                                                        &mut pending_requests, &mut outbound_message_text,
                                                                        &bundle_keypair, &event_tx,
                                                                    ).await;
                                                                }
                                                                used = true;
                                                            }
                                                            Err(e) => {
                                                                let _ = event_tx.send(NetworkEvent::Error {
                                                                    message: format!("[DHT] Prekey session creation failed: {e}"),
                                                                }).await;
                                                            }
                                                        }
                                                        }
                                                    }
                                                    Ok(false) => {
                                                        let _ = event_tx.send(NetworkEvent::Error {
                                                            message: format!("[DHT] Prekey bundle invalid/expired for {target_peer}"),
                                                        }).await;
                                                    }
                                                    Err(e) => {
                                                        let _ = event_tx.send(NetworkEvent::Error {
                                                            message: format!("[DHT] Prekey verification error: {e}"),
                                                        }).await;
                                                    }
                                                }
                                            }

                                            // If DHT bundle wasn't used, fall back to KeyRequest.
                                            if !used && !olm.has_session(&target_peer)
                                                && let Ok(pid) = target_peer.parse::<PeerId>()
                                                && !key_request_in_flight.contains(&target_peer)
                                            {
                                                key_request_in_flight.insert(target_peer.clone());
                                                let req_id = swarm.behaviour_mut().messaging.send_request(
                                                    &pid,
                                                    HavenMessage::KeyRequest,
                                                );
                                                pending_requests.insert(req_id, target_peer);
                                            }
                                        }
                                    }
                                    kad::QueryResult::GetRecord(Ok(
                                        kad::GetRecordOk::FinishedWithNoAdditionalRecord { .. }
                                    )) => {
                                        // If this query is still pending (no FoundRecord came), fall back.
                                        hollow_log!("[HOLLOW-SWARM] GetRecord FinishedWithNoAdditionalRecord for query {:?}", id);
                                        if let Some(target_peer) = pending_prekey_fetches.remove(&id) {
                                            hollow_log!("[HOLLOW-SWARM] No prekey record found for {target_peer}, falling back");
                                            dht_fetch_in_flight.remove(&target_peer);
                                            let _ = event_tx.send(NetworkEvent::Error {
                                                message: format!("[DHT] No prekey found for {target_peer}, falling back to KeyRequest"),
                                            }).await;

                                            if !olm.has_session(&target_peer)
                                                && let Ok(pid) = target_peer.parse::<PeerId>()
                                                && !key_request_in_flight.contains(&target_peer)
                                            {
                                                key_request_in_flight.insert(target_peer.clone());
                                                let req_id = swarm.behaviour_mut().messaging.send_request(
                                                    &pid,
                                                    HavenMessage::KeyRequest,
                                                );
                                                pending_requests.insert(req_id, target_peer);
                                            }
                                        }
                                    }
                                    kad::QueryResult::GetRecord(Err(e)) => {
                                        // DHT fetch failed — fall back to KeyRequest.
                                        hollow_log!("[HOLLOW-SWARM] GetRecord Error for query {:?}: {e:?}", id);
                                        if let Some(target_peer) = pending_prekey_fetches.remove(&id) {
                                            hollow_log!("[HOLLOW-SWARM] GetRecord failed for {target_peer}, falling back");
                                            dht_fetch_in_flight.remove(&target_peer);
                                            let _ = event_tx.send(NetworkEvent::Error {
                                                message: format!("[DHT] Prekey fetch failed for {target_peer}: {e:?}"),
                                            }).await;

                                            if !olm.has_session(&target_peer)
                                                && let Ok(pid) = target_peer.parse::<PeerId>()
                                                && !key_request_in_flight.contains(&target_peer)
                                            {
                                                key_request_in_flight.insert(target_peer.clone());
                                                let req_id = swarm.behaviour_mut().messaging.send_request(
                                                    &pid,
                                                    HavenMessage::KeyRequest,
                                                );
                                                pending_requests.insert(req_id, target_peer);
                                            }
                                        }
                                    }
                                    _ => {}
                                }
                            }
                            _ => {}
                        }
                    }

                    // -- AutoNAT events --
                    SwarmEvent::Behaviour(HavenBehaviourEvent::Autonat(
                        autonat::Event::StatusChanged { new, .. }
                    )) => {
                        match new {
                            autonat::NatStatus::Public(addr) => {
                                // We're publicly reachable — advertise our address.
                                let addr_str = addr.to_string();
                                if !known_addresses.contains(&addr_str) {
                                    known_addresses.push(addr_str);
                                }
                                swarm.add_external_address(addr);
                            }
                            autonat::NatStatus::Private => {
                                // Behind NAT — rely on relay + hole punching.
                            }
                            autonat::NatStatus::Unknown => {}
                        }
                    }
                    SwarmEvent::Behaviour(HavenBehaviourEvent::Autonat(_)) => {}

                    // -- DCUtR (hole punching) events --
                    SwarmEvent::Behaviour(HavenBehaviourEvent::Dcutr(event)) => {
                        match event.result {
                            Ok(_connection_id) => {
                                let _ = event_tx
                                    .send(NetworkEvent::Listening {
                                        address: format!("hole-punch-ok:{}", event.remote_peer_id),
                                    })
                                    .await;
                            }
                            Err(error) => {
                                let _ = event_tx
                                    .send(NetworkEvent::Error {
                                        message: format!("Hole punch failed to {}: {error}", event.remote_peer_id),
                                    })
                                    .await;
                            }
                        }
                    }

                    // -- Relay client events --
                    SwarmEvent::Behaviour(HavenBehaviourEvent::RelayClient(event)) => {
                        match event {
                            relay::client::Event::ReservationReqAccepted { relay_peer_id, renewal, .. } => {
                                let _ = event_tx.send(NetworkEvent::RelayStatusChanged {
                                    status: "circuit_ready".to_string(),
                                }).await;
                                if !renewal {
                                    let _ = event_tx
                                        .send(NetworkEvent::Listening {
                                            address: format!("relay-reserved:{relay_peer_id}"),
                                        })
                                        .await;
                                }
                            }
                            relay::client::Event::OutboundCircuitEstablished { relay_peer_id, .. } => {
                                let _ = event_tx
                                    .send(NetworkEvent::Listening {
                                        address: format!("relay-circuit-out:{relay_peer_id}"),
                                    })
                                    .await;
                            }
                            relay::client::Event::InboundCircuitEstablished { src_peer_id, .. } => {
                                let _ = event_tx
                                    .send(NetworkEvent::Listening {
                                        address: format!("relay-circuit-in:{src_peer_id}"),
                                    })
                                    .await;
                                // Peer is genuinely connecting to us — clear from
                                // disconnected set so they can be re-discovered.
                                disconnected_peers.remove(&src_peer_id);
                                // Cancel any pending debounced disconnect.
                                pending_disconnects.remove(&src_peer_id);
                                expected_peers.insert(src_peer_id);
                                // Emit PeerDiscovered + SessionEstablished (dedup: only once per session).
                                if discovered_peers.insert(src_peer_id) {
                                    let src_peer_str = src_peer_id.to_string();
                                    let circuit_base = if proxy_enabled { RELAY_ADDR_TCP } else { RELAY_ADDR_QUIC };
                                    let _ = event_tx
                                        .send(NetworkEvent::PeerDiscovered {
                                            peer: DiscoveredPeer {
                                                peer_id: src_peer_str.clone(),
                                                addresses: vec![format!(
                                                    "{}/p2p/{}/p2p-circuit/p2p/{}",
                                                    circuit_base, RELAY_PEER_ID, src_peer_id
                                                )],
                                            },
                                        })
                                        .await;
                                    if olm.has_session(&src_peer_str) {
                                        let _ = event_tx
                                            .send(NetworkEvent::SessionEstablished {
                                                peer_id: src_peer_str,
                                            })
                                            .await;
                                    }
                                }
                            }
                        }
                    }

                    // -- Identify events --
                    SwarmEvent::Behaviour(HavenBehaviourEvent::Identify(
                        identify::Event::Received { peer_id, info, .. },
                    )) => {
                        // Add identified peer's addresses to Kademlia.
                        for addr in info.listen_addrs {
                            swarm.behaviour_mut().kademlia.add_address(&peer_id, addr);
                        }
                    }
                    SwarmEvent::Behaviour(HavenBehaviourEvent::Identify(_)) => {}

                    // -- Ping events --
                    SwarmEvent::Behaviour(HavenBehaviourEvent::Ping(_)) => {}

                    // -- Debug: connection lifecycle --
                    SwarmEvent::ConnectionEstablished { peer_id, num_established, endpoint, .. } => {
                        let _ = event_tx
                            .send(NetworkEvent::Error {
                                message: format!("[DEBUG] Connected to {peer_id} via {endpoint:?}"),
                            })
                            .await;

                        // Track connected peers (skip relay node).
                        if relay_peer_id() != Some(peer_id) {
                            connected_peers.insert(peer_id);
                            // Cancel any pending debounced disconnect for this peer.
                            pending_disconnects.remove(&peer_id);
                            // Peer genuinely reconnected — allow future bootstraps to re-add them.
                            disconnected_peers.remove(&peer_id);

                            // Send join requests for any pending server joins.
                            for sid in pending_server_joins.iter() {
                                swarm.behaviour_mut().messaging.send_request(
                                    &peer_id,
                                    HavenMessage::ServerJoinRequest {
                                        server_id: sid.clone(),
                                    },
                                );
                            }

                            // Treat a connection as "first" if num_established==1 (truly first)
                            // OR the peer is not in discovered_peers (was gracefully disconnected
                            // but the old transport lingers, so num_established > 1).
                            let is_first_connection = num_established.get() == 1
                                || !discovered_peers.contains(&peer_id);

                            // Only emit PeerDiscovered for peers we expect (from
                            // signaling bootstrap, mDNS, or relay inbound circuit).
                            // This prevents Kademlia routing connections from
                            // polluting the peer list.
                            if is_first_connection && expected_peers.contains(&peer_id) {
                                let peer_id_str = peer_id.to_string();
                                // Dedup: only emit PeerDiscovered if not already emitted this session.
                                if discovered_peers.insert(peer_id) {
                                    let _ = event_tx
                                        .send(NetworkEvent::PeerDiscovered {
                                            peer: DiscoveredPeer {
                                                peer_id: peer_id_str.clone(),
                                                addresses: vec![format!("{endpoint:?}")],
                                            },
                                        })
                                        .await;
                                }
                                if olm.has_session(&peer_id_str) {
                                    // Re-emit SessionEstablished so the lock icon appears.
                                    let _ = event_tx
                                        .send(NetworkEvent::SessionEstablished {
                                            peer_id: peer_id_str.clone(),
                                        })
                                        .await;
                                    // Retry any failed sync batches on reconnect.
                                    flush_pending_sync_requests(
                                        &mut pending_sync_requests, &peer_id_str, &peer_id,
                                        &mut swarm, &mut olm, &crypto_store,
                                        &mut pending_requests, &mut outbound_message_text,
                                        &bundle_keypair, &event_tx,
                                    ).await;
                                } else if !key_request_in_flight.contains(&peer_id_str)
                                    && !dht_fetch_in_flight.contains(&peer_id_str)
                                {
                                    // No Olm session — proactively start key exchange
                                    // so encryption is ready before the first message.
                                    hollow_log!("[HOLLOW-SWARM] Proactive key exchange for {peer_id_str}");
                                    let _ = event_tx.send(NetworkEvent::KeyExchangeStarted {
                                        peer_id: peer_id_str.clone(),
                                    }).await;
                                    let _ = event_tx.send(NetworkEvent::KeyExchangeProgress {
                                        peer_id: peer_id_str.clone(),
                                        stage: "fetching_prekey".to_string(),
                                    }).await;
                                    let record_key = kad::RecordKey::new(
                                        &format!("/hollow/prekeys/{}", peer_id_str),
                                    );
                                    let query_id = swarm.behaviour_mut().kademlia
                                        .get_record(record_key);
                                    pending_prekey_fetches.insert(query_id, peer_id_str.clone());
                                    dht_fetch_in_flight.insert(peer_id_str);
                                }
                            }

                            // -- Trigger CRDT sync + message sync for shared servers --
                            // Only on FIRST connection to this peer (not duplicate TCP/QUIC/relay).
                            if is_first_connection {
                                let reconnected_peer_str = peer_id.to_string();
                                let mut is_server_member = false;
                                for (sid, state) in server_states.iter() {
                                    if state.members.contains_key(&reconnected_peer_str) {
                                        is_server_member = true;
                                        // CRDT state sync (channels, members, roles).
                                        let our_vector = StateVector::from_server_state(state);
                                        if let Ok(sv_json) = serde_json::to_string(&our_vector) {
                                            swarm.behaviour_mut().messaging.send_request(
                                                &peer_id,
                                                HavenMessage::SyncRequest {
                                                    server_id: sid.clone(),
                                                    state_vector_json: sv_json,
                                                },
                                            );
                                        }

                                        // Channel message sync — register with fan-out coordinator.
                                        // Instead of syncing every channel from this one peer,
                                        // the coordinator collects peers for 500ms, then assigns
                                        // channels evenly across all available peers.
                                        {
                                            let data_dir = crate::identity::data_dir().unwrap_or_default();
                                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                            if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                                    let channels_ts: Vec<(String, i64)> = state.channels.keys()
                                                        .map(|cid| {
                                                            let ts = store
                                                                .get_latest_channel_timestamp(sid, cid)
                                                                .unwrap_or(None)
                                                                .unwrap_or(0);
                                                            (cid.clone(), ts)
                                                        })
                                                        .collect();
                                                    sync_coordinator.register_peer(sid, peer_id, channels_ts);
                                                }
                                            }
                                        }

                                        // MLS: if we're the owner and this peer isn't in the MLS group yet,
                                        // request their KeyPackage so we can add them.
                                        if let Some(ref mls_mgr) = mls {
                                            if mls_mgr.has_group(sid) {
                                                let mls_members = mls_mgr.group_members(sid);
                                                if !mls_members.contains(&reconnected_peer_str) {
                                                    let local_peer = swarm.local_peer_id().to_string();
                                                    let is_owner = state.roles.get(&local_peer)
                                                        .map(|r| *r.read() == crate::crdt::operations::MemberRole::Owner)
                                                        .unwrap_or(false);
                                                    if is_owner {
                                                        hollow_log!("[HOLLOW-MLS] Requesting KeyPackage from {reconnected_peer_str} for server {sid}");
                                                        swarm.behaviour_mut().messaging.send_request(
                                                            &peer_id,
                                                            HavenMessage::MlsKeyPackageRequest {
                                                                server_id: sid.clone(),
                                                            },
                                                        );
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                // DM sync — request missed DMs from this peer.
                                {
                                    let dm_peer_str = peer_id.to_string();
                                    let data_dir = crate::identity::data_dir().unwrap_or_default();
                                    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                    if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                            let since = store
                                                .get_latest_dm_timestamp(&dm_peer_str)
                                                .unwrap_or(None)
                                                .unwrap_or(0);
                                            swarm.behaviour_mut().messaging.send_request(
                                                &peer_id,
                                                HavenMessage::DmSyncRequest {
                                                    since_timestamp: since,
                                                },
                                            );
                                        }
                                    }
                                }

                                // Send our profile to the newly connected peer.
                                {
                                    let data_dir = crate::identity::data_dir().unwrap_or_default();
                                    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                    if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                        if let Ok(db) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                            if let Ok(Some(profile)) = db.load_profile(&local_peer_str) {
                                                if !profile.display_name.is_empty() {
                                                    use base64::Engine;
                                                    let avatar_b64 = profile.avatar_bytes.as_ref().map(|b| base64::engine::general_purpose::STANDARD.encode(b)).unwrap_or_default();
                                                    let banner_b64 = profile.banner_bytes.as_ref().map(|b| base64::engine::general_purpose::STANDARD.encode(b)).unwrap_or_default();
                                                    swarm.behaviour_mut().messaging.send_request(
                                                        &peer_id,
                                                        HavenMessage::ProfileUpdate {
                                                            display_name: profile.display_name,
                                                            status: profile.status,
                                                            about_me: profile.about_me,
                                                            updated_at: profile.updated_at,
                                                            avatar_b64,
                                                            banner_b64,
                                                        },
                                                    );
                                                }
                                            }
                                        }
                                    }
                                }

                                // Ensure peers show as online in UI even if they
                                // weren't in expected_peers (e.g., direct connection
                                // before signaling bootstrap, or DM-only peers).
                                if !expected_peers.contains(&peer_id) && (is_server_member || olm.has_session(&reconnected_peer_str)) {
                                    if discovered_peers.insert(peer_id) {
                                        let _ = event_tx
                                            .send(NetworkEvent::PeerDiscovered {
                                                peer: DiscoveredPeer {
                                                    peer_id: reconnected_peer_str.clone(),
                                                    addresses: vec![format!("{endpoint:?}")],
                                                },
                                            })
                                            .await;
                                    }
                                    if olm.has_session(&reconnected_peer_str) {
                                        let _ = event_tx
                                            .send(NetworkEvent::SessionEstablished {
                                                peer_id: reconnected_peer_str,
                                            })
                                            .await;
                                    }
                                }
                            }
                        }

                        // Once connected to the relay, request a circuit reservation.
                        // Use the transport that actually connected (check endpoint).
                        // When proxy is enabled, always use real TCP addr (tunnel is transparent).
                        if relay_peer_id() == Some(peer_id) {
                            let base = if proxy_enabled {
                                RELAY_ADDR_TCP
                            } else {
                                let ep_str = format!("{endpoint:?}");
                                if ep_str.contains("quic") {
                                    RELAY_ADDR_QUIC
                                } else if ep_str.contains("ws") || ep_str.contains("443") {
                                    RELAY_ADDR_WSS
                                } else {
                                    RELAY_ADDR_TCP
                                }
                            };
                            let relay_circuit: Multiaddr = format!(
                                "{base}/p2p/{RELAY_PEER_ID}/p2p-circuit"
                            )
                            .parse()
                            .unwrap();
                            let _ = event_tx
                                .send(NetworkEvent::Error {
                                    message: format!("[DEBUG] Connected to relay! Requesting circuit via: {relay_circuit}"),
                                })
                                .await;
                            let _ = event_tx.send(NetworkEvent::RelayStatusChanged {
                                status: "connected".to_string(),
                            }).await;
                            let _ = event_tx.send(NetworkEvent::RelayStatusChanged {
                                status: "circuit_requested".to_string(),
                            }).await;
                            if let Err(e) = swarm.listen_on(relay_circuit) {
                                let _ = event_tx
                                    .send(NetworkEvent::Error {
                                        message: format!("Failed to listen on relay circuit: {e}"),
                                    })
                                    .await;
                            }
                        } else {
                            // Connected to a non-relay peer. If we have pending messages
                            // for them (re-queued after a failed send), initiate key
                            // exchange or send them now.
                            let peer_str = peer_id.to_string();
                            if pending_messages.contains_key(&peer_str) {
                                hollow_log!("[HOLLOW-SWARM] Connection established to {peer_str}, flushing pending messages");
                                if olm.has_session(&peer_str) {
                                    // Session exists — flush immediately.
                                    if let Some(queued) = pending_messages.remove(&peer_str) {
                                        for text in queued {
                                            send_encrypted_message(
                                                &mut swarm, &mut olm, &crypto_store,
                                                &mut pending_requests, &mut outbound_message_text,
                                                &peer_id, &peer_str, &text, &event_tx,
                                            ).await;
                                        }
                                    }
                                } else if !key_request_in_flight.contains(&peer_str)
                                    && !dht_fetch_in_flight.contains(&peer_str)
                                {
                                    // No session — try DHT prekey fetch first.
                                    let record_key = kad::RecordKey::new(
                                        &format!("/hollow/prekeys/{}", peer_str),
                                    );
                                    let query_id = swarm.behaviour_mut().kademlia
                                        .get_record(record_key);
                                    pending_prekey_fetches.insert(query_id, peer_str.clone());
                                    dht_fetch_in_flight.insert(peer_str.clone());
                                    hollow_log!("[HOLLOW-SWARM] Starting DHT prekey fetch for {peer_str}");
                                }
                            }
                        }
                    }
                    SwarmEvent::OutgoingConnectionError { peer_id, error, .. } => {
                        let _ = event_tx
                            .send(NetworkEvent::Error {
                                message: format!("[DEBUG] Dial failed to {peer_id:?}: {error}"),
                            })
                            .await;
                        if let Some(pid) = peer_id {
                            let err_str = format!("{error}");
                            let method = if err_str.contains("p2p-circuit") { "relay" }
                                else if err_str.contains("quic") { "quic" }
                                else if err_str.contains("ws") || err_str.contains("443") { "wss" }
                                else if err_str.contains("tcp") { "tcp" }
                                else { "unknown" };
                            let reason: String = err_str.chars().take(200).collect();
                            let _ = event_tx.send(NetworkEvent::ConnectionAttemptFailed {
                                peer_id: pid.to_string(),
                                method: method.to_string(),
                                reason,
                            }).await;
                        }
                    }
                    SwarmEvent::ListenerError { listener_id, error } => {
                        let _ = event_tx
                            .send(NetworkEvent::Error {
                                message: format!("[DEBUG] Listener error ({listener_id:?}): {error}"),
                            })
                            .await;
                    }
                    SwarmEvent::ListenerClosed { listener_id, reason, .. } => {
                        let _ = event_tx
                            .send(NetworkEvent::Error {
                                message: format!("[DEBUG] Listener closed ({listener_id:?}): {reason:?}"),
                            })
                            .await;
                    }

                    SwarmEvent::ConnectionClosed { peer_id, num_established, cause, .. } => {
                        let _ = event_tx
                            .send(NetworkEvent::Error {
                                message: format!(
                                    "[DEBUG] Connection to {peer_id} closed (remaining: {num_established}, cause: {cause:?})"
                                ),
                            })
                            .await;

                        // When ALL connections to this peer are gone, queue a
                        // debounced disconnect instead of emitting immediately.
                        // This prevents rapid add/remove/add UI churn when libp2p
                        // is upgrading transports (multiple connections established
                        // then pruned down to one within the same second).
                        if num_established == 0 && relay_peer_id() != Some(peer_id) {
                            connected_peers.remove(&peer_id);
                            // Only queue debounced disconnect if not already handled
                            // by a graceful PeerDisconnecting message.
                            if !disconnected_peers.contains_key(&peer_id) {
                                pending_disconnects.insert(peer_id, std::time::Instant::now());
                            }
                        }

                        // Relay connection lost — immediately re-dial to restore circuit.
                        if num_established == 0 && relay_peer_id() == Some(peer_id) {
                            let _ = event_tx.send(NetworkEvent::Error {
                                message: "[RELAY] Relay connection lost! Re-dialing in 5s...".to_string(),
                            }).await;
                            let _ = event_tx.send(NetworkEvent::RelayStatusChanged {
                                status: "reconnecting".to_string(),
                            }).await;
                            // Remove stale relay circuit addresses.
                            known_addresses.retain(|a| !a.contains("p2p-circuit"));
                            // Brief delay before re-dial to avoid tight reconnect loops.
                            let relay_pid = peer_id;
                            tokio::time::sleep(Duration::from_secs(5)).await;
                            let addrs = proxy_aware_relay_addrs(proxy_enabled);
                            for addr in &addrs {
                                swarm.add_peer_address(relay_pid, addr.clone());
                                swarm.behaviour_mut().kademlia.add_address(&relay_pid, addr.clone());
                            }
                            // When proxy is on, dial the specific tunnel address to avoid
                            // libp2p trying cached direct QUIC/WSS/TCP addresses.
                            let dial_result = if proxy_enabled {
                                if let Some(addr) = addrs.into_iter().next() {
                                    swarm.dial(addr)
                                } else {
                                    Err(libp2p::swarm::DialError::NoAddresses.into())
                                }
                            } else {
                                swarm.dial(relay_pid)
                            };
                            if let Err(e) = dial_result {
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: format!("[RELAY] Re-dial failed: {e}"),
                                }).await;
                            }
                        }
                    }

                    _ => {}
                }
            }
            // Handle signaling service events (bootstrap peer discovery).
            Some(sig_event) = sig_event_rx.recv() => {
                match sig_event {
                    SignalingEvent::BootstrapPeers { peers } => {
                        let _ = event_tx
                            .send(NetworkEvent::Error {
                                message: format!("[DEBUG] Bootstrap returned {} peers", peers.len()),
                            })
                            .await;
                        for bp in peers {
                            // Skip ourselves.
                            let Ok(peer_id) = bp.peer_id.parse::<PeerId>() else {
                                continue;
                            };
                            if peer_id == *swarm.local_peer_id() {
                                continue;
                            }
                            // Skip peers we already tried and disconnected from.
                            // Prevents ghost peers from stale signaling entries.
                            if disconnected_peers.contains_key(&peer_id) {
                                continue;
                            }
                            // Skip peers we're already connected to.
                            if connected_peers.contains(&peer_id) {
                                continue;
                            }

                            // Register addresses from signaling + add relay circuits.
                            // Strategy: dial relay circuit FIRST for instant connectivity,
                            // then add direct addresses so libp2p can upgrade later.
                            // This avoids 10s+ timeouts on stale direct addresses.

                            let mut relay_circuit_addrs = Vec::new();

                            // Build relay circuit addresses (fast, reliable path).
                            if let Some(relay_pid) = relay_peer_id() {
                                let bases: Vec<&str> = if proxy_enabled {
                                    vec![RELAY_ADDR_TCP]
                                } else {
                                    vec![RELAY_ADDR_TCP, RELAY_ADDR_WSS]
                                };
                                for base in bases {
                                    if let Ok(circuit_addr) = format!(
                                        "{}/p2p/{}/p2p-circuit/p2p/{}",
                                        base, relay_pid, peer_id
                                    ).parse::<Multiaddr>() {
                                        relay_circuit_addrs.push(circuit_addr);
                                    }
                                }
                            }

                            // Add relay circuit addresses and dial them first.
                            // This gives us a connection within ~1s via relay.
                            for addr in &relay_circuit_addrs {
                                swarm.add_peer_address(peer_id, addr.clone());
                            }

                            // Mark as expected so ConnectionEstablished can emit PeerDiscovered.
                            expected_peers.insert(peer_id);

                            // Notify Dart of the discovered peer (dedup: only emit once per session).
                            if discovered_peers.insert(peer_id) {
                                let _ = event_tx
                                    .send(NetworkEvent::PeerDiscovered {
                                        peer: DiscoveredPeer {
                                            peer_id: bp.peer_id.clone(),
                                            addresses: bp.addresses.clone(),
                                        },
                                    })
                                    .await;
                            }

                            // Dial relay circuit first for fast connection.
                            let _ = event_tx.send(NetworkEvent::ConnectionAttemptStarted {
                                peer_id: bp.peer_id.clone(),
                                method: "relay".to_string(),
                            }).await;
                            let _ = swarm.dial(peer_id);

                            // NOW add direct addresses from signaling (for potential
                            // direct upgrade via DCUtR/hole-punching later).
                            for addr_str in &bp.addresses {
                                if let Ok(addr) = addr_str.parse::<Multiaddr>() {
                                    swarm.add_peer_address(peer_id, addr.clone());
                                    if !addr_str.contains("p2p-circuit") {
                                        swarm.behaviour_mut().kademlia.add_address(&peer_id, addr);
                                    }
                                }
                            }
                        }

                        // Trigger Kademlia bootstrap to populate routing table.
                        let _ = swarm.behaviour_mut().kademlia.bootstrap();
                    }
                    SignalingEvent::Error { message } => {
                        let _ = event_tx
                            .send(NetworkEvent::Error { message })
                            .await;
                    }
                }
            }

            // Republish prekey bundle periodically to keep DHT records fresh.
            _ = prekey_timer.tick() => {
                if prekey_published {
                    let peer_id_str = swarm.local_peer_id().to_string();
                    match publish_prekey_bundle(
                        &mut swarm, &bundle_keypair, &peer_id_str, &pub_key_b64,
                        &mut olm, &crypto_store,
                    ) {
                        Ok(()) => {
                            let _ = event_tx.send(NetworkEvent::Error {
                                message: "[DHT] Prekey bundle republished".to_string(),
                            }).await;
                        }
                        Err(e) => {
                            let _ = event_tx.send(NetworkEvent::Error {
                                message: format!("[DHT] Prekey republish failed: {e}"),
                            }).await;
                        }
                    }
                }
            }

            // MLS batch addition timer — process queued KeyPackages as a single commit.
            _ = mls_batch_timer.tick() => {
                if let Some(ref mut mls_mgr) = mls {
                    let server_ids: Vec<String> = pending_mls_key_packages.keys().cloned().collect();
                    for server_id in server_ids {
                        if let Some(queued) = pending_mls_key_packages.remove(&server_id) {
                            if queued.is_empty() { continue; }

                            hollow_log!("[HOLLOW-MLS] Processing batch of {} KeyPackages for {server_id}", queued.len());

                            match mls_mgr.add_members_batch(&server_id, &queued) {
                                Ok((commit_bytes, welcome_bytes, added_peers)) => {
                                    if let Err(e) = mls_mgr.merge_pending_commit(&server_id) {
                                        hollow_log!("[HOLLOW-MLS] Failed to merge batch commit: {e}");
                                        continue;
                                    }
                                    persist_mls_state(mls_mgr, &bundle_keypair);

                                    let welcome_b64 = base64::engine::general_purpose::STANDARD.encode(&welcome_bytes);
                                    let commit_b64 = base64::engine::general_purpose::STANDARD.encode(&commit_bytes);

                                    // Send Welcome to all new joiners.
                                    for peer_id_str in &added_peers {
                                        if let Ok(pid) = peer_id_str.parse::<PeerId>() {
                                            if connected_peers.contains(&pid) {
                                                swarm.behaviour_mut().messaging.send_request(
                                                    &pid,
                                                    HavenMessage::MlsWelcome {
                                                        server_id: server_id.clone(),
                                                        welcome: welcome_b64.clone(),
                                                    },
                                                );
                                            }
                                        }
                                    }

                                    // Broadcast single Commit to all existing members.
                                    if let Some(state) = server_states.get(&server_id) {
                                        let local_peer = swarm.local_peer_id().to_string();
                                        for member_peer_str in state.members.keys() {
                                            if member_peer_str == &local_peer { continue; }
                                            if added_peers.contains(member_peer_str) { continue; }
                                            if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                                if connected_peers.contains(&pid) {
                                                    swarm.behaviour_mut().messaging.send_request(
                                                        &pid,
                                                        HavenMessage::MlsCommit {
                                                            server_id: server_id.clone(),
                                                            commit: commit_b64.clone(),
                                                        },
                                                    );
                                                }
                                            }
                                        }
                                    }

                                    hollow_log!("[HOLLOW-MLS] Batch-added {} members to server {server_id}: {:?}", added_peers.len(), added_peers);
                                }
                                Err(e) => hollow_log!("[HOLLOW-MLS] Batch add failed for {server_id}: {e}"),
                            }
                        }
                    }
                }
            }

            // Periodic re-bootstrap for mutual peer discovery.
            _ = rebootstrap_timer.tick() => {
                // Clear disconnected peers that have cooled down past the stale threshold.
                // This prevents ghost re-discovery from signaling entries that haven't
                // been cleaned up yet. Only peers disconnected > 3 min ago are cleared.
                if !disconnected_peers.is_empty() {
                    let now = std::time::Instant::now();
                    let before = disconnected_peers.len();
                    disconnected_peers.retain(|_, disconnected_at| {
                        now.duration_since(*disconnected_at) < DISCONNECT_COOLDOWN
                    });
                    let cleared = before - disconnected_peers.len();
                    if cleared > 0 {
                        hollow_log!("[HOLLOW-SWARM] Cleared {cleared} cooled-down disconnected peers ({} still cooling)", disconnected_peers.len());
                    }
                }
                // Re-register with signaling to prevent stale cleanup (3-min threshold).
                let reg_addrs: Vec<String> = known_addresses.iter()
                    .filter(|a| is_registerable_address(a))
                    .cloned()
                    .collect();

                if let Some(room) = &active_room {
                    if !reg_addrs.is_empty() {
                        let _ = sig_cmd_tx.send(SignalingCmd::Register {
                            room_code: room.clone(),
                            addresses: reg_addrs.clone(),
                        }).await;
                    }
                    let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
                        room_code: room.clone(),
                    }).await;
                }
                // Also re-register + re-bootstrap all server signaling rooms.
                for sid in server_states.keys() {
                    if !reg_addrs.is_empty() {
                        let _ = sig_cmd_tx.send(SignalingCmd::Register {
                            room_code: sid.clone(),
                            addresses: reg_addrs.clone(),
                        }).await;
                    }
                    let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
                        room_code: sid.clone(),
                    }).await;
                }
            }

            // Multi-peer fan-out sync coordinator dispatch.
            // Checks every 100ms if any servers have passed the 500ms collection window
            // and are ready to dispatch channel sync probes across peers.
            _ = sync_dispatch_timer.tick() => {
                let ready = sync_coordinator.collect_ready();
                for (server_id, assignments) in &ready {
                    let total_channels: usize = assignments.iter().map(|(_, chs)| chs.len()).sum();
                    let total_peers = assignments.len();
                    hollow_log!(
                        "[HOLLOW-SYNC] Fan-out dispatch for server {server_id}: {total_channels} channel probes across {total_peers} peers"
                    );

                    // Open DB for message count queries.
                    let sync_data_dir = crate::identity::data_dir().unwrap_or_default();
                    let sync_db_path = sync_data_dir.join("messages.db").to_string_lossy().to_string();
                    let sync_store = if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                        let pass = hex::encode(&proto[..32.min(proto.len())]);
                        crate::storage::MessageStore::open(&sync_db_path, &pass).ok()
                    } else {
                        None
                    };

                    for (peer, channels) in assignments {
                        for (channel_id, our_latest) in channels {
                            let msg_count = sync_store.as_ref()
                                .map(|s| s.count_channel_messages(server_id, channel_id))
                                .unwrap_or(0);
                            swarm.behaviour_mut().messaging.send_request(
                                peer,
                                HavenMessage::ChannelSyncProbe {
                                    server_id: server_id.clone(),
                                    channel_id: channel_id.clone(),
                                    our_latest: *our_latest,
                                    msg_count,
                                },
                            );
                        }
                    }

                    // Emit sync started for UI feedback.
                    let _ = event_tx.send(NetworkEvent::MessageSyncStarted {
                        server_id: server_id.clone(),
                        peer_id: "fan-out".to_string(),
                    }).await;
                }

                // Clean up stale entries (dispatched > 30s ago).
                sync_coordinator.cleanup_stale();
            }

            // Flush pending disconnects that have passed the debounce window.
            _ = disconnect_debounce_timer.tick() => {
                if !pending_disconnects.is_empty() {
                    let now = std::time::Instant::now();
                    let mut to_emit = Vec::new();
                    pending_disconnects.retain(|peer_id, queued_at| {
                        if now.duration_since(*queued_at) >= DISCONNECT_DEBOUNCE {
                            to_emit.push(*peer_id);
                            false
                        } else {
                            true
                        }
                    });
                    for peer_id in to_emit {
                        // Only emit if the peer is still not connected AND wasn't
                        // already handled by a graceful PeerDisconnecting (which adds
                        // to disconnected_peers immediately).
                        if !connected_peers.contains(&peer_id) && !disconnected_peers.contains_key(&peer_id) {
                            disconnected_peers.insert(peer_id, now);
                            discovered_peers.remove(&peer_id);
                            let _ = event_tx
                                .send(NetworkEvent::PeerDisconnected {
                                    peer_id: peer_id.to_string(),
                                })
                                .await;
                        }
                    }
                }
            }

            // Relay health check — re-dial relay if connection dropped.
            _ = relay_health_timer.tick() => {
                if let Some(relay_pid) = relay_peer_id() {
                    if !swarm.is_connected(&relay_pid) {
                        let _ = event_tx.send(NetworkEvent::Error {
                            message: "[RELAY] Not connected to relay, re-dialing...".to_string(),
                        }).await;
                        // Remove stale relay circuit addresses.
                        known_addresses.retain(|a| !a.contains("p2p-circuit"));
                        // Re-add relay addresses and dial.
                        let addrs = proxy_aware_relay_addrs(proxy_enabled);
                        for addr in &addrs {
                            swarm.add_peer_address(relay_pid, addr.clone());
                            swarm.behaviour_mut().kademlia.add_address(&relay_pid, addr.clone());
                        }
                        // When proxy is on, dial specific tunnel address.
                        if proxy_enabled {
                            if let Some(addr) = addrs.into_iter().next() {
                                let _ = swarm.dial(addr);
                            }
                        } else {
                            let _ = swarm.dial(relay_pid);
                        }
                    } else {
                        // Connected to relay but check if we have a circuit address.
                        let has_circuit = known_addresses.iter().any(|a| a.contains("p2p-circuit"));
                        if !has_circuit {
                            let _ = event_tx.send(NetworkEvent::Error {
                                message: "[RELAY] Connected but no circuit address, re-requesting...".to_string(),
                            }).await;
                            // Re-request circuit reservation.
                            let circuit_base = if proxy_enabled { RELAY_ADDR_TCP } else { RELAY_ADDR_QUIC };
                            let relay_circuit: Multiaddr = format!(
                                "{}/p2p/{}/p2p-circuit",
                                circuit_base, RELAY_PEER_ID
                            ).parse().unwrap();
                            let _ = swarm.listen_on(relay_circuit);
                        }
                    }
                }
            }

            // -- Stream transfer progress poll (every 500ms) --
            _ = stream_progress_timer.tick() => {
                // Snapshot progress under lock, then emit events outside lock.
                let snapshot: Vec<(String, u64, u64)> = {
                    let Ok(map) = super::stream_transfer::stream_progress().lock() else { continue };
                    map.iter().map(|(id, p)| {
                        (id.clone(), p.bytes_received.load(std::sync::atomic::Ordering::Relaxed), p.total_bytes)
                    }).collect()
                };
                for (file_id, received, total) in snapshot {
                    if received > 0 {
                        let _ = event_tx.send(NetworkEvent::FileProgress {
                            file_id,
                            chunks_received: (received / (1024 * 1024)).max(1) as u32,
                            total_chunks: (total / (1024 * 1024)).max(1) as u32,
                        }).await;
                    }
                }
            }

            // -- Vault rebalance + retention enforcement (every 30 min) --
            _ = rebalance_timer.tick() => {
                hollow_log!("[HOLLOW-VAULT] Running rebalance + retention check");
                let local_peer = swarm.local_peer_id().to_string();
                let data_dir = crate::identity::data_dir().unwrap_or_default();
                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                let vault_dir = data_dir.join("vault");
                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                let passphrase = hex::encode(&proto[..32.min(proto.len())]);

                if let Ok(cs) = crate::vault::content_store::ContentStore::open(&db_path, &passphrase, &vault_dir) {
                    // 1. Update last_seen for all connected server members
                    let now_ts = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_secs() as i64;

                    for (server_id, state) in &server_states {
                        for member_peer_str in state.members.keys() {
                            if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                if connected_peers.contains(&pid) {
                                    let _ = cs.update_member_last_seen(server_id, member_peer_str, now_ts);
                                }
                            }
                        }

                        // 2. Retention enforcement: delete expired manifests
                        for tier in [crate::vault::content_store::StorageTier::Standard, crate::vault::content_store::StorageTier::Low] {
                            let policy = crate::vault::adaptive::retention_for_tier(tier, &state.settings);
                            if let Some(days) = crate::vault::adaptive::parse_retention_days(&policy) {
                                let cutoff = now_ts - (days as i64 * 86400);
                                if let Ok(expired) = cs.find_expired_manifests(server_id, cutoff) {
                                    for manifest in &expired {
                                        if manifest.storage_tier == tier.as_str() {
                                            hollow_log!("[HOLLOW-VAULT] Retention: deleting expired content {} (tier: {})", manifest.content_id, manifest.storage_tier);
                                            let _ = cs.delete_content(server_id, &manifest.content_id);
                                            let _ = cs.delete_placements(&manifest.content_id);
                                            let _ = cs.delete_manifest(&manifest.content_id);
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // 3. Cache eviction (1GB default limit)
                    if let Ok(freed) = crate::vault::pipeline::evict_cache_if_needed(1024 * 1024 * 1024) {
                        if freed > 0 {
                            hollow_log!("[HOLLOW-VAULT] Cache eviction freed {} bytes", freed);
                        }
                    }
                }
            }
        }
    }

    // Abort tunnel tasks on shutdown.
    if let Some(handles) = tunnel_handles {
        for h in handles {
            h.abort();
        }
        hollow_log!("[HOLLOW] [PROXY] Shadowsocks tunnels stopped");
    }
}

/// Persist MLS state (signer + credential + storage) to SQLCipher.
fn persist_mls_state(mls: &MlsManager, keypair: &identity::Keypair) {
    let signer = match mls.signer_bytes() {
        Ok(s) => s,
        Err(e) => { hollow_log!("[HOLLOW-MLS] Failed to serialize signer: {e}"); return; }
    };
    let cred = match mls.credential_bytes() {
        Ok(c) => c,
        Err(e) => { hollow_log!("[HOLLOW-MLS] Failed to serialize credential: {e}"); return; }
    };
    let storage = match mls.serialize_storage() {
        Ok(s) => s,
        Err(e) => { hollow_log!("[HOLLOW-MLS] Failed to serialize storage: {e}"); return; }
    };
    let data_dir = crate::identity::data_dir().unwrap_or_default();
    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
    let proto = keypair.to_protobuf_encoding().unwrap_or_default();
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);
    if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
        let _ = store.save_mls_identity(&signer, &cred, &storage);
    }
}

/// Encrypt and send a message to a peer with an established session.
/// Returns `true` on success, `false` if encryption failed.
async fn send_encrypted_message(
    swarm: &mut libp2p::Swarm<HavenBehaviour>,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    pending_requests: &mut HashMap<request_response::OutboundRequestId, String>,
    outbound_message_text: &mut HashMap<request_response::OutboundRequestId, (String, String)>,
    peer_id: &PeerId,
    peer_id_str: &str,
    text: &str,
    event_tx: &mpsc::Sender<NetworkEvent>,
) -> bool {
    match olm.encrypt(peer_id_str, text.as_bytes()) {
        Ok((msg_type, ciphertext)) => {
            // Persist crypto state.
            persist_crypto_state(olm, crypto_store, peer_id_str);

            if msg_type == 0 {
                hollow_log!("[HOLLOW-CRYPTO] Sending PreKey (type 0) to {peer_id_str}");
            }

            let identity_key = if msg_type == 0 {
                Some(olm.identity_key_base64())
            } else {
                None
            };

            let req_id = swarm.behaviour_mut().messaging.send_request(
                peer_id,
                HavenMessage::Encrypted {
                    message_type: msg_type,
                    body: OlmManager::encode_base64(&ciphertext),
                    identity_key,
                },
            );
            pending_requests.insert(req_id, peer_id_str.to_string());
            // Track original text so we can re-queue on delivery failure.
            outbound_message_text.insert(req_id, (peer_id_str.to_string(), text.to_string()));
            true
        }
        Err(e) => {
            let _ = event_tx
                .send(NetworkEvent::MessageSendFailed {
                    to_peer: peer_id_str.to_string(),
                    error: format!("Encryption failed: {e}"),
                })
                .await;
            false
        }
    }
}

/// Handle an incoming request from a peer.
async fn handle_incoming_request(
    swarm: &mut libp2p::Swarm<HavenBehaviour>,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    pending_requests: &mut HashMap<request_response::OutboundRequestId, String>,
    outbound_message_text: &mut HashMap<request_response::OutboundRequestId, (String, String)>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    key_request_in_flight: &mut std::collections::HashSet<String>,
    server_states: &mut HashMap<String, ServerState>,
    bundle_keypair: &identity::Keypair,
    connected_peers: &mut std::collections::HashSet<PeerId>,
    pending_server_joins: &mut std::collections::HashSet<String>,
    pending_sync_requests: &mut HashMap<String, Vec<(String, String, i64)>>,
    mls: &mut Option<MlsManager>,
    discovered_peers: &mut std::collections::HashSet<PeerId>,
    disconnected_peers: &mut HashMap<PeerId, std::time::Instant>,
    pending_disconnects: &mut HashMap<PeerId, std::time::Instant>,
    mls_bootstrap_requested: &mut std::collections::HashSet<String>,
    sig_cmd_tx: &mpsc::Sender<SignalingCmd>,
    known_addresses: &[String],
    pending_shard_assembly: &mut HashMap<String, PendingShardAssembly>,
    pending_file_streams: &mut HashMap<String, PendingFileStream>,
    pending_shard_streams: &mut HashMap<String, PendingShardStream>,
    decrypt_fail_cooldown: &mut HashMap<String, std::time::Instant>,
    pending_mls_key_packages: &mut HashMap<String, Vec<(String, Vec<u8>)>>,
    mls_decrypt_failures: &mut HashMap<String, u32>,
    peer: PeerId,
    request: HavenMessage,
    channel: request_response::ResponseChannel<HavenMessage>,
) {
    let peer_str = peer.to_string();

    match request {
        HavenMessage::KeyRequest => {
            // Peer wants our key bundle — generate a one-time key and respond.
            let otk = olm.generate_one_time_key();
            let identity_key = olm.identity_key_base64();

            // Persist account (one-time key was consumed).
            if let Ok(pickle) = olm.account_pickle_json() {
                crypto_store.save_account(pickle);
            }

            let _ = swarm.behaviour_mut().messaging.send_response(
                channel,
                HavenMessage::KeyBundle {
                    identity_key,
                    one_time_key: otk,
                },
            );
        }

        HavenMessage::Encrypted { message_type, body, identity_key } => {
            let ciphertext = match OlmManager::decode_base64(&body) {
                Ok(b) => b,
                Err(e) => {
                    let _ = event_tx
                        .send(NetworkEvent::Error {
                            message: format!("Failed to decode message from {peer_str}: {e}"),
                        })
                        .await;
                    let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);
                    return;
                }
            };

            let plaintext = if message_type == 0 {
                // PreKeyMessage — create inbound session.
                let their_identity = match &identity_key {
                    Some(k) => k,
                    None => {
                        let _ = event_tx
                            .send(NetworkEvent::Error {
                                message: format!("PreKeyMessage from {peer_str} missing identity_key"),
                            })
                            .await;
                        let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);
                        return;
                    }
                };

                let had_existing_session = olm.has_session(&peer_str);

                if had_existing_session {
                    // We have an inbound-derived session (already good). Try to decrypt
                    // the PreKey using the existing session — this handles the race where
                    // two encrypted messages arrive as PreKeys (e.g. sync batch response +
                    // regular channel message overlap). The first creates a new session,
                    // the second should decrypt with it.
                    match olm.try_decrypt_prekey_with_existing(&peer_str, &ciphertext) {
                        Ok(pt) => {
                            hollow_log!("[HOLLOW-CRYPTO] Decrypted PreKey with existing session for {peer_str}");
                            pt
                        }
                        Err(_) => {
                            // Existing session can't handle this PreKey — it's a
                            // genuinely new session from the peer (e.g. they re-keyed).
                            // Replace our session with the new inbound one.
                            olm.remove_session(&peer_str);
                            match olm.create_inbound_session(&peer_str, their_identity, &ciphertext) {
                                Ok(pt) => {
                                    let _ = event_tx
                                        .send(NetworkEvent::SessionEstablished {
                                            peer_id: peer_str.clone(),
                                        })
                                        .await;
                                    key_request_in_flight.remove(&peer_str);
                                    // Send encrypted SessionAck to upgrade peer's outbound ratchet.
                                    let ack_json = serde_json::to_string(&MessageEnvelope::SessionAck).unwrap_or_default();
                                    send_encrypted_message(
                                        swarm, olm, crypto_store, pending_requests,
                                        outbound_message_text, &peer, &peer_str, &ack_json, event_tx,
                                    ).await;
                                    if let Some(queued) = pending_messages.remove(&peer_str) {
                                        for text in queued {
                                            send_encrypted_message(
                                                swarm, olm, crypto_store, pending_requests,
                                                outbound_message_text, &peer, &peer_str, &text, event_tx,
                                            ).await;
                                        }
                                    }
                                    flush_pending_sync_requests(
                                        pending_sync_requests, &peer_str, &peer,
                                        swarm, olm, crypto_store,
                                        pending_requests, outbound_message_text,
                                        bundle_keypair, event_tx,
                                    ).await;
                                    pt
                                }
                                Err(e2) => {
                                    // Both paths failed. Apply cooldown to prevent flood.
                                    let now = std::time::Instant::now();
                                    let should_rekey = match decrypt_fail_cooldown.get(&peer_str) {
                                        Some(last) => now.duration_since(*last) >= Duration::from_secs(5),
                                        None => true,
                                    };
                                    if should_rekey {
                                        hollow_log!("[HOLLOW-CRYPTO] PreKey session creation also failed for {peer_str}: {e2} — initiating re-key");
                                        decrypt_fail_cooldown.insert(peer_str.clone(), now);
                                        if !key_request_in_flight.contains(&peer_str) {
                                            key_request_in_flight.insert(peer_str.clone());
                                            let req_id = swarm.behaviour_mut().messaging.send_request(
                                                &peer,
                                                HavenMessage::KeyRequest,
                                            );
                                            pending_requests.insert(req_id, peer_str.clone());
                                        }
                                    }
                                    persist_crypto_state(olm, crypto_store, &peer_str);
                                    let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);
                                    return;
                                }
                            }
                        }
                    }
                } else {
                    // No existing session — standard path: create inbound session.
                    match olm.create_inbound_session(&peer_str, their_identity, &ciphertext) {
                        Ok(pt) => {
                            let _ = event_tx
                                .send(NetworkEvent::SessionEstablished {
                                    peer_id: peer_str.clone(),
                                })
                                .await;
                            key_request_in_flight.remove(&peer_str);
                            // Send encrypted SessionAck to upgrade peer's outbound ratchet.
                            let ack_json = serde_json::to_string(&MessageEnvelope::SessionAck).unwrap_or_default();
                            send_encrypted_message(
                                swarm, olm, crypto_store, pending_requests,
                                outbound_message_text, &peer, &peer_str, &ack_json, event_tx,
                            ).await;
                            if let Some(queued) = pending_messages.remove(&peer_str) {
                                for text in queued {
                                    send_encrypted_message(
                                        swarm, olm, crypto_store, pending_requests,
                                        outbound_message_text, &peer, &peer_str, &text, event_tx,
                                    ).await;
                                }
                            }
                            flush_pending_sync_requests(
                                pending_sync_requests, &peer_str, &peer,
                                swarm, olm, crypto_store,
                                pending_requests, outbound_message_text,
                                bundle_keypair, event_tx,
                            ).await;
                            pt
                        }
                        Err(e) => {
                            // Apply cooldown to prevent flood from stale PreKey messages.
                            let now = std::time::Instant::now();
                            let should_rekey = match decrypt_fail_cooldown.get(&peer_str) {
                                Some(last) => now.duration_since(*last) >= Duration::from_secs(5),
                                None => true,
                            };
                            if should_rekey {
                                hollow_log!("[HOLLOW-CRYPTO] PreKey session creation failed for {peer_str}: {e} — initiating re-key");
                                decrypt_fail_cooldown.insert(peer_str.clone(), now);
                                if !key_request_in_flight.contains(&peer_str) {
                                    key_request_in_flight.insert(peer_str.clone());
                                    let req_id = swarm.behaviour_mut().messaging.send_request(
                                        &peer,
                                        HavenMessage::KeyRequest,
                                    );
                                    pending_requests.insert(req_id, peer_str.clone());
                                }
                            }
                            persist_crypto_state(olm, crypto_store, &peer_str);
                            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);
                            return;
                        }
                    }
                }
            } else {
                // Normal encrypted message — decrypt with existing session.
                match olm.decrypt(&peer_str, message_type, &ciphertext) {
                    Ok(pt) => pt,
                    Err(e) => {
                        // Decrypt failure — check cooldown before killing session.
                        // This prevents rapid session thrashing when many in-flight
                        // chunks fail (e.g., large file transfer with 1000+ chunks).
                        let now = std::time::Instant::now();
                        let should_rekey = match decrypt_fail_cooldown.get(&peer_str) {
                            Some(last_kill) => now.duration_since(*last_kill) >= Duration::from_secs(5),
                            None => true, // First failure — allow rekey
                        };

                        if should_rekey {
                            hollow_log!("[HOLLOW-SWARM] Decrypt failed for {peer_str}: {e} — removing stale session");
                            olm.remove_session(&peer_str);
                            persist_crypto_state(olm, crypto_store, &peer_str);
                            decrypt_fail_cooldown.insert(peer_str.clone(), now);

                            let _ = event_tx
                                .send(NetworkEvent::Error {
                                    message: format!("Stale session with {peer_str}, re-keying..."),
                                })
                                .await;

                            // Emit MessageSyncFailed for any servers where this peer is a member
                            // so the UI doesn't stay stuck on "Syncing...".
                            for (sid, state) in server_states.iter() {
                                if state.members.contains_key(&peer_str) {
                                    let _ = event_tx.send(NetworkEvent::MessageSyncFailed {
                                        server_id: sid.clone(),
                                        error: format!("Decrypt failed with {peer_str}, re-keying"),
                                    }).await;
                                }
                            }

                            // Send a KeyRequest to re-establish the session.
                            if !key_request_in_flight.contains(&peer_str) {
                                key_request_in_flight.insert(peer_str.clone());
                                let req_id = swarm.behaviour_mut().messaging.send_request(
                                    &peer,
                                    HavenMessage::KeyRequest,
                                );
                                pending_requests.insert(req_id, peer_str.clone());
                            }
                        }
                        // else: within cooldown — silently skip this stale message

                        let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);
                        return;
                    }
                }
            };

            // Persist crypto state after decrypt.
            persist_crypto_state(olm, crypto_store, &peer_str);

            // Detect message envelope and route accordingly.
            let text = String::from_utf8_lossy(&plaintext).to_string();
            match serde_json::from_str::<MessageEnvelope>(&text) {
                Ok(MessageEnvelope::ChannelMessage { sid, cid, text: msg_text, ts, sig, pk, mid, reply_to, file_id }) => {
                    // SECURITY: Verify sender is a member of the claimed server.
                    if let Some(state) = server_states.get(&sid) {
                        if !state.members.contains_key(&peer_str) {
                            hollow_log!("[HOLLOW-SECURITY] REJECTED ChannelMessage from {peer_str} — not a member of server {sid}");
                            return;
                        }
                    } else {
                        hollow_log!("[HOLLOW-SECURITY] REJECTED ChannelMessage for unknown server {sid}");
                        return;
                    }

                    // SECURITY: Reject messages with invalid signatures.
                    if sig.is_some() {
                        let payload = message_signing_payload(
                            "ch", &format!("{sid}:{cid}"), &peer_str, ts, &msg_text,
                        );
                        if !verify_message_signature(&peer_str, sig.as_deref(), pk.as_deref(), &payload) {
                            hollow_log!("[HOLLOW-SECURITY] REJECTED ChannelMessage from {peer_str} — signature verification FAILED");
                            return;
                        }
                    }

                    // SECURITY: Enforce 4,000 character limit on message text.
                    let msg_text = if msg_text.len() > 4000 { msg_text[..4000].to_string() } else { msg_text };

                    // Persist channel message using sender's timestamp.
                    // INSERT OR IGNORE deduplicates via UNIQUE(server_id, channel_id, sender_id, timestamp, text).
                    let mut is_new = true;
                    let data_dir = crate::identity::data_dir().unwrap_or_default();
                    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                    if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                            match store.insert_channel_message(
                                &sid, &cid, &peer_str, &msg_text, false, ts,
                                sig.as_deref(), pk.as_deref(), mid.as_deref(),
                                reply_to.as_deref(), file_id.as_deref(),
                            ) {
                                Ok(0) => { is_new = false; } // INSERT OR IGNORE skipped — duplicate
                                Ok(_) => {}
                                Err(_) => { is_new = false; }
                            }
                        }
                    }

                    // Only emit event if this is a genuinely new message.
                    if is_new {
                        let _ = event_tx
                            .send(NetworkEvent::ChannelMessageReceived {
                                server_id: sid,
                                channel_id: cid,
                                from_peer: peer_str,
                                text: msg_text,
                                timestamp: ts,
                                message_id: mid.unwrap_or_default(),
                                reply_to_mid: reply_to.unwrap_or_default(),
                            })
                            .await;
                    }
                }
                Ok(MessageEnvelope::ChannelSyncBatch { sid, cid, messages, total, has_more }) => {
                    hollow_log!("[HOLLOW-SYNC] Received {} sync messages for {cid} in {sid} (total: {total}, has_more: {has_more:?})", messages.len());
                    let local_peer = swarm.local_peer_id().to_string();
                    let mut new_count = 0u32;
                    let received_count = messages.len() as u32;

                    let data_dir = crate::identity::data_dir().unwrap_or_default();
                    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                    if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                            for msg in &messages {
                                // Verify signature on each synced message.
                                if msg.sig.is_some() {
                                    let payload = message_signing_payload(
                                        "ch", &format!("{sid}:{cid}"), &msg.s, msg.ts, &msg.t,
                                    );
                                    if !verify_message_signature(&msg.s, msg.sig.as_deref(), msg.pk.as_deref(), &payload) {
                                        hollow_log!("[HOLLOW-CRYPTO] Signature verification FAILED for synced message from {}", msg.s);
                                    }
                                }

                                let is_mine = msg.s == local_peer;
                                match store.insert_channel_message(
                                    &sid, &cid, &msg.s, &msg.t, is_mine, msg.ts,
                                    msg.sig.as_deref(), msg.pk.as_deref(), msg.mid.as_deref(),
                                    msg.reply_to.as_deref(), msg.file_id.as_deref(),
                                ) {
                                    Ok(1) => { new_count += 1; }
                                    _ => {} // Duplicate or error — skip.
                                }

                                // Sync reactions for this message (INSERT OR IGNORE — idempotent).
                                if let Some(mid) = &msg.mid {
                                    for r in &msg.reactions {
                                        let _ = store.add_reaction(
                                            mid, &r.e, &r.p, r.ts,
                                            r.sig.as_deref(), r.pk.as_deref(),
                                        );
                                    }
                                }
                            }

                            // Pagination: if has_more, send a follow-up ChannelSyncRequest
                            // with updated per-sender timestamps from our DB.
                            if has_more == Some(true) {
                                let sender_ts = store
                                    .get_per_sender_timestamps(&sid, &cid)
                                    .unwrap_or_default();
                                let since = store
                                    .get_latest_channel_timestamp(&sid, &cid)
                                    .unwrap_or(None)
                                    .unwrap_or(0);
                                hollow_log!("[HOLLOW-SYNC] Requesting next page for {cid} in {sid}");
                                swarm.behaviour_mut().messaging.send_request(
                                    &peer,
                                    HavenMessage::ChannelSyncRequest {
                                        server_id: sid.clone(),
                                        channel_id: cid.clone(),
                                        since_timestamp: since,
                                        sender_timestamps: sender_ts,
                                    },
                                );
                            }
                        }
                    }

                    // Emit progress so the UI can show "Syncing 47/120..."
                    if total > 0 {
                        let _ = event_tx.send(NetworkEvent::MessageSyncProgress {
                            server_id: sid.clone(),
                            channel_id: cid.clone(),
                            received_count,
                            total_count: total,
                        }).await;
                    }

                    // Only emit completion when there are no more pages.
                    if has_more != Some(true) {
                        let _ = event_tx.send(NetworkEvent::MessageSyncCompleted {
                            server_id: sid.clone(),
                            new_message_count: new_count,
                        }).await;

                        // File sync happens from the Dart side after a delay
                        // to avoid interfering with the message sync pipeline.
                    }
                }
                Ok(MessageEnvelope::DirectMessage { text: msg_text, ts, sig, pk, mid, reply_to, file_id }) => {
                    // SECURITY: Enforce 4,000 character limit on message text.
                    let msg_text = if msg_text.len() > 4000 { msg_text[..4000].to_string() } else { msg_text };

                    // Verify DM signature if present.
                    if sig.is_some() {
                        let local_peer = swarm.local_peer_id().to_string();
                        let payload = message_signing_payload(
                            "dm", &local_peer, &peer_str, ts, &msg_text,
                        );
                        if !verify_message_signature(&peer_str, sig.as_deref(), pk.as_deref(), &payload) {
                            hollow_log!("[HOLLOW-CRYPTO] Signature verification FAILED for DM from {peer_str}");
                        }
                    }

                    // Persist received DM using sender's timestamp (not Dart DateTime.now()).
                    // This ensures DM sync timestamps are consistent for deduplication.
                    let mut is_new = true;
                    {
                        let data_dir = crate::identity::data_dir().unwrap_or_default();
                        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                        if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                match store.insert(
                                    &peer_str, &msg_text, false, ts,
                                    sig.as_deref(), pk.as_deref(), mid.as_deref(),
                                    reply_to.as_deref(), file_id.as_deref(),
                                ) {
                                    Ok(0) => { is_new = false; } // Duplicate
                                    Ok(_) => {}
                                    Err(_) => { is_new = false; }
                                }
                            }
                        }
                    }

                    // Only emit event if this is a genuinely new message.
                    if is_new {
                        let _ = event_tx
                            .send(NetworkEvent::MessageReceived {
                                from_peer: peer_str,
                                text: msg_text,
                                timestamp: ts,
                                message_id: mid.unwrap_or_default(),
                                reply_to_mid: reply_to.unwrap_or_default(),
                            })
                            .await;
                    }
                }
                Ok(MessageEnvelope::DmSyncBatch { messages, has_more }) => {
                    hollow_log!("[HOLLOW-SYNC] Received {} DM sync messages from {peer_str} (has_more: {has_more:?})", messages.len());
                    let local_peer = swarm.local_peer_id().to_string();
                    let mut new_count = 0u32;

                    let data_dir = crate::identity::data_dir().unwrap_or_default();
                    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                    if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                            for msg in &messages {
                                // All sync items are messages the peer SENT to us
                                // (get_dm_messages_since only returns is_mine=1 from their DB).
                                // From our perspective, these are received messages (is_mine=false).

                                // Verify signature if present.
                                if msg.sig.is_some() {
                                    // Sender=them, recipient=us
                                    let payload = message_signing_payload(
                                        "dm", &local_peer, &peer_str, msg.ts, &msg.t,
                                    );
                                    if !verify_message_signature(&peer_str, msg.sig.as_deref(), msg.pk.as_deref(), &payload) {
                                        hollow_log!("[HOLLOW-CRYPTO] Signature verification FAILED for DM sync message from {peer_str}");
                                    }
                                }

                                match store.insert(
                                    &peer_str, &msg.t, false, msg.ts,
                                    msg.sig.as_deref(), msg.pk.as_deref(), msg.mid.as_deref(),
                                    msg.reply_to.as_deref(), msg.file_id.as_deref(),
                                ) {
                                    Ok(id) if id > 0 => { new_count += 1; }
                                    _ => {} // Duplicate or error — skip.
                                }

                                // Sync reactions for this message (INSERT OR IGNORE — idempotent).
                                if let Some(mid) = &msg.mid {
                                    for r in &msg.reactions {
                                        let _ = store.add_reaction(
                                            mid, &r.e, &r.p, r.ts,
                                            r.sig.as_deref(), r.pk.as_deref(),
                                        );
                                    }
                                }
                            }

                            // Pagination: if has_more, send follow-up DmSyncRequest.
                            if has_more == Some(true) {
                                let since = store
                                    .get_latest_dm_timestamp(&peer_str)
                                    .unwrap_or(None)
                                    .unwrap_or(0);
                                hollow_log!("[HOLLOW-SYNC] Requesting next DM page from {peer_str} since {since}");
                                swarm.behaviour_mut().messaging.send_request(
                                    &peer,
                                    HavenMessage::DmSyncRequest {
                                        since_timestamp: since,
                                    },
                                );
                            }
                        }
                    }

                    hollow_log!("[HOLLOW-SYNC] DM sync: {new_count} new messages from {peer_str}");
                    // Always emit DmSyncCompleted — even with 0 new messages.
                    // Dart may have cleared its in-memory cache on disconnect;
                    // this tells it to reload from DB regardless.
                    // Only emit completion when there are no more pages.
                    if has_more != Some(true) {
                        let _ = event_tx.send(NetworkEvent::DmSyncCompleted {
                            peer_id: peer_str,
                            new_message_count: new_count,
                        }).await;
                    }
                }
                Ok(MessageEnvelope::EditMessage { mid, text: new_text, ts, sig, pk, sid, cid }) => {
                    hollow_log!("[HOLLOW-EDIT] Received edit for message {mid} from {peer_str}");

                    // Persist the edit to local DB (preserves old text).
                    let data_dir = crate::identity::data_dir().unwrap_or_default();
                    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                    let mut edit_applied = false;
                    if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                            if sid.is_some() {
                                // Channel edit — verify sender owns the message.
                                let sender = store.get_channel_message_sender(&mid);
                                if sender.as_deref() == Some(&peer_str) {
                                    let _ = store.edit_channel_message(
                                        &mid, &new_text, ts,
                                        sig.as_deref(), pk.as_deref(),
                                    );
                                    edit_applied = true;
                                } else {
                                    hollow_log!("[HOLLOW-EDIT] Rejected: {peer_str} tried to edit message {mid} owned by {sender:?}");
                                }
                            } else {
                                // DM edit — verify the message is NOT mine (i.e. it's from this peer).
                                let is_mine = store.get_dm_message_is_mine(&mid);
                                if is_mine == Some(false) {
                                    let _ = store.edit_dm_message(
                                        &mid, &new_text, ts,
                                        sig.as_deref(), pk.as_deref(),
                                    );
                                    edit_applied = true;
                                } else {
                                    hollow_log!("[HOLLOW-EDIT] Rejected: {peer_str} tried to edit DM {mid} (is_mine={is_mine:?})");
                                }
                            }
                        }
                    }

                    // Emit event so Dart updates UI.
                    if edit_applied {
                        if let (Some(server_id), Some(channel_id)) = (sid, cid) {
                            let _ = event_tx.send(NetworkEvent::ChannelMessageEdited {
                                server_id,
                                channel_id,
                                message_id: mid,
                                new_text,
                                edited_at: ts,
                            }).await;
                        } else {
                            let _ = event_tx.send(NetworkEvent::DmMessageEdited {
                                peer_id: peer_str,
                                message_id: mid,
                                new_text,
                                edited_at: ts,
                            }).await;
                        }
                    }
                }
                Ok(MessageEnvelope::DeleteMessage { mid, ts, sig, pk, sid, cid }) => {
                    hollow_log!("[HOLLOW-DELETE] Received delete for message {mid} from {peer_str}");

                    // Hide the message in local DB (preserves text in message_deletions).
                    let data_dir = crate::identity::data_dir().unwrap_or_default();
                    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                    if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                            if sid.is_some() {
                                // SECURITY: Verify sender owns the message before hiding.
                                let sender = store.get_channel_message_sender(&mid);
                                if sender.as_deref() != Some(&peer_str) {
                                    hollow_log!("[HOLLOW-SECURITY] REJECTED DeleteMessage from {peer_str} — not the sender of message {mid}");
                                    return;
                                }
                                let _ = store.hide_channel_message(
                                    &mid, ts,
                                    sig.as_deref(), pk.as_deref(),
                                );
                            } else {
                                // SECURITY: Verify sender owns the DM message.
                                let is_mine = store.get_dm_message_is_mine(&mid);
                                if is_mine != Some(false) {
                                    // If is_mine is true, it's OUR message (not the peer's).
                                    // If is_mine is None, message not found. Either way, reject.
                                    hollow_log!("[HOLLOW-SECURITY] REJECTED DeleteMessage (DM) from {peer_str} — not the sender of message {mid}");
                                    return;
                                }
                                let _ = store.hide_dm_message(
                                    &mid, ts,
                                    sig.as_deref(), pk.as_deref(),
                                );
                            }
                        }
                    }

                    // Emit event so Dart updates UI.
                    if let (Some(server_id), Some(channel_id)) = (sid, cid) {
                        let _ = event_tx.send(NetworkEvent::ChannelMessageDeleted {
                            server_id,
                            channel_id,
                            message_id: mid,
                            deleted_at: ts,
                        }).await;
                    } else {
                        let _ = event_tx.send(NetworkEvent::DmMessageDeleted {
                            peer_id: peer_str,
                            message_id: mid,
                            deleted_at: ts,
                        }).await;
                    }
                }
                Ok(MessageEnvelope::AddReaction { mid, emoji, ts, sig, pk, sid, cid }) => {
                    // SECURITY: Reject emoji strings longer than 10 characters.
                    if emoji.len() > 10 {
                        hollow_log!("[HOLLOW-SECURITY] REJECTED AddReaction from {peer_str} — emoji too long ({} chars)", emoji.len());
                        return;
                    }
                    hollow_log!("[HOLLOW-REACTION] Received reaction {emoji} on {mid} from {peer_str}");

                    let data_dir = crate::identity::data_dir().unwrap_or_default();
                    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                    if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                            let _ = store.add_reaction(
                                &mid, &emoji, &peer_str, ts,
                                sig.as_deref(), pk.as_deref(),
                            );
                        }
                    }

                    if let (Some(server_id), Some(channel_id)) = (sid, cid) {
                        let _ = event_tx.send(NetworkEvent::ChannelReactionAdded {
                            server_id,
                            channel_id,
                            message_id: mid,
                            emoji,
                            reactor: peer_str,
                            added_at: ts,
                        }).await;
                    } else {
                        let _ = event_tx.send(NetworkEvent::DmReactionAdded {
                            peer_id: peer_str.clone(),
                            message_id: mid,
                            emoji,
                            reactor: peer_str,
                            added_at: ts,
                        }).await;
                    }
                }
                Ok(MessageEnvelope::RemoveReaction { mid, emoji, ts, sig, pk, sid, cid }) => {
                    hollow_log!("[HOLLOW-REACTION] Received remove reaction {emoji} on {mid} from {peer_str}");

                    let data_dir = crate::identity::data_dir().unwrap_or_default();
                    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                    if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                            let _ = store.remove_reaction(
                                &mid, &emoji, &peer_str, ts,
                                sig.as_deref(), pk.as_deref(),
                            );
                        }
                    }

                    if let (Some(server_id), Some(channel_id)) = (sid, cid) {
                        let _ = event_tx.send(NetworkEvent::ChannelReactionRemoved {
                            server_id,
                            channel_id,
                            message_id: mid,
                            emoji,
                            reactor: peer_str,
                            removed_at: ts,
                        }).await;
                    } else {
                        let _ = event_tx.send(NetworkEvent::DmReactionRemoved {
                            peer_id: peer_str.clone(),
                            message_id: mid,
                            emoji,
                            reactor: peer_str,
                            removed_at: ts,
                        }).await;
                    }
                }
                // -- File transfer receive handlers --
                Ok(MessageEnvelope::FileHeader { fid, name, ext, mime, size, chunks, img, w, h, mid, sid, cid, ts, aes_key, aes_nonce, .. }) => {
                    use crate::node::file_transfer;
                    hollow_log!("[HOLLOW-FILE] FileHeader received: {fid} ({name}, {size} bytes, {chunks} chunks)");

                    // SECURITY: Validate file size against server limit (or default 34MB for DMs).
                    let max_bytes: u64 = if let Some(ref s) = sid {
                        if let Some(state) = server_states.get(s) {
                            let max_mb_str = state.settings.get("max_file_size_mb")
                                .map(|r| r.read().clone())
                                .unwrap_or_else(|| "34".to_string());
                            let max_mb = max_mb_str.parse::<u64>().unwrap_or(34);
                            max_mb * 1024 * 1024
                        } else {
                            34 * 1024 * 1024
                        }
                    } else {
                        34 * 1024 * 1024
                    };
                    if size > max_bytes {
                        hollow_log!("[HOLLOW-SECURITY] REJECTED FileHeader from {peer_str} — size {size} exceeds max {max_bytes} bytes");
                        return;
                    }

                    let ctx_type = if sid.is_some() { "channel" } else { "dm" };
                    let ctx_id = match (&sid, &cid) {
                        (Some(s), Some(c)) => format!("{s}:{c}"),
                        _ => peer_str.clone(),
                    };

                    // Save file metadata to DB.
                    let data_dir = crate::identity::data_dir().unwrap_or_default();
                    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                    if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                            let _ = store.insert_file_metadata(
                                &fid, &name, &ext, &mime,
                                size, chunks, img,
                                w, h,
                                mid.as_deref(), ctx_type, &ctx_id,
                                &peer_str, false, ts,
                            );
                        }
                    }

                    let mid_str = mid.unwrap_or_default();
                    let sid_str = sid.unwrap_or_default();
                    let cid_str = cid.unwrap_or_else(|| peer_str.clone());

                    // If aes_key is present, this is a streamed transfer — register for stream receive.
                    if let (Some(ak), Some(an)) = (aes_key, aes_nonce) {
                        pending_file_streams.insert(fid.clone(), PendingFileStream {
                            aes_key: ak,
                            aes_nonce: an,
                            file_name: name.clone(),
                            ext: ext.clone(),
                            sender: peer_str.clone(),
                            server_id: sid_str.clone(),
                            channel_id: cid_str.clone(),
                            message_id: mid_str.clone(),
                            is_image: img,
                            width: w,
                            height: h,
                        });
                        hollow_log!("[HOLLOW-FILE] Registered pending stream for {fid} (streamed transfer)");
                    }

                    let _ = event_tx.send(NetworkEvent::FileHeaderReceived {
                        file_id: fid,
                        file_name: name,
                        size_bytes: size,
                        is_image: img,
                        width: w,
                        height: h,
                        message_id: mid_str,
                        sender_id: peer_str.clone(),
                        server_id: sid_str,
                        channel_id: cid_str,
                    }).await;
                }
                Ok(MessageEnvelope::FileChunk { fid, idx, data }) => {
                    use crate::node::file_transfer;
                    // Decode base64 chunk data.
                    let chunk_bytes = base64::engine::general_purpose::STANDARD.decode(&data);
                    if let Err(e) = &chunk_bytes {
                        hollow_log!("[HOLLOW-FILE] Failed to decode chunk {idx} for {fid}: {e}");
                    }
                    if let Ok(chunk_bytes) = chunk_bytes {

                    // Write chunk to disk.
                    if let Err(e) = file_transfer::write_chunk(&fid, idx, &chunk_bytes) {
                        hollow_log!("[HOLLOW-FILE] {e}");
                    } else {

                    // Update DB.
                    let data_dir = crate::identity::data_dir().unwrap_or_default();
                    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                    if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                            if let Ok(received) = store.mark_chunk_received(&fid, idx) {
                                // Get total chunks from file metadata.
                                if let Ok(Some(file_meta)) = store.get_file_metadata(&fid) {
                                    let _ = event_tx.send(NetworkEvent::FileProgress {
                                        file_id: fid.clone(),
                                        chunks_received: received,
                                        total_chunks: file_meta.chunk_count,
                                    }).await;

                                    // Check if all chunks received.
                                    if received >= file_meta.chunk_count {
                                        let final_path = file_transfer::final_file_path(&fid, &file_meta.file_ext);
                                        match file_transfer::assemble_file(&fid, file_meta.chunk_count, &final_path) {
                                            Ok(()) => {
                                                let disk_path = final_path.to_string_lossy().to_string();
                                                let _ = store.mark_file_complete(&fid, &disk_path);
                                                hollow_log!("[HOLLOW-FILE] File {fid} complete: {disk_path}");
                                                let _ = event_tx.send(NetworkEvent::FileCompleted {
                                                    file_id: fid,
                                                    disk_path,
                                                }).await;
                                            }
                                            Err(e) => {
                                                hollow_log!("[HOLLOW-FILE] Assembly failed for {fid}: {e}");
                                                let _ = event_tx.send(NetworkEvent::FileFailed {
                                                    file_id: fid,
                                                    error: e,
                                                }).await;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    } // else (write_chunk ok)
                    } // if let Ok(chunk_bytes)
                }

                // -- Vault shard receive handlers (Phase 4) --
                Ok(MessageEnvelope::ShardStore { sid, cid, si, sk, k, m, total_size, tier, data, chunks }) => {
                    hollow_log!("[HOLLOW-VAULT] ShardStore received: cid={cid} si={si} chunks={chunks} from {peer_str}");

                    // Verify sender is a member of the server
                    let is_member = server_states.get(&sid)
                        .map(|s| s.members.contains_key(&peer_str))
                        .unwrap_or(false);
                    if !is_member {
                        hollow_log!("[HOLLOW-SECURITY] REJECTED ShardStore from {peer_str} — not a member of {sid}");
                    } else if chunks == 0 && data.is_empty() {
                        // Streamed shard — data arrives via /hollow/stream/1.0.0.
                        let key = format!("{cid}:{si}");
                        pending_shard_streams.insert(key.clone(), PendingShardStream {
                            server_id: sid, content_id: cid, shard_index: si,
                            shard_key: sk, k, m, total_size, tier,
                        });
                        hollow_log!("[HOLLOW-VAULT] Registered pending shard stream: {key}");
                    } else if chunks == 0 {
                        // Inline shard (legacy) — decode and store immediately
                        if let Ok(shard_bytes) = base64::engine::general_purpose::STANDARD.decode(&data) {
                            // Check pledge capacity
                            let local_peer = swarm.local_peer_id().to_string();
                            let pledge = server_states.get(&sid)
                                .map(|s| s.get_storage_pledge(&local_peer))
                                .unwrap_or(0);
                            let data_dir = crate::identity::data_dir().unwrap_or_default();
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            let vault_dir = data_dir.join("vault");
                            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);

                            if let Ok(content_store) = crate::vault::content_store::ContentStore::open(&db_path, &passphrase, &vault_dir) {
                                let used = content_store.total_storage_used(&sid).unwrap_or(0);
                                if pledge > 0 && used + shard_bytes.len() as u64 > pledge {
                                    hollow_log!("[HOLLOW-VAULT] Pledge exceeded for {sid} — rejecting shard");
                                    let ack = MessageEnvelope::ShardStoreAck {
                                        sid: sid.clone(), cid: cid.clone(), si, ok: false,
                                        err: Some("Pledge capacity exceeded".into()),
                                    };
                                    let ack_json = serde_json::to_string(&ack).unwrap_or_default();
                                    if let Ok(pid) = peer_str.parse::<PeerId>() {
                                        send_encrypted_message(
                                            swarm, olm, crypto_store,
                                            pending_requests, outbound_message_text,
                                            &pid, &peer_str, &ack_json, event_tx,
                                        ).await;
                                    }
                                } else {
                                    // Store the shard
                                    let tier_enum = crate::vault::content_store::StorageTier::from_str(&tier);
                                    match content_store.store_shard(&sid, &cid, si, k, m, total_size, tier_enum, &shard_bytes) {
                                        Ok(_) => {
                                            hollow_log!("[HOLLOW-VAULT] Shard stored: cid={cid} si={si}");
                                            let _ = event_tx.send(NetworkEvent::ShardStored {
                                                server_id: sid.clone(),
                                                content_id: cid.clone(),
                                                shard_index: si,
                                                from_peer: peer_str.clone(),
                                            }).await;
                                            // Send ack
                                            let ack = MessageEnvelope::ShardStoreAck {
                                                sid: sid.clone(), cid: cid.clone(), si, ok: true, err: None,
                                            };
                                            let ack_json = serde_json::to_string(&ack).unwrap_or_default();
                                            if let Ok(pid) = peer_str.parse::<PeerId>() {
                                                send_encrypted_message(
                                                    swarm, olm, crypto_store,
                                                    pending_requests, outbound_message_text,
                                                    &pid, &peer_str, &ack_json, event_tx,
                                                ).await;
                                            }
                                        }
                                        Err(e) => {
                                            hollow_log!("[HOLLOW-VAULT] Failed to store shard: {e}");
                                            let ack = MessageEnvelope::ShardStoreAck {
                                                sid: sid.clone(), cid: cid.clone(), si, ok: false,
                                                err: Some(e),
                                            };
                                            let ack_json = serde_json::to_string(&ack).unwrap_or_default();
                                            if let Ok(pid) = peer_str.parse::<PeerId>() {
                                                send_encrypted_message(
                                                    swarm, olm, crypto_store,
                                                    pending_requests, outbound_message_text,
                                                    &pid, &peer_str, &ack_json, event_tx,
                                                ).await;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        // Chunked shard — create assembly entry
                        let key = format!("{cid}:{si}:{peer_str}");
                        pending_shard_assembly.insert(key, PendingShardAssembly {
                            server_id: sid,
                            content_id: cid,
                            shard_index: si,
                            shard_key: sk,
                            k,
                            m,
                            total_size,
                            tier,
                            expected_chunks: chunks,
                            received: std::collections::HashSet::new(),
                            chunk_data: Vec::new(),
                            sender_peer: peer_str.clone(),
                            received_at: std::time::Instant::now(),
                        });
                    }
                }

                Ok(MessageEnvelope::ShardChunk { sid, cid, si, ci, data }) => {
                    let key = format!("{cid}:{si}:{peer_str}");
                    if let Some(assembly) = pending_shard_assembly.get_mut(&key) {
                        if let Ok(chunk_bytes) = base64::engine::general_purpose::STANDARD.decode(&data) {
                            if !assembly.received.contains(&ci) {
                                assembly.received.insert(ci);
                                assembly.chunk_data.push((ci, chunk_bytes));
                            }

                            // Check if all chunks received
                            if assembly.received.len() as u32 >= assembly.expected_chunks {
                                // Reassemble in order
                                let mut asm = pending_shard_assembly.remove(&key).unwrap();
                                asm.chunk_data.sort_by_key(|(idx, _)| *idx);
                                let mut full_data = Vec::new();
                                for (_, chunk) in &asm.chunk_data {
                                    full_data.extend_from_slice(chunk);
                                }

                                // Store via ContentStore
                                let data_dir = crate::identity::data_dir().unwrap_or_default();
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let vault_dir = data_dir.join("vault");
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);

                                if let Ok(content_store) = crate::vault::content_store::ContentStore::open(&db_path, &passphrase, &vault_dir) {
                                    let tier_enum = crate::vault::content_store::StorageTier::from_str(&asm.tier);
                                    match content_store.store_shard(&asm.server_id, &asm.content_id, asm.shard_index, asm.k, asm.m, asm.total_size, tier_enum, &full_data) {
                                        Ok(_) => {
                                            hollow_log!("[HOLLOW-VAULT] Chunked shard assembled+stored: cid={} si={}", asm.content_id, asm.shard_index);
                                            let _ = event_tx.send(NetworkEvent::ShardStored {
                                                server_id: asm.server_id.clone(),
                                                content_id: asm.content_id.clone(),
                                                shard_index: asm.shard_index,
                                                from_peer: peer_str.clone(),
                                            }).await;
                                            let ack = MessageEnvelope::ShardStoreAck {
                                                sid: asm.server_id, cid: asm.content_id, si: asm.shard_index, ok: true, err: None,
                                            };
                                            let ack_json = serde_json::to_string(&ack).unwrap_or_default();
                                            if let Ok(pid) = peer_str.parse::<PeerId>() {
                                                send_encrypted_message(
                                                    swarm, olm, crypto_store,
                                                    pending_requests, outbound_message_text,
                                                    &pid, &peer_str, &ack_json, event_tx,
                                                ).await;
                                            }
                                        }
                                        Err(e) => {
                                            hollow_log!("[HOLLOW-VAULT] Failed to store assembled shard: {e}");
                                            let ack = MessageEnvelope::ShardStoreAck {
                                                sid: asm.server_id, cid: asm.content_id, si: asm.shard_index, ok: false, err: Some(e),
                                            };
                                            let ack_json = serde_json::to_string(&ack).unwrap_or_default();
                                            if let Ok(pid) = peer_str.parse::<PeerId>() {
                                                send_encrypted_message(
                                                    swarm, olm, crypto_store,
                                                    pending_requests, outbound_message_text,
                                                    &pid, &peer_str, &ack_json, event_tx,
                                                ).await;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        hollow_log!("[HOLLOW-VAULT] ShardChunk for unknown assembly: cid={cid} si={si} ci={ci}");
                    }
                }

                Ok(MessageEnvelope::ShardStoreAck { sid, cid, si, ok, err }) => {
                    hollow_log!("[HOLLOW-VAULT] ShardStoreAck: cid={cid} si={si} ok={ok} err={err:?}");
                    let _ = event_tx.send(NetworkEvent::ShardStoreAckReceived {
                        server_id: sid.clone(),
                        content_id: cid.clone(),
                        shard_index: si,
                        success: ok,
                        error: err.unwrap_or_default(),
                    }).await;

                    // Mark placement as confirmed in DB
                    if ok {
                        let data_dir = crate::identity::data_dir().unwrap_or_default();
                        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                        let vault_dir = data_dir.join("vault");
                        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                        if let Ok(content_store) = crate::vault::content_store::ContentStore::open(&db_path, &passphrase, &vault_dir) {
                            let _ = content_store.confirm_placement(&cid, si);
                        }
                    }
                }

                Ok(MessageEnvelope::ShardDelete { sid, cid }) => {
                    hollow_log!("[HOLLOW-VAULT] ShardDelete received: cid={cid} from {peer_str}");

                    // Verify sender is a member with MANAGE_SERVER permission
                    let allowed = server_states.get(&sid)
                        .map(|s| {
                            s.members.contains_key(&peer_str) &&
                            s.has_permission(&peer_str, crate::crdt::operations::Permission::MANAGE_SERVER)
                        })
                        .unwrap_or(false);

                    if !allowed {
                        hollow_log!("[HOLLOW-SECURITY] REJECTED ShardDelete from {peer_str} — not authorized for {sid}");
                    } else {
                        let data_dir = crate::identity::data_dir().unwrap_or_default();
                        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                        let vault_dir = data_dir.join("vault");
                        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                        if let Ok(cs) = crate::vault::content_store::ContentStore::open(&db_path, &passphrase, &vault_dir) {
                            let _ = cs.delete_content(&sid, &cid);
                            let _ = cs.delete_placements(&cid);
                        }
                        hollow_log!("[HOLLOW-VAULT] Shard content deleted: cid={cid}");
                        let _ = event_tx.send(NetworkEvent::ShardDeleted {
                            server_id: sid,
                            content_id: cid,
                        }).await;
                    }
                }

                // -- Vault shard retrieve handlers (Phase 4) --

                Ok(MessageEnvelope::ShardRequest { sid, cid, si, sk }) => {
                    hollow_log!("[HOLLOW-VAULT] ShardRequest: cid={cid} si={si} from {peer_str}");
                    let is_member = server_states.get(&sid)
                        .map(|s| s.members.contains_key(&peer_str))
                        .unwrap_or(false);
                    if !is_member {
                        hollow_log!("[HOLLOW-SECURITY] REJECTED ShardRequest from {peer_str} — not a member of {sid}");
                    } else {
                        let data_dir = crate::identity::data_dir().unwrap_or_default();
                        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                        let vault_dir = data_dir.join("vault");
                        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);

                        if let Ok(cs) = crate::vault::content_store::ContentStore::open(&db_path, &passphrase, &vault_dir) {
                            match cs.read_shard_unchecked(&sid, &sk) {
                                Ok(shard_data) => {
                                    // Send metadata via Olm, stream shard bytes.
                                    let resp = MessageEnvelope::ShardResponse {
                                        sid: sid.clone(), cid: cid.clone(), si,
                                        data: String::new(), chunks: 0, found: true,
                                    };
                                    let json = serde_json::to_string(&resp).unwrap_or_default();
                                    if let Ok(pid) = peer_str.parse::<PeerId>() {
                                        send_encrypted_message(
                                            swarm, olm, crypto_store,
                                            pending_requests, outbound_message_text,
                                            &pid, &peer_str, &json, event_tx,
                                        ).await;

                                        // Stream shard bytes via /hollow/stream/1.0.0.
                                        if let Ok(stream_req) = super::stream_transfer::shard_stream_request(
                                            &cid, si, &shard_data,
                                        ) {
                                            swarm.behaviour_mut().file_streaming.send_request(
                                                &pid, stream_req,
                                            );
                                            hollow_log!("[HOLLOW-VAULT] Streaming shard response si={si} ({} bytes) to {peer_str}", shard_data.len());
                                        }
                                    }
                                }
                                Err(_) => {
                                    let resp = MessageEnvelope::ShardResponse {
                                        sid, cid, si, data: String::new(), chunks: 0, found: false,
                                    };
                                    let json = serde_json::to_string(&resp).unwrap_or_default();
                                    if let Ok(pid) = peer_str.parse::<PeerId>() {
                                        send_encrypted_message(
                                            swarm, olm, crypto_store,
                                            pending_requests, outbound_message_text,
                                            &pid, &peer_str, &json, event_tx,
                                        ).await;
                                    }
                                }
                            }
                        }
                    }
                }

                Ok(MessageEnvelope::ShardResponse { sid, cid, si, data, chunks, found }) => {
                    hollow_log!("[HOLLOW-VAULT] ShardResponse: cid={cid} si={si} found={found} chunks={chunks} from {peer_str}");
                    if !found {
                        let _ = event_tx.send(NetworkEvent::ShardRequestFailed {
                            server_id: sid, content_id: cid, shard_index: si,
                            error: "Shard not found on peer".into(),
                        }).await;
                    } else if data.is_empty() {
                        // Streamed shard response — data arrives via /hollow/stream/1.0.0.
                        // Register pending_shard_streams so the stream handler stores it.
                        let key = format!("{cid}:{si}");
                        pending_shard_streams.insert(key.clone(), PendingShardStream {
                            server_id: sid.clone(), content_id: cid.clone(), shard_index: si,
                            shard_key: String::new(), k: 0, m: 0, total_size: 0,
                            tier: "standard".to_string(),
                        });
                        hollow_log!("[HOLLOW-VAULT] Registered pending shard stream for response: {key}");
                    } else {
                        // Inline shard data (small shards) — decode and store immediately
                        if let Ok(shard_bytes) = base64::engine::general_purpose::STANDARD.decode(&data) {
                            let data_dir = crate::identity::data_dir().unwrap_or_default();
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            let vault_dir = data_dir.join("vault");
                            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                            if let Ok(cs) = crate::vault::content_store::ContentStore::open(&db_path, &passphrase, &vault_dir) {
                                let tier = crate::vault::content_store::StorageTier::Standard;
                                let _ = cs.store_shard(&sid, &cid, si, 0, 0, 0, tier, &shard_bytes);
                            }
                            let _ = event_tx.send(NetworkEvent::ShardReceived {
                                server_id: sid, content_id: cid, shard_index: si,
                                from_peer: peer_str.clone(),
                            }).await;
                        }
                    }
                }

                Ok(MessageEnvelope::ShardResponseChunk { sid, cid, si, ci, data }) => {
                    let key = format!("resp:{cid}:{si}:{peer_str}");
                    if let Some(assembly) = pending_shard_assembly.get_mut(&key) {
                        if let Ok(chunk_bytes) = base64::engine::general_purpose::STANDARD.decode(&data) {
                            if !assembly.received.contains(&ci) {
                                assembly.received.insert(ci);
                                assembly.chunk_data.push((ci, chunk_bytes));
                            }
                            if assembly.received.len() as u32 >= assembly.expected_chunks {
                                let asm = pending_shard_assembly.remove(&key).unwrap();
                                let mut sorted = asm.chunk_data;
                                sorted.sort_by_key(|(idx, _)| *idx);
                                let _full_data: Vec<u8> = sorted.into_iter().flat_map(|(_, d)| d).collect();
                                let _ = event_tx.send(NetworkEvent::ShardReceived {
                                    server_id: sid, content_id: cid, shard_index: si,
                                    from_peer: peer_str.clone(),
                                }).await;
                            }
                        }
                    }
                }

                Ok(MessageEnvelope::ShardProbe { sid, cid }) => {
                    hollow_log!("[HOLLOW-VAULT] ShardProbe: cid={cid} from {peer_str}");
                    let is_member = server_states.get(&sid)
                        .map(|s| s.members.contains_key(&peer_str))
                        .unwrap_or(false);
                    if is_member {
                        let data_dir = crate::identity::data_dir().unwrap_or_default();
                        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                        let vault_dir = data_dir.join("vault");
                        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);

                        let mut indices = Vec::new();
                        if let Ok(cs) = crate::vault::content_store::ContentStore::open(&db_path, &passphrase, &vault_dir) {
                            if let Ok(records) = cs.list_content_shards(&sid, &cid) {
                                indices = records.iter().map(|r| r.shard_index).collect();
                            }
                        }
                        let resp = MessageEnvelope::ShardProbeResponse {
                            sid, cid, shards: indices,
                        };
                        let json = serde_json::to_string(&resp).unwrap_or_default();
                        if let Ok(pid) = peer_str.parse::<PeerId>() {
                            send_encrypted_message(
                                swarm, olm, crypto_store,
                                pending_requests, outbound_message_text,
                                &pid, &peer_str, &json, event_tx,
                            ).await;
                        }
                    }
                }

                Ok(MessageEnvelope::ShardProbeResponse { sid, cid, shards }) => {
                    hollow_log!("[HOLLOW-VAULT] ShardProbeResponse: cid={cid} shards={shards:?} from {peer_str}");
                    // Logged for now — download pipeline will use this data when built
                }

                Ok(MessageEnvelope::VaultManifestBroadcast { sid, cid, chid, manifest }) => {
                    hollow_log!("[HOLLOW-VAULT] VaultManifest received: cid={cid} in {sid}/{chid} from {peer_str}");
                    if let Ok(manifest_obj) = serde_json::from_str::<crate::vault::pipeline::VaultManifest>(&manifest) {
                        let data_dir = crate::identity::data_dir().unwrap_or_default();
                        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                        let vault_dir = data_dir.join("vault");
                        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                        if let Ok(cs) = crate::vault::content_store::ContentStore::open(&db_path, &passphrase, &vault_dir) {
                            let _ = cs.save_manifest(&sid, &chid, &manifest_obj);
                        }
                    }
                }

                Ok(MessageEnvelope::ShardMigrate { sid, cid, si, sk, data }) => {
                    hollow_log!("[HOLLOW-VAULT] ShardMigrate received: cid={cid} si={si} from {peer_str}");
                    // Same logic as ShardStore inline — verify membership, store shard
                    let is_member = server_states.get(&sid)
                        .map(|s| s.members.contains_key(&peer_str))
                        .unwrap_or(false);
                    if is_member {
                        if let Ok(shard_bytes) = base64::engine::general_purpose::STANDARD.decode(&data) {
                            let data_dir = crate::identity::data_dir().unwrap_or_default();
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            let vault_dir = data_dir.join("vault");
                            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                            if let Ok(content_store) = crate::vault::content_store::ContentStore::open(&db_path, &passphrase, &vault_dir) {
                                let tier = crate::vault::content_store::StorageTier::Standard;
                                let _ = content_store.store_shard(&sid, &cid, si, 0, 0, 0, tier, &shard_bytes);
                                hollow_log!("[HOLLOW-VAULT] Migrated shard stored: cid={cid} si={si}");
                            }
                        }
                    }
                }

                Ok(MessageEnvelope::SessionAck) => {
                    // Lightweight encrypted ping from peer after they created an inbound
                    // session. The act of decrypting this message upgrades our outbound
                    // session's ratchet so subsequent encrypts produce Normal (type 1).
                    hollow_log!("[HOLLOW-CRYPTO] SessionAck received from {peer_str} — session ratchet upgraded");
                    olm.mark_session_bidirectional(&peer_str);
                }

                Err(_) => {
                    // Legacy raw-text DM (backward compatible).
                    let legacy_ts = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_millis() as i64;
                    let _ = event_tx
                        .send(NetworkEvent::MessageReceived {
                            from_peer: peer_str,
                            text,
                            timestamp: legacy_ts,
                            message_id: String::new(),
                            reply_to_mid: String::new(),
                        })
                        .await;
                }
            }

            // Ack.
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);
        }

        // -- CRDT sync message handlers --

        HavenMessage::SyncRequest { server_id, state_vector_json } => {
            hollow_log!("[HOLLOW-CRDT] SyncRequest from {peer_str} for server {server_id}");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            if let Some(state) = server_states.get(&server_id) {
                // Compute what they're missing
                if let Ok(their_vector) = serde_json::from_str::<StateVector>(&state_vector_json) {
                    let delta = crdt_sync::compute_delta(&state.op_log, &their_vector);
                    if !delta.is_empty() {
                        if let Ok(ops_json) = serde_json::to_string(&delta) {
                            hollow_log!("[HOLLOW-CRDT] Sending {} delta ops to {peer_str}", delta.len());
                            swarm.behaviour_mut().messaging.send_request(
                                &peer,
                                HavenMessage::SyncResponse {
                                    server_id: server_id.clone(),
                                    ops_json,
                                },
                            );
                        }
                    }
                }

                // No bidirectional SyncRequest here — both peers trigger
                // sync in ConnectionEstablished, so both sides already initiate.
            }
        }

        HavenMessage::SyncResponse { server_id, ops_json } => {
            hollow_log!("[HOLLOW-CRDT] SyncResponse from {peer_str} for server {server_id}");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            // Room gating: only accept sync for servers we already know about
            // or are actively trying to join.
            let is_known = server_states.contains_key(&server_id);
            let is_pending_join = pending_server_joins.contains(&server_id);
            if !is_known && !is_pending_join {
                hollow_log!("[HOLLOW-CRDT] Ignoring SyncResponse for unknown server {server_id} (not joined)");
                return;
            }

            if let Ok(incoming_ops) = serde_json::from_str::<Vec<crate::crdt::operations::CrdtOp>>(&ops_json) {
                let state = server_states.entry(server_id.clone()).or_insert_with(|| {
                    let mut s = ServerState::new(server_id.clone(), "".into(), peer_str.clone());
                    s.set_hlc(Hlc::new(swarm.local_peer_id().to_string()));
                    s
                });

                match crdt_sync::merge_ops(state, incoming_ops) {
                    Ok(applied) if applied > 0 => {
                        hollow_log!("[HOLLOW-CRDT] Applied {applied} ops for server {server_id}");

                        // Persist
                        if let Ok(json) = serde_json::to_string(&state) {
                            let data_dir = crate::identity::data_dir().unwrap_or_default();
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                let _ = store.save_server_state(&server_id, &json);
                            }
                        }

                        // Check if this completes a pending server join
                        if pending_server_joins.remove(&server_id) {
                            let server_name = state.name().to_string();
                            hollow_log!("[HOLLOW-CRDT] Server join completed: {server_id} ({server_name})");
                            let _ = event_tx.send(NetworkEvent::ServerJoined {
                                server_id: server_id.clone(),
                                name: server_name,
                            }).await;

                            // Auto-pledge min_pledge_mb for the newly joined server
                            {
                                let local_peer = swarm.local_peer_id().to_string();
                                if state.get_storage_pledge(&local_peer) == 0 {
                                    let min_pledge_bytes = state.min_pledge_mb() * 1024 * 1024;
                                    hollow_log!("[HOLLOW-VAULT] Auto-pledging {} MB for server {server_id}", min_pledge_bytes / (1024 * 1024));
                                    let pledge_op = state.create_op(CrdtPayload::StoragePledgeChanged {
                                        peer_id: local_peer.clone(),
                                        pledge_bytes: min_pledge_bytes,
                                    });
                                    let _ = state.apply_op(&pledge_op);

                                    if let Ok(json) = serde_json::to_string(&state) {
                                        let data_dir = crate::identity::data_dir().unwrap_or_default();
                                        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                            let _ = store.save_server_state(&server_id, &json);
                                            let _ = store.insert_crdt_op(&pledge_op);
                                        }
                                    }

                                    // Broadcast pledge to connected members
                                    if let Ok(op_json) = serde_json::to_string(&pledge_op) {
                                        for member in state.members_list() {
                                            if member.peer_id == local_peer { continue; }
                                            if let Ok(pid) = member.peer_id.parse::<PeerId>() {
                                                if connected_peers.contains(&pid) {
                                                    swarm.behaviour_mut().messaging.send_request(
                                                        &pid,
                                                        HavenMessage::CrdtOpBroadcast {
                                                            server_id: server_id.clone(),
                                                            op_json: op_json.clone(),
                                                        },
                                                    );
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            // Establish Olm session with all server members we're
                            // connected to but don't have sessions with yet.
                            // Also emit PeerDiscovered so they show as online.
                            for member in state.members_list() {
                                let local_id = swarm.local_peer_id().to_string();
                                if member.peer_id != local_id {
                                    if let Ok(member_pid) = member.peer_id.parse::<PeerId>() {
                                        if connected_peers.contains(&member_pid) {
                                            // Ensure member shows as online in UI.
                                            let _ = event_tx.send(NetworkEvent::PeerDiscovered {
                                                peer: DiscoveredPeer {
                                                    peer_id: member.peer_id.clone(),
                                                    addresses: vec![],
                                                },
                                            }).await;

                                            if !olm.has_session(&member.peer_id)
                                                && !key_request_in_flight.contains(&member.peer_id)
                                            {
                                                hollow_log!("[HOLLOW-SWARM] No Olm session with server member {}, sending KeyRequest", member.peer_id);
                                                let req_id = swarm.behaviour_mut().messaging.send_request(
                                                    &member_pid,
                                                    HavenMessage::KeyRequest,
                                                );
                                                pending_requests.insert(req_id, member.peer_id.clone());
                                                key_request_in_flight.insert(member.peer_id.clone());
                                            }
                                        }
                                    }
                                }
                            }

                            // MLS: if we don't have the MLS group after joining,
                            // the MlsWelcome was lost. Send our KeyPackage to the
                            // owner so they can re-add us to the MLS group.
                            if let Some(mls_mgr) = mls.as_ref() {
                                if !mls_mgr.has_group(&server_id) {
                                    hollow_log!("[HOLLOW-MLS] No MLS group after join, sending KeyPackage to owner for MLS bootstrap");
                                    // Find the owner and send KeyPackage.
                                    let local_id = swarm.local_peer_id().to_string();
                                    for member in state.members_list() {
                                        if member.peer_id == local_id { continue; }
                                        let is_owner = state.roles.get(&member.peer_id)
                                            .map(|r| *r.read() == crate::crdt::operations::MemberRole::Owner)
                                            .unwrap_or(false);
                                        if is_owner {
                                            if let Ok(owner_pid) = member.peer_id.parse::<PeerId>() {
                                                if connected_peers.contains(&owner_pid) {
                                                    if let Ok(kp_bytes) = mls_mgr.generate_key_package() {
                                                        let kp_b64 = base64::engine::general_purpose::STANDARD.encode(&kp_bytes);
                                                        swarm.behaviour_mut().messaging.send_request(
                                                            &owner_pid,
                                                            HavenMessage::MlsKeyPackage {
                                                                server_id: server_id.clone(),
                                                                key_package: kp_b64,
                                                            },
                                                        );
                                                    }
                                                }
                                            }
                                            break;
                                        }
                                    }
                                }
                            }
                        }

                        let _ = event_tx.send(NetworkEvent::SyncCompleted {
                            server_id,
                            ops_applied: applied as u32,
                        }).await;
                    }
                    _ => {}
                }
            }
        }

        HavenMessage::CrdtOpBroadcast { server_id, op_json } => {
            hollow_log!("[HOLLOW-CRDT] CrdtOpBroadcast from {peer_str} for server {server_id}");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            // Room gating: only accept ops for servers we're a member of.
            if !server_states.contains_key(&server_id) {
                hollow_log!("[HOLLOW-CRDT] Ignoring CrdtOpBroadcast for unknown server {server_id}");
                return;
            }

            if let Ok(op) = serde_json::from_str::<crate::crdt::operations::CrdtOp>(&op_json) {
                // SECURITY: Log author mismatch but don't reject — the op may be
                // legitimately relayed by another peer during join/sync fan-out.
                // The per-payload permission check below validates the author's role.
                if op.author != peer_str {
                    hollow_log!("[HOLLOW-CRDT] Note: CrdtOpBroadcast author '{}' differs from sender '{peer_str}' (relay)", op.author);
                }

                // SECURITY: Verify the AUTHOR has permission for this operation type.
                // Use op.author (the original creator) for role lookup, not the sender
                // (who may be relaying the op).
                {
                    let state = server_states.get(&server_id).unwrap();
                    let sender_role = state.get_role(&op.author);
                    let sender_perms = sender_role.default_permissions();
                    use crate::crdt::operations::{CrdtPayload, Permission, MemberRole};

                    let allowed = match &op.payload {
                        // Only admins+ can manage channels
                        CrdtPayload::ChannelAdded { .. }
                        | CrdtPayload::ChannelRemoved { .. }
                        | CrdtPayload::ChannelRenamed { .. }
                        | CrdtPayload::ChannelLayoutUpdated { .. } => {
                            (sender_perms & Permission::MANAGE_CHANNELS) != 0
                        }
                        // Only admins+ can change roles
                        CrdtPayload::RoleChanged { peer_id, role, .. } => {
                            state.can_change_role(&peer_str, peer_id, role)
                        }
                        // Only admins+ can change server settings/rename
                        CrdtPayload::ServerRenamed { .. }
                        | CrdtPayload::ServerSettingChanged { .. } => {
                            sender_role == MemberRole::Owner || sender_role == MemberRole::Admin
                        }
                        // Only moderators+ can kick members
                        CrdtPayload::MemberRemoved { peer_id } => {
                            let target_role = state.get_role(peer_id);
                            (sender_perms & Permission::KICK_MEMBERS) != 0
                                && sender_role.outranks(&target_role)
                        }
                        // Members can add other members (via invite), change own nickname,
                        // pin/unpin messages (if they have MANAGE_CHANNELS), create servers
                        CrdtPayload::MemberAdded { .. } => {
                            state.members.contains_key(&peer_str)
                        }
                        CrdtPayload::NicknameChanged { peer_id, .. } => {
                            // Members can only change their own nickname
                            peer_id == &peer_str || sender_role == MemberRole::Owner || sender_role == MemberRole::Admin
                        }
                        CrdtPayload::MessagePinned { .. }
                        | CrdtPayload::MessageUnpinned { .. } => {
                            (sender_perms & Permission::MANAGE_CHANNELS) != 0
                        }
                        CrdtPayload::StoragePledgeChanged { peer_id, .. } => {
                            // Members can change own pledge, admins can change anyone's
                            peer_id == &peer_str || sender_role == MemberRole::Owner || sender_role == MemberRole::Admin
                        }
                        CrdtPayload::ServerCreated { .. } => true,
                    };

                    if !allowed {
                        hollow_log!("[HOLLOW-SECURITY] REJECTED CrdtOpBroadcast from {peer_str} — insufficient permission for {:?} (role: {:?})", op.payload, sender_role);
                        return;
                    }
                }

                let state = server_states.get_mut(&server_id).unwrap();

                let was_len = state.op_log.len();
                let _ = state.apply_op(&op);

                if state.op_log.len() > was_len {
                    // New op — persist and forward to other connected peers
                    if let Ok(json) = serde_json::to_string(&state) {
                        let data_dir = crate::identity::data_dir().unwrap_or_default();
                        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                            let _ = store.save_server_state(&server_id, &json);
                            let _ = store.insert_crdt_op(&op);
                        }
                    }

                    // Forward to other connected server members (simple gossip).
                    let local_peer = swarm.local_peer_id().to_string();
                    for member_peer_str in state.members.keys() {
                        if member_peer_str == &local_peer { continue; }
                        if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                            if pid != peer && connected_peers.contains(&pid) {
                                swarm.behaviour_mut().messaging.send_request(
                                    &pid,
                                    HavenMessage::CrdtOpBroadcast {
                                        server_id: server_id.clone(),
                                        op_json: op_json.clone(),
                                    },
                                );
                            }
                        }
                    }

                    // Emit specific events based on op payload so Dart UI updates correctly.
                    match &op.payload {
                        CrdtPayload::ChannelAdded { channel_id, name, .. } => {
                            let _ = event_tx.send(NetworkEvent::ChannelAdded {
                                server_id: server_id.clone(),
                                channel_id: channel_id.clone(),
                                name: name.clone(),
                            }).await;
                        }
                        CrdtPayload::ChannelRemoved { channel_id } => {
                            let _ = event_tx.send(NetworkEvent::ChannelRemoved {
                                server_id: server_id.clone(),
                                channel_id: channel_id.clone(),
                            }).await;
                        }
                        CrdtPayload::ChannelRenamed { channel_id, new_name } => {
                            let _ = event_tx.send(NetworkEvent::ChannelRenamed {
                                server_id: server_id.clone(),
                                channel_id: channel_id.clone(),
                                new_name: new_name.clone(),
                            }).await;
                        }
                        CrdtPayload::MemberAdded { peer_id, .. } => {
                            let _ = event_tx.send(NetworkEvent::MemberJoined {
                                server_id: server_id.clone(),
                                peer_id: peer_id.clone(),
                            }).await;
                        }
                        CrdtPayload::MemberRemoved { peer_id } => {
                            let _ = event_tx.send(NetworkEvent::MemberLeft {
                                server_id: server_id.clone(),
                                peer_id: peer_id.clone(),
                            }).await;
                        }
                        CrdtPayload::RoleChanged { peer_id, role, .. } => {
                            let _ = event_tx.send(NetworkEvent::RoleChanged {
                                server_id: server_id.clone(),
                                peer_id: peer_id.clone(),
                                new_role: role.as_str().to_string(),
                            }).await;
                        }
                        CrdtPayload::NicknameChanged { peer_id, .. } => {
                            // Re-use MemberJoined to trigger member list refresh in Dart
                            let _ = event_tx.send(NetworkEvent::MemberJoined {
                                server_id: server_id.clone(),
                                peer_id: peer_id.clone(),
                            }).await;
                        }
                        CrdtPayload::MessagePinned { channel_id, message_id } => {
                            let _ = event_tx.send(NetworkEvent::MessagePinned {
                                server_id: server_id.clone(),
                                channel_id: channel_id.clone(),
                                message_id: message_id.clone(),
                            }).await;
                        }
                        CrdtPayload::MessageUnpinned { channel_id, message_id } => {
                            let _ = event_tx.send(NetworkEvent::MessageUnpinned {
                                server_id: server_id.clone(),
                                channel_id: channel_id.clone(),
                                message_id: message_id.clone(),
                            }).await;
                        }
                        _ => {
                            // ServerRenamed, ServerSettingChanged, etc.
                            let _ = event_tx.send(NetworkEvent::ServerUpdated {
                                server_id: server_id.clone(),
                            }).await;
                        }
                    }
                }
            }
        }

        HavenMessage::ServerJoinRequest { server_id } => {
            hollow_log!("[HOLLOW-CRDT] ServerJoinRequest from {peer_str} for server {server_id}");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            if let Some(state) = server_states.get_mut(&server_id) {
                // Check if peer is already a member
                let already_member = state.members_list().iter().any(|m| m.peer_id == peer_str);

                if !already_member {
                    // Add the new member via CRDT op
                    let display_name = format!("{}...{}", &peer_str[..4.min(peer_str.len())], &peer_str[peer_str.len().saturating_sub(4)..]);
                    let op = state.create_op(CrdtPayload::MemberAdded {
                        peer_id: peer_str.clone(),
                        display_name,
                    });
                    let _ = state.apply_op(&op);

                    // Persist
                    if let Ok(json) = serde_json::to_string(&state) {
                        let data_dir = crate::identity::data_dir().unwrap_or_default();
                        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                            let _ = store.save_server_state(&server_id, &json);
                            let _ = store.insert_crdt_op(&op);
                        }
                    }

                    // Broadcast MemberAdded to other peers
                    if let Ok(op_json) = serde_json::to_string(&op) {
                        for &other_peer in connected_peers.iter() {
                            swarm.behaviour_mut().messaging.send_request(
                                &other_peer,
                                HavenMessage::CrdtOpBroadcast {
                                    server_id: server_id.clone(),
                                    op_json: op_json.clone(),
                                },
                            );
                        }
                    }

                    let _ = event_tx.send(NetworkEvent::MemberJoined {
                        server_id: server_id.clone(),
                        peer_id: peer_str.clone(),
                    }).await;

                    // Emit PeerDiscovered so the new member shows as online
                    // in the member panel (they may have connected via mDNS
                    // before being a server member, skipping the normal path).
                    if connected_peers.contains(&peer) {
                        let _ = event_tx.send(NetworkEvent::PeerDiscovered {
                            peer: DiscoveredPeer {
                                peer_id: peer_str.clone(),
                                addresses: vec![],
                            },
                        }).await;
                    }
                }

                // Send full server state to the joiner (all ops so they can reconstruct)
                let all_ops: Vec<&crate::crdt::operations::CrdtOp> = state.op_log.iter().collect();
                if let Ok(ops_json) = serde_json::to_string(&all_ops) {
                    hollow_log!("[HOLLOW-CRDT] Sending {} ops to joiner {peer_str}", all_ops.len());
                    swarm.behaviour_mut().messaging.send_request(
                        &peer,
                        HavenMessage::SyncResponse {
                            server_id,
                            ops_json,
                        },
                    );
                }

                // Proactively establish Olm session with the new member so
                // encrypted channel sync batches can be sent immediately.
                if !olm.has_session(&peer_str) && !key_request_in_flight.contains(&peer_str) {
                    hollow_log!("[HOLLOW-SWARM] No Olm session with new member {peer_str}, sending KeyRequest");
                    let req_id = swarm.behaviour_mut().messaging.send_request(
                        &peer,
                        HavenMessage::KeyRequest,
                    );
                    pending_requests.insert(req_id, peer_str.clone());
                    key_request_in_flight.insert(peer_str.clone());
                }
            } else {
                hollow_log!("[HOLLOW-CRDT] ServerJoinRequest for unknown server {server_id}");
            }
        }

        HavenMessage::ServerDeleteBroadcast { server_id } => {
            hollow_log!("[HOLLOW-CRDT] ServerDeleteBroadcast from {peer_str} for server {server_id}");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            // SECURITY: Verify sender is the server Owner before deleting.
            if let Some(state) = server_states.get(&server_id) {
                let sender_role = state.get_role(&peer_str);
                if sender_role != crate::crdt::operations::MemberRole::Owner {
                    hollow_log!("[HOLLOW-SECURITY] REJECTED ServerDeleteBroadcast from non-owner {peer_str} (role: {:?}) for server {server_id}", sender_role);
                    return;
                }
            } else {
                hollow_log!("[HOLLOW-SECURITY] REJECTED ServerDeleteBroadcast for unknown server {server_id}");
                return;
            }

            if server_states.remove(&server_id).is_some() {
                // Remove from DB.
                let data_dir = crate::identity::data_dir().unwrap_or_default();
                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                    let _ = store.delete_server_state(&server_id);
                }

                // Clean up MLS group.
                if let Some(mls_mgr) = mls {
                    mls_mgr.remove_group(&server_id);
                    persist_mls_state(mls_mgr, bundle_keypair);
                }

                let _ = event_tx.send(NetworkEvent::ServerDeleted {
                    server_id,
                }).await;
            }
        }

        HavenMessage::MemberKickBroadcast { server_id } => {
            hollow_log!("[HOLLOW-CRDT] MemberKickBroadcast from {peer_str} — kicked from server {server_id}");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            // SECURITY: Verify sender has KICK_MEMBERS permission and outranks us.
            if let Some(state) = server_states.get(&server_id) {
                let sender_role = state.get_role(&peer_str);
                let sender_perms = sender_role.default_permissions();
                let local_peer = swarm.local_peer_id().to_string();
                let our_role = state.get_role(&local_peer);
                if (sender_perms & crate::crdt::operations::Permission::KICK_MEMBERS) == 0 {
                    hollow_log!("[HOLLOW-SECURITY] REJECTED MemberKickBroadcast from {peer_str} — no KICK_MEMBERS permission (role: {:?})", sender_role);
                    return;
                }
                if !sender_role.outranks(&our_role) {
                    hollow_log!("[HOLLOW-SECURITY] REJECTED MemberKickBroadcast from {peer_str} — does not outrank us ({:?} vs {:?})", sender_role, our_role);
                    return;
                }
            } else {
                hollow_log!("[HOLLOW-SECURITY] REJECTED MemberKickBroadcast for unknown server {server_id}");
                return;
            }

            // Same cleanup as ServerDeleteBroadcast — remove ourselves from this server.
            if server_states.remove(&server_id).is_some() {
                let data_dir = crate::identity::data_dir().unwrap_or_default();
                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                    let _ = store.delete_server_state(&server_id);
                }

                // Clean up MLS group.
                if let Some(mls_mgr) = mls {
                    mls_mgr.remove_group(&server_id);
                    persist_mls_state(mls_mgr, bundle_keypair);
                }

                let _ = event_tx.send(NetworkEvent::ServerDeleted {
                    server_id,
                }).await;
            }
        }

        HavenMessage::ChannelSyncRequest { server_id, channel_id, since_timestamp, sender_timestamps } => {
            hollow_log!("[HOLLOW-SYNC] ChannelSyncRequest from {peer_str} for {channel_id} in {server_id} since {since_timestamp} (per-sender: {} entries)", sender_timestamps.len());
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            // Room gating: only respond for servers we're a member of.
            if !server_states.contains_key(&server_id) {
                return;
            }

            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                    // Use per-sender sync if available, fall back to legacy single-timestamp.
                    let messages_result = if !sender_timestamps.is_empty() {
                        store.get_channel_messages_since_per_sender(
                            &server_id, &channel_id, &sender_timestamps, 200,
                        )
                    } else {
                        store.get_channel_messages_since(
                            &server_id, &channel_id, since_timestamp, 200,
                        )
                    };
                    if let Ok(messages) = messages_result {
                        hollow_log!("[HOLLOW-SYNC] Sending {} sync messages for {channel_id}", messages.len());
                        // Load reactions for all messages in the batch.
                        let msg_ids: Vec<String> = messages.iter().filter_map(|m| m.message_id.clone()).collect();
                        let reactions_map = store.load_reactions_for_sync(&msg_ids).unwrap_or_default();

                        let items: Vec<SyncMessageItem> = messages.iter().map(|m| {
                            let reactions = m.message_id.as_ref()
                                .and_then(|mid| reactions_map.get(mid))
                                .map(|rs| rs.iter().map(|(e, p, ts, sig, pk)| SyncReactionItem {
                                    e: e.clone(), p: p.clone(), ts: *ts, sig: sig.clone(), pk: pk.clone(),
                                }).collect())
                                .unwrap_or_default();
                            SyncMessageItem {
                                s: m.sender_id.clone(),
                                t: m.text.clone(),
                                ts: m.timestamp,
                                sig: m.signature.clone(),
                                pk: m.public_key.clone(),
                                mid: m.message_id.clone(),
                                edited_at: m.edited_at,
                                reply_to: m.reply_to_mid.clone(),
                                file_id: m.file_id.clone(),
                                reactions,
                            }
                        }).collect();

                        let total = if !sender_timestamps.is_empty() {
                            store.count_channel_messages_since_per_sender(
                                &server_id, &channel_id, &sender_timestamps,
                            ).unwrap_or(items.len() as u32)
                        } else {
                            store.count_channel_messages_since(
                                &server_id, &channel_id, since_timestamp,
                            ).unwrap_or(items.len() as u32)
                        };

                        let has_more = if items.len() >= 200 && total > 200 {
                            Some(true)
                        } else {
                            None
                        };
                        let envelope = MessageEnvelope::ChannelSyncBatch {
                            sid: server_id,
                            cid: channel_id,
                            messages: items,
                            total,
                            has_more,
                        };
                        let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();

                        // Send encrypted (E2EE).
                        let ok = send_encrypted_message(
                            swarm, olm, crypto_store,
                            pending_requests, outbound_message_text,
                            &peer, &peer_str, &envelope_json, event_tx,
                        ).await;

                        if !ok {
                            hollow_log!("[HOLLOW-SYNC] Encryption failed for sync batch to {peer_str}");
                            // Don't queue retry here — the requester will send a new
                            // ChannelSyncRequest after re-key completes. Queuing retries
                            // on the responder side causes an infinite loop:
                            // SessionEstablished → flush → encrypt fail → re-key → SessionEstablished → ...
                        }
                    }
                }
            }
        }

        // -- Multi-peer fan-out sync probe handlers --

        HavenMessage::ChannelSyncProbe { server_id, channel_id, our_latest, msg_count: _probe_count } => {
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            // Room gating: only respond for servers we're a member of.
            if !server_states.contains_key(&server_id) {
                return;
            }

            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                    let their_latest = store
                        .get_latest_channel_timestamp(&server_id, &channel_id)
                        .unwrap_or(None)
                        .unwrap_or(0);
                    let msg_count = store
                        .count_channel_messages(&server_id, &channel_id);

                    hollow_log!(
                        "[HOLLOW-SYNC] Probe from {peer_str} for {channel_id}: ours={their_latest} theirs={our_latest} (count={msg_count})"
                    );

                    swarm.behaviour_mut().messaging.send_request(
                        &peer,
                        HavenMessage::ChannelSyncProbeResponse {
                            server_id,
                            channel_id,
                            their_latest,
                            msg_count,
                        },
                    );
                }
            }
        }

        HavenMessage::ChannelSyncProbeResponse { server_id, channel_id, their_latest, msg_count } => {
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            // Compare: if the peer has newer messages than us, fire a full sync request.
            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                    let our_latest = store
                        .get_latest_channel_timestamp(&server_id, &channel_id)
                        .unwrap_or(None)
                        .unwrap_or(0);
                    let our_msg_count = store.count_channel_messages(&server_id, &channel_id);

                    // Sync if: peer has newer timestamp, OR counts differ (catches mid-session drops).
                    if their_latest > our_latest || msg_count != our_msg_count {
                        // Peer has newer messages or count mismatch — fire full sync request.
                        let sender_ts = store
                            .get_per_sender_timestamps(&server_id, &channel_id)
                            .unwrap_or_default();
                        hollow_log!(
                            "[HOLLOW-SYNC] Probe response: {channel_id} needs sync (ts: ours={our_latest} peer={their_latest}, count: ours={our_msg_count} peer={msg_count}). Requesting from {peer_str}"
                        );
                        swarm.behaviour_mut().messaging.send_request(
                            &peer,
                            HavenMessage::ChannelSyncRequest {
                                server_id: server_id.clone(),
                                channel_id: channel_id.clone(),
                                since_timestamp: our_latest,
                                sender_timestamps: sender_ts,
                            },
                        );
                    } else {
                        hollow_log!(
                            "[HOLLOW-SYNC] Probe response: {channel_id} is up to date (ts: ours={our_latest} peer={their_latest}, count: {our_msg_count}). Skipping."
                        );
                        // Emit completion for this channel so UI knows sync is done.
                        let _ = event_tx.send(NetworkEvent::MessageSyncCompleted {
                            server_id,
                            new_message_count: 0,
                        }).await;
                    }
                }
            }
        }

        HavenMessage::DmSyncRequest { since_timestamp } => {
            hollow_log!("[HOLLOW-SYNC] DmSyncRequest from {peer_str} since {since_timestamp}");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                    if let Ok(messages) = store.get_dm_messages_since(&peer_str, since_timestamp, 200) {
                        hollow_log!("[HOLLOW-SYNC] Sending {} DM sync messages to {peer_str}", messages.len());
                        let msg_ids: Vec<String> = messages.iter().filter_map(|m| m.message_id.clone()).collect();
                        let reactions_map = store.load_reactions_for_sync(&msg_ids).unwrap_or_default();

                        let items: Vec<DmSyncItem> = messages.iter().map(|m| {
                            let reactions = m.message_id.as_ref()
                                .and_then(|mid| reactions_map.get(mid))
                                .map(|rs| rs.iter().map(|(e, p, ts, sig, pk)| SyncReactionItem {
                                    e: e.clone(), p: p.clone(), ts: *ts, sig: sig.clone(), pk: pk.clone(),
                                }).collect())
                                .unwrap_or_default();
                            DmSyncItem {
                                t: m.text.clone(),
                                ts: m.timestamp,
                                mine: m.is_mine,
                                sig: m.signature.clone(),
                                pk: m.public_key.clone(),
                                mid: m.message_id.clone(),
                                edited_at: m.edited_at,
                                reply_to: m.reply_to_mid.clone(),
                                file_id: m.file_id.clone(),
                                reactions,
                            }
                        }).collect();

                        if !items.is_empty() {
                            let has_more = if items.len() >= 200 {
                                Some(true)
                            } else {
                                None
                            };
                            let envelope = MessageEnvelope::DmSyncBatch {
                                messages: items,
                                has_more,
                            };
                            let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();

                            send_encrypted_message(
                                swarm, olm, crypto_store,
                                pending_requests, outbound_message_text,
                                &peer, &peer_str, &envelope_json, event_tx,
                            ).await;
                        }
                    }
                }
            }
        }

        HavenMessage::PeerDisconnecting => {
            hollow_log!("[HOLLOW-SWARM] Peer {peer_str} is disconnecting gracefully");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);
            // Graceful disconnect bypasses debounce — emit immediately.
            // Remove from connected_peers so the subsequent ConnectionClosed + debounce
            // won't emit a second PeerDisconnected.
            connected_peers.remove(&peer);
            pending_disconnects.remove(&peer);
            discovered_peers.remove(&peer);
            disconnected_peers.insert(peer, std::time::Instant::now());
            let _ = event_tx.send(NetworkEvent::PeerDisconnected {
                peer_id: peer_str,
            }).await;
        }

        // -- MLS message handlers --

        HavenMessage::MlsChannelMessage { server_id, body } => {
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            if let Some(mls_mgr) = mls {
                if !mls_mgr.has_group(&server_id) {
                    hollow_log!("[HOLLOW-MLS] Received MlsChannelMessage for unknown group {server_id}");

                    // If we're a member of this server but don't have the MLS group,
                    // the Welcome was lost. Send KeyPackage to the owner to bootstrap.
                    // Only do this once per server to avoid spamming the owner.
                    if !mls_bootstrap_requested.contains(&server_id) {
                        if let Some(state) = server_states.get(&server_id) {
                            let local_peer = swarm.local_peer_id().to_string();
                            for member in state.members_list() {
                                if member.peer_id == local_peer { continue; }
                                let is_owner = state.roles.get(&member.peer_id)
                                    .map(|r| *r.read() == crate::crdt::operations::MemberRole::Owner)
                                    .unwrap_or(false);
                                if is_owner {
                                    if let Ok(owner_pid) = member.peer_id.parse::<PeerId>() {
                                        if connected_peers.contains(&owner_pid) {
                                            hollow_log!("[HOLLOW-MLS] Sending KeyPackage to owner for MLS bootstrap (triggered by message)");
                                            if let Ok(kp_bytes) = mls_mgr.generate_key_package() {
                                                let kp_b64 = base64::engine::general_purpose::STANDARD.encode(&kp_bytes);
                                                swarm.behaviour_mut().messaging.send_request(
                                                    &owner_pid,
                                                    HavenMessage::MlsKeyPackage {
                                                        server_id: server_id.clone(),
                                                        key_package: kp_b64,
                                                    },
                                                );
                                                mls_bootstrap_requested.insert(server_id.clone());
                                            }
                                        }
                                    }
                                    break;
                                }
                            }
                        }
                    }

                    return;
                }

                let ciphertext = match base64::engine::general_purpose::STANDARD.decode(&body) {
                    Ok(ct) => ct,
                    Err(e) => { hollow_log!("[HOLLOW-MLS] Base64 decode failed: {e}"); return; }
                };

                match mls_mgr.decrypt(&server_id, &ciphertext) {
                    Ok((plaintext, sender_peer_id)) => {
                        persist_mls_state(mls_mgr, bundle_keypair);
                        mls_decrypt_failures.remove(&server_id); // Reset failure counter on success.

                        // Parse the plaintext as a MessageEnvelope.
                        let envelope_str = String::from_utf8_lossy(&plaintext);
                        if let Ok(envelope) = serde_json::from_str::<MessageEnvelope>(&envelope_str) {
                            if let MessageEnvelope::ChannelMessage { sid, cid, text, ts, sig, pk, mid, reply_to, file_id } = envelope {
                                // Verify Ed25519 signature.
                                let signing_payload = message_signing_payload(
                                    "ch", &format!("{}:{}", sid, cid),
                                    &sender_peer_id, ts, &text,
                                );
                                verify_message_signature(
                                    &sender_peer_id,
                                    sig.as_deref(),
                                    pk.as_deref(),
                                    &signing_payload,
                                );

                                let local_peer = swarm.local_peer_id().to_string();
                                let is_mine = sender_peer_id == local_peer;

                                // Persist to DB.
                                let data_dir = crate::identity::data_dir().unwrap_or_default();
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let rows = store.insert_channel_message(
                                        &sid, &cid, &sender_peer_id, &text, is_mine, ts,
                                        sig.as_deref(), pk.as_deref(), mid.as_deref(),
                                        reply_to.as_deref(), file_id.as_deref(),
                                    );
                                    let is_new = rows.as_ref().map(|&r| r > 0).unwrap_or(false);
                                    if is_new {
                                        let _ = event_tx.send(NetworkEvent::ChannelMessageReceived {
                                            server_id: sid,
                                            channel_id: cid,
                                            from_peer: sender_peer_id,
                                            text,
                                            timestamp: ts,
                                            message_id: mid.unwrap_or_default(),
                                            reply_to_mid: reply_to.unwrap_or_default(),
                                        }).await;
                                    }
                                }
                            } else if let MessageEnvelope::EditMessage { mid, text: new_text, ts, sig, pk, sid, cid } = envelope {
                                // Handle edit received via MLS.
                                let data_dir = crate::identity::data_dir().unwrap_or_default();
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                let mut edit_applied = false;
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    // Verify sender owns the message.
                                    let sender = store.get_channel_message_sender(&mid);
                                    if sender.as_deref() == Some(&peer_str) {
                                        let _ = store.edit_channel_message(
                                            &mid, &new_text, ts,
                                            sig.as_deref(), pk.as_deref(),
                                        );
                                        edit_applied = true;
                                    } else {
                                        hollow_log!("[HOLLOW-EDIT] MLS rejected: {peer_str} tried to edit message {mid} owned by {sender:?}");
                                    }
                                }
                                if edit_applied {
                                    if let (Some(s_id), Some(c_id)) = (sid, cid) {
                                        let _ = event_tx.send(NetworkEvent::ChannelMessageEdited {
                                            server_id: s_id,
                                            channel_id: c_id,
                                            message_id: mid,
                                            new_text,
                                            edited_at: ts,
                                        }).await;
                                    }
                                }
                            } else if let MessageEnvelope::DeleteMessage { mid, ts, sig, pk, sid, cid } = envelope {
                                // Handle delete received via MLS.
                                let data_dir = crate::identity::data_dir().unwrap_or_default();
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    // SECURITY: Verify sender owns the message before hiding.
                                    let sender = store.get_channel_message_sender(&mid);
                                    if sender.as_deref() != Some(&sender_peer_id) {
                                        hollow_log!("[HOLLOW-SECURITY] REJECTED MLS DeleteMessage from {sender_peer_id} — not the sender of {mid}");
                                        return;
                                    }
                                    let _ = store.hide_channel_message(
                                        &mid, ts,
                                        sig.as_deref(), pk.as_deref(),
                                    );
                                }
                                if let (Some(s_id), Some(c_id)) = (sid, cid) {
                                    let _ = event_tx.send(NetworkEvent::ChannelMessageDeleted {
                                        server_id: s_id,
                                        channel_id: c_id,
                                        message_id: mid,
                                        deleted_at: ts,
                                    }).await;
                                }
                            } else if let MessageEnvelope::AddReaction { mid, emoji, ts, sig, pk, sid, cid } = envelope {
                                // Handle reaction received via MLS.
                                let data_dir = crate::identity::data_dir().unwrap_or_default();
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let _ = store.add_reaction(
                                        &mid, &emoji, &peer_str, ts,
                                        sig.as_deref(), pk.as_deref(),
                                    );
                                }
                                if let (Some(s_id), Some(c_id)) = (sid, cid) {
                                    let _ = event_tx.send(NetworkEvent::ChannelReactionAdded {
                                        server_id: s_id,
                                        channel_id: c_id,
                                        message_id: mid,
                                        emoji,
                                        reactor: peer_str,
                                        added_at: ts,
                                    }).await;
                                }
                            } else if let MessageEnvelope::RemoveReaction { mid, emoji, ts, sig, pk, sid, cid } = envelope {
                                // Handle remove reaction received via MLS.
                                let data_dir = crate::identity::data_dir().unwrap_or_default();
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let _ = store.remove_reaction(
                                        &mid, &emoji, &peer_str, ts,
                                        sig.as_deref(), pk.as_deref(),
                                    );
                                }
                                if let (Some(s_id), Some(c_id)) = (sid, cid) {
                                    let _ = event_tx.send(NetworkEvent::ChannelReactionRemoved {
                                        server_id: s_id,
                                        channel_id: c_id,
                                        message_id: mid,
                                        emoji,
                                        reactor: peer_str,
                                        removed_at: ts,
                                    }).await;
                                }
                            } else if let MessageEnvelope::FileHeader { fid, name, ext, mime, size, chunks, img, w, h, mid, sid, cid, ts, .. } = envelope {
                                // Handle FileHeader received via MLS.
                                use crate::node::file_transfer;
                                hollow_log!("[HOLLOW-FILE] MLS FileHeader: {fid} ({name}, {size} bytes, {chunks} chunks)");

                                // SECURITY: Validate file size against server limit.
                                let max_mb_str = if let Some(state) = server_states.get(&server_id) {
                                    state.settings.get("max_file_size_mb")
                                        .map(|r| r.read().clone())
                                        .unwrap_or_else(|| "34".to_string())
                                } else { "34".to_string() };
                                let max_bytes = max_mb_str.parse::<u64>().unwrap_or(34) * 1024 * 1024;
                                if size > max_bytes {
                                    hollow_log!("[HOLLOW-SECURITY] REJECTED MLS FileHeader from {sender_peer_id} — size {size} exceeds max {max_bytes}");
                                    return;
                                }

                                let ctx_type = "channel";
                                let ctx_id = match (&sid, &cid) {
                                    (Some(s), Some(c)) => format!("{s}:{c}"),
                                    _ => server_id.clone(),
                                };

                                let data_dir = crate::identity::data_dir().unwrap_or_default();
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let _ = store.insert_file_metadata(
                                        &fid, &name, &ext, &mime,
                                        size, chunks, img,
                                        w, h,
                                        mid.as_deref(), ctx_type, &ctx_id,
                                        &sender_peer_id, false, ts,
                                    );
                                }

                                let _ = event_tx.send(NetworkEvent::FileHeaderReceived {
                                    file_id: fid,
                                    file_name: name,
                                    size_bytes: size,
                                    is_image: img,
                                    width: w,
                                    height: h,
                                    message_id: mid.unwrap_or_default(),
                                    sender_id: sender_peer_id.clone(),
                                    server_id: sid.unwrap_or(server_id.clone()),
                                    channel_id: cid.unwrap_or_default(),
                                }).await;

                            } else if let MessageEnvelope::FileChunk { fid, idx, data } = envelope {
                                // Handle FileChunk received via MLS.
                                use crate::node::file_transfer;

                                let chunk_bytes = match base64::engine::general_purpose::STANDARD.decode(&data) {
                                    Ok(b) => b,
                                    Err(e) => {
                                        hollow_log!("[HOLLOW-FILE] MLS chunk decode failed: {e}");
                                        return;
                                    }
                                };

                                if let Err(e) = file_transfer::write_chunk(&fid, idx, &chunk_bytes) {
                                    hollow_log!("[HOLLOW-FILE] {e}");
                                } else {
                                    let data_dir = crate::identity::data_dir().unwrap_or_default();
                                    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                    let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                    let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                    if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                        if let Ok(received) = store.mark_chunk_received(&fid, idx) {
                                            if let Ok(Some(file_meta)) = store.get_file_metadata(&fid) {
                                                let _ = event_tx.send(NetworkEvent::FileProgress {
                                                    file_id: fid.clone(),
                                                    chunks_received: received,
                                                    total_chunks: file_meta.chunk_count,
                                                }).await;

                                                if received >= file_meta.chunk_count {
                                                    let final_path = file_transfer::final_file_path(&fid, &file_meta.file_ext);
                                                    match file_transfer::assemble_file(&fid, file_meta.chunk_count, &final_path) {
                                                        Ok(()) => {
                                                            let disk_path = final_path.to_string_lossy().to_string();
                                                            let _ = store.mark_file_complete(&fid, &disk_path);
                                                            hollow_log!("[HOLLOW-FILE] MLS file {fid} complete: {disk_path}");
                                                            let _ = event_tx.send(NetworkEvent::FileCompleted {
                                                                file_id: fid,
                                                                disk_path,
                                                            }).await;
                                                        }
                                                        Err(e) => {
                                                            hollow_log!("[HOLLOW-FILE] MLS assembly failed: {e}");
                                                            let _ = event_tx.send(NetworkEvent::FileFailed {
                                                                file_id: fid,
                                                                error: e,
                                                            }).await;
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            hollow_log!("[HOLLOW-MLS] Failed to parse decrypted envelope");
                        }
                    }
                    Err(e) => {
                        hollow_log!("[HOLLOW-MLS] Decrypt failed for {server_id}: {e}");

                        // Track consecutive failures — trigger recovery after 3.
                        let count = mls_decrypt_failures.entry(server_id.clone()).or_insert(0);
                        *count += 1;

                        if *count >= 3 && !mls_bootstrap_requested.contains(&server_id) {
                            hollow_log!("[HOLLOW-MLS] {} consecutive decrypt failures — initiating MLS recovery for {server_id}", count);
                            *count = 0;

                            // Drop broken group and request re-bootstrap from owner.
                            mls_mgr.remove_group(&server_id);
                            persist_mls_state(mls_mgr, bundle_keypair);

                            if let Some(state) = server_states.get(&server_id) {
                                let local_peer = swarm.local_peer_id().to_string();
                                for member in state.members_list() {
                                    if member.peer_id == local_peer { continue; }
                                    let is_owner = state.roles.get(&member.peer_id)
                                        .map(|r| *r.read() == crate::crdt::operations::MemberRole::Owner)
                                        .unwrap_or(false);
                                    if is_owner {
                                        if let Ok(owner_pid) = member.peer_id.parse::<PeerId>() {
                                            if connected_peers.contains(&owner_pid) {
                                                if let Ok(kp_bytes) = mls_mgr.generate_key_package() {
                                                    let kp_b64 = base64::engine::general_purpose::STANDARD.encode(&kp_bytes);
                                                    swarm.behaviour_mut().messaging.send_request(
                                                        &owner_pid,
                                                        HavenMessage::MlsKeyPackage {
                                                            server_id: server_id.clone(),
                                                            key_package: kp_b64,
                                                        },
                                                    );
                                                    mls_bootstrap_requested.insert(server_id.clone());
                                                    hollow_log!("[HOLLOW-MLS] Sent recovery KeyPackage to owner for {server_id}");
                                                }
                                            }
                                        }
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        HavenMessage::MlsKeyPackage { server_id, key_package } => {
            hollow_log!("[HOLLOW-MLS] MlsKeyPackage from {peer_str} for server {server_id}");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            // Only the server owner processes KeyPackages (single-committer model).
            let local_peer = swarm.local_peer_id().to_string();
            let is_owner = server_states.get(&server_id)
                .map(|s| {
                    s.roles.get(&local_peer)
                        .map(|r| *r.read() == crate::crdt::operations::MemberRole::Owner)
                        .unwrap_or(false)
                })
                .unwrap_or(false);

            if !is_owner {
                hollow_log!("[HOLLOW-MLS] Not owner of {server_id}, ignoring KeyPackage");
                return;
            }

            if let Some(mls_mgr) = mls {
                // Create MLS group lazily if it doesn't exist (migration for pre-MLS servers).
                if !mls_mgr.has_group(&server_id) {
                    hollow_log!("[HOLLOW-MLS] Lazily creating MLS group for existing server {server_id}");
                    if let Err(e) = mls_mgr.create_group(&server_id) {
                        hollow_log!("[HOLLOW-MLS] Failed to create MLS group: {e}");
                        return;
                    }
                }

                // Duplicate check: skip if peer is already in the MLS group.
                let already_member = mls_mgr.group_members(&server_id).contains(&peer_str);
                if already_member {
                    hollow_log!("[HOLLOW-MLS] Peer {peer_str} already in MLS group for {server_id}, skipping");
                    return;
                }

                let kp_bytes = match base64::engine::general_purpose::STANDARD.decode(&key_package) {
                    Ok(b) => b,
                    Err(e) => { hollow_log!("[HOLLOW-MLS] Base64 decode KeyPackage failed: {e}"); return; }
                };

                // Queue KeyPackage for batch processing (single epoch advance per batch).
                pending_mls_key_packages
                    .entry(server_id.clone())
                    .or_default()
                    .push((peer_str.clone(), kp_bytes));
                hollow_log!("[HOLLOW-MLS] Queued KeyPackage from {peer_str} for batch add to {server_id}");
            }
        }

        HavenMessage::MlsWelcome { server_id, welcome } => {
            hollow_log!("[HOLLOW-MLS] MlsWelcome from {peer_str} for server {server_id}");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            if let Some(mls_mgr) = mls {
                let welcome_bytes = match base64::engine::general_purpose::STANDARD.decode(&welcome) {
                    Ok(b) => b,
                    Err(e) => { hollow_log!("[HOLLOW-MLS] Base64 decode Welcome failed: {e}"); return; }
                };

                match mls_mgr.join_from_welcome(&server_id, &welcome_bytes) {
                    Ok(()) => {
                        persist_mls_state(mls_mgr, bundle_keypair);
                        mls_bootstrap_requested.remove(&server_id);
                        hollow_log!("[HOLLOW-MLS] Joined MLS group for server {server_id}");
                    }
                    Err(e) => {
                        hollow_log!("[HOLLOW-MLS] Failed to join from Welcome for {server_id}: {e}");
                        // Clear bootstrap flag so next MlsChannelMessage can trigger retry.
                        mls_bootstrap_requested.remove(&server_id);
                    }
                }
            }
        }

        HavenMessage::MlsCommit { server_id, commit } => {
            hollow_log!("[HOLLOW-MLS] MlsCommit from {peer_str} for server {server_id}");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            if let Some(mls_mgr) = mls {
                let commit_bytes = match base64::engine::general_purpose::STANDARD.decode(&commit) {
                    Ok(b) => b,
                    Err(e) => { hollow_log!("[HOLLOW-MLS] Base64 decode Commit failed: {e}"); return; }
                };

                match mls_mgr.process_commit(&server_id, &commit_bytes) {
                    Ok(()) => {
                        persist_mls_state(mls_mgr, bundle_keypair);
                        hollow_log!("[HOLLOW-MLS] Processed commit for server {server_id}");
                    }
                    Err(e) => {
                        hollow_log!("[HOLLOW-MLS] Failed to process commit for {server_id}: {e}");

                        // Commit processing failed — MLS group state is stale.
                        // Drop group and request re-bootstrap from owner.
                        if !mls_bootstrap_requested.contains(&server_id) {
                            hollow_log!("[HOLLOW-MLS] Dropping stale MLS group and requesting re-bootstrap for {server_id}");
                            mls_mgr.remove_group(&server_id);
                            persist_mls_state(mls_mgr, bundle_keypair);

                            if let Some(state) = server_states.get(&server_id) {
                                let local_peer = swarm.local_peer_id().to_string();
                                for member in state.members_list() {
                                    if member.peer_id == local_peer { continue; }
                                    let is_owner = state.roles.get(&member.peer_id)
                                        .map(|r| *r.read() == crate::crdt::operations::MemberRole::Owner)
                                        .unwrap_or(false);
                                    if is_owner {
                                        if let Ok(owner_pid) = member.peer_id.parse::<PeerId>() {
                                            if connected_peers.contains(&owner_pid) {
                                                if let Ok(kp_bytes) = mls_mgr.generate_key_package() {
                                                    let kp_b64 = base64::engine::general_purpose::STANDARD.encode(&kp_bytes);
                                                    swarm.behaviour_mut().messaging.send_request(
                                                        &owner_pid,
                                                        HavenMessage::MlsKeyPackage {
                                                            server_id: server_id.clone(),
                                                            key_package: kp_b64,
                                                        },
                                                    );
                                                    mls_bootstrap_requested.insert(server_id.clone());
                                                }
                                            }
                                        }
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        HavenMessage::MlsKeyPackageRequest { server_id } => {
            hollow_log!("[HOLLOW-MLS] MlsKeyPackageRequest from {peer_str} for server {server_id}");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            // Respond with our KeyPackage if we have an MLS identity.
            // Skip if we already have the MLS group (reconnecting peer, not a new joiner).
            if let Some(mls_mgr) = mls {
                if mls_mgr.has_group(&server_id) {
                    hollow_log!("[HOLLOW-MLS] Already in MLS group for {server_id}, ignoring KeyPackageRequest");
                    return;
                }
                match mls_mgr.generate_key_package() {
                    Ok(kp_bytes) => {
                        let kp_b64 = base64::engine::general_purpose::STANDARD.encode(&kp_bytes);
                        swarm.behaviour_mut().messaging.send_request(
                            &peer,
                            HavenMessage::MlsKeyPackage {
                                server_id,
                                key_package: kp_b64,
                            },
                        );
                    }
                    Err(e) => hollow_log!("[HOLLOW-MLS] Failed to generate KeyPackage: {e}"),
                }
            }
        }

        // -- Profile sync (Phase 3.5) --

        HavenMessage::FriendRequest { requested_at } => {
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);
            hollow_log!("[HOLLOW-FRIENDS] Friend request from {peer_str}");

            // Save as pending incoming.
            {
                let data_dir = crate::identity::data_dir().unwrap_or_default();
                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                    let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                    if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                        let _ = store.save_friend(&peer_str, "pending", "incoming", requested_at);
                    }
                }
            }

            // Register DM room code so we can rediscover this peer.
            let local_peer = swarm.local_peer_id().to_string();
            let room = dm_room_code(&local_peer, &peer_str);
            let addrs: Vec<String> = known_addresses.iter()
                .filter(|a| is_registerable_address(a))
                .cloned()
                .collect();
            if !addrs.is_empty() {
                let _ = sig_cmd_tx.send(SignalingCmd::Register {
                    room_code: room.clone(),
                    addresses: addrs,
                }).await;
            }
            let _ = sig_cmd_tx.send(SignalingCmd::SetRoom {
                room_code: room.clone(),
            }).await;
            let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
                room_code: room,
            }).await;

            let _ = event_tx.send(NetworkEvent::FriendRequestReceived {
                peer_id: peer_str,
            }).await;
        }

        HavenMessage::FriendAccept => {
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);
            hollow_log!("[HOLLOW-FRIENDS] Friend accepted by {peer_str}");

            // Update our outgoing request to accepted.
            {
                let data_dir = crate::identity::data_dir().unwrap_or_default();
                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                    let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                    if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                        let now = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as i64;
                        let _ = store.save_friend(&peer_str, "accepted", "", now);
                    }
                }
            }

            // Register DM room code with signaling for internet discovery.
            let local_peer = swarm.local_peer_id().to_string();
            let room = dm_room_code(&local_peer, &peer_str);
            let addrs: Vec<String> = known_addresses.iter()
                .filter(|a| is_registerable_address(a))
                .cloned()
                .collect();
            if !addrs.is_empty() {
                let _ = sig_cmd_tx.send(SignalingCmd::Register {
                    room_code: room.clone(),
                    addresses: addrs,
                }).await;
            }
            let _ = sig_cmd_tx.send(SignalingCmd::SetRoom {
                room_code: room.clone(),
            }).await;
            let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
                room_code: room,
            }).await;

            let _ = event_tx.send(NetworkEvent::FriendRequestAccepted {
                peer_id: peer_str,
            }).await;
        }

        HavenMessage::FriendReject => {
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);
            hollow_log!("[HOLLOW-FRIENDS] Friend rejected by {peer_str}");

            // Remove our outgoing request.
            {
                let data_dir = crate::identity::data_dir().unwrap_or_default();
                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                    let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                    if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                        let _ = store.remove_friend(&peer_str);
                    }
                }
            }

            let _ = event_tx.send(NetworkEvent::FriendRequestRejected {
                peer_id: peer_str,
            }).await;
        }

        HavenMessage::FriendRemove => {
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);
            hollow_log!("[HOLLOW-FRIENDS] Friend removed by {peer_str}");

            {
                let data_dir = crate::identity::data_dir().unwrap_or_default();
                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                    let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                    if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                        let _ = store.remove_friend(&peer_str);
                    }
                }
            }

            let _ = event_tx.send(NetworkEvent::FriendRemoved {
                peer_id: peer_str,
            }).await;
        }

        HavenMessage::TypingIndicator { server_id, channel_id } => {
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            let _ = event_tx.send(NetworkEvent::TypingStarted {
                peer_id: peer_str,
                server_id,
                channel_id,
            }).await;
        }

        HavenMessage::ProfileUpdate { display_name, status, about_me, updated_at, avatar_b64, banner_b64 } => {
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            // SECURITY: Truncate profile fields to prevent oversized strings from malicious peers.
            // Slightly above UI limits (32/48/128) as a safety backstop.
            let display_name = if display_name.len() > 64 { display_name[..64].to_string() } else { display_name };
            let status = if status.len() > 96 { status[..96].to_string() } else { status };
            let about_me = if about_me.len() > 256 { about_me[..256].to_string() } else { about_me };

            // Decode avatar/banner from base64.
            // Empty string = no change (None). "CLEAR" = clear (Some(empty)). Otherwise = base64 data.
            use base64::Engine;
            let avatar_bytes: Option<Vec<u8>> = if avatar_b64.is_empty() {
                None
            } else if avatar_b64 == "CLEAR" {
                Some(vec![]) // empty = clear signal for save_profile
            } else {
                match base64::engine::general_purpose::STANDARD.decode(&avatar_b64) {
                    Ok(bytes) if bytes.len() <= 1_000_000 => Some(bytes), // 1MB for GIF support
                    Ok(_) => { hollow_log!("[HOLLOW-SWARM] Rejecting avatar from {peer_str}: too large"); None }
                    Err(e) => { hollow_log!("[HOLLOW-SWARM] Invalid avatar base64 from {peer_str}: {e}"); None }
                }
            };
            let banner_bytes: Option<Vec<u8>> = if banner_b64.is_empty() {
                None
            } else if banner_b64 == "CLEAR" {
                Some(vec![]) // empty = clear signal for save_profile
            } else {
                match base64::engine::general_purpose::STANDARD.decode(&banner_b64) {
                    Ok(bytes) if bytes.len() <= 2_000_000 => Some(bytes), // 2MB for GIF support
                    Ok(_) => { hollow_log!("[HOLLOW-SWARM] Rejecting banner from {peer_str}: too large"); None }
                    Err(e) => { hollow_log!("[HOLLOW-SWARM] Invalid banner base64 from {peer_str}: {e}"); None }
                }
            };

            hollow_log!("[HOLLOW-SWARM] ProfileUpdate from {peer_str}: name={display_name}");

            // Save to local DB (upsert with timestamp check — only update if newer).
            {
                let data_dir = crate::identity::data_dir().unwrap_or_default();
                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                    let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                    if let Ok(db) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                        if let Err(e) = db.save_profile(
                            &peer_str, &display_name, &status, &about_me, updated_at,
                            avatar_bytes.as_deref(), banner_bytes.as_deref(),
                        ) {
                            hollow_log!("[HOLLOW-SWARM] Failed to save peer profile: {e}");
                        }
                    }
                }
            }

            // Notify Dart to refresh UI.
            let _ = event_tx.send(NetworkEvent::ProfileUpdated {
                peer_id: peer_str,
            }).await;
        }

        // File request — respond with file chunks via Olm.
        HavenMessage::FileRequest { file_id, chunks } => {
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);
            use crate::node::file_transfer;
            hollow_log!("[HOLLOW-FILE] FileRequest from {peer_str} for {file_id}");

            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                    if let Ok(Some(file_meta)) = store.get_file_metadata(&file_id) {
                        if let Some(ref disk_path) = file_meta.disk_path {
                            if let Ok(file_data) = std::fs::read(disk_path) {
                                // AES-encrypt and stream the file.
                                if let Ok(enc) = crate::vault::pipeline::aes_encrypt(&file_data) {
                                    let temp_path = file_transfer::files_dir().join(format!(".stream_send_{file_id}.tmp"));
                                    if let Ok(()) = std::fs::write(&temp_path, &enc.ciphertext) {
                                        // Extract server/channel IDs from context.
                                        let (resp_sid, resp_cid) = if file_meta.context_type == "channel" {
                                            let parts: Vec<&str> = file_meta.context_id.splitn(2, ':').collect();
                                            if parts.len() == 2 {
                                                (Some(parts[0].to_string()), Some(parts[1].to_string()))
                                            } else {
                                                (None, None)
                                            }
                                        } else {
                                            (None, None)
                                        };
                                        let header = MessageEnvelope::FileHeader {
                                            fid: file_id.clone(),
                                            name: file_meta.file_name.clone(),
                                            ext: file_meta.file_ext.clone(),
                                            mime: file_meta.mime_type.clone(),
                                            size: file_meta.size_bytes,
                                            chunks: 0,
                                            img: file_meta.is_image,
                                            w: file_meta.width,
                                            h: file_meta.height,
                                            mid: file_meta.message_id.clone(),
                                            sid: resp_sid,
                                            cid: resp_cid,
                                            ts: file_meta.created_at,
                                            sig: None,
                                            pk: None,
                                            aes_key: Some(hex::encode(enc.key)),
                                            aes_nonce: Some(hex::encode(enc.nonce)),
                                        };
                                        let header_json = serde_json::to_string(&header).unwrap_or_default();
                                        if let Ok(pid) = peer_str.parse::<PeerId>() {
                                            if olm.has_session(&peer_str) {
                                                send_encrypted_message(
                                                    swarm, olm, crypto_store,
                                                    pending_requests, outbound_message_text,
                                                    &pid, &peer_str, &header_json, event_tx,
                                                ).await;

                                                let stream_req = super::stream_transfer::file_stream_request(
                                                    &file_id, temp_path, enc.ciphertext.len() as u64,
                                                );
                                                swarm.behaviour_mut().file_streaming.send_request(
                                                    &pid, stream_req,
                                                );
                                                hollow_log!("[HOLLOW-FILE] Streamed file {} to {peer_str}", file_id);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // KeyBundle and Ack shouldn't arrive as requests, but handle gracefully.
        _ => {
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);
        }
    }
}

/// Handle an incoming response to one of our outbound requests.
async fn handle_incoming_response(
    swarm: &mut libp2p::Swarm<HavenBehaviour>,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    pending_requests: &mut HashMap<request_response::OutboundRequestId, String>,
    outbound_message_text: &mut HashMap<request_response::OutboundRequestId, (String, String)>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    key_request_in_flight: &mut std::collections::HashSet<String>,
    pending_sync_requests: &mut HashMap<String, Vec<(String, String, i64)>>,
    bundle_keypair: &identity::Keypair,
    request_id: request_response::OutboundRequestId,
    response: HavenMessage,
) {
    let Some(to_peer) = pending_requests.remove(&request_id) else {
        return;
    };

    match response {
        HavenMessage::KeyBundle { identity_key, one_time_key } => {
            // We got the peer's key bundle — create outbound session.
            key_request_in_flight.remove(&to_peer);

            // Guard: don't overwrite an existing session (e.g. inbound session
            // from peer's PreKey that arrived while our KeyRequest was in flight).
            if olm.has_session(&to_peer) {
                hollow_log!("[HOLLOW-SWARM] Session already exists for {to_peer}, skipping KeyBundle session creation");
            } else {
                if let Err(e) = olm.create_outbound_session(&to_peer, &identity_key, &one_time_key) {
                    let _ = event_tx
                        .send(NetworkEvent::Error {
                            message: format!("Failed to create outbound session with {to_peer}: {e}"),
                        })
                        .await;
                    return;
                }

                // Persist crypto state.
                persist_crypto_state(olm, crypto_store, &to_peer);

                let _ = event_tx
                    .send(NetworkEvent::SessionEstablished {
                        peer_id: to_peer.clone(),
                    })
                    .await;
            }

            // Always flush pending messages + sync — session is good either way.
            let peer_id: PeerId = match to_peer.parse() {
                Ok(p) => p,
                Err(_) => return,
            };
            if let Some(queued) = pending_messages.remove(&to_peer) {
                for text in queued {
                    send_encrypted_message(
                        swarm, olm, crypto_store, pending_requests,
                        outbound_message_text, &peer_id, &to_peer, &text, event_tx,
                    ).await;
                }
            }

            // Retry any sync batches that failed due to encryption before re-key.
            flush_pending_sync_requests(
                pending_sync_requests, &to_peer, &peer_id,
                swarm, olm, crypto_store,
                pending_requests, outbound_message_text,
                bundle_keypair, event_tx,
            ).await;
        }

        HavenMessage::Ack => {
            // Delivery confirmation for an encrypted message.
            outbound_message_text.remove(&request_id);
            let _ = event_tx
                .send(NetworkEvent::MessageSent { to_peer })
                .await;
        }

        _ => {
            // Unexpected response type — ignore.
        }
    }
}

/// Retry failed sync-batch sends after a session is (re-)established with a peer.
/// Drains all queued (server_id, channel_id, since_timestamp) entries for the peer,
/// re-queries the DB, and re-sends encrypted ChannelSyncBatch responses.
async fn flush_pending_sync_requests(
    pending_sync_requests: &mut HashMap<String, Vec<(String, String, i64)>>,
    peer_str: &str,
    peer: &PeerId,
    swarm: &mut libp2p::Swarm<HavenBehaviour>,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    pending_requests: &mut HashMap<request_response::OutboundRequestId, String>,
    outbound_message_text: &mut HashMap<request_response::OutboundRequestId, (String, String)>,
    bundle_keypair: &identity::Keypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
) {
    let Some(entries) = pending_sync_requests.remove(peer_str) else {
        return;
    };
    if entries.is_empty() {
        return;
    }

    hollow_log!("[HOLLOW-SYNC] Flushing {} pending sync requests for {peer_str}", entries.len());

    let data_dir = crate::identity::data_dir().unwrap_or_default();
    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
    let Ok(proto) = bundle_keypair.to_protobuf_encoding() else { return };
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);
    let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) else { return };

    for (server_id, channel_id, since_timestamp) in entries {
        let _ = event_tx.send(NetworkEvent::MessageSyncStarted {
            server_id: server_id.clone(),
            peer_id: peer_str.to_string(),
        }).await;

        // Re-query per-sender timestamps at flush time (DB may have changed since original request).
        let sender_ts = store.get_per_sender_timestamps(&server_id, &channel_id).unwrap_or_default();
        let messages_result = if !sender_ts.is_empty() {
            store.get_channel_messages_since_per_sender(&server_id, &channel_id, &sender_ts, 200)
        } else {
            store.get_channel_messages_since(&server_id, &channel_id, since_timestamp, 200)
        };
        match messages_result {
            Ok(messages) => {
                hollow_log!("[HOLLOW-SYNC] Retry: sending {} messages for {channel_id} to {peer_str}", messages.len());
                let msg_ids: Vec<String> = messages.iter().filter_map(|m| m.message_id.clone()).collect();
                let reactions_map = store.load_reactions_for_sync(&msg_ids).unwrap_or_default();

                let items: Vec<SyncMessageItem> = messages.iter().map(|m| {
                    let reactions = m.message_id.as_ref()
                        .and_then(|mid| reactions_map.get(mid))
                        .map(|rs| rs.iter().map(|(e, p, ts, sig, pk)| SyncReactionItem {
                            e: e.clone(), p: p.clone(), ts: *ts, sig: sig.clone(), pk: pk.clone(),
                        }).collect())
                        .unwrap_or_default();
                    SyncMessageItem {
                        s: m.sender_id.clone(),
                        t: m.text.clone(),
                        ts: m.timestamp,
                        sig: m.signature.clone(),
                        pk: m.public_key.clone(),
                        mid: m.message_id.clone(),
                        edited_at: m.edited_at,
                        reply_to: m.reply_to_mid.clone(),
                        file_id: m.file_id.clone(),
                        reactions,
                    }
                }).collect();

                let total = if !sender_ts.is_empty() {
                    store.count_channel_messages_since_per_sender(
                        &server_id, &channel_id, &sender_ts,
                    ).unwrap_or(items.len() as u32)
                } else {
                    store.count_channel_messages_since(
                        &server_id, &channel_id, since_timestamp,
                    ).unwrap_or(items.len() as u32)
                };

                let has_more = if items.len() >= 200 && total > 200 {
                    Some(true)
                } else {
                    None
                };
                let envelope = MessageEnvelope::ChannelSyncBatch {
                    sid: server_id.clone(),
                    cid: channel_id,
                    messages: items,
                    total,
                    has_more,
                };
                let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();

                let ok = send_encrypted_message(
                    swarm, olm, crypto_store,
                    pending_requests, outbound_message_text,
                    peer, peer_str, &envelope_json, event_tx,
                ).await;

                if !ok {
                    hollow_log!("[HOLLOW-SYNC] Retry also failed for {server_id} — giving up");
                    let _ = event_tx.send(NetworkEvent::MessageSyncFailed {
                        server_id,
                        error: "Retry after re-key also failed".to_string(),
                    }).await;
                }
            }
            Err(e) => {
                hollow_log!("[HOLLOW-SYNC] DB query failed during retry for {server_id}: {e}");
            }
        }
    }
}

/// Persist both account and session state to DB (fire-and-forget).
fn persist_crypto_state(olm: &OlmManager, crypto_store: &CryptoStore, peer_id: &str) {
    if let Ok(account_json) = olm.account_pickle_json() {
        crypto_store.save_account(account_json);
    }
    if let Ok(Some(session_json)) = olm.session_pickle_json(peer_id) {
        crypto_store.save_session(peer_id.to_string(), session_json);
    }
}
