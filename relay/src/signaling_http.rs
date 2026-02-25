use std::collections::HashMap;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use axum::extract::{Path, State};
use axum::http::{HeaderValue, Method, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use base64::Engine;
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde::Deserialize;
use tokio::sync::RwLock;

// -- Constants (matching the Cloudflare Worker) --

const MAX_PEERS_PER_ROOM: usize = 50;
const MAX_ADDRS_PER_PEER: usize = 5;
const STALE_THRESHOLD_SECS: u64 = 600; // 10 minutes
const TIMESTAMP_SKEW_SECS: u64 = 300; // 5 minutes anti-replay
const CLEANUP_INTERVAL_SECS: u64 = 300; // 5 minutes
const MAX_BOOTSTRAP_PEERS: usize = 10;

// -- Data types --

#[derive(Clone)]
pub struct PeerEntry {
    peer_id: String,
    addresses: Vec<String>,
    last_seen: u64,
}

pub type RoomMap = Arc<RwLock<HashMap<String, Vec<PeerEntry>>>>;

#[derive(Deserialize)]
struct RegisterRequest {
    room_code: String,
    peer_id: String,
    addresses: Vec<String>,
    timestamp: u64,
    public_key: String,
    signature: String,
}

// -- HTTP handlers --

async fn handle_register(
    State(rooms): State<RoomMap>,
    Json(body): Json<RegisterRequest>,
) -> impl IntoResponse {
    // Validate required fields.
    if body.room_code.is_empty() || body.room_code.len() > 64 {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "Invalid room_code"})),
        );
    }

    if body.addresses.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "addresses must be a non-empty array"})),
        );
    }

    if body.peer_id.is_empty() || body.public_key.is_empty() || body.signature.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "Missing required fields"})),
        );
    }

    // Anti-replay: timestamp must be within 5 minutes.
    let now_secs = now_unix_secs();
    let diff = if now_secs > body.timestamp {
        now_secs - body.timestamp
    } else {
        body.timestamp - now_secs
    };
    if diff > TIMESTAMP_SKEW_SECS {
        return (
            StatusCode::FORBIDDEN,
            Json(serde_json::json!({"error": "Timestamp too far from server time"})),
        );
    }

    // Trim addresses.
    let trimmed_addrs: Vec<String> = body.addresses.into_iter().take(MAX_ADDRS_PER_PEER).collect();
    let addrs_joined = trimmed_addrs.join(",");

    // Verify Ed25519 signature.
    let signed_message = format!(
        "haven-register:{}:{}:{}:{}",
        body.room_code, body.peer_id, addrs_joined, body.timestamp
    );

    if !verify_signature(&body.public_key, &body.signature, &signed_message) {
        return (
            StatusCode::FORBIDDEN,
            Json(serde_json::json!({"error": "Invalid signature"})),
        );
    }

    // Upsert peer in room.
    let mut map = rooms.write().await;
    let peers = map.entry(body.room_code).or_default();

    // Filter out stale entries.
    peers.retain(|p| now_secs - p.last_seen < STALE_THRESHOLD_SECS);

    // Upsert this peer.
    if let Some(existing) = peers.iter_mut().find(|p| p.peer_id == body.peer_id) {
        existing.addresses = trimmed_addrs;
        existing.last_seen = now_secs;
    } else {
        // Enforce room cap — evict oldest if full.
        if peers.len() >= MAX_PEERS_PER_ROOM {
            peers.sort_by_key(|p| p.last_seen);
            peers.remove(0);
        }
        peers.push(PeerEntry {
            peer_id: body.peer_id,
            addresses: trimmed_addrs,
            last_seen: now_secs,
        });
    }

    let count = peers.len();

    (
        StatusCode::OK,
        Json(serde_json::json!({"ok": true, "peers_in_room": count})),
    )
}

async fn handle_bootstrap(
    State(rooms): State<RoomMap>,
    Path(room_code): Path<String>,
) -> impl IntoResponse {
    if room_code.is_empty() || room_code.len() > 64 {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "Invalid room code"})),
        );
    }

    let map = rooms.read().await;
    let peers = match map.get(&room_code) {
        Some(p) => p,
        None => return (StatusCode::OK, Json(serde_json::json!({"peers": []}))),
    };

    let now_secs = now_unix_secs();
    let result: Vec<serde_json::Value> = peers
        .iter()
        .filter(|p| now_secs - p.last_seen < STALE_THRESHOLD_SECS)
        .take(MAX_BOOTSTRAP_PEERS)
        .map(|p| {
            serde_json::json!({
                "peer_id": p.peer_id,
                "addresses": p.addresses,
            })
        })
        .collect();

    (StatusCode::OK, Json(serde_json::json!({"peers": result})))
}

async fn handle_health() -> impl IntoResponse {
    Json(serde_json::json!({
        "status": "ok",
        "service": "haven-signaling"
    }))
}

// -- Signature verification --

/// Verify an Ed25519 signature using the libp2p protobuf-encoded public key.
fn verify_signature(public_key_b64: &str, signature_b64: &str, message: &str) -> bool {
    let b64 = base64::engine::general_purpose::STANDARD;

    // Decode base64 protobuf key (36 bytes: 4-byte header + 32-byte raw Ed25519 key).
    let proto_bytes = match b64.decode(public_key_b64) {
        Ok(b) => b,
        Err(_) => return false,
    };

    if proto_bytes.len() != 36 {
        return false;
    }

    // Header: 08 01 12 20 = protobuf field tags for Ed25519 key type + 32-byte length.
    if proto_bytes[..4] != [0x08, 0x01, 0x12, 0x20] {
        return false;
    }

    let raw_key: [u8; 32] = match proto_bytes[4..].try_into() {
        Ok(k) => k,
        Err(_) => return false,
    };

    let verifying_key = match VerifyingKey::from_bytes(&raw_key) {
        Ok(k) => k,
        Err(_) => return false,
    };

    let sig_bytes = match b64.decode(signature_b64) {
        Ok(b) => b,
        Err(_) => return false,
    };

    let sig_arr: [u8; 64] = match sig_bytes.try_into() {
        Ok(a) => a,
        Err(_) => return false,
    };

    let signature = Signature::from_bytes(&sig_arr);
    verifying_key.verify(message.as_bytes(), &signature).is_ok()
}

// -- Cleanup task --

/// Spawn a background task that periodically removes stale peer entries.
pub fn spawn_cleanup_task(rooms: RoomMap) {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(
            CLEANUP_INTERVAL_SECS,
        ));
        loop {
            interval.tick().await;
            let now_secs = now_unix_secs();
            let mut map = rooms.write().await;

            // Remove stale entries from all rooms.
            map.retain(|_, peers| {
                peers.retain(|p| now_secs - p.last_seen < STALE_THRESHOLD_SECS);
                !peers.is_empty()
            });

            let total_rooms = map.len();
            let total_peers: usize = map.values().map(|v| v.len()).sum();
            if total_rooms > 0 {
                tracing::debug!("Cleanup: {total_peers} peers in {total_rooms} rooms");
            }
        }
    });
}

// -- Router --

/// Build the axum router with CORS support.
pub fn build_router(rooms: RoomMap) -> Router {
    use axum::http::header;
    use tower_http::cors::CorsLayer;

    // We'll build CORS manually via middleware since tower-http might not be a dep.
    // Instead, just add CORS headers in a simple layer.
    let cors = CorsLayer::new()
        .allow_origin("*".parse::<HeaderValue>().unwrap())
        .allow_methods([Method::GET, Method::POST, Method::OPTIONS])
        .allow_headers([header::CONTENT_TYPE]);

    Router::new()
        .route("/register", post(handle_register))
        .route("/bootstrap/{room_code}", get(handle_bootstrap))
        .route("/health", get(handle_health))
        .layer(cors)
        .with_state(rooms)
}

/// Run the HTTP signaling server.
pub async fn run_signaling_http(
    rooms: RoomMap,
    port: u16,
) -> Result<(), Box<dyn std::error::Error>> {
    spawn_cleanup_task(rooms.clone());

    let app = build_router(rooms);
    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{port}")).await?;
    tracing::info!("Signaling HTTP server listening on port {port}");
    axum::serve(listener, app).await?;
    Ok(())
}

// -- Helpers --

fn now_unix_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
