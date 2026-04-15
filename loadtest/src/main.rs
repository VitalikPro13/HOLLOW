// Hollow WebSocket relay load tester.
//
// Spawns N concurrent authenticated WS connections, distributes them across R rooms,
// and sends a small heartbeat message every `heartbeat-interval` seconds.
//
// Usage:
//   hollow-loadtest --target wss://relay.anonlisten.com/ws --connections 10000 --rooms 200
//   hollow-loadtest --target ws://141.227.186.209:8080/ws --connections 10000 --rooms 200

use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine;
use clap::Parser;
use ed25519_dalek::{Signer, SigningKey};
use futures_util::{SinkExt, StreamExt};
use rand::rngs::OsRng;
use serde::Serialize;
use tokio::sync::Semaphore;
use tokio::time::{sleep, MissedTickBehavior};
use tokio_tungstenite::tungstenite::Message;

#[derive(Parser, Clone)]
#[command(name = "hollow-loadtest")]
struct Args {
    /// Target WS URL, e.g. wss://relay.anonlisten.com/ws or ws://1.2.3.4:8080/ws
    #[arg(long)]
    target: String,

    /// Total number of WS connections to open
    #[arg(long, default_value = "10000")]
    connections: usize,

    /// Number of distinct rooms to distribute connections across
    #[arg(long, default_value = "200")]
    rooms: usize,

    /// Connections to open per second during ramp-up
    #[arg(long, default_value = "200")]
    ramp_per_sec: usize,

    /// Heartbeat interval in seconds (each connection sends a Msg every N seconds)
    #[arg(long, default_value = "30")]
    heartbeat_interval: u64,

    /// Hold duration in seconds after ramp-up completes
    #[arg(long, default_value = "300")]
    hold_secs: u64,

    /// Max concurrent in-flight handshakes (back-pressure on ramp)
    #[arg(long, default_value = "500")]
    max_inflight: usize,
}

#[derive(Clone, Default)]
struct Stats {
    connecting: Arc<AtomicUsize>,
    connected: Arc<AtomicUsize>,
    failed_handshake: Arc<AtomicU64>,
    failed_auth: Arc<AtomicU64>,
    disconnected: Arc<AtomicU64>,
    msgs_sent: Arc<AtomicU64>,
    msgs_recv: Arc<AtomicU64>,
    bytes_sent: Arc<AtomicU64>,
    bytes_recv: Arc<AtomicU64>,
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ClientMsg<'a> {
    Auth {
        peer_id: &'a str,
        public_key: &'a str,
        timestamp: u64,
        signature: &'a str,
    },
    Join { room: &'a str },
    Msg { room: &'a str, data: &'a str },
}

#[tokio::main(flavor = "multi_thread")]
async fn main() {
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("install rustls crypto provider");

    let args = Args::parse();
    let stats = Stats::default();

    println!(
        "Target: {}\nConnections: {}\nRooms: {}\nRamp: {}/s\nHeartbeat: every {}s\nHold: {}s",
        args.target, args.connections, args.rooms, args.ramp_per_sec, args.heartbeat_interval, args.hold_secs
    );

    // Reporter task — prints stats every 2s
    let reporter_stats = stats.clone();
    let reporter = tokio::spawn(async move {
        let start = Instant::now();
        let mut tick = tokio::time::interval(Duration::from_secs(2));
        tick.set_missed_tick_behavior(MissedTickBehavior::Delay);
        loop {
            tick.tick().await;
            let elapsed = start.elapsed().as_secs();
            println!(
                "[{:>4}s] connecting={:>5} connected={:>5} hs_fail={:>4} auth_fail={:>4} disc={:>4} | sent={} ({} KB) recv={} ({} KB)",
                elapsed,
                reporter_stats.connecting.load(Ordering::Relaxed),
                reporter_stats.connected.load(Ordering::Relaxed),
                reporter_stats.failed_handshake.load(Ordering::Relaxed),
                reporter_stats.failed_auth.load(Ordering::Relaxed),
                reporter_stats.disconnected.load(Ordering::Relaxed),
                reporter_stats.msgs_sent.load(Ordering::Relaxed),
                reporter_stats.bytes_sent.load(Ordering::Relaxed) / 1024,
                reporter_stats.msgs_recv.load(Ordering::Relaxed),
                reporter_stats.bytes_recv.load(Ordering::Relaxed) / 1024,
            );
        }
    });

    let semaphore = Arc::new(Semaphore::new(args.max_inflight));
    let mut handles = Vec::with_capacity(args.connections);
    let ramp_delay = Duration::from_micros(1_000_000 / args.ramp_per_sec as u64);

    for i in 0..args.connections {
        let permit = semaphore.clone().acquire_owned().await.unwrap();
        let target = args.target.clone();
        let stats_c = stats.clone();
        let room = format!("loadtest-room-{}", i % args.rooms);
        let heartbeat = args.heartbeat_interval;

        let h = tokio::spawn(async move {
            // Permit is released after handshake+auth completes (passed by value, dropped inside)
            run_connection(target, room, stats_c, heartbeat, args.hold_secs + 60, permit).await;
        });
        handles.push(h);

        sleep(ramp_delay).await;
    }

    println!("\n--- Ramp complete. Holding for {}s ---\n", args.hold_secs);
    sleep(Duration::from_secs(args.hold_secs)).await;
    println!("\n--- Hold complete. Tearing down. ---\n");

    reporter.abort();
    for h in handles {
        h.abort();
    }
    sleep(Duration::from_secs(2)).await;

    println!(
        "\n=== Final ===\nConnected peak: {}\nHandshake failures: {}\nAuth failures: {}\nDisconnects: {}\nMsgs sent: {} ({} KB)\nMsgs recv: {} ({} KB)",
        stats.connected.load(Ordering::Relaxed),
        stats.failed_handshake.load(Ordering::Relaxed),
        stats.failed_auth.load(Ordering::Relaxed),
        stats.disconnected.load(Ordering::Relaxed),
        stats.msgs_sent.load(Ordering::Relaxed),
        stats.bytes_sent.load(Ordering::Relaxed) / 1024,
        stats.msgs_recv.load(Ordering::Relaxed),
        stats.bytes_recv.load(Ordering::Relaxed) / 1024,
    );
}

async fn run_connection(
    target: String,
    room: String,
    stats: Stats,
    heartbeat_interval: u64,
    total_lifetime: u64,
    permit: tokio::sync::OwnedSemaphorePermit,
) {
    let mut permit = Some(permit);
    stats.connecting.fetch_add(1, Ordering::Relaxed);

    // Generate identity (libp2p-compatible: protobuf-wrapped pubkey + multihash peer_id)
    let signing_key = SigningKey::generate(&mut OsRng);
    let verifying_key = signing_key.verifying_key();
    let pubkey_raw = verifying_key.to_bytes();

    // 36-byte protobuf: [0x08, 0x01, 0x12, 0x20] + raw 32-byte pubkey
    let mut pubkey_proto = Vec::with_capacity(36);
    pubkey_proto.extend_from_slice(&[0x08, 0x01, 0x12, 0x20]);
    pubkey_proto.extend_from_slice(&pubkey_raw);
    let pubkey_b64 = base64::engine::general_purpose::STANDARD.encode(&pubkey_proto);

    // peer_id = base58(0x00 + 0x24 + pubkey_proto)
    let mut multihash = Vec::with_capacity(2 + pubkey_proto.len());
    multihash.push(0x00);
    multihash.push(pubkey_proto.len() as u8);
    multihash.extend_from_slice(&pubkey_proto);
    let peer_id = bs58::encode(&multihash).with_alphabet(bs58::Alphabet::BITCOIN).into_string();

    // Connect
    let ws_stream = match tokio_tungstenite::connect_async(&target).await {
        Ok((s, _)) => s,
        Err(_) => {
            stats.connecting.fetch_sub(1, Ordering::Relaxed);
            stats.failed_handshake.fetch_add(1, Ordering::Relaxed);
            return;
        }
    };
    let (mut write, mut read) = ws_stream.split();

    // Auth
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let signed_msg = format!("hollow-ws-auth:{}:{}", peer_id, timestamp);
    let signature = signing_key.sign(signed_msg.as_bytes());
    let sig_b64 = base64::engine::general_purpose::STANDARD.encode(signature.to_bytes());

    let auth = ClientMsg::Auth {
        peer_id: &peer_id,
        public_key: &pubkey_b64,
        timestamp,
        signature: &sig_b64,
    };
    let auth_json = serde_json::to_string(&auth).unwrap();
    let auth_len = auth_json.len() as u64;
    if write.send(Message::Text(auth_json.into())).await.is_err() {
        stats.connecting.fetch_sub(1, Ordering::Relaxed);
        stats.failed_auth.fetch_add(1, Ordering::Relaxed);
        return;
    }
    stats.bytes_sent.fetch_add(auth_len, Ordering::Relaxed);

    // Wait for AuthOk
    let auth_ok = tokio::time::timeout(Duration::from_secs(15), read.next()).await;
    let authed = matches!(auth_ok, Ok(Some(Ok(Message::Text(ref t)))) if t.contains("auth_ok"));
    if !authed {
        stats.connecting.fetch_sub(1, Ordering::Relaxed);
        stats.failed_auth.fetch_add(1, Ordering::Relaxed);
        return;
    }

    // Join room
    let join = ClientMsg::Join { room: &room };
    let join_json = serde_json::to_string(&join).unwrap();
    let join_len = join_json.len() as u64;
    if write.send(Message::Text(join_json.into())).await.is_err() {
        stats.connecting.fetch_sub(1, Ordering::Relaxed);
        stats.failed_auth.fetch_add(1, Ordering::Relaxed);
        return;
    }
    stats.bytes_sent.fetch_add(join_len, Ordering::Relaxed);
    stats.msgs_sent.fetch_add(2, Ordering::Relaxed); // auth + join

    stats.connecting.fetch_sub(1, Ordering::Relaxed);
    stats.connected.fetch_add(1, Ordering::Relaxed);

    // Handshake done — release in-flight permit so the next ramp slot can start
    permit.take();

    let stats_recv = stats.clone();
    let recv_task = tokio::spawn(async move {
        while let Some(Ok(msg)) = read.next().await {
            match msg {
                Message::Text(t) => {
                    stats_recv.msgs_recv.fetch_add(1, Ordering::Relaxed);
                    stats_recv.bytes_recv.fetch_add(t.len() as u64, Ordering::Relaxed);
                }
                Message::Binary(b) => {
                    stats_recv.msgs_recv.fetch_add(1, Ordering::Relaxed);
                    stats_recv.bytes_recv.fetch_add(b.len() as u64, Ordering::Relaxed);
                }
                Message::Ping(_) | Message::Pong(_) => {}
                Message::Close(_) => break,
                _ => {}
            }
        }
    });

    // Heartbeat loop
    let hb = ClientMsg::Msg { room: &room, data: "hb" };
    let hb_json = serde_json::to_string(&hb).unwrap();
    let hb_len = hb_json.len() as u64;

    let mut tick = tokio::time::interval(Duration::from_secs(heartbeat_interval));
    tick.set_missed_tick_behavior(MissedTickBehavior::Delay);
    tick.tick().await; // skip immediate fire

    let deadline = Instant::now() + Duration::from_secs(total_lifetime);
    while Instant::now() < deadline {
        tick.tick().await;
        if write.send(Message::Text(hb_json.clone().into())).await.is_err() {
            break;
        }
        stats.msgs_sent.fetch_add(1, Ordering::Relaxed);
        stats.bytes_sent.fetch_add(hb_len, Ordering::Relaxed);
    }

    recv_task.abort();
    stats.connected.fetch_sub(1, Ordering::Relaxed);
    stats.disconnected.fetch_add(1, Ordering::Relaxed);
}
