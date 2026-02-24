use libp2p::identity;
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;
use tokio::time::{self, Duration};

const SIGNALING_URL: &str = "https://haven-signaling.anonlisten.workers.dev";
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(300); // 5 minutes

// -- Commands & Events --

pub(crate) enum SignalingCmd {
    Register {
        room_code: String,
        addresses: Vec<String>,
    },
    Bootstrap {
        room_code: String,
    },
}

#[derive(Debug)]
pub(crate) enum SignalingEvent {
    BootstrapPeers { peers: Vec<BootstrapPeer> },
    Error { message: String },
}

#[derive(Debug, Clone)]
pub(crate) struct BootstrapPeer {
    pub peer_id: String,
    pub addresses: Vec<String>,
}

// -- Wire types (JSON) --

#[derive(Serialize)]
struct RegisterPayload {
    room_code: String,
    peer_id: String,
    addresses: Vec<String>,
    timestamp: u64,
    public_key: String,
    signature: String,
}

#[derive(Deserialize)]
struct BootstrapResponse {
    peers: Vec<BootstrapPeerWire>,
}

#[derive(Deserialize)]
struct BootstrapPeerWire {
    peer_id: String,
    addresses: Vec<String>,
}

// -- Background task --

/// Spawn the signaling background task.
/// Returns a command sender and event receiver.
pub(crate) fn spawn_signaling_task(
    keypair: identity::Keypair,
    peer_id_str: String,
) -> (mpsc::Sender<SignalingCmd>, mpsc::Receiver<SignalingEvent>) {
    let (cmd_tx, cmd_rx) = mpsc::channel::<SignalingCmd>(32);
    let (event_tx, event_rx) = mpsc::channel::<SignalingEvent>(32);

    tokio::spawn(signaling_loop(keypair, peer_id_str, cmd_rx, event_tx));

    (cmd_tx, event_rx)
}

async fn signaling_loop(
    keypair: identity::Keypair,
    peer_id_str: String,
    mut cmd_rx: mpsc::Receiver<SignalingCmd>,
    event_tx: mpsc::Sender<SignalingEvent>,
) {
    let client = reqwest::Client::new();

    // Encode the public key as base64 protobuf (36 bytes for Ed25519).
    let pub_key_proto = keypair.public().encode_protobuf();
    let pub_key_b64 = base64::Engine::encode(
        &base64::engine::general_purpose::STANDARD,
        &pub_key_proto,
    );

    // Track active room for heartbeat.
    let mut active_room: Option<String> = None;
    let mut active_addrs: Vec<String> = Vec::new();
    let mut heartbeat = time::interval(HEARTBEAT_INTERVAL);
    heartbeat.tick().await; // consume the immediate first tick

    loop {
        tokio::select! {
            Some(cmd) = cmd_rx.recv() => {
                match cmd {
                    SignalingCmd::Register { room_code, addresses } => {
                        active_room = Some(room_code.clone());
                        active_addrs = addresses.clone();
                        if let Err(e) = do_register(
                            &client, &keypair, &peer_id_str, &pub_key_b64,
                            &room_code, &addresses,
                        ).await {
                            let _ = event_tx.send(SignalingEvent::Error {
                                message: format!("Register failed: {e}"),
                            }).await;
                        }
                    }
                    SignalingCmd::Bootstrap { room_code } => {
                        match do_bootstrap(&client, &room_code).await {
                            Ok(peers) => {
                                let _ = event_tx.send(SignalingEvent::BootstrapPeers { peers }).await;
                            }
                            Err(e) => {
                                let _ = event_tx.send(SignalingEvent::Error {
                                    message: format!("Bootstrap failed: {e}"),
                                }).await;
                            }
                        }
                    }
                }
            }
            _ = heartbeat.tick() => {
                // Re-register with the signaling service to stay fresh.
                if let Some(room) = &active_room
                    && let Err(e) = do_register(
                        &client, &keypair, &peer_id_str, &pub_key_b64,
                        room, &active_addrs,
                    ).await
                {
                    let _ = event_tx.send(SignalingEvent::Error {
                        message: format!("Heartbeat failed: {e}"),
                    }).await;
                }
            }
        }
    }
}

async fn do_register(
    client: &reqwest::Client,
    keypair: &identity::Keypair,
    peer_id_str: &str,
    pub_key_b64: &str,
    room_code: &str,
    addresses: &[String],
) -> Result<(), String> {
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| format!("Clock error: {e}"))?
        .as_secs();

    // Trim to max 5 addresses.
    let addrs: Vec<String> = addresses.iter().take(5).cloned().collect();
    let addrs_joined = addrs.join(",");

    // Sign: "haven-register:{room_code}:{peer_id}:{addresses_joined}:{timestamp}"
    let message = format!("haven-register:{room_code}:{peer_id_str}:{addrs_joined}:{timestamp}");
    let signature = keypair
        .sign(message.as_bytes())
        .map_err(|e| format!("Signing failed: {e}"))?;
    let sig_b64 = base64::Engine::encode(
        &base64::engine::general_purpose::STANDARD,
        &signature,
    );

    let payload = RegisterPayload {
        room_code: room_code.to_string(),
        peer_id: peer_id_str.to_string(),
        addresses: addrs,
        timestamp,
        public_key: pub_key_b64.to_string(),
        signature: sig_b64,
    };

    let resp = client
        .post(format!("{SIGNALING_URL}/register"))
        .json(&payload)
        .timeout(Duration::from_secs(10))
        .send()
        .await
        .map_err(|e| format!("HTTP request failed: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("Server returned {status}: {body}"));
    }

    Ok(())
}

async fn do_bootstrap(
    client: &reqwest::Client,
    room_code: &str,
) -> Result<Vec<BootstrapPeer>, String> {
    let url = format!("{SIGNALING_URL}/bootstrap/{}", urlencoding_encode(room_code));

    let resp = client
        .get(&url)
        .timeout(Duration::from_secs(10))
        .send()
        .await
        .map_err(|e| format!("HTTP request failed: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("Server returned {status}: {body}"));
    }

    let data: BootstrapResponse = resp
        .json()
        .await
        .map_err(|e| format!("Invalid response JSON: {e}"))?;

    Ok(data
        .peers
        .into_iter()
        .map(|p| BootstrapPeer {
            peer_id: p.peer_id,
            addresses: p.addresses,
        })
        .collect())
}

/// Simple percent-encoding for URL path segments.
fn urlencoding_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char);
            }
            _ => {
                out.push_str(&format!("%{b:02X}"));
            }
        }
    }
    out
}
