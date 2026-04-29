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
const STALE_THRESHOLD_SECS: u64 = 180; // 3 minutes
const TIMESTAMP_SKEW_SECS: u64 = 60; // Phase 6.25: tightened from 300s to 60s
const CLEANUP_INTERVAL_SECS: u64 = 120; // 2 minutes
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

#[derive(Deserialize)]
struct UnregisterRequest {
    room_code: String,
    peer_id: String,
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
        "hollow-register:{}:{}:{}:{}",
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

async fn handle_unregister(
    State(rooms): State<RoomMap>,
    Json(body): Json<UnregisterRequest>,
) -> impl IntoResponse {
    if body.room_code.is_empty() || body.room_code.len() > 64 {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "Invalid room_code"})),
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

    // Verify Ed25519 signature.
    let signed_message = format!(
        "hollow-unregister:{}:{}:{}",
        body.room_code, body.peer_id, body.timestamp
    );

    if !verify_signature(&body.public_key, &body.signature, &signed_message) {
        return (
            StatusCode::FORBIDDEN,
            Json(serde_json::json!({"error": "Invalid signature"})),
        );
    }

    // Remove peer from room.
    let mut map = rooms.write().await;
    if let Some(peers) = map.get_mut(&body.room_code) {
        peers.retain(|p| p.peer_id != body.peer_id);
        if peers.is_empty() {
            map.remove(&body.room_code);
        }
    }

    (
        StatusCode::OK,
        Json(serde_json::json!({"ok": true})),
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
        "service": "hollow-signaling"
    }))
}

/// Server stats endpoint — returns RAM, network bandwidth, and online user count.
/// Reads from /proc/meminfo and /proc/net/dev. Cached for 5s to handle many clients.
async fn handle_server_stats(
    State(ws_state): State<crate::ws_router::SharedWsState>,
) -> impl IntoResponse {
    use std::sync::OnceLock;
    use tokio::sync::Mutex;

    struct CachedStats {
        json: serde_json::Value,
        fetched_at: std::time::Instant,
        prev_rx_bytes: u64,
        prev_tx_bytes: u64,
        prev_sample_at: std::time::Instant,
        rx_mbps: f64,
        tx_mbps: f64,
    }

    static CACHE: OnceLock<Mutex<Option<CachedStats>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(None));
    let mut guard = cache.lock().await;

    // Return cached response if fresh (<5s).
    if let Some(ref cached) = *guard {
        if cached.fetched_at.elapsed().as_secs() < 5 {
            return (StatusCode::OK, Json(cached.json.clone()));
        }
    }

    // Read /proc/meminfo.
    let (mem_total_kb, mem_available_kb) = match tokio::fs::read_to_string("/proc/meminfo").await {
        Ok(contents) => {
            let mut total = 0u64;
            let mut available = 0u64;
            for line in contents.lines() {
                if line.starts_with("MemTotal:") {
                    total = parse_proc_kb(line);
                } else if line.starts_with("MemAvailable:") {
                    available = parse_proc_kb(line);
                }
            }
            (total, available)
        }
        Err(_) => (0, 0),
    };

    // Read /proc/net/dev for ens16.
    let (rx_bytes, tx_bytes) = match tokio::fs::read_to_string("/proc/net/dev").await {
        Ok(contents) => {
            let mut rx = 0u64;
            let mut tx = 0u64;
            for line in contents.lines() {
                let trimmed = line.trim();
                if trimmed.starts_with("ens16:") {
                    let parts: Vec<&str> = trimmed.split_whitespace().collect();
                    if parts.len() >= 10 {
                        rx = parts[1].parse().unwrap_or(0);
                        tx = parts[9].parse().unwrap_or(0);
                    }
                }
            }
            (rx, tx)
        }
        Err(_) => (0, 0),
    };

    // Compute bandwidth from previous sample.
    let now = std::time::Instant::now();
    let (rx_mbps, tx_mbps) = if let Some(ref prev) = *guard {
        let elapsed = prev.prev_sample_at.elapsed().as_secs_f64();
        if elapsed > 0.5 {
            let rx_delta = rx_bytes.saturating_sub(prev.prev_rx_bytes) as f64;
            let tx_delta = tx_bytes.saturating_sub(prev.prev_tx_bytes) as f64;
            // bytes/sec → Mbps (megabits per second)
            let rx_m = (rx_delta * 8.0) / (elapsed * 1_000_000.0);
            let tx_m = (tx_delta * 8.0) / (elapsed * 1_000_000.0);
            (rx_m, tx_m)
        } else {
            (prev.rx_mbps, prev.tx_mbps)
        }
    } else {
        (0.0, 0.0)
    };

    // Count online users (unique peer IDs with active WS connections).
    let online_users = {
        let peers = ws_state.peer_count().await;
        peers
    };

    let mem_used_kb = mem_total_kb.saturating_sub(mem_available_kb);

    let json = serde_json::json!({
        "mem_total_kb": mem_total_kb,
        "mem_used_kb": mem_used_kb,
        "rx_mbps": (rx_mbps * 100.0).round() / 100.0,
        "tx_mbps": (tx_mbps * 100.0).round() / 100.0,
        "bandwidth_cap_mbps": 400,
        "online_users": online_users,
    });

    *guard = Some(CachedStats {
        json: json.clone(),
        fetched_at: now,
        prev_rx_bytes: rx_bytes,
        prev_tx_bytes: tx_bytes,
        prev_sample_at: now,
        rx_mbps,
        tx_mbps,
    });

    (StatusCode::OK, Json(json))
}

/// Parse a /proc/meminfo line like "MemTotal:     8130796 kB" → 8130796.
fn parse_proc_kb(line: &str) -> u64 {
    line.split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0)
}

/// Generate time-limited TURN credentials using HMAC-SHA1 shared secret.
/// Coturn's `use-auth-secret` expects: username = "expiry_timestamp:arbitrary_id",
/// password = Base64(HMAC-SHA1(secret, username)).
/// TTL = 1 hour. Credentials are time-limited and coturn enforces its own
/// allocation limits — no relay-side rate limit needed (Phase 6.25 review).
async fn handle_turn_credentials() -> impl IntoResponse {
    use hmac::{Hmac, Mac};
    use sha1::Sha1;

    let secret = match std::env::var("TURN_SECRET") {
        Ok(s) if !s.is_empty() => s,
        _ => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(serde_json::json!({"error": "TURN not configured"})),
            );
        }
    };

    let ttl: u64 = 3600; // 1 hour
    let expiry = now_unix_secs() + ttl;
    let username = format!("{expiry}:hollow");

    let mut mac = Hmac::<Sha1>::new_from_slice(secret.as_bytes())
        .expect("HMAC can take key of any size");
    mac.update(username.as_bytes());
    let password = base64::engine::general_purpose::STANDARD.encode(mac.finalize().into_bytes());

    (
        StatusCode::OK,
        Json(serde_json::json!({
            "username": username,
            "password": password,
            "ttl": ttl,
            "uris": [
                "turn:relay.anonlisten.com:3478",
                "turn:relay.anonlisten.com:3478?transport=tcp",
                "turns:relay.anonlisten.com:5349"
            ]
        })),
    )
}

// -- Signature verification --

/// Verify an Ed25519 signature using the libp2p protobuf-encoded public key.
pub fn verify_signature(public_key_b64: &str, signature_b64: &str, message: &str) -> bool {
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

// -- Relay status --

async fn handle_relay_status(
    State(license): State<crate::license::SharedLicenseState>,
) -> impl IntoResponse {
    Json(serde_json::json!({
        "license_required": license.is_enabled().await,
        "version": env!("CARGO_PKG_VERSION"),
    }))
}

// -- Router --

/// Build the axum router with CORS support.
pub fn build_router(
    rooms: RoomMap,
    ws_state: crate::ws_router::SharedWsState,
    license: crate::license::SharedLicenseState,
) -> Router {
    use axum::http::header;
    use tower_http::cors::CorsLayer;

    let cors = CorsLayer::new()
        .allow_origin("*".parse::<HeaderValue>().unwrap())
        .allow_methods([Method::GET, Method::POST, Method::OPTIONS])
        .allow_headers([header::CONTENT_TYPE]);

    // Signaling routes use RoomMap state.
    let signaling = Router::new()
        .route("/register", post(handle_register))
        .route("/unregister", post(handle_unregister))
        .route("/bootstrap/{room_code}", get(handle_bootstrap))
        .route("/health", get(handle_health))
        .with_state(rooms);

    // TURN credential route (no shared state needed — credentials are time-limited,
    // coturn enforces its own allocation limits).
    let turn = Router::new()
        .route("/turn-credentials", get(handle_turn_credentials));

    // WebSocket + stats routes use WsState.
    let ws = Router::new()
        .route("/ws", axum::routing::get(crate::ws_router::ws_upgrade))
        .route("/server-stats", get(handle_server_stats))
        .with_state(ws_state);

    // Relay status route (license state).
    let status = Router::new()
        .route("/relay-status", get(handle_relay_status))
        .with_state(license);

    signaling.merge(ws).merge(turn).merge(status).layer(cors)
}

/// Run the HTTP + WebSocket signaling server.
pub async fn run_signaling_http(
    rooms: RoomMap,
    ws_state: crate::ws_router::SharedWsState,
    license: crate::license::SharedLicenseState,
    port: u16,
) -> Result<(), Box<dyn std::error::Error>> {
    spawn_cleanup_task(rooms.clone());

    let app = build_router(rooms, ws_state, license);
    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{port}")).await?;
    tracing::info!("Signaling + WebSocket server listening on port {port}");
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
