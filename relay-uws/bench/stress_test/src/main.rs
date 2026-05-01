use base64::Engine;
use ed25519_dalek::{Signer, SigningKey};
use futures_util::{SinkExt, StreamExt};
use rand::rngs::OsRng;
use serde_json::json;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::sync::Semaphore;
use tokio::time::sleep;
use tokio_tungstenite::tungstenite::Message;

static AUTH_OK: AtomicU64 = AtomicU64::new(0);
static FAILED: AtomicU64 = AtomicU64::new(0);
static DROPPED: AtomicU64 = AtomicU64::new(0);

fn make_auth_message(peer_id: &str) -> String {
    let signing_key = SigningKey::generate(&mut OsRng);
    let verifying_key = signing_key.verifying_key();

    let raw_pub = verifying_key.to_bytes();
    let mut wrapped = vec![0x08, 0x01, 0x12, 0x20];
    wrapped.extend_from_slice(&raw_pub);
    let pub_b64 = base64::engine::general_purpose::STANDARD.encode(&wrapped);

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

async fn connect_and_hold(
    id: u64,
    semaphore: Arc<Semaphore>,
    tls_connector: tokio_tungstenite::Connector,
) {
    let peer_id = format!("stress-{:06}", id);

    let (mut ws, _) = {
        let _permit = semaphore.acquire().await.unwrap();

        match tokio_tungstenite::connect_async_tls_with_config(
            "wss://relay.anonlisten.com:443/ws",
            None,
            false,
            Some(tls_connector.clone()),
        )
        .await
        {
            Ok(r) => r,
            Err(e) => {
                let f = FAILED.fetch_add(1, Ordering::Relaxed) + 1;
                if f <= 10 || f % 5000 == 0 {
                    eprintln!("[FAIL #{}] id={} connect: {}", f, id, e);
                }
                return;
            }
        }
    };

    let auth_msg = make_auth_message(&peer_id);
    if ws.send(Message::Text(auth_msg)).await.is_err() {
        FAILED.fetch_add(1, Ordering::Relaxed);
        return;
    }

    let timeout = tokio::time::timeout(Duration::from_secs(10), ws.next()).await;
    match timeout {
        Ok(Some(Ok(Message::Text(txt)))) => {
            if txt.contains("auth_ok") {
                AUTH_OK.fetch_add(1, Ordering::Relaxed);
            } else {
                let f = FAILED.fetch_add(1, Ordering::Relaxed) + 1;
                if f <= 10 || f % 5000 == 0 {
                    eprintln!("[FAIL #{}] id={} auth rejected: {}", f, id, txt);
                }
                return;
            }
        }
        _ => {
            FAILED.fetch_add(1, Ordering::Relaxed);
            return;
        }
    }

    loop {
        match tokio::time::timeout(Duration::from_secs(130), ws.next()).await {
            Ok(Some(Ok(_))) => {}
            Ok(Some(Err(_))) | Ok(None) => break,
            Err(_) => break,
        }
    }

    AUTH_OK.fetch_sub(1, Ordering::Relaxed);
    DROPPED.fetch_add(1, Ordering::Relaxed);
}

async fn find_relay_pid() -> u64 {
    let output = tokio::process::Command::new("bash")
        .args(["-c", "ps aux | grep 'hollow-relay.*--port 443' | grep -v grep | awk '{print $2}' | head -1"])
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

async fn get_self_rss_mb() -> f64 {
    let output = tokio::process::Command::new("bash")
        .args(["-c", &format!("ps -o rss= -p {}", std::process::id())])
        .output()
        .await
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();
    let kb: u64 = output.parse().unwrap_or(0);
    kb as f64 / 1024.0
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let target: u64 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(10000);
    let ramp_rate: u64 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(500);
    let concurrency: usize = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(100);

    // build a shared rustls config (single allocation for all connections)
    let mut root_store = rustls::RootCertStore::empty();
    root_store.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let tls_config = rustls::ClientConfig::builder()
        .with_root_certificates(root_store)
        .with_no_client_auth();
    let tls_connector =
        tokio_tungstenite::Connector::Rustls(Arc::new(tls_config));

    let relay_pid = find_relay_pid().await;
    let baseline_rss = get_relay_rss_kb(relay_pid).await;

    println!("=== Hollow Relay Stress Test (rustls) ===");
    println!("Target: {} connections", target);
    println!(
        "Ramp: {} per batch, {} concurrent handshakes",
        ramp_rate, concurrency
    );
    println!(
        "Relay PID: {} (baseline RSS: {} KB = {:.1} MB)",
        relay_pid,
        baseline_rss,
        baseline_rss as f64 / 1024.0
    );
    println!();

    let semaphore = Arc::new(Semaphore::new(concurrency));

    let baseline_rss_copy = baseline_rss;
    tokio::spawn(async move {
        loop {
            sleep(Duration::from_secs(5)).await;
            let authed = AUTH_OK.load(Ordering::Relaxed);
            let failed = FAILED.load(Ordering::Relaxed);
            let dropped = DROPPED.load(Ordering::Relaxed);
            let rss_kb = get_relay_rss_kb(relay_pid).await;
            let rss_mb = rss_kb as f64 / 1024.0;
            let per_conn_kb = if authed > 0 {
                (rss_kb.saturating_sub(baseline_rss_copy)) as f64 / authed as f64
            } else {
                0.0
            };
            let self_mb = get_self_rss_mb().await;

            println!(
                "[STATS] alive: {:>6} | failed: {:>5} | dropped: {:>5} | relay: {:>7.1} MB ({:.2} KB/conn) | client: {:>7.1} MB",
                authed, failed, dropped, rss_mb, per_conn_kb, self_mb
            );
        }
    });

    let mut spawned = 0u64;
    while spawned < target {
        let batch_end = std::cmp::min(spawned + ramp_rate, target);
        println!(
            "\n--- Ramping {}-{} (total target: {}) ---",
            spawned + 1,
            batch_end,
            target
        );

        for id in spawned..batch_end {
            let sem = semaphore.clone();
            let tls = tls_connector.clone();
            tokio::spawn(connect_and_hold(id, sem, tls));
            if id % 10 == 9 {
                sleep(Duration::from_millis(5)).await;
            }
        }
        spawned = batch_end;

        let wait_secs =
            std::cmp::max((ramp_rate as f64 / concurrency as f64 * 2.0).ceil() as u64, 5);
        println!("  (settling for {}s...)", wait_secs);
        sleep(Duration::from_secs(wait_secs)).await;
    }

    println!("\n=== All {} connections spawned ===", target);
    println!("Waiting 30s for stragglers...");
    sleep(Duration::from_secs(30)).await;

    let final_authed = AUTH_OK.load(Ordering::Relaxed);
    let final_failed = FAILED.load(Ordering::Relaxed);
    let final_dropped = DROPPED.load(Ordering::Relaxed);
    let final_rss = get_relay_rss_kb(relay_pid).await;
    let final_self = get_self_rss_mb().await;

    println!("\n=== FINAL RESULTS ===");
    println!("Alive:       {}", final_authed);
    println!("Failed:      {}", final_failed);
    println!("Dropped:     {}", final_dropped);
    println!(
        "Relay RSS:   {:.1} MB ({} KB)",
        final_rss as f64 / 1024.0,
        final_rss
    );
    if final_authed > 0 {
        println!(
            "Per-conn:    {:.2} KB",
            (final_rss.saturating_sub(baseline_rss)) as f64 / final_authed as f64
        );
    }
    println!(
        "Client RSS:  {:.1} MB",
        final_self
    );
    println!(
        "Success:     {:.1}%",
        final_authed as f64 / target as f64 * 100.0
    );

    println!("\nHolding connections for 60s...");
    sleep(Duration::from_secs(60)).await;
    println!("Done.");
}
