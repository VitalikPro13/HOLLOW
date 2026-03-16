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
    UpdateProfile { display_name: String, status: String, about_me: String },
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
        /// Number of chunks.
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
            haven_log!("[HAVEN-CRYPTO] Failed to sign message: {e}");
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

    let record_key = kad::RecordKey::new(&format!("/haven/prekeys/{}", peer_id_str));
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
                [("/haven/msg/2.0.0", ProtocolSupport::Full)],
                request_response::Config::default(),
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
                "/haven/1.0.0".to_string(),
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
        haven_log!("[HAVEN] [PROXY] Proxy mode enabled, starting Shadowsocks tunnels...");
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

    // -- CRDT state (Phase 3) --
    // Server states keyed by server_id. Reload from DB so servers survive restarts.
    let mut server_states: HashMap<String, ServerState> = HashMap::new();
    {
        let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                haven_log!("Failed to deserialize server {}: {}", server_id, e);
                            }
                        }
                    }
                    if !server_states.is_empty() {
                        haven_log!("Loaded {} server(s) from DB", server_states.len());
                    }
                }
                Err(e) => {
                    haven_log!("Failed to load servers from DB: {}", e);
                }
            }
        }
    }

    // -- MLS state --
    let local_peer_str = swarm.local_peer_id().to_string();
    let mut mls: Option<MlsManager> = {
        let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                            haven_log!("[HAVEN-MLS] Restored MLS identity from DB");
                            Some(mgr)
                        }
                        Err(e) => {
                            haven_log!("[HAVEN-MLS] Failed to restore MLS identity: {e}");
                            None
                        }
                    }
                }
                Ok(None) => None,
                Err(e) => {
                    haven_log!("[HAVEN-MLS] Failed to load MLS identity: {e}");
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
                haven_log!("[HAVEN-MLS] Created new MLS identity");
                // Persist immediately.
                if let Ok(signer) = mgr.signer_bytes() {
                    if let Ok(cred) = mgr.credential_bytes() {
                        if let Ok(storage) = mgr.serialize_storage() {
                            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                haven_log!("[HAVEN-MLS] Failed to create MLS identity: {e}");
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

    // Multi-peer fan-out sync coordinator.
    // Collects connected peers for 500ms, then assigns channels evenly across peers.
    let mut sync_coordinator = SyncCoordinator::new();

    // Sync coordinator dispatch timer (100ms tick — checks if collection window has elapsed).
    let mut sync_dispatch_timer = tokio::time::interval(Duration::from_millis(100));
    sync_dispatch_timer.tick().await; // consume immediate first tick

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
                        haven_log!("[HAVEN-SWARM] SendMessage received for {peer_id_str} mid={message_id}");

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
                            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                haven_log!("[HAVEN-SWARM] No session for {peer_id_str}, starting DHT prekey fetch");
                                let record_key = kad::RecordKey::new(
                                    &format!("/haven/prekeys/{}", peer_id_str),
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
                        haven_log!("[HAVEN-SWARM] SendChannelMessage for channel {channel_id} in server {server_id} mid={message_id}");

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
                                    haven_log!("[HAVEN-MLS] Encrypt failed, falling back to Olm: {e}");
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
                        let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                        haven_log!("[HAVEN-CRDT] Creating server '{name}' id={server_id}");

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
                            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                let _ = store.save_server_state(&server_id, &json);
                                let _ = store.insert_crdt_op(&op);
                            }
                        }

                        server_states.insert(server_id.clone(), state);

                        // Create MLS group for this server (owner is sole member).
                        if let Some(ref mut mls_mgr) = mls {
                            match mls_mgr.create_group(&server_id) {
                                Ok(()) => persist_mls_state(mls_mgr, &bundle_keypair),
                                Err(e) => haven_log!("[HAVEN-MLS] Failed to create MLS group: {e}"),
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
                                haven_log!("[HAVEN-CRDT] Permission denied: cannot create channel in {server_id}");
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
                            haven_log!("[HAVEN-CRDT] Creating channel '{name}' id={channel_id} in server {server_id}");

                            let op = state.create_op(CrdtPayload::ChannelAdded {
                                channel_id: channel_id.clone(),
                                name: name.clone(),
                                category: category.clone(),
                            });
                            let _ = state.apply_op(&op);

                            // Persist
                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                haven_log!("[HAVEN-CRDT] Permission denied: cannot remove channel in {server_id}");
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: "Permission denied: cannot manage channels".to_string(),
                                }).await;
                                continue;
                            }
                            haven_log!("[HAVEN-CRDT] Removing channel {channel_id} from server {server_id}");

                            let op = state.create_op(CrdtPayload::ChannelRemoved {
                                channel_id: channel_id.clone(),
                            });
                            let _ = state.apply_op(&op);

                            // Persist
                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                haven_log!("[HAVEN-CRDT] Permission denied: cannot rename server {server_id}");
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: "Permission denied: cannot manage server".to_string(),
                                }).await;
                                continue;
                            }
                            haven_log!("[HAVEN-CRDT] Renaming server {server_id} to '{new_name}'");

                            let op = state.create_op(CrdtPayload::ServerRenamed {
                                new_name: new_name.clone(),
                            });
                            let _ = state.apply_op(&op);

                            // Persist
                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                haven_log!("[HAVEN-CRDT] Permission denied: cannot rename channel in {server_id}");
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: "Permission denied: cannot manage channels".to_string(),
                                }).await;
                                continue;
                            }
                            haven_log!("[HAVEN-CRDT] Renaming channel {channel_id} to '{new_name}' in server {server_id}");

                            let op = state.create_op(CrdtPayload::ChannelRenamed {
                                channel_id: channel_id.clone(),
                                new_name: new_name.clone(),
                            });
                            let _ = state.apply_op(&op);

                            // Persist
                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                            haven_log!("[HAVEN-CRDT] Updating setting '{key}'='{value}' in server {server_id}");

                            let op = state.create_op(CrdtPayload::ServerSettingChanged {
                                key: key.clone(),
                                value: value.clone(),
                            });
                            let _ = state.apply_op(&op);

                            // Persist
                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                haven_log!("[HAVEN-CRDT] Permission denied: cannot delete server {server_id}");
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: "Permission denied: only the owner can delete the server".to_string(),
                                }).await;
                                continue;
                            }
                        }

                        haven_log!("[HAVEN-CRDT] Deleting server {server_id}");

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
                        let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                        haven_log!("[HAVEN-CRDT] Joining server {server_id}");
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
                                Err(e) => { haven_log!("[HAVEN-MLS] Failed to generate KeyPackage: {e}"); None }
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
                                haven_log!("[HAVEN-CRDT] Permission denied: cannot change {peer_id} to {new_role} in {server_id}");
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: format!("Permission denied: cannot change role to {new_role}"),
                                }).await;
                                continue;
                            }

                            haven_log!("[HAVEN-CRDT] Changing role of {peer_id} to {new_role} in {server_id}");
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
                                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                haven_log!("[HAVEN-CRDT] Permission denied: cannot kick {peer_id} from {server_id}");
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: "Permission denied: cannot kick this member".to_string(),
                                }).await;
                                continue;
                            }

                            haven_log!("[HAVEN-CRDT] Kicking member {peer_id} from {server_id}");
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
                                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                                    haven_log!("[HAVEN-MLS] Removed {peer_id} from MLS group, epoch rotated");
                                                }
                                                Err(e) => haven_log!("[HAVEN-MLS] Failed to merge remove commit: {e}"),
                                            }
                                        }
                                        Err(e) => haven_log!("[HAVEN-MLS] Failed to remove member from MLS group: {e}"),
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
                                haven_log!("[HAVEN-CRDT] Permission denied: cannot set nickname for {peer_id}");
                                continue;
                            }

                            haven_log!("[HAVEN-CRDT] Setting nickname for {peer_id} to '{nickname}' in {server_id}");
                            let op = state.create_op(CrdtPayload::NicknameChanged {
                                peer_id: peer_id.clone(),
                                nickname: nickname.clone(),
                            });
                            let _ = state.apply_op(&op);

                            // Persist
                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                    NodeCommand::UpdateProfile { display_name, status, about_me } => {
                        let now = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as i64;

                        // Save our own profile to DB.
                        {
                            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                            if let Ok(db) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                if let Err(e) = db.save_profile(&local_peer_str, &display_name, &status, &about_me, now) {
                                    haven_log!("[HAVEN-SWARM] Failed to save own profile: {e}");
                                }
                            }
                        }

                        // Broadcast to all connected peers.
                        let msg = HavenMessage::ProfileUpdate {
                            display_name: display_name.clone(),
                            status: status.clone(),
                            about_me: about_me.clone(),
                            updated_at: now,
                        };
                        haven_log!("[HAVEN-SWARM] Broadcasting profile update to {} peers", connected_peers.len());
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
                        haven_log!("[HAVEN-SWARM] EditChannelMessage {message_id} in {server_id}/{channel_id}");

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
                            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                    haven_log!("[HAVEN-MLS] Edit encrypt failed, falling back to Olm: {e}");
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
                        haven_log!("[HAVEN-SWARM] EditDmMessage {message_id} for {peer_id_str}");

                        let edit_timestamp = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as i64;

                        // Sign the edit.
                        let signing_payload = format!("edit:{}:{}:{}", message_id, new_text, edit_timestamp);
                        let (sig, pk) = sign_message(&bundle_keypair, &pub_key_b64, &signing_payload);

                        // Update local DB.
                        {
                            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                        haven_log!("[HAVEN-SWARM] DeleteChannelMessage {message_id} in {server_id}/{channel_id}");

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
                            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                    haven_log!("[HAVEN-MLS] Delete encrypt failed, falling back to Olm: {e}");
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
                        haven_log!("[HAVEN-SWARM] DeleteDmMessage {message_id} for {peer_id_str}");

                        let delete_timestamp = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as i64;

                        // Sign the deletion.
                        let signing_payload = format!("delete:{}:{}", message_id, delete_timestamp);
                        let (sig, pk) = sign_message(&bundle_keypair, &pub_key_b64, &signing_payload);

                        // Hide in local DB.
                        {
                            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                        haven_log!("[HAVEN-SWARM] AddChannelReaction {emoji} on {message_id} in {server_id}/{channel_id}");

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
                            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                    haven_log!("[HAVEN-MLS] Reaction encrypt failed, falling back to Olm: {e}");
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
                        haven_log!("[HAVEN-SWARM] AddDmReaction {emoji} on {message_id} for {peer_id_str}");

                        let local_peer = swarm.local_peer_id().to_string();
                        let reaction_ts = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as i64;

                        let signing_payload = format!("reaction:{}:{}:{}", message_id, emoji, reaction_ts);
                        let (sig, pk) = sign_message(&bundle_keypair, &pub_key_b64, &signing_payload);

                        // Save to local DB.
                        {
                            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                        haven_log!("[HAVEN-SWARM] RemoveChannelReaction {emoji} on {message_id} in {server_id}/{channel_id}");

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
                            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                    haven_log!("[HAVEN-MLS] Remove reaction encrypt failed, Olm fallback: {e}");
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
                        haven_log!("[HAVEN-SWARM] RemoveDmReaction {emoji} on {message_id} for {peer_id_str}");

                        let local_peer = swarm.local_peer_id().to_string();
                        let remove_ts = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as i64;

                        let signing_payload = format!("unreaction:{}:{}:{}", message_id, emoji, remove_ts);
                        let (sig, pk) = sign_message(&bundle_keypair, &pub_key_b64, &signing_payload);

                        // Remove from local DB.
                        {
                            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                        haven_log!("[HAVEN-FRIENDS] Sending friend request to {peer_id_str}");

                        let now = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as i64;

                        // Save as pending outgoing.
                        {
                            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                        haven_log!("[HAVEN-FRIENDS] Accepting friend request from {peer_id_str}");

                        // Update to accepted.
                        {
                            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                        haven_log!("[HAVEN-FRIENDS] Rejecting friend request from {peer_id_str}");

                        // Remove from friends table.
                        {
                            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                        haven_log!("[HAVEN-FRIENDS] Removing friend {peer_id_str}");

                        {
                            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                haven_log!("[HAVEN-CRDT] Permission denied: cannot update channel layout in {server_id}");
                                continue;
                            }

                            haven_log!("[HAVEN-CRDT] Updating channel layout in {server_id}");
                            let op = state.create_op(CrdtPayload::ChannelLayoutUpdated {
                                layout_json: layout_json.clone(),
                            });
                            let _ = state.apply_op(&op);

                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                haven_log!("[HAVEN-CRDT] Permission denied: cannot pin in {server_id}");
                                continue;
                            }

                            haven_log!("[HAVEN-CRDT] Pinning message {message_id} in {server_id}/{channel_id}");
                            let op = state.create_op(CrdtPayload::MessagePinned {
                                channel_id: channel_id.clone(),
                                message_id: message_id.clone(),
                            });
                            let _ = state.apply_op(&op);

                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                haven_log!("[HAVEN-CRDT] Permission denied: cannot unpin in {server_id}");
                                continue;
                            }

                            haven_log!("[HAVEN-CRDT] Unpinning message {message_id} in {server_id}/{channel_id}");
                            let op = state.create_op(CrdtPayload::MessageUnpinned {
                                channel_id: channel_id.clone(),
                                message_id: message_id.clone(),
                            });
                            let _ = state.apply_op(&op);

                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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

                    // -- File sharing (Phase 3.5) --
                    NodeCommand::SendFile { peer_id, server_id, channel_id, file_path, message_id, message_text } => {
                        use crate::node::file_transfer;
                        use crate::node::image_convert;

                        haven_log!("[HAVEN-FILE] SendFile: {file_path} mid={message_id}");

                        // 1. Read file from disk.
                        let file_data = match std::fs::read(&file_path) {
                            Ok(d) => d,
                            Err(e) => {
                                haven_log!("[HAVEN-FILE] Failed to read file: {e}");
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
                            haven_log!("[HAVEN-FILE] File too large: {} > {}", file_data.len(), max_size);
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
                                    haven_log!("[HAVEN-FILE] Converted to WebP: {}KB -> {}KB ({}x{})",
                                        file_data.len() / 1024, webp_data.len() / 1024, w, h);
                                    (webp_data, "webp".to_string(), Some(w), Some(h))
                                }
                                Err(e) => {
                                    haven_log!("[HAVEN-FILE] WebP conversion failed, sending original: {e}");
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

                        // 5. Generate file ID and chunk.
                        let file_id = file_transfer::generate_file_id();
                        let chunks = file_transfer::chunk_file(&final_data);
                        let total_chunks = chunks.len() as u32;
                        let file_size = final_data.len() as u64;
                        let final_mime = file_transfer::mime_from_ext(&final_ext);

                        haven_log!("[HAVEN-FILE] File {file_id}: {original_name} -> {total_chunks} chunks, {file_size} bytes");

                        // 6. Store file locally.
                        let final_path = file_transfer::final_file_path(&file_id, &final_ext);
                        if let Err(e) = std::fs::write(&final_path, &final_data) {
                            haven_log!("[HAVEN-FILE] Failed to save local file: {e}");
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
                            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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

                                // Send FileHeader.
                                let header = MessageEnvelope::FileHeader {
                                    fid: file_id.clone(),
                                    name: original_name.clone(),
                                    ext: final_ext.clone(),
                                    mime: final_mime.clone(),
                                    size: file_size,
                                    chunks: total_chunks,
                                    img: is_image,
                                    w: width,
                                    h: height,
                                    mid: Some(message_id.clone()),
                                    sid: None,
                                    cid: None,
                                    ts: timestamp,
                                    sig: None,
                                    pk: None,
                                };
                                let header_json = serde_json::to_string(&header).unwrap_or_default();
                                send_encrypted_message(
                                    &mut swarm, &mut olm, &crypto_store,
                                    &mut pending_requests, &mut outbound_message_text,
                                    &target_peer, &peer_str, &header_json, &event_tx,
                                ).await;

                                // Send chunks.
                                for (idx, chunk_data) in chunks.iter().enumerate() {
                                    let chunk_b64 = base64::engine::general_purpose::STANDARD.encode(chunk_data);
                                    let chunk_envelope = MessageEnvelope::FileChunk {
                                        fid: file_id.clone(),
                                        idx: idx as u32,
                                        data: chunk_b64,
                                    };
                                    let chunk_json = serde_json::to_string(&chunk_envelope).unwrap_or_default();
                                    send_encrypted_message(
                                        &mut swarm, &mut olm, &crypto_store,
                                        &mut pending_requests, &mut outbound_message_text,
                                        &target_peer, &peer_str, &chunk_json, &event_tx,
                                    ).await;
                                }
                                } // if connected_peers (file data only)
                            }

                            haven_log!("[HAVEN-FILE] Sent {total_chunks} chunks for {file_id} to DM {peer_str}");

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
                                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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

                            // Send FileHeader + chunks via Olm ONLY to connected peers.
                            // File data is NOT queued for offline peers — they get it via sync.
                            let header = MessageEnvelope::FileHeader {
                                fid: file_id.clone(),
                                name: original_name.clone(),
                                ext: final_ext.clone(),
                                mime: final_mime.clone(),
                                size: file_size,
                                chunks: total_chunks,
                                img: is_image,
                                w: width,
                                h: height,
                                mid: Some(message_id.clone()),
                                sid: Some(sid.clone()),
                                cid: Some(cid.clone()),
                                ts: timestamp,
                                sig: None,
                                pk: None,
                            };
                            let header_json = serde_json::to_string(&header).unwrap_or_default();

                            if let Some(state) = server_states.get(&sid) {
                                for member_peer_str in state.members.keys() {
                                    if member_peer_str == &local_peer { continue; }
                                    if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                        if connected_peers.contains(&pid) && olm.has_session(member_peer_str) {
                                            // Send FileHeader via Olm.
                                            send_encrypted_message(
                                                &mut swarm, &mut olm, &crypto_store,
                                                &mut pending_requests, &mut outbound_message_text,
                                                &pid, member_peer_str, &header_json, &event_tx,
                                            ).await;

                                            // Send chunks via Olm.
                                            for (idx, chunk_data) in chunks.iter().enumerate() {
                                                let chunk_b64 = base64::engine::general_purpose::STANDARD.encode(chunk_data);
                                                let chunk_envelope = MessageEnvelope::FileChunk {
                                                    fid: file_id.clone(),
                                                    idx: idx as u32,
                                                    data: chunk_b64,
                                                };
                                                let chunk_json = serde_json::to_string(&chunk_envelope).unwrap_or_default();
                                                send_encrypted_message(
                                                    &mut swarm, &mut olm, &crypto_store,
                                                    &mut pending_requests, &mut outbound_message_text,
                                                    &pid, member_peer_str, &chunk_json, &event_tx,
                                                ).await;
                                            }
                                        }
                                    }
                                }
                            }

                            haven_log!("[HAVEN-FILE] Sent {total_chunks} chunks for {file_id} to channel {cid}");
                        }
                    }

                    NodeCommand::RequestFile { file_id, peer_id, chunks } => {
                        // Send a FileRequest HavenMessage to the remote peer,
                        // asking them to send us the file data.
                        haven_log!("[HAVEN-FILE] Requesting file {file_id} from peer {peer_id}");
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
                        haven_log!("[HAVEN-SWARM] Notifying {} peers of shutdown", connected_peers.len());
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
                                    let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
                                    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                    if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                            if let Ok(friends) = store.load_friends(None) {
                                                let local_peer = swarm.local_peer_id().to_string();
                                                haven_log!("[HAVEN-FRIENDS] Registering {} friend DM room codes", friends.len());
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
                                        haven_log!("[HAVEN-SWARM] OutboundFailure for {to_peer}, re-queuing message for retry");
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
                                        haven_log!("[HAVEN-SWARM] GetRecord FoundRecord for query {:?}", id);
                                        if let Some(target_peer) = pending_prekey_fetches.remove(&id) {
                                            haven_log!("[HAVEN-SWARM] Found prekey record for {target_peer}");
                                            dht_fetch_in_flight.remove(&target_peer);

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

                                                        match olm.create_outbound_session(
                                                            &target_peer,
                                                            &bundle.identity_key,
                                                            otk,
                                                        ) {
                                                            Ok(()) => {
                                                                persist_crypto_state(&olm, &crypto_store, &target_peer);
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
                                        haven_log!("[HAVEN-SWARM] GetRecord FinishedWithNoAdditionalRecord for query {:?}", id);
                                        if let Some(target_peer) = pending_prekey_fetches.remove(&id) {
                                            haven_log!("[HAVEN-SWARM] No prekey record found for {target_peer}, falling back");
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
                                        haven_log!("[HAVEN-SWARM] GetRecord Error for query {:?}: {e:?}", id);
                                        if let Some(target_peer) = pending_prekey_fetches.remove(&id) {
                                            haven_log!("[HAVEN-SWARM] GetRecord failed for {target_peer}, falling back");
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
                                    haven_log!("[HAVEN-SWARM] Proactive key exchange for {peer_id_str}");
                                    let record_key = kad::RecordKey::new(
                                        &format!("/haven/prekeys/{}", peer_id_str),
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
                                            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                                        haven_log!("[HAVEN-MLS] Requesting KeyPackage from {reconnected_peer_str} for server {sid}");
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
                                    let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                    let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
                                    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                    if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                        if let Ok(db) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                            if let Ok(Some(profile)) = db.load_profile(&local_peer_str) {
                                                if !profile.display_name.is_empty() {
                                                    swarm.behaviour_mut().messaging.send_request(
                                                        &peer_id,
                                                        HavenMessage::ProfileUpdate {
                                                            display_name: profile.display_name,
                                                            status: profile.status,
                                                            about_me: profile.about_me,
                                                            updated_at: profile.updated_at,
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
                                haven_log!("[HAVEN-SWARM] Connection established to {peer_str}, flushing pending messages");
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
                                        &format!("/haven/prekeys/{}", peer_str),
                                    );
                                    let query_id = swarm.behaviour_mut().kademlia
                                        .get_record(record_key);
                                    pending_prekey_fetches.insert(query_id, peer_str.clone());
                                    dht_fetch_in_flight.insert(peer_str.clone());
                                    haven_log!("[HAVEN-SWARM] Starting DHT prekey fetch for {peer_str}");
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
                        haven_log!("[HAVEN-SWARM] Cleared {cleared} cooled-down disconnected peers ({} still cooling)", disconnected_peers.len());
                    }
                }
                if let Some(room) = &active_room {
                    let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
                        room_code: room.clone(),
                    }).await;
                }
                // Also re-bootstrap all server signaling rooms.
                for sid in server_states.keys() {
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
                    haven_log!(
                        "[HAVEN-SYNC] Fan-out dispatch for server {server_id}: {total_channels} channel probes across {total_peers} peers"
                    );

                    for (peer, channels) in assignments {
                        for (channel_id, our_latest) in channels {
                            swarm.behaviour_mut().messaging.send_request(
                                peer,
                                HavenMessage::ChannelSyncProbe {
                                    server_id: server_id.clone(),
                                    channel_id: channel_id.clone(),
                                    our_latest: *our_latest,
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
        }
    }

    // Abort tunnel tasks on shutdown.
    if let Some(handles) = tunnel_handles {
        for h in handles {
            h.abort();
        }
        haven_log!("[HAVEN] [PROXY] Shadowsocks tunnels stopped");
    }
}

/// Persist MLS state (signer + credential + storage) to SQLCipher.
fn persist_mls_state(mls: &MlsManager, keypair: &identity::Keypair) {
    let signer = match mls.signer_bytes() {
        Ok(s) => s,
        Err(e) => { haven_log!("[HAVEN-MLS] Failed to serialize signer: {e}"); return; }
    };
    let cred = match mls.credential_bytes() {
        Ok(c) => c,
        Err(e) => { haven_log!("[HAVEN-MLS] Failed to serialize credential: {e}"); return; }
    };
    let storage = match mls.serialize_storage() {
        Ok(s) => s,
        Err(e) => { haven_log!("[HAVEN-MLS] Failed to serialize storage: {e}"); return; }
    };
    let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                    // We already have a session with this peer. Try to decrypt the
                    // PreKey message using the existing session first. This handles
                    // the race where two encrypted messages arrive as PreKeys
                    // (e.g. sync batch response + regular channel message overlap).
                    // The first creates a new session, the second should decrypt
                    // with it rather than trying (and failing) to create another.
                    match olm.try_decrypt_prekey_with_existing(&peer_str, &ciphertext) {
                        Ok(pt) => {
                            haven_log!("[HAVEN-CRYPTO] Decrypted PreKey with existing session for {peer_str}");
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
                                    haven_log!("[HAVEN-CRYPTO] PreKey session creation also failed for {peer_str}: {e2} — initiating re-key");
                                    // Both paths failed. Initiate a clean re-key.
                                    if !key_request_in_flight.contains(&peer_str) {
                                        key_request_in_flight.insert(peer_str.clone());
                                        let req_id = swarm.behaviour_mut().messaging.send_request(
                                            &peer,
                                            HavenMessage::KeyRequest,
                                        );
                                        pending_requests.insert(req_id, peer_str.clone());
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
                            haven_log!("[HAVEN-CRYPTO] PreKey session creation failed for {peer_str}: {e} — initiating re-key");
                            if !key_request_in_flight.contains(&peer_str) {
                                key_request_in_flight.insert(peer_str.clone());
                                let req_id = swarm.behaviour_mut().messaging.send_request(
                                    &peer,
                                    HavenMessage::KeyRequest,
                                );
                                pending_requests.insert(req_id, peer_str.clone());
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
                        // Stale session — remove it and initiate fresh key exchange.
                        haven_log!("[HAVEN-SWARM] Decrypt failed for {peer_str}: {e} — removing stale session");
                        olm.remove_session(&peer_str);
                        persist_crypto_state(olm, crypto_store, &peer_str);

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
                            haven_log!("[HAVEN-SECURITY] REJECTED ChannelMessage from {peer_str} — not a member of server {sid}");
                            return;
                        }
                    } else {
                        haven_log!("[HAVEN-SECURITY] REJECTED ChannelMessage for unknown server {sid}");
                        return;
                    }

                    // SECURITY: Reject messages with invalid signatures.
                    if sig.is_some() {
                        let payload = message_signing_payload(
                            "ch", &format!("{sid}:{cid}"), &peer_str, ts, &msg_text,
                        );
                        if !verify_message_signature(&peer_str, sig.as_deref(), pk.as_deref(), &payload) {
                            haven_log!("[HAVEN-SECURITY] REJECTED ChannelMessage from {peer_str} — signature verification FAILED");
                            return;
                        }
                    }

                    // SECURITY: Enforce 4,000 character limit on message text.
                    let msg_text = if msg_text.len() > 4000 { msg_text[..4000].to_string() } else { msg_text };

                    // Persist channel message using sender's timestamp.
                    // INSERT OR IGNORE deduplicates via UNIQUE(server_id, channel_id, sender_id, timestamp, text).
                    let mut is_new = true;
                    let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                    haven_log!("[HAVEN-SYNC] Received {} sync messages for {cid} in {sid} (total: {total}, has_more: {has_more:?})", messages.len());
                    let local_peer = swarm.local_peer_id().to_string();
                    let mut new_count = 0u32;
                    let received_count = messages.len() as u32;

                    let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                        haven_log!("[HAVEN-CRYPTO] Signature verification FAILED for synced message from {}", msg.s);
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
                                haven_log!("[HAVEN-SYNC] Requesting next page for {cid} in {sid}");
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
                            haven_log!("[HAVEN-CRYPTO] Signature verification FAILED for DM from {peer_str}");
                        }
                    }

                    // Persist received DM using sender's timestamp (not Dart DateTime.now()).
                    // This ensures DM sync timestamps are consistent for deduplication.
                    let mut is_new = true;
                    {
                        let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                    haven_log!("[HAVEN-SYNC] Received {} DM sync messages from {peer_str} (has_more: {has_more:?})", messages.len());
                    let local_peer = swarm.local_peer_id().to_string();
                    let mut new_count = 0u32;

                    let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                        haven_log!("[HAVEN-CRYPTO] Signature verification FAILED for DM sync message from {peer_str}");
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
                                haven_log!("[HAVEN-SYNC] Requesting next DM page from {peer_str} since {since}");
                                swarm.behaviour_mut().messaging.send_request(
                                    &peer,
                                    HavenMessage::DmSyncRequest {
                                        since_timestamp: since,
                                    },
                                );
                            }
                        }
                    }

                    haven_log!("[HAVEN-SYNC] DM sync: {new_count} new messages from {peer_str}");
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
                    haven_log!("[HAVEN-EDIT] Received edit for message {mid} from {peer_str}");

                    // Persist the edit to local DB (preserves old text).
                    let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                    haven_log!("[HAVEN-EDIT] Rejected: {peer_str} tried to edit message {mid} owned by {sender:?}");
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
                                    haven_log!("[HAVEN-EDIT] Rejected: {peer_str} tried to edit DM {mid} (is_mine={is_mine:?})");
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
                    haven_log!("[HAVEN-DELETE] Received delete for message {mid} from {peer_str}");

                    // Hide the message in local DB (preserves text in message_deletions).
                    let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
                    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                    if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                            if sid.is_some() {
                                // SECURITY: Verify sender owns the message before hiding.
                                let sender = store.get_channel_message_sender(&mid);
                                if sender.as_deref() != Some(&peer_str) {
                                    haven_log!("[HAVEN-SECURITY] REJECTED DeleteMessage from {peer_str} — not the sender of message {mid}");
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
                                    haven_log!("[HAVEN-SECURITY] REJECTED DeleteMessage (DM) from {peer_str} — not the sender of message {mid}");
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
                        haven_log!("[HAVEN-SECURITY] REJECTED AddReaction from {peer_str} — emoji too long ({} chars)", emoji.len());
                        return;
                    }
                    haven_log!("[HAVEN-REACTION] Received reaction {emoji} on {mid} from {peer_str}");

                    let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                    haven_log!("[HAVEN-REACTION] Received remove reaction {emoji} on {mid} from {peer_str}");

                    let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                Ok(MessageEnvelope::FileHeader { fid, name, ext, mime, size, chunks, img, w, h, mid, sid, cid, ts, .. }) => {
                    use crate::node::file_transfer;
                    haven_log!("[HAVEN-FILE] FileHeader received: {fid} ({name}, {size} bytes, {chunks} chunks)");

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
                        haven_log!("[HAVEN-SECURITY] REJECTED FileHeader from {peer_str} — size {size} exceeds max {max_bytes} bytes");
                        return;
                    }

                    let ctx_type = if sid.is_some() { "channel" } else { "dm" };
                    let ctx_id = match (&sid, &cid) {
                        (Some(s), Some(c)) => format!("{s}:{c}"),
                        _ => peer_str.clone(),
                    };

                    // Save file metadata to DB.
                    let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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

                    let _ = event_tx.send(NetworkEvent::FileHeaderReceived {
                        file_id: fid,
                        file_name: name,
                        size_bytes: size,
                        is_image: img,
                        width: w,
                        height: h,
                        message_id: mid.unwrap_or_default(),
                        sender_id: peer_str.clone(),
                        server_id: sid.unwrap_or_default(),
                        channel_id: cid.unwrap_or_else(|| peer_str.clone()),
                    }).await;
                }
                Ok(MessageEnvelope::FileChunk { fid, idx, data }) => {
                    use crate::node::file_transfer;
                    // Decode base64 chunk data.
                    let chunk_bytes = base64::engine::general_purpose::STANDARD.decode(&data);
                    if let Err(e) = &chunk_bytes {
                        haven_log!("[HAVEN-FILE] Failed to decode chunk {idx} for {fid}: {e}");
                    }
                    if let Ok(chunk_bytes) = chunk_bytes {

                    // Write chunk to disk.
                    if let Err(e) = file_transfer::write_chunk(&fid, idx, &chunk_bytes) {
                        haven_log!("[HAVEN-FILE] {e}");
                    } else {

                    // Update DB.
                    let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                                haven_log!("[HAVEN-FILE] File {fid} complete: {disk_path}");
                                                let _ = event_tx.send(NetworkEvent::FileCompleted {
                                                    file_id: fid,
                                                    disk_path,
                                                }).await;
                                            }
                                            Err(e) => {
                                                haven_log!("[HAVEN-FILE] Assembly failed for {fid}: {e}");
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
            haven_log!("[HAVEN-CRDT] SyncRequest from {peer_str} for server {server_id}");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            if let Some(state) = server_states.get(&server_id) {
                // Compute what they're missing
                if let Ok(their_vector) = serde_json::from_str::<StateVector>(&state_vector_json) {
                    let delta = crdt_sync::compute_delta(&state.op_log, &their_vector);
                    if !delta.is_empty() {
                        if let Ok(ops_json) = serde_json::to_string(&delta) {
                            haven_log!("[HAVEN-CRDT] Sending {} delta ops to {peer_str}", delta.len());
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
            haven_log!("[HAVEN-CRDT] SyncResponse from {peer_str} for server {server_id}");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            // Room gating: only accept sync for servers we already know about
            // or are actively trying to join.
            let is_known = server_states.contains_key(&server_id);
            let is_pending_join = pending_server_joins.contains(&server_id);
            if !is_known && !is_pending_join {
                haven_log!("[HAVEN-CRDT] Ignoring SyncResponse for unknown server {server_id} (not joined)");
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
                        haven_log!("[HAVEN-CRDT] Applied {applied} ops for server {server_id}");

                        // Persist
                        if let Ok(json) = serde_json::to_string(&state) {
                            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                            haven_log!("[HAVEN-CRDT] Server join completed: {server_id} ({server_name})");
                            let _ = event_tx.send(NetworkEvent::ServerJoined {
                                server_id: server_id.clone(),
                                name: server_name,
                            }).await;

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
                                                haven_log!("[HAVEN-SWARM] No Olm session with server member {}, sending KeyRequest", member.peer_id);
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
                                    haven_log!("[HAVEN-MLS] No MLS group after join, sending KeyPackage to owner for MLS bootstrap");
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
            haven_log!("[HAVEN-CRDT] CrdtOpBroadcast from {peer_str} for server {server_id}");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            // Room gating: only accept ops for servers we're a member of.
            if !server_states.contains_key(&server_id) {
                haven_log!("[HAVEN-CRDT] Ignoring CrdtOpBroadcast for unknown server {server_id}");
                return;
            }

            if let Ok(op) = serde_json::from_str::<crate::crdt::operations::CrdtOp>(&op_json) {
                // SECURITY: Verify the claimed author matches the actual sender.
                // Without this, a peer could forge ops as any other user (e.g., the owner).
                if op.author != peer_str {
                    haven_log!("[HAVEN-SECURITY] REJECTED CrdtOpBroadcast — author mismatch: claimed '{}' but sender is '{peer_str}'", op.author);
                    return;
                }

                // SECURITY: Verify the sender has permission for this operation type.
                {
                    let state = server_states.get(&server_id).unwrap();
                    let sender_role = state.get_role(&peer_str);
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
                        CrdtPayload::ServerCreated { .. } => true,
                    };

                    if !allowed {
                        haven_log!("[HAVEN-SECURITY] REJECTED CrdtOpBroadcast from {peer_str} — insufficient permission for {:?} (role: {:?})", op.payload, sender_role);
                        return;
                    }
                }

                let state = server_states.get_mut(&server_id).unwrap();

                let was_len = state.op_log.len();
                let _ = state.apply_op(&op);

                if state.op_log.len() > was_len {
                    // New op — persist and forward to other connected peers
                    if let Ok(json) = serde_json::to_string(&state) {
                        let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
            haven_log!("[HAVEN-CRDT] ServerJoinRequest from {peer_str} for server {server_id}");
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
                        let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                    haven_log!("[HAVEN-CRDT] Sending {} ops to joiner {peer_str}", all_ops.len());
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
                    haven_log!("[HAVEN-SWARM] No Olm session with new member {peer_str}, sending KeyRequest");
                    let req_id = swarm.behaviour_mut().messaging.send_request(
                        &peer,
                        HavenMessage::KeyRequest,
                    );
                    pending_requests.insert(req_id, peer_str.clone());
                    key_request_in_flight.insert(peer_str.clone());
                }
            } else {
                haven_log!("[HAVEN-CRDT] ServerJoinRequest for unknown server {server_id}");
            }
        }

        HavenMessage::ServerDeleteBroadcast { server_id } => {
            haven_log!("[HAVEN-CRDT] ServerDeleteBroadcast from {peer_str} for server {server_id}");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            // SECURITY: Verify sender is the server Owner before deleting.
            if let Some(state) = server_states.get(&server_id) {
                let sender_role = state.get_role(&peer_str);
                if sender_role != crate::crdt::operations::MemberRole::Owner {
                    haven_log!("[HAVEN-SECURITY] REJECTED ServerDeleteBroadcast from non-owner {peer_str} (role: {:?}) for server {server_id}", sender_role);
                    return;
                }
            } else {
                haven_log!("[HAVEN-SECURITY] REJECTED ServerDeleteBroadcast for unknown server {server_id}");
                return;
            }

            if server_states.remove(&server_id).is_some() {
                // Remove from DB.
                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
            haven_log!("[HAVEN-CRDT] MemberKickBroadcast from {peer_str} — kicked from server {server_id}");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            // SECURITY: Verify sender has KICK_MEMBERS permission and outranks us.
            if let Some(state) = server_states.get(&server_id) {
                let sender_role = state.get_role(&peer_str);
                let sender_perms = sender_role.default_permissions();
                let local_peer = swarm.local_peer_id().to_string();
                let our_role = state.get_role(&local_peer);
                if (sender_perms & crate::crdt::operations::Permission::KICK_MEMBERS) == 0 {
                    haven_log!("[HAVEN-SECURITY] REJECTED MemberKickBroadcast from {peer_str} — no KICK_MEMBERS permission (role: {:?})", sender_role);
                    return;
                }
                if !sender_role.outranks(&our_role) {
                    haven_log!("[HAVEN-SECURITY] REJECTED MemberKickBroadcast from {peer_str} — does not outrank us ({:?} vs {:?})", sender_role, our_role);
                    return;
                }
            } else {
                haven_log!("[HAVEN-SECURITY] REJECTED MemberKickBroadcast for unknown server {server_id}");
                return;
            }

            // Same cleanup as ServerDeleteBroadcast — remove ourselves from this server.
            if server_states.remove(&server_id).is_some() {
                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
            haven_log!("[HAVEN-SYNC] ChannelSyncRequest from {peer_str} for {channel_id} in {server_id} since {since_timestamp} (per-sender: {} entries)", sender_timestamps.len());
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            // Room gating: only respond for servers we're a member of.
            if !server_states.contains_key(&server_id) {
                return;
            }

            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                        haven_log!("[HAVEN-SYNC] Sending {} sync messages for {channel_id}", messages.len());
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
                            haven_log!("[HAVEN-SYNC] Encryption failed for sync batch to {peer_str}");
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

        HavenMessage::ChannelSyncProbe { server_id, channel_id, our_latest } => {
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            // Room gating: only respond for servers we're a member of.
            if !server_states.contains_key(&server_id) {
                return;
            }

            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                    let their_latest = store
                        .get_latest_channel_timestamp(&server_id, &channel_id)
                        .unwrap_or(None)
                        .unwrap_or(0);
                    let msg_count = store
                        .count_channel_messages_since(&server_id, &channel_id, 0)
                        .unwrap_or(0);

                    haven_log!(
                        "[HAVEN-SYNC] Probe from {peer_str} for {channel_id}: ours={their_latest} theirs={our_latest} (count={msg_count})"
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
            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                    let our_latest = store
                        .get_latest_channel_timestamp(&server_id, &channel_id)
                        .unwrap_or(None)
                        .unwrap_or(0);

                    if their_latest > our_latest || (msg_count > 0 && our_latest == 0) {
                        // Peer has newer messages — fire full sync request.
                        let sender_ts = store
                            .get_per_sender_timestamps(&server_id, &channel_id)
                            .unwrap_or_default();
                        haven_log!(
                            "[HAVEN-SYNC] Probe response: {channel_id} needs sync (ours={our_latest} peer={their_latest}, peer_count={msg_count}). Requesting from {peer_str}"
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
                        haven_log!(
                            "[HAVEN-SYNC] Probe response: {channel_id} is up to date (ours={our_latest} peer={their_latest}). Skipping."
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
            haven_log!("[HAVEN-SYNC] DmSyncRequest from {peer_str} since {since_timestamp}");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                    if let Ok(messages) = store.get_dm_messages_since(&peer_str, since_timestamp, 200) {
                        haven_log!("[HAVEN-SYNC] Sending {} DM sync messages to {peer_str}", messages.len());
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
            haven_log!("[HAVEN-SWARM] Peer {peer_str} is disconnecting gracefully");
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
                    haven_log!("[HAVEN-MLS] Received MlsChannelMessage for unknown group {server_id}");

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
                                            haven_log!("[HAVEN-MLS] Sending KeyPackage to owner for MLS bootstrap (triggered by message)");
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
                    Err(e) => { haven_log!("[HAVEN-MLS] Base64 decode failed: {e}"); return; }
                };

                match mls_mgr.decrypt(&server_id, &ciphertext) {
                    Ok((plaintext, sender_peer_id)) => {
                        persist_mls_state(mls_mgr, bundle_keypair);

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
                                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                        haven_log!("[HAVEN-EDIT] MLS rejected: {peer_str} tried to edit message {mid} owned by {sender:?}");
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
                                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    // SECURITY: Verify sender owns the message before hiding.
                                    let sender = store.get_channel_message_sender(&mid);
                                    if sender.as_deref() != Some(&sender_peer_id) {
                                        haven_log!("[HAVEN-SECURITY] REJECTED MLS DeleteMessage from {sender_peer_id} — not the sender of {mid}");
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
                                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                haven_log!("[HAVEN-FILE] MLS FileHeader: {fid} ({name}, {size} bytes, {chunks} chunks)");

                                // SECURITY: Validate file size against server limit.
                                let max_mb_str = if let Some(state) = server_states.get(&server_id) {
                                    state.settings.get("max_file_size_mb")
                                        .map(|r| r.read().clone())
                                        .unwrap_or_else(|| "34".to_string())
                                } else { "34".to_string() };
                                let max_bytes = max_mb_str.parse::<u64>().unwrap_or(34) * 1024 * 1024;
                                if size > max_bytes {
                                    haven_log!("[HAVEN-SECURITY] REJECTED MLS FileHeader from {sender_peer_id} — size {size} exceeds max {max_bytes}");
                                    return;
                                }

                                let ctx_type = "channel";
                                let ctx_id = match (&sid, &cid) {
                                    (Some(s), Some(c)) => format!("{s}:{c}"),
                                    _ => server_id.clone(),
                                };

                                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                        haven_log!("[HAVEN-FILE] MLS chunk decode failed: {e}");
                                        return;
                                    }
                                };

                                if let Err(e) = file_transfer::write_chunk(&fid, idx, &chunk_bytes) {
                                    haven_log!("[HAVEN-FILE] {e}");
                                } else {
                                    let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                                                            haven_log!("[HAVEN-FILE] MLS file {fid} complete: {disk_path}");
                                                            let _ = event_tx.send(NetworkEvent::FileCompleted {
                                                                file_id: fid,
                                                                disk_path,
                                                            }).await;
                                                        }
                                                        Err(e) => {
                                                            haven_log!("[HAVEN-FILE] MLS assembly failed: {e}");
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
                            haven_log!("[HAVEN-MLS] Failed to parse decrypted envelope");
                        }
                    }
                    Err(e) => haven_log!("[HAVEN-MLS] Decrypt failed: {e}"),
                }
            }
        }

        HavenMessage::MlsKeyPackage { server_id, key_package } => {
            haven_log!("[HAVEN-MLS] MlsKeyPackage from {peer_str} for server {server_id}");
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
                haven_log!("[HAVEN-MLS] Not owner of {server_id}, ignoring KeyPackage");
                return;
            }

            if let Some(mls_mgr) = mls {
                // Create MLS group lazily if it doesn't exist (migration for pre-MLS servers).
                if !mls_mgr.has_group(&server_id) {
                    haven_log!("[HAVEN-MLS] Lazily creating MLS group for existing server {server_id}");
                    if let Err(e) = mls_mgr.create_group(&server_id) {
                        haven_log!("[HAVEN-MLS] Failed to create MLS group: {e}");
                        return;
                    }
                }

                let kp_bytes = match base64::engine::general_purpose::STANDARD.decode(&key_package) {
                    Ok(b) => b,
                    Err(e) => { haven_log!("[HAVEN-MLS] Base64 decode KeyPackage failed: {e}"); return; }
                };

                match mls_mgr.add_member(&server_id, &kp_bytes) {
                    Ok((commit_bytes, welcome_bytes)) => {
                        if let Err(e) = mls_mgr.merge_pending_commit(&server_id) {
                            haven_log!("[HAVEN-MLS] Failed to merge add commit: {e}");
                            return;
                        }
                        persist_mls_state(mls_mgr, bundle_keypair);

                        // Send Welcome to the joiner.
                        let welcome_b64 = base64::engine::general_purpose::STANDARD.encode(&welcome_bytes);
                        swarm.behaviour_mut().messaging.send_request(
                            &peer,
                            HavenMessage::MlsWelcome {
                                server_id: server_id.clone(),
                                welcome: welcome_b64,
                            },
                        );

                        // Broadcast Commit to all other MLS group members.
                        let commit_b64 = base64::engine::general_purpose::STANDARD.encode(&commit_bytes);
                        if let Some(state) = server_states.get(&server_id) {
                            let local_peer = swarm.local_peer_id().to_string();
                            for member_peer_str in state.members.keys() {
                                if member_peer_str == &local_peer || member_peer_str == &peer_str { continue; }
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

                        haven_log!("[HAVEN-MLS] Added {peer_str} to MLS group for server {server_id}");
                    }
                    Err(e) => haven_log!("[HAVEN-MLS] Failed to add member: {e}"),
                }
            }
        }

        HavenMessage::MlsWelcome { server_id, welcome } => {
            haven_log!("[HAVEN-MLS] MlsWelcome from {peer_str} for server {server_id}");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            if let Some(mls_mgr) = mls {
                let welcome_bytes = match base64::engine::general_purpose::STANDARD.decode(&welcome) {
                    Ok(b) => b,
                    Err(e) => { haven_log!("[HAVEN-MLS] Base64 decode Welcome failed: {e}"); return; }
                };

                match mls_mgr.join_from_welcome(&server_id, &welcome_bytes) {
                    Ok(()) => {
                        persist_mls_state(mls_mgr, bundle_keypair);
                        mls_bootstrap_requested.remove(&server_id);
                        haven_log!("[HAVEN-MLS] Joined MLS group for server {server_id}");
                    }
                    Err(e) => haven_log!("[HAVEN-MLS] Failed to join from Welcome: {e}"),
                }
            }
        }

        HavenMessage::MlsCommit { server_id, commit } => {
            haven_log!("[HAVEN-MLS] MlsCommit from {peer_str} for server {server_id}");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            if let Some(mls_mgr) = mls {
                let commit_bytes = match base64::engine::general_purpose::STANDARD.decode(&commit) {
                    Ok(b) => b,
                    Err(e) => { haven_log!("[HAVEN-MLS] Base64 decode Commit failed: {e}"); return; }
                };

                match mls_mgr.process_commit(&server_id, &commit_bytes) {
                    Ok(()) => {
                        persist_mls_state(mls_mgr, bundle_keypair);
                        haven_log!("[HAVEN-MLS] Processed commit for server {server_id}");
                    }
                    Err(e) => haven_log!("[HAVEN-MLS] Failed to process commit: {e}"),
                }
            }
        }

        HavenMessage::MlsKeyPackageRequest { server_id } => {
            haven_log!("[HAVEN-MLS] MlsKeyPackageRequest from {peer_str} for server {server_id}");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            // Respond with our KeyPackage if we have an MLS identity.
            if let Some(mls_mgr) = mls {
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
                    Err(e) => haven_log!("[HAVEN-MLS] Failed to generate KeyPackage: {e}"),
                }
            }
        }

        // -- Profile sync (Phase 3.5) --

        HavenMessage::FriendRequest { requested_at } => {
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);
            haven_log!("[HAVEN-FRIENDS] Friend request from {peer_str}");

            // Save as pending incoming.
            {
                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
            haven_log!("[HAVEN-FRIENDS] Friend accepted by {peer_str}");

            // Update our outgoing request to accepted.
            {
                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
            haven_log!("[HAVEN-FRIENDS] Friend rejected by {peer_str}");

            // Remove our outgoing request.
            {
                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
            haven_log!("[HAVEN-FRIENDS] Friend removed by {peer_str}");

            {
                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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

        HavenMessage::ProfileUpdate { display_name, status, about_me, updated_at } => {
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            // SECURITY: Truncate profile fields to prevent oversized strings from malicious peers.
            // Slightly above UI limits (32/48/128) as a safety backstop.
            let display_name = if display_name.len() > 64 { display_name[..64].to_string() } else { display_name };
            let status = if status.len() > 96 { status[..96].to_string() } else { status };
            let about_me = if about_me.len() > 256 { about_me[..256].to_string() } else { about_me };

            haven_log!("[HAVEN-SWARM] ProfileUpdate from {peer_str}: name={display_name}");

            // Save to local DB (upsert with timestamp check — only update if newer).
            {
                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                    let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                    if let Ok(db) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                        if let Err(e) = db.save_profile(&peer_str, &display_name, &status, &about_me, updated_at) {
                            haven_log!("[HAVEN-SWARM] Failed to save peer profile: {e}");
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
            haven_log!("[HAVEN-FILE] FileRequest from {peer_str} for {file_id}");

            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                    if let Ok(Some(file_meta)) = store.get_file_metadata(&file_id) {
                        if let Some(ref disk_path) = file_meta.disk_path {
                            if let Ok(file_data) = std::fs::read(disk_path) {
                                // Send FileHeader first.
                                let header = MessageEnvelope::FileHeader {
                                    fid: file_id.clone(),
                                    name: file_meta.file_name.clone(),
                                    ext: file_meta.file_ext.clone(),
                                    mime: file_meta.mime_type.clone(),
                                    size: file_meta.size_bytes,
                                    chunks: file_meta.chunk_count,
                                    img: file_meta.is_image,
                                    w: file_meta.width,
                                    h: file_meta.height,
                                    mid: file_meta.message_id.clone(),
                                    sid: None,
                                    cid: None,
                                    ts: file_meta.created_at,
                                    sig: None,
                                    pk: None,
                                };
                                let header_json = serde_json::to_string(&header).unwrap_or_default();
                                if let Ok(pid) = peer_str.parse::<PeerId>() {
                                    if olm.has_session(&peer_str) {
                                        send_encrypted_message(
                                            swarm, olm, crypto_store,
                                            pending_requests, outbound_message_text,
                                            &pid, &peer_str, &header_json, event_tx,
                                        ).await;

                                        // Send requested chunks (or all if empty).
                                        let all_chunks = file_transfer::chunk_file(&file_data);
                                        let indices: Vec<u32> = if chunks.is_empty() {
                                            (0..all_chunks.len() as u32).collect()
                                        } else {
                                            chunks
                                        };
                                        for idx in indices {
                                            if let Some(chunk_data) = all_chunks.get(idx as usize) {
                                                let chunk_b64 = base64::engine::general_purpose::STANDARD.encode(chunk_data);
                                                let chunk_envelope = MessageEnvelope::FileChunk {
                                                    fid: file_id.clone(),
                                                    idx,
                                                    data: chunk_b64,
                                                };
                                                let chunk_json = serde_json::to_string(&chunk_envelope).unwrap_or_default();
                                                send_encrypted_message(
                                                    swarm, olm, crypto_store,
                                                    pending_requests, outbound_message_text,
                                                    &pid, &peer_str, &chunk_json, event_tx,
                                                ).await;
                                            }
                                        }
                                        haven_log!("[HAVEN-FILE] Sent file {} to {peer_str}", file_id);
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

            // Flush all pending messages for this peer.
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

    haven_log!("[HAVEN-SYNC] Flushing {} pending sync requests for {peer_str}", entries.len());

    let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
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
                haven_log!("[HAVEN-SYNC] Retry: sending {} messages for {channel_id} to {peer_str}", messages.len());
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
                    haven_log!("[HAVEN-SYNC] Retry also failed for {server_id} — giving up");
                    let _ = event_tx.send(NetworkEvent::MessageSyncFailed {
                        server_id,
                        error: "Retry after re-key also failed".to_string(),
                    }).await;
                }
            }
            Err(e) => {
                haven_log!("[HAVEN-SYNC] DB query failed during retry for {server_id}: {e}");
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
