use std::collections::{HashMap, HashSet};
use std::time::Instant;

use serde::{Deserialize, Serialize};

// -- Shared handler-parameter shorthands --
// No SwarmContext struct: the borrow checker needs disjoint borrows, so the
// node modules pass state as individual parameters, and these aliases keep the
// resulting handler signatures short.

pub(crate) type ServerStates = HashMap<String, crate::crdt::server_state::ServerState>;
pub(crate) type WsCmdTx = tokio::sync::mpsc::UnboundedSender<crate::node::ws_client::WsCommand>;
pub(crate) type WsRoomPeers = HashMap<String, HashSet<String>>;
pub(crate) type GossipOverlays = HashMap<String, crate::node::gossip::GossipOverlay>;
pub(crate) type EventTx = tokio::sync::mpsc::Sender<NetworkEvent>;

// -- Security constants --

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

/// Deterministic DM room code for a pair of peers (SHA-256, 32 hex chars).
///
/// PURE in its arguments, never a resolver lookup: both sides must derive the
/// same room, and per-peer resolver state can diverge (one side ingested a
/// device list the other did not) and would then compute a different room.
/// Callers pass MASTER ids, so all of a master's devices share one room; a
/// fan-out to a single device names that device only as `target_peer`.
pub(crate) fn dm_room_code(peer_a: &str, peer_b: &str) -> String {
    use sha2::{Sha256, Digest};
    let mut sorted = [peer_a, peer_b];
    sorted.sort();
    let combined = format!("dm-{}-{}", sorted[0], sorted[1]);
    let hash = Sha256::digest(combined.as_bytes());
    hex::encode(&hash[..16])
}

/// A discovered peer on the local network.
pub(crate) struct DiscoveredPeer {
    pub peer_id: String,
    pub addresses: Vec<String>,
}

/// A master-signed list of the device peer_ids belonging to one identity.
///
/// `peer_id_from_pubkey_protobuf(master_pubkey_b64)` MUST equal `master_peer_id`:
/// that is what binds the key to the identity. `revoked` is a tombstone set, and
/// a revoked id can never re-enter `devices` (`ingest_device_list`); only a
/// higher-`version` signed list may drop it again. `version` is monotonic per
/// master, so a replayed older list can neither un-revoke nor re-add. `devices`
/// and `revoked` are sorted so the signed payload is canonical, and `sig_b64` is
/// the master's signature over `device_list_signing_payload`.
#[derive(Clone, Debug, Serialize, Deserialize, Default)]
pub(crate) struct SignedDeviceList {
    #[serde(default)]
    pub master_pubkey_b64: String,
    #[serde(default)]
    pub master_peer_id: String,
    #[serde(default)]
    pub devices: Vec<String>,
    #[serde(default)]
    pub revoked: Vec<String>,
    #[serde(default)]
    pub version: u64,
    #[serde(default)]
    pub sig_b64: String,
}

/// An Olm prekey bundle carried inside a friend request, so the handshake needs
/// no co-presence at all.
///
/// Not a [`HavenMessage::KeyBundle`]: that one is addressed to a recipient DEVICE
/// and expires in `KEY_EXCHANGE_SKEW_SECS`, while a carried bundle is addressed
/// to a MASTER (a stranger has no device of ours to name) and must survive a
/// relay mailbox, so it gets its own age bound and its own domain-separated
/// signing payload. Replay protection is the one-time key being single-use.
///
/// SECURITY: `verify_carried_bundle` requires the DEVICE signature over
/// `carried_bundle_signing_payload` AND that device to appear in the sender's
/// master-signed device list, so master -> device list -> device key -> bundle
/// -> Olm keys is unbroken, exactly like the live path.
#[derive(Clone, Debug, Serialize, Deserialize, Default)]
pub(crate) struct CarriedBundle {
    /// Sender device's Olm Curve25519 identity key (base64).
    #[serde(default)]
    pub identity_key: String,
    /// A FRESH one-time key minted for this request (base64).
    #[serde(default)]
    pub one_time_key: String,
    /// Recipient MASTER peer id (NOT a device) this bundle is addressed to.
    #[serde(default)]
    pub to_master: String,
    /// Unix SECONDS (not millis) the bundle was minted.
    #[serde(default)]
    pub ts: i64,
    /// Sender DEVICE signature over the carried payload (base64).
    #[serde(default)]
    pub sig_b64: String,
    /// Sender DEVICE Ed25519 pubkey protobuf (base64) -> derives the sender device id.
    #[serde(default)]
    pub device_pk_b64: String,
}

/// The sender's own master-signed profile, carried inside a `FriendRequest` so
/// the incoming card renders with a real name: a stranger has never sent us a
/// `ProfileUpdate`, so without this the card falls back to a raw peer id.
///
/// LIGHT like every profile announce: the avatar HASH only, never the bytes.
///
/// SECURITY: `profile_sig` is REQUIRED on ingest and made by `source_peer_id`'s
/// MASTER key; an absent or invalid signature drops the PROFILE, never the
/// request. Only the subject's own signature may assert the subject's name and
/// avatar, which is why this is verified exactly like a relayed profile.
#[derive(Clone, Debug, Serialize, Deserialize, Default)]
pub(crate) struct CarriedProfile {
    /// The subject's MASTER peer_id. Bound to the request sender's resolved master
    /// on ingest and dropped on a mismatch: nobody may assert a third party's profile.
    #[serde(default)]
    pub source_peer_id: String,
    #[serde(default)]
    pub display_name: String,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub about_me: String,
    #[serde(default)]
    pub updated_at: i64,
    #[serde(default)]
    pub twitch_username: String,
    /// Hex SHA-256 of the avatar blob; empty = no avatar. Never the bytes.
    #[serde(default)]
    pub avatar_hash: String,
    /// Subject's signature over `profile_signing_payload`. REQUIRED: an unsigned
    /// carried profile is dropped and the request kept.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile_sig: Option<String>,
    /// Subject MASTER public key (base64 protobuf) paired with `profile_sig`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile_pk: Option<String>,
}

/// One friend entry shared between an identity's own devices: relationship
/// metadata only, never message history. See `HavenMessage::FriendListSync`.
#[derive(Clone, Debug, Serialize, Deserialize, Default)]
pub(crate) struct FriendListEntry {
    #[serde(default)]
    pub peer_id: String,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub direction: String,
    #[serde(default)]
    pub requested_at: i64,
}

/// Events emitted by the network node.
pub(crate) enum NetworkEvent {
    PeerDiscovered { peer: DiscoveredPeer },
    PeerExpired { peer_id: String },
    PeerDisconnected { peer_id: String },
    RoomCleared,
    Listening { address: String },
    MessageReceived { from_peer: String, text: String, timestamp: i64, message_id: String, reply_to_mid: String, link_preview: Option<LinkPreviewRef>, signature: Option<String>, public_key: Option<String>,
        /// True when this DM is our OWN message echoed from a sibling device: then
        /// `from_peer` is the recipient master and Dart must render it as outgoing.
        is_own: bool,
        /// The row already existed (a sync batch, pending drain or fetch-node insert
        /// beat this delivery). Still emitted so an open chat renders it; Dart must
        /// skip unread increments and notifications.
        duplicate: bool },
    ChannelMessageReceived { server_id: String, channel_id: String, from_peer: String, text: String, timestamp: i64, message_id: String, reply_to_mid: String, link_preview: Option<LinkPreviewRef>, signature: Option<String>, public_key: Option<String>,
        /// True when `reply_to_mid` points at a message WE authored; Dart's
        /// mentions-only notification gate reads this.
        reply_to_own: bool,
        /// Same contract as [`NetworkEvent::MessageReceived::duplicate`].
        duplicate: bool },
    MessageSent { to_peer: String, message_id: String, timestamp: i64, signature: Option<String>, public_key: Option<String> },
    ChannelMessageSent { server_id: String, channel_id: String, message_id: String, timestamp: i64, signature: Option<String>, public_key: Option<String> },
    MessageSendFailed { to_peer: String, error: String },
    SessionEstablished { peer_id: String },
    Error { message: String },
    // -- CRDT events --
    ServerCreated { server_id: String, name: String },
    ServerUpdated { server_id: String },
    /// Emote bytes arrived and were cached; Dart invalidates its hash-keyed cache.
    EmoteAssetsReceived { hashes: Vec<String> },
    ChannelAdded { server_id: String, channel_id: String, name: String, channel_type: String },
    ChannelRemoved { server_id: String, channel_id: String },
    ChannelRenamed { server_id: String, channel_id: String, new_name: String },
    ServerDeleted { server_id: String },
    MemberJoined { server_id: String, peer_id: String },
    MemberLeft { server_id: String, peer_id: String },
    SyncCompleted { server_id: String, ops_applied: u32 },
    ServerJoined { server_id: String, name: String },
    ServerJoinFailed { server_id: String, reason: String },
    /// The live window elapsed with nobody there to answer, so the request was
    /// parked in the server room's join ring. Not a failure; the UI shows a tile.
    ServerJoinParked { server_id: String },
    /// `state` is one of `rejected`, `admitted`, `ready`, `discarded`; `reason`
    /// carries the reject reason and is empty otherwise.
    PendingJoinUpdated { server_id: String, state: String, reason: String },
    MessageSyncStarted { server_id: String, peer_id: String },
    MessageSyncCompleted { server_id: String, new_message_count: u32 },
    MessageSyncFailed { server_id: String, error: String },
    MessageSyncProgress { server_id: String, channel_id: String, received_count: u32, total_count: u32 },
    RoleChanged { server_id: String, peer_id: String, new_role: String },
    DmSyncCompleted { peer_id: String, new_message_count: u32 },
    // -- Profile events --
    ProfileUpdated { peer_id: String },
    /// A device list was ingested for `master_peer_id`; Dart invalidates its
    /// device-to-identity map so attribution updates.
    DeviceListUpdated { master_peer_id: String },
    /// A contact's identity changed: a new device joined it, or one of their
    /// devices re-keyed. `peer_id` is the MASTER, `kind` a
    /// `security_alerts::KIND_*` constant. Emitted once per distinct fact, so a
    /// dismissed warning stays dismissed across reconnects.
    SecurityAlert { peer_id: String, kind: String, detail: String, created_at: i64 },
    /// THIS device appears in the identity's signed `revoked` set. Dart self-nukes
    /// (`stash_pending_wipe()` + relaunch); the cryptographic cutoff already
    /// happened everywhere else.
    SelfRevoked,
    // -- Message editing events --
    ChannelMessageEdited { server_id: String, channel_id: String, message_id: String, new_text: String, edited_at: i64, signature: Option<String>, public_key: Option<String> },
    DmMessageEdited { peer_id: String, message_id: String, new_text: String, edited_at: i64, signature: Option<String>, public_key: Option<String> },
    // -- Late link-preview events (issue #45) --
    // Deliberately NOT an edit event: `edited_at` is untouched, so the bubble must
    // not grow an "(edited)" badge because its preview arrived late.
    ChannelLinkPreviewUpdated { server_id: String, channel_id: String, message_id: String, preview: Option<LinkPreviewRef> },
    DmLinkPreviewUpdated { peer_id: String, message_id: String, preview: Option<LinkPreviewRef> },
    // -- Message deletion events --
    ChannelMessageDeleted { server_id: String, channel_id: String, message_id: String, deleted_at: i64 },
    DmMessageDeleted { peer_id: String, message_id: String, deleted_at: i64 },
    // -- Emoji reaction events --
    ChannelReactionAdded { server_id: String, channel_id: String, message_id: String, emoji: String, reactor: String, added_at: i64 },
    DmReactionAdded { peer_id: String, message_id: String, emoji: String, reactor: String, added_at: i64 },
    ChannelReactionRemoved { server_id: String, channel_id: String, message_id: String, emoji: String, reactor: String, removed_at: i64 },
    DmReactionRemoved { peer_id: String, message_id: String, emoji: String, reactor: String, removed_at: i64 },
    // -- Friend events --
    FriendRequestReceived { peer_id: String },
    FriendRequestAccepted { peer_id: String },
    FriendRequestRejected { peer_id: String },
    FriendRemoved { peer_id: String },
    /// A sibling sent our identity's friend list and we inserted `count` new rows.
    FriendsBackfilled { count: u32 },
    // -- Conference events (see node/conference.rs + reports/CONFERENCES_PLAN.md) --
    /// (Host) a stranger is at the door. Blocklist already applied at ingest;
    /// `avatar_hash` is a hash, never blob bytes.
    ConferenceJoinRequestReceived { conf_id: String, peer_id: String, display_name: String, avatar_hash: String },
    /// (Joiner) the host declined us / wrong access code / meeting gone.
    ConferenceJoinDenied { conf_id: String, reason: String },
    /// (Joiner) lobby banner: whose meeting we're waiting for.
    ConferenceLobbyInfo { conf_id: String, host_peer_id: String, host_name: String, host_avatar_hash: String },
    /// (Joiner) our MLS Welcome for the conf group landed — we're in.
    ConferenceAdmitted { conf_id: String },
    /// RAM-only conference chat line (never persisted, no unread machinery).
    ConferenceChatMessage { conf_id: String, sender_peer_id: String, text: String, timestamp: i64 },
    /// The meeting ended. Dart validates `by_peer_id` against the known host.
    ConferenceEnded { conf_id: String, by_peer_id: String },
    /// (Member) we were removed from the meeting by the host.
    ConferenceKicked { conf_id: String, by_peer_id: String },
    // -- Temporary nickname events --
    NicknameClaimed { nickname: String },
    NicknameReleased,
    NicknameClaimFailed { error: String },
    NicknameResolveFailed { nickname: String, error: String },
    // -- Relay connection events --
    RelayDisconnected,
    /// The WS relay connection was (re)established and authenticated. The UI
    /// shows real "Connected" only after this — not on local node start.
    RelayConnected,
    /// A WS connect attempt is in progress. `reconnecting` is true when this
    /// follows a prior drop (backoff retry), false for the initial connect.
    RelayConnecting { reconnecting: bool },
    ChannelNotificationHint {
        server_id: String, channel_id: String, from_peer: String,
        message_id: String,
        has_everyone: bool, mentioned_names: Vec<String>,
        /// True only when the message replies to one of OUR messages. Pre-0.9.1
        /// senders cannot tell us the reply author, so this stays false for them.
        is_reply_to_own: bool,
    },
    // -- Typing indicator events --
    TypingStarted { peer_id: String, server_id: String, channel_id: String },
    // -- Presence events --
    PeerStatusChanged { peer_id: String, status: String },
    // -- Pinned message events --
    MessagePinned { server_id: String, channel_id: String, message_id: String },
    MessageUnpinned { server_id: String, channel_id: String, message_id: String },
    // -- File transfer events --
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
        /// Present when this FileHeader is the thumbnail for a vault video.
        video_thumb: Option<VideoThumbRef>,
        /// Hidden Share back-reference for large files / progressive video streaming.
        share_ref: Option<ShareRef>,
        /// Tiny base64 WebP placeholder shown blurred under the Download button.
        /// None for non-images and pre-0.9.4 senders.
        thumb_b64: Option<String>,
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
    /// Honest file-card state for a file whose bytes are not on disk. `state` is
    /// one of "requesting" | "waiting" | "gone" | "expired"; `peer_id` is the
    /// MASTER it is about ("" when none): the holder being asked, the offline DM
    /// counterparty, or the peer that answered that it does not have the file.
    FileAvailability {
        file_id: String,
        state: String,
        peer_id: String,
    },
    /// Time-limited TURN credentials from the relay over the authed WS. Rust owns
    /// the refresh cadence (on connect, then every 50 minutes).
    TurnCredentials { username: String, password: String, ttl: u64, uris: Vec<String> },
    /// The relay's advertised media forwarder. Static relay config, refreshed only
    /// on each (re)connect.
    MediaForwarderInfo { peer_id: String, online: bool },
    // -- Multi-device link snapshot events --
    /// (Populated device) our link code was claimed on the relay; show it with a
    /// countdown for the empty device to enter.
    LinkCodeClaimed { code: String },
    /// (Populated/empty) A link-code claim or resolve failed (taken / invalid /
    /// not_found / expired).
    LinkCodeError { error: String, code: String },
    /// A populated sibling is offering, or an empty one requesting, a full DB
    /// snapshot. `peer_id` is the sibling DEVICE id; the counts drive direction.
    SiblingLinkAvailable {
        peer_id: String,
        their_msg_count: u32,
        their_friend_count: u32,
        their_has_profile: bool,
    },
    /// Real-time progress of an inbound link snapshot transfer (drives the bar).
    LinkProgress {
        link_id: String,
        bytes_received: u64,
        total_bytes: u64,
    },
    /// The inbound snapshot was decrypted and imported; the counts are post-import.
    LinkComplete {
        link_id: String,
        msg_count: u32,
        friend_count: u32,
        server_count: u32,
    },
    /// The link snapshot transfer/decrypt/import failed.
    LinkFailed {
        link_id: String,
        error: String,
    },
    /// (Sender) the snapshot is fully queued to the target, so the sender can close
    /// its dialog. It does NOT restart; its own DB is intact.
    LinkPushComplete {
        bytes: u64,
    },
    // -- Vault shard events --
    ShardStored { server_id: String, content_id: String, shard_index: u16, from_peer: String },
    ShardStoreAckReceived { server_id: String, content_id: String, shard_index: u16, success: bool, error: String },
    ShardStoreFailed { server_id: String, content_id: String, shard_index: u16, target_peer: String, error: String },
    ShardDeleted { server_id: String, content_id: String },
    ShardReceived { server_id: String, content_id: String, shard_index: u16, from_peer: String },
    ShardRequestFailed { server_id: String, content_id: String, shard_index: u16, error: String },
    // -- Vault upload pipeline events --
    VaultUploadProgress { server_id: String, content_id: String, phase: String, progress: f32 },
    VaultUploadComplete { server_id: String, content_id: String, channel_id: String },
    VaultUploadFailed { server_id: String, content_id: String, error: String },
    // -- Vault download pipeline events --
    VaultDownloadProgress { server_id: String, content_id: String, phase: String, progress: f32 },
    VaultDownloadComplete { server_id: String, content_id: String, disk_path: String },
    VaultDownloadFailed { server_id: String, content_id: String, error: String },
    // -- Vault rebalancing events --
    RebalanceStarted { server_id: String, shards_to_move: u32 },
    RebalanceProgress { server_id: String, moved: u32, total: u32 },
    RebalanceCompleted { server_id: String },
    // -- Vault guard events --
    VaultUploadReplicationFallback { server_id: String, content_id: String, online: usize, needed: usize },
    // -- Connection status events --
    KeyExchangeStarted { peer_id: String },
    KeyExchangeProgress { peer_id: String, stage: String },
    // -- WebRTC events --
    WebRtcSignal { peer_id: String, signal_type: String, payload: String, conn_id: String },
    /// Tell Dart to send a file over WebRTC data channel.
    /// `chunk_index` is only meaningful when kind == "share_chunk"; otherwise 0.
    WebRtcSendFile { peer_id: String, transfer_id: String, file_path: String, total_size: u64, kind: String, shard_index: u16, chunk_index: u32 },
    // -- Voice call events --
    CallSignal { peer_id: String, signal_type: String, payload: String },
    // -- Voice channel events --
    /// `is_self` = this is OUR OWN join or leave, set by the emitting handler. Dart
    /// must branch on it and never compare `peer_id` against a local id: the
    /// participant set is keyed by ROUTABLE DEVICE ids.
    VoiceChannelJoined { server_id: String, channel_id: String, peer_id: String, is_self: bool },
    VoiceChannelLeft { server_id: String, channel_id: String, peer_id: String, is_self: bool },
    VoiceChannelSignal { server_id: String, channel_id: String, peer_id: String, signal_type: String, payload: String },
    // -- Media forwarder events (media forwarding step 3) --
    /// A client-bound `fwd_*` signal from a media forwarder. Dart gates on
    /// "from_peer is the discovered forwarder AND origin is watched+assigned";
    /// Rust only enforces the SDP size cap here.
    ForwarderSignal { from_peer: String, signal_type: String, payload: String },
    // -- Gossip relay tree events --
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
    /// Tell Dart to send a small gossip frame (`GossipCrdtOp` JSON, type byte 0x04
    /// on 'hollow-data') to each target's open data channel, so CRDT ops flood
    /// peer-to-peer instead of paying the relay's O(N) egress.
    GossipRelayOp {
        targets: Vec<String>,
        payload: Vec<u8>,
    },
    /// Voice channel mode changed (mesh <-> gossip).
    VoiceChannelModeChanged {
        server_id: String,
        channel_id: String,
        mode: String,
        gossip_neighbors: Vec<String>,
    },
    /// MLS epoch changed, so the SFrame key needs rotation. `channel_id` is
    /// `Some(cid)` when the key belongs to a restricted channel's MLS SUBGROUP and
    /// Dart applies it only to that channel's cryptor; `None` = the server group.
    MlsEpochChanged {
        server_id: String,
        epoch: u64,
        sframe_key: Vec<u8>,
        channel_id: Option<String>,
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
    // -- Hollow Share --
    ShareManifestReady { root_hash: String, file_name: String, total_size: u64, chunk_count: u32 },
    ShareProgress { root_hash: String, chunks_have: u32, chunks_total: u32, seeders: u8, leechers: u8, bytes_per_sec: u64 },
    ShareCompleted { root_hash: String, disk_path: String },
    /// Download/seed encountered a fatal error; swarm state has been dropped.
    ShareFailed { root_hash: String, error: String },
    ShareSeedingChanged { root_hash: String, seeding: bool, seeders: u8, leechers: u8, bytes_uploaded: u64 },
    ShareCreated { root_hash: String, link: String, file_name: String, total_size: u64 },
    /// Hidden share created for a large file or video streaming; carries the
    /// root_hash and key a `ShareRef` on the FileHeader needs.
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
    // -- Guest sync events (Public Channels Phase 3) --
    PublicChannelListReceived { server_id: String, server_name: String, channels: Vec<PublicChannelEntryFfi>, server_avatar: Option<Vec<u8>>, server_banner_thumb: Option<Vec<u8>> },
    PublicChannelSyncReceived { server_id: String, channel_id: String, messages: Vec<GuestSyncMessageFfi>, has_more: bool, sender_profiles: Vec<SyncSenderProfileFfi> },
    PublicChannelConfigChanged { server_id: String, channel_id: String, is_public: bool, channel_name: String, category: Option<String> },
}

/// Lightweight ShareEntry for streaming lists to Dart; the persisted row is
/// wider (manifest JSON, encryption key) and Dart only needs what it renders.
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct PublicChannelEntry {
    pub channel_id: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub category: Option<String>,
}

#[derive(Clone)]
pub(crate) struct PublicChannelEntryFfi {
    pub channel_id: String,
    pub name: String,
    pub category: Option<String>,
}

#[derive(Clone)]
pub(crate) struct GuestSyncMessageFfi {
    pub sender_id: String,
    pub text: String,
    pub timestamp: i64,
    pub message_id: Option<String>,
    pub signature: Option<String>,
    pub public_key: Option<String>,
    pub edited_at: Option<i64>,
    pub reply_to: Option<String>,
    pub hidden_at: Option<i64>,
    pub reactions: Vec<GuestReactionFfi>,
    /// Attachment metadata: name, size and type only, never bytes.
    pub file_meta: Option<GuestFileMetaFfi>,
    /// The message's link preview. Guests hold no rows, so the card comes straight
    /// off the wire; `guest_item_accepted` folds it into the signature check, which
    /// is what stops a relay pasting its own card onto a plaintext public batch.
    pub link_preview: Option<LinkPreviewRef>,
}

/// FFI-visible file metadata for a guest message. Metadata ONLY — a guest
/// obtains bytes separately via the gated public-file request path.
#[derive(Clone)]
pub(crate) struct GuestFileMetaFfi {
    pub file_id: String,
    pub file_name: String,
    pub file_ext: String,
    pub mime_type: String,
    pub size_bytes: u64,
    pub is_image: bool,
    pub width: Option<u32>,
    pub height: Option<u32>,
    /// LOCAL branch only (previewing our own server): the completed file's path on
    /// OUR disk, so the card renders with no peer fetch. Never populated from the
    /// wire, where a responder's path is meaningless.
    pub disk_path: Option<String>,
}

#[derive(Clone)]
pub(crate) struct GuestReactionFfi {
    pub emoji: String,
    pub peer_id: String,
    pub added_at: i64,
}

#[derive(Clone)]
pub(crate) struct SyncSenderProfileFfi {
    pub peer_id: String,
    pub name: Option<String>,
    pub avatar: Option<Vec<u8>>,
}

pub(crate) struct SendFilePayload {
    pub peer_id: Option<String>,
    pub server_id: Option<String>,
    pub channel_id: Option<String>,
    pub file_path: String,
    pub message_id: String,
    pub message_text: String,
    pub vthumb: Option<VideoThumbRef>,
    pub override_width: Option<u32>,
    pub override_height: Option<u32>,
    pub share_ref: Option<ShareRef>,
    /// True for recorded voice messages. The wire name is the recorder's temp
    /// basename, so the auto-download-gate exemption has to come from Dart.
    pub voice: bool,
    /// Video poster frame extracted by Dart. Rust re-encodes it small and lossy
    /// into `FileHeaderPayload::thumb` and falls back to its dimensions when the
    /// ffmpeg probe found none, so receivers always get the right aspect.
    pub poster: Option<Vec<u8>>,
}

/// Internal re-entry payload: an image SendFile whose WebP/GIF conversion ran
/// off the event loop. Carries the converted bytes plus the original request
/// context so `finish_send_file` can resume. Never constructed from FFI.
pub(crate) struct SendFileConvertedPayload {
    pub peer_id: Option<String>,
    pub server_id: Option<String>,
    pub channel_id: Option<String>,
    pub message_id: String,
    pub message_text: String,
    pub vthumb: Option<VideoThumbRef>,
    pub share_ref: Option<ShareRef>,
    pub original_name: String,
    pub is_image: bool,
    pub final_data: Vec<u8>,
    pub final_ext: String,
    pub width: Option<u32>,
    pub height: Option<u32>,
    /// Tiny base64 WebP placeholder built alongside the conversion.
    pub thumb: Option<String>,
    pub voice: bool,
}

/// Internal re-entry payload: erasure coding and the local shard writes ran off
/// the event loop; resume at shard distribution. Never constructed from FFI.
pub(crate) struct VaultUploadPreparedPayload {
    pub server_id: String,
    pub channel_id: String,
    pub content_id: String,
    pub message_id: String,
    pub plan: crate::vault::pipeline::UploadPlan,
    /// Some((online, needed)) when the upload guard fell back to replication.
    pub fallback_info: Option<(usize, usize)>,
}

pub(crate) struct VaultUploadFilePayload {
    pub server_id: String,
    pub channel_id: String,
    pub file_name: String,
    pub mime_type: String,
    pub message_id: String,
    pub ciphertext: Vec<u8>,
    pub aes_key: Vec<u8>,
    pub aes_nonce: Vec<u8>,
    pub original_size: u64,
    pub content_id: String,
}

/// In-flight server-join state, keyed by server_id in `pending_server_joins`.
/// Carries the gate-bypass tokens needed when (re-)sending a ServerJoinRequest.
#[derive(Debug, Clone, Default)]
pub(crate) struct PendingJoin {
    pub(crate) twitch_proof_json: Option<String>,
    /// True once the user accepted the NSFW "proceed at your own risk" prompt.
    pub(crate) nsfw_confirmed: bool,
    /// Unix MILLISECONDS when the user asked, and the request NONCE: every answer
    /// names it, so a stale copy replayed out of the three-day ring can never
    /// resolve a NEWER request.
    pub(crate) requested_at: i64,
    /// True once the live window elapsed with no answer and we deposited a copy in
    /// the server room's `~join` ring. A parked join has no timer: it waits for a
    /// member to return.
    pub(crate) parked: bool,
    /// Unix MILLISECONDS of the last ring deposit, so a flapping joiner cannot
    /// refill a 200-frame ring on every reconnect (see `REDEPOSIT_INTERVAL_MS`).
    pub(crate) last_deposited_at: i64,
    /// Our OWN master-signed device list, carried on every copy of the request. A
    /// member that has never been online with us holds no device-to-master link, so
    /// `resolve()` alone would add our raw DEVICE id as the member key.
    pub(crate) device_list: Option<SignedDeviceList>,
    /// Base64 of our serialised MLS KeyPackage, minted ONCE per row and reused for
    /// every re-send: we hold its private half until a Welcome consumes it, and
    /// OpenMLS accepts a re-add of the same package once the old leaf is gone. It
    /// rides the PARKED ring copy so an admitter can seat the LEAF in the same
    /// batch that admits the membership, with the joiner nowhere near.
    pub(crate) key_package: Option<String>,
}

/// How often a still-parked join re-deposits its copy into the `~join` ring.
///
/// The ring is 200 frames / 1 MB per (room, topic) and shared by every joiner
/// of that server, so a joiner that flapped once a minute would own the whole
/// ring within hours. Twelve hours is far inside the three-day retention, which
/// keeps the relay's fair-share eviction a backstop rather than the design.
pub(crate) const REDEPOSIT_INTERVAL_MS: i64 = 12 * 3600 * 1000;

/// The pseudo-channel the server room's join ring is keyed under.
///
/// Never a channel id: `~` is not in the channel-id alphabet, so this cannot
/// collide with a real channel's ring. The relay validates topic strings for
/// LENGTH only, so no registration beyond the ordinary `set_topic_buffer`.
pub(crate) const JOIN_TOPIC: &str = "~join";

/// Wall-clock unix MILLISECONDS. Wall clock rather than a monotonic instant
/// because the value crosses the wire and outlives the process that minted it.
pub(crate) fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

/// A fresh channel id: the server's first 8 characters, then 4 random bytes.
///
/// ONE definition, called by whoever sends [NodeCommand::CreateChannel], so the
/// id exists before the command does and can be handed back to the caller.
pub(crate) fn new_channel_id(server_id: &str) -> String {
    let mut buf = [0u8; 4];
    getrandom::fill(&mut buf)
        .expect("system RNG unavailable — cannot generate secure random bytes");
    format!("{}-{}", &server_id[..8.min(server_id.len())], hex::encode(buf))
}

/// Commands the FFI layer can send into the swarm event loop.
pub(crate) enum NodeCommand {
    SendMessage { peer_id: String, text: String, message_id: String, reply_to_mid: Option<String>, link_preview: Option<LinkPreviewRef> },
    SendChannelMessage { server_id: String, channel_id: String, text: String, message_id: String, reply_to_mid: Option<String>, link_preview: Option<LinkPreviewRef> },
    JoinRoom { room_code: String },
    // -- CRDT commands --
    CreateServer { name: String },
    /// `channel_id` is minted by the CALLER (`new_channel_id`) so the FFI can hand
    /// Dart the real id synchronously: "create channel in this category" writes a
    /// layout entry, and a placeholder id leaves one no channel will ever match.
    CreateChannel { server_id: String, channel_id: String, name: String, category: Option<String>, channel_type: String },
    RemoveChannel { server_id: String, channel_id: String },
    RenameServer { server_id: String, new_name: String },
    RenameChannel { server_id: String, channel_id: String, new_name: String },
    UpdateServerSetting { server_id: String, key: String, value: String },
    DeleteServer { server_id: String },
    JoinServer { server_id: String, twitch_proof_json: Option<String>, nsfw_confirmed: bool },
    RequestChannelSync { server_id: String, channel_id: String },
    ChangeRole { server_id: String, peer_id: String, new_role: String },
    KickMember { server_id: String, peer_id: String },
    LeaveServer { server_id: String },
    ChangeRolePermissions { server_id: String, role: String, permissions: u32 },
    BanMember { server_id: String, peer_id: String },
    UnbanMember { server_id: String, peer_id: String },
    SetChannelVisibility { server_id: String, channel_id: String, visibility: String },
    SetChannelPosting { server_id: String, channel_id: String, posting: String },
    SetChannelPublic { server_id: String, channel_id: String, is_public: bool },
    /// Request/reply: a LIVE clone of one server's in-memory CRDT state. Preferred
    /// over the persisted snapshot because the CrdtStore flush is fire-and-forget,
    /// so a DB read racing a fresh toggle returns the PREVIOUS value and reverts
    /// the optimistic UI (#44). `None` = server unknown.
    GetServerStateSnapshot {
        server_id: String,
        reply: tokio::sync::oneshot::Sender<Option<crate::crdt::server_state::ServerState>>,
    },
    MuteMember { server_id: String, peer_id: String, expires_at: u64 },
    UnmuteMember { server_id: String, peer_id: String },
    SetChannelSlowMode { server_id: String, channel_id: String, seconds: u32 },
    SetChannelMediaOnly { server_id: String, channel_id: String, media_only: bool },
    // -- Label-gated access + temporary grants (issue #32) --
    SetChannelVisibilityLabels { server_id: String, channel_id: String, labels: Vec<String> },
    SetChannelPostingLabels { server_id: String, channel_id: String, labels: Vec<String> },
    /// `expires_at` epoch ms; `u64::MAX` = until revoked.
    GrantChannelAccess { server_id: String, channel_id: String, peer_id: String, expires_at: u64 },
    RevokeChannelAccess { server_id: String, channel_id: String, peer_id: String },
    // -- Guest sync commands (Public Channels Phase 3) --
    RequestPublicChannels { server_id: String },
    RequestPublicChannelSync { server_id: String, channel_id: String, before_timestamp: Option<i64> },
    /// Guest download of a PUBLIC-channel file: one FileRequest to a single room
    /// peer (`peer_hint` preferred when live), arming the receipt cap. ONE target
    /// only, because each holder re-encrypts with its own AES key and a fan-out
    /// would poison the single header key.
    RequestPublicFile { server_id: String, file_id: String, peer_hint: Option<String> },
    LeaveGuestRoom { server_id: String },
    CreateLabel { server_id: String, name: String, color: String, access: bool },
    DeleteLabel { server_id: String, label_id: String },
    UpdateLabel { server_id: String, label_id: String, name: String, color: String, access: bool },
    AssignLabel { server_id: String, label_id: String, peer_id: String },
    UnassignLabel { server_id: String, label_id: String, peer_id: String },
    // -- Custom emotes --
    /// Add/replace a custom server emote (blob already stored locally by the
    /// FFI import; the CRDT op carries metadata only).
    AddServerEmote { server_id: String, name: String, hash: String, animated: bool },
    RemoveServerEmote { server_id: String, name: String },
    AddServerSticker {
        server_id: String,
        hash: String,
        name: String,
        pack: String,
        animated: bool,
        w: u32,
        h: u32,
    },
    RemoveServerSticker { server_id: String, hash: String },
    /// Pull asset bytes we don't have (emotes, banners, stickers, GIFs —
    /// `kind` sizes the receipt cap). `server_id` targets an online member of
    /// that server's room; `peer_hint` targets a specific peer (DM sender).
    RequestEmotes {
        hashes: Vec<String>,
        kind: super::assets::AssetKind,
        server_id: Option<String>,
        peer_hint: Option<String>,
    },
    SetNickname { server_id: String, peer_id: String, nickname: String },
    SetTwitchUsername { server_id: String, peer_id: String, twitch_username: String },
    NotifyShutdown,
    // -- Profile commands --
    UpdateProfile { display_name: String, status: String, about_me: String, avatar_bytes: Option<Vec<u8>>, banner_bytes: Option<Vec<u8>>, twitch_username: String, showcase_board: Option<String>, showcase_assets: Option<Vec<u8>>, avatar_frame: Option<String>, avatar_anim: Option<String>, banner_anim: Option<String>, support_creds: Option<String> },
    // -- Message editing --
    EditChannelMessage { server_id: String, channel_id: String, message_id: String, new_text: String },
    EditDmMessage { peer_id: String, message_id: String, new_text: String },
    // -- Late link previews (issue #45) --
    // Attach a card to a message ALREADY sent, re-signing the row rather than
    // editing it. `preview: None` clears an existing card.
    AttachChannelLinkPreview { server_id: String, channel_id: String, message_id: String, preview: Option<Box<LinkPreviewRef>> },
    AttachDmLinkPreview { peer_id: String, message_id: String, preview: Option<Box<LinkPreviewRef>> },
    // -- Message deletion/hiding --
    DeleteChannelMessage { server_id: String, channel_id: String, message_id: String },
    DeleteDmMessage { peer_id: String, message_id: String },
    // -- Emoji reactions --
    AddChannelReaction { server_id: String, channel_id: String, message_id: String, emoji: String },
    AddDmReaction { peer_id: String, message_id: String, emoji: String },
    RemoveChannelReaction { server_id: String, channel_id: String, message_id: String, emoji: String },
    RemoveDmReaction { peer_id: String, message_id: String, emoji: String },
    // -- Friends --
    SendFriendRequest { peer_id: String },
    SendFriendRequestByNickname { nickname: String },
    AcceptFriendRequest { peer_id: String },
    RejectFriendRequest { peer_id: String },
    RemoveFriend { peer_id: String },
    /// File a report against a peer with the relay (deduped relay-side, one per
    /// reporter per target per category). Blocking itself is FFI-direct and local.
    ReportUser { target: String, category: String },
    // -- Temporary nicknames --
    ClaimNickname { nickname: String },
    ReleaseNickname,
    // -- Multi-device linking --
    /// (Populated device) Claim a 6-char link code on the relay so an empty
    /// sibling can find this device by code. Reply arrives as `LinkCodeClaimed`.
    ClaimLinkCode { code: String },
    /// (Populated device) Release the claimed link code.
    ReleaseLinkCode,
    /// (Empty device) Resolve a link code to the populated device, then send it a
    /// snapshot request. Reply path: `LinkCodeResolved` → `LinkSnapshotRequest`.
    ResolveLinkCode { code: String, include_vault: bool, include_files: bool },
    /// (Empty device, mnemonic path) Ask an already-known sibling device for a
    /// full snapshot directly (no code; used when the device list is already known).
    RequestLinkSnapshot { target_peer: String, include_vault: bool, include_files: bool },
    /// (Populated device) Accept an inbound link request and push the snapshot.
    AcceptLinkPush { target_peer: String, include_vault: bool, include_files: bool },
    /// (Populated device) Decline an inbound link request.
    DeclineLinkPush { target_peer: String },
    /// Revoke one of OUR OWN devices: bumps our master-signed list with the device
    /// tombstoned, drops our Olm session to it, and removes its MLS leaf from
    /// shared servers where we coordinate. Manual-only.
    RevokeDevice { device_peer_id: String },
    /// Full sibling teardown: tombstone EVERY device but the one we run on in a
    /// single version bump, propagate to friends, and nuke each revoked sibling. A
    /// local wipe alone regrows, because the device-list merge is grow-only.
    ResetDeviceLists,
    /// Ask the chosen SOURCE sibling to re-announce all its servers and re-share
    /// its friends to us. `source_device_id` is that device's peer_id.
    RequestStateSync { source_device_id: String },
    // -- Push notifications --
    RegisterPushToken { token: String, platform: String },
    /// Register per-server/channel push notification prefs with the relay
    /// (RAM only, re-sent on reconnect). See `WsCommand::SetPushPrefs`.
    SetPushPrefs { prefs_json: String },
    /// Opt in/out of the relay's extended offline DM buffer. RAM-only on the relay
    /// and re-registered on every reconnect. See `WsCommand::SetOfflineBuffer`.
    SetOfflineInbox { enabled: bool, retention_secs: i64 },
    // -- Typing indicators --
    SendTypingIndicator { server_id: String, channel_id: String },
    // -- Presence --
    SetInvisible { invisible: bool },
    // -- Channel subscriptions --
    SubscribeChannels { server_id: String, channel_ids: Vec<String> },
    // -- Channel layout --
    UpdateChannelLayout { server_id: String, layout_json: String },
    // -- Pinned messages --
    PinMessage { server_id: String, channel_id: String, message_id: String },
    UnpinMessage { server_id: String, channel_id: String, message_id: String },
    // -- Storage pledge --
    SetStoragePledge { server_id: String, pledge_bytes: u64 },
    // -- File sharing --
    SendFile(Box<SendFilePayload>),
    /// Internal: image conversion finished off-loop; resume the send.
    SendFileConverted(Box<SendFileConvertedPayload>),
    RequestFile {
        file_id: String,
        peer_id: String,
        chunks: Vec<u32>,
    },
    /// Stop waiting for a file. Drops the pending ask AND the explicit-pull
    /// receipt, so an answer already on its way is treated as an unsolicited push
    /// and faces the size cap and the auto-download gate exactly as one. Emits
    /// nothing; the card clears its own state on the tap.
    CancelFileRequest {
        file_id: String,
    },
    /// The auto-download config changed; re-advertise `auto_dl_pref` to every
    /// connected DM peer and sibling so senders stop or resume pushing us bytes.
    ReadvertiseAutoDlPref,
    // -- Vault shard distribution --
    VaultDownloadFile { server_id: String, content_id: String },
    VaultUploadFile(Box<VaultUploadFilePayload>),
    /// Internal: erasure coding finished off-loop; resume the upload.
    VaultUploadPrepared(Box<VaultUploadPreparedPayload>),
    DeleteVaultContent { server_id: String, content_id: String },
    RequestShardFromPeer {
        server_id: String,
        content_id: String,
        shard_index: u16,
        shard_key: String,
        target_peer: String,
    },
    // -- WebRTC commands --
    WebRtcPeerConnected { peer_id: String },
    WebRtcPeerDisconnected { peer_id: String },
    /// Hollow Share's DEDICATED STUN-only data channel. Tracked in its own set
    /// (`webrtc_share_peers`), never mixed with the general one: that channel
    /// carries TURN, and multi-GB Share payloads must not land on the relay.
    WebRtcSharePeerConnected { peer_id: String },
    WebRtcSharePeerDisconnected { peer_id: String },
    /// A Share chunk transfer failed on the Share channel. Separate from
    /// `WebRtcTransferFailed` so a Share hiccup cannot evict the peer from the
    /// general set and knock DM/channel files onto the WS relay.
    WebRtcShareTransferFailed { transfer_id: String, peer_id: String, error: String },
    WebRtcSendSignal { peer_id: String, signal_type: String, payload: String, conn_id: String },
    /// `chunk_index` is only meaningful when kind == "share_chunk"; for "file" / "shard" it's ignored.
    WebRtcTransferComplete { transfer_id: String, temp_path: String, sender_peer_id: String, kind: String, shard_index: u16, chunk_index: u32 },
    WebRtcSendComplete { transfer_id: String },
    WebRtcTransferFailed { transfer_id: String, peer_id: String, error: String },
    // -- Voice call commands --
    CallSendSignal { peer_id: String, signal_type: String, payload: String },
    // -- Voice channel commands --
    VoiceChannelJoin { server_id: String, channel_id: String },
    VoiceChannelLeave { server_id: String, channel_id: String },
    VoiceChannelSendSignal { server_id: String, channel_id: String, peer_id: String, signal_type: String, payload: String },
    /// SFrame heal (issue #27): Dart's cryptors report sustained decrypt
    /// failures against `peer_id` — re-emit the current MLS key; with
    /// `escalate` also re-bootstrap the group / re-add the failing peer.
    VoiceSframeHeal { server_id: String, channel_id: String, peer_id: String, escalate: bool },
    // -- Media forwarder control plane (media forwarding step 3) --
    /// Send an Olm-encrypted `fwd_*` envelope to a media forwarder inside its
    /// `fwd:{peer_id}` room. Queues and fires a signed KeyRequest when there is
    /// no Olm session yet.
    ForwarderSendSignal { forwarder_peer_id: String, signal_type: String, payload: String },
    /// Join/leave the forwarder's dedicated relay room. Deliberately NOT
    /// `NodeCommand::JoinRoom`: that arm mutates `active_room` and fires
    /// `RoomCleared`, which would wipe the open DM chat.
    JoinForwarderRoom { forwarder_peer_id: String },
    LeaveForwarderRoom { forwarder_peer_id: String },
    // -- Embedded peer forwarder (media forwarding step 3 phase 2) --
    /// Settings toggle: this desktop may act as a viewer-peer forwarder.
    /// No-op on mobile / non-forwarder builds.
    SetPeerForwardingEnabled { enabled: bool },
    /// The viewer advertised `fwd_capable` on a `vc_screen_watch` for this
    /// originator, so the embedded engine may accept a matching
    /// `fwd_stream_register` while the watch lasts. This is the abuse gate: a peer
    /// forwarder only ever forwards a stream its user explicitly watches.
    SetForwarderExpectation { origin_peer: String, kind: String, active: bool },
    /// INTERNAL (embedded engine to swarm): a plaintext engine reply to Olm-encrypt
    /// and send through our own `fwd:{device_id}` room, or, when `to_peer` is
    /// ourselves, to short-circuit back as a `ForwarderSignal` event.
    EmbeddedForwarderOut { to_peer: String, envelope_json: String, via_target_room: bool },
    /// Feeder election: start or stop feeding another forwarder with a stream our
    /// embedded engine already forwards. Driven by the stream OWNER over
    /// `vc_screen_assign{feed_target}`.
    SetForwarderFeed {
        origin_peer: String,
        kind: String,
        stream: String,
        target_forwarder: String,
        active: bool,
    },
    // -- Conference commands (node/conference.rs) --
    ConferenceStart { conf_id: String, waiting_room: bool, access_code_hash: Option<String>, host_display_name: String, host_avatar_hash: String },
    ConferenceEnd { conf_id: String },
    ConferenceRequestJoin { conf_id: String, display_name: String, avatar_hash: String, access_code: Option<String> },
    ConferenceAdmit { conf_id: String, peer_id: String },
    ConferenceDeny { conf_id: String, peer_id: String, reason: String },
    ConferenceKick { conf_id: String, peer_id: String },
    ConferenceLeave { conf_id: String },
    ConferenceSendChat { conf_id: String, text: String, timestamp: i64 },
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
    // -- Gossip relay tree commands --
    /// Internal: a pending join's window elapsed, so consider PARKING it.
    ///
    /// `only_if_empty` marks the SHORT window (`JOIN_EMPTY_ROOM_WINDOW`): it parks
    /// only when the relay has already told us the server room holds nobody else.
    /// The long window sends `false` and is the authority for every other case.
    CheckPendingJoinTimeout { server_id: String, only_if_empty: bool },
    /// Internal: a pending join went unanswered past the coordinator's window, so
    /// re-send it and let EVERY online member serve it. The safety net for a
    /// members' election that named a coordinator already gone (presence skew).
    RetryPendingJoin { server_id: String },
    /// User action: drop a persisted pending or rejected join row. Also leaves the
    /// server room, so a late admission's buffered answer never replays. Nothing is
    /// sent to the relay; the ring copy ages out.
    DiscardPendingJoin { server_id: String },
    /// User action ("Request again") on a pending or rejected tile: re-run the join
    /// with the row's stored NSFW/Twitch values under a FRESH nonce. Deliberately
    /// NOT `RetryPendingJoin`, the internal coordinator-window re-ask, which must
    /// keep its nonce.
    RequestPendingJoinAgain { server_id: String },
    /// Dart reports data channel keepalive RTT for peer scoring.
    WebRtcPingReport { peer_id: String, rtt_ms: u32 },
    /// Dart reports the ICE route class of a live connection (Tier 3
    /// reachability-aware overlay): `is_direct` = host/srflx/LAN vs TURN.
    WebRtcRouteReport { peer_id: String, is_direct: bool },
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
    /// Dart hands back a gossip CRDT-op frame (type 0x04) from a data channel.
    /// Ingested through the same validated path as a relay `CrdtOpBroadcast`, and
    /// re-flooded to our own neighbors only when the op is NEW to our op_log.
    WebRtcGossipOpReceived { sender_peer_id: String, payload: Vec<u8> },
    // -- Recovery pool commands (Evidence Recovery) --
    InitiateRecoveryPool { server_id: String, token: String },
    JoinRecoveryPool { server_id: String, token: String },
    StopRecoveryPool { server_id: String },
    // -- Hollow Share --
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

    /// TEST-ONLY: read a live snapshot of the event loop's in-memory MLS/Olm state,
    /// which the running loop owns and nothing outside can otherwise read, and
    /// reply on the oneshot. The variant does not exist in release builds.
    #[cfg(test)]
    DebugSnapshot {
        reply: tokio::sync::oneshot::Sender<DebugSnapshotReply>,
    },
}

impl NodeCommand {
    /// Variant name only — for the swarm-loop stall sentinel. Never exposes
    /// payload (no ids/content in sentinel lines).
    pub(crate) fn kind(&self) -> &'static str {
        match self {
            Self::SendMessage { .. } => "SendMessage",
            Self::SendChannelMessage { .. } => "SendChannelMessage",
            Self::JoinRoom { .. } => "JoinRoom",
            Self::CreateServer { .. } => "CreateServer",
            Self::CreateChannel { .. } => "CreateChannel",
            Self::RemoveChannel { .. } => "RemoveChannel",
            Self::RenameServer { .. } => "RenameServer",
            Self::RenameChannel { .. } => "RenameChannel",
            Self::UpdateServerSetting { .. } => "UpdateServerSetting",
            Self::DeleteServer { .. } => "DeleteServer",
            Self::JoinServer { .. } => "JoinServer",
            Self::RequestChannelSync { .. } => "RequestChannelSync",
            Self::ChangeRole { .. } => "ChangeRole",
            Self::KickMember { .. } => "KickMember",
            Self::LeaveServer { .. } => "LeaveServer",
            Self::ChangeRolePermissions { .. } => "ChangeRolePermissions",
            Self::BanMember { .. } => "BanMember",
            Self::UnbanMember { .. } => "UnbanMember",
            Self::SetChannelVisibility { .. } => "SetChannelVisibility",
            Self::SetChannelPosting { .. } => "SetChannelPosting",
            Self::SetChannelPublic { .. } => "SetChannelPublic",
            Self::GetServerStateSnapshot { .. } => "GetServerStateSnapshot",
            Self::MuteMember { .. } => "MuteMember",
            Self::UnmuteMember { .. } => "UnmuteMember",
            Self::SetChannelSlowMode { .. } => "SetChannelSlowMode",
            Self::SetChannelMediaOnly { .. } => "SetChannelMediaOnly",
            Self::SetChannelVisibilityLabels { .. } => "SetChannelVisibilityLabels",
            Self::SetChannelPostingLabels { .. } => "SetChannelPostingLabels",
            Self::GrantChannelAccess { .. } => "GrantChannelAccess",
            Self::RevokeChannelAccess { .. } => "RevokeChannelAccess",
            Self::RequestPublicChannels { .. } => "RequestPublicChannels",
            Self::RequestPublicChannelSync { .. } => "RequestPublicChannelSync",
            Self::RequestPublicFile { .. } => "RequestPublicFile",
            Self::LeaveGuestRoom { .. } => "LeaveGuestRoom",
            Self::CreateLabel { .. } => "CreateLabel",
            Self::DeleteLabel { .. } => "DeleteLabel",
            Self::UpdateLabel { .. } => "UpdateLabel",
            Self::AssignLabel { .. } => "AssignLabel",
            Self::UnassignLabel { .. } => "UnassignLabel",
            Self::AddServerEmote { .. } => "AddServerEmote",
            Self::RemoveServerEmote { .. } => "RemoveServerEmote",
            Self::AddServerSticker { .. } => "AddServerSticker",
            Self::RemoveServerSticker { .. } => "RemoveServerSticker",
            Self::RequestEmotes { .. } => "RequestEmotes",
            Self::SetNickname { .. } => "SetNickname",
            Self::SetTwitchUsername { .. } => "SetTwitchUsername",
            Self::NotifyShutdown => "NotifyShutdown",
            Self::UpdateProfile { .. } => "UpdateProfile",
            Self::EditChannelMessage { .. } => "EditChannelMessage",
            Self::EditDmMessage { .. } => "EditDmMessage",
            Self::AttachChannelLinkPreview { .. } => "AttachChannelLinkPreview",
            Self::AttachDmLinkPreview { .. } => "AttachDmLinkPreview",
            Self::DeleteChannelMessage { .. } => "DeleteChannelMessage",
            Self::DeleteDmMessage { .. } => "DeleteDmMessage",
            Self::AddChannelReaction { .. } => "AddChannelReaction",
            Self::AddDmReaction { .. } => "AddDmReaction",
            Self::RemoveChannelReaction { .. } => "RemoveChannelReaction",
            Self::RemoveDmReaction { .. } => "RemoveDmReaction",
            Self::SendFriendRequest { .. } => "SendFriendRequest",
            Self::SendFriendRequestByNickname { .. } => "SendFriendRequestByNickname",
            Self::AcceptFriendRequest { .. } => "AcceptFriendRequest",
            Self::RejectFriendRequest { .. } => "RejectFriendRequest",
            Self::RemoveFriend { .. } => "RemoveFriend",
            Self::ReportUser { .. } => "ReportUser",
            Self::ClaimNickname { .. } => "ClaimNickname",
            Self::ReleaseNickname => "ReleaseNickname",
            Self::ClaimLinkCode { .. } => "ClaimLinkCode",
            Self::ReleaseLinkCode => "ReleaseLinkCode",
            Self::ResolveLinkCode { .. } => "ResolveLinkCode",
            Self::RequestLinkSnapshot { .. } => "RequestLinkSnapshot",
            Self::AcceptLinkPush { .. } => "AcceptLinkPush",
            Self::DeclineLinkPush { .. } => "DeclineLinkPush",
            Self::RevokeDevice { .. } => "RevokeDevice",
            Self::ResetDeviceLists => "ResetDeviceLists",
            Self::RequestStateSync { .. } => "RequestStateSync",
            Self::RegisterPushToken { .. } => "RegisterPushToken",
            Self::SetPushPrefs { .. } => "SetPushPrefs",
            Self::SetOfflineInbox { .. } => "SetOfflineInbox",
            Self::SendTypingIndicator { .. } => "SendTypingIndicator",
            Self::SetInvisible { .. } => "SetInvisible",
            Self::SubscribeChannels { .. } => "SubscribeChannels",
            Self::UpdateChannelLayout { .. } => "UpdateChannelLayout",
            Self::PinMessage { .. } => "PinMessage",
            Self::UnpinMessage { .. } => "UnpinMessage",
            Self::SetStoragePledge { .. } => "SetStoragePledge",
            Self::SendFile(..) => "SendFile",
            Self::SendFileConverted(..) => "SendFileConverted",
            Self::RequestFile { .. } => "RequestFile",
            Self::CancelFileRequest { .. } => "CancelFileRequest",
            Self::ReadvertiseAutoDlPref => "ReadvertiseAutoDlPref",
            Self::VaultDownloadFile { .. } => "VaultDownloadFile",
            Self::VaultUploadFile(..) => "VaultUploadFile",
            Self::VaultUploadPrepared(..) => "VaultUploadPrepared",
            Self::DeleteVaultContent { .. } => "DeleteVaultContent",
            Self::RequestShardFromPeer { .. } => "RequestShardFromPeer",
            Self::WebRtcPeerConnected { .. } => "WebRtcPeerConnected",
            Self::WebRtcPeerDisconnected { .. } => "WebRtcPeerDisconnected",
            Self::WebRtcSharePeerConnected { .. } => "WebRtcSharePeerConnected",
            Self::WebRtcSharePeerDisconnected { .. } => "WebRtcSharePeerDisconnected",
            Self::WebRtcShareTransferFailed { .. } => "WebRtcShareTransferFailed",
            Self::WebRtcSendSignal { .. } => "WebRtcSendSignal",
            Self::WebRtcTransferComplete { .. } => "WebRtcTransferComplete",
            Self::WebRtcSendComplete { .. } => "WebRtcSendComplete",
            Self::WebRtcTransferFailed { .. } => "WebRtcTransferFailed",
            Self::CallSendSignal { .. } => "CallSendSignal",
            Self::VoiceChannelJoin { .. } => "VoiceChannelJoin",
            Self::VoiceChannelLeave { .. } => "VoiceChannelLeave",
            Self::VoiceChannelSendSignal { .. } => "VoiceChannelSendSignal",
            Self::VoiceSframeHeal { .. } => "VoiceSframeHeal",
            Self::ForwarderSendSignal { .. } => "ForwarderSendSignal",
            Self::JoinForwarderRoom { .. } => "JoinForwarderRoom",
            Self::LeaveForwarderRoom { .. } => "LeaveForwarderRoom",
            Self::SetPeerForwardingEnabled { .. } => "SetPeerForwardingEnabled",
            Self::SetForwarderExpectation { .. } => "SetForwarderExpectation",
            Self::EmbeddedForwarderOut { .. } => "EmbeddedForwarderOut",
            Self::SetForwarderFeed { .. } => "SetForwarderFeed",
            Self::ConferenceStart { .. } => "ConferenceStart",
            Self::ConferenceEnd { .. } => "ConferenceEnd",
            Self::ConferenceRequestJoin { .. } => "ConferenceRequestJoin",
            Self::ConferenceAdmit { .. } => "ConferenceAdmit",
            Self::ConferenceDeny { .. } => "ConferenceDeny",
            Self::ConferenceKick { .. } => "ConferenceKick",
            Self::ConferenceLeave { .. } => "ConferenceLeave",
            Self::ConferenceSendChat { .. } => "ConferenceSendChat",
            Self::StoreShardOnPeer { .. } => "StoreShardOnPeer",
            Self::CheckPendingJoinTimeout { .. } => "CheckPendingJoinTimeout",
            Self::RetryPendingJoin { .. } => "RetryPendingJoin",
            Self::DiscardPendingJoin { .. } => "DiscardPendingJoin",
            Self::RequestPendingJoinAgain { .. } => "RequestPendingJoinAgain",
            Self::WebRtcPingReport { .. } => "WebRtcPingReport",
            Self::WebRtcRouteReport { .. } => "WebRtcRouteReport",
            Self::WebRtcBroadcastReceived { .. } => "WebRtcBroadcastReceived",
            Self::WebRtcGossipOpReceived { .. } => "WebRtcGossipOpReceived",
            Self::InitiateRecoveryPool { .. } => "InitiateRecoveryPool",
            Self::JoinRecoveryPool { .. } => "JoinRecoveryPool",
            Self::StopRecoveryPool { .. } => "StopRecoveryPool",
            Self::ShareCreate { .. } => "ShareCreate",
            Self::ShareCreateHidden { .. } => "ShareCreateHidden",
            Self::ShareOpenLink { .. } => "ShareOpenLink",
            Self::ShareStart { .. } => "ShareStart",
            Self::ShareCancel { .. } => "ShareCancel",
            Self::ShareSetSeeding { .. } => "ShareSetSeeding",
            Self::ShareRemove { .. } => "ShareRemove",
            Self::ShareList => "ShareList",
            #[cfg(test)]
            Self::DebugSnapshot { .. } => "DebugSnapshot",
        }
    }
}

/// TEST-ONLY: a snapshot of a node's live in-memory crypto state, answered by
/// the event loop for the harness's MLS/Olm inspectors.
#[cfg(test)]
#[derive(Debug, Clone, Default)]
pub(crate) struct DebugSnapshotReply {
    /// server_id -> the MLS group's leaf DEVICE ids: the raw device-keyed truth
    /// under the master-keyed CRDT member panel.
    pub mls_members: std::collections::HashMap<String, Vec<String>>,
    /// server_id -> current MLS epoch.
    pub mls_epoch: std::collections::HashMap<String, u64>,
    /// peer DEVICE id -> Olm session status: "none" | "unconfirmed" | "confirmed".
    pub olm_sessions: std::collections::HashMap<String, String>,
}

// -- Wire protocol types (v2: encrypted) --

/// Unified message type for the Haven protocol.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub(crate) enum HavenMessage {
    /// Ask a peer for an Olm prekey bundle.
    ///
    /// SECURITY: receiving this makes us TEAR DOWN a working session, so it is
    /// DEVICE-signed (`crypto_handler::signed_key_request`). All four fields are
    /// `Option` + `#[serde(default)]` so a pre-rollout client's bare
    /// `{"type":"key_request"}` still deserializes.
    #[serde(rename = "key_request")]
    KeyRequest {
        /// Recipient device peer_id — blocks reflection at a third party.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        to: Option<String>,
        /// Unix seconds — freshness, blocks replay.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        ts: Option<i64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sig: Option<String>,
        /// Sender's DEVICE Ed25519 public key (protobuf, base64).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pk: Option<String>,
    },

    /// An Olm prekey bundle: the Curve25519 keys a peer will ratchet with.
    ///
    /// SECURITY: these keys travel through the relay, so they are DEVICE-signed
    /// (`crypto_handler::signed_key_bundle`). Unsigned, a hostile relay could
    /// substitute its own keys and sit in the middle of the conversation. Same
    /// `Option` + `#[serde(default)]` rollout treatment as `KeyRequest`.
    #[serde(rename = "key_bundle")]
    KeyBundle {
        identity_key: String,
        one_time_key: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        to: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        ts: Option<i64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sig: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pk: Option<String>,
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

    // -- CRDT sync messages --

    #[serde(rename = "sync_request")]
    SyncRequest {
        server_id: String,
        state_vector_json: String,
        /// Sender's SERVER-GROUP MLS epoch, riding the plaintext first-contact sync so
        /// a stale member is detected the moment it re-enters the room: the responder
        /// serves an `MlsCommitCatchup` replay when the sender is behind, and probes
        /// the authority itself when it is AHEAD of us. Absent = old client.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        mls_epoch: Option<u64>,
    },

    #[serde(rename = "sync_response")]
    SyncResponse {
        server_id: String,
        ops_json: String,
    },

    /// Full server state snapshot, sent alongside the op log when serving a join.
    /// Op logs can be incomplete (history loss, 1000-op compaction), so a joiner
    /// replaying ops alone can miss channels, layout or name. The responder's STATE
    /// is the base and ops merge on top. Honored only while a join is pending.
    #[serde(rename = "srv_snapshot")]
    ServerStateSnapshot {
        server_id: String,
        state_json: String,
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
        /// Set by the joiner after they accept the NSFW "proceed at your own
        /// risk" prompt, so the receiver's NSFW gate lets them through.
        #[serde(default)]
        nsfw_confirmed: bool,
        /// Unix MILLISECONDS the user asked at: the request NONCE. Binds every answer
        /// to the ask it resolves, so a copy replayed out of the `~join` ring can never
        /// satisfy or reject a newer request. 0 = a client from before parked joins.
        #[serde(default)]
        requested_at: i64,
        /// The joiner's OWN master-signed device list. A member serving a PARKED join
        /// has by definition never been online with the joiner, so `resolve()` hands
        /// the device id straight back and the member entry would be device-keyed.
        /// Absent = a pre-parked client; the receiver falls back to the resolver.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        device_list: Option<SignedDeviceList>,
        /// True ONLY on the copy deposited into the room's `~join` ring. It is read out
        /// of a TTL buffer, possibly days later, by a member that was not there when it
        /// was written, so it is held to stricter rules than the live unicast copy: no
        /// coordinator-gate bypass, no interactive rejections written into the ring.
        #[serde(default)]
        parked: bool,
        /// The joiner's MLS KeyPackage, base64 of the serialised package. Set ONLY on
        /// the parked ring copy (`deposit_parked_join`); a live request carries `None`
        /// and bootstraps on its SyncResponse instead. A KeyPackage is public material
        /// by construction, so it rides a frame any invite-holder can pull without
        /// widening what the ring exposes. Absent = a client from before rung 2.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        key_package: Option<String>,
    },

    #[serde(rename = "join_rejected")]
    ServerJoinRejected {
        server_id: String,
        reason: String,
        /// The `requested_at` of the request being refused.
        ///
        /// Load-bearing since parked joins: a refusal rides
        /// `send_message_to_peer_in_room`, so the relay BUFFERS it for an absent joiner
        /// and replays it on that device's next join of the server room, which is
        /// usually the user asking again. Without the nonce that stale copy would kill
        /// the fresh request. 0 = a pre-nonce client: "refuse whatever is pending".
        #[serde(default)]
        requested_at: i64,
    },

    /// A member's answer to a join, published on the server room's `~join`
    /// pseudo-topic so it survives the joiner being offline and tells the other
    /// members the join is already resolved. Not a second CRDT ingest path:
    /// `op_json` carries the very `MemberAdded` op the admitting member authored,
    /// and receivers route it through the same author-validated apply the
    /// plaintext `CrdtOpBroadcast` arm uses.
    #[serde(rename = "join_resolved")]
    ServerJoinResolved {
        #[serde(default)]
        server_id: String,
        /// The joiner's MASTER identity (never a device id): the key the CRDT
        /// member entry and the local `join_resolutions` map are stamped under.
        #[serde(default)]
        joiner_master: String,
        /// The `requested_at` of the request this answers.
        #[serde(default)]
        requested_at: i64,
        #[serde(default)]
        admitted: bool,
        /// "" when admitted, else the same reason string `ServerJoinRejected`
        /// carries.
        #[serde(default)]
        reason: String,
        /// The `MemberAdded` CrdtOp JSON when admitted, else None.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        op_json: Option<String>,
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

    #[serde(rename = "dm_sync_req")]
    DmSyncRequest {
        /// Latest DM timestamp the requester has from this peer.
        since_timestamp: i64,
        /// Multi-device peer-fallback: the responder serves BOTH directions of the
        /// conversation, not just `is_mine = 1`, so a friend re-serves the requester's
        /// OWN messages sent from another device that is now offline. Omitted by
        /// single-device requesters (false = the unchanged one-directional path).
        #[serde(default)]
        both_directions: bool,
    },

    /// Multi-device sibling DM backfill: a sibling device asks for the FULL DM
    /// history across ALL conversations, both directions. Honored ONLY from a
    /// `same_identity` sender, because a friend must never pull our DB.
    /// `per_convo_since` carries `(friend_master, latest_ts)` high-water marks and
    /// omitted conversations are served from 0; the responder replies with one
    /// `DmSiblingSyncBatch` per conversation.
    #[serde(rename = "dm_sib_sync_req")]
    DmSiblingSyncRequest {
        #[serde(default)]
        per_convo_since: Vec<(String, i64)>,
    },

    /// Sent to all connected peers when the app is shutting down.
    #[serde(rename = "disconnecting")]
    PeerDisconnecting,

    /// Multi-device: the creator of a NEW server tells its OWN siblings that the
    /// server exists, because the room is brand-new and a sibling has no other way
    /// to learn. The sibling runs its normal join flow; the creator's request
    /// handler same-identity fast-paths it, with no Twitch or ban gate for a co-owner.
    #[serde(rename = "sib_server_announce")]
    SiblingServerAnnounce {
        server_id: String,
    },

    // -- MLS group encryption messages --

    /// MLS-encrypted channel message. `channel_id` `None` = the server-wide group;
    /// `Some(cid)` = that restricted channel's per-channel subgroup, keyed by
    /// `subgroup_id(server_id, cid)`.
    #[serde(rename = "mls_msg")]
    MlsChannelMessage {
        server_id: String,
        body: String, // base64 MLS ciphertext
        #[serde(default, skip_serializing_if = "Option::is_none")]
        channel_id: Option<String>,
    },

    /// KeyPackage from a peer wanting to join an MLS group.
    /// `channel_id` selects server group (None) vs a channel subgroup (Some).
    #[serde(rename = "mls_kp")]
    MlsKeyPackage {
        server_id: String,
        key_package: String, // base64 serialized KeyPackage
        #[serde(default, skip_serializing_if = "Option::is_none")]
        channel_id: Option<String>,
    },

    /// Welcome message sent to a joiner after add_members().
    /// `channel_id` selects server group (None) vs a channel subgroup (Some).
    #[serde(rename = "mls_welcome")]
    MlsWelcome {
        server_id: String,
        welcome: String, // base64 serialized Welcome
        #[serde(default, skip_serializing_if = "Option::is_none")]
        channel_id: Option<String>,
    },

    /// Commit message (membership change) from the server owner.
    /// `channel_id` selects server group (None) vs a channel subgroup (Some).
    #[serde(rename = "mls_commit")]
    MlsCommit {
        server_id: String,
        commit: String, // base64 serialized Commit
        #[serde(default, skip_serializing_if = "Option::is_none")]
        channel_id: Option<String>,
        /// POST-merge epoch of this commit. Commits ride a single room broadcast, so
        /// they also reach fresh joiners already at this epoch and duplicate
        /// deliveries; receivers at or past it skip processing instead of erroring into
        /// the drop-group and re-bootstrap path. Absent from legacy senders.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        epoch: Option<u64>,
    },

    /// Request peers to send their KeyPackages for MLS group bootstrap.
    /// `channel_id` selects server group (None) vs a channel subgroup (Some).
    #[serde(rename = "mls_kp_req")]
    MlsKeyPackageRequest {
        server_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        channel_id: Option<String>,
    },

    /// Plaintext epoch probe: "my MLS group for this key sits at `epoch`, am I
    /// behind?" Sent to the group authority at VC join and from SFrame heal step 2.
    /// A present-but-stale group is otherwise INVISIBLE: commits ride an unbuffered
    /// 0x03 room broadcast and every recovery trigger keys on `has_group`, so a
    /// member that missed join-churn commits sits on a stale SFrame key until the
    /// escalated heal. Plaintext by the sync rule: the prober's MLS is stale.
    #[serde(rename = "mls_epoch_probe")]
    MlsEpochProbe {
        server_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        channel_id: Option<String>,
        epoch: u64,
    },

    /// Replay of missed MLS commit frames to ONE stale member, in ascending epoch
    /// order, as `(post_merge_epoch, base64_commit)`. The SAME bytes that already
    /// rode the server-room `MlsCommit` broadcast, so replaying them to a verified
    /// member leaks nothing and the receiver revalidates every frame through the
    /// normal OpenMLS commit-apply path. The non-churning repair: remove+re-add
    /// bumps the epoch for everyone and feeds a churn spiral.
    #[serde(rename = "mls_commit_catchup")]
    MlsCommitCatchup {
        server_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        channel_id: Option<String>,
        commits: Vec<(u64, String)>,
    },

    // -- Conferences (node/conference.rs; reports/CONFERENCES_PLAN.md) --

    /// Joiner to the conf room: knock on the door, carrying a fresh MLS KeyPackage
    /// so admission is a single host-side commit. `avatar_hash` is a HASH (a
    /// stranger surface is a light announce, never blobs); `access_hash` is
    /// `derive_access_hash(conf_id, code)` or empty.
    #[serde(rename = "conf_join_req")]
    ConferenceJoinRequest {
        conf_id: String,
        display_name: String,
        #[serde(default)]
        avatar_hash: String,
        key_package: String,
        #[serde(default)]
        access_hash: String,
    },

    /// Host → joiner: not getting in (wrong_code / declined / ended).
    #[serde(rename = "conf_join_denied")]
    ConferenceJoinDenied {
        conf_id: String,
        reason: String,
    },

    /// Host → joiner: lobby banner ("waiting for X's meeting").
    #[serde(rename = "conf_lobby")]
    ConferenceLobbyInfo {
        conf_id: String,
        host_name: String,
        #[serde(default)]
        host_avatar_hash: String,
    },

    /// MLS-encrypted conference chat line — RAM-only on both ends, decrypted
    /// under the `conf:{id}` group; NEVER persisted or ring-buffered.
    #[serde(rename = "conf_chat")]
    ConferenceChat {
        conf_id: String,
        body: String,
    },

    #[serde(rename = "conf_ended")]
    ConferenceEnded {
        conf_id: String,
    },

    /// Host → kicked member: you were removed (the MLS remove commit already
    /// cut them off cryptographically — this is the courtesy teardown signal).
    #[serde(rename = "conf_kicked")]
    ConferenceKicked {
        conf_id: String,
    },

    // -- Profile sync --

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
        /// Multi-device: the sender's master-signed device list (Phase 6).
        /// `None` from older clients → sender is treated as single-device.
        #[serde(default)]
        device_list: Option<SignedDeviceList>,
        /// Hex SHA-256 of the sender's current avatar/banner blob; empty = no blob.
        /// Re-announces are LIGHT (empty b64 = "no change") and carry only the hashes,
        /// so a stale receiver pulls once instead of every reconnect re-shipping blobs.
        #[serde(default)]
        avatar_hash: String,
        #[serde(default)]
        banner_hash: String,
        /// Showcase board JSON. `None` from clients that predate boards —
        /// receivers PRESERVE their stored board (a status edit from an old
        /// client must not wipe it). `Some("")` = explicit clear.
        #[serde(default)]
        showcase_board: Option<String>,
        /// Showcase asset bundle (game covers/artwork), avatar-style blob
        /// semantics: "" = no change, "CLEAR" = clear, else base64. Rides
        /// ONLY full sends; light announces carry the hash below.
        #[serde(default)]
        showcase_assets_b64: String,
        #[serde(default)]
        showcase_assets_hash: String,
        /// Avatar frame ID (issue #54): `""` = none, `"b:<hue>"` = a built-in
        /// procedural frame, 64-hex = an asset-rail blob hash. Never the bytes; the art
        /// is PULLED on demand so it can be evicted, unlike this push. `None` from
        /// clients that predate frames and receivers PRESERVE it (a status edit must
        /// not wipe somebody's frame); `Some("")` = explicit clear.
        #[serde(default)]
        avatar_frame: Option<String>,
        /// Asset-rail hash of the sender's ANIMATED avatar (issue #54's follow-up):
        /// `""` = none, 64-hex = a blob to pull under `AssetKind::Profile`. NEVER the
        /// bytes, so a profile push stays kilobytes while the animation is pulled on
        /// demand and LRU-evicted. `None` from clients that predate it and receivers
        /// PRESERVE it; `Some("")` = explicit clear.
        #[serde(default)]
        avatar_anim: Option<String>,
        /// Asset-rail hash of the sender's ANIMATED banner. See `avatar_anim`.
        #[serde(default)]
        banner_anim: Option<String>,
        /// Support credentials: a JSON array of self-contained blind-signature entries,
        /// each binding this profile's MASTER peer id to an item. Capped text, so it
        /// rides the light announce like the showcase board. `None` from clients that
        /// predate it and receivers PRESERVE it; `Some("")` clears, but only when
        /// `support_creds_sig` verifies over it. Verified entry by entry on ingest
        /// (`support_creds::sanitize_incoming_support_creds`) and deliberately outside
        /// the profile signature: an entry already binds the identity.
        #[serde(default)]
        support_creds: Option<String>,
        /// The MASTER's Ed25519 signature (base64) over `(peer_id, updated_at,
        /// support_creds)`, sent whenever `support_creds` is `Some`, including
        /// `Some("")`. REQUIRED on ingest: a receiver applies `support_creds` only
        /// under a valid signature and otherwise PRESERVES what it stored, so
        /// stripping it in flight changes nothing. The credentials are unforgeable
        /// without it; this is what stops a relay DENYING them.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        support_creds_sig: Option<String>,
        /// Owner's signature over the relayable subset of this profile
        /// (`crypto_handler::profile_signing_payload`). REQUIRED on ingest; receivers
        /// store it so they can forward it in a `ProfileRelay`, which is what stops a
        /// forwarder asserting a third party's profile.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        profile_sig: Option<String>,
        /// Owner MASTER public key (base64 protobuf) paired with `profile_sig`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        profile_pk: Option<String>,
    },

    // -- Multi-peer fan-out sync --

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

    // -- Friends --

    #[serde(rename = "friend_request")]
    FriendRequest {
        requested_at: i64,
        /// Async friending: the sender's Olm prekey bundle, so the accepter can build a
        /// session without ever being online at the same moment. Absent = a
        /// pre-async-friending client, which falls back to lazy co-presence exchange.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        carried_bundle: Option<CarriedBundle>,
        /// The sender's own master-signed device list, so the accepter can check the
        /// carried bundle's device really speaks for that master WITHOUT having
        /// ingested a ProfileUpdate first (a stranger, by definition, has not).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        device_list: Option<SignedDeviceList>,
        /// The sender's own master-signed profile, so the receiver can fill the incoming
        /// card for a stranger it holds no profile for; verified and stored exactly like
        /// a `ProfileRelay`. Absent from older clients: the card falls back to the id.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        carried_profile: Option<CarriedProfile>,
    },

    #[serde(rename = "friend_accept")]
    FriendAccept {
        /// Stamp of the request this accept answers. The receiver drops a stamped
        /// accept older than its current request (a relay-parked or mailbox-replayed
        /// copy after a remove and re-add); absent from pre-0.11.1 senders, which
        /// stay honoured.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        requested_at: Option<i64>,
    },

    #[serde(rename = "friend_reject")]
    FriendReject {
        /// The `requested_at` of the request being declined, so a stale or replayed
        /// reject can never delete a NEWER request or an accepted friendship.
        /// 0 = a pre-2026-08-29 client: "decline whatever is pending".
        #[serde(default)]
        requested_at: i64,
        /// The decliner's OWN master-signed device list, exactly what a `FriendRequest`
        /// carries and for exactly the same reason: the requester has never been online
        /// with us, so `resolve()` alone returns the raw device id and misses the
        /// master-keyed friend row. The list makes attribution cryptographic instead of
        /// dependent on a prior meeting. Absent = a pre-carried-list client, and the
        /// receiver falls back to the resolver.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        device_list: Option<SignedDeviceList>,
    },

    #[serde(rename = "friend_remove")]
    FriendRemove,

    /// Multi-device: one device shares its accepted-friend list with a SIBLING of
    /// the same master, so a freshly-linked device learns its identity's friends
    /// and can join their DM rooms. Sent DIRECTLY, only after
    /// `resolver::same_identity` confirms the recipient is our own other device.
    /// Carries no message history, and is idempotent on the receiver.
    #[serde(rename = "friend_list_sync")]
    FriendListSync {
        #[serde(default)]
        friends: Vec<FriendListEntry>,
    },

    /// Multi-device: ask a SIBLING device to send us its friend list. The pull
    /// companion to `FriendListSync`, for the join-timing race where a freshly
    /// linked device's profile reached the established device before it was
    /// listening, so nothing was ever pushed. On detecting a sibling we both push
    /// and request. Verified-self only; the responder replies with `FriendListSync`.
    #[serde(rename = "friend_list_request")]
    FriendListRequest,

    /// Multi-device MANUAL state sync ("Sync from this device"). The DESTINATION
    /// device sends this to a chosen SOURCE sibling, which re-announces EVERY
    /// server it holds (`SiblingServerAnnounce` each) and re-shares its friend list.
    /// The on-demand equivalent of the reconnect re-announce, and the escape hatch
    /// for when automatic sibling sync did not converge. Verified-self only.
    #[serde(rename = "sibling_state_sync_request")]
    SiblingStateSyncRequest,

    // -- Multi-device sibling proof handshake (anti-mis-link) --

    /// Sent to an UNPROVEN peer that appeared in our own `inbox:{master}` room,
    /// challenging it to prove it holds our master private key. A friend-request
    /// sender lands in our inbox too but holds no master key and can never answer,
    /// which is what stops a stranger being mis-merged as our device. `nonce` is a
    /// fresh per-attempt value remembered in `pending_sibling_challenges`.
    #[serde(rename = "sib_prove_req")]
    SiblingProveRequest {
        #[serde(default)]
        nonce: String,
    },

    /// Response to a [`HavenMessage::SiblingProveRequest`]: the responder signs
    /// `hollow-sibling:{challenger_master}:{responder_device}:{nonce}` with the
    /// SHARED master key. The challenger verifies the signature binds to ITS OWN
    /// master and to the device id it challenged before it runs any sibling merge.
    /// `master_pubkey_b64` is the protobuf-encoded master pubkey (base64).
    #[serde(rename = "sib_prove_resp")]
    SiblingProveResponse {
        #[serde(default)]
        nonce: String,
        #[serde(default)]
        sig_b64: String,
        #[serde(default)]
        master_pubkey_b64: String,
    },

    // -- Multi-device link snapshot --

    /// (Empty to populated sibling) "Send me your full DB snapshot", carrying the
    /// requester's state summary so the populated device can show direction. It
    /// answers with `SiblingLinkAvailable`, then `LinkSnapshotKey` plus the bytes.
    #[serde(rename = "link_snapshot_request")]
    LinkSnapshotRequest {
        #[serde(default)]
        include_vault: bool,
        #[serde(default)]
        include_files: bool,
        #[serde(default)]
        msg_count: u32,
        #[serde(default)]
        friend_count: u32,
        #[serde(default)]
        has_profile: bool,
    },

    /// (Populated → empty) The one-time AES key/nonce to decrypt the snapshot bytes
    /// that follow on the `LinkSnapshot` binary stream. `link_id` matches the stream id.
    #[serde(rename = "link_snapshot_key")]
    LinkSnapshotKey {
        #[serde(default)]
        link_id: String,
        #[serde(default)]
        aes_key: String,
        #[serde(default)]
        aes_nonce: String,
    },

    /// (Populated → empty) The populated device declined the link request.
    #[serde(rename = "link_declined")]
    LinkDeclined,

    /// (Empty to populated) the empty device received and stashed the full snapshot.
    /// The sender holds its "sending" spinner until this lands: bytes leaving our
    /// WS channel are NOT proof of receipt. `link_id` matches the stream id.
    #[serde(rename = "link_snapshot_ack")]
    LinkSnapshotAck {
        #[serde(default)]
        link_id: String,
    },

    /// Lightweight notification hint for unsubscribed channels (topic routing).
    /// Sent via SendToRoom (0x03) so all room members receive it.
    #[serde(rename = "notif_hint")]
    ChannelNotificationHint {
        server_id: String,
        channel_id: String,
        #[serde(default)]
        message_id: String,
        #[serde(default)]
        has_everyone: bool,
        #[serde(default)]
        mentioned_names: Vec<String>,
        /// Kept for pre-0.9.1 receivers (any-reply flag); new receivers gate on
        /// `reply_to_sender` instead — a bare "is a reply" made the mentions-only
        /// level fire on every reply to anyone.
        #[serde(default)]
        is_reply: bool,
        /// MASTER id of the replied-to message's author (sender looks it up in
        /// its own store). Receivers compare against their own identity.
        #[serde(default)]
        reply_to_sender: Option<String>,
    },

    // -- Public channels --

    /// Plaintext channel message for public channels. Ed25519-signed but NOT
    /// MLS-encrypted. Broadcast via SendToRoom so guests (non-members) receive it.
    #[serde(rename = "pub_ch_msg")]
    PublicChannelMessage {
        server_id: String,
        channel_id: String,
        text: String,
        ts: i64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sig: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pk: Option<String>,
        mid: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reply_to: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        file_id: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        link_preview: Option<LinkPreviewRef>,
        /// Microsecond send stamp (Lamport). The v2 message signature binds it, so the
        /// receive path must persist the SENDER's value, never a local `ts*1000`
        /// default. `None` from a pre-0.8.3 sender, whose v1 signature omits it.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        order_us: Option<i64>,
        /// Attachment metadata for GUESTS, who cannot decrypt the MLS FileHeader
        /// (never bytes). The v2 signature binds `file_id`, not this blob, so receivers
        /// require `file_meta.fid == file_id`; members ignore it entirely and take
        /// their metadata from the MLS header.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        file_meta: Option<SyncFileMetaItem>,
    },

    #[serde(rename = "pub_ch_edit")]
    PublicChannelEdit {
        server_id: String,
        channel_id: String,
        mid: String,
        text: String,
        ts: i64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sig: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pk: Option<String>,
    },

    /// Attach (or clear) a link preview on an existing PUBLIC channel message.
    /// Plaintext twin of `MessageEnvelope::LinkPreviewSet` — see that variant
    /// for why this is not an edit. Issue #45.
    #[serde(rename = "pub_lp_set")]
    PublicLinkPreviewSet {
        server_id: String,
        channel_id: String,
        mid: String,
        /// `None` clears the card (an edit removed the URL).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        lp: Option<Box<LinkPreviewRef>>,
        /// The ORIGINAL message timestamp, not "now".
        ts: i64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sig: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pk: Option<String>,
    },

    #[serde(rename = "pub_ch_del")]
    PublicChannelDelete {
        server_id: String,
        channel_id: String,
        mid: String,
        ts: i64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sig: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pk: Option<String>,
    },

    #[serde(rename = "pub_ch_react")]
    PublicChannelAddReaction {
        server_id: String,
        channel_id: String,
        mid: String,
        emoji: String,
        ts: i64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sig: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pk: Option<String>,
    },

    #[serde(rename = "pub_ch_unreact")]
    PublicChannelRemoveReaction {
        server_id: String,
        channel_id: String,
        mid: String,
        emoji: String,
        ts: i64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sig: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pk: Option<String>,
    },

    // -- Guest sync (Public Channels Phase 3) --

    #[serde(rename = "pub_ch_list_req")]
    PublicChannelListRequest {
        server_id: String,
    },

    #[serde(rename = "pub_ch_list_resp")]
    PublicChannelListResponse {
        server_id: String,
        #[serde(default)]
        server_name: String,
        #[serde(default)]
        channels: Vec<PublicChannelEntry>,
        #[serde(default)]
        server_avatar_b64: String,
        /// 400x133 still THUMBNAIL of the server banner — never the full
        /// blob (this is a pre-join wire path to strangers).
        #[serde(default)]
        server_banner_thumb_b64: String,
    },

    #[serde(rename = "pub_ch_sync_req")]
    PublicChannelSyncRequest {
        server_id: String,
        channel_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        before_timestamp: Option<i64>,
    },

    #[serde(rename = "pub_ch_sync_resp")]
    PublicChannelSyncResponse {
        server_id: String,
        channel_id: String,
        #[serde(default)]
        messages: Vec<SyncMessageItem>,
        #[serde(default)]
        has_more: bool,
        #[serde(default, skip_serializing_if = "std::collections::HashMap::is_empty")]
        sender_profiles: std::collections::HashMap<String, SyncSenderProfile>,
    },

    #[serde(rename = "pub_ch_config")]
    PublicChannelConfigChanged {
        server_id: String,
        channel_id: String,
        is_public: bool,
        #[serde(default)]
        channel_name: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        category: Option<String>,
    },

    // -- Typing indicators --

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

    /// Per-device auto-download preference advert (issue #41 pre-negotiation),
    /// sent to DM-room peers on join and on settings change so the SENDER can skip
    /// pushing file bytes a gated receiver would only discard. `mb` is the
    /// advertiser's threshold for the TARGET device's identity (0 = off there); to
    /// own siblings it is the global threshold. Best-effort: the receive-side gate
    /// remains the enforcement, and an unknown pref pushes as before.
    #[serde(rename = "auto_dl_pref")]
    AutoDownloadPref {
        #[serde(default)]
        mb: u32,
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

    // -- File sharing --

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

    /// Negative answer to `FileRequest`: we know this file_id, you are entitled to
    /// its bytes, and we do not hold them, so the asker rotates to another holder
    /// instead of waiting out a timer and the card can say WHY.
    ///
    /// Sent ONLY behind the same entitlement gate the positive answer passes, and
    /// only when a row exists. A blocked requester, an unknown file_id and a
    /// non-entitled requester all keep getting silence: answering "unknown" would
    /// let anyone tell "this device holds a row for X" from "it does not", which
    /// is a membership leak.
    #[serde(rename = "file_unavail")]
    FileUnavailable {
        file_id: String,
        /// "gone" (evicted by the storage cap, downloads cleared, never landed) or
        /// "expired" (the sender's retention sweep marked it). Old clients ignore
        /// unknown variants, so this whole message is invisible to them.
        #[serde(default)]
        reason: String,
    },

    /// Plaintext FileHeader answering a FileRequest from a NON-member for a file in
    /// a PUBLIC channel. Members get the Olm-wrapped `MessageEnvelope::FileHeader`
    /// instead; this exists because a guest may hold no Olm session with the
    /// responder. The plaintext per-request AES key is consistent with the public
    /// trust model, since the relay already sees public-channel content. Receivers
    /// accept it ONLY for a file they explicitly requested, against the
    /// `pending_public_file_requests` receipt cap.
    #[serde(rename = "pub_file_hdr")]
    PublicFileHeader {
        file_id: String,
        name: String,
        ext: String,
        mime: String,
        size: u64,
        img: bool,
        #[serde(default)]
        w: Option<u32>,
        #[serde(default)]
        h: Option<u32>,
        #[serde(default)]
        mid: Option<String>,
        sid: String,
        cid: String,
        ts: i64,
        aes_key: String,
        aes_nonce: String,
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

    // -- WebRTC signaling --

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

    // -- Hollow Share data-channel signaling --
    //
    // Share negotiates a SECOND, dedicated peer connection per peer from the
    // STUN-only Share ICE config so its bytes never touch the relay (HOLLOW_PLAN
    // §7A). It gets its own variants rather than a flag on RtcOffer/RtcAnswer on
    // purpose: a client that predates the Share lane cannot parse these and DROPS
    // them at the envelope layer, instead of handing a Share offer to its single
    // data-channel layer, where the glare tiebreaker would tear down the live
    // hollow-data connection its DMs and file transfers depend on.

    /// SDP offer for the dedicated Hollow Share data channel.
    #[serde(rename = "rtc_share_offer")]
    RtcShareOffer {
        sdp: String,
        conn_id: String,
    },

    /// SDP answer for the dedicated Hollow Share data channel.
    #[serde(rename = "rtc_share_answer")]
    RtcShareAnswer {
        sdp: String,
        conn_id: String,
    },

    /// ICE candidate for the dedicated Hollow Share data channel.
    #[serde(rename = "rtc_share_ice")]
    RtcShareIceCandidate {
        candidate: String,
        sdp_mid: String,
        sdp_mline_index: u32,
        conn_id: String,
    },

    // -- Voice call signaling --

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

    /// Rebuild the call's media session from scratch, keeping the call alive.
    ///
    /// Sent when a link has been recovered but its transport was torn down
    /// underneath SFrame. Repairing cryptors in place on a rebuilt transport never
    /// once produced working audio in the field; a FRESH peer connection is exactly
    /// what a call start does. The receiver tears its peer connection down and
    /// treats the offer that follows as an initial one, so the call id, the SFrame
    /// key and the UI state survive and the user sees "Reconnecting", not a new ring.
    #[serde(rename = "call_media_restart")]
    CallMediaRestart { call_id: String },

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

    /// Mute/deafen state change during a 1:1 call (badge sync).
    #[serde(rename = "call_audio_state")]
    CallAudioState {
        #[serde(default)]
        call_id: String,
        #[serde(default)]
        muted: bool,
        #[serde(default)]
        deafened: bool,
    },

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

    /// Viewer to sharer: request or cancel receiving the call screen share (opt-in
    /// watching, issue #38 follow-up). The sharer only sends a screen offer after
    /// want=true.
    ///
    /// `viewer_width`/`viewer_height` are the viewer's largest display in physical
    /// pixels, so the sharer clamps THIS viewer's encoder to what they can show;
    /// 0x0 = unknown (old client) = no clamp. There is deliberately no per-viewer
    /// quality opt-out: the clamp already tracks the viewer's monitor, and a shared
    /// forwarder branch has no per-viewer encoder for one to apply to.
    #[serde(rename = "call_screen_watch")]
    CallScreenWatch {
        #[serde(default)]
        call_id: String,
        #[serde(default)]
        want: bool,
        #[serde(default)]
        viewer_width: u32,
        #[serde(default)]
        viewer_height: u32,
    },

    /// Call recording indicator (issue #53): the peer started/stopped a local
    /// recording. `recording` is authoritative — the Dart-facing signal-type
    /// string ("recording_start"/"recording_stop") is reconstructed from it.
    #[serde(rename = "call_recording_state")]
    CallRecordingState {
        #[serde(default)]
        call_id: String,
        #[serde(default)]
        recording: bool,
    },

    // -- Gossip relay tree --

    /// Gossip peer exchange: share neighbor list for topology discovery.
    #[serde(rename = "peer_exchange")]
    PeerExchange {
        server_id: String,
        peers: Vec<String>,
    },

    /// Request a peer's profile (they respond with ProfileUpdate).
    #[serde(rename = "profile_request")]
    ProfileRequest,

    /// Request custom emote bytes by content hash (answered with EmoteAssets
    /// for whatever subset the receiver has cached).
    #[serde(rename = "emote_request")]
    EmoteRequest {
        #[serde(default)]
        hashes: Vec<String>,
    },

    /// Content-addressed emote bytes: JSON map hash → base64 (same codec as
    /// showcase asset bundles — the receiver drops any entry whose bytes
    /// don't match their hash, so a hostile peer can't poison the cache).
    #[serde(rename = "emote_assets")]
    EmoteAssets {
        #[serde(default)]
        bundle_json: String,
        /// Hashes from the request we do NOT hold, so the asker rotates to another
        /// holder instead of waiting out its retry timer. The bundle may be empty when
        /// every asked hash lands here; older clients simply stay silent on a miss.
        #[serde(default)]
        missing: Vec<String>,
    },

    /// Ask an online peer to relay a third (offline) peer's profile.
    #[serde(rename = "profile_request_for")]
    ProfileRequestFor {
        #[serde(default)]
        target_peer_id: String,
    },

    /// Relayed profile for an offline peer (avatar included, no banner).
    #[serde(rename = "profile_relay")]
    ProfileRelay {
        #[serde(default)]
        source_peer_id: String,
        #[serde(default)]
        display_name: String,
        #[serde(default)]
        status: String,
        #[serde(default)]
        about_me: String,
        #[serde(default)]
        updated_at: i64,
        #[serde(default)]
        avatar_b64: String,
        #[serde(default)]
        twitch_username: String,
        /// The avatar hash the OWNER signed, carried explicitly rather than derived
        /// from `avatar_b64` because a relayer's cached blob can lag the owner's
        /// current one. Receivers verify the signature over THIS, then separately
        /// check the bytes against it and drop just the avatar on a mismatch.
        #[serde(default)]
        avatar_hash: String,
        /// The SUBJECT's own signature, forwarded verbatim by the relayer.
        ///
        /// This frame is the reason profiles are signed at all: `source_peer_id`
        /// is chosen by whoever sends the frame, and it is PLAINTEXT, so without
        /// this the relay or any co-present peer could rewrite any identity's
        /// name and avatar in our DB. REQUIRED — an unsigned relay is dropped.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        profile_sig: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        profile_pk: Option<String>,
    },

    // -- Voice channel coordination (plaintext for MLS epoch resilience) --
    // Plaintext rather than an MLS `MessageEnvelope`, so they survive epoch
    // staleness after a reconnect. SDP and ICE carry IPs and stay MLS-encrypted
    // with Olm fallback; only these state broadcasts are plaintext.

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

    /// Broadcast: recording state (on/off) in a voice channel (REC indicator,
    /// issue #53). Plaintext twin of `MessageEnvelope::VoiceChannelRecordingState`.
    #[serde(rename = "vc_recording_state")]
    VoiceChannelRecordingState {
        server_id: String,
        channel_id: String,
        #[serde(default)]
        recording: bool,
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

    // -- Hollow Share --
    // Share control lives in HavenMessage, not MessageEnvelope: MessageEnvelope
    // assumes a stable MLS group membership and a share swarm has none, since
    // anyone with the link joins and leaves freely.

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

// -- Hollow Share manifest --

/// Manifest describing a shared file, transmitted in the clear over the swarm
/// room: its SHA-256 IS the root_hash from the share link, so encrypting it
/// would make discovery impossible. The decryption key is in the link only.
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct DirectMessagePayload {
    pub text: String,
    #[serde(default)]
    pub ts: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sig: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pk: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mid: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reply_to: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub link_preview: Option<LinkPreviewRef>,
    /// Multi-device self fan-out: the OTHER party's MASTER id, set ONLY on the copy
    /// we echo to our OWN sibling device so it files the message under the correct
    /// conversation. Without it the sibling resolves the convo from the SENDER (us)
    /// and misfiles our outgoing DM as a conversation with ourselves. `None` on
    /// every normal send, which stays backward-compatible.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub convo: Option<String>,
    /// Microsecond send timestamp for stable cross-device ordering (Step 9C/C4).
    /// `None` from a pre-9C peer → receiver falls back to `ts * 1000`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub order_us: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct ChannelMessagePayload {
    pub sid: String,
    pub cid: String,
    pub text: String,
    pub ts: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sig: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pk: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mid: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reply_to: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub link_preview: Option<LinkPreviewRef>,
    /// Microsecond send timestamp for stable cross-device ordering (Step 9C/C4).
    /// `None` from a pre-9C peer → receiver falls back to `ts * 1000`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub order_us: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct FileHeaderPayload {
    pub fid: String,
    pub name: String,
    pub ext: String,
    pub mime: String,
    pub size: u64,
    pub chunks: u32,
    #[serde(default)]
    pub img: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub w: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub h: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mid: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sid: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cid: Option<String>,
    pub ts: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sig: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pk: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub aes_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub aes_nonce: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub vthumb: Option<VideoThumbRef>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub share_ref: Option<ShareRef>,
    /// Microsecond send stamp of the companion message (Lamport). The
    /// captionless-offline-image path creates the MESSAGE row from this header, and
    /// the v2 message signature binds `order_us`, so inserting with a local
    /// `ts*1000` default stores a row whose signature fails when re-served.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub order_us: Option<i64>,
    /// Base64 of the AES-encrypted file bytes, INLINED into the header. Only set
    /// when delivering a small image to an OFFLINE peer, so the relay buffers them
    /// alongside the message and the FCM fetch node can write the file to disk with
    /// no live stream. None on the normal online path, and for non-image or large
    /// files.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inline_bytes: Option<String>,
    /// Tiny blurred-placeholder thumbnail for images: base64 lossy WebP, max
    /// dimension ~32 px. Rendered blurred under the manual Download button when the
    /// auto-download gate keeps the real bytes off disk (issue #41). Receivers cap
    /// its size and only honor it for images.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thumb: Option<String>,
    /// True for recorded voice messages, which are exempt from the auto-download
    /// gate on every receive path. Pre-0.9.4 senders do not set it, so receivers
    /// ALSO match the recorder's filename pattern (`voice_{stamp}_{rand}.ogg`) as a
    /// legacy fallback (see `is_voice_message_name`).
    #[serde(default)]
    pub voice: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct ShardStorePayload {
    pub sid: String,
    pub cid: String,
    pub si: u16,
    pub sk: String,
    pub k: u16,
    pub m: u16,
    pub total_size: u64,
    pub tier: String,
    pub data: String,
    pub chunks: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
}

/// Envelope for the plaintext body inside an Encrypted message.
/// Legacy DMs are raw text (no JSON). New messages use this envelope.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "t")]
pub(crate) enum MessageEnvelope {
    #[serde(rename = "dm")]
    DirectMessage {
        #[serde(flatten)]
        inner: Box<DirectMessagePayload>,
    },
    #[serde(rename = "ch")]
    ChannelMessage {
        #[serde(flatten)]
        inner: Box<ChannelMessagePayload>,
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
    /// Multi-device sibling DM backfill batch: one conversation's missed DMs, BOTH
    /// directions (each item carries `mine`). `convo` is the OTHER party's master
    /// id, so the receiving sibling files these under that thread and not under the
    /// sender, which is its own other device. Only honored from `same_identity`.
    #[serde(rename = "dm_sib_sync")]
    DmSiblingSyncBatch {
        convo: String,
        messages: Vec<DmSyncItem>,
        /// If true, this convo has more messages — re-request it from `convo`'s high-water mark.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        has_more: Option<bool>,
    },
    /// Edit an existing message (channel or DM).
    #[serde(rename = "edit")]
    EditMessage {
        mid: String,
        text: String,
        /// Edit timestamp (millis since epoch).
        ts: i64,
        /// Ed25519 signature over the edit payload.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sig: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pk: Option<String>,
        /// Server ID (present for channel edits, absent for DM edits).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sid: Option<String>,
        /// Channel ID (present for channel edits, absent for DM edits).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cid: Option<String>,
    },
    /// Attach (or clear) a link preview on an existing message, WITHOUT touching
    /// its text and WITHOUT stamping it edited (issue #45).
    ///
    /// Re-signed over the SAME text / ts / reply_to / file_id / order_us with the
    /// new `lp_digest`, so the row keeps verifying, including through signed sync
    /// backfill, which carries the digest. `ts` is the ORIGINAL message timestamp,
    /// never "now": `edited_at` stays untouched, and no "(edited)" badge appears
    /// just because a preview arrived a second late.
    #[serde(rename = "lp_set")]
    LinkPreviewSet {
        mid: String,
        /// The card. `None` CLEARS it (used when an edit removes the URL).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        lp: Option<Box<LinkPreviewRef>>,
        /// The original message's timestamp — what the re-signature binds.
        ts: i64,
        /// Ed25519 signature over the re-signed message payload.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sig: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pk: Option<String>,
        /// Server ID (present for channel messages, absent for DMs).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sid: Option<String>,
        /// Channel ID (present for channel messages, absent for DMs).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cid: Option<String>,
    },
    /// Delete (hide) an existing message (channel or DM).
    #[serde(rename = "delete")]
    DeleteMessage {
        mid: String,
        /// Deletion timestamp (millis since epoch).
        ts: i64,
        /// Ed25519 signature over the deletion payload.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sig: Option<String>,
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
        mid: String,
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

    // -- File sharing --

    #[serde(rename = "file_hdr")]
    FileHeader {
        #[serde(flatten)]
        inner: Box<FileHeaderPayload>,
    },

    /// A single file chunk (base64-encoded data).
    #[serde(rename = "file_chunk")]
    FileChunk {
        fid: String,
        /// 0-based chunk index.
        idx: u32,
        /// Base64-encoded chunk data (up to 256KB decoded).
        data: String,
    },

    // -- Vault shard store --

    #[serde(rename = "shard_store")]
    ShardStore {
        #[serde(flatten)]
        inner: Box<ShardStorePayload>,
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

    // -- Vault shard retrieve --

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
        /// Multi-device: the sender's master-signed device list (Phase 6).
        #[serde(default)]
        device_list: Option<SignedDeviceList>,
        /// Blob staleness hashes — see HavenMessage::ProfileUpdate.
        #[serde(default)]
        avatar_hash: String,
        #[serde(default)]
        banner_hash: String,
        /// Showcase board JSON — None from old clients preserves the stored
        /// board; see HavenMessage::ProfileUpdate.
        #[serde(default)]
        showcase_board: Option<String>,
        /// Showcase asset bundle — see HavenMessage::ProfileUpdate.
        #[serde(default)]
        showcase_assets_b64: String,
        #[serde(default)]
        showcase_assets_hash: String,
        /// Avatar frame ID — see HavenMessage::ProfileUpdate.
        #[serde(default)]
        avatar_frame: Option<String>,
        /// Animated avatar/banner asset-rail hashes — see
        /// HavenMessage::ProfileUpdate.
        #[serde(default)]
        avatar_anim: Option<String>,
        #[serde(default)]
        banner_anim: Option<String>,
        /// Support credentials; see `HavenMessage::ProfileUpdate`.
        #[serde(default)]
        support_creds: Option<String>,
        /// The MASTER's signature over the credentials, REQUIRED on ingest; see
        /// `HavenMessage::ProfileUpdate`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        support_creds_sig: Option<String>,
        /// Owner's profile signature — see HavenMessage::ProfileUpdate.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        profile_sig: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        profile_pk: Option<String>,
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

    // -- 1:1 call signaling --

    /// One 1:1 call signal, carried INSIDE the Olm ciphertext.
    ///
    /// SECURITY: the `HavenMessage::Call*` variants used to ride the wire as bare
    /// plaintext frames, so the relay read every call's AES-128-GCM SFrame media
    /// key, every SDP and every ICE candidate, and could forge a CallAccept
    /// carrying a key of its own. The signal now travels as this envelope,
    /// decrypted only by the recipient device, and the plaintext receive arms
    /// REJECT instead of handling, so a relay-injected Call* frame is inert.
    ///
    /// Boxed because `HavenMessage` is a large enum and this envelope is reachable
    /// from the swarm event loop, whose tokio worker stack it has already blown.
    ///
    /// Only ever built for the `Call*` variants; the receiver whitelists them again
    /// on the way out (`voice_handler::handle_call_signal_message`).
    #[serde(rename = "call_sig")]
    CallSignal {
        signal: Box<HavenMessage>,
    },

    // -- Voice channel signaling --

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

    // -- Voice channel screen sharing --

    /// Targeted: SDP offer for a voice channel screen share (separate PC per
    /// direction). `origin` is the stream's ORIGINATOR; absent means the sender is
    /// the originator (old clients and direct legs).
    #[serde(rename = "vc_screen_offer")]
    VoiceChannelScreenOffer {
        sid: String,
        cid: String,
        sdp: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        origin: Option<Box<StreamOrigin>>,
    },

    /// Targeted: SDP answer for voice channel screen share. `origin` echoes
    /// the offer's origin back (viewer → sharer), see `StreamOrigin`.
    #[serde(rename = "vc_screen_answer")]
    VoiceChannelScreenAnswer {
        sid: String,
        cid: String,
        sdp: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        origin: Option<Box<StreamOrigin>>,
    },

    /// Targeted: ICE candidate for voice channel screen share. `origin` per
    /// `StreamOrigin` (sender's own share on role "outgoing", echo on
    /// "incoming").
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
        #[serde(default, skip_serializing_if = "Option::is_none")]
        origin: Option<Box<StreamOrigin>>,
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

    /// Targeted: viewer to sharer, request or cancel receiving their screen share
    /// (opt-in watching, issue #38). The sharer only sends a screen offer to peers
    /// that asked with want=true.
    ///
    /// `viewer_width`/`viewer_height` are the viewer's largest display in physical
    /// pixels, so the sharer clamps THIS viewer's encoder to what they can show;
    /// 0x0 = unknown (old client) = no clamp. There is deliberately no per-viewer
    /// quality opt-out: the clamp already tracks the viewer's monitor, and a shared
    /// forwarder branch has no per-viewer encoder for one to apply to.
    #[serde(rename = "vc_screen_watch")]
    VoiceChannelScreenWatch {
        sid: String,
        cid: String,
        #[serde(default)]
        want: bool,
        #[serde(default)]
        viewer_width: u32,
        #[serde(default)]
        viewer_height: u32,
        /// Viewer's self-reported route class to the sharer: "" = old/unknown client,
        /// "direct", "relay", or "direct_failed" (a re-watch after a forwarder
        /// failure). ADVISORY, and a wrong hint is corrected by the fallback ladder.
        /// Non-empty also marks a step-3-capable client: old viewers must never
        /// receive `vc_screen_assign`.
        #[serde(default)]
        route: String,
        /// This watcher offers to serve as a forwarder for THIS share (desktop with
        /// peer forwarding on). The sharer may pick it for relay-routed viewers and
        /// even self-assign it, which switches its display to its own embedded
        /// engine's egress leg. Absent (old client) = false = never a candidate.
        #[serde(default)]
        fwd_capable: bool,
        /// This viewer runs "Always relay calls": its media may only touch OPERATOR
        /// infrastructure (TURN or the infra forwarder), never another member's
        /// machine, so the sharer must skip the peer-forwarder rungs for it. Advisory
        /// like `route`; the viewer also hard-refuses peer-forwarder assignments
        /// locally. Absent (old client) = false.
        #[serde(default)]
        relay_private: bool,
        /// This watcher's embedded forwarder engine can ingest a 2-layer rid simulcast
        /// and select layers per viewer. Offered ONLY to forwarders that advertised
        /// it: an old engine would blindly fan BOTH layers' interleaved packets down
        /// one egress stream. Absent (old client) = false = single-layer ingest.
        #[serde(default)]
        fwd_simulcast: bool,
        /// This watcher's embedded engine can also FEED another forwarder, re-emitting
        /// the stream it already receives into a second forwarder's ingest so the
        /// sharer uploads one copy instead of two. The sharer only sends `feed_target`
        /// to a branch head that advertised this. Absent (old client) = false.
        #[serde(default)]
        fwd_feed: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
    },

    /// Targeted: sharer to viewer, assignment to a media forwarder. The viewer
    /// joins `fwd:{forwarder}` and attaches to the stream named by `origin`
    /// instead of a direct per-viewer PC; `forwarder` empty = revert to direct.
    /// Origin is spoof-guarded like the screen offer and must name the sender.
    #[serde(rename = "vc_screen_assign")]
    VoiceChannelScreenAssign {
        sid: String,
        cid: String,
        #[serde(default)]
        origin: Box<StreamOrigin>,
        #[serde(default)]
        forwarder: String,
        /// Feeder election (owner to branch head): "also feed your copy of my stream
        /// into forwarder `feed_target`". Empty or absent = stop feeding, or never
        /// asked. It rides the assign because that carries the same
        /// originator-authenticated trust (`inbound_origin_ok`): only the stream's
        /// originator may direct where its own stream goes.
        #[serde(default, skip_serializing_if = "String::is_empty")]
        feed_target: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
    },

    /// Targeted: feeder → sharer, the state of a delegated feed leg.
    ///
    /// The sharer keeps supplying the far forwarder's ingest itself until
    /// `up: true` arrives, so the handover is MAKE-BEFORE-BREAK; `up: false` (the
    /// leg died, or the far forwarder refused) makes it resume immediately.
    #[serde(rename = "vc_screen_feed_state")]
    VoiceChannelScreenFeedState {
        sid: String,
        cid: String,
        #[serde(default)]
        origin: Box<StreamOrigin>,
        /// The forwarder being fed.
        #[serde(default)]
        forwarder: String,
        #[serde(default)]
        up: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
    },

    // -- Voice channel camera --

    /// Targeted: renegotiation SDP offer (adding/removing video track).
    #[serde(rename = "vc_reneg_offer")]
    VoiceChannelRenegOffer {
        sid: String,
        cid: String,
        sdp: String,
        /// This renegotiation exists ONLY to apply an ICE restart, so the m-lines are
        /// unchanged and the receiver must NOT run its camera-track safety net for it.
        /// That net materialises a renderer for any video receiver it finds (because
        /// `onTrack` can stay silent when a transceiver is REUSED for a camera turning
        /// on), and on an ICE-restart re-offer the inactive video transceiver is still
        /// there, so the net invents a camera tile for a peer whose camera is off.
        /// Absent (old client) = false.
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        ice_restart: bool,
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

    /// Targeted: "our leg is broken, please re-offer it".
    ///
    /// The mesh gives the offer to the lexicographically LOWER peer id, so a leg
    /// that only the OTHER side can see as broken had no way to be rebuilt: the
    /// higher id would close its side and then wait forever for an offer nobody
    /// was going to send. This is the request that lets it ask. Payload-free: the
    /// sid/cid already ride the envelope, and the sender is the leg.
    #[serde(rename = "vc_leg_restart")]
    VoiceChannelLegRestart {
        sid: String,
        cid: String,
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

    /// Broadcast: recording state (on/off) in a voice channel (REC indicator,
    /// issue #53).
    #[serde(rename = "vc_recording_state")]
    VoiceChannelRecordingState {
        sid: String,
        cid: String,
        #[serde(default)]
        recording: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
    },

    // -- Media forwarder control plane (media forwarding step 3) --
    //
    // Client to forwarder ONLY, Olm-direct inside the dedicated
    // `fwd:{forwarder_peer_id}` relay room: never room-broadcast, never MLS, never
    // the vc_* lane, because the forwarder cannot satisfy is_vc_participant and
    // must never hold group keys. Registration requires `origin.peer` to be the
    // Olm-authenticated sender, and a viewer must be on the stream's allowlist to
    // attach. Both legs exchange COMPLETE SDPs (the forwarder has a fixed public
    // host candidate, so a NAT'd client reaches it without trickle). Tag `fwd_ice`
    // is RESERVED for a future trickle path; do not reuse it.

    /// Sharer → forwarder: register a stream and its viewer allowlist.
    /// Idempotent — re-registering replaces the allowlist.
    #[serde(rename = "fwd_stream_register")]
    FwdStreamRegister {
        #[serde(default)]
        origin: Box<StreamOrigin>,
        #[serde(default)]
        allowed_viewers: Vec<String>,
        /// Simulcast: viewers that should be served the LOW layer (rid "q") when the
        /// ingest carries one; everyone else rides the full layer (rid "f").
        /// Absent/empty = full for all. The choice is applied when a viewer's egress
        /// leg is created, so a re-register updates FUTURE attaches and never rewires
        /// a live leg.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        low_viewers: Vec<String>,
        /// Feeder election: the ONE peer the owner delegates to supply this stream's
        /// ingest in its place, so the originator uploads one copy instead of two.
        /// Empty or absent = nobody, exactly the pre-feeder owner-only rule.
        ///
        /// SECURITY: only the owner can name a feeder (this register is
        /// Olm-authenticated and `admit_register` pins origin == sender), and the grant
        /// is SUPPLY ONLY: `admit_owner_op` still gates auth and unregister. See
        /// `forwarder::dispatch::admit_ingest_offer`.
        #[serde(default, skip_serializing_if = "String::is_empty")]
        feeder: String,
    },

    /// Sharer → forwarder: incremental allowlist update for a registered
    /// stream (viewers joining/leaving the watch set).
    #[serde(rename = "fwd_stream_auth")]
    FwdStreamAuth {
        #[serde(default)]
        origin: Box<StreamOrigin>,
        #[serde(default)]
        add: Vec<String>,
        #[serde(default)]
        remove: Vec<String>,
    },

    /// Sharer → forwarder: tear down a stream (also implicit when the sharer
    /// leaves the fwd room or the ingest leg dies).
    #[serde(rename = "fwd_stream_unregister")]
    FwdStreamUnregister {
        #[serde(default)]
        origin: Box<StreamOrigin>,
    },

    /// Sharer → forwarder: complete SDP offer for the single ingest leg.
    #[serde(rename = "fwd_ingest_offer")]
    FwdIngestOffer {
        #[serde(default)]
        origin: Box<StreamOrigin>,
        #[serde(default)]
        sdp: String,
    },

    /// Forwarder → sharer: complete SDP answer for the ingest leg.
    #[serde(rename = "fwd_ingest_answer")]
    FwdIngestAnswer {
        #[serde(default)]
        origin: Box<StreamOrigin>,
        #[serde(default)]
        sdp: String,
    },

    /// Viewer → forwarder: request an egress leg for a stream we were
    /// assigned to (`vc_screen_assign`) and allowlisted for.
    #[serde(rename = "fwd_attach")]
    FwdAttach {
        #[serde(default)]
        origin: Box<StreamOrigin>,
    },

    /// Viewer → forwarder: tear down our egress leg.
    #[serde(rename = "fwd_detach")]
    FwdDetach {
        #[serde(default)]
        origin: Box<StreamOrigin>,
    },

    /// Forwarder → viewer: complete SDP offer for the egress leg (the
    /// forwarder offers, mirroring the viewer's existing answerer shape).
    #[serde(rename = "fwd_egress_offer")]
    FwdEgressOffer {
        #[serde(default)]
        origin: Box<StreamOrigin>,
        #[serde(default)]
        sdp: String,
    },

    /// Viewer → forwarder: complete SDP answer for the egress leg.
    #[serde(rename = "fwd_egress_answer")]
    FwdEgressAnswer {
        #[serde(default)]
        origin: Box<StreamOrigin>,
        #[serde(default)]
        sdp: String,
    },

    /// Forwarder to client: explicit refusal or failure. `code` is one of
    /// `full | over_budget | not_authorized | unknown_stream | shutting_down`
    /// (`forwarder::budget::FwdErrorCode`). Receivers fall back to direct+TURN:
    /// the forwarder is an availability helper, never authority.
    #[serde(rename = "fwd_error")]
    FwdError {
        #[serde(default)]
        origin: Box<StreamOrigin>,
        #[serde(default)]
        code: String,
        #[serde(default)]
        detail: String,
    },

    // -- Gossip relay tree --

    /// Broadcast metadata: notifies server members that a gossip file broadcast is in flight.
    #[serde(rename = "broadcast_meta")]
    BroadcastMeta {
        broadcast_id: String,
        origin: String,
        sid: String,
        cid: String,
        file_id: String,
        /// TTL, decremented on each relay hop.
        #[serde(default = "default_broadcast_ttl")]
        ttl: u8,
    },
}

impl MessageEnvelope {
    /// Returns the target peer ID if this is a targeted message.
    pub(crate) fn target(&self) -> Option<&str> {
        match self {
            Self::ChannelSyncBatch { target, .. }
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
            | Self::VoiceChannelScreenWatch { target, .. }
            | Self::VoiceChannelScreenAssign { target, .. }
            | Self::VoiceChannelRenegOffer { target, .. }
            | Self::VoiceChannelRenegAnswer { target, .. }
            | Self::VoiceChannelLegRestart { target, .. }
            | Self::VoiceChannelCameraState { target, .. }
            | Self::VoiceChannelRecordingState { target, .. } => target.as_deref(),
            Self::FileHeader { inner } => inner.target.as_deref(),
            Self::ShardStore { inner } => inner.target.as_deref(),
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
    /// Number of automatic re-requests already attempted after a failed decrypt /
    /// assembly. Bounded by FILE_DECRYPT_MAX_RETRIES so a genuinely corrupt source
    /// can't loop forever. In-memory only; reset whenever a fresh FileHeader arrives.
    pub retry_count: u32,
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

/// Sender profile embedded in public channel sync responses (one per unique sender per batch).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct SyncSenderProfile {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar_b64: Option<String>,
}

/// A single message in a sync batch.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct SyncMessageItem {
    pub s: String,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reply_to: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_id: Option<String>,
    /// File metadata for late joiners (so they can create file cards).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_meta: Option<SyncFileMetaItem>,
    /// Deletion timestamp (if message was deleted).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hidden_at: Option<i64>,
    /// Author's own deletion signature for `hidden_at`: the "ch-delete" proof
    /// stored in `message_deletions` at deletion time. Receivers REJECT-ABSENT,
    /// because a bare `hidden_at` in a sync batch is a censorship primitive: any
    /// responder, or a relay tampering with a plaintext public-channel batch,
    /// could hide arbitrary messages on the victim.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hidden_sig: Option<String>,
    /// Author public key (base64 protobuf) paired with `hidden_sig`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hidden_pk: Option<String>,
    /// Microsecond send timestamp, carried verbatim through backfill so a sender's
    /// same-millisecond burst sorts in true send order on every device. `None` from
    /// a pre-9C peer, which falls back to `ts * 1000`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub order_us: Option<i64>,
    /// Hex `link_preview_digest` of the message's link preview. Backfill
    /// verification needs the digest the sender signed, and this carries it on its
    /// own for rows where [`Self::lp`] is absent but a preview exists. `None` = no
    /// preview, or a pre-0.8.3 responder whose rows are v1-signed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lp_digest: Option<String>,
    /// The message's link preview, carried IN FULL, so a peer catching up through
    /// backfill can render the card its row's signature already binds.
    ///
    /// When both this and `lp_digest` are present the digest is RECOMPUTED from
    /// this preview and the wire's `lp_digest` is ignored: that is what makes the
    /// card signature-covered end to end, so a responder swapping in a phishing
    /// card fails the backfill check instead of having it stored.
    ///
    /// Boxed deliberately, like [`LinkPreviewRef::rich`]: these items are built,
    /// cloned and matched inside the swarm's async state machines.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lp: Option<Box<LinkPreviewRef>>,
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
    /// Present when this file is the thumbnail for a vault-stored video.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub vthumb: Option<VideoThumbRef>,
    /// Tiny base64 WebP placeholder (see `FileHeaderPayload::thumb`), so
    /// sync-backfilled cards render it too.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thumb: Option<String>,
}

/// Back-reference from a thumbnail image (sent over the image P2P path) to the
/// underlying video bytes in the vault. Carried in
/// `MessageEnvelope::FileHeader` and persisted alongside file metadata.
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

/// Back-reference to a hidden Share providing chunked P2P delivery for large
/// files (>34 MB) or progressive video streaming, so the receiver joins the
/// share swarm instead of waiting for a direct P2P binary stream.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShareRef {
    /// Root hash of the share manifest (hex, 64 chars).
    #[serde(default)]
    pub root_hash: String,
    /// AES-256-GCM encryption key for the share chunks (hex, 64 chars).
    #[serde(default)]
    pub key: String,
}

/// Identifies the ORIGINATOR of a (potentially forwarded) media stream
/// (reports/MEDIA_FORWARDING_PLAN.md).
///
/// Rides `vc_screen_offer` / `vc_screen_answer` / `vc_screen_ice` as
/// `Option<Box<StreamOrigin>>`; absent means the delivering sender IS the
/// originator. Receivers key attribution, dedup, watch-consent and SFrame
/// cryptor registration on `peer`, while transport stays keyed on the
/// delivering neighbor.
///
/// SECURITY: an inbound origin is accepted only when `peer` equals the
/// Olm/MLS-authenticated sender (offer direction) or ourselves (answer/ICE echo
/// of our own share); see `voice_handler::inbound_origin_ok`. Forwarder legs
/// ride the separate `fwd_*` namespace, never this lane.
///
/// BOXED per the `LinkPreviewRef::rich` rule below: inline envelope fields grow
/// every event-loop future frame and have overflowed the 2 MB tokio worker
/// stacks before.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub(crate) struct StreamOrigin {
    /// Originator DEVICE peer_id: routable, since VC signals key on the WS sender.
    #[serde(default)]
    pub peer: String,
    /// Stream kind: "screen" (cameras may join in a later phase).
    #[serde(default)]
    pub kind: String,
    /// Per-share-session random id (8 hex chars, minted at startScreenShare).
    /// A stop/restart mints a new id so stale state is distinguishable.
    #[serde(default)]
    pub stream: String,
}

/// A link preview for a URL embedded in a message.
///
/// Generated by the SENDER (OG tags plus a thumbnail compressed to lossy WebP)
/// and embedded in the outgoing envelope. Receivers render the card from these
/// fields and NEVER make an HTTP request to the previewed URL: that is a
/// privacy requirement, not a cache optimisation.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LinkPreviewRef {
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
    /// Social-post extras (issue #45), absent for a plain OpenGraph card.
    ///
    /// BOXED ON PURPOSE. A `LinkPreviewRef` sits BY VALUE inside
    /// `ChannelMessagePayload`, `DirectMessagePayload` and
    /// `HavenMessage::PublicChannelMessage`, all of which live in the swarm event
    /// loop's async state machines; five inline fields grew every one of those
    /// frames by ~80 bytes and overflowed the 2 MB tokio worker stack in debug
    /// builds. Behind one pointer the same data costs 8 bytes, so anything added
    /// here later belongs in [`RichCard`], never as another inline field.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rich: Option<Box<RichCard>>,
}

/// The extra fields a social-post card carries. See [`LinkPreviewRef::rich`]
/// for why this is a separate boxed struct rather than five more fields.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct RichCard {
    /// Card layout the SENDER chose: `Some("large")` for a social post
    /// (image on top, room for the full post text), `None` for the compact
    /// row. Adapter-enriched previews go large; plain OpenGraph stays compact.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    /// Post author line, e.g. `"Jane Doe (@jane)"`. Social adapters only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    /// Where this post's video lives. NEVER an iframe or a JS embed.
    ///
    /// Either a DIRECT `.mp4`/`.webm` the card can play inline on an explicit tap,
    /// or the media PAGE itself (a YouTube watch URL, an Instagram reel), which the
    /// card opens instead; the receiver tells them apart from the URL
    /// (`isDirectPlayableVideo` on the Dart side). Nothing is fetched to RENDER
    /// the card, and nothing ever autoplays.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub video_url: Option<String>,
    /// Video width, for the card's aspect ratio.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub video_w: Option<u32>,
    /// Video height, for the card's aspect ratio.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub video_h: Option<u32>,
}

impl RichCard {
    /// True when nothing was actually enriched — such a card is stored as
    /// `None` so it hashes (and serializes) identically to a plain preview.
    pub fn is_empty(&self) -> bool {
        self.kind.is_none()
            && self.author.is_none()
            && self.video_url.is_none()
            && self.video_w.is_none()
            && self.video_h.is_none()
    }

    /// `Some(boxed)` unless every field is absent.
    pub fn into_opt(self) -> Option<Box<Self>> {
        (!self.is_empty()).then(|| Box::new(self))
    }
}

/// A single DM in a DM sync batch.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct DmSyncItem {
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reply_to: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_id: Option<String>,
    /// File metadata for late joiners (so they can create file cards).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_meta: Option<SyncFileMetaItem>,
    /// Deletion timestamp (if message was deleted).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hidden_at: Option<i64>,
    /// Author's own "dm-delete" proof for `hidden_at` (0.8.4). See
    /// [`SyncMessageItem::hidden_sig`] — REJECT-ABSENT on apply.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hidden_sig: Option<String>,
    /// Author public key (base64 protobuf) paired with `hidden_sig`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hidden_pk: Option<String>,
    /// Microsecond send timestamp; see [`SyncMessageItem::order_us`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub order_us: Option<i64>,
    /// Hex link-preview digest; see [`SyncMessageItem::lp_digest`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lp_digest: Option<String>,
    /// The DM's link preview, carried in full. See [`SyncMessageItem::lp`] —
    /// same field, same recompute-the-digest rule, same reason it exists.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lp: Option<Box<LinkPreviewRef>>,
    /// Reactions on this message (synced alongside the message).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub reactions: Vec<SyncReactionItem>,
}

// ---------------------------------------------------------------------------
// Multi-Peer Fan-Out Sync Coordinator
// ---------------------------------------------------------------------------
//
// Channel sync is spread across ALL available peers rather than pulled from
// the one peer whose connection happened to be established first.

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
    /// How long to wait after the first peer connects, so more can join the spread.
    collection_window: std::time::Duration,
}

impl SyncCoordinator {
    pub(crate) fn new() -> Self {
        Self {
            pending: HashMap::new(),
            collection_window: std::time::Duration::from_millis(500),
        }
    }

    /// Registers a newly connected peer for a server's sync.
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

                // Each channel goes to a primary peer and, where there are enough peers, a
                // backup as well, so one silent peer cannot stall a channel's sync.
                let peers = &sync.available_peers;
                let peer_count = peers.len();
                let use_backup = peer_count >= 3;

                let mut assignments: HashMap<String, Vec<(String, i64)>> = HashMap::new();

                for (i, (cid, ts)) in sync.channels.iter().enumerate() {
                    let primary_idx = i % peer_count;
                    assignments
                        .entry(peers[primary_idx].clone())
                        .or_default()
                        .push((cid.clone(), *ts));

                    // Offset by half the peer count so primary and backup rarely coincide.
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

#[cfg(test)]
mod stream_origin_tests {
    use super::*;

    /// Old-client wire WITHOUT `origin` must parse to `origin: None`; pinned
    /// byte-for-byte because the harness cannot simulate a pre-rollout client.
    #[test]
    fn vc_screen_offer_without_origin_parses_to_none() {
        let json = r#"{"t":"vc_screen_offer","sid":"srv1","cid":"vc1","sdp":"v=0"}"#;
        match serde_json::from_str::<MessageEnvelope>(json) {
            Ok(MessageEnvelope::VoiceChannelScreenOffer { sid, cid, sdp, origin, .. }) => {
                assert_eq!(sid, "srv1");
                assert_eq!(cid, "vc1");
                assert_eq!(sdp, "v=0");
                assert!(origin.is_none());
            }
            other => panic!("unexpected parse result: {other:?}"),
        }
    }

    #[test]
    fn vc_screen_offer_with_origin_round_trips() {
        let env = MessageEnvelope::VoiceChannelScreenOffer {
            sid: "srv1".into(),
            cid: "vc1".into(),
            sdp: "v=0".into(),
            target: None,
            origin: Some(Box::new(StreamOrigin {
                peer: "12D3KooWSharer".into(),
                kind: "screen".into(),
                stream: "ab12cd34".into(),
            })),
        };
        let json = serde_json::to_string(&env).unwrap();
        assert!(json.contains(r#""origin""#), "origin missing from wire: {json}");
        match serde_json::from_str::<MessageEnvelope>(&json).unwrap() {
            MessageEnvelope::VoiceChannelScreenOffer { origin, .. } => {
                let o = origin.expect("origin survived the round trip");
                assert_eq!(o.peer, "12D3KooWSharer");
                assert_eq!(o.kind, "screen");
                assert_eq!(o.stream, "ab12cd34");
            }
            other => panic!("unexpected variant: {other:?}"),
        }
    }

    /// `origin: None` must serialize to EXACTLY today's wire bytes, with no
    /// `origin` key at all, so pre-step-2 clients see an unchanged protocol.
    #[test]
    fn vc_screen_signals_without_origin_keep_wire_bytes() {
        let offer = MessageEnvelope::VoiceChannelScreenOffer {
            sid: "s".into(), cid: "c".into(), sdp: "x".into(),
            target: None, origin: None,
        };
        let json = serde_json::to_string(&offer).unwrap();
        assert_eq!(json, r#"{"t":"vc_screen_offer","sid":"s","cid":"c","sdp":"x"}"#);

        let ice = MessageEnvelope::VoiceChannelScreenIce {
            sid: "s".into(), cid: "c".into(), candidate: "cand".into(),
            sdp_mid: "0".into(), sdp_mline_index: 0, role: "outgoing".into(),
            target: None, origin: None,
        };
        let json = serde_json::to_string(&ice).unwrap();
        assert!(!json.contains("origin"), "unexpected origin key: {json}");
    }

    /// Unknown extra fields inside `origin` must not break parsing (a NEWER
    /// client may extend StreamOrigin later).
    #[test]
    fn stream_origin_tolerates_unknown_fields() {
        let json = r#"{"t":"vc_screen_ice","sid":"s","cid":"c","candidate":"x","sdp_mid":"0","sdp_mline_index":0,"role":"incoming","origin":{"peer":"p1","kind":"screen","stream":"ff00ff00","future_field":true}}"#;
        match serde_json::from_str::<MessageEnvelope>(json) {
            Ok(MessageEnvelope::VoiceChannelScreenIce { origin, .. }) => {
                let o = origin.expect("origin parsed");
                assert_eq!(o.peer, "p1");
                assert_eq!(o.stream, "ff00ff00");
            }
            other => panic!("unexpected parse result: {other:?}"),
        }
    }
}

#[cfg(test)]
mod epoch_catchup_wire_tests {
    use super::*;

    /// Old-client `sync_request` (no `mls_epoch`) must parse to `None`; pinned
    /// byte-for-byte because the harness cannot simulate a pre-rollout client.
    #[test]
    fn sync_request_without_epoch_parses_to_none() {
        let json = r#"{"type":"sync_request","server_id":"srv1","state_vector_json":"{}"}"#;
        match serde_json::from_str::<HavenMessage>(json) {
            Ok(HavenMessage::SyncRequest { server_id, state_vector_json, mls_epoch }) => {
                assert_eq!(server_id, "srv1");
                assert_eq!(state_vector_json, "{}");
                assert!(mls_epoch.is_none());
            }
            other => panic!("unexpected parse result: {other:?}"),
        }
    }

    /// `mls_epoch: None` must serialize to EXACTLY today's wire bytes, with no
    /// `mls_epoch` key at all, so old clients see an unchanged protocol.
    #[test]
    fn sync_request_without_epoch_keeps_wire_bytes() {
        let msg = HavenMessage::SyncRequest {
            server_id: "s".into(),
            state_vector_json: "{}".into(),
            mls_epoch: None,
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert_eq!(json, r#"{"type":"sync_request","server_id":"s","state_vector_json":"{}"}"#);
    }

    #[test]
    fn sync_request_with_epoch_round_trips() {
        let msg = HavenMessage::SyncRequest {
            server_id: "s".into(),
            state_vector_json: "{}".into(),
            mls_epoch: Some(6),
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains(r#""mls_epoch":6"#), "epoch missing from wire: {json}");
        match serde_json::from_str::<HavenMessage>(&json).unwrap() {
            HavenMessage::SyncRequest { mls_epoch, .. } => assert_eq!(mls_epoch, Some(6)),
            other => panic!("unexpected variant: {other:?}"),
        }
    }

    /// Tag pin: the probe's wire name is part of the protocol.
    #[test]
    fn epoch_probe_round_trips_with_pinned_tag() {
        let msg = HavenMessage::MlsEpochProbe {
            server_id: "srv1".into(),
            channel_id: None,
            epoch: 4,
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert_eq!(json, r#"{"type":"mls_epoch_probe","server_id":"srv1","epoch":4}"#);
        match serde_json::from_str::<HavenMessage>(&json).unwrap() {
            HavenMessage::MlsEpochProbe { server_id, channel_id, epoch } => {
                assert_eq!(server_id, "srv1");
                assert!(channel_id.is_none());
                assert_eq!(epoch, 4);
            }
            other => panic!("unexpected variant: {other:?}"),
        }
    }

    /// Tag pin + subgroup form + entry ordering survives the round trip.
    #[test]
    fn commit_catchup_round_trips_with_pinned_tag() {
        let msg = HavenMessage::MlsCommitCatchup {
            server_id: "srv1".into(),
            channel_id: Some("chan1".into()),
            commits: vec![(5, "YWJj".into()), (6, "ZGVm".into())],
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.starts_with(r#"{"type":"mls_commit_catchup""#), "tag drifted: {json}");
        match serde_json::from_str::<HavenMessage>(&json).unwrap() {
            HavenMessage::MlsCommitCatchup { server_id, channel_id, commits } => {
                assert_eq!(server_id, "srv1");
                assert_eq!(channel_id.as_deref(), Some("chan1"));
                assert_eq!(commits, vec![(5, "YWJj".to_string()), (6, "ZGVm".to_string())]);
            }
            other => panic!("unexpected variant: {other:?}"),
        }
    }
}

#[cfg(test)]
mod screen_assign_route_tests {
    use super::*;

    /// Old-client `vc_screen_watch` (no `route`) parses with route = "", the
    /// "unknown client" marker that keeps `vc_screen_assign` away from it.
    #[test]
    fn screen_watch_without_route_defaults_empty() {
        let json = r#"{"t":"vc_screen_watch","sid":"s","cid":"c","want":true,"viewer_width":1920,"viewer_height":1080,"source_quality":false}"#;
        match serde_json::from_str::<MessageEnvelope>(json) {
            Ok(MessageEnvelope::VoiceChannelScreenWatch { want, route, viewer_width, .. }) => {
                assert!(want);
                assert_eq!(viewer_width, 1920);
                assert_eq!(route, "");
            }
            other => panic!("unexpected parse result: {other:?}"),
        }
    }

    #[test]
    fn screen_watch_route_round_trips() {
        let env = MessageEnvelope::VoiceChannelScreenWatch {
            sid: "s".into(), cid: "c".into(), want: true,
            viewer_width: 2560, viewer_height: 1440,
            route: "relay".into(), fwd_capable: false, relay_private: false,
            fwd_simulcast: false, fwd_feed: false,
            target: None,
        };
        let json = serde_json::to_string(&env).unwrap();
        match serde_json::from_str::<MessageEnvelope>(&json).unwrap() {
            MessageEnvelope::VoiceChannelScreenWatch { route, .. } => {
                assert_eq!(route, "relay");
            }
            other => panic!("unexpected variant: {other:?}"),
        }
    }

    /// Phase 2: `fwd_capable` + `relay_private` round-trip, and their absence
    /// parses as false, so an old watcher is never picked as a peer forwarder and
    /// only an explicit flag steers a viewer off the peer rungs.
    #[test]
    fn screen_watch_fwd_capable_round_trips_and_defaults_false() {
        let env = MessageEnvelope::VoiceChannelScreenWatch {
            sid: "s".into(), cid: "c".into(), want: true,
            viewer_width: 1920, viewer_height: 1080,
            route: "direct".into(), fwd_capable: true, relay_private: true,
            fwd_simulcast: true, fwd_feed: true,
            target: None,
        };
        let json = serde_json::to_string(&env).unwrap();
        match serde_json::from_str::<MessageEnvelope>(&json).unwrap() {
            MessageEnvelope::VoiceChannelScreenWatch {
                fwd_capable, relay_private, fwd_simulcast, fwd_feed, route, ..
            } => {
                assert!(fwd_capable);
                assert!(relay_private);
                assert!(fwd_simulcast);
                assert!(fwd_feed);
                assert_eq!(route, "direct");
            }
            other => panic!("unexpected variant: {other:?}"),
        }
        let old = r#"{"t":"vc_screen_watch","sid":"s","cid":"c","want":true,"viewer_width":1920,"viewer_height":1080,"source_quality":false,"route":"direct"}"#;
        match serde_json::from_str::<MessageEnvelope>(old).unwrap() {
            MessageEnvelope::VoiceChannelScreenWatch {
                fwd_capable, relay_private, fwd_simulcast, fwd_feed, ..
            } => {
                assert!(!fwd_capable, "absent fwd_capable must default to false");
                assert!(!relay_private, "absent relay_private must default to false");
                assert!(!fwd_simulcast, "absent fwd_simulcast must default to false");
                assert!(!fwd_feed, "absent fwd_feed must default to false");
            }
            other => panic!("unexpected variant: {other:?}"),
        }
    }

    #[test]
    fn screen_assign_round_trips_and_tag_pinned() {
        let env = MessageEnvelope::VoiceChannelScreenAssign {
            sid: "s".into(), cid: "c".into(),
            origin: Box::new(StreamOrigin {
                peer: "12D3KooWSharer".into(),
                kind: "screen".into(),
                stream: "ab12cd34".into(),
            }),
            forwarder: "12D3KooWFwd".into(),
            feed_target: String::new(),
            target: None,
        };
        let json = serde_json::to_string(&env).unwrap();
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["t"], serde_json::json!("vc_screen_assign"));
        assert!(
            !json.contains("feed_target"),
            "an assign with no feeder delegation must keep the old wire bytes: {json}"
        );
        match serde_json::from_str::<MessageEnvelope>(&json).unwrap() {
            MessageEnvelope::VoiceChannelScreenAssign { origin, forwarder, .. } => {
                assert_eq!(origin.peer, "12D3KooWSharer");
                assert_eq!(origin.stream, "ab12cd34");
                assert_eq!(forwarder, "12D3KooWFwd");
            }
            other => panic!("unexpected variant: {other:?}"),
        }
        // Revert-to-direct: empty forwarder survives (plain default field).
        let json = r#"{"t":"vc_screen_assign","sid":"s","cid":"c","origin":{"peer":"p"}}"#;
        match serde_json::from_str::<MessageEnvelope>(json).unwrap() {
            MessageEnvelope::VoiceChannelScreenAssign { forwarder, feed_target, .. } => {
                assert_eq!(forwarder, "");
                assert_eq!(feed_target, "", "absent feed_target must mean no delegation");
            }
            other => panic!("unexpected variant: {other:?}"),
        }
    }

    /// An ICE-restart re-offer is additive and self-describing: absent on the
    /// wire = a normal renegotiation (old client), and a normal renegotiation
    /// keeps the EXACT pre-flag bytes so nothing downstream sees a new key.
    #[test]
    fn reneg_offer_ice_restart_wire_compat() {
        match serde_json::from_str::<MessageEnvelope>(
            r#"{"t":"vc_reneg_offer","sid":"s","cid":"c","sdp":"v=0"}"#,
        )
        .unwrap()
        {
            MessageEnvelope::VoiceChannelRenegOffer { ice_restart, sdp, .. } => {
                assert!(!ice_restart, "absent ice_restart must default to false");
                assert_eq!(sdp, "v=0");
            }
            other => panic!("unexpected variant: {other:?}"),
        }
        let plain = MessageEnvelope::VoiceChannelRenegOffer {
            sid: "s".into(), cid: "c".into(), sdp: "v=0".into(),
            ice_restart: false, target: None,
        };
        let json = serde_json::to_string(&plain).unwrap();
        assert!(
            !json.contains("ice_restart"),
            "a normal reneg must keep the old wire bytes: {json}"
        );
        let restart = MessageEnvelope::VoiceChannelRenegOffer {
            sid: "s".into(), cid: "c".into(), sdp: "v=0".into(),
            ice_restart: true, target: None,
        };
        let json = serde_json::to_string(&restart).unwrap();
        match serde_json::from_str::<MessageEnvelope>(&json).unwrap() {
            MessageEnvelope::VoiceChannelRenegOffer { ice_restart, .. } => {
                assert!(ice_restart);
            }
            other => panic!("unexpected variant: {other:?}"),
        }
    }

    /// Feeder election: the delegation rides the assign, and the feeder's
    /// answer rides its own tag. Both additive — old clients drop what they
    /// don't know and simply never feed.
    #[test]
    fn feed_delegation_and_state_round_trip() {
        let env = MessageEnvelope::VoiceChannelScreenAssign {
            sid: "s".into(), cid: "c".into(),
            origin: Box::new(StreamOrigin {
                peer: "12D3KooWSharer".into(),
                kind: "screen".into(),
                stream: "ab12cd34".into(),
            }),
            forwarder: "12D3KooWHead".into(),
            feed_target: "12D3KooWVps".into(),
            target: None,
        };
        let json = serde_json::to_string(&env).unwrap();
        match serde_json::from_str::<MessageEnvelope>(&json).unwrap() {
            MessageEnvelope::VoiceChannelScreenAssign { forwarder, feed_target, .. } => {
                assert_eq!(forwarder, "12D3KooWHead");
                assert_eq!(feed_target, "12D3KooWVps");
            }
            other => panic!("unexpected variant: {other:?}"),
        }

        let env = MessageEnvelope::VoiceChannelScreenFeedState {
            sid: "s".into(), cid: "c".into(),
            origin: Box::new(StreamOrigin {
                peer: "12D3KooWSharer".into(),
                kind: "screen".into(),
                stream: "ab12cd34".into(),
            }),
            forwarder: "12D3KooWVps".into(),
            up: true,
            target: None,
        };
        let json = serde_json::to_string(&env).unwrap();
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["t"], serde_json::json!("vc_screen_feed_state"));
        match serde_json::from_str::<MessageEnvelope>(&json).unwrap() {
            MessageEnvelope::VoiceChannelScreenFeedState { forwarder, up, origin, .. } => {
                assert_eq!(forwarder, "12D3KooWVps");
                assert!(up);
                assert_eq!(origin.stream, "ab12cd34");
            }
            other => panic!("unexpected variant: {other:?}"),
        }
        // A minimal frame defaults to "down" — the safe direction: the owner
        // keeps supplying the far forwarder itself.
        match serde_json::from_str::<MessageEnvelope>(
            r#"{"t":"vc_screen_feed_state","sid":"s","cid":"c","origin":{"peer":"p"}}"#,
        ).unwrap() {
            MessageEnvelope::VoiceChannelScreenFeedState { up, forwarder, .. } => {
                assert!(!up, "absent up must default to down (owner keeps feeding)");
                assert_eq!(forwarder, "");
            }
            other => panic!("unexpected variant: {other:?}"),
        }
    }
}

#[cfg(test)]
mod fwd_envelope_tests {
    use super::*;

    fn origin() -> Box<StreamOrigin> {
        Box::new(StreamOrigin {
            peer: "12D3KooWSharer".into(),
            kind: "screen".into(),
            stream: "ab12cd34".into(),
        })
    }

    /// Every fwd_* wire tag pinned literally — the forwarder and clients ship
    /// on independent schedules, so a silent tag rename would strand deployed
    /// forwarders.
    #[test]
    fn fwd_tags_are_pinned() {
        let cases: Vec<(MessageEnvelope, &str)> = vec![
            (MessageEnvelope::FwdStreamRegister { origin: origin(), allowed_viewers: vec![], low_viewers: vec![], feeder: String::new() }, "fwd_stream_register"),
            (MessageEnvelope::FwdStreamAuth { origin: origin(), add: vec![], remove: vec![] }, "fwd_stream_auth"),
            (MessageEnvelope::FwdStreamUnregister { origin: origin() }, "fwd_stream_unregister"),
            (MessageEnvelope::FwdIngestOffer { origin: origin(), sdp: "v=0".into() }, "fwd_ingest_offer"),
            (MessageEnvelope::FwdIngestAnswer { origin: origin(), sdp: "v=0".into() }, "fwd_ingest_answer"),
            (MessageEnvelope::FwdAttach { origin: origin() }, "fwd_attach"),
            (MessageEnvelope::FwdDetach { origin: origin() }, "fwd_detach"),
            (MessageEnvelope::FwdEgressOffer { origin: origin(), sdp: "v=0".into() }, "fwd_egress_offer"),
            (MessageEnvelope::FwdEgressAnswer { origin: origin(), sdp: "v=0".into() }, "fwd_egress_answer"),
            (MessageEnvelope::FwdError { origin: origin(), code: "full".into(), detail: String::new() }, "fwd_error"),
        ];
        for (env, tag) in cases {
            let json = serde_json::to_string(&env).unwrap();
            let v: serde_json::Value = serde_json::from_str(&json).unwrap();
            assert_eq!(v["t"], *tag, "wrong tag on {json}");
        }
    }

    #[test]
    fn fwd_register_round_trips() {
        let env = MessageEnvelope::FwdStreamRegister {
            origin: origin(),
            allowed_viewers: vec!["12D3KooWViewerA".into(), "12D3KooWViewerB".into()],
            low_viewers: vec!["12D3KooWViewerB".into()],
            feeder: String::new(),
        };
        let json = serde_json::to_string(&env).unwrap();
        match serde_json::from_str::<MessageEnvelope>(&json).unwrap() {
            MessageEnvelope::FwdStreamRegister { origin, allowed_viewers, low_viewers, .. } => {
                assert_eq!(origin.peer, "12D3KooWSharer");
                assert_eq!(origin.stream, "ab12cd34");
                assert_eq!(allowed_viewers.len(), 2);
                assert_eq!(low_viewers, vec!["12D3KooWViewerB".to_string()]);
            }
            other => panic!("unexpected variant: {other:?}"),
        }
    }

    /// The simulcast field is additive: absent on the wire = empty (old
    /// sharer), and an empty set serializes to the EXACT pre-phase-3 bytes so
    /// deployed forwarders and clients never see an unknown key.
    #[test]
    fn fwd_register_low_viewers_wire_compat() {
        match serde_json::from_str::<MessageEnvelope>(
            r#"{"t":"fwd_stream_register","origin":{"peer":"p"},"allowed_viewers":["a"]}"#,
        ) {
            Ok(MessageEnvelope::FwdStreamRegister { low_viewers, .. }) => {
                assert!(low_viewers.is_empty());
            }
            other => panic!("unexpected parse result: {other:?}"),
        }
        let env = MessageEnvelope::FwdStreamRegister {
            origin: origin(),
            allowed_viewers: vec!["a".into()],
            low_viewers: vec![],
            feeder: String::new(),
        };
        let json = serde_json::to_string(&env).unwrap();
        assert!(
            !json.contains("low_viewers"),
            "empty low set must not appear on the wire: {json}"
        );
    }

    /// Feeder election is additive the same way: absent = nobody delegated,
    /// and an unelected stream serializes to the EXACT pre-feeder bytes, so a
    /// deployed forwarder never sees an unknown key.
    #[test]
    fn fwd_register_feeder_wire_compat() {
        match serde_json::from_str::<MessageEnvelope>(
            r#"{"t":"fwd_stream_register","origin":{"peer":"p"},"allowed_viewers":["a"]}"#,
        ) {
            Ok(MessageEnvelope::FwdStreamRegister { feeder, .. }) => {
                assert!(feeder.is_empty(), "absent feeder must default to nobody");
            }
            other => panic!("unexpected parse result: {other:?}"),
        }
        let env = MessageEnvelope::FwdStreamRegister {
            origin: origin(),
            allowed_viewers: vec!["a".into()],
            low_viewers: vec![],
            feeder: String::new(),
        };
        let json = serde_json::to_string(&env).unwrap();
        assert!(
            !json.contains("feeder"),
            "an unelected stream must not carry the key: {json}"
        );

        // And when elected it round-trips.
        let env = MessageEnvelope::FwdStreamRegister {
            origin: origin(),
            allowed_viewers: vec!["a".into()],
            low_viewers: vec![],
            feeder: "12D3KooWBranchHead".into(),
        };
        let json = serde_json::to_string(&env).unwrap();
        match serde_json::from_str::<MessageEnvelope>(&json).unwrap() {
            MessageEnvelope::FwdStreamRegister { feeder, .. } => {
                assert_eq!(feeder, "12D3KooWBranchHead");
            }
            other => panic!("unexpected variant: {other:?}"),
        }
    }

    #[test]
    fn fwd_error_round_trips() {
        let env = MessageEnvelope::FwdError {
            origin: origin(),
            code: "not_authorized".into(),
            detail: "viewer not on allowlist".into(),
        };
        let json = serde_json::to_string(&env).unwrap();
        match serde_json::from_str::<MessageEnvelope>(&json).unwrap() {
            MessageEnvelope::FwdError { code, detail, .. } => {
                assert_eq!(code, "not_authorized");
                assert_eq!(detail, "viewer not on allowlist");
            }
            other => panic!("unexpected variant: {other:?}"),
        }
    }

    /// A minimal frame with every field absent still parses (all
    /// `#[serde(default)]`) — an older/newer counterpart can always drop
    /// fields it doesn't know.
    #[test]
    fn fwd_absent_fields_default() {
        match serde_json::from_str::<MessageEnvelope>(r#"{"t":"fwd_attach"}"#) {
            Ok(MessageEnvelope::FwdAttach { origin }) => {
                assert_eq!(origin.peer, "");
                assert_eq!(origin.kind, "");
                assert_eq!(origin.stream, "");
            }
            other => panic!("unexpected parse result: {other:?}"),
        }
        match serde_json::from_str::<MessageEnvelope>(r#"{"t":"fwd_stream_auth","origin":{"peer":"p"}}"#) {
            Ok(MessageEnvelope::FwdStreamAuth { origin, add, remove }) => {
                assert_eq!(origin.peer, "p");
                assert!(add.is_empty());
                assert!(remove.is_empty());
            }
            other => panic!("unexpected parse result: {other:?}"),
        }
    }

    /// fwd envelopes are Olm-direct only — none may claim a broadcast target.
    #[test]
    fn fwd_envelopes_have_no_target() {
        let envs = [
            MessageEnvelope::FwdStreamRegister { origin: origin(), allowed_viewers: vec![], low_viewers: vec![], feeder: String::new() },
            MessageEnvelope::FwdIngestOffer { origin: origin(), sdp: "v=0".into() },
            MessageEnvelope::FwdEgressOffer { origin: origin(), sdp: "v=0".into() },
            MessageEnvelope::FwdError { origin: origin(), code: "full".into(), detail: String::new() },
        ];
        for env in envs {
            assert!(env.target().is_none(), "fwd envelope unexpectedly targetable");
        }
    }
}
