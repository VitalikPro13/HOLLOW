//! WebSocket client for the Hollow relay room router.
//!
//! One persistent WSS connection carries every room. Against a relay that offers it, a
//! session outlives the socket (RESUMABLE_SESSIONS_PLAN.md section 9, the rules in
//! `relay_session`): both sides count and ack stream frames, a dropped socket resumes
//! without a single rejoin, and a heartbeat with a deadline finds a dead path in seconds.

use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use futures_util::stream::{SplitSink, SplitStream};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::protocol::CloseFrame;
use tokio_tungstenite::tungstenite::Message;

use base64::Engine;

use super::relay_session::{
    self, Ask, AuthReply, Backoff, Class, Clocks, Entry, Established, Frame, Inbound, Liveness, Note, Outbound,
    Queued, Timing,
};

/// Max time for ONE socket write before the connection is declared wedged.
///
/// The liveness deadline cannot catch a peer whose KERNEL stays alive but whose
/// application stops reading: it ACKs with a zero TCP window, an in-flight
/// `SinkExt::send` pends FOREVER with no error, and while that await is pending
/// `tokio::select!` polls no other arm, so the liveness check can never run.
/// 30s because the largest frame, a 256 KB stream chunk, reaches the OS buffer
/// well inside it even on a dreadful uplink.
const WRITE_TIMEOUT: Duration = Duration::from_secs(30);

/// A goodbye (`end`, a close frame and its reply) is a courtesy: never worth a long wait.
const GOODBYE_WRITE_TIMEOUT: Duration = Duration::from_secs(2);

/// The kernel gives up on unacknowledged data after this long (Linux, Android) instead
/// of hiding a dead path behind 15 to 30 minutes of retransmits.
#[cfg(any(target_os = "linux", target_os = "android"))]
const TCP_USER_TIMEOUT: Duration = Duration::from_secs(20);

/// Queue entries written per loop turn, so reads and acks interleave with a long flush.
const PUMP_BATCH: usize = 64;

/// How long `suspend()` waits for every client to close.
const SUSPEND_MAX: Duration = Duration::from_secs(5);

/// The signature that ends a `frame_auth` seal ahead of its body.
const SEAL_SIG_LEN: usize = 64;

// -- Public types --

/// One signal parked on the relay's kill list: who deposited it, and its stamp.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KillSignalId {
    pub issuer: String,
    pub issued_at_ms: i64,
}

/// The `kill_ack` frame: the one signal turned away, or (`None`, after a wipe) all.
pub(crate) fn kill_ack_frame(signal: Option<&KillSignalId>) -> serde_json::Value {
    match signal {
        Some(s) => serde_json::json!({ "type": "kill_ack", "issuer": s.issuer, "issued_at_ms": s.issued_at_ms }),
        None => serde_json::json!({ "type": "kill_ack" }),
    }
}

/// The `topic_catchup` frame. `end` rides only when asked: a relay from before the
/// marker ignores it, and a request without it is byte for byte the old one.
pub(crate) fn topic_catchup_frame(room: &str, channel: &str, max_age_secs: i64, end: bool) -> serde_json::Value {
    let mut msg = serde_json::json!({
        "type": "topic_catchup",
        "room": room,
        "channel": channel,
        "max_age_secs": max_age_secs,
    });
    if end {
        msg["end"] = serde_json::Value::Bool(true);
    }
    msg
}

/// Commands sent from the swarm to the WebSocket client.
#[derive(Debug, Clone)]
pub enum WsCommand {
    JoinRoom { room_code: String },
    /// Join OUR OWN `inbox:{master}` room carrying an ownership PROOF, so the
    /// relay also replays the master-keyed mailbox (async friending): a request
    /// for an offline stranger is addressed to their MASTER, which no socket
    /// authenticates as. `proof` is our master-signed device list, and the relay
    /// checks the signature, the pubkey-to-master derivation, that OUR device is
    /// an un-revoked member of it, and that the room really is that master's.
    /// Someone ELSE's inbox is a plain `JoinRoom`.
    /// Join our own `inbox:` room showing our roster, from which the relay decides
    /// whether this device is one of the identity's (design ID-1R).
    JoinInbox { room_code: String, roster: crate::identity::roster::Roster },
    /// The newest door we hold for a server's room (`None` = none any more). Joins of
    /// that room prove it to the relay from now on; a joined room proves it at once.
    SetDoor { room_code: String, door: Option<DoorSecret> },
    LeaveRoom { room_code: String },
    /// Broadcast an encrypted message to all peers in a room.
    SendToRoom { room_code: String, data: Vec<u8> },
    /// A room broadcast that also reaches the peers a door-locked room hides: public
    /// channel traffic, which guests read.
    SendPublic { room_code: String, data: Vec<u8> },
    /// Send directly to a specific peer in a room (for shard transfers).
    SendDirect { room_code: String, target_peer: String, data: Vec<u8> },
    /// Send directly to a peer, flagged as carrying an inlined image. Identical
    /// to SendDirect except for a 0x08 frame, so the relay applies the image cap
    /// (3 per peer) to its offline buffer instead of the text cap.
    SendDirectImage { room_code: String, target_peer: String, data: Vec<u8> },
    /// Send binary data directly to a specific peer (for file/shard streaming).
    SendBinaryDirect { room_code: String, target_peer: String, data: Vec<u8> },
    /// Deliver `json` (a `MessageEnvelope`) to one device inside its Olm session.
    /// Never reaches the relay: the sealing stage hands it back to the node, which
    /// owns the sessions (`olm_lane`); `ticket` names it in the node loop's book of
    /// waiting carries.
    Carry { device: String, room: Option<String>, json: String, no_session: super::olm_lane::NoSession, ticket: Option<u64> },
    /// Subscribe to specific channel topics in a room (reduces fan-out).
    Subscribe { room_code: String, topics: Vec<String> },
    /// Broadcast to peers subscribed to a specific topic in a room.
    SendToRoomTopic { room_code: String, topic: String, data: Vec<u8> },
    /// Ask the relay which peers/rooms are actually alive.
    CheckPeers { peers: Vec<String>, rooms: Vec<String> },
    /// Ask the relay for the peers currently connected to a room, over the live
    /// WS connection (replaces the HTTP /bootstrap poll — no fresh TLS handshake).
    DiscoverPeers { room_code: String },
    /// Ask the relay for time-limited TURN credentials over the authenticated WS
    /// connection, so retries ride the normal reconnect machinery.
    GetTurnCredentials,
    /// Ask the relay which media forwarder it advertises. Authed WS only, re-sent
    /// on every reconnect; the id is static config, so no refresh timer.
    GetMediaForwarder,
    /// Claim a temporary nickname on the relay (RAM only). `master` is our MASTER
    /// identity, handed back on resolve so a stranger's friend request targets
    /// `inbox:{master}`, not our WS-auth DEVICE id whose inbox nobody joins.
    ClaimNickname { nickname: String, master: String, claim: super::nick_claim::NickClaim },
    /// Release the currently claimed nickname.
    ReleaseNickname,
    /// Resolve a nickname to a peer_id via the relay.
    ResolveNickname { nickname: String },
    /// Claim a multi-device link code on the relay (RAM only, 5-min TTL).
    ClaimLinkCode { code: String },
    /// Release the currently claimed link code.
    ReleaseLinkCode,
    /// Resolve a link code to a peer_id via the relay (consumed on resolve).
    ResolveLinkCode { code: String },
    /// Register FCM/APNs push token with the relay for offline notifications.
    RegisterPushToken { token: String, platform: String },
    /// Register per-server channel push preferences with the relay (RAM only).
    /// `prefs_json` = {"<server_room>": {"level": "all|mentions|nothing",
    /// "channels": {"<channel_id>": ...}}}. The relay checks these BEFORE firing
    /// a push, because an iOS alert push cannot be suppressed after delivery.
    SetPushPrefs { prefs_json: String },
    /// Targeted channel-message frame for an OFFLINE server member (0x09). The
    /// relay buffers `data` for replay to the member's background fetch node and
    /// fires a channel push filtered by that member's prefs and `mention`. Empty
    /// `data` = push trigger only, nothing to buffer.
    SendChannelDirect {
        room_code: String,
        target_peer: String,
        channel_id: String,
        mention: bool,
        data: Vec<u8>,
    },
    /// Register the opt-in offline-delivery setting with the relay. A RAM-side
    /// registry like push prefs, replayed automatically on every reconnect.
    /// Enabled = a bigger DM text/FileHeader window at the given retention.
    SetOfflineBuffer { enabled: bool, retention_secs: i64 },
    /// Register/refresh per-channel topic ring buffers for a server room whose
    /// owner enabled relay catch-up (`clear` = owner turned it off). Must be
    /// sent AFTER joining the room; re-sent once per connection by the swarm.
    /// `auth` signs it with the server's newest join-lock change key (`ring_auth`);
    /// without it the relay only keeps existing rings from idling out.
    SetTopicBuffer {
        room_code: String,
        channels: Vec<String>,
        retention_secs: i64,
        clear: bool,
        auth: Option<super::ring_auth::RingAuth>,
    },
    /// Ask the relay to replay one channel's buffered ring; the frames arrive as
    /// normal topic messages and ride the standard verify/dedup/merge path.
    /// `max_age_secs` > 0 replays only frames younger than that (the client
    /// passes its watermark age plus lookback, because MLS cannot decrypt
    /// consumed generations). 0 = everything still in retention. `end` asks the
    /// relay to mark the end of the replay ([`WsEvent::TopicCatchupDone`]).
    TopicCatchup { room_code: String, channel_id: String, max_age_secs: i64, end: bool },
    /// Park a destruction order for devices that are NOT connected. `blob` is
    /// opaque to the relay (base64 of the signed payload), capped at 2 KB, at most
    /// 16 targets per deposit. The relay hands it over on the target's next auth
    /// and keeps it until that device acks.
    KillDeposit { targets: Vec<String>, issued_at_ms: i64, blob: String },
    /// Delete OUR OWN parked entry. Sent after a wipe and after a PERMANENT
    /// rejection: without it the relay re-sends on every auth for a year.
    /// `signal` names the one turned away, so junk never takes a genuine order
    /// sharing its stamp with it; `None` clears them all.
    KillAck { signal: Option<KillSignalId> },
    /// Drop this device's push token from the relay (wipe step 5). No reply.
    UnregisterPushToken,
    /// Ask the relay for the join lock chains of these servers, as (server id, owner
    /// id or empty). One `LockChain` answers each.
    LockGet { locks: Vec<(String, String)> },
    /// Offer the relay a join lock chain (or its next links) for a server. Answered
    /// by a `LockChain` naming whether the relay took it.
    LockPut { server: String, owner: String, links: Vec<super::join_lock::LockLink> },
    /// File a user report with the relay. One-shot: never replayed by a fresh
    /// session (the relay also dedups per (reporter, target, category) via hashed keys).
    ReportUser { target: String, category: String },
}

/// Events received from the WebSocket relay, forwarded to the swarm.
#[derive(Debug, Clone)]
pub enum WsEvent {
    /// A fresh session: the first connect, after `SessionLost`, or every connect to a
    /// relay without sessions. Rooms are joined from here.
    Connected,
    /// The socket is gone but the relay holds our session: nothing is lost and sends
    /// keep queueing. `Resumed` or `SessionLost` follows.
    Suspended,
    /// The relay resumed our session on a new socket without a single rejoin. `gap`:
    /// frames fell out of its ring while we were away, so the catch-ups run.
    Resumed { gap: bool },
    /// The relay refused or forgot our session, or there never was one: purge and
    /// rebuild from the next `Connected`.
    SessionLost,
    /// A connect attempt is starting. `reconnecting` is true for every attempt after
    /// the very first.
    Connecting { reconnecting: bool },
    PeerJoined { room: String, peer_id: String },
    PeerLeft { room: String, peer_id: String },
    /// WE left a room, emitted locally when the Leave frame goes out (the relay
    /// never echoes our own leave). The swarm MUST purge its `ws_room_peers` for
    /// the room: no more PeerLeft/RoomMembers arrive for a room we are not in, so
    /// the frozen list stays forever and `ws_room_for_peer`'s first match can
    /// route targeted sends into it, which the relay then drops.
    LeftRoom { room: String },
    /// Whether the relay shows us the room: false only in a door-locked server room
    /// whose newest door it does not count us as holding. Sent right before the
    /// `RoomMembers` it came with.
    DoorStatus { room: String, proved: bool },
    RoomMembers { room: String, peers: Vec<String> },
    /// The relay replayed all it holds of a ring we asked for with `end`, every
    /// frame of it ahead of this event.
    TopicCatchupDone { room: String, channel: String },
    /// Encrypted message from another peer, routed through a room.
    Message { room: String, from: String, data: Vec<u8> },
    /// Direct message from a specific peer (shard transfers, etc.)
    DirectMessage { room: String, from: String, data: Vec<u8> },
    /// Binary data from a specific peer (file/shard streaming chunks).
    BinaryDirect { room: String, from: String, data: Vec<u8> },
    /// License key validation failed — do not auto-reconnect.
    LicenseError { reason: String },
    /// Room budget update — current count and server-side cap.
    RoomBudgetUpdate { joined: u32, limit: u32 },
    /// Server rejected a room join (cap hit).
    RoomCapHit { room: String },
    /// Response to CheckPeers — which peers/rooms are actually alive.
    PeerStatus { online: Vec<String>, active_rooms: Vec<String> },
    /// Response to DiscoverPeers — peers currently in the given room.
    DiscoveredPeers { room: String, peers: Vec<String> },
    /// Response to GetTurnCredentials — time-limited TURN credentials.
    TurnCredentials { username: String, password: String, ttl: u64, uris: Vec<String> },
    /// Response to GetMediaForwarder — the relay's advertised media forwarder.
    MediaForwarderInfo { peer_id: String, online: bool },
    /// Temporary nickname successfully claimed.
    NicknameClaimed { nickname: String },
    /// Temporary nickname released.
    NicknameReleased,
    /// Nickname operation error (claim failed or resolve failed).
    NicknameError { error: String, nickname: String },
    /// Nickname resolved to a peer_id. `master_id` is the claimer's MASTER, and
    /// `claim` its signature for this nickname and device; unchecked here.
    NicknameResolved { nickname: String, peer_id: String, master_id: String, claim: super::nick_claim::NickClaim },
    /// Multi-device link code successfully claimed.
    LinkCodeClaimed { code: String },
    /// Multi-device link code released.
    LinkCodeReleased,
    /// Link code operation error (claim failed or resolve failed).
    LinkCodeError { error: String, code: String },
    /// Link code resolved to the populated sibling's peer_id.
    LinkCodeResolved { code: String, peer_id: String },
    /// A destruction order the relay parked for this device, handed over right
    /// after auth. Opaque here: the swarm verifies it against OUR master.
    KillSignal { blob: String, signal: KillSignalId },
    /// The join lock chain the relay holds for a server (empty when none). `put` is
    /// set on the answer to our own `LockPut`: whether its newest lock is now the
    /// relay's. Unverified here: whoever reads it checks it back to the owner.
    LockChain { server: String, links: Vec<super::join_lock::LockLink>, put: Option<bool> },
}

impl WsEvent {
    /// Variant name only — for the swarm-loop stall sentinel. Never exposes
    /// payload (no rooms/peers/content in sentinel lines).
    pub(crate) fn kind(&self) -> &'static str {
        match self {
            Self::Connected => "Connected",
            Self::Suspended => "Suspended",
            Self::Resumed { .. } => "Resumed",
            Self::SessionLost => "SessionLost",
            Self::Connecting { .. } => "Connecting",
            Self::PeerJoined { .. } => "PeerJoined",
            Self::PeerLeft { .. } => "PeerLeft",
            Self::LeftRoom { .. } => "LeftRoom",
            Self::DoorStatus { .. } => "DoorStatus",
            Self::RoomMembers { .. } => "RoomMembers",
            Self::TopicCatchupDone { .. } => "TopicCatchupDone",
            Self::Message { .. } => "Message",
            Self::DirectMessage { .. } => "DirectMessage",
            Self::BinaryDirect { .. } => "BinaryDirect",
            Self::LicenseError { .. } => "LicenseError",
            Self::RoomBudgetUpdate { .. } => "RoomBudgetUpdate",
            Self::RoomCapHit { .. } => "RoomCapHit",
            Self::PeerStatus { .. } => "PeerStatus",
            Self::DiscoveredPeers { .. } => "DiscoveredPeers",
            Self::TurnCredentials { .. } => "TurnCredentials",
            Self::MediaForwarderInfo { .. } => "MediaForwarderInfo",
            Self::NicknameClaimed { .. } => "NicknameClaimed",
            Self::NicknameReleased => "NicknameReleased",
            Self::NicknameError { .. } => "NicknameError",
            Self::NicknameResolved { .. } => "NicknameResolved",
            Self::LinkCodeClaimed { .. } => "LinkCodeClaimed",
            Self::LinkCodeReleased => "LinkCodeReleased",
            Self::LinkCodeError { .. } => "LinkCodeError",
            Self::LinkCodeResolved { .. } => "LinkCodeResolved",
            Self::KillSignal { .. } => "KillSignal",
            Self::LockChain { .. } => "LockChain",
        }
    }
}

// -- Wire protocol --

fn is_false(v: &bool) -> bool { !*v }

#[derive(Serialize)]
#[serde(tag = "type")]
#[serde(rename_all = "snake_case")]
enum ClientMsg {
    /// Asks the relay for the challenge the auth signature covers.
    AuthHello,
    Auth {
        /// 2, or 3 with `session` and `in_h` for a relay that offered sessions; the
        /// signature covers the relay's challenge, its domain and every flag
        /// ([`auth_v2_message`], [`relay_session::auth_v3_message`]).
        v: u8,
        peer_id: String,
        public_key: String,
        timestamp: u64,
        nonce: String,
        domain: String,
        signature: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        license_key: Option<String>,
        #[serde(default, skip_serializing_if = "is_false")]
        fetch: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        session: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        in_h: Option<u64>,
    },
    Join {
        room: String,
        /// The joiner's own roster, for an `inbox:{master}` room: the relay folds it
        /// into what it holds for the master and lets in only a member.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        inbox_roster: Option<crate::identity::roster::Roster>,
        /// For a server room: that we hold its newest door ([`door_proof`]).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        door_proof: Option<String>,
    },
    Leave { room: String },
}

#[derive(Deserialize)]
#[serde(tag = "type")]
#[serde(rename_all = "snake_case")]
enum ServerMsg {
    PeerJoined { room: String, peer_id: String },
    PeerLeft { room: String, peer_id: String },
    /// `proved` only in a door-locked server room.
    Members { room: String, peers: Vec<String>, #[serde(default)] proved: Option<bool> },
    TopicCatchupDone { room: String, channel: String },
    // `active_rooms` is always empty now: the relay's room-activity probe was
    // removed (it let anyone holding two peer_ids ask whether their deterministic
    // DM room was live). Defaulted so a relay dropping the field deserializes.
    PeerStatus { online: Vec<String>, #[serde(default)] active_rooms: Vec<String> },
    DiscoveredPeers { room: String, peers: Vec<String> },
    TurnCredentials {
        #[serde(default)] username: String,
        #[serde(default)] password: String,
        #[serde(default)] ttl: u64,
        #[serde(default)] uris: Vec<String>,
        #[serde(default)] error: Option<String>,
    },
    MediaForwarder {
        #[serde(default)] peer_id: String,
        #[serde(default)] online: bool,
        #[serde(default)] error: Option<String>,
    },
    Error { error: String },
    NicknameClaimed { nickname: String },
    NicknameReleased,
    NicknameError { error: String, #[serde(default)] nickname: String },
    NicknameResolved {
        nickname: String,
        peer_id: String,
        #[serde(default)] master_id: String,
        #[serde(default)] master_key: String,
        #[serde(default)] ts: i64,
        #[serde(default)] sig: String,
    },
    LinkCodeClaimed { code: String },
    LinkCodeReleased,
    LinkCodeError { error: String, #[serde(default)] code: String },
    LinkCodeResolved { code: String, peer_id: String },
    KillSignal { #[serde(default)] blob: String, #[serde(default)] issued_at_ms: i64, #[serde(default)] issuer: String },
    KillDeposited { #[serde(default)] stored: u32 },
    LockChain {
        server: String,
        #[serde(default)] links: Vec<super::join_lock::LockLink>,
        #[serde(default)] put: Option<bool>,
    },
    /// The relay's count of our stream frames, answering a heartbeat.
    HbAck { h: u64 },
    Ack { h: u64 },
    /// The relay is about to restart: resume after this long.
    Reconnect { #[serde(default)] after_ms: u64 },
}

/// A server's door secret on its way to the socket that proves it; never printed.
#[derive(Clone)]
pub struct DoorSecret(pub zeroize::Zeroizing<[u8; 32]>);

impl std::fmt::Debug for DoorSecret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("DoorSecret(..)")
    }
}

/// What door proofs on one socket are made for: the relay's challenge and domain, our
/// id there, and the relay's door key (none from a relay without door rooms).
#[derive(Clone, Default)]
pub(crate) struct RelaySession {
    pub domain: String,
    pub nonce: String,
    pub peer_id: String,
    pub door_key: String,
}

/// The bytes a door proof's HMAC covers; pinned against the relay's
/// `door_room::proof_message` (relay-uws/test/test_door_room.cpp).
pub(crate) fn door_proof_message(session: &RelaySession, room: &str, door: &str) -> String {
    format!(
        "hollow-door1\n{}\n{}\n{}\n{room}\n{door}\n{}",
        session.domain, session.nonce, session.peer_id, session.door_key
    )
}

/// Proof that we hold `door` (a server's newest door secret) for this socket in
/// `room`: HMAC-SHA256 under the X25519 secret it shares with the relay's door key.
/// `None` without a relay key, or for a low-order one.
pub(crate) fn door_proof(session: &RelaySession, room: &str, door: &[u8; 32]) -> Option<String> {
    use hmac::Mac;
    let relay = super::sealed_box::key_from_text(&session.door_key)?;
    let shared = x25519_dalek::StaticSecret::from(*door).diffie_hellman(&x25519_dalek::PublicKey::from(relay));
    if !shared.was_contributory() {
        return None;
    }
    let door_text = super::sealed_box::key_to_text(&super::sealed_box::public_of(door));
    let mut mac = hmac::Hmac::<sha2::Sha256>::new_from_slice(shared.as_bytes()).ok()?;
    mac.update(door_proof_message(session, room, &door_text).as_bytes());
    Some(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes()))
}

// -- Real-time sessions and the FFI controls --

const ROOM_BUDGET_LIMIT: u32 = 2000;

/// Whether a real-time session (a DM call, a voice channel, a conference) is
/// live right now. Set from Dart when one starts, cleared when the last ends.
///
/// The reconnect policy has to know. Exponential backoff exists so a fleet does
/// not hammer a relay that is down, which is sound while the app is idle. It is
/// exactly wrong during a call, because a call has a DEADLINE: recovering a
/// lapsed media link needs an ICE restart, the offer carrying it rides this
/// socket, and the hold-open window is tens of seconds, so a ladder already at
/// 30 seconds leaves the socket asleep long after the network is back. The
/// policy is conditional rather than capped: normal backoff when idle, a steady
/// `Timing::realtime_retry` while a call is live.
static REALTIME_ACTIVE: AtomicBool = AtomicBool::new(false);

/// Set from the FFI when a call / voice channel / conference starts or ends.
pub fn set_realtime_active(active: bool) {
    REALTIME_ACTIVE.store(active, Ordering::Relaxed);
}

pub(crate) fn realtime_active() -> bool {
    REALTIME_ACTIVE.load(Ordering::Relaxed)
}

/// What the FFI asks of a running client.
#[derive(Debug)]
pub(crate) enum Control {
    /// Look at the connection now. `external`: from the app, which also ends a suspend;
    /// the client's own (a clock jump) never does.
    Nudge { reason: String, external: bool },
    Background(bool),
    Suspend(oneshot::Sender<()>),
}

/// Every running full client, one per relay; a closed one drops out on the next send.
static CONTROLS: Mutex<Vec<mpsc::UnboundedSender<Control>>> = Mutex::new(Vec::new());
static BACKGROUND: AtomicBool = AtomicBool::new(false);

fn controls() -> std::sync::MutexGuard<'static, Vec<mpsc::UnboundedSender<Control>>> {
    CONTROLS.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn tell_all(make: impl Fn() -> Control) {
    controls().retain(|tx| tx.send(make()).is_ok());
}

/// Look at the relay connection now: the app came to the foreground, the network
/// changed, the machine woke (RESUMABLE_SESSIONS_PLAN.md 9.6).
pub fn nudge(reason: &str) {
    let reason = match reason {
        "foreground" | "focus" | "network" | "wake" => reason,
        _ => "other",
    };
    tell_all(|| Control::Nudge { reason: reason.to_string(), external: true });
}

/// The app went to the background (`inactive`, slower heartbeat) or came back
/// (`active`, a `foreground` nudge).
pub fn set_background(background: bool) {
    BACKGROUND.store(background, Ordering::Relaxed);
    tell_all(|| Control::Background(background));
}

/// Flush, wait briefly for the relay's ack, close cleanly into the session's grace and
/// stay closed until the next nudge. Returns once every client closed.
pub async fn suspend() {
    let mut waits = Vec::new();
    controls().retain(|tx| {
        let (done, wait) = oneshot::channel();
        let open = tx.send(Control::Suspend(done)).is_ok();
        if open {
            waits.push(wait);
        }
        open
    });
    let _ = tokio::time::timeout(SUSPEND_MAX, futures_util::future::join_all(waits)).await;
}

// -- Public API --

/// Spawn the WebSocket client as a background task.
/// Returns a JoinHandle that runs until the command channel closes.
#[allow(clippy::too_many_arguments)]
pub fn spawn_ws_client(
    relay_url: String,
    peer_id: String,
    keypair_proto: Vec<u8>,
    pub_key_b64: String,
    license_key: Option<String>,
    fetch: bool,
    cmd_rx: mpsc::UnboundedReceiver<WsCommand>,
    event_tx: mpsc::UnboundedSender<WsEvent>,
) -> JoinHandle<()> {
    let (ctl_tx, ctl_rx) = mpsc::unbounded_channel();
    controls().push(ctl_tx);
    let dial = Dial { url: relay_url, peer_id, keypair_proto, pub_key_b64, license_key, fetch };
    let client = Client::new(dial, Timing::default(), event_tx, BACKGROUND.load(Ordering::Relaxed));
    tokio::spawn(client.run(cmd_rx, ctl_rx))
}

/// [`spawn_ws_client`] with its own timing and control channel, outside the FFI's reach.
#[cfg(test)]
#[allow(clippy::too_many_arguments)]
pub(crate) fn spawn_with(
    relay_url: String,
    peer_id: String,
    keypair_proto: Vec<u8>,
    pub_key_b64: String,
    timing: Timing,
    cmd_rx: mpsc::UnboundedReceiver<WsCommand>,
    event_tx: mpsc::UnboundedSender<WsEvent>,
    ctl_rx: mpsc::UnboundedReceiver<Control>,
) -> JoinHandle<()> {
    let dial = Dial { url: relay_url, peer_id, keypair_proto, pub_key_b64, license_key: None, fetch: false };
    tokio::spawn(Client::new(dial, timing, event_tx, false).run(cmd_rx, ctl_rx))
}

// -- The client --

/// What every connect attempt needs.
#[derive(Clone)]
struct Dial {
    url: String,
    peer_id: String,
    keypair_proto: Vec<u8>,
    pub_key_b64: String,
    license_key: Option<String>,
    fetch: bool,
}

/// What the client keeps about rooms across sockets and sessions.
#[derive(Default)]
struct Rooms {
    /// Rooms we are in: a fresh session joins each again.
    joined: HashSet<String>,
    /// The roster each own `inbox:` room was joined with ([`WsCommand::JoinInbox`]): a
    /// plain join on a new session owns nothing.
    inbox_rosters: HashMap<String, crate::identity::roster::Roster>,
    /// The newest door the node holds per server room, proved on every join of it.
    doors: HashMap<String, DoorSecret>,
    /// The latest topic set per room: the relay keeps subscriptions per session.
    subscriptions: HashMap<String, Vec<String>>,
    /// The latest offline-delivery opt-in, registered again by every fresh session.
    offline_optin: Option<(bool, i64)>,
    /// The room of the last join written, rolled back if the relay says the cap is hit.
    last_join_attempt: Option<String>,
}

type WsSink = SplitSink<WsStream, Message>;

struct Socket {
    write: WsSink,
    read: SplitStream<WsStream>,
    /// This socket's challenge: door proofs on a session-less socket, and after a reprove.
    door: RelaySession,
    /// The relay keeps a session for this socket: frames are counted and acked.
    session: bool,
    live: Liveness,
}

struct Attempt {
    fut: Pin<Box<dyn Future<Output = Result<Opened, ConnectError>> + Send>>,
    /// Racing a socket that is still being judged (make before break).
    racing: bool,
    started: Instant,
}

struct Suspending {
    until: Instant,
    done: oneshot::Sender<()>,
    asked: bool,
}

/// Why a socket went, which decides when the next one is tried.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Why {
    /// Closed or broken by the other end.
    Lost,
    /// Nothing heard after a heartbeat (the dead rule).
    Dead,
    SendFailed,
    /// The relay's drain hint ran out with the socket still open.
    Drain,
    Suspend,
}

struct Client {
    dial: Dial,
    timing: Timing,
    event_tx: mpsc::UnboundedSender<WsEvent>,
    /// The host we dialled; TURN URIs naming any other host are dropped.
    relay_host: String,
    rooms: Rooms,
    out: Outbound<WsCommand>,
    inbound: Inbound,
    /// The session the relay holds for us.
    sid: Option<String>,
    /// What this session's door proofs are made for: the challenge of the socket that
    /// minted it, until a `reprove` resume (section 9.8).
    session_door: Option<RelaySession>,
    /// The join each room's fresh-session replay wrote, and when: the node's identical
    /// join of that room right after (its Connected work echoing the replay) is dropped,
    /// once. Every other join is written, identical or not: a re-join is how the node
    /// asks for a fresh `members`.
    replayed_joins: HashMap<String, (String, Instant)>,
    socket: Option<Socket>,
    attempt: Option<Attempt>,
    reconnect_at: Option<Instant>,
    /// Set by the relay's drain hint: resume no earlier than this.
    drain_at: Option<Instant>,
    backoff: Backoff,
    background: bool,
    /// Closed on purpose until an external nudge.
    suspended: bool,
    suspending: Option<Suspending>,
    next_beat: Instant,
    clocks: Clocks,
    attempts: u64,
    license_busy_notified: bool,
    stopped: bool,
}

async fn read_next(
    socket: &mut Option<Socket>,
) -> Option<Result<Message, tokio_tungstenite::tungstenite::Error>> {
    match socket {
        Some(s) => s.read.next().await,
        None => std::future::pending().await,
    }
}

async fn poll_attempt(attempt: &mut Option<Attempt>) -> Result<Opened, ConnectError> {
    match attempt {
        Some(a) => (&mut a.fut).await,
        None => std::future::pending().await,
    }
}

impl Client {
    fn new(dial: Dial, timing: Timing, event_tx: mpsc::UnboundedSender<WsEvent>, background: bool) -> Self {
        let now = Instant::now();
        Self {
            relay_host: relay_auth_domain(&dial.url).unwrap_or_default(),
            next_beat: now + timing.heartbeat_every(background),
            clocks: Clocks { wall_ms: super::frame_auth::now_ms(), mono: now },
            dial,
            timing,
            event_tx,
            rooms: Rooms::default(),
            out: Outbound::default(),
            inbound: Inbound::default(),
            sid: None,
            session_door: None,
            replayed_joins: HashMap::new(),
            socket: None,
            attempt: None,
            reconnect_at: Some(now),
            drain_at: None,
            backoff: Backoff::default(),
            background,
            suspended: false,
            suspending: None,
            attempts: 0,
            license_busy_notified: false,
            stopped: false,
        }
    }

    async fn run(mut self, mut cmd_rx: mpsc::UnboundedReceiver<WsCommand>, mut ctl_rx: mpsc::UnboundedReceiver<Control>) {
        loop {
            let deadline = tokio::time::Instant::from_std(self.next_deadline());
            let pump = self.can_pump();
            tokio::select! {
                frame = read_next(&mut self.socket) => self.on_frame(frame).await,
                opened = poll_attempt(&mut self.attempt) => self.on_attempt(opened).await,
                cmd = cmd_rx.recv(), if self.takes_commands() => match cmd {
                    Some(cmd) => self.enqueue(cmd),
                    // The node dropped its sender: it is shutting down. Exit, or the
                    // socket would ping and reconnect forever (a per-restart leak).
                    None => {
                        self.shutdown().await;
                        return;
                    }
                },
                Some(ctl) = ctl_rx.recv() => {
                    if matches!(ctl, Control::Suspend(_)) {
                        // Suspend flushes what the node already handed over.
                        while self.takes_commands()
                            && let Ok(cmd) = cmd_rx.try_recv()
                        {
                            self.enqueue(cmd);
                        }
                    }
                    self.on_control(ctl).await;
                }
                _ = tokio::time::sleep_until(deadline) => self.on_timers().await,
                _ = std::future::ready(()), if pump => self.pump().await,
            }
            self.check_suspend().await;
            if self.stopped {
                return;
            }
        }
    }

    /// While a socket drains the queue, a burst waits in the node's channel rather than
    /// be pruned here; with no socket the bounds of section 9.4 apply.
    fn takes_commands(&self) -> bool {
        self.socket.is_none() || self.out.has_room()
    }

    fn next_deadline(&self) -> Instant {
        let mut at = self.next_beat;
        let mut consider = |t: Option<Instant>| {
            if let Some(t) = t {
                at = at.min(t);
            }
        };
        if let Some(s) = &self.socket {
            consider(s.live.dead_at(&self.timing));
            consider(s.live.probe_missed_at());
            if s.session {
                consider(self.inbound.ack_due_at(&self.timing));
            }
            consider(self.drain_at);
        } else if self.attempt.is_none() {
            consider(self.reconnect_at);
        }
        consider(self.suspending.as_ref().map(|s| s.until));
        at
    }

    fn notify(&self, notes: Vec<Note>) {
        for note in notes {
            let event = match note {
                Note::Suspended => WsEvent::Suspended,
                Note::Resumed { gap } => WsEvent::Resumed { gap },
                Note::SessionLost => WsEvent::SessionLost,
                Note::Connected => WsEvent::Connected,
            };
            let _ = self.event_tx.send(event);
        }
    }

    // -- Commands --

    /// Take a command from the node. Room state is remembered here, at once, so a fresh
    /// session joins what the node asked for even before the command reaches the wire.
    fn enqueue(&mut self, cmd: WsCommand) {
        let budget = match &cmd {
            WsCommand::SetDoor { room_code, door } => {
                let changed = remember_door(&mut self.rooms.doors, room_code, door.clone());
                if changed && door.is_some() && self.rooms.joined.contains(room_code) {
                    self.push(WsCommand::JoinRoom { room_code: room_code.clone() });
                }
                return;
            }
            WsCommand::JoinRoom { room_code } => {
                self.rooms.joined.insert(room_code.clone());
                true
            }
            WsCommand::JoinInbox { room_code, roster } => {
                self.rooms.inbox_rosters.insert(room_code.clone(), roster.clone());
                self.rooms.joined.insert(room_code.clone());
                true
            }
            WsCommand::LeaveRoom { room_code } => {
                self.rooms.joined.remove(room_code);
                self.rooms.subscriptions.remove(room_code);
                self.rooms.inbox_rosters.remove(room_code);
                true
            }
            WsCommand::Subscribe { room_code, topics } => {
                self.rooms.subscriptions.insert(room_code.clone(), topics.clone());
                false
            }
            WsCommand::SetOfflineBuffer { enabled, retention_secs } => {
                self.rooms.offline_optin = Some((*enabled, *retention_secs));
                false
            }
            _ => false,
        };
        if budget {
            let _ = self.event_tx.send(WsEvent::RoomBudgetUpdate {
                joined: self.rooms.joined.len() as u32,
                limit: ROOM_BUDGET_LIMIT,
            });
        }
        self.push(cmd);
    }

    fn push(&mut self, cmd: WsCommand) {
        let pruned = self.out.push(cmd, super::frame_auth::now_ms());
        if pruned > 0 {
            hollow_log!("[HOLLOW-WS] Outbound queue full: {pruned} unwritten frame(s) dropped");
        }
    }

    fn can_pump(&self) -> bool {
        let Some(s) = &self.socket else { return false };
        !self.attempt.as_ref().is_some_and(|a| a.racing)
            && self.out.has_unwritten()
            && (!s.session || self.out.can_write())
    }

    /// Write queued entries, a batch per loop turn. A frame gets its number before the
    /// write, so one that may have reached the relay is resent on resume rather than
    /// written again as new; on a session-less socket a failed entry goes back in
    /// front, and nothing behind it moves.
    async fn pump(&mut self) {
        for _ in 0..PUMP_BATCH {
            if !self.can_pump() {
                return;
            }
            let Some(entry) = self.out.pop() else { return };
            let Some((frame, room_state)) = self.render(&entry) else { continue };
            let session = self.socket.as_ref().is_some_and(|s| s.session);
            if session && relay_session::client_frame_counts(&frame) > 0 {
                self.out.record(frame.clone(), room_state);
            }
            let sent = match self.socket.as_mut() {
                Some(s) => bounded_send(&mut s.write, frame.to_message()).await,
                None => Err("no socket".to_string()),
            };
            if let Err(e) = sent {
                hollow_log!("[HOLLOW-WS] Send failed: {e}");
                if !session {
                    self.out.unpop(entry);
                }
                self.drop_socket(Why::SendFailed).await;
                return;
            }
        }
    }

    /// The frame an entry becomes on this socket, and whether it is room state a
    /// fresh session rebuilds. None: nothing to write.
    fn render(&mut self, entry: &Entry<WsCommand>) -> Option<(Frame, bool)> {
        let (cmd, replay) = match entry {
            Entry::Frame(f) => return Some((f.clone(), false)),
            Entry::Command(c) => (c, false),
            Entry::Replay(c) => (c, true),
        };
        match cmd {
            WsCommand::JoinRoom { room_code } => {
                self.render_join(room_code, None, replay).map(|t| (Frame::text(t), true))
            }
            WsCommand::JoinInbox { room_code, roster } => {
                self.render_join(room_code, Some(roster.clone()), replay).map(|t| (Frame::text(t), true))
            }
            WsCommand::LeaveRoom { room_code } => {
                self.replayed_joins.remove(room_code);
                let _ = self.event_tx.send(WsEvent::LeftRoom { room: room_code.clone() });
                let text = serde_json::to_string(&ClientMsg::Leave { room: room_code.clone() }).ok()?;
                Some((Frame::text(text), true))
            }
            WsCommand::Subscribe { .. } | WsCommand::SetOfflineBuffer { .. } => command_frame(cmd).map(|f| (f, true)),
            _ => command_frame(cmd).map(|f| (f, false)),
        }
    }

    /// The join frame for `room` on this socket, proving its door when we hold one. None
    /// for the node's first join of a room right after our replay wrote the identical one.
    fn render_join(
        &mut self,
        room: &str,
        inbox_roster: Option<crate::identity::roster::Roster>,
        replay: bool,
    ) -> Option<String> {
        let door_proof = self
            .rooms
            .doors
            .get(room)
            .and_then(|d| self.proof_door().and_then(|session| door_proof(session, room, &d.0)));
        let text = serde_json::to_string(&ClientMsg::Join { room: room.to_string(), inbox_roster, door_proof }).ok()?;
        let now = Instant::now();
        if replay {
            self.replayed_joins.insert(room.to_string(), (text.clone(), now));
        } else if let Some((replayed, at)) = self.replayed_joins.remove(room)
            && replayed == text
            && now.saturating_duration_since(at) <= self.timing.replay_echo
        {
            return None;
        }
        self.rooms.last_join_attempt = Some(room.to_string());
        Some(text)
    }

    fn proof_door(&self) -> Option<&RelaySession> {
        if self.sid.is_some() {
            self.session_door.as_ref()
        } else {
            self.socket.as_ref().map(|s| &s.door)
        }
    }

    /// A fresh session joins every room again, newest roster and door included, then
    /// subscribes and registers the opt-in, all ahead of whatever is queued.
    fn replay_rooms(&mut self) {
        let mut rooms: Vec<&String> = self.rooms.joined.iter().collect();
        rooms.sort_by_key(|room| (!self.rooms.inbox_rosters.contains_key(*room), (*room).clone()));
        let mut entries: Vec<Entry<WsCommand>> = rooms
            .into_iter()
            .map(|room| {
                Entry::Replay(match self.rooms.inbox_rosters.get(room) {
                    Some(roster) => WsCommand::JoinInbox { room_code: room.clone(), roster: roster.clone() },
                    None => WsCommand::JoinRoom { room_code: room.clone() },
                })
            })
            .collect();
        let mut subscriptions: Vec<(&String, &Vec<String>)> = self.rooms.subscriptions.iter().collect();
        subscriptions.sort();
        entries.extend(subscriptions.into_iter().map(|(room, topics)| {
            Entry::Replay(WsCommand::Subscribe { room_code: room.clone(), topics: topics.clone() })
        }));
        if let Some((enabled, retention_secs)) = self.rooms.offline_optin {
            entries.push(Entry::Replay(WsCommand::SetOfflineBuffer { enabled, retention_secs }));
        }
        let pruned = self.out.push_front(entries, super::frame_auth::now_ms());
        if pruned > 0 {
            hollow_log!("[HOLLOW-WS] Outbound queue full: {pruned} unwritten frame(s) dropped");
        }
        let _ = self.event_tx.send(WsEvent::RoomBudgetUpdate {
            joined: self.rooms.joined.len() as u32,
            limit: ROOM_BUDGET_LIMIT,
        });
    }

    /// After a `reprove` resume: join every room we hold a door for again, proving it
    /// for the new socket.
    fn reprove_doors(&mut self) {
        let mut rooms: Vec<String> =
            self.rooms.doors.keys().filter(|room| self.rooms.joined.contains(*room)).cloned().collect();
        rooms.sort();
        let entries = rooms
            .into_iter()
            .map(|room| {
                Entry::Command(match self.rooms.inbox_rosters.get(&room) {
                    Some(roster) => WsCommand::JoinInbox { room_code: room, roster: roster.clone() },
                    None => WsCommand::JoinRoom { room_code: room },
                })
            })
            .collect();
        self.out.push_front(entries, super::frame_auth::now_ms());
    }

    // -- Inbound --

    async fn on_frame(&mut self, frame: Option<Result<Message, tokio_tungstenite::tungstenite::Error>>) {
        let now = Instant::now();
        let msg = match frame {
            Some(Ok(msg)) => msg,
            Some(Err(e)) => {
                hollow_log!("[HOLLOW-WS] Read error: {e}");
                self.drop_socket(Why::Lost).await;
                return;
            }
            None => {
                hollow_log!("[HOLLOW-WS] Connection closed by server");
                self.drop_socket(Why::Lost).await;
                return;
            }
        };
        let Some(socket) = self.socket.as_mut() else { return };
        socket.live.heard(now);
        let session = socket.session;
        if self.attempt.as_ref().is_some_and(|a| a.racing) {
            hollow_log!("[HOLLOW-WS] The old socket answered first; the new one is dropped");
            self.attempt = None;
        }
        let ack_now = match msg {
            Message::Text(text) => {
                let due = session && self.inbound.received(relay_session::relay_frame_counts(&Frame::Text(text.clone())), now);
                self.on_text(&text);
                due
            }
            Message::Binary(data) => {
                let due = session && self.inbound.received(relay_session::relay_frame_counts(&Frame::Binary(data.clone())), now);
                dispatch_binary(&self.event_tx, &data);
                due
            }
            Message::Ping(data) => {
                self.write_control(Message::Pong(data)).await;
                false
            }
            Message::Close(frame) => {
                // The relay never closes silently (bad_license, auth timeout, moved).
                let reason = frame.as_ref().map(|f| f.reason.to_string()).unwrap_or_default();
                hollow_log!("[HOLLOW-WS] Connection closed by server: {reason}");
                self.drop_socket(Why::Lost).await;
                false
            }
            Message::Pong(_) | Message::Frame(_) => false,
        };
        if ack_now {
            self.send_ack().await;
        }
    }

    fn on_text(&mut self, text: &str) {
        let Ok(msg) = serde_json::from_str::<ServerMsg>(text) else { return };
        match msg {
            ServerMsg::HbAck { h } | ServerMsg::Ack { h } => {
                if self.socket.as_ref().is_some_and(|s| s.session) {
                    self.out.ack(h);
                }
            }
            ServerMsg::Reconnect { after_ms } => {
                let wait = relay_session::drain_wait(after_ms);
                hollow_log!("[HOLLOW-WS] The relay is restarting: resuming in {}ms", wait.as_millis());
                self.drain_at = Some(Instant::now() + wait);
            }
            other => handle_server_message(&self.event_tx, other, &mut self.rooms, &mut self.replayed_joins, &self.relay_host),
        }
    }

    // -- Writes outside the queue (uncounted) --

    /// A protocol frame on the current socket; false (and the socket dropped) on failure.
    async fn write_control(&mut self, msg: Message) -> bool {
        let Some(socket) = self.socket.as_mut() else { return false };
        match bounded_send(&mut socket.write, msg).await {
            Ok(()) => true,
            Err(e) => {
                hollow_log!("[HOLLOW-WS] Send failed: {e}");
                self.drop_socket(Why::SendFailed).await;
                false
            }
        }
    }

    async fn send_ack(&mut self) -> bool {
        let h = self.inbound.acked();
        self.write_control(relay_session::ack_frame(h).to_message()).await
    }

    /// A heartbeat: `hb` with our count on a session socket, a WebSocket ping on an
    /// older relay, which answers pings with pongs.
    async fn beat(&mut self) -> bool {
        let Some(socket) = self.socket.as_mut() else { return false };
        let msg = if socket.session {
            relay_session::hb_frame(self.inbound.acked()).to_message()
        } else {
            Message::Ping(vec![0x01].into())
        };
        socket.live.beat_sent(Instant::now());
        self.write_control(msg).await
    }

    // -- Timers --

    async fn on_timers(&mut self) {
        let now = Instant::now();
        if self.suspending.as_ref().is_some_and(|s| now >= s.until) {
            self.finish_suspend().await;
        }
        if self.socket.is_some() && self.drain_at.is_some_and(|at| now >= at) {
            self.drain_at = None;
            self.drop_socket(Why::Drain).await;
        }
        let dead = self.socket.as_ref().and_then(|s| s.live.dead_at(&self.timing)).is_some_and(|at| now >= at);
        if dead {
            hollow_log!("[HOLLOW-WS] Nothing heard for {}s after a heartbeat: the socket is dead", self.timing.dead_after.as_secs());
            self.drop_socket(Why::Dead).await;
        }
        let missed = self.socket.as_ref().and_then(|s| s.live.probe_missed_at()).is_some_and(|at| now >= at);
        if missed {
            if let Some(s) = self.socket.as_mut() {
                s.live.probe_given_up();
            }
            if self.attempt.is_none() {
                hollow_log!("[HOLLOW-WS] No answer to the probe: racing a new socket");
                self.start_attempt(true);
            }
        }
        let ack_due = self.socket.as_ref().is_some_and(|s| s.session)
            && self.inbound.ack_due_at(&self.timing).is_some_and(|at| now >= at);
        if ack_due {
            self.send_ack().await;
        }
        if now >= self.next_beat {
            self.on_beat(now).await;
        }
        let reconnect =
            self.socket.is_none() && self.attempt.is_none() && self.reconnect_at.is_some_and(|at| now >= at);
        if reconnect {
            self.reconnect_at = None;
            self.start_attempt(false);
        }
    }

    /// The heartbeat tick: also where a machine that slept is noticed, because the
    /// monotonic clock stood still while the wall clock ran (section 9.5).
    async fn on_beat(&mut self, now: Instant) {
        let reading = Clocks { wall_ms: super::frame_auth::now_ms(), mono: now };
        let slept = self.clocks.slept(&reading, &self.timing);
        self.clocks = reading;
        self.next_beat = now + self.timing.heartbeat_every(self.background);
        if slept {
            hollow_log!("[HOLLOW-WS] The clocks drifted apart: the machine slept");
            self.nudge("wake", false).await;
        } else if self.socket.is_some() {
            self.beat().await;
        }
    }

    // -- Controls --

    async fn on_control(&mut self, ctl: Control) {
        match ctl {
            Control::Nudge { reason, external } => self.nudge(&reason, external).await,
            Control::Background(background) => {
                self.background = background;
                self.next_beat = Instant::now() + self.timing.heartbeat_every(background);
                if self.socket.as_ref().is_some_and(|s| s.session) {
                    let frame = if background { relay_session::INACTIVE } else { relay_session::ACTIVE };
                    if !self.write_control(Message::Text(frame.into())).await {
                        return;
                    }
                }
                if !background {
                    self.nudge("foreground", true).await;
                }
            }
            Control::Suspend(done) => self.begin_suspend(done),
        }
    }

    /// Section 9.6: a socket that spoke in the quiet window is fine; otherwise probe it
    /// and race a new socket on a miss. With no socket, connect now. Every nudge resets
    /// the backoff.
    async fn nudge(&mut self, reason: &str, external: bool) {
        if self.suspended && !external {
            return;
        }
        if external {
            self.suspended = false;
            if let Some(s) = self.suspending.take() {
                let _ = s.done.send(());
            }
        }
        self.backoff.reset();
        let now = Instant::now();
        match &self.socket {
            Some(socket) => {
                if self.attempt.is_some() || !socket.live.wants_probe(now, &self.timing) {
                    return;
                }
                hollow_log!("[HOLLOW-WS] Nudge ({reason}): probing the socket");
                if self.beat().await
                    && let Some(socket) = self.socket.as_mut()
                {
                    socket.live.probe_sent(now, &self.timing);
                }
            }
            None => match &self.attempt {
                Some(a) if now.saturating_duration_since(a.started) >= self.timing.nudge_quiet => {
                    hollow_log!("[HOLLOW-WS] Nudge ({reason}): starting the connect over");
                    self.attempt = None;
                    self.start_attempt(false);
                }
                Some(_) => {}
                None => {
                    hollow_log!("[HOLLOW-WS] Nudge ({reason}): connecting now");
                    self.drain_at = None;
                    self.reconnect_at = Some(now);
                }
            },
        }
    }

    fn begin_suspend(&mut self, done: oneshot::Sender<()>) {
        if self.socket.is_none() {
            self.suspended = true;
            self.attempt = None;
            self.reconnect_at = None;
            self.drain_at = None;
            hollow_log!("[HOLLOW-WS] Suspended with no socket open");
            let _ = done.send(());
            return;
        }
        if self.attempt.as_ref().is_some_and(|a| a.racing) {
            self.attempt = None;
        }
        if let Some(previous) = self.suspending.take() {
            let _ = previous.done.send(());
        }
        self.suspending = Some(Suspending { until: Instant::now() + self.timing.suspend_wait, done, asked: false });
    }

    /// Once the queue is written and the relay acked it all (or right away without a
    /// session), close; a heartbeat asks the relay for its count instead of waiting for
    /// its ack timer.
    async fn check_suspend(&mut self) {
        let Some(session) = self.socket.as_ref().map(|s| s.session) else { return };
        let Some(asked) = self.suspending.as_ref().map(|s| s.asked) else { return };
        if self.out.has_unwritten() {
            return;
        }
        if !session || self.out.all_acked() {
            self.finish_suspend().await;
        } else if !asked {
            if let Some(s) = self.suspending.as_mut() {
                s.asked = true;
            }
            self.beat().await;
        }
    }

    async fn finish_suspend(&mut self) {
        let unacked_in = self.socket.as_ref().is_some_and(|s| s.session) && self.inbound.ack_due_at(&self.timing).is_some();
        if unacked_in && !self.send_ack().await {
            return;
        }
        if self.socket.is_some() {
            self.drop_socket(Why::Suspend).await;
        } else if let Some(s) = self.suspending.take() {
            self.suspended = true;
            let _ = s.done.send(());
        }
        hollow_log!("[HOLLOW-WS] Suspended: closed until the next nudge");
    }

    // -- Sockets --

    fn start_attempt(&mut self, racing: bool) {
        if !racing {
            let _ = self.event_tx.send(WsEvent::Connecting { reconnecting: self.attempts > 0 });
            hollow_log!("[HOLLOW-WS] Connecting to {}...", self.dial.url);
        }
        self.attempts += 1;
        let held = self.sid.clone().map(|sid| (sid, self.inbound.h()));
        let fut = open_socket(self.dial.clone(), true, held, self.timing.clone());
        self.attempt = Some(Attempt { fut: Box::pin(fut), racing, started: Instant::now() });
    }

    async fn on_attempt(&mut self, result: Result<Opened, ConnectError>) {
        let Some(attempt) = self.attempt.take() else { return };
        let held = self.sid.is_some();
        let judged = result.and_then(|opened| {
            relay_session::judge(&opened.ask, held, opened.reply)
                .map(|established| (opened.stream, opened.door, established))
                .map_err(ConnectError::Other)
        });
        let (stream, door, established) = match judged {
            Ok(up) => up,
            Err(e) => {
                hollow_log!("[HOLLOW-WS] Connection failed: {e}");
                if attempt.racing {
                    // The old socket is still being judged; the dead rule decides it.
                    return;
                }
                // A busy key is still OUR key: the holder is usually our own ghost
                // socket or a sibling device, so keep retrying and tell the UI once
                // per outage; only a refused key stops the client. Only the relay's
                // exact refusal codes count, never text that merely mentions a license.
                match e {
                    ConnectError::License(LicenseRefusal::InUse) => {
                        if !self.license_busy_notified {
                            self.license_busy_notified = true;
                            let _ = self.event_tx.send(WsEvent::LicenseError { reason: LicenseRefusal::InUse.code().into() });
                        }
                    }
                    ConnectError::License(refusal) => {
                        hollow_log!("[HOLLOW-WS] License refused, not retrying");
                        let _ = self.event_tx.send(WsEvent::LicenseError { reason: refusal.code().into() });
                        self.stopped = true;
                        return;
                    }
                    ConnectError::Other(_) => {}
                }
                if !held {
                    let _ = self.event_tx.send(WsEvent::SessionLost);
                }
                self.schedule(Why::Lost);
                return;
            }
        };
        if attempt.racing {
            // The new socket answered first; the old one goes quietly and the relay
            // moves the session over.
            if let Some(old) = self.socket.take() {
                self.forget_socket(&old);
            }
            self.notify(relay_session::on_drop(held));
        }
        self.establish(stream, door, established).await;
    }

    async fn establish(&mut self, stream: WsStream, door: RelaySession, established: Established) {
        let now = Instant::now();
        let (write, read) = stream.split();
        match established {
            Established::Fresh { sid, lost } => {
                if lost {
                    self.lose_session();
                }
                self.notify(relay_session::on_established(&Established::Fresh { sid: sid.clone(), lost }));
                let session = sid.is_some();
                self.session_door = sid.as_ref().map(|_| door.clone());
                self.sid = sid;
                self.inbound = Inbound::default();
                self.replayed_joins.clear();
                self.socket = Some(Socket { write, read, door, session, live: Liveness::new(now) });
                self.up(now);
                hollow_log!("[HOLLOW-WS] Connected and authenticated ({})", if session { "new session" } else { "no session" });
                self.replay_rooms();
                if self.background && session {
                    self.write_control(Message::Text(relay_session::INACTIVE.into())).await;
                }
            }
            Established::Resumed { h, gap, reprove } => {
                let Some(resend) = self.out.resume(h) else {
                    hollow_log!("[HOLLOW-WS] The relay resumed numbers that are not ours: starting a fresh session");
                    self.notify(relay_session::on_resume_refused());
                    self.lose_session();
                    self.backoff.reset();
                    self.reconnect_at = Some(now);
                    return;
                };
                self.notify(relay_session::on_established(&Established::Resumed { h, gap, reprove }));
                if reprove {
                    self.session_door = Some(door.clone());
                }
                self.socket = Some(Socket { write, read, door, session: true, live: Liveness::new(now) });
                self.up(now);
                hollow_log!(
                    "[HOLLOW-WS] Session resumed: {} frame(s) to send again{}",
                    resend.len(),
                    if gap { ", the relay's ring had a gap" } else { "" }
                );
                for frame in resend {
                    if !self.write_control(frame.to_message()).await {
                        return;
                    }
                }
                if reprove {
                    self.reprove_doors();
                }
            }
        }
    }

    fn up(&mut self, now: Instant) {
        self.backoff.reset();
        self.license_busy_notified = false;
        self.reconnect_at = None;
        self.next_beat = now + self.timing.heartbeat_every(self.background);
    }

    /// The session is gone: its unacked data waits for the next one, its numbers and
    /// joins start over.
    fn lose_session(&mut self) {
        self.out.lose_session();
        self.inbound = Inbound::default();
        self.sid = None;
        self.session_door = None;
        self.replayed_joins.clear();
    }

    fn forget_socket(&mut self, socket: &Socket) {
        if !socket.session {
            self.replayed_joins.clear();
        }
    }

    async fn drop_socket(&mut self, why: Why) {
        let Some(socket) = self.socket.take() else { return };
        self.forget_socket(&socket);
        match why {
            Why::Suspend => goodbye(socket, None, "suspend").await,
            Why::Drain => goodbye(socket, None, "drain").await,
            _ => drop(socket),
        }
        self.notify(relay_session::on_drop(self.sid.is_some()));
        if let Some(a) = self.attempt.as_mut() {
            a.racing = false;
        }
        if let Some(s) = self.suspending.take() {
            self.suspended = true;
            let _ = s.done.send(());
        }
        self.schedule(why);
    }

    /// When to try again: at once after a dead path or a failed write, when the
    /// relay's drain hint says, else after the backoff; never while suspended.
    fn schedule(&mut self, why: Why) {
        if self.suspended {
            self.reconnect_at = None;
            return;
        }
        let now = Instant::now();
        let at = match why {
            Why::Dead | Why::SendFailed | Why::Drain => {
                self.backoff.reset();
                self.drain_at = None;
                now
            }
            Why::Lost | Why::Suspend => match self.drain_at.take() {
                Some(at) => at,
                None => now + self.retry_wait(),
            },
        };
        self.reconnect_at = Some(at);
    }

    fn retry_wait(&mut self) -> Duration {
        // A call riding on this socket retries at a steady short interval and does
        // NOT let the ladder climb, so an ICE restart can be delivered inside the
        // call's hold-open window. See REALTIME_ACTIVE.
        if realtime_active() {
            self.backoff.reset();
            return self.timing.realtime_retry;
        }
        let mut roll = [0u8; 8];
        let _ = getrandom::fill(&mut roll);
        self.backoff.next(u64::from_le_bytes(roll), &self.timing)
    }

    /// The node is shutting down: end the session so the relay hands its ring to the
    /// offline buffer now instead of after the grace window.
    async fn shutdown(&mut self) {
        hollow_log!("[HOLLOW-WS] Command channel closed: shutting down the WS client task");
        if let Some(socket) = self.socket.take() {
            let end = socket.session.then_some(relay_session::END);
            goodbye(socket, end, "end").await;
        }
    }
}

/// Close a socket on purpose: an optional last frame, the close frame, then the relay's
/// close reply, so the goodbye is read rather than lost to a reset of a socket closed
/// with unread data in it. Frames still arriving are not counted: the relay resends
/// them on resume.
async fn goodbye(mut socket: Socket, last: Option<&'static str>, reason: &'static str) {
    if let Some(text) = last
        && bounded_send_within(&mut socket.write, Message::Text(text.into()), GOODBYE_WRITE_TIMEOUT).await.is_err()
    {
        return;
    }
    let close = CloseFrame { code: CloseCode::Normal, reason: reason.into() };
    if bounded_send_within(&mut socket.write, Message::Close(Some(close)), GOODBYE_WRITE_TIMEOUT).await.is_err() {
        return;
    }
    let _ = tokio::time::timeout(GOODBYE_WRITE_TIMEOUT, async {
        while let Some(Ok(msg)) = socket.read.next().await {
            if matches!(msg, Message::Close(_)) {
                break;
            }
        }
    })
    .await;
}

/// Room state ranks last in the prune; a sealed live-only frame first once its
/// receiver would refuse it.
impl Queued for WsCommand {
    fn bytes(&self) -> usize {
        const OVERHEAD: usize = 128;
        let payload = match self {
            WsCommand::SendToRoom { data, .. }
            | WsCommand::SendPublic { data, .. }
            | WsCommand::SendDirect { data, .. }
            | WsCommand::SendDirectImage { data, .. }
            | WsCommand::SendBinaryDirect { data, .. }
            | WsCommand::SendToRoomTopic { data, .. }
            | WsCommand::SendChannelDirect { data, .. } => data.len(),
            WsCommand::Carry { json, .. } => json.len(),
            WsCommand::SetPushPrefs { prefs_json } => prefs_json.len(),
            WsCommand::KillDeposit { blob, .. } => blob.len(),
            WsCommand::JoinInbox { .. } | WsCommand::LockPut { .. } => 4096,
            _ => 0,
        };
        OVERHEAD + payload
    }

    fn class(&self) -> Class {
        match self {
            WsCommand::JoinRoom { .. }
            | WsCommand::JoinInbox { .. }
            | WsCommand::LeaveRoom { .. }
            | WsCommand::Subscribe { .. }
            | WsCommand::SetDoor { .. }
            | WsCommand::SetOfflineBuffer { .. } => Class::RoomState,
            WsCommand::SendToRoom { data, .. }
            | WsCommand::SendPublic { data, .. }
            | WsCommand::SendDirect { data, .. }
            | WsCommand::SendDirectImage { data, .. }
            | WsCommand::SendBinaryDirect { data, .. }
            | WsCommand::SendToRoomTopic { data, .. }
            | WsCommand::SendChannelDirect { data, .. } => sealed_class(data),
            _ => Class::Ordinary,
        }
    }

    fn frame_class(frame: &Frame) -> Class {
        match frame {
            Frame::Binary(bytes) => binary_payload(bytes).map(sealed_class).unwrap_or(Class::Ordinary),
            Frame::Text(_) => Class::Ordinary,
        }
    }
}

/// How the prune ranks a sealed payload: a live-only message (`HavenMessage::live_only`)
/// with its seal time, else ordinary.
fn sealed_class(payload: &[u8]) -> Class {
    let Some((sealed_ms, body)) = sealed_parts(payload) else { return Class::Ordinary };
    match serde_json::from_slice::<super::types::HavenMessage>(body) {
        Ok(msg) if msg.live_only() => Class::LiveOnly { sealed_ms },
        _ => Class::Ordinary,
    }
}

/// The seal time and body of a frame `frame_auth::seal` made, unchecked: only for
/// ranking our own queued frames.
fn sealed_parts(frame: &[u8]) -> Option<(i64, &[u8])> {
    let rest = frame.strip_prefix(&super::frame_auth::MAGIC[..])?;
    let ts_ms = i64::from_be_bytes(rest.get(..8)?.try_into().ok()?);
    let rest = rest.get(8 + super::frame_auth::NONCE_LEN..)?;
    let (&route_len, rest) = rest.split_first()?;
    Some((ts_ms, rest.get(route_len as usize + SEAL_SIG_LEN..)?))
}

/// The peer payload of a client binary frame: what follows its NUL-ended fields.
fn binary_payload(frame: &[u8]) -> Option<&[u8]> {
    let (&op, mut rest) = frame.split_first()?;
    let fields = match op {
        0x03 | 0x0A => 1,
        0x02 | 0x04 | 0x07 | 0x08 => 2,
        0x09 => 3,
        _ => return None,
    };
    for _ in 0..fields {
        let at = rest.iter().position(|&b| b == 0)?;
        rest = &rest[at + 1..];
    }
    if op == 0x09 {
        rest = rest.get(1..)?;
    }
    Some(rest)
}

fn binary_frame(op: u8, fields: &[&str], data: &[u8]) -> Frame {
    let mut frame = Vec::with_capacity(1 + fields.iter().map(|f| f.len() + 1).sum::<usize>() + data.len());
    frame.push(op);
    for field in fields {
        frame.extend_from_slice(field.as_bytes());
        frame.push(0x00);
    }
    frame.extend_from_slice(data);
    Frame::Binary(frame.into())
}

/// The frame a command becomes on the wire; None for one that writes nothing. Joins
/// and leaves are rendered by the client, which proves doors and drops repeats.
fn command_frame(cmd: &WsCommand) -> Option<Frame> {
    let json = |v: serde_json::Value| Some(Frame::text(v.to_string()));
    match cmd {
        WsCommand::SendBinaryDirect { room_code, target_peer, data } => Some(binary_frame(0x02, &[room_code, target_peer], data)),
        WsCommand::SendToRoom { room_code, data } => Some(binary_frame(0x03, &[room_code], data)),
        WsCommand::SendPublic { room_code, data } => Some(binary_frame(0x0A, &[room_code], data)),
        WsCommand::SendDirect { room_code, target_peer, data } => Some(binary_frame(0x04, &[room_code, target_peer], data)),
        // Same layout as 0x04, but 0x08 tells the relay this direct carries an inlined
        // image, so the image cap applies to its offline buffer.
        WsCommand::SendDirectImage { room_code, target_peer, data } => Some(binary_frame(0x08, &[room_code, target_peer], data)),
        WsCommand::SendToRoomTopic { room_code, topic, data } => Some(binary_frame(0x07, &[room_code, topic], data)),
        // [0x09][room\0][target\0][channel\0][flags:1][payload]; flags bit0 = mention.
        // The payload may be empty (a push trigger only).
        WsCommand::SendChannelDirect { room_code, target_peer, channel_id, mention, data } => {
            let mut flagged = Vec::with_capacity(1 + data.len());
            flagged.push(if *mention { 0x01 } else { 0x00 });
            flagged.extend_from_slice(data);
            Some(binary_frame(0x09, &[room_code, target_peer, channel_id], &flagged))
        }
        WsCommand::CheckPeers { peers, rooms } => json(serde_json::json!({ "type": "check_peers", "peers": peers, "rooms": rooms })),
        WsCommand::DiscoverPeers { room_code } => json(serde_json::json!({ "type": "discover_peers", "room": room_code })),
        WsCommand::GetTurnCredentials => json(serde_json::json!({ "type": "get_turn_credentials" })),
        WsCommand::GetMediaForwarder => json(serde_json::json!({ "type": "get_media_forwarder" })),
        WsCommand::Subscribe { room_code, topics } => {
            json(serde_json::json!({ "type": "subscribe", "room": room_code, "topics": topics }))
        }
        WsCommand::ClaimNickname { nickname, master, claim } => json(serde_json::json!({
            "type": "claim_nickname",
            "nickname": nickname,
            "master": master,
            "master_key": claim.master_key,
            "ts": claim.ts_ms,
            "sig": claim.sig,
        })),
        WsCommand::ReleaseNickname => json(serde_json::json!({ "type": "release_nickname" })),
        WsCommand::ResolveNickname { nickname } => json(serde_json::json!({ "type": "resolve_nickname", "nickname": nickname })),
        WsCommand::ClaimLinkCode { code } => json(serde_json::json!({ "type": "claim_link_code", "code": code })),
        WsCommand::ReleaseLinkCode => json(serde_json::json!({ "type": "release_link_code" })),
        WsCommand::ResolveLinkCode { code } => json(serde_json::json!({ "type": "resolve_link_code", "code": code })),
        WsCommand::RegisterPushToken { token, platform } => {
            json(serde_json::json!({ "type": "register_push_token", "token": token, "platform": platform }))
        }
        WsCommand::SetPushPrefs { prefs_json } => {
            // Embedded as a real JSON object so the relay parses it directly; a
            // malformed prefs string is dropped here.
            let Ok(prefs) = serde_json::from_str::<serde_json::Value>(prefs_json) else {
                hollow_log!("[HOLLOW-WS] SetPushPrefs: invalid prefs JSON, skipped");
                return None;
            };
            json(serde_json::json!({ "type": "set_push_prefs", "prefs": prefs }))
        }
        WsCommand::SetOfflineBuffer { enabled, retention_secs } => json(serde_json::json!({
            "type": "set_offline_buffer",
            "enabled": enabled,
            "retention_secs": retention_secs,
        })),
        WsCommand::ReportUser { target, category } => {
            json(serde_json::json!({ "type": "report", "target": target, "category": category }))
        }
        WsCommand::SetTopicBuffer { room_code, channels, retention_secs, clear, auth } => {
            // Every field the signature covers goes on the wire as signed.
            let mut msg = serde_json::json!({
                "type": "set_topic_buffer",
                "room": room_code,
                "channels": channels,
                "retention_secs": retention_secs,
                "clear": clear,
            });
            if let Some(auth) = auth {
                msg["owner"] = auth.owner.clone().into();
                msg["ts"] = auth.ts_ms.into();
                msg["sig"] = auth.sig.clone().into();
            }
            json(msg)
        }
        WsCommand::TopicCatchup { room_code, channel_id, max_age_secs, end } => {
            json(topic_catchup_frame(room_code, channel_id, *max_age_secs, *end))
        }
        WsCommand::KillDeposit { targets, issued_at_ms, blob } => json(serde_json::json!({
            "type": "kill_deposit",
            "targets": targets,
            "issued_at_ms": issued_at_ms,
            "blob": blob,
        })),
        WsCommand::KillAck { signal } => json(kill_ack_frame(signal.as_ref())),
        WsCommand::LockGet { locks } => {
            let locks: Vec<serde_json::Value> = locks
                .iter()
                .map(|(server, owner)| serde_json::json!({ "server": server, "owner": owner }))
                .collect();
            json(serde_json::json!({ "type": "lock_get", "locks": locks }))
        }
        WsCommand::LockPut { server, owner, links } => {
            json(serde_json::json!({ "type": "lock_put", "server": server, "owner": owner, "links": links }))
        }
        WsCommand::UnregisterPushToken => json(serde_json::json!({ "type": "unregister_push_token" })),
        WsCommand::JoinRoom { .. }
        | WsCommand::JoinInbox { .. }
        | WsCommand::LeaveRoom { .. }
        | WsCommand::SetDoor { .. }
        | WsCommand::Carry { .. } => None,
    }
}

/// Keep (or forget) the door of `room`; whether it changed.
fn remember_door(doors: &mut HashMap<String, DoorSecret>, room: &str, door: Option<DoorSecret>) -> bool {
    match door {
        Some(door) => doors.insert(room.to_string(), door.clone()).is_none_or(|old| *old.0 != *door.0),
        None => doors.remove(room).is_some(),
    }
}

// -- Connection + Auth --

pub(crate) type WsStream = tokio_tungstenite::WebSocketStream<
    tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
>;

/// Why a connect attempt failed. A license refusal is only ever one of the relay's
/// exact codes: a relay's free text can never stop the node or touch the key.
#[derive(Debug)]
pub(crate) enum ConnectError {
    License(LicenseRefusal),
    Other(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum LicenseRefusal {
    Invalid,
    InUse,
    Required,
}

impl LicenseRefusal {
    fn from_code(code: &str) -> Option<Self> {
        match code {
            "invalid_license_key" => Some(Self::Invalid),
            "license_key_in_use" => Some(Self::InUse),
            "license_key_required" => Some(Self::Required),
            _ => None,
        }
    }

    /// The relay's code, which the UI keys its message on.
    pub(crate) fn code(self) -> &'static str {
        match self {
            Self::Invalid => "invalid_license_key",
            Self::InUse => "license_key_in_use",
            Self::Required => "license_key_required",
        }
    }
}

impl std::fmt::Display for ConnectError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::License(r) => write!(f, "{}", r.code()),
            Self::Other(e) => write!(f, "{e}"),
        }
    }
}

impl From<String> for ConnectError {
    fn from(e: String) -> Self {
        Self::Other(e)
    }
}

/// The relay host a v2 auth signature names: the host of the URL we dialled,
/// lowercase, no port. Matches the relay's `auth_domain(--domain)`.
pub(crate) fn relay_auth_domain(url: &str) -> Option<String> {
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;
    let request = url.into_client_request().ok()?;
    let host = request.uri().host()?.to_ascii_lowercase();
    (!host.is_empty()).then_some(host)
}

/// The TURN/STUN URIs whose host is the relay's own. A relay could otherwise route
/// every call's media, Always-relay calls included, through a server of its choosing.
pub(crate) fn turn_uris_on_relay(uris: Vec<String>, relay_host: &str) -> Vec<String> {
    uris.into_iter()
        .filter(|uri| !relay_host.is_empty() && turn_uri_host(uri).is_some_and(|h| h == relay_host))
        .collect()
}

/// The lowercase host of a `turn:`, `turns:`, `stun:` or `stuns:` URI.
fn turn_uri_host(uri: &str) -> Option<String> {
    let (scheme, rest) = uri.split_once(':')?;
    if !matches!(scheme.to_ascii_lowercase().as_str(), "turn" | "turns" | "stun" | "stuns") {
        return None;
    }
    let rest = rest.split('?').next()?;
    let host = if rest.starts_with('[') {
        &rest[..=rest.find(']')?]
    } else {
        rest.split(':').next()?
    };
    (!host.is_empty()).then(|| host.to_ascii_lowercase())
}

/// The exact bytes a v2 auth signature covers; pinned against the relay's
/// `auth_v2_message` (relay-uws/test/test_auth_frame.cpp). `license_digest` is the
/// lowercase hex SHA-256 of the key, empty without one.
pub(crate) fn auth_v2_message(
    domain: &str,
    nonce: &str,
    peer_id: &str,
    timestamp: u64,
    mode: &str,
    license_digest: &str,
) -> String {
    format!("hollow-ws-auth2\n{domain}\n{nonce}\n{peer_id}\n{timestamp}\n{mode}\n{license_digest}")
}

pub(crate) fn license_digest(key: Option<&str>) -> String {
    use sha2::{Digest, Sha256};
    key.filter(|k| !k.is_empty())
        .map(|k| hex::encode(Sha256::digest(k.as_bytes())))
        .unwrap_or_default()
}

fn is_auth_nonce(nonce: &str) -> bool {
    nonce.len() == 64 && nonce.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Reads the relay's next text frame as an [`AuthReply`], within `limit`.
async fn read_auth_reply<S>(read: &mut S, limit: Duration) -> Result<(AuthReply, String), ConnectError>
where
    S: futures_util::Stream<Item = Result<Message, tokio_tungstenite::tungstenite::Error>> + Unpin,
{
    let deadline = tokio::time::Instant::now() + limit;
    loop {
        let response = tokio::time::timeout_at(deadline, read.next())
            .await
            .map_err(|_| "Auth timeout".to_string())?
            .ok_or_else(|| "Connection closed before auth response".to_string())?
            .map_err(|e| format!("Read error: {e}"))?;
        let text = match response {
            Message::Text(text) => text,
            Message::Ping(_) | Message::Pong(_) => continue,
            _ => return Err("Unexpected auth response".to_string().into()),
        };
        return match serde_json::from_str::<AuthReply>(&text) {
            Ok(reply) => Ok((reply, text.to_string())),
            Err(_) => Err(format!("Auth rejected: {text}").into()),
        };
    }
}

/// A WebSocket over a TCP stream we opened ourselves, so the stream's options are set
/// before TLS.
async fn dial_websocket(url: &str) -> Result<WsStream, ConnectError> {
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;
    let request = url.into_client_request().map_err(|e| format!("Bad relay URL: {e}"))?;
    let host = request.uri().host().ok_or_else(|| format!("Bad relay URL: {url}"))?;
    let host = host.trim_start_matches('[').trim_end_matches(']').to_string();
    let port = request
        .uri()
        .port_u16()
        .or_else(|| match request.uri().scheme_str() {
            Some("wss") => Some(443),
            Some("ws") => Some(80),
            _ => None,
        })
        .ok_or_else(|| format!("Bad relay URL: {url}"))?;
    let addr = dial_override().unwrap_or_else(|| format!("{host}:{port}"));
    let tcp = tokio::net::TcpStream::connect(addr)
        .await
        .map_err(|e| format!("WebSocket connect failed: {e}"))?;
    limit_unacked_send_time(&tcp);
    let (stream, _response) = tokio_tungstenite::client_async_tls_with_config(request, tcp, None, None)
        .await
        .map_err(|e| format!("WebSocket connect failed: {e}"))?;
    Ok(stream)
}

/// Debug builds only: a `relay_connect` file in the data dir (one `ip:port` line) is
/// dialled instead of the relay, so the fleet can cut one app's path at its proxy.
/// TLS and the auth domain stay the relay's.
#[cfg(debug_assertions)]
fn dial_override() -> Option<String> {
    dial_override_in(&crate::identity::data_dir().ok()?)
}

#[cfg(not(debug_assertions))]
fn dial_override() -> Option<String> {
    None
}

#[cfg(debug_assertions)]
fn dial_override_in(dir: &std::path::Path) -> Option<String> {
    let line = std::fs::read_to_string(dir.join("relay_connect")).ok()?;
    let addr = line.trim();
    addr.parse::<std::net::SocketAddr>().is_ok().then(|| addr.to_string())
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn limit_unacked_send_time(tcp: &tokio::net::TcpStream) {
    if let Err(e) = socket2::SockRef::from(tcp).set_tcp_user_timeout(Some(TCP_USER_TIMEOUT)) {
        hollow_log!("[HOLLOW-WS] TCP_USER_TIMEOUT not set: {e}");
    }
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn limit_unacked_send_time(_tcp: &tokio::net::TcpStream) {}

/// A socket that passed auth, with what it asked and what the relay answered.
struct Opened {
    stream: WsStream,
    door: RelaySession,
    ask: Ask,
    reply: AuthReply,
}

/// Connect, take the relay's challenge and sign in: v3 with a session (resuming
/// `held`) only to a relay that offered sessions and only when `want_session`, else v2.
async fn open_socket(dial: Dial, want_session: bool, held: Option<(String, u64)>, timing: Timing) -> Result<Opened, ConnectError> {
    let domain = relay_auth_domain(&dial.url).ok_or_else(|| format!("Bad relay URL: {}", dial.url))?;
    let stream = tokio::time::timeout(timing.handshake, dial_websocket(&dial.url))
        .await
        .map_err(|_| "WebSocket connect timed out".to_string())??;
    let (mut write, mut read) = stream.split();

    let hello = serde_json::to_string(&ClientMsg::AuthHello).map_err(|e| format!("JSON error: {e}"))?;
    bounded_send(&mut write, Message::Text(hello.into()))
        .await
        .map_err(|e| format!("Failed to ask for a challenge: {e}"))?;
    let (challenge, text) = read_auth_reply(&mut read, timing.auth_reply).await?;
    let offered = challenge.offers_sessions();
    let (nonce, door_key) = match challenge {
        AuthReply::AuthChallenge { nonce, door_key, .. } if is_auth_nonce(&nonce) => (nonce, door_key),
        // A relay older than 0.12 answers the hello as a bad auth frame.
        AuthReply::AuthFailed { .. } => {
            return Err("The relay offers no auth challenge (it needs updating)".to_string().into());
        }
        _ => return Err(format!("Auth rejected: {text}").into()),
    };

    let ask = Ask::choose(offered && want_session, dial.fetch, held.as_ref().map(|(sid, in_h)| (sid.as_str(), *in_h)));
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let mode = if dial.fetch { "fetch" } else { "full" };
    let digest = license_digest(dial.license_key.as_deref());
    let session = ask.session_field();
    let sign_payload = match &session {
        Some((field, in_h)) => {
            relay_session::auth_v3_message(&domain, &nonce, &dial.peer_id, timestamp, mode, &digest, field, *in_h)
        }
        None => auth_v2_message(&domain, &nonce, &dial.peer_id, timestamp, mode, &digest),
    };
    let keypair = crate::identity::native_identity::NativeKeypair::from_protobuf_encoding(&dial.keypair_proto)
        .map_err(|e| format!("Failed to decode keypair: {e}"))?;
    let signature = base64::engine::general_purpose::STANDARD.encode(keypair.sign(sign_payload.as_bytes()));

    let door = RelaySession { domain: domain.clone(), nonce: nonce.clone(), peer_id: dial.peer_id.clone(), door_key };
    let auth = ClientMsg::Auth {
        v: if session.is_some() { 3 } else { 2 },
        peer_id: dial.peer_id.clone(),
        public_key: dial.pub_key_b64.clone(),
        timestamp,
        nonce,
        domain,
        signature,
        license_key: dial.license_key.as_deref().filter(|k| !k.is_empty()).map(str::to_string),
        fetch: dial.fetch,
        in_h: session.as_ref().map(|(_, in_h)| *in_h),
        session: session.map(|(field, _)| field),
    };
    let auth_json = serde_json::to_string(&auth).map_err(|e| format!("JSON error: {e}"))?;
    bounded_send(&mut write, Message::Text(auth_json.into()))
        .await
        .map_err(|e| format!("Failed to send auth: {e}"))?;

    match read_auth_reply(&mut read, timing.auth_reply).await? {
        (AuthReply::AuthFailed { error }, _) => Err(match LicenseRefusal::from_code(&error) {
            Some(refusal) => ConnectError::License(refusal),
            None => ConnectError::Other(error),
        }),
        (AuthReply::AuthChallenge { .. }, text) => Err(format!("Auth rejected: {text}").into()),
        (reply, _) => {
            let stream = read.reunite(write).map_err(|e| format!("Reunite error: {e}"))?;
            Ok(Opened { stream, door, ask, reply })
        }
    }
}

/// A signed-in socket for the push fetch and the forwarder: today's v2 frame, never a
/// session, whatever the relay offers.
pub(crate) async fn connect_and_auth(
    url: &str,
    peer_id: &str,
    keypair_proto: &[u8],
    pub_key_b64: &str,
    license_key: Option<&str>,
    fetch: bool,
) -> Result<WsStream, ConnectError> {
    let dial = Dial {
        url: url.to_string(),
        peer_id: peer_id.to_string(),
        keypair_proto: keypair_proto.to_vec(),
        pub_key_b64: pub_key_b64.to_string(),
        license_key: license_key.map(str::to_string),
        fetch,
    };
    let opened = open_socket(dial, false, None, Timing::default()).await?;
    match opened.reply {
        AuthReply::AuthOk { .. } => Ok(opened.stream),
        _ => Err("Auth rejected: an answer for a session nobody asked for".to_string().into()),
    }
}

// -- Writes --

/// Bounded socket write, the ONLY way this module writes to the sink. See
/// WRITE_TIMEOUT for why an unbounded `send` can freeze the entire client loop
/// with the liveness watchdog unable to run. A timeout is reported as an error
/// string, so every `Err -> reconnect` path handles it exactly like a dead socket.
async fn bounded_send(write: &mut WsSink, msg: Message) -> Result<(), String> {
    bounded_send_within(write, msg, WRITE_TIMEOUT).await
}

async fn bounded_send_within(write: &mut WsSink, msg: Message, limit: Duration) -> Result<(), String> {
    match tokio::time::timeout(limit, write.send(msg)).await {
        Ok(Ok(())) => Ok(()),
        Ok(Err(e)) => Err(e.to_string()),
        Err(_) => Err(format!("write timed out after {}s: connection wedged", limit.as_secs())),
    }
}

// -- Binary frame parsing --

fn parse_binary_relay_frame(data: &[u8]) -> Option<(String, String, Vec<u8>)> {
    let room_nul = data.iter().position(|&b| b == 0)?;
    let room = std::str::from_utf8(&data[..room_nul]).ok()?.to_string();
    let peer_start = room_nul + 1;
    if peer_start >= data.len() { return None; }
    let peer_nul = data[peer_start..].iter().position(|&b| b == 0)? + peer_start;
    let from = std::str::from_utf8(&data[peer_start..peer_nul]).ok()?.to_string();
    let payload = data[peer_nul + 1..].to_vec();
    Some((room, from, payload))
}

fn dispatch_binary(event_tx: &mpsc::UnboundedSender<WsEvent>, data: &[u8]) {
    if data.len() <= 3 {
        return;
    }
    let event = match data[0] {
        0x02 => parse_binary_relay_frame(&data[1..]).map(|(room, from, data)| WsEvent::BinaryDirect { room, from, data }),
        0x05 => parse_binary_relay_frame(&data[1..]).map(|(room, from, data)| WsEvent::Message { room, from, data }),
        0x06 => parse_binary_relay_frame(&data[1..]).map(|(room, from, data)| WsEvent::DirectMessage { room, from, data }),
        // Topic broadcast: [0x08][room\0][topic\0][sender\0][payload]
        0x08 => {
            let rest = &data[1..];
            rest.iter().position(|&b| b == 0).and_then(|room_end| {
                let room = String::from_utf8_lossy(&rest[..room_end]).to_string();
                let after_room = &rest[room_end + 1..];
                let topic_end = after_room.iter().position(|&b| b == 0)?;
                let after_topic = &after_room[topic_end + 1..];
                let sender_end = after_topic.iter().position(|&b| b == 0)?;
                let from = String::from_utf8_lossy(&after_topic[..sender_end]).to_string();
                Some(WsEvent::Message { room, from, data: after_topic[sender_end + 1..].to_vec() })
            })
        }
        _ => None,
    };
    if let Some(event) = event {
        let _ = event_tx.send(event);
    }
}

// -- Server message handling --

fn handle_server_message(
    event_tx: &mpsc::UnboundedSender<WsEvent>,
    msg: ServerMsg,
    rooms: &mut Rooms,
    replayed_joins: &mut HashMap<String, (String, Instant)>,
    relay_host: &str,
) {
    let event = match msg {
        ServerMsg::PeerJoined { room, peer_id } => {
            hollow_log!("[HOLLOW-WS] Peer joined {room}: {peer_id}");
            WsEvent::PeerJoined { room, peer_id }
        }
        ServerMsg::PeerLeft { room, peer_id } => {
            hollow_log!("[HOLLOW-WS] Peer left {room}: {peer_id}");
            WsEvent::PeerLeft { room, peer_id }
        }
        ServerMsg::Members { room, peers, proved } => {
            hollow_log!("[HOLLOW-WS] Room {room} members: {} peers", peers.len());
            // An open room hides nobody: every roster says where we stand.
            let _ = event_tx.send(WsEvent::DoorStatus { room: room.clone(), proved: proved.unwrap_or(true) });
            WsEvent::RoomMembers { room, peers }
        }
        ServerMsg::TopicCatchupDone { room, channel } => WsEvent::TopicCatchupDone { room, channel },
        ServerMsg::PeerStatus { online, active_rooms } => {
            hollow_log!("[HOLLOW-WS] PeerStatus: {} online, {} active rooms", online.len(), active_rooms.len());
            WsEvent::PeerStatus { online, active_rooms }
        }
        ServerMsg::DiscoveredPeers { room, peers } => {
            hollow_log!("[HOLLOW-WS] DiscoveredPeers: {} peers in room {room}", peers.len());
            WsEvent::DiscoveredPeers { room, peers }
        }
        ServerMsg::TurnCredentials { username, password, ttl, uris, error } => {
            if let Some(err) = error {
                // Non-fatal: relay without TURN configured (or guest socket).
                // Calls fall back to STUN-only; the next interval retries.
                hollow_log!("[HOLLOW-WS] TURN credentials unavailable: {err}");
                return;
            }
            let offered = uris.len();
            let uris = turn_uris_on_relay(uris, relay_host);
            if uris.len() < offered {
                hollow_log!("[HOLLOW-WS] Dropped {} TURN URI(s) naming a host other than the relay", offered - uris.len());
            }
            if uris.is_empty() {
                return;
            }
            hollow_log!("[HOLLOW-WS] TURN credentials received: {} URI(s), ttl={ttl}s", uris.len());
            WsEvent::TurnCredentials { username, password, ttl, uris }
        }
        ServerMsg::MediaForwarder { peer_id, online, error } => {
            if let Some(err) = error {
                // Non-fatal: relay without a forwarder configured (or guest
                // socket) — clients just keep today's direct+TURN path.
                hollow_log!("[HOLLOW-WS] Media forwarder unavailable: {err}");
                return;
            }
            hollow_log!("[HOLLOW-WS] Media forwarder advertised (online={online})");
            WsEvent::MediaForwarderInfo { peer_id, online }
        }
        ServerMsg::Error { error } => {
            hollow_log!("[HOLLOW-WS] Server error: {error}");
            if error.contains("Too many rooms") {
                let room = rooms.last_join_attempt.take().unwrap_or_default();
                if !room.is_empty() {
                    rooms.joined.remove(&room);
                    replayed_joins.remove(&room);
                    let _ = event_tx.send(WsEvent::RoomBudgetUpdate { joined: rooms.joined.len() as u32, limit: ROOM_BUDGET_LIMIT });
                    let _ = event_tx.send(WsEvent::RoomCapHit { room });
                }
            }
            return;
        }
        ServerMsg::NicknameClaimed { nickname } => {
            hollow_log!("[HOLLOW-WS] Nickname claimed");
            WsEvent::NicknameClaimed { nickname }
        }
        ServerMsg::NicknameReleased => {
            hollow_log!("[HOLLOW-WS] Nickname released");
            WsEvent::NicknameReleased
        }
        ServerMsg::NicknameError { error, nickname } => {
            hollow_log!("[HOLLOW-WS] Nickname error: {error}");
            WsEvent::NicknameError { error, nickname }
        }
        ServerMsg::NicknameResolved { nickname, peer_id, master_id, master_key, ts, sig } => {
            hollow_log!("[HOLLOW-WS] Nickname resolved");
            let claim = super::nick_claim::NickClaim { master_key, ts_ms: ts, sig };
            WsEvent::NicknameResolved { nickname, peer_id, master_id, claim }
        }
        ServerMsg::LinkCodeClaimed { code } => {
            hollow_log!("[HOLLOW-LINK] Link code claimed");
            WsEvent::LinkCodeClaimed { code }
        }
        ServerMsg::LinkCodeReleased => {
            hollow_log!("[HOLLOW-LINK] Link code released");
            WsEvent::LinkCodeReleased
        }
        ServerMsg::LinkCodeError { error, code } => {
            hollow_log!("[HOLLOW-LINK] Link code error: {error}");
            WsEvent::LinkCodeError { error, code }
        }
        ServerMsg::LinkCodeResolved { code, peer_id } => {
            hollow_log!("[HOLLOW-LINK] Link code resolved");
            WsEvent::LinkCodeResolved { code, peer_id }
        }
        ServerMsg::KillSignal { blob, issued_at_ms, issuer } => {
            // Nothing identifying: the blob is somebody's signed payload and the
            // target is us.
            hollow_log!("[HOLLOW-DESTROY] Kill signal received from the relay");
            WsEvent::KillSignal { blob, signal: KillSignalId { issuer, issued_at_ms } }
        }
        ServerMsg::KillDeposited { stored } => {
            hollow_log!("[HOLLOW-DESTROY] Relay parked {stored} destruction order(s)");
            return;
        }
        ServerMsg::LockChain { server, links, put } => WsEvent::LockChain { server, links, put },
        ServerMsg::HbAck { .. } | ServerMsg::Ack { .. } | ServerMsg::Reconnect { .. } => return,
    };

    let _ = event_tx.send(event);
}

#[cfg(test)]
#[path = "ws_client_wire_tests.rs"]
mod wire_tests;

// -- Tests --

#[cfg(test)]
mod tests {
    use super::*;

    /// D5: the relay names who parked each kill signal, and turning one away echoes it.
    #[tokio::test]
    async fn a_kill_signal_keeps_its_issuer_for_the_ack() {
        let mut rooms = Rooms::default();
        let mut joins = HashMap::new();
        let (tx, mut rx) = mpsc::unbounded_channel();
        let frame = r#"{"type":"kill_signal","blob":"b","issued_at_ms":5,"issuer":"12D3KooWJunk"}"#;
        handle_server_message(&tx, serde_json::from_str(frame).unwrap(), &mut rooms, &mut joins, "");
        let Ok(WsEvent::KillSignal { signal, .. }) = rx.try_recv() else { panic!("no kill signal") };
        assert_eq!(signal, KillSignalId { issuer: "12D3KooWJunk".into(), issued_at_ms: 5 });
        assert_eq!(
            kill_ack_frame(Some(&signal)),
            serde_json::json!({ "type": "kill_ack", "issuer": "12D3KooWJunk", "issued_at_ms": 5 }),
            "a stamp alone cannot tell junk from an order sharing it",
        );
        assert_eq!(kill_ack_frame(None), serde_json::json!({ "type": "kill_ack" }), "only a wipe acks everything");
    }

    #[test]
    fn the_fleet_dial_override_takes_only_one_address() {
        let dir = crate::test_tmp::tempdir().unwrap();
        assert_eq!(dial_override_in(dir.path()), None, "no file, the relay's own address");
        std::fs::write(dir.path().join("relay_connect"), "127.0.0.1:18501\r\n").unwrap();
        assert_eq!(dial_override_in(dir.path()).as_deref(), Some("127.0.0.1:18501"));
        for junk in ["relay.example.com:443", "127.0.0.1", "127.0.0.1:18501 10.0.0.1:1", ""] {
            std::fs::write(dir.path().join("relay_connect"), junk).unwrap();
            assert_eq!(dial_override_in(dir.path()), None, "{junk:?} is not one address");
        }
    }

    #[test]
    fn test_auth_message_format() {
        let hello = serde_json::to_string(&ClientMsg::AuthHello).unwrap();
        assert_eq!(hello, r#"{"type":"auth_hello"}"#);

        let msg = ClientMsg::Auth {
            v: 2,
            peer_id: "12D3KooWTest".into(),
            public_key: "AQID".into(),
            timestamp: 1234567890,
            nonce: "ab".repeat(32),
            domain: "relay.example.com".into(),
            signature: "c2lnbmF0dXJl".into(),
            license_key: None,
            fetch: false,
            session: None,
            in_h: None,
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"auth\""));
        assert!(json.contains("\"v\":2"));
        assert!(json.contains("\"peer_id\":\"12D3KooWTest\""));
        assert!(json.contains("\"timestamp\":1234567890"));
        assert!(json.contains("\"domain\":\"relay.example.com\""));
        assert!(!json.contains("\"fetch\""));
        assert!(!json.contains("license_key"));

        let msg_fetch = ClientMsg::Auth {
            v: 2,
            peer_id: "12D3KooWTest".into(),
            public_key: "AQID".into(),
            timestamp: 1234567890,
            nonce: "ab".repeat(32),
            domain: "relay.example.com".into(),
            signature: "c2lnbmF0dXJl".into(),
            license_key: Some("L".into()),
            fetch: true,
            session: None,
            in_h: None,
        };
        let json_fetch = serde_json::to_string(&msg_fetch).unwrap();
        assert!(json_fetch.contains("\"fetch\":true"));
        assert!(json_fetch.contains("\"license_key\":\"L\""));
    }

    /// The bytes a v2 auth signature covers, pinned against the relay's copy in
    /// relay-uws/test/test_auth_frame.cpp: the relay's challenge, its domain, the mode
    /// and the license key are all under the signature.
    #[test]
    fn auth_v2_message_matches_the_relays_pinned_vector() {
        let nonce = "0123456789abcdef".repeat(4);
        let got = auth_v2_message(
            "relay.example.com", &nonce, "12D3KooWPeer", 1790000000, "fetch", &license_digest(Some("L")),
        );
        assert_eq!(
            got,
            "hollow-ws-auth2\nrelay.example.com\n0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n\
             12D3KooWPeer\n1790000000\nfetch\n72dfcfb0c470ac255cde83fb8fe38de8a128188e03ea5ba5b2a93adbea1062fa"
        );
        assert_eq!(license_digest(None), "");
        assert_eq!(license_digest(Some("")), "", "an empty key is no key, as the relay reads it");
    }

    #[test]
    fn auth_domain_is_the_dialled_host_without_port() {
        assert_eq!(relay_auth_domain("wss://Relay.Example.com:8443/ws").as_deref(), Some("relay.example.com"));
        assert_eq!(relay_auth_domain("wss://relay.anonlisten.com/ws").as_deref(), Some("relay.anonlisten.com"));
        assert_eq!(relay_auth_domain("not a url"), None);
    }

    #[test]
    fn turn_uris_must_name_the_relay() {
        let offered = vec![
            "turn:relay.example.com:3478".to_string(),
            "turn:RELAY.example.com:3478?transport=tcp".to_string(),
            "turns:relay.example.com:5349".to_string(),
            "turn:evil.example.net:3478".to_string(),
            "turn:relay.example.com.evil.net:3478".to_string(),
            "http://relay.example.com".to_string(),
            "turn:".to_string(),
        ];
        assert_eq!(
            turn_uris_on_relay(offered.clone(), "relay.example.com"),
            vec![
                "turn:relay.example.com:3478".to_string(),
                "turn:RELAY.example.com:3478?transport=tcp".to_string(),
                "turns:relay.example.com:5349".to_string(),
            ],
        );
        assert!(turn_uris_on_relay(offered, "").is_empty(), "no relay host, no TURN");
        assert_eq!(
            turn_uris_on_relay(vec!["turn:[::1]:3478".to_string()], "[::1]"),
            vec!["turn:[::1]:3478".to_string()],
        );
    }

    #[test]
    fn only_the_relays_exact_codes_are_license_refusals() {
        assert_eq!(LicenseRefusal::from_code("invalid_license_key"), Some(LicenseRefusal::Invalid));
        assert_eq!(LicenseRefusal::from_code("license_key_in_use"), Some(LicenseRefusal::InUse));
        assert_eq!(LicenseRefusal::from_code("license_key_required"), Some(LicenseRefusal::Required));
        assert_eq!(LicenseRefusal::from_code("Authentication failed"), None);
        assert_eq!(LicenseRefusal::from_code("your license_key is bad"), None);
        assert_eq!(LicenseRefusal::from_code("license_key"), None);
        assert!(is_auth_nonce(&"a0".repeat(32)));
        assert!(!is_auth_nonce(&"A0".repeat(32)));
        assert!(!is_auth_nonce("abcd"));
    }

    #[test]
    fn test_join_message_format() {
        let msg = ClientMsg::Join { room: "server123".into(), inbox_roster: None, door_proof: None };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"join\""));
        assert!(json.contains("\"room\":\"server123\""));
        assert!(!json.contains("inbox_roster"), "a plain join carries no roster");
        assert!(!json.contains("door_proof"), "nor a door it does not hold");
    }

    /// A door proof, pinned against the relay's copy in relay-uws/test/test_door_room.cpp
    /// and computed a third time outside both: the socket's challenge, the peer, the
    /// room, the door and the relay's key are all under the HMAC.
    #[test]
    fn door_proof_matches_the_relays_pinned_vector() {
        let relay_key = super::super::sealed_box::key_to_text(&super::super::sealed_box::public_of(&[0x22; 32]));
        assert_eq!(relay_key, "D6poTtKIZ7l_Smot7l34zpdOdrcBjj8iocTPJnhXDyA");
        let session = RelaySession {
            domain: "relay.example.org".into(),
            nonce: "0123456789abcdef".repeat(4),
            peer_id: "12D3KooWK99VoVxNE7XzyBwXEzW7xhK7Gpv85r9F3V3fyKSUKPH5".into(),
            door_key: relay_key,
        };
        let room = "8ef8bc89d3891dca86ff72c6783e396351aed5ba";
        assert_eq!(door_proof(&session, room, &[0x11; 32]).as_deref(), Some("iyHv-DBusf2SG9eXxTNOd1-VpXZM77eeFbZbz9Su9Lo"));
        assert_ne!(door_proof(&session, "00112233445566778899aabbccddeeff00112233", &[0x11; 32]), door_proof(&session, room, &[0x11; 32]));
        assert_ne!(door_proof(&session, room, &[0x33; 32]), door_proof(&session, room, &[0x11; 32]));
        let low_order = RelaySession { door_key: "A".repeat(43), ..session.clone() };
        assert_eq!(door_proof(&low_order, room, &[0x11; 32]), None, "a low-order relay key gets no proof");
        let none = RelaySession { door_key: String::new(), ..session };
        assert_eq!(door_proof(&none, room, &[0x11; 32]), None, "a relay without door rooms gets none");
    }

    /// The inbox join carries the roster the relay folds before it lets a device read
    /// the master's mailbox (design ID-1R), in the shape `relay-uws/src/roster.h` reads.
    #[test]
    fn test_join_message_carries_the_roster() {
        let k = |t: u8| crate::identity::native_identity::NativeKeypair::from_secret_bytes(&[t; 32]);
        let roster = crate::identity::roster::Roster::genesis(&k(0x7a), &k(0x7b), &k(0x7c), 1_000);
        let room = format!("inbox:{}", roster.master);
        let msg = ClientMsg::Join { room: room.clone(), inbox_roster: Some(roster), door_proof: None };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"join\""));
        assert!(json.contains(&format!("\"room\":\"{room}\"")));
        for field in ["\"inbox_roster\"", "\"master\"", "\"r_pub\"", "\"recoveries\"", "\"consents\"", "\"sig_r\""] {
            assert!(json.contains(field), "{field} missing from {json}");
        }
        assert!(!json.contains("inbox_proof"));
    }

    #[test]
    fn test_binary_msg_frame() {
        let room = "server:main";
        let payload = vec![0xDE, 0xAD, 0xBE, 0xEF];
        let mut frame = Vec::new();
        frame.push(0x03);
        frame.extend_from_slice(room.as_bytes());
        frame.push(0x00);
        frame.extend_from_slice(&payload);
        assert_eq!(frame[0], 0x03);
        assert_eq!(&frame[1..12], b"server:main");
        assert_eq!(frame[12], 0x00);
        assert_eq!(&frame[13..], &[0xDE, 0xAD, 0xBE, 0xEF]);
    }

    #[test]
    fn test_parse_binary_relay_frame() {
        let mut data = Vec::new();
        data.extend_from_slice(b"server:main");
        data.push(0x00);
        data.extend_from_slice(b"12D3KooWPeer");
        data.push(0x00);
        data.extend_from_slice(&[0xCA, 0xFE]);
        let (room, from, payload) = parse_binary_relay_frame(&data).unwrap();
        assert_eq!(room, "server:main");
        assert_eq!(from, "12D3KooWPeer");
        assert_eq!(payload, vec![0xCA, 0xFE]);
    }

    #[test]
    fn test_server_msg_parse_members() {
        let json = r#"{"type":"members","room":"server1","peers":["peer_a","peer_b"]}"#;
        let msg: ServerMsg = serde_json::from_str(json).unwrap();
        match msg {
            ServerMsg::Members { room, peers, proved } => {
                assert_eq!(room, "server1");
                assert_eq!(peers.len(), 2);
                assert_eq!(proved, None, "an open room says nothing of doors");
            }
            _ => panic!("Wrong variant"),
        }
        let locked = r#"{"type":"members","room":"s","peers":["me"],"proved":false}"#;
        assert!(matches!(serde_json::from_str(locked).unwrap(), ServerMsg::Members { proved: Some(false), .. }));
    }

    /// HOL-SEC-121: a catch-up asks for the relay's end mark only when told to, and the
    /// mark reaches the swarm as its own event.
    #[tokio::test]
    async fn a_catchup_asks_for_its_end_mark_only_when_told() {
        let plain = topic_catchup_frame("srv", "~join", 0, false);
        assert_eq!(plain, serde_json::json!({ "type": "topic_catchup", "room": "srv", "channel": "~join", "max_age_secs": 0 }));
        assert_eq!(topic_catchup_frame("srv", "~join", 0, true)["end"], serde_json::json!(true));

        let mut rooms = Rooms::default();
        let mut joins = HashMap::new();
        let (tx, mut rx) = mpsc::unbounded_channel();
        let mark = r#"{"type":"topic_catchup_done","room":"srv","channel":"~join"}"#;
        handle_server_message(&tx, serde_json::from_str(mark).unwrap(), &mut rooms, &mut joins, "");
        let Ok(WsEvent::TopicCatchupDone { room, channel }) = rx.try_recv() else { panic!("no end mark") };
        assert_eq!((room.as_str(), channel.as_str()), ("srv", "~join"));
    }

    #[test]
    fn test_server_msg_parse_peer_joined() {
        let json = r#"{"type":"peer_joined","room":"r1","peer_id":"12D3KooW..."}"#;
        let msg: ServerMsg = serde_json::from_str(json).unwrap();
        match msg {
            ServerMsg::PeerJoined { room, peer_id } => {
                assert_eq!(room, "r1");
                assert_eq!(peer_id, "12D3KooW...");
            }
            _ => panic!("Wrong variant"),
        }
    }

    /// Section 9.1: the v3 frame is the v2 frame with `"v":3`, `session` and `in_h`; a
    /// v2 frame carries neither.
    #[test]
    fn the_v3_auth_frame_carries_the_session_and_the_count() {
        let frame = |v: u8, session: Option<&str>, in_h: Option<u64>| {
            serde_json::to_value(ClientMsg::Auth {
                v,
                peer_id: "12D3KooWTest".into(),
                public_key: "AQID".into(),
                timestamp: 1,
                nonce: "ab".repeat(32),
                domain: "relay.example.com".into(),
                signature: "c2ln".into(),
                license_key: None,
                fetch: false,
                session: session.map(str::to_string),
                in_h,
            })
            .unwrap()
        };
        let v3 = frame(3, Some("00112233445566778899aabbccddeeff"), Some(42));
        assert_eq!((v3["v"].as_u64(), v3["session"].as_str(), v3["in_h"].as_u64()), (Some(3), Some("00112233445566778899aabbccddeeff"), Some(42)));
        let fresh = frame(3, Some("new"), Some(0));
        assert_eq!((fresh["session"].as_str(), fresh["in_h"].as_u64()), (Some("new"), Some(0)));
        let v2 = frame(2, None, None);
        assert!(v2.get("session").is_none() && v2.get("in_h").is_none(), "{v2}");
    }

    /// Every command keeps the bytes it had before the outbound queue existed.
    #[test]
    fn commands_keep_their_wire_layout() {
        let bin = |cmd: WsCommand| match command_frame(&cmd) {
            Some(Frame::Binary(b)) => b.to_vec(),
            other => panic!("not binary: {other:?}"),
        };
        let text = |cmd: WsCommand| match command_frame(&cmd) {
            Some(Frame::Text(t)) => serde_json::from_str::<serde_json::Value>(&t).unwrap(),
            other => panic!("not text: {other:?}"),
        };
        assert_eq!(bin(WsCommand::SendToRoom { room_code: "r".into(), data: vec![1, 2] }), b"\x03r\x00\x01\x02");
        assert_eq!(bin(WsCommand::SendPublic { room_code: "r".into(), data: vec![1] }), b"\x0ar\x00\x01");
        assert_eq!(bin(WsCommand::SendDirect { room_code: "r".into(), target_peer: "p".into(), data: vec![1] }), b"\x04r\x00p\x00\x01");
        assert_eq!(bin(WsCommand::SendDirectImage { room_code: "r".into(), target_peer: "p".into(), data: vec![1] }), b"\x08r\x00p\x00\x01");
        assert_eq!(bin(WsCommand::SendBinaryDirect { room_code: "r".into(), target_peer: "p".into(), data: vec![1] }), b"\x02r\x00p\x00\x01");
        assert_eq!(bin(WsCommand::SendToRoomTopic { room_code: "r".into(), topic: "t".into(), data: vec![1] }), b"\x07r\x00t\x00\x01");
        assert_eq!(
            bin(WsCommand::SendChannelDirect { room_code: "r".into(), target_peer: "p".into(), channel_id: "c".into(), mention: true, data: vec![9] }),
            b"\x09r\x00p\x00c\x00\x01\x09"
        );
        assert_eq!(
            bin(WsCommand::SendChannelDirect { room_code: "r".into(), target_peer: "p".into(), channel_id: "c".into(), mention: false, data: vec![] }),
            b"\x09r\x00p\x00c\x00\x00"
        );
        assert_eq!(text(WsCommand::Subscribe { room_code: "r".into(), topics: vec!["a".into()] }), serde_json::json!({ "type": "subscribe", "room": "r", "topics": ["a"] }));
        assert_eq!(text(WsCommand::SetOfflineBuffer { enabled: true, retention_secs: 5 }), serde_json::json!({ "type": "set_offline_buffer", "enabled": true, "retention_secs": 5 }));
        assert_eq!(text(WsCommand::SetPushPrefs { prefs_json: r#"{"s":{"level":"all"}}"#.into() })["prefs"]["s"]["level"], "all");
        assert!(command_frame(&WsCommand::SetPushPrefs { prefs_json: "not json".into() }).is_none(), "malformed prefs write nothing");
        assert_eq!(text(WsCommand::KillAck { signal: None }), kill_ack_frame(None));
        assert!(command_frame(&WsCommand::SetDoor { room_code: "r".into(), door: None }).is_none());
        for frame in [
            command_frame(&WsCommand::SendToRoom { room_code: "r".into(), data: vec![1] }).unwrap(),
            command_frame(&WsCommand::GetTurnCredentials).unwrap(),
            command_frame(&WsCommand::Subscribe { room_code: "r".into(), topics: vec![] }).unwrap(),
        ] {
            assert_eq!(relay_session::client_frame_counts(&frame), 1, "every command is a stream frame: {frame:?}");
        }
    }

    /// The prune reads the seal of a queued frame: a live-only message ranks by its seal
    /// time, everything else (another message, an unsealed or truncated body) is ordinary.
    #[test]
    fn queued_frames_rank_by_what_their_seal_carries() {
        let kp = crate::identity::native_identity::NativeKeypair::from_secret_bytes(&[3; 32]);
        let at = 1_790_000_000_000i64;
        let seal = |msg: &super::super::types::HavenMessage, route: &str| {
            super::super::frame_auth::seal_at(&kp, "r", route, at, [7; 16], &serde_json::to_vec(msg).unwrap())
        };
        let live = seal(&super::super::types::HavenMessage::FriendListRequest, "12D3KooWTarget");
        let kept = seal(&super::super::types::HavenMessage::FriendRemove, "12D3KooWTarget");
        assert_eq!(sealed_class(&live), Class::LiveOnly { sealed_ms: at });
        assert_eq!(sealed_class(&kept), Class::Ordinary);
        assert_eq!(sealed_class(b"{\"plain\":true}"), Class::Ordinary);
        assert_eq!(sealed_class(&live[..20]), Class::Ordinary);

        let direct = WsCommand::SendDirect { room_code: "r".into(), target_peer: "12D3KooWTarget".into(), data: live.clone() };
        assert_eq!(direct.class(), Class::LiveOnly { sealed_ms: at });
        let wire = command_frame(&direct).unwrap();
        assert_eq!(WsCommand::frame_class(&wire), Class::LiveOnly { sealed_ms: at }, "a written frame keeps its rank");
        let channel = WsCommand::SendChannelDirect {
            room_code: "r".into(), target_peer: "12D3KooWTarget".into(), channel_id: "c".into(), mention: false, data: live,
        };
        assert_eq!(WsCommand::frame_class(&command_frame(&channel).unwrap()), Class::LiveOnly { sealed_ms: at });
        assert_eq!(WsCommand::JoinRoom { room_code: "r".into() }.class(), Class::RoomState);
        assert_eq!(WsCommand::GetTurnCredentials.class(), Class::Ordinary);
        assert_eq!(binary_payload(b"\x05r\x00x"), None, "a relay opcode is no client frame");
    }
}
