//! The forwarder's relay control plane: one authenticated WS in the dedicated
//! `fwd:{peer_id}` room, an Olm KEY-EXCHANGE RESPONDER, and the fwd_* envelope
//! dispatch into the engine.
//!
//! Olm sessions live in RAM only, so the relay box's disk never lists who used the
//! forwarder (C-RP-07); only the account, whose identity key clients pin, is saved.
//! A client still writing on a session a restart forgot is asked to re-key, the one
//! time the forwarder initiates.
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
use std::time::{Duration, Instant};

use futures_util::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;

use crate::crypto::{CryptoStore, OlmManager};
use crate::hollow_log;
use crate::identity::native_identity::NativeKeypair;
use crate::node::crypto_handler::{
    encrypted_frame, key_bundle_signing_payload, key_request_signing_payload, signed_key_bundle,
    signed_key_request, verify_key_exchange, KeyExchangeAuth, REQUIRE_SIGNED_KEY_EXCHANGE,
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
/// A peer's session is torn down or re-asked for at most this often (re-key storms).
const REKEY_COOLDOWN: Duration = Duration::from_secs(5);
/// How long a peer's KeyBundle answers our request to re-key.
const ASK_WINDOW: Duration = Duration::from_secs(30);
/// The node's OLM_KEY_REQUEST_TIMEOUT: a KeyRequest crossing our PreKey this fresh is
/// answered on the same session, never with a second one.
const PREKEY_RESEND_WINDOW: Duration = Duration::from_secs(10);

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
    olm: OlmManager,
    account_store: CryptoStore,
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

    let mut control = Control::new(keypair, olm, account_store, engine_tx);
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
                    control.prune(Instant::now());
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
                    let outbox = control.reply(sig);
                    send_all(&mut write, &room, &control, outbox).await;
                }
                frame = read.next() => {
                    let Some(Ok(msg)) = frame else {
                        hollow_log!("[HOLLOW-FWD] relay read ended — reconnecting");
                        break 'session;
                    };
                    last_recv = tokio::time::Instant::now();
                    match msg {
                        Message::Text(text) => {
                            handle_text_frame(&text, &room, &mut room_peers, &control.engine_tx);
                        }
                        Message::Binary(data) => {
                            let outbox = control.on_binary(&data);
                            send_all(&mut write, &room, &control, outbox).await;
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

/// What one inbound frame or engine reply makes the forwarder send: (target, message).
pub(crate) type Outbox = Vec<(String, HavenMessage)>;

/// Why an inbound Olm body did not open.
#[derive(Debug, PartialEq, Eq)]
enum Unopened {
    /// A PreKey without its sender's proof of the identity key: no session was tried.
    Unproven,
    /// No session of ours reads it.
    Unread,
}

/// The control plane's state between frames.
pub(crate) struct Control {
    keypair: NativeKeypair,
    local: String,
    olm: OlmManager,
    account_store: CryptoStore,
    engine_tx: mpsc::UnboundedSender<EngineCmd>,
    sealing: Sealing,
    /// When each peer last made us drop its session.
    rekey_cooldown: HashMap<String, Instant>,
    /// Peers we asked to re-key, and when: only their bundle builds us a session.
    asked: HashMap<String, Instant>,
}

impl Control {
    pub(crate) fn new(
        keypair: NativeKeypair,
        mut olm: OlmManager,
        account_store: CryptoStore,
        engine_tx: mpsc::UnboundedSender<EngineCmd>,
    ) -> Self {
        crate::node::crypto_handler::bind_olm_identity(&mut olm, &keypair);
        Self {
            local: keypair.peer_id(),
            sealing: Sealing::new(keypair.clone()),
            keypair,
            olm,
            account_store,
            engine_tx,
            rekey_cooldown: HashMap::new(),
            asked: HashMap::new(),
        }
    }

    /// `msg` as it goes on the wire to `target`: sealed by us for this room and route.
    pub(crate) fn wire(&self, room: &str, target: &str, msg: &HavenMessage) -> Option<Vec<u8>> {
        let json = serde_json::to_vec(msg).ok()?;
        Some(self.sealing.payload_for(room, target, &json))
    }

    /// Whether our session with `peer` has read a message from it.
    #[cfg(test)]
    pub(crate) fn confirmed_with(&self, peer: &str) -> bool {
        self.olm.has_confirmed_session(peer)
    }

    fn prune(&mut self, now: Instant) {
        self.sealing.replays.prune(crate::node::frame_auth::now_ms());
        self.rekey_cooldown.retain(|_, at| now.duration_since(*at) < REKEY_COOLDOWN);
        self.asked.retain(|_, at| now.duration_since(*at) < ASK_WINDOW);
    }

    /// The account changed (a key minted or spent): save it, without who holds which key.
    fn keep_account(&self) {
        match self.olm.identity_pickle_json() {
            Ok(pickle) => self.account_store.save_account(pickle),
            Err(e) => hollow_log!("[HOLLOW-FWD] Olm account not saved: {e}"),
        }
    }

    /// Inbound relay binary frame: only 0x06 (direct) matters — the whole fwd
    /// control plane is Olm-direct.
    ///
    /// NO rate limiting here: the per-peer token bucket this once carried was the only
    /// spot in the fwd pipeline that ate a frame with ZERO trace, the silent-drop class
    /// the relay refuses (`feedback_relay_rules`). The DoS surface stays bounded
    /// without it: garbage fails the cheap HavenMessage/Olm parse, the expensive
    /// KeyRequest re-bundle and our own re-key request sit behind 5 s per-peer
    /// cooldowns, and admission caps refuse with explicit FwdError codes.
    fn on_binary(&mut self, data: &[u8]) -> Outbox {
        if data.len() <= 3 || data[0] != 0x06 {
            return Vec::new();
        }
        let Some((room, sender, frame)) = parse_direct_frame(&data[1..]) else {
            hollow_log!("[HOLLOW-FWD] inbound {} B: malformed direct frame — dropped", data.len());
            return Vec::new();
        };
        self.on_direct(&room, &sender, frame)
    }

    /// One relay direct from `sender` in `room`.
    pub(crate) fn on_direct(&mut self, room: &str, sender: &str, frame: &[u8]) -> Outbox {
        let frame_len = frame.len();
        let Some((haven, frame_ts_ms)) =
            self.sealing.admit(room, sender, &self.local, frame, crate::node::frame_auth::now_ms())
        else {
            return Vec::new();
        };
        match haven {
            HavenMessage::KeyRequest { to, ts, sig, pk } => {
                hollow_log!("[HOLLOW-FWD] inbound {frame_len} B: KeyRequest");
                self.answer_key_request(sender, to, ts, sig, pk)
            }
            HavenMessage::KeyBundle { identity_key, one_time_key, to, ts, sig, pk } => {
                hollow_log!("[HOLLOW-FWD] inbound {frame_len} B: KeyBundle");
                self.take_key_bundle(sender, &identity_key, &one_time_key, to, ts, sig, pk)
            }
            HavenMessage::Encrypted { message_type, body, identity_key, identity_sig, identity_pk } => {
                let Ok(ciphertext) = OlmManager::decode_base64(&body) else {
                    hollow_log!("[HOLLOW-FWD] inbound {frame_len} B: bad base64 body — dropped");
                    return Vec::new();
                };
                let opened = olm_decrypt(
                    sender, message_type, identity_key.as_deref(), identity_sig.as_deref(),
                    identity_pk.as_deref(), &ciphertext, &mut self.olm, &self.local,
                );
                match opened {
                    Ok((plaintext, spent_key)) => {
                        if spent_key {
                            self.keep_account();
                        }
                        self.dispatch(sender, &plaintext, frame_ts_ms, frame_len);
                        Vec::new()
                    }
                    // A restart forgot the session this sender still writes on.
                    Err(Unopened::Unread) if !self.olm.has_session(sender) => {
                        hollow_log!("[HOLLOW-FWD] inbound {frame_len} B: no session reads it — asking for a re-key");
                        self.ask_to_rekey(sender)
                    }
                    Err(_) => {
                        hollow_log!(
                            "[HOLLOW-FWD] inbound {frame_len} B: Olm decrypt failed (msg_type {message_type}) — dropped"
                        );
                        Vec::new()
                    }
                }
            }
            _ => {
                hollow_log!("[HOLLOW-FWD] inbound {frame_len} B: non-fwd HavenMessage — ignored");
                Vec::new()
            }
        }
    }

    /// A decrypted body: fwd envelopes go to the engine.
    fn dispatch(&self, sender: &str, plaintext: &[u8], frame_ts_ms: i64, frame_len: usize) {
        let Some(env) = open_envelope(plaintext, frame_ts_ms, crate::node::frame_auth::now_ms()) else {
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
                hollow_log!("[HOLLOW-FWD] inbound {frame_len} B: {} → engine", fwd_env_label(&env));
                let _ = self.engine_tx.send(EngineCmd::Signal { sender: sender.to_string(), envelope: env });
            }
            // SessionAck confirms the peer's ratchet; anything else a client broadcasts at
            // room peers is irrelevant to a forwarder.
            _ => {
                hollow_log!("[HOLLOW-FWD] inbound {frame_len} B: non-fwd envelope — ignored");
            }
        }
    }

    /// The Olm key-exchange RESPONDER: re-key storms bounded by a 5 s cooldown, our
    /// bundle signed by the forwarder's own keypair (master == device here).
    fn answer_key_request(
        &mut self,
        sender: &str,
        to: Option<String>,
        ts: Option<i64>,
        sig: Option<String>,
        pk: Option<String>,
    ) -> Outbox {
        let payload = key_request_signing_payload(sender, &self.local, ts.unwrap_or(0));
        let auth = verify_key_exchange(sender, &self.local, to.as_deref(), ts, sig.as_deref(), pk.as_deref(), &payload);
        if !key_exchange_accepted(auth, "KeyRequest") {
            return Vec::new();
        }
        // No `key_exchange_device_unauthorized` check: the forwarder holds no device-list
        // state, so every device is first-contact, and authorization is enforced where it
        // matters, at the per-stream allowlist.

        let now = Instant::now();
        let cooldown_ok = self
            .rekey_cooldown
            .get(sender)
            .is_none_or(|last| now.duration_since(*last) >= REKEY_COOLDOWN);
        if self.olm.has_confirmed_session(sender) && !cooldown_ok {
            return Vec::new();
        }
        if self.olm.claim_prekey_resend(sender, PREKEY_RESEND_WINDOW) {
            // It crossed the PreKey we built from its bundle: a second session would collide.
            return self.encrypt_for(sender, &MessageEnvelope::SessionAck);
        }
        if self.olm.has_session(sender) {
            // Peer lost their half: the session it builds from the new bundle is the one
            // used, and ours still reads what it already sent.
            self.olm.retire_session(sender);
            self.rekey_cooldown.insert(sender.to_string(), now);
        }
        // One key per requesting device, as the node hands out (A-DM-01).
        let (otk, minted) = self.olm.key_for_requester(sender);
        if minted {
            self.keep_account();
        }
        let identity_key = self.olm.identity_key_base64();
        vec![(sender.to_string(), signed_key_bundle(&self.keypair, &self.local, sender, identity_key, otk))]
    }

    /// Ask a sender we hold no session for to re-key, as a node asks a peer whose
    /// message it cannot read.
    fn ask_to_rekey(&mut self, sender: &str) -> Outbox {
        let now = Instant::now();
        if self.asked.get(sender).is_some_and(|at| now.duration_since(*at) < REKEY_COOLDOWN) {
            return Vec::new();
        }
        self.asked.insert(sender.to_string(), now);
        vec![(sender.to_string(), signed_key_request(&self.keypair, &self.local, sender))]
    }

    /// The bundle that answers our request to re-key: we build the session and send the
    /// first message on it, from which the sender builds its half.
    #[allow(clippy::too_many_arguments)]
    fn take_key_bundle(
        &mut self,
        sender: &str,
        identity_key: &str,
        one_time_key: &str,
        to: Option<String>,
        ts: Option<i64>,
        sig: Option<String>,
        pk: Option<String>,
    ) -> Outbox {
        if self.asked.get(sender).is_none_or(|at| at.elapsed() >= ASK_WINDOW) {
            hollow_log!("[HOLLOW-FWD] a KeyBundle we did not ask for — ignored");
            return Vec::new();
        }
        let payload = key_bundle_signing_payload(sender, &self.local, identity_key, one_time_key, ts.unwrap_or(0));
        let auth = verify_key_exchange(sender, &self.local, to.as_deref(), ts, sig.as_deref(), pk.as_deref(), &payload);
        if !key_exchange_accepted(auth, "KeyBundle") || self.olm.has_confirmed_session(sender) {
            return Vec::new();
        }
        if let Err(e) = self.olm.create_outbound_session(sender, identity_key, one_time_key) {
            hollow_log!("[HOLLOW-FWD] no session from a KeyBundle: {e}");
            return Vec::new();
        }
        self.asked.remove(sender);
        self.encrypt_for(sender, &MessageEnvelope::SessionAck)
    }

    /// An engine reply, Olm-encrypted to its target.
    pub(crate) fn reply(&mut self, sig: OutSignal) -> Outbox {
        if !self.olm.has_session(&sig.to_peer) {
            // Cannot happen for replies (every request arrived through a session); if it
            // does, the client's 20 s watch timeout walks the fallback ladder.
            hollow_log!("[HOLLOW-FWD] no Olm session for reply target — dropped");
            return Vec::new();
        }
        self.encrypt_for(&sig.to_peer, &sig.envelope)
    }

    fn encrypt_for(&mut self, to: &str, envelope: &MessageEnvelope) -> Outbox {
        let Ok(json) = serde_json::to_string(envelope) else {
            return Vec::new();
        };
        match self.olm.encrypt(to, json.as_bytes()) {
            Ok((msg_type, ciphertext)) => vec![(to.to_string(), encrypted_frame(&self.olm, msg_type, &ciphertext))],
            Err(e) => {
                hollow_log!("[HOLLOW-FWD] encrypt failed: {e}");
                Vec::new()
            }
        }
    }
}

/// Whether a key-exchange frame's authentication lets it act: a signature is REQUIRED
/// (`REQUIRE_SIGNED_KEY_EXCHANGE`).
fn key_exchange_accepted(auth: KeyExchangeAuth, what: &str) -> bool {
    match auth {
        KeyExchangeAuth::Verified => true,
        KeyExchangeAuth::Unsigned if !REQUIRE_SIGNED_KEY_EXCHANGE => true,
        KeyExchangeAuth::Unsigned => {
            hollow_log!("[HOLLOW-SECURITY] REJECTED unsigned {what} at forwarder");
            false
        }
        KeyExchangeAuth::Invalid => {
            hollow_log!("[HOLLOW-SECURITY] REJECTED {what} at forwarder — authentication FAILED");
            false
        }
    }
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
/// session first, then recreate inbound. The flag says a PreKey spent one of our keys.
#[allow(clippy::too_many_arguments)]
fn olm_decrypt(
    from: &str,
    message_type: usize,
    identity_key: Option<&str>,
    identity_sig: Option<&str>,
    identity_pk: Option<&str>,
    ciphertext: &[u8],
    olm: &mut OlmManager,
    local_peer_id: &str,
) -> Result<(Vec<u8>, bool), Unopened> {
    if message_type == 0 {
        let Some(their_identity) = identity_key else {
            return Err(Unopened::Unproven);
        };
        if !crate::node::crypto_handler::verify_olm_identity(from, their_identity, identity_sig, identity_pk) {
            hollow_log!("[HOLLOW-SECURITY] REJECTED PreKey from {from}: identity key not signed by that device");
            return Err(Unopened::Unproven);
        }
        match olm.open_prekey(from, their_identity, ciphertext, local_peer_id) {
            Ok(opened) => Ok((opened.plaintext, opened.created)),
            Err(e) => {
                hollow_log!("[HOLLOW-FWD] PreKey undecryptable: {e}");
                Err(Unopened::Unread)
            }
        }
    } else {
        match olm.decrypt(from, message_type, ciphertext) {
            Ok(opened) => Ok((opened.plaintext, false)),
            Err(e) => {
                hollow_log!("[HOLLOW-FWD] Olm decrypt failed: {e}");
                Err(Unopened::Unread)
            }
        }
    }
}

/// Send what one frame or reply produced, each as a relay 0x04 direct in our room.
async fn send_all(write: &mut WsSink, room: &str, control: &Control, outbox: Outbox) {
    for (target, msg) in outbox {
        if let Some(payload) = control.wire(room, &target, &msg) {
            send_direct(write, room, &target, &payload).await;
        }
    }
}

/// Frame + send one sealed payload as `[0x04][room\0][target\0][payload]`, the
/// SendDirect layout.
async fn send_direct(write: &mut WsSink, room: &str, target: &str, payload: &[u8]) {
    let room_b = room.as_bytes();
    let target_b = target.as_bytes();
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

    /// Media S-11: a PreKey whose identity key its sending device did not sign builds
    /// no session at the forwarder, which would otherwise answer an impostor.
    #[test]
    fn fwd_opens_a_prekey_only_with_its_senders_own_proof() {
        use base64::Engine;
        let _g = crate::node::resolver::test_lock();
        let (fwd, alice, carol) = (keypair(1), keypair(2), keypair(3));
        let (local, from) = (fwd.peer_id(), alice.peer_id());
        let mut fwd_olm = OlmManager::new();
        let otk = fwd_olm.generate_one_time_key();
        let mut alice_olm = OlmManager::new();
        alice_olm.create_outbound_session(&local, &fwd_olm.identity_key_base64(), &otk).unwrap();
        let (message_type, ciphertext) = alice_olm.encrypt(&local, b"{}").unwrap();
        assert_eq!(message_type, 0, "the first message is a PreKey");
        let key = alice_olm.identity_key_base64();
        let payload = crate::node::crypto_handler::olm_identity_signing_payload(&from, &key);
        let by = |k: &NativeKeypair| {
            let pk = base64::engine::general_purpose::STANDARD.encode(k.public_key_protobuf());
            crate::node::crypto_handler::sign_message(k, &pk, &payload)
        };
        let mut open_with = |(sig, pk): (Option<String>, Option<String>)| {
            olm_decrypt(&from, message_type, Some(&key), sig.as_deref(), pk.as_deref(), &ciphertext, &mut fwd_olm, &local)
        };
        for (proof, what) in [((None, None), "no proof"), (by(&carol), "another device's proof")] {
            assert_eq!(open_with(proof).err(), Some(Unopened::Unproven), "the forwarder opened a PreKey with {what}");
        }
        let opened = open_with(by(&alice)).expect("the sender's own proof opens it");
        assert_eq!((opened.0.as_slice(), opened.1), (&b"{}"[..], true), "and spends one of our keys");
    }

    /// A forwarder's control plane on its own database, and the engine's inbox.
    fn control(fwd: &NativeKeypair, path: &str, pass: &str) -> (Control, mpsc::UnboundedReceiver<EngineCmd>) {
        let olm = super::super::load_olm(path, pass).unwrap();
        let store = CryptoStore::open(path.to_string(), pass.to_string()).unwrap();
        let (engine_tx, engine_rx) = mpsc::unbounded_channel();
        (Control::new(fwd.clone(), olm, store, engine_tx), engine_rx)
    }

    /// `msg` as `from` puts it on the wire to `to` now.
    fn sealed(from: &NativeKeypair, to: &str, msg: &HavenMessage) -> Vec<u8> {
        crate::node::frame_auth::seal(from, ROOM, to, &serde_json::to_vec(msg).unwrap())
    }

    /// A client's Olm account, its identity key proven as a node proves it.
    fn client_olm(kp: &NativeKeypair) -> OlmManager {
        let mut olm = OlmManager::new();
        crate::node::crypto_handler::bind_olm_identity(&mut olm, kp);
        olm
    }

    fn attach() -> Vec<u8> {
        serde_json::to_vec(&MessageEnvelope::FwdAttach { origin: Box::default() }).unwrap()
    }

    /// An Olm message no session of ours reads.
    fn unreadable() -> HavenMessage {
        HavenMessage::Encrypted {
            message_type: 1,
            body: OlmManager::encode_base64(b"no session reads this"),
            identity_key: None,
            identity_sig: None,
            identity_pk: None,
        }
    }

    /// C-RP-07: a client that keys, talks and is answered, or is only handed a key,
    /// leaves no trace of its id in the forwarder's database, and a restart keeps the
    /// identity key clients pin.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)] // serializes the resolver's tests
    async fn fwd_keeps_no_client_device_id_on_disk() {
        let _g = crate::node::resolver::test_lock();
        let (fwd, alice) = (keypair(1), keypair(2));
        let (local, from) = (fwd.peer_id(), alice.peer_id());
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("fwd.db").to_string_lossy().into_owned();
        let pass = "ab".repeat(32);
        let (mut ctl, mut engine_rx) = control(&fwd, &path, &pass);
        let mut alice_olm = client_olm(&alice);
        let out = ctl.on_direct(ROOM, &from, &sealed(&alice, &local, &signed_key_request(&alice, &from, &local)));
        let [(to, HavenMessage::KeyBundle { identity_key, one_time_key, .. })] = &out[..] else {
            panic!("no bundle for the requester");
        };
        assert_eq!(to, &from);
        alice_olm.create_outbound_session(&local, identity_key, one_time_key).unwrap();
        let (mt, ct) = alice_olm.encrypt(&local, &attach()).unwrap();
        ctl.on_direct(ROOM, &from, &sealed(&alice, &local, &encrypted_frame(&alice_olm, mt, &ct)));
        assert!(matches!(engine_rx.try_recv(), Ok(EngineCmd::Signal { sender, .. }) if sender == from));
        assert_eq!(ctl.reply(OutSignal { to_peer: from.clone(), envelope: MessageEnvelope::SessionAck }).len(), 1);
        let bob = keypair(4);
        let bob_id = bob.peer_id();
        let asked = sealed(&bob, &local, &signed_key_request(&bob, &bob_id, &local));
        assert_eq!(ctl.on_direct(ROOM, &bob_id, &asked).len(), 1, "bob is handed a key");

        // The store applies commands in order: once this lands, everything before has.
        ctl.account_store.save_read_mark("sentinel".into(), 1);
        let store = crate::storage::MessageStore::open(&path, &pass).unwrap();
        for _ in 0..100 {
            if store.load_olm_read_marks().unwrap().iter().any(|(p, _)| p == "sentinel") {
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        let sessions = store.load_all_olm_sessions().unwrap();
        assert!(sessions.is_empty(), "the forwarder wrote a session for {:?}", sessions.iter().map(|s| &s.0).collect::<Vec<_>>());
        let account = store.load_olm_account().unwrap().unwrap_or_default();
        for id in [&from, &bob_id] {
            assert!(!account.contains(id.as_str()), "the forwarder's account row names {id}");
        }
        drop(store);

        let identity = ctl.olm.identity_key_base64();
        drop(ctl);
        tokio::time::sleep(Duration::from_millis(200)).await;
        let again = super::super::load_olm(&path, &pass).unwrap();
        assert_eq!(again.identity_key_base64(), identity, "a restart changed the identity key clients pin");
    }

    /// A message no session reads, from a sender we hold none for (a restart forgot it),
    /// gets one signed request to re-key per cooldown; from a sender we hold one for, none.
    #[tokio::test]
    async fn fwd_asks_a_sender_it_holds_no_session_for_to_rekey_once() {
        let _g = crate::node::resolver::test_lock();
        let (fwd, alice, bob) = (keypair(1), keypair(2), keypair(4));
        let (local, from) = (fwd.peer_id(), alice.peer_id());
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("fwd.db").to_string_lossy().into_owned();
        let (mut ctl, _engine_rx) = control(&fwd, &path, &"ab".repeat(32));

        let out = ctl.on_direct(ROOM, &from, &sealed(&alice, &local, &unreadable()));
        let [(target, HavenMessage::KeyRequest { to, ts, sig, pk })] = &out[..] else {
            panic!("no request to re-key: {}", out.len());
        };
        assert_eq!(target, &from);
        let payload = key_request_signing_payload(&local, &from, ts.unwrap_or(0));
        assert_eq!(
            verify_key_exchange(&local, &from, to.as_deref(), *ts, sig.as_deref(), pk.as_deref(), &payload),
            KeyExchangeAuth::Verified,
            "the request is the forwarder's own, addressed to the sender",
        );
        assert!(
            ctl.on_direct(ROOM, &from, &sealed(&alice, &local, &unreadable())).is_empty(),
            "asked again inside the cooldown"
        );

        let bob_id = bob.peer_id();
        let mut bob_olm = client_olm(&bob);
        let out = ctl.on_direct(ROOM, &bob_id, &sealed(&bob, &local, &signed_key_request(&bob, &bob_id, &local)));
        let [(_, HavenMessage::KeyBundle { identity_key, one_time_key, .. })] = &out[..] else { panic!("no bundle") };
        bob_olm.create_outbound_session(&local, identity_key, one_time_key).unwrap();
        let (mt, ct) = bob_olm.encrypt(&local, &attach()).unwrap();
        ctl.on_direct(ROOM, &bob_id, &sealed(&bob, &local, &encrypted_frame(&bob_olm, mt, &ct)));
        assert!(
            ctl.on_direct(ROOM, &bob_id, &sealed(&bob, &local, &unreadable())).is_empty(),
            "a sender we hold a session for was asked to re-key over one bad message"
        );
    }

    /// A bundle builds a session only when it answers our own request to re-key, and the
    /// message we send on it is the PreKey its sender builds its half from.
    #[tokio::test]
    async fn fwd_takes_a_key_bundle_only_when_it_asked() {
        let _g = crate::node::resolver::test_lock();
        let (fwd, alice) = (keypair(1), keypair(2));
        let (local, from) = (fwd.peer_id(), alice.peer_id());
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("fwd.db").to_string_lossy().into_owned();
        let (mut ctl, mut engine_rx) = control(&fwd, &path, &"ab".repeat(32));
        let mut alice_olm = client_olm(&alice);
        let (otk, _) = alice_olm.key_for_requester(&local);
        let bundle = |olm: &OlmManager| {
            sealed(&alice, &local, &signed_key_bundle(&alice, &from, &local, olm.identity_key_base64(), otk.clone()))
        };
        assert!(ctl.on_direct(ROOM, &from, &bundle(&alice_olm)).is_empty(), "an unasked bundle built a session");

        assert_eq!(ctl.on_direct(ROOM, &from, &sealed(&alice, &local, &unreadable())).len(), 1);
        let out = ctl.on_direct(ROOM, &from, &bundle(&alice_olm));
        let [(to, HavenMessage::Encrypted { message_type: 0, body, identity_key: Some(key), identity_sig, identity_pk })] =
            &out[..]
        else {
            panic!("the asked-for bundle was not answered with a PreKey");
        };
        assert_eq!(to, &from);
        assert!(crate::node::crypto_handler::verify_olm_identity(&local, key, identity_sig.as_deref(), identity_pk.as_deref()));
        let opened = alice_olm.open_prekey(&local, key, &OlmManager::decode_base64(body).unwrap(), &from).unwrap();
        assert!(matches!(serde_json::from_slice(&opened.plaintext), Ok(MessageEnvelope::SessionAck)));

        let (mt, ct) = alice_olm.encrypt(&local, &attach()).unwrap();
        assert_eq!(mt, 1, "the client writes on the session the PreKey built");
        ctl.on_direct(ROOM, &from, &sealed(&alice, &local, &encrypted_frame(&alice_olm, mt, &ct)));
        assert!(matches!(engine_rx.try_recv(), Ok(EngineCmd::Signal { sender, .. }) if sender == from));
    }

    /// The client's own KeyRequest crossing the PreKey we built from its bundle is
    /// answered on that same session, never with a bundle for a second one.
    #[tokio::test]
    async fn fwd_answers_a_request_crossing_its_prekey_on_the_same_session() {
        let _g = crate::node::resolver::test_lock();
        let (fwd, alice) = (keypair(1), keypair(2));
        let (local, from) = (fwd.peer_id(), alice.peer_id());
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("fwd.db").to_string_lossy().into_owned();
        let (mut ctl, _engine_rx) = control(&fwd, &path, &"ab".repeat(32));
        let mut alice_olm = client_olm(&alice);
        let (otk, _) = alice_olm.key_for_requester(&local);
        ctl.on_direct(ROOM, &from, &sealed(&alice, &local, &unreadable()));
        let bundle = signed_key_bundle(&alice, &from, &local, alice_olm.identity_key_base64(), otk);
        assert_eq!(ctl.on_direct(ROOM, &from, &sealed(&alice, &local, &bundle)).len(), 1);
        let first = ctl.olm.session_id(&from);
        let out = ctl.on_direct(ROOM, &from, &sealed(&alice, &local, &signed_key_request(&alice, &from, &local)));
        assert!(
            matches!(&out[..], [(_, HavenMessage::Encrypted { message_type: 0, .. })]),
            "a crossing request was answered with a new bundle"
        );
        assert_eq!(ctl.olm.session_id(&from), first, "the crossing request replaced the session");
    }
}
