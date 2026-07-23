use base64::Engine;
use ed25519_dalek::{Signer, SigningKey};
use futures_util::{SinkExt, StreamExt};
use rand::rngs::OsRng;
use serde_json::json;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::sync::Mutex;
use tokio::time::sleep;
use tokio_tungstenite::tungstenite::Message;

type WsStream = tokio_tungstenite::WebSocketStream<
    tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
>;

const B58_ALPHABET: &[u8] = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

fn base58_encode(data: &[u8]) -> String {
    let zeros = data.iter().take_while(|b| **b == 0).count();
    let mut buf = vec![0u8; (data.len() - zeros) * 138 / 100 + 1];
    for &byte in &data[zeros..] {
        let mut carry = byte as usize;
        for slot in buf.iter_mut().rev() {
            carry += 256 * (*slot as usize);
            *slot = (carry % 58) as u8;
            carry /= 58;
        }
    }
    let skip = buf.iter().take_while(|b| **b == 0).count();
    let mut out = String::new();
    out.extend(std::iter::repeat('1').take(zeros));
    out.extend(buf[skip..].iter().map(|&b| B58_ALPHABET[b as usize] as char));
    out
}

/// Mirror of `NativeKeypair::peer_id()`: bs58btc of the identity multihash
/// wrapping the protobuf public key.
///
/// The relay now REJECTS an auth frame whose peer_id is not the derivation of
/// its public key, so a synthetic id like "roombench-0001" no longer
/// authenticates. Each connection generates its own keypair, so derived ids are
/// still unique per connection.
fn derive_peer_id(raw_pub: &[u8; 32]) -> String {
    let mut multihash = vec![0x00, 0x24, 0x08, 0x01, 0x12, 0x20];
    multihash.extend_from_slice(raw_pub);
    base58_encode(&multihash)
}

fn make_auth_message() -> String {
    let signing_key = SigningKey::generate(&mut OsRng);
    let verifying_key = signing_key.verifying_key();

    let raw_pub = verifying_key.to_bytes();
    let mut wrapped = vec![0x08, 0x01, 0x12, 0x20];
    wrapped.extend_from_slice(&raw_pub);
    let pub_b64 = base64::engine::general_purpose::STANDARD.encode(&wrapped);
    let peer_id = derive_peer_id(&raw_pub);

    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();

    let sign_payload = format!("hollow-ws-auth:{}:{}", peer_id, timestamp);
    let signature = signing_key.sign(sign_payload.as_bytes());
    let sig_b64 = base64::engine::general_purpose::STANDARD.encode(signature.to_bytes());

    json!({
        "type": "auth",
        "peer_id": peer_id,
        "public_key": pub_b64,
        "timestamp": timestamp,
        "signature": sig_b64
    })
    .to_string()
}

async fn connect_and_auth(
    tls_connector: &tokio_tungstenite::Connector,
) -> Option<WsStream> {
    let (mut ws, _) = tokio_tungstenite::connect_async_tls_with_config(
        "wss://relay.anonlisten.com:443/ws",
        None,
        false,
        Some(tls_connector.clone()),
    )
    .await
    .ok()?;

    let auth_msg = make_auth_message();
    ws.send(Message::Text(auth_msg)).await.ok()?;

    let timeout = tokio::time::timeout(Duration::from_secs(10), ws.next()).await;
    match timeout {
        Ok(Some(Ok(Message::Text(txt)))) if txt.contains("auth_ok") => Some(ws),
        _ => None,
    }
}

async fn join_room(ws: &Arc<Mutex<WsStream>>, room: &str) -> bool {
    let msg = json!({"type": "join", "room": room}).to_string();
    let mut ws = ws.lock().await;
    if ws.send(Message::Text(msg)).await.is_err() {
        return false;
    }
    // drain the members response (and any peer_joined notifications)
    match tokio::time::timeout(Duration::from_secs(5), ws.next()).await {
        Ok(Some(Ok(Message::Text(txt)))) => {
            if txt.contains("error") {
                eprintln!("  Room join error: {}", txt);
                return false;
            }
            true
        }
        _ => false,
    }
}

async fn find_relay_pid() -> u64 {
    let output = tokio::process::Command::new("bash")
        .args([
            "-c",
            "ps aux | grep 'hollow-relay.*--port 443' | grep -v grep | awk '{print $2}' | head -1",
        ])
        .output()
        .await
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();
    output.parse().unwrap_or(0)
}

async fn get_relay_rss_kb(pid: u64) -> u64 {
    if pid == 0 {
        return 0;
    }
    let output = tokio::process::Command::new("bash")
        .args(["-c", &format!("ps -o rss= -p {}", pid)])
        .output()
        .await
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();
    output.parse().unwrap_or(0)
}

/// Drain any pending messages from the websocket without blocking
async fn drain(ws: &Arc<Mutex<WsStream>>) {
    let mut ws = ws.lock().await;
    loop {
        match tokio::time::timeout(Duration::from_millis(100), ws.next()).await {
            Ok(Some(Ok(_))) => continue,
            _ => break,
        }
    }
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let num_peers: usize = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(50);
    let rooms_per_step: usize = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(100);
    let max_rooms: usize = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(5000);
    let settle_secs: u64 = args.get(4).and_then(|s| s.parse().ok()).unwrap_or(5);

    println!("=== Hollow Relay — Room Count Benchmark ===");
    println!("Peers:          {}", num_peers);
    println!("Rooms/step:     {}", rooms_per_step);
    println!("Max rooms:      {}", max_rooms);
    println!("Settle time:    {}s", settle_secs);
    println!();

    // Temporarily bump the relay cap for this benchmark
    // (The relay must be restarted with a higher MAX_ROOMS_PER_PEER or the cap removed)
    println!("NOTE: Make sure the relay's MAX_ROOMS_PER_PEER is raised above {} before running!", max_rooms);
    println!();

    let mut root_store = rustls::RootCertStore::empty();
    root_store.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let tls_config = rustls::ClientConfig::builder()
        .with_root_certificates(root_store)
        .with_no_client_auth();
    let tls_connector = tokio_tungstenite::Connector::Rustls(Arc::new(tls_config));

    let relay_pid = find_relay_pid().await;
    if relay_pid == 0 {
        eprintln!("ERROR: Could not find relay process. Is hollow-relay running?");
        return;
    }

    let baseline_rss = get_relay_rss_kb(relay_pid).await;
    println!(
        "Relay PID: {} (baseline RSS: {:.1} MB)",
        relay_pid,
        baseline_rss as f64 / 1024.0
    );

    // Phase 1: Connect all peers
    println!("\n--- Phase 1: Connecting {} peers ---", num_peers);
    let mut peers: Vec<Arc<Mutex<WsStream>>> = Vec::new();
    for i in 0..num_peers {
        match connect_and_auth(&tls_connector).await {
            Some(ws) => peers.push(Arc::new(Mutex::new(ws))),
            None => eprintln!("  Failed to connect peer {}", i),
        }
        if i % 10 == 9 {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }
    println!("Connected: {} / {}", peers.len(), num_peers);

    sleep(Duration::from_secs(settle_secs)).await;
    let after_connect_rss = get_relay_rss_kb(relay_pid).await;
    let per_conn_kb =
        (after_connect_rss.saturating_sub(baseline_rss)) as f64 / peers.len() as f64;
    println!(
        "After connect: {:.1} MB ({:.2} KB/conn)",
        after_connect_rss as f64 / 1024.0,
        per_conn_kb
    );

    // Phase 2: Join rooms in steps, each peer joins the same rooms
    // This gives us: total_room_memberships = num_peers * rooms_joined_per_peer
    println!("\n--- Phase 2: Room scaling ---");
    println!(
        "{:>8} {:>10} {:>12} {:>14} {:>14} {:>14}",
        "rooms/p", "total_memb", "relay_MB", "delta_MB", "bytes/memb", "bytes/room_p"
    );
    println!("{}", "-".repeat(80));

    let mut current_rooms: usize = 0;
    let mut prev_rss = after_connect_rss;
    let mut results: Vec<(usize, usize, f64, f64)> = Vec::new();

    while current_rooms < max_rooms {
        let step_start = current_rooms;
        let step_end = std::cmp::min(current_rooms + rooms_per_step, max_rooms);
        let mut any_failed = false;

        for room_idx in step_start..step_end {
            let room_code = format!("bench-room-{:06}", room_idx);
            for peer_ws in &peers {
                if !join_room(peer_ws, &room_code).await {
                    any_failed = true;
                    break;
                }
            }
            if any_failed {
                break;
            }
        }

        if any_failed {
            println!("  Room join failed at room {} — hit relay cap?", current_rooms);
            break;
        }

        current_rooms = step_end;

        // drain pending messages from all peers
        for peer_ws in &peers {
            drain(peer_ws).await;
        }

        sleep(Duration::from_secs(settle_secs)).await;

        let rss_now = get_relay_rss_kb(relay_pid).await;
        let total_memberships = current_rooms * peers.len();
        let delta_kb = rss_now.saturating_sub(after_connect_rss) as f64;
        let bytes_per_membership = if total_memberships > 0 {
            delta_kb * 1024.0 / total_memberships as f64
        } else {
            0.0
        };
        let bytes_per_room_per_peer = if current_rooms > 0 {
            delta_kb * 1024.0 / (current_rooms as f64 * peers.len() as f64)
        } else {
            0.0
        };

        println!(
            "{:>8} {:>10} {:>11.1} {:>13.2} {:>13.1} {:>13.1}",
            current_rooms,
            total_memberships,
            rss_now as f64 / 1024.0,
            delta_kb / 1024.0,
            bytes_per_membership,
            bytes_per_room_per_peer
        );

        results.push((
            current_rooms,
            total_memberships,
            rss_now as f64 / 1024.0,
            bytes_per_membership,
        ));

        prev_rss = rss_now;
    }

    // Phase 3: Summary
    println!("\n=== RESULTS ===");
    println!(
        "Baseline (no rooms): {:.1} MB ({} peers)",
        after_connect_rss as f64 / 1024.0,
        peers.len()
    );

    if let Some(last) = results.last() {
        let total_delta_mb = last.2 - after_connect_rss as f64 / 1024.0;
        println!(
            "Final ({} rooms/peer, {} total memberships): {:.1} MB",
            last.0, last.1, last.2
        );
        println!("Room overhead: {:.2} MB total", total_delta_mb);
        println!("Per room-membership: {:.1} bytes", last.3);
        println!(
            "Estimated cost of 2000 rooms/peer × {} peers: {:.2} MB",
            peers.len(),
            last.3 * 2000.0 * peers.len() as f64 / 1024.0 / 1024.0
        );
        println!(
            "Estimated cost of 10000 rooms/peer × {} peers: {:.2} MB",
            peers.len(),
            last.3 * 10000.0 * peers.len() as f64 / 1024.0 / 1024.0
        );
    }

    let final_rss = get_relay_rss_kb(relay_pid).await;
    println!(
        "\nRelay RSS now: {:.1} MB",
        final_rss as f64 / 1024.0
    );

    println!("\nDropping connections...");
    drop(peers);
    sleep(Duration::from_secs(3)).await;

    let post_drop_rss = get_relay_rss_kb(relay_pid).await;
    println!(
        "After disconnect: {:.1} MB (freed {:.1} MB)",
        post_drop_rss as f64 / 1024.0,
        (final_rss.saturating_sub(post_drop_rss)) as f64 / 1024.0
    );

    println!("\nDone.");
}
