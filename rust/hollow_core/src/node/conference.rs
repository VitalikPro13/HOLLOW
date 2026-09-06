//! Conferences: Zoom-style ad-hoc rooms with an MLS-gated waiting room.
//! Design doc: `reports/CONFERENCES_PLAN.md`.
//!
//! A conference is a "virtual server": its id `conf:{conf_id}` is at once the
//! relay WS room code, the MLS group key and the `server_id` fed to the existing
//! voice-channel machinery (the channel is always [`CONF_CHANNEL`]).
//! `server_states` never contains a `conf:` id, so every CRDT-coupled path skips
//! naturally.
//!
//! **Admission IS the cryptography:** the waiting room gates an MLS `add`, so
//! until the host commits it a joiner sitting in the WS room holds only
//! ciphertext, and kick or deny never needs UI enforcement. Each `Start meeting`
//! mints a FRESH group, so past attendees cannot decrypt the next one. Live-only:
//! nothing rides topic rings or the offline buffer, and chat is never persisted.

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

use base64::Engine;
use sha2::{Digest, Sha256};
use tokio::sync::mpsc;

use crate::crypto::{CryptoStore, MlsManager};

use super::crypto_handler::{
    broadcast_mls_commit, persist_mls_state, send_message_to_peer_in_room,
};
use super::types::{HavenMessage, NetworkEvent};
use super::ws_client::WsCommand;

/// Virtual server-id / WS room-code / MLS group-key prefix.
pub(crate) const CONF_SID_PREFIX: &str = "conf:";

/// The single synthetic channel id conferences feed the VC machinery.
pub(crate) const CONF_CHANNEL: &str = "main";

pub(crate) fn conf_server_id(conf_id: &str) -> String {
    format!("{CONF_SID_PREFIX}{conf_id}")
}

pub(crate) fn is_conference_sid(sid: &str) -> bool {
    sid.starts_with(CONF_SID_PREFIX)
}

pub(crate) fn conf_id_from_sid(sid: &str) -> Option<&str> {
    sid.strip_prefix(CONF_SID_PREFIX)
}

/// Access-code wire form: sha256("{conf_id}:{code}") hex. The code itself never
/// travels, and the derivation is conf-scoped, so one room's hash is useless
/// against another. An ADMISSION check, not key material: control is the MLS add.
pub(crate) fn derive_access_hash(conf_id: &str, code: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(conf_id.as_bytes());
    hasher.update(b":");
    hasher.update(code.as_bytes());
    hex::encode(hasher.finalize())
}

/// A joiner parked in the waiting room (host side). Only the KeyPackage is
/// held — admission commits the MLS add without a second round-trip; the
/// name/avatar shown in the host panel live in Dart (from the request event).
pub(crate) struct ConfPendingJoin {
    pub key_package_b64: String,
}

/// (Joiner side) an outbound knock not yet admitted or denied. Kept so it can be
/// RE-SENT when the host appears: a joiner who opens the link before the meeting
/// starts broadcasts into an empty room and would otherwise wait forever.
struct PendingKnock {
    display_name: String,
    avatar_hash: String,
    /// Already-derived wire form (re-derivation would need the raw code).
    access_hash: String,
    last_sent: std::time::Instant,
}

/// Process-global like `blocklist` (the deep `handle_incoming_request` arms
/// that must CLEAR entries don't thread conference state). Harness caveat:
/// shared across in-process test nodes — tests use distinct conf ids.
static PENDING_KNOCKS: Mutex<Option<HashMap<String, PendingKnock>>> = Mutex::new(None);

fn note_pending_knock(conf_id: &str, display_name: String, avatar_hash: String, access_hash: String) {
    if let Ok(mut g) = PENDING_KNOCKS.lock() {
        g.get_or_insert_with(HashMap::new).insert(conf_id.to_string(), PendingKnock {
            display_name, avatar_hash, access_hash,
            last_sent: std::time::Instant::now(),
        });
    }
}

/// Clear a knock once it resolved (admitted / denied / left / meeting ended).
pub(crate) fn clear_pending_knock(conf_id: &str) {
    if let Ok(mut g) = PENDING_KNOCKS.lock() {
        if let Some(map) = g.as_mut() {
            map.remove(conf_id);
        }
    }
}

/// A peer appeared in a conf room we are still knocking on: re-broadcast the join
/// request with a FRESH KeyPackage, since the arrival may be the host starting the
/// meeting. Throttled, and the host side dedups by peer anyway.
pub(crate) fn reknock_if_pending(
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    room_code: &str,
) {
    let Some(conf_id) = conf_id_from_sid(room_code) else { return; };
    let (display_name, avatar_hash, access_hash) = {
        let Ok(mut g) = PENDING_KNOCKS.lock() else { return; };
        let Some(map) = g.as_mut() else { return; };
        let Some(knock) = map.get_mut(conf_id) else { return; };
        if knock.last_sent.elapsed() < std::time::Duration::from_secs(2) {
            return;
        }
        knock.last_sent = std::time::Instant::now();
        (knock.display_name.clone(), knock.avatar_hash.clone(), knock.access_hash.clone())
    };
    let Some(mls_mgr) = mls.as_mut() else { return; };
    let kp = match super::crypto_handler::mint_key_package(mls_mgr, crypto_store) {
        Ok(kp) => base64::engine::general_purpose::STANDARD.encode(kp),
        Err(e) => {
            hollow_log!("[HOLLOW-CONF] Re-knock KeyPackage generation failed for {conf_id}: {e}");
            return;
        }
    };
    let data = serde_json::to_vec(&HavenMessage::ConferenceJoinRequest {
        conf_id: conf_id.to_string(),
        display_name,
        avatar_hash,
        key_package: kp,
        access_hash,
    }).unwrap_or_default();
    let _ = ws_cmd_tx.send(WsCommand::SendToRoom { room_code: room_code.to_string(), data });
    hollow_log!("[HOLLOW-CONF] Re-knocked on conference {conf_id} (peer appeared in room)");
}

/// Host-side state for one ACTIVE meeting (exists only between Start/End).
pub(crate) struct ConferenceHostState {
    pub waiting_room: bool,
    pub access_code_hash: Option<String>,
    pub host_display_name: String,
    pub host_avatar_hash: String,
    pub pending: HashMap<String, ConfPendingJoin>,
}

// ── Host: start / end ────────────────────────────────────────────────

/// Start a meeting: mint a FRESH MLS group under the conf sid (dropping any
/// previous meeting's group — past attendees must be re-admitted) and join the
/// relay room. The caller (Dart) follows up with `voice_channel_join(sid, "main")`.
#[allow(clippy::too_many_arguments)]
pub(crate) fn handle_conference_start(
    conference_host: &mut HashMap<String, ConferenceHostState>,
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    voice_channel_participants: &mut HashMap<String, HashSet<String>>,
    voice_channel_gossip_mode: &mut HashMap<String, bool>,
    conf_id: String,
    waiting_room: bool,
    access_code_hash: Option<String>,
    host_display_name: String,
    host_avatar_hash: String,
) {
    clear_conf_voice_state(voice_channel_participants, voice_channel_gossip_mode, &conf_id);
    let sid = conf_server_id(&conf_id);
    let Some(mls_mgr) = mls.as_mut() else {
        hollow_log!("[HOLLOW-CONF] Cannot start {conf_id}: MLS not initialized");
        return;
    };
    if mls_mgr.has_group(&sid) {
        mls_mgr.remove_group(&sid);
    }
    if let Err(e) = mls_mgr.create_group(&sid) {
        hollow_log!("[HOLLOW-CONF] create_group failed for {conf_id}: {e}");
        return;
    }
    persist_mls_state(mls_mgr, crypto_store);
    let _ = ws_cmd_tx.send(WsCommand::JoinRoom { room_code: sid });
    conference_host.insert(conf_id.clone(), ConferenceHostState {
        waiting_room,
        access_code_hash,
        host_display_name,
        host_avatar_hash,
        pending: HashMap::new(),
    });
    hollow_log!("[HOLLOW-CONF] Meeting started for conference {conf_id} (waiting_room={waiting_room})");
}

/// End a meeting: tell the room, leave it, forget host state. The MLS group is
/// dropped so the next Start mints fresh keys.
pub(crate) fn handle_conference_end(
    conference_host: &mut HashMap<String, ConferenceHostState>,
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    voice_channel_participants: &mut HashMap<String, HashSet<String>>,
    voice_channel_gossip_mode: &mut HashMap<String, bool>,
    conf_id: &str,
) {
    clear_conf_voice_state(voice_channel_participants, voice_channel_gossip_mode, conf_id);
    let sid = conf_server_id(conf_id);
    if conference_host.remove(conf_id).is_none() {
        hollow_log!("[HOLLOW-CONF] End for {conf_id} we aren't hosting — ignoring");
        return;
    }
    let data = serde_json::to_vec(&HavenMessage::ConferenceEnded {
        conf_id: conf_id.to_string(),
    }).unwrap_or_default();
    let _ = ws_cmd_tx.send(WsCommand::SendToRoom { room_code: sid.clone(), data });
    let _ = ws_cmd_tx.send(WsCommand::LeaveRoom { room_code: sid.clone() });
    if let Some(mls_mgr) = mls.as_mut() {
        if mls_mgr.has_group(&sid) {
            mls_mgr.remove_group(&sid);
            persist_mls_state(mls_mgr, crypto_store);
        }
    }
    hollow_log!("[HOLLOW-CONF] Meeting ended for conference {conf_id}");
}

// ── Joiner: request / leave ──────────────────────────────────────────

/// Ask to join: enter the relay room and broadcast a join request carrying our
/// fresh KeyPackage (light-announce rule: avatar HASH only, never blob bytes).
pub(crate) fn handle_conference_request_join(
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    conf_id: String,
    display_name: String,
    avatar_hash: String,
    access_code: Option<String>,
) {
    let sid = conf_server_id(&conf_id);
    let Some(mls_mgr) = mls.as_mut() else {
        hollow_log!("[HOLLOW-CONF] Cannot request join {conf_id}: MLS not initialized");
        return;
    };
    let kp = match super::crypto_handler::mint_key_package(mls_mgr, crypto_store) {
        Ok(kp) => base64::engine::general_purpose::STANDARD.encode(kp),
        Err(e) => {
            hollow_log!("[HOLLOW-CONF] KeyPackage generation failed for {conf_id}: {e}");
            return;
        }
    };
    let access_hash = access_code
        .filter(|c| !c.is_empty())
        .map(|c| derive_access_hash(&conf_id, &c))
        .unwrap_or_default();
    // Remember the knock so PeerJoined/RoomMembers arms can RE-SEND it when
    // the host appears (knocking into an empty room otherwise waits forever).
    note_pending_knock(&conf_id, display_name.clone(), avatar_hash.clone(), access_hash.clone());
    let _ = ws_cmd_tx.send(WsCommand::JoinRoom { room_code: sid.clone() });
    let data = serde_json::to_vec(&HavenMessage::ConferenceJoinRequest {
        conf_id,
        display_name,
        avatar_hash,
        key_package: kp,
        access_hash,
    }).unwrap_or_default();
    let _ = ws_cmd_tx.send(WsCommand::SendToRoom { room_code: sid, data });
}

/// Leave a conference (joiner side, or a host tile closing without ending the
/// meeting is not supported in v1 — hosts end). Group state is left in place;
/// a re-admission's Welcome replaces it (the Welcome arm drops stale groups).
pub(crate) fn handle_conference_leave(
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    voice_channel_participants: &mut HashMap<String, HashSet<String>>,
    voice_channel_gossip_mode: &mut HashMap<String, bool>,
    conf_id: &str,
) {
    clear_pending_knock(conf_id);
    clear_conf_voice_state(voice_channel_participants, voice_channel_gossip_mode, conf_id);
    let _ = ws_cmd_tx.send(WsCommand::LeaveRoom { room_code: conf_server_id(conf_id) });
    hollow_log!("[HOLLOW-CONF] Left conference {conf_id}");
}

// ── Host: inbound join requests + admit/deny ─────────────────────────

/// Host-side gate for an inbound `ConferenceJoinRequest`. Order matters: blocklist
/// FIRST (the standard inbound stranger-surface rule), then the access code, then
/// waiting room versus auto-admit.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_inbound_join_request(
    conference_host: &mut HashMap<String, ConferenceHostState>,
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sender_peer: &str,
    local_peer_str: &str,
    conf_id: String,
    display_name: String,
    avatar_hash: String,
    key_package_b64: String,
    access_hash: String,
) {
    // Only the host of an ACTIVE meeting reacts; other members ignore.
    let Some(host_state) = conference_host.get_mut(&conf_id) else { return; };
    if sender_peer == local_peer_str { return; }

    if super::blocklist::is_blocked(sender_peer) {
        hollow_log!("[HOLLOW-CONF] Dropped join request from blocked peer for {conf_id}");
        return;
    }

    let sid = conf_server_id(&conf_id);

    if let Some(expected) = &host_state.access_code_hash {
        if &access_hash != expected {
            send_message_to_peer_in_room(ws_cmd_tx, &sid, sender_peer,
                HavenMessage::ConferenceJoinDenied {
                    conf_id, reason: "wrong_code".to_string(),
                });
            return;
        }
    }

    // Lobby banner: who they're waiting for. Sent even on auto-admit — the
    // joiner's UI shows it during the Welcome round-trip.
    send_message_to_peer_in_room(ws_cmd_tx, &sid, sender_peer,
        HavenMessage::ConferenceLobbyInfo {
            conf_id: conf_id.clone(),
            host_name: host_state.host_display_name.clone(),
            host_avatar_hash: host_state.host_avatar_hash.clone(),
        });

    if !host_state.waiting_room {
        admit_peer(mls, crypto_store, ws_cmd_tx, event_tx,
            &conf_id, sender_peer, &key_package_b64).await;
        return;
    }

    host_state.pending.insert(sender_peer.to_string(), ConfPendingJoin {
        key_package_b64,
    });
    let _ = event_tx.send(NetworkEvent::ConferenceJoinRequestReceived {
        conf_id, peer_id: sender_peer.to_string(), display_name, avatar_hash,
    }).await;
}

/// Host accepted a waiting joiner (or the waiting room is off): commit the MLS
/// add, Welcome the joiner directly, broadcast the commit to the room with the
/// Tier-1 epoch guard, and rotate our own SFrame key.
pub(crate) async fn admit_peer(
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    conf_id: &str,
    peer_id: &str,
    key_package_b64: &str,
) {
    let sid = conf_server_id(conf_id);
    let Some(mls_mgr) = mls.as_mut() else { return; };
    let kp_bytes = match base64::engine::general_purpose::STANDARD.decode(key_package_b64) {
        Ok(b) => b,
        Err(e) => {
            hollow_log!("[HOLLOW-CONF] KeyPackage b64 decode failed for {conf_id}: {e}");
            return;
        }
    };
    let (commit, welcome) = match mls_mgr.add_member(&sid, &kp_bytes) {
        Ok(cw) => cw,
        Err(e) => {
            hollow_log!("[HOLLOW-CONF] add_member failed for {conf_id}: {e}");
            return;
        }
    };
    if let Err(e) = mls_mgr.merge_pending_commit(&sid) {
        hollow_log!("[HOLLOW-CONF] merge_pending_commit failed for {conf_id}: {e}");
        return;
    }
    persist_mls_state(mls_mgr, crypto_store);

    let welcome_b64 = base64::engine::general_purpose::STANDARD.encode(welcome);
    send_message_to_peer_in_room(ws_cmd_tx, &sid, peer_id,
        HavenMessage::MlsWelcome {
            server_id: sid.clone(), welcome: welcome_b64, channel_id: None,
        });
    let epoch = mls_mgr.epoch(&sid).ok();
    broadcast_mls_commit(mls_mgr, ws_cmd_tx, &sid, None,
        base64::engine::general_purpose::STANDARD.encode(commit), epoch);

    // Our own cryptors rotate too — mirror the batch-flush emission.
    if let Ok(sframe_key) = mls_mgr.export_secret(&sid, "sframe", b"", 32) {
        let _ = event_tx.send(NetworkEvent::MlsEpochChanged {
            server_id: sid.clone(), epoch: epoch.unwrap_or(0), sframe_key,
            channel_id: None,
        }).await;
    }
    hollow_log!("[HOLLOW-CONF] Admitted {peer_id} to conference {conf_id}");
}

/// Host explicitly admits a waiting-room entry (FFI `conference_admit`).
pub(crate) async fn handle_conference_admit(
    conference_host: &mut HashMap<String, ConferenceHostState>,
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    conf_id: &str,
    peer_id: &str,
) {
    let Some(host_state) = conference_host.get_mut(conf_id) else { return; };
    let Some(pending) = host_state.pending.remove(peer_id) else {
        hollow_log!("[HOLLOW-CONF] Admit for {peer_id} with no pending request in {conf_id}");
        return;
    };
    admit_peer(mls, crypto_store, ws_cmd_tx, event_tx,
        conf_id, peer_id, &pending.key_package_b64).await;
}

/// Host declines a waiting-room entry (FFI `conference_deny`).
pub(crate) fn handle_conference_deny(
    conference_host: &mut HashMap<String, ConferenceHostState>,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    conf_id: &str,
    peer_id: &str,
    reason: String,
) {
    let Some(host_state) = conference_host.get_mut(conf_id) else { return; };
    if host_state.pending.remove(peer_id).is_none() { return; }
    send_message_to_peer_in_room(ws_cmd_tx, &conf_server_id(conf_id), peer_id,
        HavenMessage::ConferenceJoinDenied {
            conf_id: conf_id.to_string(), reason,
        });
    hollow_log!("[HOLLOW-CONF] Denied {peer_id} for conference {conf_id}");
}

/// (Host) kick a CURRENT member: MLS remove commit (cryptographic cutoff —
/// the next SFrame rotation locks them out of media too), room-broadcast the
/// commit, then the courtesy teardown signal so their UI leaves cleanly.
pub(crate) async fn handle_conference_kick(
    conference_host: &mut HashMap<String, ConferenceHostState>,
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    conf_id: &str,
    peer_id: &str,
) {
    if !conference_host.contains_key(conf_id) {
        hollow_log!("[HOLLOW-CONF] Kick for {conf_id} we aren't hosting — ignoring");
        return;
    }
    let sid = conf_server_id(conf_id);
    let Some(mls_mgr) = mls.as_mut() else { return; };
    let commit = match mls_mgr.remove_identity_leaves(&sid, &[peer_id]) {
        Ok(c) => c,
        Err(e) => {
            hollow_log!("[HOLLOW-CONF] Kick remove_identity_leaves failed for {conf_id}: {e}");
            return;
        }
    };
    if let Err(e) = mls_mgr.merge_pending_commit(&sid) {
        hollow_log!("[HOLLOW-CONF] Kick merge_pending_commit failed for {conf_id}: {e}");
        return;
    }
    persist_mls_state(mls_mgr, crypto_store);
    let epoch = mls_mgr.epoch(&sid).ok();
    broadcast_mls_commit(mls_mgr, ws_cmd_tx, &sid, None,
        base64::engine::general_purpose::STANDARD.encode(commit), epoch);
    send_message_to_peer_in_room(ws_cmd_tx, &sid, peer_id,
        HavenMessage::ConferenceKicked { conf_id: conf_id.to_string() });
    // Rotate our own cryptors to the post-remove epoch.
    if let Ok(sframe_key) = mls_mgr.export_secret(&sid, "sframe", b"", 32) {
        let _ = event_tx.send(NetworkEvent::MlsEpochChanged {
            server_id: sid.clone(), epoch: epoch.unwrap_or(0), sframe_key,
            channel_id: None,
        }).await;
    }
    hollow_log!("[HOLLOW-CONF] Kicked {peer_id} from conference {conf_id}");
}

// ── Chat (RAM-only, MLS application messages) ────────────────────────

/// Send a chat line: MLS-encrypt `{text, ts}` under the conf group and
/// broadcast. Never persisted anywhere, never rides topic rings.
pub(crate) fn handle_conference_send_chat(
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    conf_id: &str,
    text: String,
    timestamp: i64,
) {
    let sid = conf_server_id(conf_id);
    let Some(mls_mgr) = mls.as_mut() else { return; };
    let plaintext = serde_json::json!({ "text": text, "ts": timestamp }).to_string();
    let ciphertext = match mls_mgr.encrypt(&sid, plaintext.as_bytes()) {
        Ok(c) => c,
        Err(e) => {
            hollow_log!("[HOLLOW-CONF] Chat encrypt failed for {conf_id}: {e}");
            return;
        }
    };
    // MLS rule: persist on encrypt (send ratchet must never be debounced).
    persist_mls_state(mls_mgr, crypto_store);
    let data = serde_json::to_vec(&HavenMessage::ConferenceChat {
        conf_id: conf_id.to_string(),
        body: base64::engine::general_purpose::STANDARD.encode(ciphertext),
    }).unwrap_or_default();
    let _ = ws_cmd_tx.send(WsCommand::SendToRoom { room_code: sid, data });
}

/// Inbound chat line: decrypt under the conf group (decrypt success IS the
/// membership proof) and emit — no store, no unread machinery.
pub(crate) async fn handle_inbound_chat(
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sender_peer: &str,
    conf_id: String,
    body_b64: String,
) {
    let sid = conf_server_id(&conf_id);
    let Some(mls_mgr) = mls.as_mut() else { return; };
    if !mls_mgr.has_group(&sid) { return; }
    let ciphertext = match base64::engine::general_purpose::STANDARD.decode(&body_b64) {
        Ok(b) => b,
        Err(_) => return,
    };
    // decrypt returns (plaintext, MLS leaf credential). Attribute chat by the
    // CREDENTIAL: it is authenticated per message, so one room member cannot spoof
    // another's lines. It is a DEVICE id, and Dart collapses it for display.
    let (plaintext, credential) = match mls_mgr.decrypt(&sid, &ciphertext) {
        Ok(p) => p,
        Err(e) => {
            hollow_log!("[HOLLOW-CONF] Chat decrypt failed for {conf_id}: {e}");
            return;
        }
    };
    // Receive ratchet advanced — same persist rule as every MLS decrypt site.
    persist_mls_state(mls_mgr, crypto_store);
    let Ok(parsed) = serde_json::from_slice::<serde_json::Value>(&plaintext) else { return; };
    let text = parsed.get("text").and_then(|v| v.as_str()).unwrap_or_default().to_string();
    let timestamp = parsed.get("ts").and_then(|v| v.as_i64()).unwrap_or(0);
    if text.is_empty() { return; }
    let sender = if credential.is_empty() { sender_peer.to_string() } else { credential };
    let _ = event_tx.send(NetworkEvent::ConferenceChatMessage {
        conf_id, sender_peer_id: sender, text, timestamp,
    }).await;
}

// ── Voice-roster hygiene ─────────────────────────────────────────────

/// Drop every voice-participant entry belonging to a conference. Called on start,
/// end and leave: a previous meeting's members otherwise linger, because their
/// VoiceChannelLeave races the host's room-leave and a restart reuses the key.
pub(crate) fn clear_conf_voice_state(
    voice_channel_participants: &mut HashMap<String, HashSet<String>>,
    voice_channel_gossip_mode: &mut HashMap<String, bool>,
    conf_id: &str,
) {
    let prefix = format!("{}:", conf_server_id(conf_id));
    voice_channel_participants.retain(|k, _| !k.starts_with(&prefix));
    voice_channel_gossip_mode.retain(|k, _| !k.starts_with(&prefix));
}

/// A device vanished from a conference ROOM (PeerLeft, or missing from the
/// authoritative RoomMembers snapshot): being in the room is a prerequisite for
/// being in the call, so drop them from the voice roster and tell Dart. This is
/// what removes the tile LIVE when a VoiceChannelLeave never arrived.
pub(crate) async fn handle_conf_room_peer_gone(
    voice_channel_participants: &mut HashMap<String, HashSet<String>>,
    voice_channel_gossip_mode: &mut HashMap<String, bool>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    room_code: &str,
    peer_id: &str,
) {
    if !is_conference_sid(room_code) { return; }
    let vc_key = format!("{room_code}:{CONF_CHANNEL}");
    let mut removed = false;
    if let Some(p) = voice_channel_participants.get_mut(&vc_key) {
        removed = p.remove(peer_id);
        if p.is_empty() {
            voice_channel_participants.remove(&vc_key);
            voice_channel_gossip_mode.remove(&vc_key);
        }
    }
    if removed {
        let _ = event_tx.send(NetworkEvent::VoiceChannelLeft {
            server_id: room_code.to_string(),
            channel_id: CONF_CHANNEL.to_string(),
            peer_id: peer_id.to_string(),
            is_self: false,
        }).await;
    }
}

// ── Room-presence bookkeeping ────────────────────────────────────────

/// A device left the conf room (or vanished from RoomMembers): drop any
/// waiting-room entry so the host panel doesn't offer admitting a ghost.
pub(crate) fn handle_peer_left_room(
    conference_host: &mut HashMap<String, ConferenceHostState>,
    room_code: &str,
    peer_id: &str,
) {
    let Some(conf_id) = conf_id_from_sid(room_code) else { return; };
    if let Some(host_state) = conference_host.get_mut(conf_id) {
        host_state.pending.remove(peer_id);
    }
}

/// Sweep host pending lists against an authoritative RoomMembers snapshot.
pub(crate) fn retain_pending_in_room(
    conference_host: &mut HashMap<String, ConferenceHostState>,
    room_code: &str,
    members: &HashSet<String>,
) {
    let Some(conf_id) = conf_id_from_sid(room_code) else { return; };
    if let Some(host_state) = conference_host.get_mut(conf_id) {
        host_state.pending.retain(|peer, _| members.contains(peer));
    }
}
