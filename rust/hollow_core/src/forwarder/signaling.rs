//! The forwarder's relay control plane: one authenticated WS in the dedicated
//! `fwd:{peer_id}` room, an Olm KEY-EXCHANGE RESPONDER (the forwarder never
//! initiates), and the fwd_* envelope dispatch into the engine.
//!
//! Deliberately NOT `spawn_node` / `spawn_ws_client`: no CRDT, MLS, sync, gossip or
//! room-state machinery. The manual loop keeps the keepalive and liveness
//! discipline of `ws_client.rs` (30 s ping, 70 s liveness, bounded writes, backoff
//! reconnect and room rejoin), and media legs ride their own UDP sockets, so they
//! survive signaling blips untouched.
//!
//! Zero metadata logging: no per-peer request logs, and a security refusal logs the
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
use crate::node::frame_auth::ReplayGuard;
use crate::node::types::{HavenMessage, MessageEnvelope};
use crate::node::ws_client;

use super::engine::{EngineCmd, OutSignal};
use super::ForwarderConfig;

/// Mirrors ws_client.rs WRITE_TIMEOUT / LIVENESS_TIMEOUT: a wedged sink must never
/// freeze the loop.
const WRITE_TIMEOUT: Duration = Duration::from_secs(30);
const LIVENESS_TIMEOUT: Duration = Duration::from_secs(70);

type WsSink = futures_util::stream::SplitSink<ws_client::WsStream, Message>;

async fn bounded_send(write: &mut WsSink, msg: Message) -> Result<(), String> {
    match tokio::time::timeout(WRITE_TIMEOUT, write.send(msg)).await {
        Ok(Ok(())) => Ok(()),
        Ok(Err(e)) => Err(e.to_string()),
        Err(_) => Err("write timed out: connection wedged".into()),
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
    crate::node::crypto_handler::bind_olm_identity(&mut olm, &keypair);
    let proto = keypair.to_protobuf_encoding()?;
    let pub_b64 = {
        use base64::Engine;
        base64::engine::general_purpose::STANDARD.encode(keypair.public_key_protobuf())
    };
    let url = format!("wss://{}/ws", cfg.relay_domain);
    let room = format!("fwd:{peer_id}");

    // Peers we hold a session-teardown cooldown for (KeyRequest re-key storms).
    let mut rekey_cooldown: HashMap<String, std::time::Instant> = HashMap::new();
    let mut sealing = Sealing::new(keypair.clone());
    let mut backoff: u64 = 1;

    loop {
        let ws = match ws_client::connect_and_auth(
            &url, &peer_id, &proto, &pub_b64, cfg.license_key.as_deref(), /*fetch=*/ false,
        )
        .await
        {
            Ok(ws) => ws,
            Err(e) => {
                if let ws_client::ConnectError::License(_) = e {
                    // License refusals never heal by retrying.
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
        if bounded_send(&mut write, Message::Text(join.clone().into())).await.is_err() {
            continue;
        }

        let mut ping = tokio::time::interval(Duration::from_secs(30));
        ping.tick().await; // consume the immediate first tick
        let mut last_recv = tokio::time::Instant::now();
        let mut room_peers: HashSet<String> = HashSet::new();

        'session: loop {
            tokio::select! {
                _ = ping.tick() => {
                    // Zombie check FIRST (the ws_client discipline).
                    if last_recv.elapsed() > LIVENESS_TIMEOUT {
                        hollow_log!("[HOLLOW-FWD] no relay traffic for {}s — reconnecting", last_recv.elapsed().as_secs());
                        break 'session;
                    }
                    sealing.replays.prune(crate::node::frame_auth::now_ms());
                    if bounded_send(&mut write, Message::Ping(vec![0x01].into())).await.is_err() {
                        break 'session;
                    }
                    // Membership belt: relay-side room-membership loss silently diverts directs
                    // into the offline buffer until our next join. Re-joining is idempotent at
                    // the relay AND replays what was buffered while membership was broken.
                    if bounded_send(&mut write, Message::Text(join.clone().into())).await.is_err() {
                        break 'session;
                    }
                }
                out = out_rx.recv() => {
                    let Some(sig) = out else { return Ok(()) }; // engine gone
                    send_encrypted(&mut olm, &crypto_store, &mut write, &room, &sealing, sig).await;
                }
                frame = read.next() => {
                    let Some(Ok(msg)) = frame else {
                        hollow_log!("[HOLLOW-FWD] relay read ended — reconnecting");
                        break 'session;
                    };
                    last_recv = tokio::time::Instant::now();
                    match msg {
                        Message::Text(text) => {
                            handle_text_frame(&text, &room, &mut room_peers, &engine_tx);
                        }
                        Message::Binary(data) => {
                            handle_binary_frame(
                                &data, &peer_id, &keypair, &mut olm, &crypto_store,
                                &mut rekey_cooldown, &mut write, &room, &engine_tx, &mut sealing,
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

/// Room presence tracking. A vanished peer drives engine cleanup: owner gone
/// unregisters streams, viewer gone detaches legs.
fn handle_text_frame(
    text: &str,
    room: &str,
    room_peers: &mut HashSet<String>,
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
            }
        }
        _ => {}
    }
}

/// Parse a relay direct frame body (after the 0x06 type byte):
/// `[room\0][sender\0][payload]` into `(room, sender, payload)`.
fn parse_direct_frame(body: &[u8]) -> Option<(String, String, &[u8])> {
    let room_end = body.iter().position(|&b| b == 0)?;
    let room = String::from_utf8_lossy(&body[..room_end]).to_string();
    let after_room = &body[room_end + 1..];
    let sender_end = after_room.iter().position(|&b| b == 0)?;
    let sender = String::from_utf8_lossy(&after_room[..sender_end]).to_string();
    Some((room, sender, &after_room[sender_end + 1..]))
}

/// The forwarder's side of `node::frame_auth`, as the main node judges frames: only
/// sealed frames come in, never our own, a live-only message only while fresh and
/// once, and every frame goes out sealed. Pre-0.12 clients are refused (HOL-SEC-053).
struct Sealing {
    keypair: NativeKeypair,
    replays: ReplayGuard,
}

impl Sealing {
    fn new(keypair: NativeKeypair) -> Self {
        Self { keypair, replays: ReplayGuard::default() }
    }

    /// The message in a direct frame and its seal time, if the frame is admitted.
    fn admit(&mut self, room: &str, sender: &str, local: &str, frame: &[u8], now_ms: i64) -> Option<(HavenMessage, i64)> {
        use crate::node::frame_auth::{is_stale, open, Delivery};
        if sender == local {
            hollow_log!("[HOLLOW-SECURITY] Dropped a frame stamped with the forwarder's own id");
            return None;
        }
        let opened = match open(frame, sender, room, Delivery::Direct { device: local, master: local }, now_ms) {
            Ok(opened) => opened,
            Err(refusal) => {
                hollow_log!("[HOLLOW-FWD] inbound frame refused: {refusal:?}");
                return None;
            }
        };
        let Ok(msg) = serde_json::from_slice::<HavenMessage>(opened.body) else {
            hollow_log!("[HOLLOW-FWD] inbound {} B: unparseable HavenMessage — dropped", frame.len());
            return None;
        };
        if msg.live_only()
            && (is_stale(opened.ts_ms, now_ms)
                || !self.replays.first_sight(sender, opened.nonce, opened.ts_ms, now_ms))
        {
            hollow_log!("[HOLLOW-SECURITY] Dropped a stale or repeated live frame at the forwarder");
            return None;
        }
        Some((msg, opened.ts_ms))
    }

    fn payload_for(&self, room: &str, target: &str, body: &[u8]) -> Vec<u8> {
        crate::node::frame_auth::seal(&self.keypair, room, target, body)
    }
}

/// The engine-bound fwd envelope's wire tag, for the inbound observability line
/// (envelope types and sizes only, never identities).
fn fwd_env_label(env: &MessageEnvelope) -> &'static str {
    match env {
        MessageEnvelope::FwdStreamRegister { .. } => "fwd_stream_register",
        MessageEnvelope::FwdStreamAuth { .. } => "fwd_stream_auth",
        MessageEnvelope::FwdStreamUnregister { .. } => "fwd_stream_unregister",
        MessageEnvelope::FwdIngestOffer { .. } => "fwd_ingest_offer",
        MessageEnvelope::FwdAttach { .. } => "fwd_attach",
        MessageEnvelope::FwdDetach { .. } => "fwd_detach",
        MessageEnvelope::FwdEgressAnswer { .. } => "fwd_egress_answer",
        _ => "other",
    }
}

/// Inbound relay binary frame: only 0x06 (direct) matters — the whole fwd
/// control plane is Olm-direct.
///
/// NO rate limiting here: the per-peer token bucket this once carried was the only
/// spot in the fwd pipeline that ate a frame with ZERO trace, the silent-drop class
/// the relay refuses (`feedback_relay_rules`). The DoS surface stays bounded
/// without it: garbage fails the cheap HavenMessage/Olm parse, the expensive
/// KeyRequest re-bundle is behind a 5 s per-peer cooldown, and admission caps refuse
/// with explicit FwdError codes.
#[allow(clippy::too_many_arguments)]
async fn handle_binary_frame(
    data: &[u8],
    local_peer_id: &str,
    keypair: &NativeKeypair,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    rekey_cooldown: &mut HashMap<String, std::time::Instant>,
    write: &mut WsSink,
    room: &str,
    engine_tx: &mpsc::UnboundedSender<EngineCmd>,
    sealing: &mut Sealing,
) {
    if data.len() <= 3 || data[0] != 0x06 {
        return;
    }
    let frame_len = data.len();
    let Some((frame_room, sender, frame)) = parse_direct_frame(&data[1..]) else {
        hollow_log!("[HOLLOW-FWD] inbound {frame_len} B: malformed direct frame — dropped");
        return;
    };
    let Some((haven, frame_ts_ms)) =
        sealing.admit(&frame_room, &sender, local_peer_id, frame, crate::node::frame_auth::now_ms())
    else {
        return;
    };

    match haven {
        HavenMessage::KeyRequest { to, ts, sig, pk } => {
            hollow_log!("[HOLLOW-FWD] inbound {frame_len} B: KeyRequest");
            handle_key_request(
                &sender, to, ts, sig, pk, local_peer_id, keypair, olm, crypto_store,
                rekey_cooldown, write, room, sealing,
            )
            .await;
        }
        HavenMessage::Encrypted { message_type, body, identity_key, identity_sig, identity_pk } => {
            let Ok(ciphertext) = OlmManager::decode_base64(&body) else {
                hollow_log!("[HOLLOW-FWD] inbound {frame_len} B: bad base64 body — dropped");
                return;
            };
            let Some(plaintext) = olm_decrypt(
                &sender, message_type, identity_key.as_deref(),
                identity_sig.as_deref(), identity_pk.as_deref(),
                &ciphertext, olm, crypto_store, local_peer_id,
            ) else {
                hollow_log!(
                    "[HOLLOW-FWD] inbound {frame_len} B: Olm decrypt failed (msg_type {message_type}) — dropped"
                );
                return;
            };
            persist_olm_session(olm, crypto_store, &sender);
            let Some(env) = open_envelope(&plaintext, frame_ts_ms, crate::node::frame_auth::now_ms()) else {
                return;
            };
            match env {
                env @ (MessageEnvelope::FwdStreamRegister { .. }
                | MessageEnvelope::FwdStreamAuth { .. }
                | MessageEnvelope::FwdStreamUnregister { .. }
                | MessageEnvelope::FwdIngestOffer { .. }
                | MessageEnvelope::FwdAttach { .. }
                | MessageEnvelope::FwdDetach { .. }
                | MessageEnvelope::FwdEgressAnswer { .. }) => {
                    hollow_log!(
                        "[HOLLOW-FWD] inbound {frame_len} B: {} → engine",
                        fwd_env_label(&env)
                    );
                    let _ = engine_tx.send(EngineCmd::Signal { sender, envelope: env });
                }
                // SessionAck confirms the peer's ratchet; anything else a client broadcasts at
                // room peers is irrelevant to a forwarder.
                _ => {
                    hollow_log!("[HOLLOW-FWD] inbound {frame_len} B: non-fwd envelope — ignored");
                }
            }
        }
        // The forwarder never sends KeyRequest, so a KeyBundle should never arrive.
        _ => {
            hollow_log!("[HOLLOW-FWD] inbound {frame_len} B: non-fwd HavenMessage — ignored");
        }
    }
}

/// The Olm key-exchange RESPONDER: signature REQUIRED
/// (`REQUIRE_SIGNED_KEY_EXCHANGE`), re-key storms bounded by a 5 s cooldown, our
/// bundle signed by the forwarder's own keypair (master == device here).
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
    sealing: &Sealing,
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
    // No `key_exchange_device_unauthorized` check: the forwarder holds no device-list
    // state, so every device is first-contact, and authorization is enforced where it
    // matters, at the per-stream allowlist.

    let now = std::time::Instant::now();
    let cooldown_ok = rekey_cooldown
        .get(sender)
        .is_none_or(|last| now.duration_since(*last) >= Duration::from_secs(5));
    if olm.has_confirmed_session(sender) && !cooldown_ok {
        return;
    }
    if olm.has_session(sender) {
        // Peer lost their half: the session it builds from the new bundle is the one
        // used, and ours still reads what it already sent.
        olm.retire_session(sender);
        rekey_cooldown.insert(sender.to_string(), now);
    }
    // One key per requesting device, as the node hands out (A-DM-01).
    let (otk, minted) = olm.key_for_requester(sender);
    let identity_key = olm.identity_key_base64();
    if minted {
        persist_crypto_state(olm, crypto_store, sender);
    }
    let bundle = signed_key_bundle(keypair, local_peer_id, sender, identity_key, otk);
    send_haven_direct(write, room, sender, &bundle, sealing).await;
}

/// The envelope in a decrypted body, unless it is live-only and its frame is stale:
/// a ratchet stops a replay, never a relay that holds a frame back.
fn open_envelope(plaintext: &[u8], frame_ts_ms: i64, now_ms: i64) -> Option<MessageEnvelope> {
    let Ok(env) = serde_json::from_slice::<MessageEnvelope>(plaintext) else {
        hollow_log!("[HOLLOW-FWD] undecodable envelope — ignored");
        return None;
    };
    if env.live_only() && crate::node::frame_auth::is_stale(frame_ts_ms, now_ms) {
        hollow_log!("[HOLLOW-SECURITY] Dropped a live signal at the forwarder that arrived too late");
        return None;
    }
    Some(env)
}

/// Olm decrypt for an inbound Encrypted body: prekey messages try the existing
/// session first, then recreate inbound.
#[allow(clippy::too_many_arguments)]
fn olm_decrypt(
    from: &str,
    message_type: usize,
    identity_key: Option<&str>,
    identity_sig: Option<&str>,
    identity_pk: Option<&str>,
    ciphertext: &[u8],
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    local_peer_id: &str,
) -> Option<Vec<u8>> {
    if message_type == 0 {
        let their_identity = identity_key?;
        if !crate::node::crypto_handler::verify_olm_identity(from, their_identity, identity_sig, identity_pk) {
            hollow_log!("[HOLLOW-SECURITY] REJECTED PreKey from {from}: identity key not signed by that device");
            return None;
        }
        match olm.open_prekey(from, their_identity, ciphertext, local_peer_id) {
            Ok(opened) => {
                if opened.created || opened.switched {
                    persist_crypto_state(olm, crypto_store, from);
                }
                Some(opened.plaintext)
            }
            Err(e) => {
                hollow_log!("[HOLLOW-FWD] PreKey undecryptable: {e}");
                None
            }
        }
    } else {
        match olm.decrypt(from, message_type, ciphertext) {
            Ok(opened) => Some(opened.plaintext),
            Err(e) => {
                hollow_log!("[HOLLOW-FWD] Olm decrypt failed: {e}");
                None
            }
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
    sealing: &Sealing,
    sig: OutSignal,
) {
    let env_json = match serde_json::to_string(&sig.envelope) {
        Ok(j) => j,
        Err(_) => return,
    };
    if !olm.has_session(&sig.to_peer) {
        // Cannot happen for replies (every request arrived through a session); if it
        // does, the client's 20 s watch timeout walks the fallback ladder.
        hollow_log!("[HOLLOW-FWD] no Olm session for reply target — dropped");
        return;
    }
    match olm.encrypt(&sig.to_peer, env_json.as_bytes()) {
        Ok((msg_type, ciphertext)) => {
            persist_olm_session(olm, crypto_store, &sig.to_peer);
            let haven = crate::node::crypto_handler::encrypted_frame(olm, msg_type, &ciphertext);
            send_haven_direct(write, room, &sig.to_peer, &haven, sealing).await;
        }
        Err(e) => {
            hollow_log!("[HOLLOW-FWD] encrypt for reply failed: {e}");
        }
    }
}

/// Frame + send one HavenMessage as a relay 0x04 direct.
async fn send_haven_direct(write: &mut WsSink, room: &str, target: &str, msg: &HavenMessage, sealing: &Sealing) {
    let Ok(json) = serde_json::to_string(msg) else {
        return;
    };
    let room_b = room.as_bytes();
    let target_b = target.as_bytes();
    let payload = sealing.payload_for(room, target, json.as_bytes());
    let payload = payload.as_slice();
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

// -- A-MED-09: the standalone forwarder holds frames to HOL-SEC-053/054 --
#[cfg(test)]
mod tests {
    use super::*;
    use crate::node::frame_auth::{open, seal_at, Delivery, LIVE_SKEW_MS, NONCE_LEN};

    const ROOM: &str = "fwd:forwarder";
    const NOW: i64 = 1_790_000_000_000;

    fn keypair(tag: u8) -> NativeKeypair {
        NativeKeypair::from_secret_bytes(&[tag; 32])
    }

    fn key_request(to: &str) -> Vec<u8> {
        serde_json::to_vec(&HavenMessage::KeyRequest {
            to: Some(to.to_string()),
            ts: Some(NOW / 1000),
            sig: Some("sig".to_string()),
            pk: Some("pk".to_string()),
        })
        .unwrap()
    }

    #[test]
    fn fwd_refuses_an_unsealed_frame_from_a_first_contact() {
        let (fwd, alice) = (keypair(1), keypair(2));
        let (local, from) = (fwd.peer_id(), alice.peer_id());
        let mut sealing = Sealing::new(fwd);
        assert!(
            sealing.admit(ROOM, &from, &local, &key_request(&local), NOW).is_none(),
            "an unsealed frame was admitted from a sender the forwarder never saw seal"
        );
        let sealed = seal_at(&alice, ROOM, &local, NOW, [1; NONCE_LEN], &key_request(&local));
        assert!(sealing.admit(ROOM, &from, &local, &sealed, NOW).is_some());
    }

    #[test]
    fn fwd_refuses_its_own_frames_echoed_back() {
        let fwd = keypair(1);
        let local = fwd.peer_id();
        let echoed = seal_at(&fwd, ROOM, &local, NOW, [1; NONCE_LEN], &key_request(&local));
        let mut sealing = Sealing::new(fwd);
        assert!(sealing.admit(ROOM, &local, &local, &echoed, NOW).is_none(), "the forwarder took its own frame");
    }

    #[test]
    fn fwd_takes_a_key_request_once_and_only_while_fresh() {
        let (fwd, alice) = (keypair(1), keypair(2));
        let (local, from) = (fwd.peer_id(), alice.peer_id());
        let mut sealing = Sealing::new(fwd);
        let frame = seal_at(&alice, ROOM, &local, NOW, [1; NONCE_LEN], &key_request(&local));
        assert!(sealing.admit(ROOM, &from, &local, &frame, NOW).is_some());
        assert!(
            sealing.admit(ROOM, &from, &local, &frame, NOW + 1_000).is_none(),
            "a replayed KeyRequest was taken a second time"
        );
        let late = seal_at(&alice, ROOM, &local, NOW - LIVE_SKEW_MS - 1_000, [2; NONCE_LEN], &key_request(&local));
        assert!(sealing.admit(ROOM, &from, &local, &late, NOW).is_none(), "a KeyRequest sealed 301 s ago was taken");
    }

    #[test]
    fn fwd_acts_on_a_stream_signal_only_while_its_frame_is_fresh() {
        let detach = serde_json::to_vec(&MessageEnvelope::FwdDetach { origin: Box::default() }).unwrap();
        assert!(open_envelope(&detach, NOW, NOW).is_some());
        assert!(
            open_envelope(&detach, NOW - LIVE_SKEW_MS - 1_000, NOW).is_none(),
            "a stream signal in a frame sealed 301 s ago reached the engine"
        );
    }

    #[test]
    fn fwd_answers_every_peer_sealed() {
        let (fwd, alice) = (keypair(1), keypair(2));
        let (local, to) = (fwd.peer_id(), alice.peer_id());
        let sealing = Sealing::new(fwd);
        let out = sealing.payload_for(ROOM, &to, b"{}");
        let opened = open(&out, &local, ROOM, Delivery::Direct { device: &to, master: &to }, crate::node::frame_auth::now_ms())
            .expect("a reply to a peer never seen sealed left unsealed");
        assert_eq!(opened.body, b"{}");
    }
}
