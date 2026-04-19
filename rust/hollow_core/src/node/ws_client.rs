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
    /// Send binary data directly to a specific peer (for file/shard streaming).
    SendBinaryDirect { room_code: String, target_peer: String, data: Vec<u8> },
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
}

// -- Wire protocol (matches relay/src/ws_router.rs) --

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
    },
    Join { room: String },
    Leave { room: String },
    Msg { room: String, data: String },
    Direct { room: String, target: String, data: String },
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
    Msg { room: String, from: String, data: String },
    Direct { room: String, from: String, data: String },
    Error { error: String },
}

// -- State --

struct WsClientState {
    /// Rooms we've joined (for re-join on reconnect).
    joined_rooms: Arc<RwLock<HashSet<String>>>,
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
    cmd_rx: mpsc::UnboundedReceiver<WsCommand>,
    event_tx: mpsc::UnboundedSender<WsEvent>,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        ws_client_loop(relay_url, peer_id, keypair_proto, pub_key_b64, license_key, cmd_rx, event_tx).await;
    })
}

async fn ws_client_loop(
    relay_url: String,
    peer_id: String,
    keypair_proto: Vec<u8>,
    pub_key_b64: String,
    license_key: Option<String>,
    mut cmd_rx: mpsc::UnboundedReceiver<WsCommand>,
    event_tx: mpsc::UnboundedSender<WsEvent>,
) {
    let state = WsClientState {
        joined_rooms: Arc::new(RwLock::new(HashSet::new())),
    };

    let mut backoff_secs = 1u64;
    let mut pending_commands: Vec<WsCommand> = Vec::new();

    loop {
        hollow_log!("[HOLLOW-WS] Connecting to {relay_url}...");

        match connect_and_auth(&relay_url, &peer_id, &keypair_proto, &pub_key_b64, license_key.as_deref()).await {
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
                }

                // Send any commands that arrived while disconnected.
                for cmd in pending_commands.drain(..) {
                    send_command(&mut ws_write, &cmd).await;
                    track_room_change(&state, &cmd).await;
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
                                        handle_server_message(&event_tx, server_msg);
                                    }
                                }
                                Some(Ok(Message::Binary(data))) => {
                                    if data.len() > 3 && data[0] == 0x02 {
                                        // BinaryDirect: [0x02][room_code\0][sender\0][payload]
                                        let room_start = 1;
                                        if let Some(room_nul_off) = data[room_start..].iter().position(|&b| b == 0) {
                                            let room_nul = room_start + room_nul_off;
                                            if let Ok(room_code) = std::str::from_utf8(&data[room_start..room_nul]) {
                                                let peer_start = room_nul + 1;
                                                if peer_start < data.len() {
                                                    if let Some(peer_nul_off) = data[peer_start..].iter().position(|&b| b == 0) {
                                                        let peer_nul = peer_start + peer_nul_off;
                                                        if let Ok(from_peer) = std::str::from_utf8(&data[peer_start..peer_nul]) {
                                                            let payload_start = peer_nul + 1;
                                                            let payload = data[payload_start..].to_vec();
                                                            let _ = event_tx.send(WsEvent::BinaryDirect {
                                                                room: room_code.to_string(),
                                                                from: from_peer.to_string(),
                                                                data: payload,
                                                            });
                                                        }
                                                    }
                                                }
                                            }
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
                            send_command(&mut ws_write, &cmd).await;
                            track_room_change(&state, &cmd).await;
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
            track_room_change(&state, &cmd).await;
            pending_commands.push(cmd);
        }

        // Exponential backoff.
        hollow_log!("[HOLLOW-WS] Reconnecting in {backoff_secs}s...");
        tokio::time::sleep(Duration::from_secs(backoff_secs)).await;
        backoff_secs = (backoff_secs * 2).min(30);
    }
}

// -- Connection + Auth --

type WsStream = tokio_tungstenite::WebSocketStream<
    tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
>;

async fn connect_and_auth(
    url: &str,
    peer_id: &str,
    keypair_proto: &[u8],
    pub_key_b64: &str,
    license_key: Option<&str>,
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

async fn send_command(write: &mut WsSink, cmd: &WsCommand) {
    // Binary commands send raw binary frames, not JSON.
    if let WsCommand::SendBinaryDirect { room_code, target_peer, data } = cmd {
        let room_bytes = room_code.as_bytes();
        let target_bytes = target_peer.as_bytes();
        let mut frame = Vec::with_capacity(1 + room_bytes.len() + 1 + target_bytes.len() + 1 + data.len());
        frame.push(0x02); // BinaryDirect type
        frame.extend_from_slice(room_bytes); // room code
        frame.push(0x00); // \0 terminator
        frame.extend_from_slice(target_bytes); // target peer ID
        frame.push(0x00); // \0 terminator
        frame.extend_from_slice(data); // payload
        if let Err(e) = write.send(Message::Binary(frame.into())).await {
            hollow_log!("[HOLLOW-WS] Binary send failed: {e}");
        }
        return;
    }

    let json = match cmd {
        WsCommand::JoinRoom { room_code } => {
            serde_json::to_string(&ClientMsg::Join { room: room_code.clone() })
        }
        WsCommand::LeaveRoom { room_code } => {
            serde_json::to_string(&ClientMsg::Leave { room: room_code.clone() })
        }
        WsCommand::SendToRoom { room_code, data } => {
            let data_b64 = base64::engine::general_purpose::STANDARD.encode(data);
            serde_json::to_string(&ClientMsg::Msg { room: room_code.clone(), data: data_b64 })
        }
        WsCommand::SendDirect { room_code, target_peer, data } => {
            let data_b64 = base64::engine::general_purpose::STANDARD.encode(data);
            serde_json::to_string(&ClientMsg::Direct {
                room: room_code.clone(),
                target: target_peer.clone(),
                data: data_b64,
            })
        }
        WsCommand::SendBinaryDirect { .. } => unreachable!(), // handled above
    };

    if let Ok(json) = json {
        if let Err(e) = write.send(Message::Text(json.into())).await {
            hollow_log!("[HOLLOW-WS] Send failed: {e}");
        }
    }
}

async fn track_room_change(state: &WsClientState, cmd: &WsCommand) {
    match cmd {
        WsCommand::JoinRoom { room_code } => {
            state.joined_rooms.write().await.insert(room_code.clone());
        }
        WsCommand::LeaveRoom { room_code } => {
            state.joined_rooms.write().await.remove(room_code);
        }
        _ => {}
    }
}

// -- Server message handling --

fn handle_server_message(event_tx: &mpsc::UnboundedSender<WsEvent>, msg: ServerMsg) {
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
        ServerMsg::Msg { room, from, data } => {
            if let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(&data) {
                WsEvent::Message { room, from, data: bytes }
            } else {
                hollow_log!("[HOLLOW-WS] Failed to decode message data from {from}");
                return;
            }
        }
        ServerMsg::Direct { room, from, data } => {
            if let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(&data) {
                WsEvent::DirectMessage { room, from, data: bytes }
            } else {
                hollow_log!("[HOLLOW-WS] Failed to decode direct data from {from}");
                return;
            }
        }
        ServerMsg::Error { error } => {
            hollow_log!("[HOLLOW-WS] Server error: {error}");
            return;
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
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"auth\""));
        assert!(json.contains("\"peer_id\":\"12D3KooWTest\""));
        assert!(json.contains("\"timestamp\":1234567890"));
    }

    #[test]
    fn test_join_message_format() {
        let msg = ClientMsg::Join { room: "server123".into() };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"join\""));
        assert!(json.contains("\"room\":\"server123\""));
    }

    #[test]
    fn test_msg_message_format() {
        let msg = ClientMsg::Msg {
            room: "room1".into(),
            data: "aGVsbG8=".into(),
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"msg\""));
        assert!(json.contains("\"data\":\"aGVsbG8=\""));
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

    #[test]
    fn test_server_msg_parse_msg() {
        let json = r#"{"type":"msg","room":"r1","from":"peer_a","data":"aGVsbG8="}"#;
        let msg: ServerMsg = serde_json::from_str(json).unwrap();
        match msg {
            ServerMsg::Msg { room, from, data } => {
                assert_eq!(room, "r1");
                assert_eq!(from, "peer_a");
                assert_eq!(data, "aGVsbG8=");
            }
            _ => panic!("Wrong variant"),
        }
    }
}
