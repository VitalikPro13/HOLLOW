//! The forwarder's relay control plane: one authenticated WS in the dedicated
//! `fwd:{peer_id}` room, an Olm KEY-EXCHANGE RESPONDER (the forwarder never
//! initiates), and the fwd_* envelope dispatch into the engine.
//!
//! Deliberately NOT `spawn_node` / `spawn_ws_client` — no CRDT, no MLS, no
//! sync, no gossip, no room-state machinery. The manual loop mirrors
//! `node/fetch.rs::run_fetch` (the proven headless precedent) plus the
//! keepalive/liveness discipline from `ws_client.rs` (30 s ping, 70 s
//! liveness, bounded writes, backoff reconnect + room rejoin). Media legs ride
//! their own UDP sockets and survive signaling blips untouched.
//!
//! Zero metadata logging: no per-peer request logs; security refusals log the
//! reason, never a stream identity.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;

use crate::crypto::{CryptoStore, OlmManager};
use crate::hollow_log;
use crate::identity::native_identity::NativeKeypair;
use crate::node::crypto_handler::{
    key_request_signing_payload, persist_crypto_state, persist_olm_session, signed_key_bundle,
    verify_key_exchange, KeyExchangeAuth, REQUIRE_SIGNED_KEY_EXCHANGE,
};
use crate::node::types::{HavenMessage, MessageEnvelope};
use crate::node::ws_client;

use super::dispatch::PeerBuckets;
use super::engine::{EngineCmd, OutSignal};
use super::ForwarderConfig;

/// Mirrors ws_client.rs WRITE_TIMEOUT / LIVENESS_TIMEOUT (the zombie-socket
/// lessons — a wedged sink must never freeze the loop).
const WRITE_TIMEOUT: Duration = Duration::from_secs(30);
const LIVENESS_TIMEOUT: Duration = Duration::from_secs(70);

type WsSink = futures_util::stream::SplitSink<ws_client::WsStream, Message>;

async fn bounded_send(write: &mut WsSink, msg: Message) -> Result<(), String> {
    match tokio::time::timeout(WRITE_TIMEOUT, write.send(msg)).await {
        Ok(Ok(())) => Ok(()),
        Ok(Err(e)) => Err(e.to_string()),
        Err(_) => Err("write timed out — connection wedged".into()),
    }
}

/// Run the signaling loop forever. Returns only on a fatal error (license
/// refused) or when the engine side hangs up.
pub(crate) async fn run(
    cfg: Arc<ForwarderConfig>,
    keypair: NativeKeypair,
    mut olm: OlmManager,
    crypto_store: CryptoStore,
    engine_tx: mpsc::UnboundedSender<EngineCmd>,
    mut out_rx: mpsc::UnboundedReceiver<OutSignal>,
) -> Result<(), String> {
    let peer_id = keypair.peer_id();
    let proto = keypair.to_protobuf_encoding()?;
    let pub_b64 = {
        use base64::Engine;
        base64::engine::general_purpose::STANDARD.encode(keypair.public_key_protobuf())
    };
    let url = format!("wss://{}/ws", cfg.relay_domain);
    let room = format!("fwd:{peer_id}");

    // Peers we hold a session-teardown cooldown for (KeyRequest re-key storms).
    let mut rekey_cooldown: HashMap<String, std::time::Instant> = HashMap::new();
    let mut backoff: u64 = 1;

    loop {
        let ws = match ws_client::connect_and_auth(
            &url, &peer_id, &proto, &pub_b64, cfg.license_key.as_deref(), /*fetch=*/ false,
        )
        .await
        {
            Ok(ws) => ws,
            Err(e) => {
                if e.contains("license") {
                    // License refusals never heal by retrying (mirrors the
                    // client's stop-on-LicenseError rule).
                    return Err(format!("relay refused auth: {e}"));
                }
                hollow_log!("[HOLLOW-FWD] relay connect failed: {e} — retry in {backoff}s");
                tokio::time::sleep(Duration::from_secs(backoff)).await;
                backoff = (backoff * 2).min(30);
                continue;
            }
        };
        hollow_log!("[HOLLOW-FWD] relay connected, joining {room}");
        backoff = 1;

        let (mut write, mut read) = ws.split();
        let join = serde_json::json!({"type": "join", "room": room}).to_string();
        if bounded_send(&mut write, Message::Text(join.into())).await.is_err() {
            continue;
        }

        let mut ping = tokio::time::interval(Duration::from_secs(30));
        ping.tick().await; // consume the immediate first tick
        let mut last_recv = tokio::time::Instant::now();
        let mut room_peers: HashSet<String> = HashSet::new();
        let mut buckets = PeerBuckets::new(20, 5);

        'session: loop {
            tokio::select! {
                _ = ping.tick() => {
                    // Zombie check FIRST (the ws_client discipline).
                    if last_recv.elapsed() > LIVENESS_TIMEOUT {
                        hollow_log!("[HOLLOW-FWD] no relay traffic for {}s — reconnecting", last_recv.elapsed().as_secs());
                        break 'session;
                    }
                    if bounded_send(&mut write, Message::Ping(vec![0x01].into())).await.is_err() {
                        break 'session;
                    }
                }
                out = out_rx.recv() => {
                    let Some(sig) = out else { return Ok(()) }; // engine gone
                    send_encrypted(&mut olm, &crypto_store, &mut write, &room, sig).await;
                }
                frame = read.next() => {
                    let Some(Ok(msg)) = frame else {
                        hollow_log!("[HOLLOW-FWD] relay read ended — reconnecting");
                        break 'session;
                    };
                    last_recv = tokio::time::Instant::now();
                    match msg {
                        Message::Text(text) => {
                            handle_text_frame(
                                &text, &room, &mut room_peers, &mut buckets, &engine_tx,
                            );
                        }
                        Message::Binary(data) => {
                            handle_binary_frame(
                                &data, &peer_id, &keypair, &mut olm, &crypto_store,
                                &mut buckets, &mut rekey_cooldown, &mut write, &room,
                                &engine_tx,
                            ).await;
                        }
                        Message::Ping(p) => {
                            if bounded_send(&mut write, Message::Pong(p)).await.is_err() {
                                break 'session;
                            }
                        }
                        Message::Close(_) => {
                            hollow_log!("[HOLLOW-FWD] relay closed the connection");
                            break 'session;
                        }
                        _ => {}
                    }
                }
            }
        }

        tokio::time::sleep(Duration::from_secs(backoff)).await;
        backoff = (backoff * 2).min(30);
    }
}

/// Room presence tracking. A vanished peer drives engine cleanup (owner gone
/// → streams unregister; viewer gone → legs detach).
fn handle_text_frame(
    text: &str,
    room: &str,
    room_peers: &mut HashSet<String>,
    buckets: &mut PeerBuckets,
    engine_tx: &mpsc::UnboundedSender<EngineCmd>,
) {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(text) else {
        return;
    };
    let msg_type = v.get("type").and_then(|t| t.as_str()).unwrap_or("");
    let in_our_room = v.get("room").and_then(|r| r.as_str()).is_none_or(|r| r == room);
    if !in_our_room {
        return;
    }
    match msg_type {
        "members" => {
            let new_peers: HashSet<String> = v
                .get("peers")
                .and_then(|p| p.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|x| x.as_str().map(|s| s.to_string()))
                        .collect()
                })
                .unwrap_or_default();
            for gone in room_peers.difference(&new_peers) {
                let _ = engine_tx.send(EngineCmd::PeerGone(gone.clone()));
                buckets.forget(gone);
            }
            *room_peers = new_peers;
        }
        "peer_joined" => {
            if let Some(p) = v.get("peer_id").and_then(|p| p.as_str()) {
                room_peers.insert(p.to_string());
            }
        }
        "peer_left" => {
            if let Some(p) = v.get("peer_id").and_then(|p| p.as_str()) {
                room_peers.remove(p);
                let _ = engine_tx.send(EngineCmd::PeerGone(p.to_string()));
                buckets.forget(p);
            }
        }
        _ => {}
    }
}

/// Parse a relay direct frame body (after the 0x06 type byte):
/// `[room\0][sender\0][payload]` (fetch.rs parse shape).
fn parse_direct_frame(body: &[u8]) -> Option<(String, String)> {
    let room_end = body.iter().position(|&b| b == 0)?;
    let after_room = &body[room_end + 1..];
    let sender_end = after_room.iter().position(|&b| b == 0)?;
    let sender = String::from_utf8_lossy(&after_room[..sender_end]).to_string();
    let payload = String::from_utf8_lossy(&after_room[sender_end + 1..]).to_string();
    Some((sender, payload))
}

/// Inbound relay binary frame: only 0x06 (direct) matters — the whole fwd
/// control plane is Olm-direct.
#[allow(clippy::too_many_arguments)]
async fn handle_binary_frame(
    data: &[u8],
    local_peer_id: &str,
    keypair: &NativeKeypair,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    buckets: &mut PeerBuckets,
    rekey_cooldown: &mut HashMap<String, std::time::Instant>,
    write: &mut WsSink,
    room: &str,
    engine_tx: &mpsc::UnboundedSender<EngineCmd>,
) {
    if data.len() <= 3 || data[0] != 0x06 {
        return;
    }
    let Some((sender, payload)) = parse_direct_frame(&data[1..]) else {
        return;
    };
    // Control-frame DoS bound: the Olm path has no client-side limiter, so the
    // forwarder carries its own. Rate-limited frames are DROPPED (a reply
    // would defeat the limiter).
    if !buckets.allow(&sender, std::time::Instant::now()) {
        return;
    }
    let Ok(haven) = serde_json::from_str::<HavenMessage>(&payload) else {
        return;
    };

    match haven {
        HavenMessage::KeyRequest { to, ts, sig, pk } => {
            handle_key_request(
                &sender, to, ts, sig, pk, local_peer_id, keypair, olm, crypto_store,
                rekey_cooldown, write, room,
            )
            .await;
        }
        HavenMessage::Encrypted { message_type, body, identity_key } => {
            let Ok(ciphertext) = OlmManager::decode_base64(&body) else {
                return;
            };
            let Some(plaintext) = olm_decrypt(
                &sender, message_type, identity_key.as_deref(), &ciphertext, olm, crypto_store,
            ) else {
                return;
            };
            persist_olm_session(olm, crypto_store, &sender);
            let text = String::from_utf8_lossy(&plaintext);
            match serde_json::from_str::<MessageEnvelope>(&text) {
                Ok(env @ (MessageEnvelope::FwdStreamRegister { .. }
                | MessageEnvelope::FwdStreamAuth { .. }
                | MessageEnvelope::FwdStreamUnregister { .. }
                | MessageEnvelope::FwdIngestOffer { .. }
                | MessageEnvelope::FwdAttach { .. }
                | MessageEnvelope::FwdDetach { .. }
                | MessageEnvelope::FwdEgressAnswer { .. })) => {
                    let _ = engine_tx.send(EngineCmd::Signal { sender, envelope: env });
                }
                // SessionAck confirms the peer's ratchet; everything else a
                // client might broadcast at room peers (profiles, sync
                // requests) is silently irrelevant to a forwarder.
                Ok(_) | Err(_) => {}
            }
        }
        // The forwarder never sends KeyRequest, so KeyBundle should never
        // arrive; everything else (profiles, friend requests, ...) is not
        // for us.
        _ => {}
    }
}

/// The Olm key-exchange RESPONDER (mirrors swarm.rs's KeyRequest arm):
/// signature REQUIRED (`REQUIRE_SIGNED_KEY_EXCHANGE`), re-key storms bounded
/// by a 5 s cooldown, our bundle signed by the forwarder's own keypair
/// (master == device for a forwarder — one identity).
#[allow(clippy::too_many_arguments)]
async fn handle_key_request(
    sender: &str,
    to: Option<String>,
    ts: Option<i64>,
    sig: Option<String>,
    pk: Option<String>,
    local_peer_id: &str,
    keypair: &NativeKeypair,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    rekey_cooldown: &mut HashMap<String, std::time::Instant>,
    write: &mut WsSink,
    room: &str,
) {
    let payload = key_request_signing_payload(sender, local_peer_id, ts.unwrap_or(0));
    match verify_key_exchange(
        sender, local_peer_id, to.as_deref(), ts, sig.as_deref(), pk.as_deref(), &payload,
    ) {
        KeyExchangeAuth::Verified => {}
        KeyExchangeAuth::Unsigned => {
            if REQUIRE_SIGNED_KEY_EXCHANGE {
                hollow_log!("[HOLLOW-SECURITY] REJECTED unsigned KeyRequest at forwarder");
                return;
            }
        }
        KeyExchangeAuth::Invalid => {
            hollow_log!("[HOLLOW-SECURITY] REJECTED KeyRequest at forwarder — authentication FAILED");
            return;
        }
    }
    // NOTE: no `key_exchange_device_unauthorized` check here — the forwarder
    // holds no device-list state (resolver empty ⇒ every device is
    // first-contact), and authorization is enforced where it matters: the
    // per-stream allowlist at admission.

    let now = std::time::Instant::now();
    let cooldown_ok = rekey_cooldown
        .get(sender)
        .is_none_or(|last| now.duration_since(*last) >= Duration::from_secs(5));
    if olm.has_confirmed_session(sender) && !cooldown_ok {
        return;
    }
    if olm.has_session(sender) {
        // Peer lost their half — drop ours before re-bundling so the new
        // inbound session isn't shadowed by a dead one.
        olm.remove_session(sender);
        rekey_cooldown.insert(sender.to_string(), now);
    }
    let otk = olm.generate_one_time_key();
    let identity_key = olm.identity_key_base64();
    if let Ok(pickle) = olm.account_pickle_json() {
        crypto_store.save_account(pickle);
    }
    persist_crypto_state(olm, crypto_store, sender);
    let bundle = signed_key_bundle(keypair, local_peer_id, sender, identity_key, otk);
    send_haven_direct(write, room, sender, &bundle).await;
}

/// Olm decrypt for an inbound Encrypted body (fetch.rs `olm_decrypt_payload`
/// shape: prekey messages try the existing session, then recreate inbound).
fn olm_decrypt(
    from: &str,
    message_type: usize,
    identity_key: Option<&str>,
    ciphertext: &[u8],
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
) -> Option<Vec<u8>> {
    if message_type == 0 {
        let their_identity = identity_key?;
        if olm.has_session(from) {
            match olm.try_decrypt_prekey_with_existing(from, ciphertext) {
                Ok(pt) => Some(pt),
                Err(_) => {
                    olm.remove_session(from);
                    create_inbound(from, their_identity, ciphertext, olm, crypto_store)
                }
            }
        } else {
            create_inbound(from, their_identity, ciphertext, olm, crypto_store)
        }
    } else {
        match olm.decrypt(from, message_type, ciphertext) {
            Ok(pt) => Some(pt),
            Err(e) => {
                hollow_log!("[HOLLOW-FWD] Olm decrypt failed: {e}");
                None
            }
        }
    }
}

fn create_inbound(
    from: &str,
    their_identity: &str,
    ciphertext: &[u8],
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
) -> Option<Vec<u8>> {
    match olm.create_inbound_session(from, their_identity, ciphertext) {
        Ok(pt) => {
            persist_crypto_state(olm, crypto_store, from);
            Some(pt)
        }
        Err(e) => {
            hollow_log!("[HOLLOW-FWD] PreKey session creation failed: {e}");
            None
        }
    }
}

/// Olm-encrypt an engine reply and send it as a 0x04 direct frame
/// (`[0x04][room\0][target\0][HavenMessage JSON]` — the SendDirect layout).
async fn send_encrypted(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    write: &mut WsSink,
    room: &str,
    sig: OutSignal,
) {
    let env_json = match serde_json::to_string(&sig.envelope) {
        Ok(j) => j,
        Err(_) => return,
    };
    if !olm.has_session(&sig.to_peer) {
        // Can't happen for replies (every request arrived through a session);
        // if it does, the client's 20 s watch timeout walks the fallback
        // ladder.
        hollow_log!("[HOLLOW-FWD] no Olm session for reply target — dropped");
        return;
    }
    match olm.encrypt(&sig.to_peer, env_json.as_bytes()) {
        Ok((msg_type, ciphertext)) => {
            persist_olm_session(olm, crypto_store, &sig.to_peer);
            let haven = HavenMessage::Encrypted {
                message_type: msg_type,
                body: OlmManager::encode_base64(&ciphertext),
                identity_key: if msg_type == 0 {
                    Some(olm.identity_key_base64())
                } else {
                    None
                },
            };
            send_haven_direct(write, room, &sig.to_peer, &haven).await;
        }
        Err(e) => {
            hollow_log!("[HOLLOW-FWD] encrypt for reply failed: {e}");
        }
    }
}

/// Frame + send one HavenMessage as a relay 0x04 direct.
async fn send_haven_direct(write: &mut WsSink, room: &str, target: &str, msg: &HavenMessage) {
    let Ok(json) = serde_json::to_string(msg) else {
        return;
    };
    let room_b = room.as_bytes();
    let target_b = target.as_bytes();
    let payload = json.as_bytes();
    let mut frame = Vec::with_capacity(1 + room_b.len() + 1 + target_b.len() + 1 + payload.len());
    frame.push(0x04);
    frame.extend_from_slice(room_b);
    frame.push(0x00);
    frame.extend_from_slice(target_b);
    frame.push(0x00);
    frame.extend_from_slice(payload);
    if let Err(e) = bounded_send(write, Message::Binary(frame.into())).await {
        hollow_log!("[HOLLOW-FWD] direct send failed: {e}");
    }
}
