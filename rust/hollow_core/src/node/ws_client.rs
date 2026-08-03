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
/// ping, or pong) before we declare the socket a zombie and force a reconnect.
///
/// A silently-dropped network path (NAT/router/WiFi/ISP blip) lets local
/// socket writes succeed into the OS buffer with no error, so a
/// write-failure check alone never fires — the connection looks "alive" while
/// nothing reaches the relay and nothing comes back. The relay sends WS pings
/// automatically (`sendPingsAutomatically=true`, see relay-uws ws_handler.cpp)
/// and drops us at its own 120s idleTimeout, so a HEALTHY connection always
/// refreshes `last_recv` well within this window; only a truly dead path lets
/// it lapse. 70s = tolerate one lost 30s keepalive cycle, react on the next.
const LIVENESS_TIMEOUT: Duration = Duration::from_secs(70);

/// Max time for ONE socket write to complete before the connection is
/// declared wedged. The liveness deadline above cannot catch everything: a
/// peer whose KERNEL stays alive but whose application stops reading keeps
/// ACKing with a zero TCP window, so an in-flight `SinkExt::send` pends
/// FOREVER with no error — and while that await is pending, `tokio::select!`
/// polls no other arm, so the ping tick that runs the liveness check can
/// never fire. Observed 2026-07-20: desktop sat 2h11m frozen mid-write —
/// stale presence, every call invite silently vanished — until the relay
/// finally reset the socket. 30s: the largest relay frame is a 256 KB
/// stream chunk, which hands off to the OS buffer well inside 30s even on a
/// dreadful-but-alive uplink; only a genuinely wedged connection lapses.
const WRITE_TIMEOUT: Duration = Duration::from_secs(30);

// -- Public types --

/// Commands sent from the swarm to the WebSocket client.
#[derive(Debug, Clone)]
pub enum WsCommand {
    JoinRoom { room_code: String },
    LeaveRoom { room_code: String },
    /// Broadcast an encrypted message to all peers in a room.
    SendToRoom { room_code: String, data: Vec<u8> },
    /// Send directly to a specific peer in a room (for shard transfers).
    SendDirect { room_code: String, target_peer: String, data: Vec<u8> },
    /// Send directly to a specific peer, flagged as carrying an inlined image
    /// (Olm-encrypted FileHeader + inline bytes). Identical to SendDirect except
    /// it emits a 0x08 frame, so the relay applies the separate image cap
    /// (3 images/peer) to its offline buffer instead of the text cap.
    SendDirectImage { room_code: String, target_peer: String, data: Vec<u8> },
    /// Send binary data directly to a specific peer (for file/shard streaming).
    SendBinaryDirect { room_code: String, target_peer: String, data: Vec<u8> },
    /// Subscribe to specific channel topics in a room (reduces fan-out).
    Subscribe { room_code: String, topics: Vec<String> },
    /// Broadcast to peers subscribed to a specific topic in a room.
    SendToRoomTopic { room_code: String, topic: String, data: Vec<u8> },
    /// Ask the relay which peers/rooms are actually alive.
    CheckPeers { peers: Vec<String>, rooms: Vec<String> },
    /// Ask the relay for the peers currently connected to a room, over the live
    /// WS connection (replaces the HTTP /bootstrap poll — no fresh TLS handshake).
    DiscoverPeers { room_code: String },
    /// Ask the relay for time-limited TURN credentials over the authenticated
    /// WS connection (replaces the open HTTP /turn-credentials endpoint —
    /// retries ride the normal reconnect machinery instead of dead-chaining).
    GetTurnCredentials,
    /// Claim a temporary nickname on the relay (RAM only). `master` is our
    /// MASTER identity — the relay hands it back on resolve so a stranger's
    /// friend request targets `inbox:{master}` (which we actually listen on)
    /// instead of our WS-auth DEVICE id (whose inbox nobody joins).
    ClaimNickname { nickname: String, master: String },
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
    /// "channels": {"<channel_id>": "all|mentions|nothing"}}}. The relay checks
    /// these BEFORE firing a channel push (iOS alert pushes can't be suppressed
    /// after delivery, so filtering must happen relay-side).
    SetPushPrefs { prefs_json: String },
    /// Targeted channel-message frame for an OFFLINE server member (0x09).
    /// The relay buffers `data` (the same MLS-group/public wire bytes the room
    /// broadcast carried) for replay to the member's background fetch node, and
    /// fires a channel push filtered by the member's registered prefs +
    /// `mention`. Empty `data` = push trigger only, nothing to buffer.
    SendChannelDirect {
        room_code: String,
        target_peer: String,
        channel_id: String,
        mention: bool,
        data: Vec<u8>,
    },
    /// Register the opt-in offline-delivery setting ("offline inbox") with the
    /// relay. RAM-side registry like push prefs — the latest value is replayed
    /// automatically on every reconnect. Enabled = the relay keeps a bigger
    /// DM text/FileHeader window for this peer at the given retention.
    SetOfflineBuffer { enabled: bool, retention_secs: i64 },
    /// Register/refresh per-channel topic ring buffers for a server room whose
    /// owner enabled relay catch-up (`clear` = owner turned it off). Must be
    /// sent AFTER joining the room; re-sent once per connection by the swarm.
    SetTopicBuffer { room_code: String, channels: Vec<String>, retention_secs: i64, clear: bool },
    /// Ask the relay to replay one channel's buffered ring. Frames arrive as
    /// normal topic messages and ride the standard verify/dedup/merge path.
    /// `max_age_secs` > 0 = only frames younger than that (the client passes
    /// its channel watermark age + lookback so already-delivered frames aren't
    /// re-replayed every session — MLS can't decrypt consumed generations and
    /// the retries were pure noise). 0 = replay everything in retention.
    TopicCatchup { room_code: String, channel_id: String, max_age_secs: i64 },
    /// Ask the relay for this connection's daily byte-budget status. The
    /// reply rides the same socket whose bytes are counted, so attribution
    /// is exact (an HTTP poll could resolve to the other address family).
    GetBandwidth,
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
    /// Temporary nickname successfully claimed.
    NicknameClaimed { nickname: String },
    /// Temporary nickname released.
    NicknameReleased,
    /// Nickname operation error (claim failed or resolve failed).
    NicknameError { error: String, nickname: String },
    /// Nickname resolved to a peer_id. `master_id` is the claimer's
    /// self-reported MASTER identity (empty when the relay predates it).
    NicknameResolved { nickname: String, peer_id: String, master_id: String },
    /// Multi-device link code successfully claimed.
    LinkCodeClaimed { code: String },
    /// Multi-device link code released.
    LinkCodeReleased,
    /// Link code operation error (claim failed or resolve failed).
    LinkCodeError { error: String, code: String },
    /// Link code resolved to the populated sibling's peer_id.
    LinkCodeResolved { code: String, peer_id: String },
    /// Response to GetBandwidth — this IP's daily relay byte budget.
    BandwidthStatus { used: u64, budget: u64, reset_in_secs: u64 },
    /// The relay closed us with 1008 "bandwidth_limit" — daily budget spent.
    BandwidthLimited,
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
            Self::NicknameClaimed { .. } => "NicknameClaimed",
            Self::NicknameReleased => "NicknameReleased",
            Self::NicknameError { .. } => "NicknameError",
            Self::NicknameResolved { .. } => "NicknameResolved",
            Self::LinkCodeClaimed { .. } => "LinkCodeClaimed",
            Self::LinkCodeReleased => "LinkCodeReleased",
            Self::LinkCodeError { .. } => "LinkCodeError",
            Self::LinkCodeResolved { .. } => "LinkCodeResolved",
            Self::BandwidthStatus { .. } => "BandwidthStatus",
            Self::BandwidthLimited => "BandwidthLimited",
        }
    }
}

// -- Wire protocol (matches relay/src/ws_router.rs) --

fn is_false(v: &bool) -> bool { !*v }

#[derive(Serialize)]
#[serde(tag = "type")]
#[serde(rename_all = "snake_case")]
enum ClientMsg {
    Auth {
        peer_id: String,
        public_key: String,
        timestamp: u64,
        signature: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        license_key: Option<String>,
        #[serde(default, skip_serializing_if = "is_false")]
        fetch: bool,
    },
    Join { room: String },
    Leave { room: String },
}

#[derive(Deserialize)]
#[serde(tag = "type")]
#[serde(rename_all = "snake_case")]
enum ServerMsg {
    AuthOk,
    AuthFailed { error: String },
    PeerJoined { room: String, peer_id: String },
    PeerLeft { room: String, peer_id: String },
    Members { room: String, peers: Vec<String> },
    // `active_rooms` is always empty now: the relay's room-activity probe was
    // removed (it let anyone holding two peer_ids ask whether their
    // deterministic DM room was live). Defaulted so a relay that drops the
    // field entirely still deserializes here.
    PeerStatus { online: Vec<String>, #[serde(default)] active_rooms: Vec<String> },
    DiscoveredPeers { room: String, peers: Vec<String> },
    TurnCredentials {
        #[serde(default)] username: String,
        #[serde(default)] password: String,
        #[serde(default)] ttl: u64,
        #[serde(default)] uris: Vec<String>,
        #[serde(default)] error: Option<String>,
    },
    Error { error: String },
    NicknameClaimed { nickname: String },
    NicknameReleased,
    NicknameError { error: String, #[serde(default)] nickname: String },
    NicknameResolved { nickname: String, peer_id: String, #[serde(default)] master_id: String },
    LinkCodeClaimed { code: String },
    LinkCodeReleased,
    LinkCodeError { error: String, #[serde(default)] code: String },
    LinkCodeResolved { code: String, peer_id: String },
    BandwidthStatus {
        #[serde(default)] used: u64,
        #[serde(default)] budget: u64,
        #[serde(default)] reset_in_secs: u64,
    },
}

// -- State --

const ROOM_BUDGET_LIMIT: u32 = 2000;

struct WsClientState {
    /// Rooms we've joined (for re-join on reconnect).
    joined_rooms: Arc<RwLock<HashSet<String>>>,
    /// Last room we attempted to join (for error rollback).
    last_join_attempt: Arc<RwLock<Option<String>>>,
    /// Channel-topic subscriptions per room (for re-subscribe on reconnect).
    /// The relay keeps subscriptions as PER-SOCKET state, so a silent
    /// reconnect (doze blip, relay restart) wiped them — the client kept
    /// receiving room traffic (typing, presence) but ZERO topic-routed
    /// channel messages until the user re-opened a channel (re-subscribing
    /// as a side effect). Mirrors `joined_rooms`: the latest Subscribe per
    /// room wins (the relay replaces the topic set), replayed right after
    /// the room re-joins.
    subscriptions: Arc<RwLock<std::collections::HashMap<String, Vec<String>>>>,
    /// Latest opt-in offline-delivery setting (enabled, retention_secs) — the
    /// relay registry is RAM-per-relay-lifetime, so replay it on every
    /// reconnect like subscriptions. None = never set this session.
    offline_optin: Arc<RwLock<Option<(bool, i64)>>>,
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
    };

    let mut backoff_secs = 1u64;
    let mut pending_commands: Vec<WsCommand> = Vec::new();

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

                // Re-join all previously joined rooms.
                let (mut ws_write, mut ws_read) = ws_stream.split();
                {
                    let rooms = state.joined_rooms.read().await;
                    for room in rooms.iter() {
                        let join_msg = serde_json::to_string(&ClientMsg::Join { room: room.clone() })
                            .unwrap_or_default();
                        let _ = bounded_send(&mut ws_write, Message::Text(join_msg.into())).await;
                    }
                    let _ = event_tx.send(WsEvent::RoomBudgetUpdate { joined: rooms.len() as u32, limit: ROOM_BUDGET_LIMIT });
                }

                // Re-subscribe channel topics — the relay's subscription
                // state is per-socket and died with the old connection.
                // Without this a silent reconnect left the client receiving
                // room traffic (typing) but no topic-routed channel messages
                // until the user re-opened a channel.
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

                // Send any commands that arrived while disconnected.
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

                // Main message loop with periodic keepalive ping.
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
                            // Zombie-socket detection: if the relay has gone
                            // completely silent past the deadline, the write
                            // below would still "succeed" into a dead OS buffer,
                            // so check liveness FIRST and force a reconnect.
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
                        // Incoming from relay.
                        msg = ws_read.next() => {
                            // Any successfully-read frame (text, binary, ping, or
                            // pong) proves the socket is alive in BOTH directions
                            // — refresh the liveness deadline. The relay's own
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
                                    // Reply to our keepalive ping. Liveness is
                                    // already refreshed above; nothing else to do.
                                }
                                Some(Ok(Message::Close(frame))) => {
                                    // Surface the relay's close reason — a
                                    // "bandwidth_limit" close means the daily
                                    // byte budget is spent and the UI must say
                                    // so (the relay NEVER silently drops).
                                    let reason = frame
                                        .as_ref()
                                        .map(|f| f.reason.to_string())
                                        .unwrap_or_default();
                                    hollow_log!("[HOLLOW-WS] Connection closed by server: {reason}");
                                    if reason == "bandwidth_limit" {
                                        let _ = event_tx.send(WsEvent::BandwidthLimited);
                                    }
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
                        // Commands from the swarm.
                        maybe_cmd = cmd_rx.recv() => {
                            // None = the swarm dropped the command sender, i.e.
                            // the node is shutting down. Exit BOTH loops so this
                            // task ends and its WS socket closes — otherwise the
                            // `select!` would just disable this arm and keep the
                            // socket alive, pinging + reconnecting forever (a
                            // per-restart task + socket leak: stop_node only
                            // aborted the event loop, not this task).
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
                if e.contains("license_key") || e.contains("license key") {
                    hollow_log!("[HOLLOW-WS] License error — not retrying");
                    let _ = event_tx.send(WsEvent::LicenseError { reason: e });
                    return;
                }
            }
        }

        // Disconnected — notify swarm and drain commands into pending buffer.
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

        // Exponential backoff.
        hollow_log!("[HOLLOW-WS] Reconnecting in {backoff_secs}s...");
        tokio::time::sleep(Duration::from_secs(backoff_secs)).await;
        backoff_secs = (backoff_secs * 2).min(30);
    }
}

// -- Connection + Auth --

pub(crate) type WsStream = tokio_tungstenite::WebSocketStream<
    tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
>;

pub(crate) async fn connect_and_auth(
    url: &str,
    peer_id: &str,
    keypair_proto: &[u8],
    pub_key_b64: &str,
    license_key: Option<&str>,
    fetch: bool,
) -> Result<WsStream, String> {
    // Connect. When anti-censorship proxy mode is on, a local `shoes` REALITY
    // tunnel exposes a SOCKS5 listener on 127.0.0.1; route the whole WSS
    // connection through it so the relay traffic rides the REALITY tunnel and
    // looks like ordinary HTTPS to a censor. Otherwise connect directly.
    // Read fresh each call so a reconnect after the tunnel comes up picks it up.
    let ws_stream = match crate::api::network::get_proxy_socks_addr() {
        Some(socks_addr) => connect_via_socks(url, &socks_addr).await?,
        None => {
            let (s, _response) = tokio_tungstenite::connect_async(url)
                .await
                .map_err(|e| format!("WebSocket connect failed: {e}"))?;
            s
        }
    };

    let (mut write, mut read) = ws_stream.split();

    // Build auth message.
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    let sign_payload = format!("hollow-ws-auth:{}:{}", peer_id, timestamp);

    // Sign with Ed25519 keypair.
    let keypair = crate::identity::native_identity::NativeKeypair::from_protobuf_encoding(keypair_proto)
        .map_err(|e| format!("Failed to decode keypair: {e}"))?;
    let sig_bytes = keypair.sign(sign_payload.as_bytes());
    let sig_b64 = base64::engine::general_purpose::STANDARD.encode(&sig_bytes);

    let auth = ClientMsg::Auth {
        peer_id: peer_id.to_string(),
        public_key: pub_key_b64.to_string(),
        timestamp,
        signature: sig_b64,
        license_key: license_key.map(|s| s.to_string()),
        fetch,
    };
    let auth_json = serde_json::to_string(&auth).map_err(|e| format!("JSON error: {e}"))?;
    bounded_send(&mut write, Message::Text(auth_json.into()))
        .await
        .map_err(|e| format!("Failed to send auth: {e}"))?;

    // Wait for auth response (5 second timeout).
    let response = tokio::time::timeout(Duration::from_secs(5), read.next())
        .await
        .map_err(|_| "Auth timeout".to_string())?
        .ok_or("Connection closed before auth response")?
        .map_err(|e| format!("Read error: {e}"))?;

    match response {
        Message::Text(text) => {
            match serde_json::from_str::<ServerMsg>(&text) {
                Ok(ServerMsg::AuthOk) => {
                    Ok(read.reunite(write).map_err(|e| format!("Reunite error: {e}"))?)
                }
                Ok(ServerMsg::AuthFailed { error }) => {
                    Err(error)
                }
                _ => Err(format!("Auth rejected: {text}"))
            }
        }
        _ => Err("Unexpected auth response".to_string()),
    }
}

/// Open the relay WSS connection through a local SOCKS5 proxy (the `shoes`
/// REALITY tunnel). We dial the SOCKS5 listener, ask it to reach the relay's
/// host:port (DNS resolves proxy-side — no local leak), then run the WS + TLS
/// handshake over that tunnelled TCP stream. The resulting stream type is
/// identical to `connect_async`'s (`MaybeTlsStream<TcpStream>`) so callers are
/// unaffected.
async fn connect_via_socks(url: &str, socks_addr: &str) -> Result<WsStream, String> {
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;

    // Parse the relay host + port out of the wss:// URL, mirroring how
    // tokio-tungstenite derives them internally (scheme default: wss → 443).
    let request = url
        .into_client_request()
        .map_err(|e| format!("Bad relay URL: {e}"))?;
    let uri = request.uri();
    let host = uri
        .host()
        .ok_or_else(|| "Relay URL has no host".to_string())?
        .to_string();
    let port = uri.port_u16().unwrap_or(match uri.scheme_str() {
        Some("ws") | Some("http") => 80,
        _ => 443,
    });

    hollow_log!("[HOLLOW-WS] Dialing relay {host}:{port} via SOCKS5 tunnel {socks_addr}");

    // Connect through SOCKS5. The target is sent as a domain so the tunnel
    // (and ultimately the Xray server) resolves it — keeps DNS off the local
    // censored network. tokio-socks takes (proxy, (host, port)).
    let socks = tokio_socks::tcp::Socks5Stream::connect(socks_addr, (host.as_str(), port))
        .await
        .map_err(|e| format!("SOCKS5 connect via tunnel failed: {e}"))?;
    let tcp = socks.into_inner();

    // Run WS + TLS over the tunnelled stream. connector=None uses the crate's
    // configured rustls-webpki-roots connector (same as connect_async).
    let (ws_stream, _response) =
        tokio_tungstenite::client_async_tls_with_config(url, tcp, None, None)
            .await
            .map_err(|e| format!("WS/TLS handshake over tunnel failed: {e}"))?;
    Ok(ws_stream)
}

// -- Command sending --

type WsSink = futures_util::stream::SplitSink<WsStream, Message>;

/// Bounded socket write — the ONLY way this module writes to the sink.
/// See WRITE_TIMEOUT for why an unbounded `send` can freeze the entire
/// client loop (zero-window zombie peer) with the liveness watchdog unable
/// to run. A timeout is reported as an error string so every existing
/// `Err → reconnect` path handles the wedge exactly like a dead socket.
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
        WsCommand::GetBandwidth => {
            let msg = serde_json::json!({ "type": "get_bandwidth" });
            if let Err(e) = bounded_send(write, Message::Text(msg.to_string().into())).await {
                hollow_log!("[HOLLOW-WS] GetBandwidth send failed: {e}");
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
        WsCommand::ClaimNickname { nickname, master } => {
            let msg = serde_json::json!({ "type": "claim_nickname", "nickname": nickname, "master": master });
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
        WsCommand::SetTopicBuffer { room_code, channels, retention_secs, clear } => {
            let msg = if *clear {
                serde_json::json!({
                    "type": "set_topic_buffer",
                    "room": room_code,
                    "clear": true,
                })
            } else {
                serde_json::json!({
                    "type": "set_topic_buffer",
                    "room": room_code,
                    "channels": channels,
                    "retention_secs": retention_secs,
                })
            };
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
            // this direct carries an inlined image so its offline buffer applies
            // the image cap (3/peer) rather than the text cap (100/peer).
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
        _ => {}
    }

    let json = match cmd {
        WsCommand::JoinRoom { room_code } => {
            serde_json::to_string(&ClientMsg::Join { room: room_code.clone() })
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
        WsCommand::LeaveRoom { room_code } => {
            let mut rooms = state.joined_rooms.write().await;
            rooms.remove(room_code);
            state.subscriptions.write().await.remove(room_code);
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
            hollow_log!("[HOLLOW-WS] TURN credentials received: {} URI(s), ttl={ttl}s", uris.len());
            WsEvent::TurnCredentials { username, password, ttl, uris }
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
        ServerMsg::NicknameResolved { nickname, peer_id, master_id } => {
            hollow_log!("[HOLLOW-WS] Nickname resolved: {nickname} -> {peer_id} (master: {master_id})");
            WsEvent::NicknameResolved { nickname, peer_id, master_id }
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
        ServerMsg::BandwidthStatus { used, budget, reset_in_secs } => {
            WsEvent::BandwidthStatus { used, budget, reset_in_secs }
        }
        ServerMsg::AuthOk | ServerMsg::AuthFailed { .. } => return,
    };

    let _ = event_tx.send(event);
}

// -- Tests --

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_auth_message_format() {
        let msg = ClientMsg::Auth {
            peer_id: "12D3KooWTest".into(),
            public_key: "AQID".into(),
            timestamp: 1234567890,
            signature: "c2lnbmF0dXJl".into(),
            license_key: None,
            fetch: false,
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"auth\""));
        assert!(json.contains("\"peer_id\":\"12D3KooWTest\""));
        assert!(json.contains("\"timestamp\":1234567890"));
        assert!(!json.contains("\"fetch\""));

        let msg_fetch = ClientMsg::Auth {
            peer_id: "12D3KooWTest".into(),
            public_key: "AQID".into(),
            timestamp: 1234567890,
            signature: "c2lnbmF0dXJl".into(),
            license_key: None,
            fetch: true,
        };
        let json_fetch = serde_json::to_string(&msg_fetch).unwrap();
        assert!(json_fetch.contains("\"fetch\":true"));
    }

    #[test]
    fn test_join_message_format() {
        let msg = ClientMsg::Join { room: "server123".into() };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"join\""));
        assert!(json.contains("\"room\":\"server123\""));
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
