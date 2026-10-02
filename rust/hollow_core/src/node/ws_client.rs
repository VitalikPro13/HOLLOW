//! WebSocket client for the Hollow relay room router.
//!
//! Maintains a persistent WSS connection to the relay server.
//! Handles authentication, room join/leave, message routing, and auto-reconnect.

use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, RwLock};
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::Message;

use base64::Engine;

use crate::hollow_log;

/// Max time with NO inbound traffic from the relay (any frame: text, binary,
/// ping or pong) before the socket is declared a zombie and force-reconnected.
///
/// A silently-dropped network path lets local writes succeed into the OS buffer
/// with no error, so a write-failure check alone never fires. The relay pings
/// automatically, so a HEALTHY connection always refreshes `last_recv` well
/// inside this window; 70s tolerates one lost 30s keepalive cycle.
const LIVENESS_TIMEOUT: Duration = Duration::from_secs(70);

/// Max time for ONE socket write before the connection is declared wedged.
///
/// The liveness deadline cannot catch a peer whose KERNEL stays alive but whose
/// application stops reading: it ACKs with a zero TCP window, an in-flight
/// `SinkExt::send` pends FOREVER with no error, and while that await is pending
/// `tokio::select!` polls no other arm, so the liveness check can never run.
/// 30s because the largest frame, a 256 KB stream chunk, reaches the OS buffer
/// well inside it even on a dreadful uplink.
const WRITE_TIMEOUT: Duration = Duration::from_secs(30);

// -- Public types --

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
    LeaveRoom { room_code: String },
    /// Broadcast an encrypted message to all peers in a room.
    SendToRoom { room_code: String, data: Vec<u8> },
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
    /// owns the sessions (`olm_lane`).
    Carry { device: String, room: Option<String>, json: String, no_session: super::olm_lane::NoSession },
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
    /// consumed generations). 0 = everything still in retention.
    TopicCatchup { room_code: String, channel_id: String, max_age_secs: i64 },
    /// Park a destruction order for devices that are NOT connected. `blob` is
    /// opaque to the relay (base64 of the signed payload), capped at 2 KB, at most
    /// 16 targets per deposit. The relay hands it over on the target's next auth
    /// and keeps it until that device acks.
    KillDeposit { targets: Vec<String>, issued_at_ms: i64, blob: String },
    /// Delete OUR OWN parked entry. Sent after a wipe and after a PERMANENT
    /// rejection: without it the relay re-sends on every auth for a year.
    /// `issued_at_ms` names the one signal answered, so turning away a junk
    /// deposit never takes a genuine order with it; `None` clears them all.
    KillAck { issued_at_ms: Option<i64> },
    /// Drop this device's push token from the relay (wipe step 5). No reply.
    UnregisterPushToken,
    /// Ask the relay for the join lock chains of these servers, as (server id, owner
    /// id or empty). One `LockChain` answers each.
    LockGet { locks: Vec<(String, String)> },
    /// Offer the relay a join lock chain (or its next links) for a server. Answered
    /// by a `LockChain` naming whether the relay took it.
    LockPut { server: String, owner: String, links: Vec<super::join_lock::LockLink> },
    /// File a user report with the relay. One-shot — deliberately NOT cached
    /// in `track_room_change`, so it is never re-sent on reconnect (the relay
    /// also dedups per (reporter, target, category) via hashed keys).
    ReportUser { target: String, category: String },
}

/// Events received from the WebSocket relay, forwarded to the swarm.
#[derive(Debug, Clone)]
pub enum WsEvent {
    Connected,
    Disconnected,
    /// A connect attempt is starting. `reconnecting` is true for backoff retries
    /// after a drop, false for the very first attempt.
    Connecting { reconnecting: bool },
    PeerJoined { room: String, peer_id: String },
    PeerLeft { room: String, peer_id: String },
    /// WE left a room, emitted locally when the Leave frame goes out (the relay
    /// never echoes our own leave). The swarm MUST purge its `ws_room_peers` for
    /// the room: no more PeerLeft/RoomMembers arrive for a room we are not in, so
    /// the frozen list stays forever and `ws_room_for_peer`'s first match can
    /// route targeted sends into it, which the relay then drops.
    LeftRoom { room: String },
    RoomMembers { room: String, peers: Vec<String> },
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
    KillSignal { blob: String, issued_at_ms: i64 },
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
            Self::Disconnected => "Disconnected",
            Self::Connecting { .. } => "Connecting",
            Self::PeerJoined { .. } => "PeerJoined",
            Self::PeerLeft { .. } => "PeerLeft",
            Self::LeftRoom { .. } => "LeftRoom",
            Self::RoomMembers { .. } => "RoomMembers",
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

// -- Wire protocol (matches relay/src/ws_router.rs) --

fn is_false(v: &bool) -> bool { !*v }

#[derive(Serialize)]
#[serde(tag = "type")]
#[serde(rename_all = "snake_case")]
enum ClientMsg {
    /// Asks the relay for the challenge the auth signature covers.
    AuthHello,
    Auth {
        /// Always 2: the signature covers the relay's challenge, its domain and
        /// every flag ([`auth_v2_message`]).
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
    },
    Join {
        room: String,
        /// The joiner's own roster, for an `inbox:{master}` room: the relay folds it
        /// into what it holds for the master and lets in only a member.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        inbox_roster: Option<crate::identity::roster::Roster>,
    },
    Leave { room: String },
}

#[derive(Deserialize)]
#[serde(tag = "type")]
#[serde(rename_all = "snake_case")]
enum ServerMsg {
    AuthChallenge { nonce: String },
    AuthOk,
    AuthFailed { error: String },
    PeerJoined { room: String, peer_id: String },
    PeerLeft { room: String, peer_id: String },
    Members { room: String, peers: Vec<String> },
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
    KillSignal { #[serde(default)] blob: String, #[serde(default)] issued_at_ms: i64 },
    KillDeposited { #[serde(default)] stored: u32 },
    LockChain {
        server: String,
        #[serde(default)] links: Vec<super::join_lock::LockLink>,
        #[serde(default)] put: Option<bool>,
    },
}

// -- State --

const ROOM_BUDGET_LIMIT: u32 = 2000;

struct WsClientState {
    /// Rooms we've joined (for re-join on reconnect).
    joined_rooms: Arc<RwLock<HashSet<String>>>,
    /// Last room we attempted to join (for error rollback).
    last_join_attempt: Arc<RwLock<Option<String>>>,
    /// Channel-topic subscriptions per room, for re-subscribe on reconnect. The
    /// relay keeps them as PER-SOCKET state, so a silent reconnect leaves the
    /// client receiving room traffic but ZERO topic-routed channel messages. The
    /// latest Subscribe per room wins, replayed right after the room re-joins.
    subscriptions: Arc<RwLock<std::collections::HashMap<String, Vec<String>>>>,
    /// Latest opt-in offline-delivery setting (enabled, retention_secs) — the
    /// relay registry is RAM-per-relay-lifetime, so replay it on every
    /// reconnect like subscriptions. None = never set this session.
    offline_optin: Arc<RwLock<Option<(bool, i64)>>>,
    /// The roster each `inbox:` room was joined with via [`WsCommand::JoinInbox`]. The
    /// reconnect replay re-sends it: a plain `Join` on a NEW socket owns nothing.
    inbox_rosters: Arc<RwLock<std::collections::HashMap<String, crate::identity::roster::Roster>>>,
    /// The host we dialled; TURN URIs naming any other host are dropped.
    relay_host: String,
}

// -- Public API --

/// Spawn the WebSocket client as a background task.
/// Returns a JoinHandle that runs forever (auto-reconnects).
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
    tokio::spawn(async move {
        ws_client_loop(relay_url, peer_id, keypair_proto, pub_key_b64, license_key, fetch, cmd_rx, event_tx).await;
    })
}

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
/// [REALTIME_RETRY_SECS] while a call is live.
static REALTIME_ACTIVE: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

/// Retry interval while a real-time session is live. Fast enough that the socket
/// is back within a second of the network returning, so a user whose internet is
/// working again does not sit watching "Reconnecting".
const REALTIME_RETRY_SECS: u64 = 1;

/// Set from the FFI when a call / voice channel / conference starts or ends.
pub fn set_realtime_active(active: bool) {
    REALTIME_ACTIVE.store(active, std::sync::atomic::Ordering::Relaxed);
}

pub(crate) fn realtime_active() -> bool {
    REALTIME_ACTIVE.load(std::sync::atomic::Ordering::Relaxed)
}

async fn ws_client_loop(
    relay_url: String,
    peer_id: String,
    keypair_proto: Vec<u8>,
    pub_key_b64: String,
    license_key: Option<String>,
    fetch: bool,
    mut cmd_rx: mpsc::UnboundedReceiver<WsCommand>,
    event_tx: mpsc::UnboundedSender<WsEvent>,
) {
    let state = WsClientState {
        joined_rooms: Arc::new(RwLock::new(HashSet::new())),
        last_join_attempt: Arc::new(RwLock::new(None)),
        subscriptions: Arc::new(RwLock::new(std::collections::HashMap::new())),
        offline_optin: Arc::new(RwLock::new(None)),
        inbox_rosters: Arc::new(RwLock::new(std::collections::HashMap::new())),
        relay_host: relay_auth_domain(&relay_url).unwrap_or_default(),
    };

    let mut backoff_secs = 1u64;
    let mut pending_commands: Vec<WsCommand> = Vec::new();
    let mut license_busy_notified = false;

    'reconnect: loop {
        hollow_log!("[HOLLOW-WS] Connecting to {relay_url}...");
        // backoff_secs > 1 means a prior connection dropped (it resets to 1 on
        // success), so this attempt is a reconnect rather than the first connect.
        let _ = event_tx.send(WsEvent::Connecting { reconnecting: backoff_secs > 1 });

        match connect_and_auth(&relay_url, &peer_id, &keypair_proto, &pub_key_b64, license_key.as_deref(), fetch).await {
            Ok(ws_stream) => {
                backoff_secs = 1; // Reset backoff on successful connect.
                let _ = event_tx.send(WsEvent::Connected);
                hollow_log!("[HOLLOW-WS] Connected and authenticated");
                license_busy_notified = false;

                let (mut ws_write, mut ws_read) = ws_stream.split();
                {
                    let rooms = state.joined_rooms.read().await;
                    let rosters = state.inbox_rosters.read().await;
                    for room in rooms.iter() {
                        let join_msg = serde_json::to_string(&ClientMsg::Join {
                            room: room.clone(),
                            inbox_roster: rosters.get(room).cloned(),
                        })
                            .unwrap_or_default();
                        let _ = bounded_send(&mut ws_write, Message::Text(join_msg.into())).await;
                    }
                    let _ = event_tx.send(WsEvent::RoomBudgetUpdate { joined: rooms.len() as u32, limit: ROOM_BUDGET_LIMIT });
                }

                // Re-subscribe channel topics: the relay's subscription state is
                // per-socket and died with the old connection.
                {
                    let subs = state.subscriptions.read().await;
                    for (room, topics) in subs.iter() {
                        let msg = serde_json::json!({
                            "type": "subscribe",
                            "room": room,
                            "topics": topics,
                        });
                        if bounded_send(&mut ws_write, Message::Text(msg.to_string().into())).await.is_err() {
                            hollow_log!("[HOLLOW-WS] Re-subscribe send failed for room {room}");
                            break;
                        }
                    }
                    if !subs.is_empty() {
                        hollow_log!("[HOLLOW-WS] Re-subscribed topics for {} room(s) after reconnect", subs.len());
                    }
                }

                // Re-register the opt-in offline-delivery setting — the relay
                // registry is RAM-only and a relay restart would silently
                // drop this peer back to the 24h push baseline.
                {
                    let optin = *state.offline_optin.read().await;
                    if let Some((enabled, retention_secs)) = optin {
                        let msg = serde_json::json!({
                            "type": "set_offline_buffer",
                            "enabled": enabled,
                            "retention_secs": retention_secs,
                        });
                        if bounded_send(&mut ws_write, Message::Text(msg.to_string().into())).await.is_err() {
                            hollow_log!("[HOLLOW-WS] Offline-buffer re-register send failed");
                        }
                    }
                }

                {
                    let cmds: Vec<WsCommand> = pending_commands.drain(..).collect();
                    for cmd in cmds {
                        if !send_command(&mut ws_write, &cmd).await {
                            hollow_log!("[HOLLOW-WS] Replay failed — connection dead again");
                            pending_commands.push(cmd);
                            break;
                        }
                        track_room_change(&state, &cmd, &event_tx).await;
                    }
                }

                let mut ping_timer = tokio::time::interval(Duration::from_secs(30));
                ping_timer.tick().await; // consume immediate first tick
                // Liveness: last time ANY inbound relay frame arrived. A healthy
                // socket is refreshed by the relay's automatic pings + our own
                // pong replies + real traffic; a zombie path stops refreshing it.
                let mut last_recv = tokio::time::Instant::now();
                loop {
                    tokio::select! {
                        // Keepalive ping — prevents Nginx/proxy/relay from closing idle connections.
                        _ = ping_timer.tick() => {
                            // Zombie-socket detection: past the deadline the
                            // write below would still "succeed" into a dead OS
                            // buffer, so check liveness FIRST and reconnect.
                            if last_recv.elapsed() > LIVENESS_TIMEOUT {
                                hollow_log!(
                                    "[HOLLOW-WS] Liveness timeout — no relay traffic in {}s, reconnecting",
                                    last_recv.elapsed().as_secs()
                                );
                                break;
                            }
                            if let Err(e) = bounded_send(&mut ws_write, Message::Ping(vec![0x01].into())).await {
                                hollow_log!("[HOLLOW-WS] Ping failed: {e}");
                                break; // Connection dead, trigger reconnect.
                            }
                        }
                        msg = ws_read.next() => {
                            // Any successfully-read frame proves the socket is
                            // alive in BOTH directions, and the relay's own
                            // automatic pings keep this fresh even when idle.
                            if matches!(msg, Some(Ok(_))) {
                                last_recv = tokio::time::Instant::now();
                            }
                            match msg {
                                Some(Ok(Message::Text(text))) => {
                                    if let Ok(server_msg) = serde_json::from_str::<ServerMsg>(&text) {
                                        handle_server_message(&event_tx, server_msg, &state).await;
                                    }
                                }
                                Some(Ok(Message::Binary(data))) => {
                                    if data.len() > 3 {
                                        match data[0] {
                                            0x02 => {
                                                if let Some((room, from, payload)) = parse_binary_relay_frame(&data[1..]) {
                                                    let _ = event_tx.send(WsEvent::BinaryDirect {
                                                        room, from, data: payload,
                                                    });
                                                }
                                            }
                                            0x05 => {
                                                if let Some((room, from, payload)) = parse_binary_relay_frame(&data[1..]) {
                                                    let _ = event_tx.send(WsEvent::Message {
                                                        room, from, data: payload,
                                                    });
                                                }
                                            }
                                            0x06 => {
                                                if let Some((room, from, payload)) = parse_binary_relay_frame(&data[1..]) {
                                                    let _ = event_tx.send(WsEvent::DirectMessage {
                                                        room, from, data: payload,
                                                    });
                                                }
                                            }
                                            0x08 => {
                                                // Topic broadcast: [0x08][room\0][topic\0][sender\0][payload]
                                                let rest = &data[1..];
                                                if let Some(room_end) = rest.iter().position(|&b| b == 0) {
                                                    let room = String::from_utf8_lossy(&rest[..room_end]).to_string();
                                                    let after_room = &rest[room_end + 1..];
                                                    if let Some(topic_end) = after_room.iter().position(|&b| b == 0) {
                                                        let after_topic = &after_room[topic_end + 1..];
                                                        if let Some(sender_end) = after_topic.iter().position(|&b| b == 0) {
                                                            let from = String::from_utf8_lossy(&after_topic[..sender_end]).to_string();
                                                            let payload = after_topic[sender_end + 1..].to_vec();
                                                            let _ = event_tx.send(WsEvent::Message {
                                                                room, from, data: payload,
                                                            });
                                                        }
                                                    }
                                                }
                                            }
                                            _ => {}
                                        }
                                    }
                                }
                                Some(Ok(Message::Ping(data))) => {
                                    // A failed/wedged pong reply is a dead
                                    // connection — reconnect, don't limp on.
                                    if let Err(e) =
                                        bounded_send(&mut ws_write, Message::Pong(data)).await
                                    {
                                        hollow_log!("[HOLLOW-WS] Pong reply failed: {e}");
                                        break;
                                    }
                                }
                                Some(Ok(Message::Pong(_))) => {
                                    // Reply to our keepalive ping; liveness is
                                    // already refreshed above.
                                }
                                Some(Ok(Message::Close(frame))) => {
                                    // Log the relay's close reason: it never
                                    // closes silently (bad_license, auth timeout).
                                    let reason = frame
                                        .as_ref()
                                        .map(|f| f.reason.to_string())
                                        .unwrap_or_default();
                                    hollow_log!("[HOLLOW-WS] Connection closed by server: {reason}");
                                    break;
                                }
                                None => {
                                    hollow_log!("[HOLLOW-WS] Connection closed by server");
                                    break;
                                }
                                Some(Err(e)) => {
                                    hollow_log!("[HOLLOW-WS] Read error: {e}");
                                    break;
                                }
                                _ => {}
                            }
                        }
                        maybe_cmd = cmd_rx.recv() => {
                            // None = the swarm dropped the command sender, so the
                            // node is shutting down. Exit BOTH loops, or `select!`
                            // just disables this arm and keeps the socket alive,
                            // pinging and reconnecting forever (a per-restart leak).
                            let Some(cmd) = maybe_cmd else {
                                hollow_log!("[HOLLOW-WS] Command channel closed — shutting down WS client task");
                                break 'reconnect;
                            };
                            if !send_command(&mut ws_write, &cmd).await {
                                hollow_log!("[HOLLOW-WS] Send failed — connection dead, reconnecting");
                                pending_commands.push(cmd);
                                break;
                            }
                            track_room_change(&state, &cmd, &event_tx).await;
                        }
                    }
                }
            }
            Err(e) => {
                hollow_log!("[HOLLOW-WS] Connection failed: {e}");
                // A busy key is still OUR key: the holder is usually our own ghost
                // socket or a sibling device, so keep the backoff going and tell
                // the UI once per outage; only a refused key stops the loop. Only
                // the relay's exact refusal codes count, never text that merely
                // mentions a license.
                match e {
                    ConnectError::License(LicenseRefusal::InUse) => {
                        if !license_busy_notified {
                            license_busy_notified = true;
                            let _ = event_tx.send(WsEvent::LicenseError { reason: LicenseRefusal::InUse.code().into() });
                        }
                    }
                    ConnectError::License(refusal) => {
                        hollow_log!("[HOLLOW-WS] License refused, not retrying");
                        let _ = event_tx.send(WsEvent::LicenseError { reason: refusal.code().into() });
                        return;
                    }
                    ConnectError::Other(_) => {}
                }
            }
        }

        let _ = event_tx.send(WsEvent::Disconnected);

        // Drain any commands that arrived during the failed connection attempt.
        // If the channel is CLOSED (sender dropped → node shutting down), stop
        // reconnecting and end the task instead of looping forever.
        loop {
            match cmd_rx.try_recv() {
                Ok(cmd) => {
                    track_room_change(&state, &cmd, &event_tx).await;
                    pending_commands.push(cmd);
                }
                Err(mpsc::error::TryRecvError::Empty) => break,
                Err(mpsc::error::TryRecvError::Disconnected) => {
                    hollow_log!("[HOLLOW-WS] Command channel closed during reconnect — shutting down WS client task");
                    break 'reconnect;
                }
            }
        }

        // Backoff, unless a call is riding on this socket: a live session retries
        // at a steady short interval and does NOT let the ladder climb, so an ICE
        // restart can be delivered inside the call's hold-open window. See
        // REALTIME_ACTIVE for why this is conditional rather than a lower cap.
        if realtime_active() {
            hollow_log!(
                "[HOLLOW-WS] Reconnecting in {REALTIME_RETRY_SECS}s (call in progress)..."
            );
            tokio::time::sleep(Duration::from_secs(REALTIME_RETRY_SECS)).await;
            backoff_secs = 1;
        } else {
            hollow_log!("[HOLLOW-WS] Reconnecting in {backoff_secs}s...");
            tokio::time::sleep(Duration::from_secs(backoff_secs)).await;
            backoff_secs = (backoff_secs * 2).min(30);
        }
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

fn license_digest(key: Option<&str>) -> String {
    use sha2::{Digest, Sha256};
    key.filter(|k| !k.is_empty())
        .map(|k| hex::encode(Sha256::digest(k.as_bytes())))
        .unwrap_or_default()
}

fn is_auth_nonce(nonce: &str) -> bool {
    nonce.len() == 64 && nonce.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Reads the relay's next text frame as a [`ServerMsg`], within the auth window.
async fn read_auth_reply<S>(read: &mut S) -> Result<(ServerMsg, String), ConnectError>
where
    S: futures_util::Stream<Item = Result<Message, tokio_tungstenite::tungstenite::Error>> + Unpin,
{
    let response = tokio::time::timeout(Duration::from_secs(5), read.next())
        .await
        .map_err(|_| "Auth timeout".to_string())?
        .ok_or_else(|| "Connection closed before auth response".to_string())?
        .map_err(|e| format!("Read error: {e}"))?;
    let Message::Text(text) = response else {
        return Err("Unexpected auth response".to_string().into());
    };
    match serde_json::from_str::<ServerMsg>(&text) {
        Ok(msg) => Ok((msg, text.to_string())),
        Err(_) => Err(format!("Auth rejected: {text}").into()),
    }
}

pub(crate) async fn connect_and_auth(
    url: &str,
    peer_id: &str,
    keypair_proto: &[u8],
    pub_key_b64: &str,
    license_key: Option<&str>,
    fetch: bool,
) -> Result<WsStream, ConnectError> {
    let domain = relay_auth_domain(url).ok_or_else(|| format!("Bad relay URL: {url}"))?;

    let (ws_stream, _response) = tokio_tungstenite::connect_async(url)
        .await
        .map_err(|e| format!("WebSocket connect failed: {e}"))?;

    let (mut write, mut read) = ws_stream.split();

    let hello = serde_json::to_string(&ClientMsg::AuthHello).map_err(|e| format!("JSON error: {e}"))?;
    bounded_send(&mut write, Message::Text(hello.into()))
        .await
        .map_err(|e| format!("Failed to ask for a challenge: {e}"))?;
    let nonce = match read_auth_reply(&mut read).await? {
        (ServerMsg::AuthChallenge { nonce }, _) if is_auth_nonce(&nonce) => nonce,
        // A relay older than 0.12 answers the hello as a bad auth frame.
        (ServerMsg::AuthFailed { .. }, _) => {
            return Err("The relay offers no auth challenge (it needs updating)".to_string().into());
        }
        (_, text) => return Err(format!("Auth rejected: {text}").into()),
    };

    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let mode = if fetch { "fetch" } else { "full" };
    let sign_payload = auth_v2_message(&domain, &nonce, peer_id, timestamp, mode, &license_digest(license_key));

    let keypair = crate::identity::native_identity::NativeKeypair::from_protobuf_encoding(keypair_proto)
        .map_err(|e| format!("Failed to decode keypair: {e}"))?;
    let sig_bytes = keypair.sign(sign_payload.as_bytes());
    let sig_b64 = base64::engine::general_purpose::STANDARD.encode(&sig_bytes);

    let auth = ClientMsg::Auth {
        v: 2,
        peer_id: peer_id.to_string(),
        public_key: pub_key_b64.to_string(),
        timestamp,
        nonce,
        domain,
        signature: sig_b64,
        license_key: license_key.filter(|k| !k.is_empty()).map(|s| s.to_string()),
        fetch,
    };
    let auth_json = serde_json::to_string(&auth).map_err(|e| format!("JSON error: {e}"))?;
    bounded_send(&mut write, Message::Text(auth_json.into()))
        .await
        .map_err(|e| format!("Failed to send auth: {e}"))?;

    match read_auth_reply(&mut read).await? {
        (ServerMsg::AuthOk, _) => Ok(read.reunite(write).map_err(|e| format!("Reunite error: {e}"))?),
        (ServerMsg::AuthFailed { error }, _) => Err(match LicenseRefusal::from_code(&error) {
            Some(refusal) => ConnectError::License(refusal),
            None => ConnectError::Other(error),
        }),
        (_, text) => Err(format!("Auth rejected: {text}").into()),
    }
}

// -- Command sending --

type WsSink = futures_util::stream::SplitSink<WsStream, Message>;

/// Bounded socket write, the ONLY way this module writes to the sink. See
/// WRITE_TIMEOUT for why an unbounded `send` can freeze the entire client loop
/// with the liveness watchdog unable to run. A timeout is reported as an error
/// string, so every `Err -> reconnect` path handles it exactly like a dead socket.
async fn bounded_send(write: &mut WsSink, msg: Message) -> Result<(), String> {
    match tokio::time::timeout(WRITE_TIMEOUT, write.send(msg)).await {
        Ok(Ok(())) => Ok(()),
        Ok(Err(e)) => Err(e.to_string()),
        Err(_) => Err(format!(
            "write timed out after {}s — connection wedged",
            WRITE_TIMEOUT.as_secs()
        )),
    }
}

/// Returns false if the send failed (connection dead — caller should break).
async fn send_command(write: &mut WsSink, cmd: &WsCommand) -> bool {
    match cmd {
        WsCommand::SendBinaryDirect { room_code, target_peer, data } => {
            let room = room_code.as_bytes();
            let target = target_peer.as_bytes();
            let mut frame = Vec::with_capacity(1 + room.len() + 1 + target.len() + 1 + data.len());
            frame.push(0x02);
            frame.extend_from_slice(room);
            frame.push(0x00);
            frame.extend_from_slice(target);
            frame.push(0x00);
            frame.extend_from_slice(data);
            if let Err(e) = bounded_send(write, Message::Binary(frame.into())).await {
                hollow_log!("[HOLLOW-WS] Binary send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::CheckPeers { peers, rooms } => {
            let msg = serde_json::json!({
                "type": "check_peers",
                "peers": peers,
                "rooms": rooms,
            });
            let text = msg.to_string();
            if let Err(e) = bounded_send(write, Message::Text(text.into())).await {
                hollow_log!("[HOLLOW-WS] CheckPeers send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::DiscoverPeers { room_code } => {
            let msg = serde_json::json!({
                "type": "discover_peers",
                "room": room_code,
            });
            let text = msg.to_string();
            if let Err(e) = bounded_send(write, Message::Text(text.into())).await {
                hollow_log!("[HOLLOW-WS] DiscoverPeers send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::GetTurnCredentials => {
            let msg = serde_json::json!({ "type": "get_turn_credentials" });
            let text = msg.to_string();
            if let Err(e) = bounded_send(write, Message::Text(text.into())).await {
                hollow_log!("[HOLLOW-WS] GetTurnCredentials send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::GetMediaForwarder => {
            let msg = serde_json::json!({ "type": "get_media_forwarder" });
            let text = msg.to_string();
            if let Err(e) = bounded_send(write, Message::Text(text.into())).await {
                hollow_log!("[HOLLOW-WS] GetMediaForwarder send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::Subscribe { room_code, topics } => {
            let msg = serde_json::json!({
                "type": "subscribe",
                "room": room_code,
                "topics": topics,
            });
            let text = msg.to_string();
            if let Err(e) = bounded_send(write, Message::Text(text.into())).await {
                hollow_log!("[HOLLOW-WS] Subscribe send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::ClaimNickname { nickname, master, claim } => {
            let msg = serde_json::json!({
                "type": "claim_nickname",
                "nickname": nickname,
                "master": master,
                "master_key": claim.master_key,
                "ts": claim.ts_ms,
                "sig": claim.sig,
            });
            if let Err(e) = bounded_send(write, Message::Text(msg.to_string().into())).await {
                hollow_log!("[HOLLOW-WS] ClaimNickname send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::ReleaseNickname => {
            let msg = serde_json::json!({ "type": "release_nickname" });
            if let Err(e) = bounded_send(write, Message::Text(msg.to_string().into())).await {
                hollow_log!("[HOLLOW-WS] ReleaseNickname send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::ResolveNickname { nickname } => {
            let msg = serde_json::json!({ "type": "resolve_nickname", "nickname": nickname });
            if let Err(e) = bounded_send(write, Message::Text(msg.to_string().into())).await {
                hollow_log!("[HOLLOW-WS] ResolveNickname send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::ClaimLinkCode { code } => {
            let msg = serde_json::json!({ "type": "claim_link_code", "code": code });
            if let Err(e) = bounded_send(write, Message::Text(msg.to_string().into())).await {
                hollow_log!("[HOLLOW-WS] ClaimLinkCode send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::ReleaseLinkCode => {
            let msg = serde_json::json!({ "type": "release_link_code" });
            if let Err(e) = bounded_send(write, Message::Text(msg.to_string().into())).await {
                hollow_log!("[HOLLOW-WS] ReleaseLinkCode send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::ResolveLinkCode { code } => {
            let msg = serde_json::json!({ "type": "resolve_link_code", "code": code });
            if let Err(e) = bounded_send(write, Message::Text(msg.to_string().into())).await {
                hollow_log!("[HOLLOW-WS] ResolveLinkCode send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::RegisterPushToken { token, platform } => {
            let msg = serde_json::json!({ "type": "register_push_token", "token": token, "platform": platform });
            if let Err(e) = bounded_send(write, Message::Text(msg.to_string().into())).await {
                hollow_log!("[HOLLOW-WS] RegisterPushToken send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::SetPushPrefs { prefs_json } => {
            // Embed the prefs as a real JSON object (not a string) so the relay
            // parses it directly. A malformed prefs string is dropped here.
            let Ok(prefs) = serde_json::from_str::<serde_json::Value>(prefs_json) else {
                hollow_log!("[HOLLOW-WS] SetPushPrefs: invalid prefs JSON — skipped");
                return true;
            };
            let msg = serde_json::json!({ "type": "set_push_prefs", "prefs": prefs });
            if let Err(e) = bounded_send(write, Message::Text(msg.to_string().into())).await {
                hollow_log!("[HOLLOW-WS] SetPushPrefs send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::SetOfflineBuffer { enabled, retention_secs } => {
            let msg = serde_json::json!({
                "type": "set_offline_buffer",
                "enabled": enabled,
                "retention_secs": retention_secs,
            });
            if let Err(e) = bounded_send(write, Message::Text(msg.to_string().into())).await {
                hollow_log!("[HOLLOW-WS] SetOfflineBuffer send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::ReportUser { target, category } => {
            let msg = serde_json::json!({
                "type": "report",
                "target": target,
                "category": category,
            });
            if let Err(e) = bounded_send(write, Message::Text(msg.to_string().into())).await {
                hollow_log!("[HOLLOW-WS] ReportUser send failed: {e}");
                return false;
            }
            return true;
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
            if let Err(e) = bounded_send(write, Message::Text(msg.to_string().into())).await {
                hollow_log!("[HOLLOW-WS] SetTopicBuffer send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::TopicCatchup { room_code, channel_id, max_age_secs } => {
            let msg = serde_json::json!({
                "type": "topic_catchup",
                "room": room_code,
                "channel": channel_id,
                "max_age_secs": max_age_secs,
            });
            if let Err(e) = bounded_send(write, Message::Text(msg.to_string().into())).await {
                hollow_log!("[HOLLOW-WS] TopicCatchup send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::SendChannelDirect { room_code, target_peer, channel_id, mention, data } => {
            // [0x09][room\0][target\0][channel\0][flags:1][payload]
            // flags bit0 = mention. Payload may be empty (push trigger only).
            let room = room_code.as_bytes();
            let target = target_peer.as_bytes();
            let channel = channel_id.as_bytes();
            let mut frame = Vec::with_capacity(
                1 + room.len() + 1 + target.len() + 1 + channel.len() + 1 + 1 + data.len(),
            );
            frame.push(0x09);
            frame.extend_from_slice(room);
            frame.push(0x00);
            frame.extend_from_slice(target);
            frame.push(0x00);
            frame.extend_from_slice(channel);
            frame.push(0x00);
            frame.push(if *mention { 0x01 } else { 0x00 });
            frame.extend_from_slice(data);
            if let Err(e) = bounded_send(write, Message::Binary(frame.into())).await {
                hollow_log!("[HOLLOW-WS] Channel direct send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::SendToRoomTopic { room_code, topic, data } => {
            let mut frame = Vec::with_capacity(1 + room_code.len() + 1 + topic.len() + 1 + data.len());
            frame.push(0x07);
            frame.extend_from_slice(room_code.as_bytes());
            frame.push(0x00);
            frame.extend_from_slice(topic.as_bytes());
            frame.push(0x00);
            frame.extend_from_slice(data);
            if let Err(e) = bounded_send(write, Message::Binary(frame.into())).await {
                hollow_log!("[HOLLOW-WS] Topic send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::SendToRoom { room_code, data } => {
            let room = room_code.as_bytes();
            let mut frame = Vec::with_capacity(1 + room.len() + 1 + data.len());
            frame.push(0x03);
            frame.extend_from_slice(room);
            frame.push(0x00);
            frame.extend_from_slice(data);
            if let Err(e) = bounded_send(write, Message::Binary(frame.into())).await {
                hollow_log!("[HOLLOW-WS] Room send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::SendDirect { room_code, target_peer, data } => {
            let room = room_code.as_bytes();
            let target = target_peer.as_bytes();
            let mut frame = Vec::with_capacity(1 + room.len() + 1 + target.len() + 1 + data.len());
            frame.push(0x04);
            frame.extend_from_slice(room);
            frame.push(0x00);
            frame.extend_from_slice(target);
            frame.push(0x00);
            frame.extend_from_slice(data);
            if let Err(e) = bounded_send(write, Message::Binary(frame.into())).await {
                hollow_log!("[HOLLOW-WS] Direct send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::SendDirectImage { room_code, target_peer, data } => {
            // Same layout as 0x04 SendDirect, but a 0x08 type byte tells the relay
            // this direct carries an inlined image, so the image cap applies.
            let room = room_code.as_bytes();
            let target = target_peer.as_bytes();
            let mut frame = Vec::with_capacity(1 + room.len() + 1 + target.len() + 1 + data.len());
            frame.push(0x08);
            frame.extend_from_slice(room);
            frame.push(0x00);
            frame.extend_from_slice(target);
            frame.push(0x00);
            frame.extend_from_slice(data);
            if let Err(e) = bounded_send(write, Message::Binary(frame.into())).await {
                hollow_log!("[HOLLOW-WS] Direct image send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::KillDeposit { targets, issued_at_ms, blob } => {
            let msg = serde_json::json!({
                "type": "kill_deposit",
                "targets": targets,
                "issued_at_ms": issued_at_ms,
                "blob": blob,
            });
            if let Err(e) = bounded_send(write, Message::Text(msg.to_string().into())).await {
                hollow_log!("[HOLLOW-WS] KillDeposit send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::KillAck { issued_at_ms } => {
            let mut msg = serde_json::json!({ "type": "kill_ack" });
            if let Some(stamp) = issued_at_ms {
                msg["issued_at_ms"] = serde_json::json!(stamp);
            }
            if let Err(e) = bounded_send(write, Message::Text(msg.to_string().into())).await {
                hollow_log!("[HOLLOW-WS] KillAck send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::LockGet { locks } => {
            let locks: Vec<serde_json::Value> = locks
                .iter()
                .map(|(server, owner)| serde_json::json!({ "server": server, "owner": owner }))
                .collect();
            let msg = serde_json::json!({ "type": "lock_get", "locks": locks });
            if let Err(e) = bounded_send(write, Message::Text(msg.to_string().into())).await {
                hollow_log!("[HOLLOW-WS] LockGet send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::LockPut { server, owner, links } => {
            let msg = serde_json::json!({ "type": "lock_put", "server": server, "owner": owner, "links": links });
            if let Err(e) = bounded_send(write, Message::Text(msg.to_string().into())).await {
                hollow_log!("[HOLLOW-WS] LockPut send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::UnregisterPushToken => {
            let msg = serde_json::json!({ "type": "unregister_push_token" });
            if let Err(e) = bounded_send(write, Message::Text(msg.to_string().into())).await {
                hollow_log!("[HOLLOW-WS] UnregisterPushToken send failed: {e}");
                return false;
            }
            return true;
        }
        _ => {}
    }

    let json = match cmd {
        WsCommand::JoinRoom { room_code } => {
            serde_json::to_string(&ClientMsg::Join {
                room: room_code.clone(),
                inbox_roster: None,
            })
        }
        WsCommand::JoinInbox { room_code, roster } => {
            serde_json::to_string(&ClientMsg::Join {
                room: room_code.clone(),
                inbox_roster: Some(roster.clone()),
            })
        }
        WsCommand::LeaveRoom { room_code } => {
            serde_json::to_string(&ClientMsg::Leave { room: room_code.clone() })
        }
        _ => return true,
    };

    if let Ok(json) = json {
        if let Err(e) = bounded_send(write, Message::Text(json.into())).await {
            hollow_log!("[HOLLOW-WS] Send failed: {e}");
            return false;
        }
    }
    true
}

async fn track_room_change(state: &WsClientState, cmd: &WsCommand, event_tx: &mpsc::UnboundedSender<WsEvent>) {
    let count = match cmd {
        WsCommand::JoinRoom { room_code } => {
            *state.last_join_attempt.write().await = Some(room_code.clone());
            let mut rooms = state.joined_rooms.write().await;
            rooms.insert(room_code.clone());
            rooms.len() as u32
        }
        WsCommand::JoinInbox { room_code, roster } => {
            *state.last_join_attempt.write().await = Some(room_code.clone());
            state
                .inbox_rosters
                .write()
                .await
                .insert(room_code.clone(), roster.clone());
            let mut rooms = state.joined_rooms.write().await;
            rooms.insert(room_code.clone());
            rooms.len() as u32
        }
        WsCommand::LeaveRoom { room_code } => {
            let mut rooms = state.joined_rooms.write().await;
            rooms.remove(room_code);
            state.subscriptions.write().await.remove(room_code);
            state.inbox_rosters.write().await.remove(room_code);
            // Confirm our own leave to the swarm so it purges the room from
            // `ws_room_peers` — see WsEvent::LeftRoom.
            let _ = event_tx.send(WsEvent::LeftRoom { room: room_code.clone() });
            rooms.len() as u32
        }
        WsCommand::Subscribe { room_code, topics } => {
            // Remember the latest topic set per room so a reconnect can
            // replay it — the relay's subscription state is per-socket.
            state
                .subscriptions
                .write()
                .await
                .insert(room_code.clone(), topics.clone());
            return;
        }
        WsCommand::SetOfflineBuffer { enabled, retention_secs } => {
            // Remember the latest opt-in so a reconnect can re-register it —
            // the relay registry dies with a relay restart.
            *state.offline_optin.write().await = Some((*enabled, *retention_secs));
            return;
        }
        _ => return,
    };
    let _ = event_tx.send(WsEvent::RoomBudgetUpdate { joined: count, limit: ROOM_BUDGET_LIMIT });
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

// -- Server message handling --

async fn handle_server_message(event_tx: &mpsc::UnboundedSender<WsEvent>, msg: ServerMsg, state: &WsClientState) {
    let event = match msg {
        ServerMsg::PeerJoined { room, peer_id } => {
            hollow_log!("[HOLLOW-WS] Peer joined {room}: {peer_id}");
            WsEvent::PeerJoined { room, peer_id }
        }
        ServerMsg::PeerLeft { room, peer_id } => {
            hollow_log!("[HOLLOW-WS] Peer left {room}: {peer_id}");
            WsEvent::PeerLeft { room, peer_id }
        }
        ServerMsg::Members { room, peers } => {
            hollow_log!("[HOLLOW-WS] Room {room} members: {} peers", peers.len());
            WsEvent::RoomMembers { room, peers }
        }
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
            let uris = turn_uris_on_relay(uris, &state.relay_host);
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
                let room = state.last_join_attempt.write().await.take().unwrap_or_default();
                if !room.is_empty() {
                    let count = {
                        let mut rooms = state.joined_rooms.write().await;
                        rooms.remove(&room);
                        rooms.len() as u32
                    };
                    let _ = event_tx.send(WsEvent::RoomBudgetUpdate { joined: count, limit: ROOM_BUDGET_LIMIT });
                    let _ = event_tx.send(WsEvent::RoomCapHit { room });
                }
            }
            return;
        }
        ServerMsg::NicknameClaimed { nickname } => {
            hollow_log!("[HOLLOW-WS] Nickname claimed: {nickname}");
            WsEvent::NicknameClaimed { nickname }
        }
        ServerMsg::NicknameReleased => {
            hollow_log!("[HOLLOW-WS] Nickname released");
            WsEvent::NicknameReleased
        }
        ServerMsg::NicknameError { error, nickname } => {
            hollow_log!("[HOLLOW-WS] Nickname error: {error} (nickname={nickname})");
            WsEvent::NicknameError { error, nickname }
        }
        ServerMsg::NicknameResolved { nickname, peer_id, master_id, master_key, ts, sig } => {
            hollow_log!("[HOLLOW-WS] Nickname resolved: {nickname} -> {peer_id} (master: {master_id})");
            let claim = super::nick_claim::NickClaim { master_key, ts_ms: ts, sig };
            WsEvent::NicknameResolved { nickname, peer_id, master_id, claim }
        }
        ServerMsg::LinkCodeClaimed { code } => {
            hollow_log!("[HOLLOW-LINK] Link code claimed: {code}");
            WsEvent::LinkCodeClaimed { code }
        }
        ServerMsg::LinkCodeReleased => {
            hollow_log!("[HOLLOW-LINK] Link code released");
            WsEvent::LinkCodeReleased
        }
        ServerMsg::LinkCodeError { error, code } => {
            hollow_log!("[HOLLOW-LINK] Link code error: {error} (code={code})");
            WsEvent::LinkCodeError { error, code }
        }
        ServerMsg::LinkCodeResolved { code, peer_id } => {
            hollow_log!("[HOLLOW-LINK] Link code resolved: {code} -> {peer_id}");
            WsEvent::LinkCodeResolved { code, peer_id }
        }
        ServerMsg::KillSignal { blob, issued_at_ms } => {
            // Nothing identifying: the blob is somebody's signed payload and the
            // target is us.
            hollow_log!("[HOLLOW-DESTROY] Kill signal received from the relay");
            WsEvent::KillSignal { blob, issued_at_ms }
        }
        ServerMsg::KillDeposited { stored } => {
            hollow_log!("[HOLLOW-DESTROY] Relay parked {stored} destruction order(s)");
            return;
        }
        ServerMsg::LockChain { server, links, put } => WsEvent::LockChain { server, links, put },
        ServerMsg::AuthChallenge { .. } | ServerMsg::AuthOk | ServerMsg::AuthFailed { .. } => return,
    };

    let _ = event_tx.send(event);
}

// -- Tests --

#[cfg(test)]
mod tests {
    use super::*;

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
        let msg = ClientMsg::Join { room: "server123".into(), inbox_roster: None };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"join\""));
        assert!(json.contains("\"room\":\"server123\""));
        assert!(!json.contains("inbox_roster"), "a plain join carries no roster");
    }

    /// The inbox join carries the roster the relay folds before it lets a device read
    /// the master's mailbox (design ID-1R), in the shape `relay-uws/src/roster.h` reads.
    #[test]
    fn test_join_message_carries_the_roster() {
        let k = |t: u8| crate::identity::native_identity::NativeKeypair::from_secret_bytes(&[t; 32]);
        let roster = crate::identity::roster::Roster::genesis(&k(0x7a), &k(0x7b), &k(0x7c), 1_000);
        let room = format!("inbox:{}", roster.master);
        let msg = ClientMsg::Join { room: room.clone(), inbox_roster: Some(roster) };
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
            ServerMsg::Members { room, peers } => {
                assert_eq!(room, "server1");
                assert_eq!(peers.len(), 2);
            }
            _ => panic!("Wrong variant"),
        }
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

}
