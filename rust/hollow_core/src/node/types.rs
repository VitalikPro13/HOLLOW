use std::collections::{HashMap, HashSet};
use std::time::Instant;

use serde::{Deserialize, Serialize};

// -- Security constants (Phase 6.25) --

/// Maximum SDP payload size (64 KB). Realistic SDP is ~2-10 KB.
pub(crate) const MAX_SDP_SIZE: usize = 64 * 1024;

/// Maximum peers in a single PeerExchange gossip message.
pub(crate) const MAX_PEER_EXCHANGE_SIZE: usize = 50;

/// Maximum allowed TTL on incoming BroadcastMeta gossip messages.
pub(crate) const MAX_BROADCAST_TTL: u8 = 8;

/// Default broadcast TTL for serde deserialization (backward compat with old peers).
pub(crate) fn default_broadcast_ttl() -> u8 { super::gossip::DEFAULT_BROADCAST_TTL }

/// VC signaling sub-rate-limiter: burst capacity (per peer).
pub(crate) const VC_SIGNAL_RATE_BURST: u32 = 30;
/// VC signaling sub-rate-limiter: refill rate (tokens per second per peer).
pub(crate) const VC_SIGNAL_RATE_REFILL: u32 = 10;

/// Compute a deterministic DM room code for two peers.
/// Both peers compute the same code so signaling can match them.
/// Uses SHA-256 truncated to 32 hex chars for collision resistance.
pub(crate) fn dm_room_code(peer_a: &str, peer_b: &str) -> String {
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
    MessageReceived { from_peer: String, text: String, timestamp: i64, message_id: String, reply_to_mid: String, link_preview: Option<LinkPreviewRef>, signature: Option<String>, public_key: Option<String> },
    ChannelMessageReceived { server_id: String, channel_id: String, from_peer: String, text: String, timestamp: i64, message_id: String, reply_to_mid: String, link_preview: Option<LinkPreviewRef>, signature: Option<String>, public_key: Option<String> },
    MessageSent { to_peer: String, message_id: String, timestamp: i64, signature: Option<String>, public_key: Option<String> },
    ChannelMessageSent { server_id: String, channel_id: String, message_id: String, timestamp: i64, signature: Option<String>, public_key: Option<String> },
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
    ChannelMessageEdited { server_id: String, channel_id: String, message_id: String, new_text: String, edited_at: i64, signature: Option<String>, public_key: Option<String> },
    DmMessageEdited { peer_id: String, message_id: String, new_text: String, edited_at: i64, signature: Option<String>, public_key: Option<String> },
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
    ChannelNotificationHint {
        server_id: String, channel_id: String, from_peer: String,
        has_everyone: bool, mentioned_names: Vec<String>, is_reply: bool,
    },
    // -- Typing indicator events (Phase 3.5) --
    TypingStarted { peer_id: String, server_id: String, channel_id: String },
    // -- Presence events (Phase 6.75) --
    PeerStatusChanged { peer_id: String, status: String },
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
        /// Video thumbnail back-reference (Phase 6.75 video preview).
        /// Present when the received FileHeader is a thumbnail for a vault video.
        video_thumb: Option<VideoThumbRef>,
        /// Hidden Share back-reference for large files / progressive video streaming.
        share_ref: Option<ShareRef>,
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
    /// `chunk_index` is only meaningful when kind == "share_chunk"; otherwise 0.
    WebRtcSendFile { peer_id: String, transfer_id: String, file_path: String, total_size: u64, kind: String, shard_index: u16, chunk_index: u32 },
    // -- Voice call events (Phase 5B) --
    /// Forward incoming voice call signaling message to Dart.
    CallSignal { peer_id: String, signal_type: String, payload: String },
    // -- Voice channel events (Phase 5C) --
    VoiceChannelJoined { server_id: String, channel_id: String, peer_id: String },
    VoiceChannelLeft { server_id: String, channel_id: String, peer_id: String },
    VoiceChannelSignal { server_id: String, channel_id: String, peer_id: String, signal_type: String, payload: String },
    // -- Gossip relay tree events (Phase 5D) --
    /// Tell Dart to establish a WebRTC data channel to this peer (gossip neighbor).
    GossipConnect { peer_id: String },
    /// Tell Dart to close the WebRTC data channel to this peer.
    GossipDisconnect { peer_id: String },
    /// Tell Dart to relay a file broadcast to gossip neighbors.
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
    /// Voice channel mode changed (mesh <-> gossip).
    VoiceChannelModeChanged {
        server_id: String,
        channel_id: String,
        mode: String,
        gossip_neighbors: Vec<String>,
    },
    /// MLS epoch changed — SFrame key needs rotation.
    MlsEpochChanged {
        server_id: String,
        epoch: u64,
        sframe_key: Vec<u8>,
    },
    // -- Recovery pool events (Evidence Recovery) --
    RecoveryPoolCreated { server_id: String, invite_link: String },
    RecoveryPoolJoined { server_id: String },
    RecoveryPoolJoinFailed { server_id: String, reason: String },
    RecoveryPoolMemberJoined { server_id: String, peer_id: String },
    RecoveryPoolMemberLeft { server_id: String, peer_id: String },
    RecoveryPoolStatus { server_id: String, total_files: u32, reconstructable: u32, partial: u32, no_shards: u32, progress_pct: f32 },
    RecoveryPoolShardTransferred { server_id: String, content_id: String, shard_index: u16 },
    RecoveryPoolFileRecovered { server_id: String, content_id: String, disk_path: String },
    RecoveryPoolStopped { server_id: String },
    // -- Hollow Share (Phase 7A) --
    /// Manifest for a share has been fetched and verified; download can be started.
    ShareManifestReady { root_hash: String, file_name: String, total_size: u64, chunk_count: u32 },
    /// Periodic progress update for an active share download or seed.
    ShareProgress { root_hash: String, chunks_have: u32, chunks_total: u32, seeders: u8, leechers: u8, bytes_per_sec: u64 },
    /// Download finished, file written to disk_path.
    ShareCompleted { root_hash: String, disk_path: String },
    /// Download/seed encountered a fatal error; swarm state has been dropped.
    ShareFailed { root_hash: String, error: String },
    /// Seeding flag toggled (manually or by completion auto-seed).
    ShareSeedingChanged { root_hash: String, seeding: bool, seeders: u8, leechers: u8, bytes_uploaded: u64 },
    /// share_create_from_file finished; link is ready to share.
    ShareCreated { root_hash: String, link: String, file_name: String, total_size: u64 },
    /// Hidden share created for large file / video streaming. Contains root_hash + key
    /// needed to build a ShareRef for the FileHeader.
    ShareCreatedHidden { root_hash: String, key_hex: String, file_name: String, total_size: u64 },
    /// Result of share_list (returned via stream so it stays uniform with other queries).
    ShareList { entries: Vec<ShareEntryRef> },
    /// A share peer needs a WebRTC connection — Dart should call ensureConnection.
    /// `hidden` indicates this is a hidden share (use TURN-enabled ICE config).
    ShareNeedWebRtc { peer_id: String, hidden: bool },
    // -- License key events --
    LicenseError { reason: String },
    // -- Twitch verification events --
    TwitchJoinRejected { server_id: String, reason: String },
    // -- Room budget events --
    RoomBudgetUpdate { joined: u32, limit: u32 },
    RoomCapHit { room: String },
}

/// Lightweight ShareEntry for streaming lists to Dart. The persisted row is wider
/// (manifest_json, encryption_key blob, etc.) — Dart only needs what it renders.
#[derive(Clone)]
pub(crate) struct ShareEntryRef {
    pub root_hash: String,
    pub file_name: String,
    pub total_size: u64,
    pub chunks_have: u32,
    pub chunks_total: u32,
    pub state: String,           // "downloading" | "completed" | "paused" | "failed"
    pub seeding: bool,
    pub disk_path: Option<String>,
    pub bytes_uploaded: u64,
    pub share_link: String,
    pub created_at: i64,
    pub server_id: Option<String>,
    pub context_type: Option<String>,
}

/// Commands the FFI layer can send into the swarm event loop.
pub(crate) enum NodeCommand {
    SendMessage { peer_id: String, text: String, message_id: String, reply_to_mid: Option<String>, link_preview: Option<LinkPreviewRef> },
    SendChannelMessage { server_id: String, channel_id: String, text: String, message_id: String, reply_to_mid: Option<String>, link_preview: Option<LinkPreviewRef> },
    JoinRoom { room_code: String },
    // -- CRDT commands (Phase 3) --
    CreateServer { name: String },
    CreateChannel { server_id: String, name: String, category: Option<String>, channel_type: String },
    RemoveChannel { server_id: String, channel_id: String },
    RenameServer { server_id: String, new_name: String },
    RenameChannel { server_id: String, channel_id: String, new_name: String },
    UpdateServerSetting { server_id: String, key: String, value: String },
    DeleteServer { server_id: String },
    JoinServer { server_id: String, twitch_proof_json: Option<String> },
    RequestChannelSync { server_id: String, channel_id: String },
    ChangeRole { server_id: String, peer_id: String, new_role: String },
    KickMember { server_id: String, peer_id: String },
    LeaveServer { server_id: String },
    ChangeRolePermissions { server_id: String, role: String, permissions: u32 },
    BanMember { server_id: String, peer_id: String },
    UnbanMember { server_id: String, peer_id: String },
    SetChannelVisibility { server_id: String, channel_id: String, visibility: String },
    SetChannelPosting { server_id: String, channel_id: String, posting: String },
    CreateLabel { server_id: String, name: String, color: String },
    DeleteLabel { server_id: String, label_id: String },
    UpdateLabel { server_id: String, label_id: String, name: String, color: String },
    AssignLabel { server_id: String, label_id: String, peer_id: String },
    UnassignLabel { server_id: String, label_id: String, peer_id: String },
    SetNickname { server_id: String, peer_id: String, nickname: String },
    SetTwitchUsername { server_id: String, peer_id: String, twitch_username: String },
    NotifyShutdown,
    // -- Profile commands (Phase 3.5) --
    UpdateProfile { display_name: String, status: String, about_me: String, avatar_bytes: Option<Vec<u8>>, banner_bytes: Option<Vec<u8>>, twitch_username: String },
    // -- Message editing (Phase 3.5) --
    EditChannelMessage { server_id: String, channel_id: String, message_id: String, new_text: String },
    EditDmMessage { peer_id: String, message_id: String, new_text: String },
    // -- Message deletion/hiding (Phase 3.5) --
    DeleteChannelMessage { server_id: String, channel_id: String, message_id: String },
    DeleteDmMessage { peer_id: String, message_id: String },
    // -- Emoji reactions (Phase 3.5) --
    AddChannelReaction { server_id: String, channel_id: String, message_id: String, emoji: String },
    AddDmReaction { peer_id: String, message_id: String, emoji: String },
    RemoveChannelReaction { server_id: String, channel_id: String, message_id: String, emoji: String },
    RemoveDmReaction { peer_id: String, message_id: String, emoji: String },
    // -- Friends (Phase 3.5) --
    SendFriendRequest { peer_id: String },
    AcceptFriendRequest { peer_id: String },
    RejectFriendRequest { peer_id: String },
    RemoveFriend { peer_id: String },
    // -- Typing indicators (Phase 3.5) --
    SendTypingIndicator { server_id: String, channel_id: String },
    // -- Presence (Phase 6.75) --
    SetInvisible { invisible: bool },
    // -- Channel subscriptions (Phase 6.75) --
    SubscribeChannels { server_id: String, channel_ids: Vec<String> },
    // -- Channel layout (Phase 3.5) --
    UpdateChannelLayout { server_id: String, layout_json: String },
    // -- Pinned messages (Phase 3.5) --
    PinMessage { server_id: String, channel_id: String, message_id: String },
    UnpinMessage { server_id: String, channel_id: String, message_id: String },
    // -- Storage pledge (Phase 4) --
    SetStoragePledge { server_id: String, pledge_bytes: u64 },
    // -- File sharing (Phase 3.5) --
    SendFile {
        peer_id: Option<String>,           // For DMs (None for channels)
        server_id: Option<String>,         // For channels
        channel_id: Option<String>,        // For channels
        file_path: String,                 // Local path to file
        message_id: String,
        message_text: String,
        /// Video thumbnail back-reference (Phase 6.75 video preview).
        /// When set, the file at `file_path` is a thumbnail image for the
        /// vault-stored video identified by `vthumb.cid`. Forwarded into
        /// the FileHeader envelope so receivers can render a play button.
        vthumb: Option<VideoThumbRef>,
        /// Override width for the FileHeader. Used by the video preview
        /// pipeline (Phase 6.75) to populate the underlying VIDEO's pixel
        /// dimensions in the FileHeader so receivers can render the bubble at
        /// the correct aspect ratio before downloading the video itself.
        /// Ignored for image files (Rust extracts those dimensions itself).
        override_width: Option<u32>,
        override_height: Option<u32>,
        /// When set, file bytes are delivered via Share infrastructure — the
        /// FileHeader carries this ref and no binary data follows.
        share_ref: Option<ShareRef>,
    },
    RequestFile {
        file_id: String,
        peer_id: String,
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
    // -- WebRTC commands (Phase 5A) --
    WebRtcPeerConnected { peer_id: String },
    WebRtcPeerDisconnected { peer_id: String },
    WebRtcSendSignal { peer_id: String, signal_type: String, payload: String, conn_id: String },
    /// `chunk_index` is only meaningful when kind == "share_chunk"; for "file" / "shard" it's ignored.
    WebRtcTransferComplete { transfer_id: String, temp_path: String, sender_peer_id: String, kind: String, shard_index: u16, chunk_index: u32 },
    WebRtcSendComplete { transfer_id: String },
    WebRtcTransferFailed { transfer_id: String, peer_id: String, error: String },
    // -- Voice call commands (Phase 5B) --
    CallSendSignal { peer_id: String, signal_type: String, payload: String },
    // -- Voice channel commands (Phase 5C) --
    VoiceChannelJoin { server_id: String, channel_id: String },
    VoiceChannelLeave { server_id: String, channel_id: String },
    VoiceChannelSendSignal { server_id: String, channel_id: String, peer_id: String, signal_type: String, payload: String },
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
    // -- Gossip relay tree commands (Phase 5D) --
    /// Internal: check if a pending server join timed out.
    CheckPendingJoinTimeout { server_id: String },
    /// Dart reports data channel keepalive RTT for peer scoring.
    WebRtcPingReport { peer_id: String, rtt_ms: u32 },
    /// Dart reports a completed broadcast file transfer for relay decision.
    WebRtcBroadcastReceived {
        transfer_id: String,
        broadcast_id: String,
        ttl: u8,
        origin_peer_id: String,
        sender_peer_id: String,
        temp_path: String,
        total_size: u64,
        kind: String,
        shard_index: u16,
    },
    // -- Recovery pool commands (Evidence Recovery) --
    InitiateRecoveryPool { server_id: String, token: String },
    JoinRecoveryPool { server_id: String, token: String },
    StopRecoveryPool { server_id: String },
    // -- Hollow Share (Phase 7A) --
    /// Build a ShareManifest from a local file, persist it, generate the link, start auto-seeding.
    /// Emits ShareCreated on success.
    ShareCreate { source_path: String },
    /// Create a hidden Share (not shown in Share tab) for large file / video streaming.
    /// Emits ShareCreatedHidden on success.
    ShareCreateHidden { source_path: String },
    /// Decode a hollow://share/ link, join the swarm room, fetch the manifest from any peer.
    /// Emits ShareManifestReady or ShareFailed.
    ShareOpenLink { link: String, server_id: Option<String>, context_type: Option<String> },
    /// After ShareManifestReady, begin downloading chunks into save_dir.
    /// When `sequential` is true, chunks are fetched in order (for video streaming).
    ShareStart { root_hash: String, save_dir: String, link: String, sequential: bool },
    /// Stop an in-flight download (keeps partial file + bitmap for resume).
    ShareCancel { root_hash: String },
    /// Toggle seeding for a completed share (joins/leaves the swarm room).
    ShareSetSeeding { root_hash: String, seeding: bool },
    /// Drop a share entry. If delete_file = true, also unlinks the file/partial.
    ShareRemove { root_hash: String, delete_file: bool },
    /// Enumerate persisted shares; result returned via NetworkEvent::ShareList.
    ShareList,
}

// -- Wire protocol types (v2: encrypted) --

/// Unified message type for the Haven protocol.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub(crate) enum HavenMessage {
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
        #[serde(default, skip_serializing_if = "Option::is_none")]
        twitch_proof_json: Option<String>,
    },

    #[serde(rename = "join_rejected")]
    ServerJoinRejected {
        server_id: String,
        reason: String,
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
        #[serde(default)]
        is_invisible: bool,
        #[serde(default)]
        twitch_username: String,
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

    /// Lightweight notification hint for unsubscribed channels (topic routing).
    /// Sent via SendToRoom (0x03) so all room members receive it.
    #[serde(rename = "notif_hint")]
    ChannelNotificationHint {
        server_id: String,
        channel_id: String,
        #[serde(default)]
        has_everyone: bool,
        #[serde(default)]
        mentioned_names: Vec<String>,
        #[serde(default)]
        is_reply: bool,
    },

    // -- Typing indicators (Phase 3.5) --

    /// Ephemeral typing indicator. Not stored, not signed. Fire-and-forget.
    #[serde(rename = "typing")]
    TypingIndicator {
        /// Empty string for DMs.
        server_id: String,
        /// Empty string for DMs.
        channel_id: String,
    },

    /// Ephemeral status update. Not stored, not signed. Fire-and-forget.
    /// Used for invisible mode — tells peers to treat this user as offline.
    #[serde(rename = "status_update")]
    StatusUpdate {
        /// "online" or "invisible"
        status: String,
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
        /// Byte offset to resume from (0 = start from beginning).
        #[serde(default)]
        offset: u64,
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

    // -- WebRTC signaling (Phase 5A) --

    /// SDP offer for WebRTC data channel connection.
    #[serde(rename = "rtc_offer")]
    RtcOffer {
        sdp: String,
        conn_id: String,
    },

    /// SDP answer for WebRTC data channel connection.
    #[serde(rename = "rtc_answer")]
    RtcAnswer {
        sdp: String,
        conn_id: String,
    },

    /// ICE candidate for WebRTC connection establishment.
    #[serde(rename = "rtc_ice")]
    RtcIceCandidate {
        candidate: String,
        sdp_mid: String,
        sdp_mline_index: u32,
        conn_id: String,
    },

    // -- Voice call signaling (Phase 5B) --

    /// Invite a peer to a voice/video call.
    #[serde(rename = "call_invite")]
    CallInvite { call_id: String, #[serde(default)] video: bool, #[serde(default)] sframe_key: String },

    /// Accept a voice call invitation.
    #[serde(rename = "call_accept")]
    CallAccept { call_id: String, #[serde(default)] sframe_key: String },

    /// Reject a voice call invitation.
    #[serde(rename = "call_reject")]
    CallReject { call_id: String },

    /// End an active voice call.
    #[serde(rename = "call_end")]
    CallEnd { call_id: String },

    /// Signal that we're already in a call.
    #[serde(rename = "call_busy")]
    CallBusy { call_id: String },

    /// SDP offer for voice call WebRTC connection.
    #[serde(rename = "call_sdp_offer")]
    CallSdpOffer { call_id: String, sdp: String },

    /// SDP answer for voice call WebRTC connection.
    #[serde(rename = "call_sdp_answer")]
    CallSdpAnswer { call_id: String, sdp: String },

    /// ICE candidate for voice call WebRTC connection.
    #[serde(rename = "call_ice")]
    CallIceCandidate {
        call_id: String,
        candidate: String,
        sdp_mid: String,
        sdp_mline_index: u32,
    },

    /// Video state change during a call (camera on/off).
    #[serde(rename = "call_video_state")]
    CallVideoState { call_id: String, enabled: bool },

    /// Screen share state change during a call (on/off).
    #[serde(rename = "call_screen_state")]
    CallScreenState {
        #[serde(default)]
        call_id: String,
        #[serde(default)]
        enabled: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        quality: Option<String>,
    },

    /// SDP offer for screen share WebRTC connection (separate PC).
    #[serde(rename = "call_screen_offer")]
    CallScreenOffer { call_id: String, sdp: String },

    /// SDP answer for screen share WebRTC connection (separate PC).
    #[serde(rename = "call_screen_answer")]
    CallScreenAnswer { call_id: String, sdp: String },

    /// ICE candidate for screen share WebRTC connection (separate PC).
    #[serde(rename = "call_screen_ice")]
    CallScreenIce {
        call_id: String,
        candidate: String,
        sdp_mid: String,
        sdp_mline_index: u32,
        role: String,
    },

    // -- Gossip relay tree (Phase 5D) --

    /// Gossip peer exchange: share neighbor list for topology discovery.
    #[serde(rename = "peer_exchange")]
    PeerExchange {
        server_id: String,
        peers: Vec<String>,
    },

    /// Request a peer's profile (they respond with ProfileUpdate).
    #[serde(rename = "profile_request")]
    ProfileRequest,

    // -- Voice channel coordination (plaintext for MLS epoch resilience) --
    // These use plaintext HavenMessage instead of MLS MessageEnvelope so they
    // survive epoch staleness after reconnection. SDP/ICE (which contain IPs)
    // stay MLS-encrypted with Olm fallback — only state broadcasts are plaintext.

    /// Broadcast: user joined a voice channel.
    #[serde(rename = "vc_join")]
    VoiceChannelJoin {
        server_id: String,
        channel_id: String,
    },

    /// Broadcast: user left a voice channel.
    #[serde(rename = "vc_leave")]
    VoiceChannelLeave {
        server_id: String,
        channel_id: String,
    },

    /// Broadcast: audio state (mute/deafen) in a voice channel.
    #[serde(rename = "vc_audio_state")]
    VoiceChannelAudioState {
        server_id: String,
        channel_id: String,
        #[serde(default)]
        muted: bool,
        #[serde(default)]
        deafened: bool,
    },

    /// Broadcast: screen share state (on/off) in a voice channel.
    #[serde(rename = "vc_screen_state")]
    VoiceChannelScreenState {
        server_id: String,
        channel_id: String,
        #[serde(default)]
        enabled: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        quality: Option<String>,
    },

    /// Broadcast: camera state (on/off) in a voice channel.
    #[serde(rename = "vc_camera_state")]
    VoiceChannelCameraState {
        server_id: String,
        channel_id: String,
        #[serde(default)]
        enabled: bool,
    },

    // -- Recovery pool (Evidence Recovery) --
    // Plaintext messages (not MLS) — no group exists for a dead server.

    /// Sent when a peer joins a recovery pool room.
    #[serde(rename = "recovery_hello")]
    RecoveryHello {
        server_id: String,
        /// content_ids of vault manifests this peer has locally.
        #[serde(default)]
        manifest_ids: Vec<String>,
        /// JSON: { content_id: [shard_index, ...], ... }
        #[serde(default)]
        shard_inventory_json: String,
    },

    /// Reply from existing pool members to a new joiner.
    #[serde(rename = "recovery_welcome")]
    RecoveryWelcome {
        #[serde(default)]
        manifest_ids: Vec<String>,
        #[serde(default)]
        shard_inventory_json: String,
    },

    /// Coordinator broadcasts the merged manifest set to all members.
    #[serde(rename = "recovery_manifest_sync")]
    RecoveryManifestSync {
        #[serde(default)]
        manifests_json: String,
    },

    /// Coordinator assigns shard transfers: who sends which shard to whom.
    #[serde(rename = "recovery_transfer_plan")]
    RecoveryTransferPlan {
        #[serde(default)]
        plan_json: String,
    },

    /// Broadcast when a shard arrives in the pool.
    #[serde(rename = "recovery_shard_received")]
    RecoveryShardReceived {
        #[serde(default)]
        content_id: String,
        #[serde(default)]
        shard_index: u16,
    },

    /// Coordinator broadcasts pool-wide status update for the dashboard.
    #[serde(rename = "recovery_status")]
    RecoveryStatus {
        #[serde(default)]
        status_json: String,
    },

    /// Initiator stops the pool.
    #[serde(rename = "recovery_stop")]
    RecoveryStop,

    // -- Hollow Share (Phase 7A) --
    // Share control lives in HavenMessage (the wire-level enum), NOT MessageEnvelope.
    // MessageEnvelope assumes a stable MLS group membership; share swarms have none —
    // anyone with the link joins/leaves freely. HavenMessage is the same layer 1:1
    // call signaling uses (RtcOffer, CallInvite, etc.).

    /// Sent by a peer that just joined a share swarm and needs the manifest.
    /// Any seeder in the room responds with ShareManifestResponse.
    #[serde(rename = "share_manifest_req")]
    ShareManifestRequest {
        root_hash: String,
    },

    /// Manifest payload (raw JSON bytes of ShareManifest, base64-encoded).
    /// Receiver verifies SHA-256(manifest_bytes) == root_hash before trusting.
    #[serde(rename = "share_manifest_resp")]
    ShareManifestResponse {
        root_hash: String,
        manifest_b64: String,
    },

    /// Periodic broadcast of which chunks the sender holds.
    /// bitmap_b64 is base64(little-endian-packed bits, MSB-first within each byte).
    #[serde(rename = "share_have")]
    ShareHave {
        root_hash: String,
        bitmap_b64: String,
        chunk_count: u32,
    },

    /// Request a batch of chunks from a specific peer.
    #[serde(rename = "share_chunk_req")]
    ShareChunkRequest {
        root_hash: String,
        indices: Vec<u32>,
    },

    /// Inline chunk delivery for very small chunks; bulk path uses the existing
    /// ws_stream binary frames + WebRtcSendFile pipeline with kind = "share_chunk".
    /// Receiver verifies SHA-256(data) == manifest.chunk_hashes[index] then AES-GCM decrypts.
    #[serde(rename = "share_chunk_resp")]
    ShareChunkResponse {
        root_hash: String,
        index: u32,
        data_b64: String,
    },
}

// -- Hollow Share manifest (Phase 7A) --

/// Manifest describing a shared file. Transmitted in the clear over the swarm room
/// (the manifest's SHA-256 IS the root_hash from the share link, so encrypting it
/// would make discovery impossible). The decryption key is in the link only — never
/// in the manifest.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct ShareManifest {
    /// Format version; bump if the chunk hash domain or nonce derivation changes.
    pub version: u16,
    pub file_name: String,
    pub mime: String,
    pub total_size: u64,
    /// 262_144 (256 KiB) for v1.
    pub chunk_size: u32,
    pub chunk_count: u32,
    /// SHA-256 of each *encrypted* chunk (ciphertext || GCM tag), in order.
    pub chunk_hashes: Vec<[u8; 32]>,
    /// Unix seconds at creation time.
    pub created_at: u64,
    /// Optional creator-supplied note.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

/// Envelope for the plaintext body inside an Encrypted message.
/// Legacy DMs are raw text (no JSON). New messages use this envelope.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "t")]
pub(crate) enum MessageEnvelope {
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
        /// Link preview for the first URL in the message (Phase 6.75).
        /// None when the message has no URL or OG fetch failed.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        link_preview: Option<LinkPreviewRef>,
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
        /// Link preview for the first URL in the message (Phase 6.75).
        /// None when the message has no URL or OG fetch failed.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        link_preview: Option<LinkPreviewRef>,
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
        /// Target peer (only that peer processes; others decrypt but discard).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
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
        /// Target peer (only that peer processes; others decrypt but discard).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
        /// Video thumbnail back-reference (Phase 6.75 video preview).
        /// When present, this file is a thumbnail image for a vault-stored video;
        /// `vthumb.cid` points to the vault content_id of the actual video bytes.
        /// Old clients lacking this field deserialize it as None.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        vthumb: Option<VideoThumbRef>,
        /// Hidden Share back-reference for large files / video streaming.
        /// When present, file bytes are delivered via Share P2P infrastructure
        /// instead of a direct binary stream. Receiver joins the share swarm
        /// using root_hash + key to download chunks.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        share_ref: Option<ShareRef>,
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
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
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
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
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
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
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
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
    },

    /// Chunked shard response (for shards > 256KB).
    #[serde(rename = "shard_resp_chunk")]
    ShardResponseChunk {
        sid: String,
        cid: String,
        si: u16,
        ci: u32,
        data: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
    },

    /// Probe: ask peer which shards they have for a content item.
    #[serde(rename = "shard_probe")]
    ShardProbe {
        sid: String,
        cid: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
    },

    /// Probe response: list of shard indices available locally.
    #[serde(rename = "shard_probe_resp")]
    ShardProbeResponse {
        sid: String,
        cid: String,
        shards: Vec<u16>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
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
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
    },

    // -- Phase 6: MLS-only server messages (replaces plaintext HavenMessage variants) --

    /// CRDT operation broadcast (replaces HavenMessage::CrdtOpBroadcast for MLS path).
    #[serde(rename = "crdt_op")]
    CrdtOp {
        sid: String,
        op_json: String,
    },

    /// Server deletion broadcast (replaces HavenMessage::ServerDeleteBroadcast for MLS path).
    #[serde(rename = "srv_delete")]
    ServerDelete {
        sid: String,
    },

    /// Member kick notification (replaces HavenMessage::MemberKickBroadcast for MLS path).
    #[serde(rename = "member_kick")]
    MemberKick {
        sid: String,
    },

    /// Typing indicator (replaces HavenMessage::TypingIndicator for server MLS path).
    #[serde(rename = "srv_typing")]
    Typing {
        sid: String,
        cid: String,
    },

    /// Profile update broadcast via MLS (replaces HavenMessage::ProfileUpdate for servers).
    #[serde(rename = "srv_profile")]
    ProfileUpdate {
        display_name: String,
        status: String,
        about_me: String,
        updated_at: i64,
        #[serde(default)]
        avatar_b64: String,
        #[serde(default)]
        banner_b64: String,
        #[serde(default)]
        is_invisible: bool,
        #[serde(default)]
        twitch_username: String,
    },

    /// CRDT sync request (replaces HavenMessage::SyncRequest for MLS path).
    #[serde(rename = "sync_req")]
    SyncReq {
        sid: String,
        state_vector_json: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
    },

    /// CRDT sync response (replaces HavenMessage::SyncResponse for MLS path).
    #[serde(rename = "sync_resp")]
    SyncResp {
        sid: String,
        ops_json: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
    },

    /// Channel message sync request (replaces HavenMessage::ChannelSyncRequest for MLS path).
    #[serde(rename = "ch_sync_req")]
    ChannelSyncReq {
        sid: String,
        cid: String,
        since_timestamp: i64,
        #[serde(default)]
        sender_timestamps: HashMap<String, i64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
    },

    /// Channel sync probe (replaces HavenMessage::ChannelSyncProbe for MLS path).
    #[serde(rename = "ch_probe")]
    ChannelProbe {
        sid: String,
        cid: String,
        our_latest: i64,
        #[serde(default)]
        msg_count: u32,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
    },

    /// Channel sync probe response (replaces HavenMessage::ChannelSyncProbeResponse for MLS path).
    #[serde(rename = "ch_probe_resp")]
    ChannelProbeResp {
        sid: String,
        cid: String,
        their_latest: i64,
        #[serde(default)]
        msg_count: u32,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
    },

    /// Lightweight encrypted ping sent after creating an inbound session.
    /// Causes the remote peer's outbound session to ratchet (upgrade from
    /// PreKey type 0 to Normal type 1) when they decrypt this message.
    #[serde(rename = "session_ack")]
    SessionAck,

    // -- Voice channel signaling (Phase 5C) --

    /// Broadcast: user joined a voice channel.
    #[serde(rename = "vc_join")]
    VoiceChannelJoin {
        sid: String,
        cid: String,
    },

    /// Broadcast: user left a voice channel.
    #[serde(rename = "vc_leave")]
    VoiceChannelLeave {
        sid: String,
        cid: String,
    },

    /// Targeted: SDP offer for voice channel WebRTC connection.
    #[serde(rename = "vc_sdp_offer")]
    VoiceChannelSdpOffer {
        sid: String,
        cid: String,
        sdp: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
    },

    /// Targeted: SDP answer for voice channel WebRTC connection.
    #[serde(rename = "vc_sdp_answer")]
    VoiceChannelSdpAnswer {
        sid: String,
        cid: String,
        sdp: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
    },

    /// Targeted: audio state (mute/deafen) for voice channel.
    #[serde(rename = "vc_audio_state")]
    VoiceChannelAudioState {
        sid: String,
        cid: String,
        #[serde(default)]
        muted: bool,
        #[serde(default)]
        deafened: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
    },

    /// Targeted: ICE candidate for voice channel WebRTC connection.
    #[serde(rename = "vc_ice")]
    VoiceChannelIce {
        sid: String,
        cid: String,
        candidate: String,
        sdp_mid: String,
        sdp_mline_index: u32,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
    },

    // -- Voice channel screen sharing (Phase 5B) --

    /// Targeted: SDP offer for voice channel screen share (separate PC per direction).
    #[serde(rename = "vc_screen_offer")]
    VoiceChannelScreenOffer {
        sid: String,
        cid: String,
        sdp: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
    },

    /// Targeted: SDP answer for voice channel screen share.
    #[serde(rename = "vc_screen_answer")]
    VoiceChannelScreenAnswer {
        sid: String,
        cid: String,
        sdp: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
    },

    /// Targeted: ICE candidate for voice channel screen share.
    #[serde(rename = "vc_screen_ice")]
    VoiceChannelScreenIce {
        sid: String,
        cid: String,
        candidate: String,
        sdp_mid: String,
        sdp_mline_index: u32,
        #[serde(default)]
        role: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
    },

    /// Broadcast: screen share state (on/off) in a voice channel.
    #[serde(rename = "vc_screen_state")]
    VoiceChannelScreenState {
        sid: String,
        cid: String,
        #[serde(default)]
        enabled: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        quality: Option<String>,
    },

    // -- Voice channel camera (Phase 5B) --

    /// Targeted: renegotiation SDP offer (adding/removing video track).
    #[serde(rename = "vc_reneg_offer")]
    VoiceChannelRenegOffer {
        sid: String,
        cid: String,
        sdp: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
    },

    /// Targeted: renegotiation SDP answer.
    #[serde(rename = "vc_reneg_answer")]
    VoiceChannelRenegAnswer {
        sid: String,
        cid: String,
        sdp: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
    },

    /// Broadcast: camera state (on/off) in a voice channel.
    #[serde(rename = "vc_camera_state")]
    VoiceChannelCameraState {
        sid: String,
        cid: String,
        #[serde(default)]
        enabled: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
    },

    // -- Gossip relay tree (Phase 5D) --

    /// Broadcast metadata: notifies server members that a gossip file broadcast is in flight.
    #[serde(rename = "broadcast_meta")]
    BroadcastMeta {
        broadcast_id: String,
        origin: String,
        sid: String,
        cid: String,
        file_id: String,
        /// TTL (time-to-live) — decremented on each relay hop. Added Phase 6.25.
        #[serde(default = "default_broadcast_ttl")]
        ttl: u8,
    },
}

impl MessageEnvelope {
    /// Returns the target peer ID if this is a targeted message.
    pub(crate) fn target(&self) -> Option<&str> {
        match self {
            Self::ChannelSyncBatch { target, .. }
            | Self::FileHeader { target, .. }
            | Self::ShardStore { target, .. }
            | Self::ShardStoreAck { target, .. }
            | Self::ShardRequest { target, .. }
            | Self::ShardResponse { target, .. }
            | Self::ShardResponseChunk { target, .. }
            | Self::ShardProbe { target, .. }
            | Self::ShardProbeResponse { target, .. }
            | Self::ShardMigrate { target, .. }
            | Self::SyncReq { target, .. }
            | Self::SyncResp { target, .. }
            | Self::ChannelSyncReq { target, .. }
            | Self::ChannelProbe { target, .. }
            | Self::ChannelProbeResp { target, .. }
            | Self::VoiceChannelSdpOffer { target, .. }
            | Self::VoiceChannelSdpAnswer { target, .. }
            | Self::VoiceChannelIce { target, .. }
            | Self::VoiceChannelAudioState { target, .. }
            | Self::VoiceChannelScreenOffer { target, .. }
            | Self::VoiceChannelScreenAnswer { target, .. }
            | Self::VoiceChannelScreenIce { target, .. }
            | Self::VoiceChannelScreenState { target, .. }
            | Self::VoiceChannelRenegOffer { target, .. }
            | Self::VoiceChannelRenegAnswer { target, .. }
            | Self::VoiceChannelCameraState { target, .. } => target.as_deref(),
            _ => None,
        }
    }
}

/// State for reassembling a chunked vault shard from multiple ShardChunk messages.
pub(crate) struct PendingShardAssembly {
    pub server_id: String,
    pub content_id: String,
    pub shard_index: u16,
    pub shard_key: String,
    pub k: u16,
    pub m: u16,
    pub total_size: u64,
    pub tier: String,
    pub expected_chunks: u32,
    pub received: HashSet<u32>,
    pub chunk_data: Vec<(u32, Vec<u8>)>,
    pub sender_peer: String,
    pub received_at: Instant,
}

/// Pending streamed file transfer — AES key stored here until stream bytes arrive.
pub(crate) struct PendingFileStream {
    pub aes_key: String,
    pub aes_nonce: String,
    pub file_name: String,
    pub ext: String,
    pub sender: String,
    pub server_id: String,
    pub channel_id: String,
    pub message_id: String,
    pub is_image: bool,
    pub width: Option<u32>,
    pub height: Option<u32>,
}

/// Pending streamed shard transfer — metadata stored here until stream bytes arrive.
pub(crate) struct PendingShardStream {
    pub server_id: String,
    pub content_id: String,
    pub shard_index: u16,
    pub shard_key: String,
    pub k: u16,
    pub m: u16,
    pub total_size: u64,
    pub tier: String,
}

/// A single message in a sync batch.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct SyncMessageItem {
    /// sender peer ID
    pub s: String,
    /// message text
    pub t: String,
    /// timestamp (millis since epoch)
    pub ts: i64,
    /// Ed25519 signature (base64) over canonical payload.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sig: Option<String>,
    /// Sender's Ed25519 public key (base64 protobuf).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pk: Option<String>,
    /// Unique message ID (UUID).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mid: Option<String>,
    /// Edit timestamp (if message was edited).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub edited_at: Option<i64>,
    /// Message ID this is replying to (optional).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reply_to: Option<String>,
    /// File attachment ID (optional).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_id: Option<String>,
    /// File metadata for late joiners (so they can create file cards).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_meta: Option<SyncFileMetaItem>,
    /// Deletion timestamp (if message was deleted).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hidden_at: Option<i64>,
    /// Reactions on this message (synced alongside the message).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub reactions: Vec<SyncReactionItem>,
}

/// A single reaction in a sync batch.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct SyncReactionItem {
    pub e: String,  // emoji
    pub p: String,  // peer_id
    pub ts: i64,    // added_at
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sig: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pk: Option<String>,
}

/// File metadata bundled with a sync message so late joiners can create file cards.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct SyncFileMetaItem {
    pub fid: String,
    pub name: String,
    pub ext: String,
    pub mime: String,
    pub size: u64,
    pub img: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub w: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub h: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mid: Option<String>,
    pub ts: i64,
    pub sender: String,
    /// Video thumbnail back-reference (Phase 6.75 video preview).
    /// Present when this file is a thumbnail for a vault-stored video.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub vthumb: Option<VideoThumbRef>,
}

/// Back-reference from a thumbnail image (sent via the image P2P path) to the
/// underlying video bytes (stored in the vault). Carried in `MessageEnvelope::FileHeader`
/// and persisted alongside file metadata.
///
/// All fields are needed by the receiver to: (a) display the thumbnail with
/// duration/size badges, (b) trigger a `vault_download_file` on play, (c) Save
/// the underlying video with its original name.
///
/// Phase 6.75 video preview in chats. See HOLLOW_PLAN.md.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VideoThumbRef {
    /// Vault content_id (sha256 of ciphertext) of the underlying video.
    #[serde(default)]
    pub cid: String,
    /// Original video file extension (mp4, webm, mkv, ...).
    #[serde(default)]
    pub ext: String,
    /// Original video file name (used as the default for the Save As dialog).
    #[serde(default)]
    pub name: String,
    /// Video size in bytes.
    #[serde(default)]
    pub size: u64,
    /// Video duration in milliseconds.
    #[serde(default)]
    pub dur_ms: u32,
}

/// Back-reference to a hidden Share that provides chunked P2P delivery for
/// large files (>34 MB) or progressive video streaming. Embedded in
/// `MessageEnvelope::FileHeader` so the receiver can join the share swarm
/// and download via the Share infrastructure instead of waiting for a
/// direct P2P binary stream.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShareRef {
    /// Root hash of the share manifest (hex, 64 chars).
    #[serde(default)]
    pub root_hash: String,
    /// AES-256-GCM encryption key for the share chunks (hex, 64 chars).
    #[serde(default)]
    pub key: String,
}

/// A link preview for a URL embedded in a message.
///
/// Generated by the sender (fetch OG tags, download + compress thumbnail to
/// lossy WebP Q=50) and embedded in the outgoing `DirectMessage` /
/// `ChannelMessage` envelope. Receivers render the card directly from these
/// fields and NEVER make an HTTP request to the previewed URL — this is a
/// privacy requirement, not a cache optimization.
///
/// Phase 6.75 link previews. See HOLLOW_PLAN.md.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LinkPreviewRef {
    /// The URL that was previewed.
    #[serde(default)]
    pub url: String,
    /// og:title or <title> fallback. Truncated to 200 chars on the sender side.
    #[serde(default)]
    pub title: String,
    /// og:description or meta description. Truncated to 400 chars.
    #[serde(default)]
    pub description: String,
    /// Display domain parsed from the URL (e.g. "github.com").
    #[serde(default)]
    pub domain: String,
    /// og:site_name if present (e.g. "GitHub"). Empty string = fall back to domain in UI.
    #[serde(default)]
    pub site_name: String,
    /// Base64-encoded lossy WebP thumbnail (Q=50, max dim 400px).
    /// `None` = no og:image found / image fetch failed / HTML had no thumbnail.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thumb_webp_b64: Option<String>,
    /// Thumbnail width after resize.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thumb_w: Option<u32>,
    /// Thumbnail height after resize.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thumb_h: Option<u32>,
}

/// A single DM in a DM sync batch.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct DmSyncItem {
    /// message text
    pub t: String,
    /// timestamp (millis since epoch)
    pub ts: i64,
    /// true if the sender of this sync batch sent this message
    pub mine: bool,
    /// Ed25519 signature (base64).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sig: Option<String>,
    /// Sender's Ed25519 public key (base64 protobuf).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pk: Option<String>,
    /// Unique message ID (UUID).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mid: Option<String>,
    /// Edit timestamp (if message was edited).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub edited_at: Option<i64>,
    /// Message ID this is replying to (optional).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reply_to: Option<String>,
    /// File attachment ID (optional).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_id: Option<String>,
    /// File metadata for late joiners (so they can create file cards).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_meta: Option<SyncFileMetaItem>,
    /// Deletion timestamp (if message was deleted).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hidden_at: Option<i64>,
    /// Reactions on this message (synced alongside the message).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub reactions: Vec<SyncReactionItem>,
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
pub(crate) struct PendingServerSync {
    /// Peer IDs available for sync (connected members of this server).
    pub available_peers: Vec<String>,
    /// Channels that need sync: (channel_id, our_latest_timestamp).
    pub channels: Vec<(String, i64)>,
    /// When the first peer for this server was registered.
    pub started_at: Instant,
    /// Whether we've already dispatched probes for this server.
    pub dispatched: bool,
}

/// Coordinates multi-peer fan-out sync across servers and channels.
pub(crate) struct SyncCoordinator {
    /// Servers waiting for sync: server_id → PendingServerSync.
    pub pending: HashMap<String, PendingServerSync>,
    /// How long to wait after first peer connects before dispatching probes.
    /// Allows more peers to connect, giving us better spread.
    collection_window: std::time::Duration,
}

impl SyncCoordinator {
    pub(crate) fn new() -> Self {
        Self {
            pending: HashMap::new(),
            collection_window: std::time::Duration::from_millis(500),
        }
    }

    /// Register a newly connected peer for a server's sync.
    /// Called from PeerJoined instead of directly sending sync requests.
    pub(crate) fn register_peer(
        &mut self,
        server_id: &str,
        peer_str: &str,
        channels_with_timestamps: Vec<(String, i64)>,
    ) {
        let entry = self.pending.entry(server_id.to_string()).or_insert_with(|| {
            PendingServerSync {
                available_peers: Vec::new(),
                channels: channels_with_timestamps.clone(),
                started_at: Instant::now(),
                dispatched: false,
            }
        });
        let peer_string = peer_str.to_string();
        if !entry.available_peers.contains(&peer_string) {
            entry.available_peers.push(peer_string);
        }
        // Update channels if this registration provides more channels
        // (e.g., server state updated between connections).
        if entry.channels.len() < channels_with_timestamps.len() {
            entry.channels = channels_with_timestamps;
        }
    }

    /// Check which servers are ready to dispatch (collection window elapsed).
    /// Returns: Vec<(server_id, assignments)> where assignments = Vec<(peer_str, Vec<(channel_id, our_latest)>)>
    pub(crate) fn collect_ready(&mut self) -> Vec<(String, Vec<(String, Vec<(String, i64)>)>)> {
        let now = Instant::now();
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

                let mut assignments: HashMap<String, Vec<(String, i64)>> = HashMap::new();

                for (i, (cid, ts)) in sync.channels.iter().enumerate() {
                    // Primary peer: round-robin by channel index
                    let primary_idx = i % peer_count;
                    assignments
                        .entry(peers[primary_idx].clone())
                        .or_default()
                        .push((cid.clone(), *ts));

                    // Backup peer: offset by half the peer count for maximum spread
                    if use_backup {
                        let backup_idx = (i + peer_count / 2 + 1) % peer_count;
                        if backup_idx != primary_idx {
                            assignments
                                .entry(peers[backup_idx].clone())
                                .or_default()
                                .push((cid.clone(), *ts));
                        }
                    }
                }

                let assignment_vec: Vec<(String, Vec<(String, i64)>)> =
                    assignments.into_iter().collect();
                ready.push((server_id.clone(), assignment_vec));
            }
        }

        ready
    }

    /// Remove completed servers from the pending map.
    pub(crate) fn remove_server(&mut self, server_id: &str) {
        self.pending.remove(server_id);
    }

    /// Check if any servers are pending dispatch.
    pub(crate) fn has_pending(&self) -> bool {
        self.pending.values().any(|s| !s.dispatched)
    }

    /// Clean up dispatched entries older than 30 seconds (sync should be done by then).
    pub(crate) fn cleanup_stale(&mut self) {
        let now = Instant::now();
        self.pending.retain(|_, sync| {
            if sync.dispatched {
                now.duration_since(sync.started_at) < std::time::Duration::from_secs(30)
            } else {
                true
            }
        });
    }
}
