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
    /// Claim a temporary nickname on the relay (RAM only).
    ClaimNickname { nickname: String },
    /// Release the currently claimed nickname.
    ReleaseNickname,
    /// Resolve a nickname to a peer_id via the relay.
    ResolveNickname { nickname: String },
    /// Register FCM/APNs push token with the relay for offline notifications.
    RegisterPushToken { token: String, platform: String },
}

/// Events received from the WebSocket relay, forwarded to the swarm.
#[derive(Debug, Clone)]
pub enum WsEvent {
    Connected,
    Disconnected,
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
    /// Temporary nickname successfully claimed.
    NicknameClaimed { nickname: String },
    /// Temporary nickname released.
    NicknameReleased,
    /// Nickname operation error (claim failed or resolve failed).
    NicknameError { error: String, nickname: String },
    /// Nickname resolved to a peer_id.
    NicknameResolved { nickname: String, peer_id: String },
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
    PeerStatus { online: Vec<String>, active_rooms: Vec<String> },
    Error { error: String },
    NicknameClaimed { nickname: String },
    NicknameReleased,
    NicknameError { error: String, #[serde(default)] nickname: String },
    NicknameResolved { nickname: String, peer_id: String },
}

// -- State --

const ROOM_BUDGET_LIMIT: u32 = 2000;

struct WsClientState {
    /// Rooms we've joined (for re-join on reconnect).
    joined_rooms: Arc<RwLock<HashSet<String>>>,
    /// Last room we attempted to join (for error rollback).
    last_join_attempt: Arc<RwLock<Option<String>>>,
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
    };

    let mut backoff_secs = 1u64;
    let mut pending_commands: Vec<WsCommand> = Vec::new();

    loop {
        hollow_log!("[HOLLOW-WS] Connecting to {relay_url}...");

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
                        let _ = ws_write.send(Message::Text(join_msg.into())).await;
                    }
                    let _ = event_tx.send(WsEvent::RoomBudgetUpdate { joined: rooms.len() as u32, limit: ROOM_BUDGET_LIMIT });
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
                loop {
                    tokio::select! {
                        // Keepalive ping — prevents Nginx/proxy/relay from closing idle connections.
                        _ = ping_timer.tick() => {
                            if let Err(e) = ws_write.send(Message::Ping(vec![0x01].into())).await {
                                hollow_log!("[HOLLOW-WS] Ping failed: {e}");
                                break; // Connection dead, trigger reconnect.
                            }
                        }
                        // Incoming from relay.
                        msg = ws_read.next() => {
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
                                    let _ = ws_write.send(Message::Pong(data)).await;
                                }
                                Some(Ok(Message::Close(_))) | None => {
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
                        Some(cmd) = cmd_rx.recv() => {
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
        while let Ok(cmd) = cmd_rx.try_recv() {
            track_room_change(&state, &cmd, &event_tx).await;
            pending_commands.push(cmd);
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
    // Connect.
    let (ws_stream, _response) = tokio_tungstenite::connect_async(url)
        .await
        .map_err(|e| format!("WebSocket connect failed: {e}"))?;

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
    write.send(Message::Text(auth_json.into()))
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

// -- Command sending --

type WsSink = futures_util::stream::SplitSink<WsStream, Message>;

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
            if let Err(e) = write.send(Message::Binary(frame.into())).await {
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
            if let Err(e) = write.send(Message::Text(text.into())).await {
                hollow_log!("[HOLLOW-WS] CheckPeers send failed: {e}");
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
            if let Err(e) = write.send(Message::Text(text.into())).await {
                hollow_log!("[HOLLOW-WS] Subscribe send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::ClaimNickname { nickname } => {
            let msg = serde_json::json!({ "type": "claim_nickname", "nickname": nickname });
            if let Err(e) = write.send(Message::Text(msg.to_string().into())).await {
                hollow_log!("[HOLLOW-WS] ClaimNickname send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::ReleaseNickname => {
            let msg = serde_json::json!({ "type": "release_nickname" });
            if let Err(e) = write.send(Message::Text(msg.to_string().into())).await {
                hollow_log!("[HOLLOW-WS] ReleaseNickname send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::ResolveNickname { nickname } => {
            let msg = serde_json::json!({ "type": "resolve_nickname", "nickname": nickname });
            if let Err(e) = write.send(Message::Text(msg.to_string().into())).await {
                hollow_log!("[HOLLOW-WS] ResolveNickname send failed: {e}");
                return false;
            }
            return true;
        }
        WsCommand::RegisterPushToken { token, platform } => {
            let msg = serde_json::json!({ "type": "register_push_token", "token": token, "platform": platform });
            if let Err(e) = write.send(Message::Text(msg.to_string().into())).await {
                hollow_log!("[HOLLOW-WS] RegisterPushToken send failed: {e}");
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
            if let Err(e) = write.send(Message::Binary(frame.into())).await {
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
            if let Err(e) = write.send(Message::Binary(frame.into())).await {
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
            if let Err(e) = write.send(Message::Binary(frame.into())).await {
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
            if let Err(e) = write.send(Message::Binary(frame.into())).await {
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
        if let Err(e) = write.send(Message::Text(json.into())).await {
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
            rooms.len() as u32
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
        ServerMsg::NicknameResolved { nickname, peer_id } => {
            hollow_log!("[HOLLOW-WS] Nickname resolved: {nickname} -> {peer_id}");
            WsEvent::NicknameResolved { nickname, peer_id }
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
