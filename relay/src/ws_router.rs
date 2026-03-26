use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use axum::extract::ws::{Message, WebSocket};
use axum::extract::{State, WebSocketUpgrade};
use axum::response::IntoResponse;
use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, RwLock};

use crate::signaling_http::verify_signature;

// -- Constants --

const TIMESTAMP_SKEW_SECS: u64 = 300;
const MAX_ROOMS_PER_PEER: usize = 100;

// -- Data types --

struct Room {
    peers: HashMap<String, mpsc::UnboundedSender<Message>>,
}

pub struct WsState {
    rooms: RwLock<HashMap<String, Room>>,
    peers: RwLock<HashMap<String, HashSet<String>>>,
}

pub type SharedWsState = Arc<WsState>;

impl WsState {
    pub fn new() -> Self {
        Self {
            rooms: RwLock::new(HashMap::new()),
            peers: RwLock::new(HashMap::new()),
        }
    }
}

// -- Wire protocol --

#[derive(Deserialize)]
#[serde(tag = "type")]
#[serde(rename_all = "snake_case")]
enum ClientMessage {
    Auth {
        peer_id: String,
        public_key: String,
        timestamp: u64,
        signature: String,
    },
    Join { room: String },
    Leave { room: String },
    Msg { room: String, data: String },
    Direct { room: String, target: String, data: String },
}

#[derive(Serialize, Clone)]
#[serde(tag = "type")]
#[serde(rename_all = "snake_case")]
enum ServerMessage {
    AuthOk,
    AuthFailed { error: String },
    PeerJoined { room: String, peer_id: String },
    PeerLeft { room: String, peer_id: String },
    Members { room: String, peers: Vec<String> },
    Msg { room: String, from: String, data: String },
    Direct { room: String, from: String, data: String },
    Error { error: String },
}

// -- WebSocket handler --

pub async fn ws_upgrade(
    ws: WebSocketUpgrade,
    State(state): State<SharedWsState>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_ws(socket, state))
}

async fn handle_ws(mut socket: WebSocket, state: SharedWsState) {
    // Create a channel for outgoing messages.
    let (tx, mut rx) = mpsc::unbounded_channel::<Message>();

    // Wait for auth message first (10 second timeout).
    let peer_id = match authenticate(&mut socket).await {
        Some(pid) => {
            let _ = socket.send(msg_json(&ServerMessage::AuthOk)).await;
            pid
        }
        None => {
            let _ = socket.send(msg_json(&ServerMessage::AuthFailed {
                error: "Authentication failed".into(),
            })).await;
            return;
        }
    };

    tracing::info!("WS authenticated: {peer_id}");

    // Track this peer.
    {
        let mut peers = state.peers.write().await;
        peers.insert(peer_id.clone(), HashSet::new());
    }

    let peer_id_clone = peer_id.clone();
    let state_clone = state.clone();

    loop {
        tokio::select! {
            // Incoming message from peer.
            msg = socket.recv() => {
                match msg {
                    Some(Ok(Message::Text(text))) => {
                        if let Ok(client_msg) = serde_json::from_str::<ClientMessage>(&text) {
                            let responses = handle_client_message(
                                &state_clone, &peer_id_clone, &tx, client_msg,
                            ).await;
                            for resp in responses {
                                if socket.send(resp).await.is_err() {
                                    break;
                                }
                            }
                        }
                    }
                    Some(Ok(Message::Binary(data))) => {
                        if data.len() > 1 {
                            match data[0] {
                                0x01 => {
                                    // Binary broadcast to room peers (legacy: 32-byte room hash).
                                    if data.len() > 33 {
                                        let room_hex = hex::encode(&data[1..33]);
                                        broadcast_binary(&state_clone, &room_hex, &peer_id_clone, &data).await;
                                    }
                                }
                                0x02 => {
                                    // Binary direct: [0x02][room\0][target\0][payload]
                                    direct_binary(&state_clone, &peer_id_clone, &data).await;
                                }
                                _ => {}
                            }
                        }
                    }
                    Some(Ok(Message::Ping(data))) => {
                        let _ = socket.send(Message::Pong(data)).await;
                    }
                    Some(Ok(Message::Close(_))) | None => break,
                    _ => {}
                }
            }
            // Outgoing message to send to this peer (from room broadcasts).
            Some(msg) = rx.recv() => {
                if socket.send(msg).await.is_err() {
                    break;
                }
            }
        }
    }

    // Cleanup.
    tracing::info!("WS disconnected: {peer_id}");
    cleanup_peer(&state, &peer_id).await;
}

async fn authenticate(socket: &mut WebSocket) -> Option<String> {
    let timeout = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        socket.recv(),
    ).await;

    if let Ok(Some(Ok(Message::Text(text)))) = timeout {
        if let Ok(ClientMessage::Auth { peer_id, public_key, timestamp, signature }) =
            serde_json::from_str::<ClientMessage>(&text)
        {
            let now = now_unix_secs();
            let diff = if now > timestamp { now - timestamp } else { timestamp - now };
            if diff > TIMESTAMP_SKEW_SECS {
                return None;
            }
            let signed_msg = format!("hollow-ws-auth:{}:{}", peer_id, timestamp);
            if verify_signature(&public_key, &signature, &signed_msg) {
                return Some(peer_id);
            }
        }
    }
    None
}

// -- Message handling --

async fn handle_client_message(
    state: &SharedWsState,
    peer_id: &str,
    tx: &mpsc::UnboundedSender<Message>,
    msg: ClientMessage,
) -> Vec<Message> {
    let mut responses = Vec::new();

    match msg {
        ClientMessage::Join { room } => {
            if room.is_empty() || room.len() > 128 {
                responses.push(msg_json(&ServerMessage::Error {
                    error: "Invalid room code".into(),
                }));
                return responses;
            }

            // Check room limit.
            {
                let peers = state.peers.read().await;
                if let Some(rooms) = peers.get(peer_id) {
                    if rooms.len() >= MAX_ROOMS_PER_PEER {
                        responses.push(msg_json(&ServerMessage::Error {
                            error: "Too many rooms".into(),
                        }));
                        return responses;
                    }
                }
            }

            // Add peer to room.
            let existing_peers = {
                let mut rooms = state.rooms.write().await;
                let room_entry = rooms.entry(room.clone()).or_insert_with(|| Room {
                    peers: HashMap::new(),
                });
                let existing: Vec<String> = room_entry.peers.keys().cloned().collect();
                room_entry.peers.insert(peer_id.to_string(), tx.clone());
                existing
            };

            // Track room on peer.
            {
                let mut peers = state.peers.write().await;
                if let Some(rooms) = peers.get_mut(peer_id) {
                    rooms.insert(room.clone());
                }
            }

            // Send member list to the joining peer.
            let mut all_peers = existing_peers.clone();
            all_peers.push(peer_id.to_string());
            responses.push(msg_json(&ServerMessage::Members {
                room: room.clone(),
                peers: all_peers,
            }));

            // Notify existing peers.
            let join_msg = msg_json(&ServerMessage::PeerJoined {
                room: room.clone(),
                peer_id: peer_id.to_string(),
            });
            let rooms = state.rooms.read().await;
            if let Some(room_entry) = rooms.get(&room) {
                for (pid, sender) in &room_entry.peers {
                    if pid != peer_id {
                        let _ = sender.send(join_msg.clone());
                    }
                }
            }
        }

        ClientMessage::Leave { room } => {
            leave_room(state, peer_id, &room).await;
        }

        ClientMessage::Msg { room, data } => {
            let broadcast = msg_json(&ServerMessage::Msg {
                room: room.clone(),
                from: peer_id.to_string(),
                data,
            });
            let rooms = state.rooms.read().await;
            if let Some(room_entry) = rooms.get(&room) {
                for (pid, sender) in &room_entry.peers {
                    if pid != peer_id {
                        let _ = sender.send(broadcast.clone());
                    }
                }
            }
        }

        ClientMessage::Direct { room, target, data } => {
            let direct = msg_json(&ServerMessage::Direct {
                room: room.clone(),
                from: peer_id.to_string(),
                data,
            });
            let rooms = state.rooms.read().await;
            if let Some(room_entry) = rooms.get(&room) {
                if let Some(sender) = room_entry.peers.get(&target) {
                    let _ = sender.send(direct);
                }
            }
        }

        ClientMessage::Auth { .. } => {}
    }

    responses
}

async fn leave_room(state: &SharedWsState, peer_id: &str, room: &str) {
    let should_notify = {
        let mut rooms = state.rooms.write().await;
        if let Some(room_entry) = rooms.get_mut(room) {
            room_entry.peers.remove(peer_id);
            if room_entry.peers.is_empty() {
                rooms.remove(room);
                false
            } else {
                true
            }
        } else {
            false
        }
    };

    {
        let mut peers = state.peers.write().await;
        if let Some(rooms) = peers.get_mut(peer_id) {
            rooms.remove(room);
        }
    }

    if should_notify {
        let leave_msg = msg_json(&ServerMessage::PeerLeft {
            room: room.to_string(),
            peer_id: peer_id.to_string(),
        });
        let rooms = state.rooms.read().await;
        if let Some(room_entry) = rooms.get(room) {
            for sender in room_entry.peers.values() {
                let _ = sender.send(leave_msg.clone());
            }
        }
    }
}

async fn cleanup_peer(state: &SharedWsState, peer_id: &str) {
    let rooms_to_leave = {
        let mut peers = state.peers.write().await;
        peers.remove(peer_id).unwrap_or_default()
    };
    for room in rooms_to_leave {
        leave_room(state, peer_id, &room).await;
    }
}

async fn broadcast_binary(state: &SharedWsState, room_hex: &str, sender_id: &str, data: &[u8]) {
    let rooms = state.rooms.read().await;
    if let Some(room_entry) = rooms.get(room_hex) {
        let msg = Message::Binary(data.to_vec().into());
        for (pid, sender) in &room_entry.peers {
            if pid != sender_id {
                let _ = sender.send(msg.clone());
            }
        }
    }
}

/// Forward a binary frame to a specific target peer.
/// Sender format: [0x02][room_code\0][target_peer\0][payload...]
/// Forwarded:     [0x02][room_code\0][sender_peer\0][payload...]
async fn direct_binary(state: &SharedWsState, sender_id: &str, data: &[u8]) {
    // Parse room code from bytes 1+ until first \0.
    let room_start = 1;
    let room_nul = match data[room_start..].iter().position(|&b| b == 0) {
        Some(p) => room_start + p,
        None => return,
    };
    let room_code = match std::str::from_utf8(&data[room_start..room_nul]) {
        Ok(s) => s,
        Err(_) => return,
    };

    // Parse target peer from next \0-terminated string.
    let peer_start = room_nul + 1;
    if peer_start >= data.len() { return; }
    let peer_nul = match data[peer_start..].iter().position(|&b| b == 0) {
        Some(p) => peer_start + p,
        None => return,
    };
    let target_peer = match std::str::from_utf8(&data[peer_start..peer_nul]) {
        Ok(s) => s,
        Err(_) => return,
    };
    let payload_start = peer_nul + 1;
    if payload_start >= data.len() { return; }

    // Build forwarded frame: replace target_peer with sender_id.
    let sender_bytes = sender_id.as_bytes();
    let room_bytes = room_code.as_bytes();
    let payload = &data[payload_start..];
    let mut forwarded = Vec::with_capacity(1 + room_bytes.len() + 1 + sender_bytes.len() + 1 + payload.len());
    forwarded.push(0x02);
    forwarded.extend_from_slice(room_bytes);
    forwarded.push(0x00);
    forwarded.extend_from_slice(sender_bytes);
    forwarded.push(0x00);
    forwarded.extend_from_slice(payload);

    let rooms = state.rooms.read().await;
    if let Some(room_entry) = rooms.get(room_code) {
        if let Some(sender) = room_entry.peers.get(target_peer) {
            let _ = sender.send(Message::Binary(forwarded.into()));
        }
    }
}

// -- Helpers --

fn msg_json(msg: &ServerMessage) -> Message {
    Message::Text(serde_json::to_string(msg).unwrap_or_default().into())
}

fn now_unix_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
