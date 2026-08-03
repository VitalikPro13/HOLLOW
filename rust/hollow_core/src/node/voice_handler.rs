use std::collections::HashMap;

use base64::Engine;
use tokio::sync::mpsc;

use crate::crdt::server_state::ServerState;
use crate::crypto::{MlsManager, OlmManager, CryptoStore};
use crate::identity::native_identity::NativeKeypair;
use super::crypto_handler::{
    peer_is_reachable, send_mls_broadcast,
    send_encrypted_message, send_message_to_peer, send_raw_to_peer, send_raw_to_identity,
};
use super::types::*;

// ── WebRtcPeerConnected ──────────────────────────────────────────────

pub(crate) fn handle_webrtc_peer_connected(
    peer_id: String,
    webrtc_peers: &mut std::collections::HashSet<String>,
    gossip_overlays: &mut HashMap<String, super::gossip::GossipOverlay>,
) {
    hollow_log!("[HOLLOW-WEBRTC] Data channel ready for {peer_id}");
    webrtc_peers.insert(peer_id.clone());
    // Update gossip peer scores: mark connected.
    for overlay in gossip_overlays.values_mut() {
        if let Some(score) = overlay.peer_scores.get_mut(&peer_id) {
            score.mark_connected();
        }
    }
}

// ── WebRtcPeerDisconnected ───────────────────────────────────────────

pub(crate) fn handle_webrtc_peer_disconnected(
    peer_id: String,
    webrtc_peers: &mut std::collections::HashSet<String>,
    gossip_overlays: &mut HashMap<String, super::gossip::GossipOverlay>,
) {
    hollow_log!("[HOLLOW-WEBRTC] Data channel closed for {peer_id}");
    webrtc_peers.remove(&peer_id);
    // Update gossip peer scores: mark disconnected.
    for overlay in gossip_overlays.values_mut() {
        if let Some(score) = overlay.peer_scores.get_mut(&peer_id) {
            score.mark_disconnected();
        }
    }
}

// ── WebRtcSendSignal ─────────────────────────────────────────────────

pub(crate) fn handle_webrtc_send_signal(
    peer_id: String,
    signal_type: String,
    payload: String,
    conn_id: String,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) {
    let msg = match signal_type.as_str() {
        "offer" => HavenMessage::RtcOffer { sdp: payload, conn_id },
        "answer" => HavenMessage::RtcAnswer { sdp: payload, conn_id },
        "ice" => {
            // Parse ICE candidate JSON payload.
            if let Ok(ice) = serde_json::from_str::<serde_json::Value>(&payload) {
                HavenMessage::RtcIceCandidate {
                    candidate: ice["candidate"].as_str().unwrap_or("").to_string(),
                    sdp_mid: ice["sdpMid"].as_str().unwrap_or("").to_string(),
                    sdp_mline_index: ice["sdpMLineIndex"].as_u64().unwrap_or(0) as u32,
                    conn_id,
                }
            } else {
                hollow_log!("[HOLLOW-WEBRTC] Failed to parse ICE payload");
                return;
            }
        }
        // Hollow Share's dedicated STUN-only data channel — own variants so a
        // pre-Share-lane client drops them instead of mistaking a Share offer
        // for a general one (see HavenMessage::RtcShareOffer).
        "share_offer" => HavenMessage::RtcShareOffer { sdp: payload, conn_id },
        "share_answer" => HavenMessage::RtcShareAnswer { sdp: payload, conn_id },
        "share_ice" => {
            if let Ok(ice) = serde_json::from_str::<serde_json::Value>(&payload) {
                HavenMessage::RtcShareIceCandidate {
                    candidate: ice["candidate"].as_str().unwrap_or("").to_string(),
                    sdp_mid: ice["sdpMid"].as_str().unwrap_or("").to_string(),
                    sdp_mline_index: ice["sdpMLineIndex"].as_u64().unwrap_or(0) as u32,
                    conn_id,
                }
            } else {
                hollow_log!("[HOLLOW-WEBRTC] Failed to parse Share ICE payload");
                return;
            }
        }
        _ => {
            hollow_log!("[HOLLOW-WEBRTC] Unknown signal type: {signal_type}");
            return;
        }
    };
    // Multi-device: `peer_id` may be the conversation MASTER (UI key), which no
    // socket authenticates as → the signal would be silently dropped and the data
    // channel (used for P2P file transfer) never forms. Target ONE concrete online
    // device of that identity — NOT a fan-out: a duplicate SDP offer/answer to
    // several devices would create competing peer connections / answer glare for a
    // single `conn_id`. A deterministic pick (lowest device id) keeps both sides
    // agreeing on the same target. Single-device falls back to the raw id.
    let target = pick_online_device(ws_room_peers, &peer_id);
    send_message_to_peer(ws_cmd_tx, ws_room_peers, &target, msg);
}

/// Pick ONE concrete online device for an identity addressed by `peer_id` (which
/// may be a master id). Used by `conn_id`-keyed call/WebRTC signaling so a signal
/// the UI addressed by master reaches a real device instead of being dropped.
///
/// CRITICAL — if `peer_id` is ALREADY a live device id (exact match in a room),
/// return it UNCHANGED. This is what keeps a call/data-channel ANSWER and its ICE
/// flowing back to the EXACT device that sent the offer: the receive path reports
/// the sender's device id to Dart, Dart replies addressed to that device, and we
/// must not re-pick a different sibling device (which would break the `conn_id`
/// negotiation). The master→device pick only kicks in for an OUTBOUND
/// invite/offer where the UI only knows the master; deterministic (lowest id) so
/// both sides converge. Falls back to the raw id when nothing is online.
fn pick_online_device(
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    peer_id: &str,
) -> String {
    // Already a live device → use it as-is (answer/ICE back to the exact peer).
    if ws_room_peers.values().any(|peers| peers.contains(peer_id)) {
        return peer_id.to_string();
    }
    let mut devices = super::crypto_handler::online_devices_for(ws_room_peers, peer_id);
    if devices.is_empty() {
        return peer_id.to_string();
    }
    devices.sort();
    devices.into_iter().next().unwrap_or_else(|| peer_id.to_string())
}

// ── CallSendSignal ───────────────────────────────────────────────────

pub(crate) fn handle_call_send_signal(
    peer_id: String,
    signal_type: String,
    payload: String,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) {
    let Some(msg) = build_call_signal(&signal_type, payload) else { return; };
    // Multi-device: `peer_id` is the friend's MASTER (the call UI keys on the
    // friend, not a device), which no socket authenticates as → every call signal
    // (invite/accept/sdp/ice/state) addressed to it is silently dropped and the
    // call never rings / never connects. Target ONE concrete online device,
    // deterministically (lowest device id) so both sides converge on the SAME
    // target for the `call_id`-keyed negotiation — NOT a fan-out (ringing every
    // device + competing answers). Full ring-all-answer-once is a later design;
    // this v1 reaches the friend's (deterministically chosen) online device.
    // Single-device falls back to the raw id (device == master), unchanged.
    let target = pick_online_device(ws_room_peers, &peer_id);
    // Observability (2026-07-20): the outgoing call path used to be fully
    // silent — an invite aimed at a stale-presence peer vanished with no
    // trace anywhere (UI rang 30s, logs empty, undiagnosable). Log the
    // resolved target for the LOW-VOLUME control signals, and always log
    // when the target is about to be dropped as unreachable; sdp/ice floods
    // stay quiet on the happy path.
    let reachable = ws_room_peers.values().any(|ps| ps.contains(&target));
    let control = matches!(
        signal_type.as_str(),
        "invite" | "accept" | "reject" | "end" | "busy"
    );
    if control || !reachable {
        hollow_log!(
            "[HOLLOW-CALL] Send {signal_type} for {peer_id} -> device {target} ({})",
            if reachable { "in-room" } else { "UNREACHABLE — will be dropped" }
        );
    }
    send_message_to_peer(ws_cmd_tx, ws_room_peers, &target, msg);
}

/// JSON string field with the signal-payload convention: missing → "".
fn jstr(v: &serde_json::Value, key: &str) -> String {
    v[key].as_str().unwrap_or("").to_string()
}

/// Build the outbound 1:1 call-signal message. Signal types are WHITELISTED —
/// an unknown type logs and yields `None` (dropped by design); a known
/// JSON-carrying type with an unparseable payload also yields `None`.
fn build_call_signal(signal_type: &str, payload: String) -> Option<HavenMessage> {
    match signal_type {
        "invite" => Some(build_call_invite(payload)),
        "accept" => Some(build_call_accept(payload)),
        "reject" => Some(HavenMessage::CallReject { call_id: payload }),
        "end" => Some(HavenMessage::CallEnd { call_id: payload }),
        "busy" => Some(HavenMessage::CallBusy { call_id: payload }),
        _ => build_call_json_signal(signal_type, &payload),
    }
}

/// CallInvite: JSON payload preferred, bare call-id string as legacy fallback.
fn build_call_invite(payload: String) -> HavenMessage {
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) {
        HavenMessage::CallInvite {
            call_id: jstr(&v, "call_id"),
            video: v["video"].as_bool().unwrap_or(false),
            sframe_key: jstr(&v, "sframe_key"),
        }
    } else {
        HavenMessage::CallInvite { call_id: payload, video: false, sframe_key: String::new() }
    }
}

/// CallAccept: JSON payload preferred, bare call-id string as legacy fallback.
fn build_call_accept(payload: String) -> HavenMessage {
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) {
        HavenMessage::CallAccept {
            call_id: v["call_id"].as_str().unwrap_or(&payload).to_string(),
            sframe_key: jstr(&v, "sframe_key"),
        }
    } else {
        HavenMessage::CallAccept { call_id: payload, sframe_key: String::new() }
    }
}

/// Call signal types whose payload MUST be valid JSON (no legacy fallback).
/// Unknown types log "Unknown call signal type"; known types with a bad
/// payload log "Failed to parse … payload" — exactly the original arm order
/// (an unknown type never reports a parse failure).
fn build_call_json_signal(signal_type: &str, payload: &str) -> Option<HavenMessage> {
    let parsed = serde_json::from_str::<serde_json::Value>(payload).ok();
    let msg = match signal_type {
        "sdp_offer" => parsed.map(|v| HavenMessage::CallSdpOffer {
            call_id: jstr(&v, "call_id"),
            sdp: jstr(&v, "sdp"),
        }),
        "sdp_answer" => parsed.map(|v| HavenMessage::CallSdpAnswer {
            call_id: jstr(&v, "call_id"),
            sdp: jstr(&v, "sdp"),
        }),
        "ice" => parsed.map(|v| HavenMessage::CallIceCandidate {
            call_id: jstr(&v, "call_id"),
            candidate: jstr(&v, "candidate"),
            sdp_mid: jstr(&v, "sdpMid"),
            sdp_mline_index: v["sdpMLineIndex"].as_u64().unwrap_or(0) as u32,
        }),
        "video_state" => parsed.map(|v| HavenMessage::CallVideoState {
            call_id: jstr(&v, "call_id"),
            enabled: v["enabled"].as_bool().unwrap_or(false),
        }),
        "audio_state" => parsed.map(|v| HavenMessage::CallAudioState {
            call_id: jstr(&v, "call_id"),
            muted: v["muted"].as_bool().unwrap_or(false),
            deafened: v["deafened"].as_bool().unwrap_or(false),
        }),
        "screen_state" => parsed.map(|v| HavenMessage::CallScreenState {
            call_id: jstr(&v, "call_id"),
            enabled: v["enabled"].as_bool().unwrap_or(false),
            quality: v["quality"].as_str().map(|s| s.to_string()),
        }),
        "screen_offer" => parsed.map(|v| HavenMessage::CallScreenOffer {
            call_id: jstr(&v, "call_id"),
            sdp: jstr(&v, "sdp"),
        }),
        "screen_answer" => parsed.map(|v| HavenMessage::CallScreenAnswer {
            call_id: jstr(&v, "call_id"),
            sdp: jstr(&v, "sdp"),
        }),
        "screen_ice" => parsed.map(|v| HavenMessage::CallScreenIce {
            call_id: jstr(&v, "call_id"),
            candidate: jstr(&v, "candidate"),
            sdp_mid: jstr(&v, "sdpMid"),
            sdp_mline_index: v["sdpMLineIndex"].as_u64().unwrap_or(0) as u32,
            role: jstr(&v, "role"),
        }),
        _ => {
            hollow_log!("[HOLLOW-CALL] Unknown call signal type: {signal_type}");
            return None;
        }
    };
    if msg.is_none() {
        // Historic log labels: "ice" reported as "ICE", every other type by name.
        let label = if signal_type == "ice" { "ICE" } else { signal_type };
        hollow_log!("[HOLLOW-CALL] Failed to parse {label} payload");
    }
    msg
}

// ── VoiceChannelJoin ─────────────────────────────────────────────────

pub(crate) async fn handle_voice_channel_join(
    server_id: String,
    channel_id: String,
    mls: &mut Option<MlsManager>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server_states: &HashMap<String, ServerState>,
    bundle_keypair: &NativeKeypair,
    crypto_store: &CryptoStore,
    voice_channel_participants: &mut HashMap<String, std::collections::HashSet<String>>,
    voice_channel_gossip_mode: &mut HashMap<String, bool>,
    gossip_overlays: &HashMap<String, super::gossip::GossipOverlay>,
    local_peer_str: &str,
    event_tx: &mpsc::Sender<NetworkEvent>,
) {
    hollow_log!("[HOLLOW-VC] Join voice channel {channel_id} in server {server_id}");

    // Restricted channel guard: a member whose role doesn't satisfy the channel's
    // visibility tier must not be able to JOIN a restricted voice channel at all
    // (the UI hides it, but a modified client could try). Reject before we announce
    // the join or touch SFrame. `can_see_channel` collapses device→master.
    let restricted = server_states
        .get(&server_id)
        .is_some_and(|s| s.channel_uses_subgroup(&channel_id));
    if restricted {
        let allowed = server_states
            .get(&server_id)
            .is_some_and(|s| s.can_see_channel(local_peer_str, &channel_id));
        if !allowed {
            hollow_log!("[HOLLOW-VC] Rejecting join to restricted channel {channel_id} — not permitted");
            return;
        }
    }

    // MLS broadcast + always plaintext — voice joins must arrive even with stale MLS epochs.
    let envelope = MessageEnvelope::VoiceChannelJoin {
        sid: server_id.clone(),
        cid: channel_id.clone(),
    };
    let plain = HavenMessage::VoiceChannelJoin {
        server_id: server_id.clone(), channel_id: channel_id.clone(),
    };
    broadcast_vc_presence(
        mls, ws_cmd_tx, ws_room_peers, server_states, crypto_store,
        &server_id, local_peer_str, &envelope, &plain,
    );
    // Track participant.
    let vc_key = format!("{}:{}", server_id, channel_id);
    voice_channel_participants.entry(vc_key.clone()).or_default()
        .insert(local_peer_str.to_string());
    // Emit current MLS epoch key BEFORE the join event — Dart caches it,
    // then applies it after creating the VoiceChannelService.
    emit_vc_sframe_key(
        mls, ws_cmd_tx, ws_room_peers, server_states,
        &server_id, &channel_id, restricted, local_peer_str, event_tx,
    ).await;
    // Emit locally so our own UI updates.
    let _ = event_tx.send(NetworkEvent::VoiceChannelJoined {
        server_id: server_id.clone(), channel_id: channel_id.clone(),
        peer_id: local_peer_str.to_string(),
    }).await;
    // Check for mode transition.
    check_voice_mode_transition(
        &vc_key, &server_id, &channel_id,
        voice_channel_participants, voice_channel_gossip_mode,
        gossip_overlays, local_peer_str, event_tx,
    ).await;
}

/// Fan a plaintext `HavenMessage` to every server member except ourselves
/// (device→master fan handled inside `send_raw_to_identity`).
fn fan_plaintext_to_members(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    state: &ServerState,
    local_peer_str: &str,
    msg: &HavenMessage,
) {
    let data = serde_json::to_vec(msg).unwrap_or_default();
    for member in state.members.keys() {
        if super::resolver::same_identity(member, local_peer_str) { continue; }
        send_raw_to_identity(ws_cmd_tx, ws_room_peers, member, data.clone());
    }
}

/// Announce voice-channel presence (join/leave): MLS broadcast when the server
/// group is held, PLUS always the plaintext member fan-out — voice presence
/// must arrive even with stale MLS epochs.
#[allow(clippy::too_many_arguments)]
fn broadcast_vc_presence(
    mls: &mut Option<MlsManager>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server_states: &HashMap<String, ServerState>,
    crypto_store: &CryptoStore,
    server_id: &str,
    local_peer_str: &str,
    envelope: &MessageEnvelope,
    plain: &HavenMessage,
) {
    let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(server_id));
    if mls_ok {
        let _ = send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, server_id, envelope, crypto_store);
    }
    if let Some(state) = server_states.get(server_id) {
        fan_plaintext_to_members(ws_cmd_tx, ws_room_peers, state, local_peer_str, plain);
    }
}

/// Emit the current SFrame key for a voice channel we just joined.
///
/// For a RESTRICTED voice channel the SFrame key is derived from the channel's
/// own MLS SUBGROUP (`subgroup_id`), NOT the server-wide group — so a
/// non-qualifying member can't derive the key. The emitted event carries
/// `channel_id: Some(cid)` so Dart routes the key to that channel's cryptor.
///
/// CAUTION: the subgroup may not exist on our side yet (we just became a
/// participant / were recently promoted). In that case we must NOT fall back to
/// the server-group key (that would defeat the cryptographic isolation). Instead
/// we pull ourselves into the subgroup via the same bootstrap path text uses —
/// the resulting Welcome → MlsEpochChanged{channel_id} delivers the key.
#[allow(clippy::too_many_arguments)]
async fn emit_vc_sframe_key(
    mls: &mut Option<MlsManager>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server_states: &HashMap<String, ServerState>,
    server_id: &str,
    channel_id: &str,
    restricted: bool,
    local_peer_str: &str,
    event_tx: &mpsc::Sender<NetworkEvent>,
) {
    let group_key = if restricted {
        crate::crypto::subgroup_id(server_id, channel_id)
    } else {
        server_id.to_string()
    };
    let emit_cid = if restricted { Some(channel_id.to_string()) } else { None };
    match mls.as_mut() {
        Some(mls_mgr) => {
            let has_group = mls_mgr.has_group(&group_key);
            hollow_log!("[HOLLOW-VC-SFRAME] MLS exists, has_group({group_key})={has_group}");
            if has_group {
                export_and_emit_sframe(mls_mgr, &group_key, server_id, emit_cid, event_tx).await;
            } else if restricted {
                // We qualify (join guard passed) but don't hold the subgroup yet.
                // Pull our KeyPackage to the subgroup coordinator; the Welcome it
                // sends back fires MlsEpochChanged with our channel_id.
                if let Some(state) = server_states.get(server_id) {
                    hollow_log!("[HOLLOW-VC-SFRAME] Subgroup {group_key} not held — requesting bootstrap");
                    super::crypto_handler::request_subgroup_bootstrap(
                        mls_mgr, ws_cmd_tx, ws_room_peers,
                        state, server_id, channel_id, local_peer_str,
                    );
                }
            } else if !super::conference::is_conference_sid(server_id) {
                // No SERVER group either — every other participant encrypts
                // with a key we can't derive, so their audio would play as
                // ciphertext until something re-adds us. Pull ourselves in via
                // the owner; the Welcome fires MlsEpochChanged (server group).
                if let Some(state) = server_states.get(server_id) {
                    hollow_log!("[HOLLOW-VC-SFRAME] Server group {group_key} not held — requesting bootstrap");
                    super::crypto_handler::request_server_group_bootstrap(
                        mls_mgr, ws_cmd_tx, ws_room_peers,
                        state, server_id, local_peer_str,
                    );
                }
            }
        }
        None => hollow_log!("[HOLLOW-VC-SFRAME] MLS is None — no SFrame key"),
    }
}

/// Export the SFrame secret from a held MLS group and emit `MlsEpochChanged`.
async fn export_and_emit_sframe(
    mls_mgr: &mut MlsManager,
    group_key: &str,
    server_id: &str,
    emit_cid: Option<String>,
    event_tx: &mpsc::Sender<NetworkEvent>,
) {
    match mls_mgr.export_secret(group_key, "sframe", b"", 32) {
        Ok(sframe_key) => {
            let epoch = mls_mgr.epoch(group_key).unwrap_or(0);
            hollow_log!("[HOLLOW-VC-SFRAME] Emitting SFrame key for {group_key} epoch {epoch}");
            let _ = event_tx.send(NetworkEvent::MlsEpochChanged {
                server_id: server_id.to_string(), epoch, sframe_key,
                channel_id: emit_cid,
            }).await;
        }
        Err(e) => hollow_log!("[HOLLOW-VC-SFRAME] export_secret FAILED: {e}"),
    }
}

// ── VoiceSframeHeal (issue #27) ──────────────────────────────────────

/// SFrame heal request from Dart: the voice cryptors report sustained decrypt
/// failures against `peer_id`, i.e. our key material and theirs disagree.
///
/// Non-escalated: re-export + re-emit the current epoch key (covers a lost
/// `MlsEpochChanged` on the Dart side), or request a bootstrap when we don't
/// hold the group at all.
///
/// Escalated (Dart applies a 60s cooldown): converge a genuinely forked group.
///   * We are NOT the group authority → drop our group and re-bootstrap from
///     the authority — the fresh Welcome lands us on their epoch.
///   * We ARE the authority (owner / subgroup coordinator) → queue a
///     remove + re-add of the failing peer's leaves; the batch timer commits
///     (re-keying everyone) and the peer converges via Welcome or its own
///     commit-fail recovery.
/// Conferences only ever re-emit — dropping the conf group would drop our
/// admission to the call itself.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_voice_sframe_heal(
    server_id: String,
    channel_id: String,
    peer_id: String,
    escalate: bool,
    mls: &mut Option<MlsManager>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server_states: &HashMap<String, ServerState>,
    pending_mls_removals: &mut HashMap<String, Vec<String>>,
    mls_bootstrap_requested: &mut HashMap<String, std::time::Instant>,
    crypto_store: &CryptoStore,
    local_peer_str: &str,
    event_tx: &mpsc::Sender<NetworkEvent>,
) {
    let Some(mls_mgr) = mls.as_mut() else {
        hollow_log!("[HOLLOW-VC-SFRAME] HEAL: MLS is None — nothing to heal");
        return;
    };
    let is_conf = super::conference::is_conference_sid(&server_id);
    let restricted = !is_conf && server_states
        .get(&server_id)
        .is_some_and(|s| s.channel_uses_subgroup(&channel_id));
    let group_key = if restricted {
        crate::crypto::subgroup_id(&server_id, &channel_id)
    } else {
        server_id.clone()
    };
    let emit_cid = if restricted { Some(channel_id.clone()) } else { None };
    hollow_log!("[HOLLOW-VC-SFRAME] HEAL request for {group_key} (escalate={escalate})");

    // Always start with the cheap fix: re-emit whatever key we currently hold
    // (idempotent on the Dart side), or pull ourselves into the group. A held
    // but INACTIVE group (we were evicted — e.g. by the authority's heal
    // remove+re-add) can't export; treat it as group-less.
    let mut group_usable = mls_mgr.has_group(&group_key);
    if group_usable && !mls_mgr.is_active(&group_key) {
        hollow_log!("[HOLLOW-VC-SFRAME] HEAL: group {group_key} held but INACTIVE (evicted) — dropping");
        mls_mgr.remove_group(&group_key);
        super::crypto_handler::persist_mls_state(mls_mgr, crypto_store);
        group_usable = false;
    }
    if group_usable {
        export_and_emit_sframe(mls_mgr, &group_key, &server_id, emit_cid.clone(), event_tx).await;
    } else if let Some(state) = server_states.get(&server_id) {
        if !mls_bootstrap_requested.get(&group_key)
            .is_some_and(|t| t.elapsed() < super::swarm::MLS_BOOTSTRAP_TIMEOUT)
        {
            if restricted {
                super::crypto_handler::request_subgroup_bootstrap(
                    mls_mgr, ws_cmd_tx, ws_room_peers,
                    state, &server_id, &channel_id, local_peer_str,
                );
                mls_bootstrap_requested.insert(group_key.clone(), std::time::Instant::now());
            } else if super::crypto_handler::request_server_group_bootstrap(
                mls_mgr, ws_cmd_tx, ws_room_peers, state, &server_id, local_peer_str,
            ) {
                mls_bootstrap_requested.insert(group_key.clone(), std::time::Instant::now());
            }
        }
        return; // no group — nothing further to escalate with
    }

    if !escalate { return; }
    if is_conf {
        hollow_log!("[HOLLOW-VC-SFRAME] HEAL: conference {server_id} — re-emit only");
        return;
    }
    let Some(state) = server_states.get(&server_id) else { return };

    // Who is the authority for this group?
    let authority: Option<String> = if restricted {
        super::crypto_handler::elect_subgroup_coordinator(
            state, &channel_id, local_peer_str, ws_room_peers)
    } else {
        state.members.keys().find(|m| {
            state.roles.get(*m)
                .map(|r| *r.read() == crate::crdt::operations::MemberRole::Owner)
                .unwrap_or(false)
        }).cloned()
    };
    let we_are_authority = authority.as_deref()
        .is_some_and(|a| super::resolver::same_identity(a, local_peer_str));

    if we_are_authority {
        // Remove + re-add the failing peer's leaves. The batch removal commit
        // rotates the key for everyone; the peer converges via the re-add
        // Welcome, or — if its group is forked and can't process the commit —
        // via its own commit-fail drop-and-rebootstrap recovery.
        let peer_master = super::resolver::resolve(&peer_id);
        let leaves = mls_mgr.group_members(&group_key);
        let mut queued = 0usize;
        for leaf in &leaves {
            if super::resolver::same_identity(leaf, &peer_master) {
                pending_mls_removals.entry(group_key.clone()).or_default().push(leaf.clone());
                queued += 1;
            }
        }
        // Fresh KeyPackage so the batch timer can re-add them (answered only
        // when the peer is group-less, i.e. mid-recovery — harmless otherwise).
        let data = serde_json::to_vec(&HavenMessage::MlsKeyPackageRequest {
            server_id: server_id.clone(),
            channel_id: emit_cid,
        }).unwrap_or_default();
        send_raw_to_identity(ws_cmd_tx, ws_room_peers, &peer_master, data);
        hollow_log!("[HOLLOW-VC-SFRAME] HEAL (authority): queued {queued} leaf removal(s) of {peer_master} from {group_key} + requested fresh KeyPackage");
    } else if let Some(authority) = authority {
        // Defer to the authority's view of the group: drop ours and get a
        // fresh Welcome at their epoch. Cooldown-guarded — group surgery.
        if mls_bootstrap_requested.get(&group_key)
            .is_some_and(|t| t.elapsed() < super::swarm::MLS_BOOTSTRAP_TIMEOUT)
        {
            hollow_log!("[HOLLOW-VC-SFRAME] HEAL: re-bootstrap for {group_key} already in flight");
            return;
        }
        hollow_log!("[HOLLOW-VC-SFRAME] HEAL: dropping {group_key} and re-bootstrapping from {authority}");
        mls_mgr.remove_group(&group_key);
        super::crypto_handler::persist_mls_state(mls_mgr, crypto_store);
        match mls_mgr.generate_key_package() {
            Ok(kp_bytes) => {
                let kp_b64 = base64::engine::general_purpose::STANDARD.encode(&kp_bytes);
                let data = serde_json::to_vec(&HavenMessage::MlsKeyPackage {
                    server_id: server_id.clone(),
                    key_package: kp_b64,
                    channel_id: emit_cid,
                }).unwrap_or_default();
                let sent = send_raw_to_identity(ws_cmd_tx, ws_room_peers, &authority, data);
                if sent > 0 {
                    mls_bootstrap_requested.insert(group_key.clone(), std::time::Instant::now());
                }
            }
            Err(e) => hollow_log!("[HOLLOW-VC-SFRAME] HEAL: KeyPackage gen failed: {e}"),
        }
    } else {
        hollow_log!("[HOLLOW-VC-SFRAME] HEAL: no reachable authority for {group_key}");
    }
}

// ── VoiceChannelLeave ────────────────────────────────────────────────

pub(crate) async fn handle_voice_channel_leave(
    server_id: String,
    channel_id: String,
    mls: &mut Option<MlsManager>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server_states: &HashMap<String, ServerState>,
    bundle_keypair: &NativeKeypair,
    crypto_store: &CryptoStore,
    voice_channel_participants: &mut HashMap<String, std::collections::HashSet<String>>,
    voice_channel_gossip_mode: &mut HashMap<String, bool>,
    gossip_overlays: &HashMap<String, super::gossip::GossipOverlay>,
    local_peer_str: &str,
    event_tx: &mpsc::Sender<NetworkEvent>,
) {
    hollow_log!("[HOLLOW-VC] Leave voice channel {channel_id} in server {server_id}");
    // MLS broadcast + always plaintext — voice leaves must arrive even with stale MLS epochs.
    let envelope = MessageEnvelope::VoiceChannelLeave {
        sid: server_id.clone(),
        cid: channel_id.clone(),
    };
    let plain = HavenMessage::VoiceChannelLeave {
        server_id: server_id.clone(), channel_id: channel_id.clone(),
    };
    broadcast_vc_presence(
        mls, ws_cmd_tx, ws_room_peers, server_states, crypto_store,
        &server_id, local_peer_str, &envelope, &plain,
    );
    // Untrack participant.
    let vc_key = format!("{}:{}", server_id, channel_id);
    if let Some(participants) = voice_channel_participants.get_mut(&vc_key) {
        participants.remove(&local_peer_str.to_string());
        if participants.is_empty() {
            voice_channel_participants.remove(&vc_key);
            voice_channel_gossip_mode.remove(&vc_key);
        }
    }
    let _ = event_tx.send(NetworkEvent::VoiceChannelLeft {
        server_id: server_id.clone(), channel_id: channel_id.clone(),
        peer_id: local_peer_str.to_string(),
    }).await;
    // Check for mode transition.
    check_voice_mode_transition(
        &vc_key, &server_id, &channel_id,
        voice_channel_participants, voice_channel_gossip_mode,
        gossip_overlays, local_peer_str, event_tx,
    ).await;
}

// ── Auto-leave on lost visibility ────────────────────────────────────

/// After a role/visibility/kick/ban op applies, leave any voice channel we're
/// currently IN but can no longer SEE (visibility raised above our tier, or we
/// were demoted / kicked / banned). Mirrors the text-channel UI eviction, but for
/// the active call: a participant who loses access must drop the call (and rotate
/// the SFrame key for the rest via the subgroup removal that already ran). Runs on
/// the affected node itself, so it works regardless of which screen is focused and
/// on both platforms via the normal `handle_voice_channel_leave` teardown.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn auto_leave_invisible_voice_channels(
    mls: &mut Option<MlsManager>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server_states: &HashMap<String, ServerState>,
    bundle_keypair: &NativeKeypair,
    crypto_store: &CryptoStore,
    voice_channel_participants: &mut HashMap<String, std::collections::HashSet<String>>,
    voice_channel_gossip_mode: &mut HashMap<String, bool>,
    gossip_overlays: &HashMap<String, super::gossip::GossipOverlay>,
    local_peer_str: &str,
    server_id: &str,
    event_tx: &mpsc::Sender<NetworkEvent>,
) {
    // Which voice channels of THIS server are we currently a participant in?
    let prefix = format!("{server_id}:");
    let leaving: Vec<String> = voice_channel_participants
        .iter()
        .filter(|(vc_key, members)| {
            vc_key.starts_with(&prefix) && members.contains(local_peer_str)
        })
        .filter_map(|(vc_key, _)| vc_key.strip_prefix(&prefix).map(|c| c.to_string()))
        .filter(|cid| {
            // Leave if we were removed from the server entirely (kick/ban → not a
            // member, so we can't be in any of its calls), OR a restricted channel's
            // visibility now excludes us (demotion / tier raised). `is_member` /
            // `can_see_channel` collapse device→master.
            server_states.get(server_id).is_some_and(|s| {
                !s.is_member(local_peer_str)
                    || (s.channel_uses_subgroup(cid) && !s.can_see_channel(local_peer_str, cid))
            })
        })
        .collect();

    for cid in leaving {
        hollow_log!("[HOLLOW-VC] Auto-leaving restricted voice channel {cid} in {server_id} — visibility lost");
        handle_voice_channel_leave(
            server_id.to_string(), cid,
            mls, ws_cmd_tx, ws_room_peers,
            server_states, bundle_keypair, crypto_store,
            voice_channel_participants, voice_channel_gossip_mode,
            gossip_overlays, local_peer_str, event_tx,
        ).await;
    }
}

// ── VoiceChannelSendSignal ───────────────────────────────────────────

pub(crate) async fn handle_voice_channel_send_signal(
    server_id: String,
    channel_id: String,
    peer_id: String,
    signal_type: String,
    payload: String,
    mls: &mut Option<MlsManager>,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server_states: &HashMap<String, ServerState>,
    bundle_keypair: &NativeKeypair,
    local_peer_str: &str,
    event_tx: &mpsc::Sender<NetworkEvent>,
) {
    hollow_log!("[HOLLOW-VC] Send signal {signal_type} to {peer_id} in vc {channel_id}");
    let Some(envelope) = build_vc_signal_envelope(&signal_type, &server_id, &channel_id, &payload) else {
        return;
    };
    // Broadcast state signals (audio/screen/camera state) → MLS broadcast + plaintext fallback.
    // Targeted SDP/ICE signals → MLS targeted + Olm fallback (IPs are sensitive).
    let is_broadcast = matches!(signal_type.as_str(), "audio_state" | "screen_state" | "camera_state");
    if is_broadcast {
        broadcast_vc_state_signal(
            &signal_type, &payload, &envelope,
            mls, crypto_store, ws_cmd_tx, ws_room_peers, server_states,
            &server_id, &channel_id, local_peer_str,
        );
    } else {
        // Targeted SDP/ICE: Olm encrypted + SendDirect.
        let env_json = serde_json::to_string(&envelope).unwrap_or_default();
        send_encrypted_message(olm, crypto_store, &peer_id, &env_json, event_tx, ws_cmd_tx, ws_room_peers).await;
    }
}

/// Build the outbound voice-channel signal envelope. Signal types are
/// WHITELISTED — an unknown type logs and yields `None`; a known type with an
/// unparseable payload silently yields `None` (dropped, matching the original
/// arm-local `return`s).
fn build_vc_signal_envelope(
    signal_type: &str,
    server_id: &str,
    channel_id: &str,
    payload: &str,
) -> Option<MessageEnvelope> {
    let sid = server_id.to_string();
    let cid = channel_id.to_string();
    let parsed = serde_json::from_str::<serde_json::Value>(payload).ok();
    match signal_type {
        "sdp_offer" => parsed.map(|v| MessageEnvelope::VoiceChannelSdpOffer {
            sid, cid, sdp: jstr(&v, "sdp"), target: None,
        }),
        "sdp_answer" => parsed.map(|v| MessageEnvelope::VoiceChannelSdpAnswer {
            sid, cid, sdp: jstr(&v, "sdp"), target: None,
        }),
        "ice" => parsed.map(|v| MessageEnvelope::VoiceChannelIce {
            sid, cid,
            candidate: jstr(&v, "candidate"),
            sdp_mid: jstr(&v, "sdpMid"),
            sdp_mline_index: v["sdpMLineIndex"].as_u64().unwrap_or(0) as u32,
            target: None,
        }),
        "audio_state" => parsed.map(|v| MessageEnvelope::VoiceChannelAudioState {
            sid, cid,
            muted: v["muted"].as_bool().unwrap_or(false),
            deafened: v["deafened"].as_bool().unwrap_or(false),
            target: None,
        }),
        "screen_offer" => parsed.map(|v| MessageEnvelope::VoiceChannelScreenOffer {
            sid, cid, sdp: jstr(&v, "sdp"), target: None,
        }),
        "screen_answer" => parsed.map(|v| MessageEnvelope::VoiceChannelScreenAnswer {
            sid, cid, sdp: jstr(&v, "sdp"), target: None,
        }),
        "screen_ice" => parsed.map(|v| MessageEnvelope::VoiceChannelScreenIce {
            sid, cid,
            candidate: jstr(&v, "candidate"),
            sdp_mid: jstr(&v, "sdpMid"),
            sdp_mline_index: v["sdpMLineIndex"].as_u64().unwrap_or(0) as u32,
            role: jstr(&v, "role"),
            target: None,
        }),
        "screen_state" => parsed.map(|v| MessageEnvelope::VoiceChannelScreenState {
            sid, cid,
            enabled: v["enabled"].as_bool().unwrap_or(false),
            target: None,
            quality: v["quality"].as_str().map(|s| s.to_string()),
        }),
        "reneg_offer" => parsed.map(|v| MessageEnvelope::VoiceChannelRenegOffer {
            sid, cid, sdp: jstr(&v, "sdp"), target: None,
        }),
        "reneg_answer" => parsed.map(|v| MessageEnvelope::VoiceChannelRenegAnswer {
            sid, cid, sdp: jstr(&v, "sdp"), target: None,
        }),
        "camera_state" => parsed.map(|v| MessageEnvelope::VoiceChannelCameraState {
            sid, cid,
            enabled: v["enabled"].as_bool().unwrap_or(false),
            target: None,
        }),
        _ => {
            hollow_log!("[HOLLOW-VC] Unknown signal type: {signal_type}");
            None
        }
    }
}

/// Broadcast a VC state signal (audio/screen/camera state): MLS broadcast when
/// the server group is held; on failure or no group, plaintext member fan-out.
#[allow(clippy::too_many_arguments)]
fn broadcast_vc_state_signal(
    signal_type: &str,
    payload: &str,
    envelope: &MessageEnvelope,
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server_states: &HashMap<String, ServerState>,
    server_id: &str,
    channel_id: &str,
    local_peer_str: &str,
) {
    let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(server_id));
    let mls_sent = mls_ok && send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, server_id, envelope, crypto_store).is_ok();
    if !mls_sent {
        // Plaintext fallback: iterate members.
        let plaintext_msg = build_vc_plaintext_state(signal_type, server_id, channel_id, payload);
        if let Some(msg) = plaintext_msg
            && let Some(state) = server_states.get(server_id)
        {
            fan_plaintext_to_members(ws_cmd_tx, ws_room_peers, state, local_peer_str, &msg);
        }
    }
}

/// Plaintext `HavenMessage` twin of a broadcast VC state signal (used only as
/// the MLS-failure fallback). Non-state types yield `None`.
fn build_vc_plaintext_state(
    signal_type: &str,
    server_id: &str,
    channel_id: &str,
    payload: &str,
) -> Option<HavenMessage> {
    let parsed = serde_json::from_str::<serde_json::Value>(payload).ok();
    match signal_type {
        "audio_state" => parsed.map(|v| HavenMessage::VoiceChannelAudioState {
            server_id: server_id.to_string(), channel_id: channel_id.to_string(),
            muted: v["muted"].as_bool().unwrap_or(false),
            deafened: v["deafened"].as_bool().unwrap_or(false),
        }),
        "screen_state" => parsed.map(|v| HavenMessage::VoiceChannelScreenState {
            server_id: server_id.to_string(), channel_id: channel_id.to_string(),
            enabled: v["enabled"].as_bool().unwrap_or(false),
            quality: v["quality"].as_str().map(|s| s.to_string()),
        }),
        "camera_state" => parsed.map(|v| HavenMessage::VoiceChannelCameraState {
            server_id: server_id.to_string(), channel_id: channel_id.to_string(),
            enabled: v["enabled"].as_bool().unwrap_or(false),
        }),
        _ => None,
    }
}

// ── WebRtcPingReport ─────────────────────────────────────────────────

pub(crate) fn handle_webrtc_ping_report(
    peer_id: String,
    rtt_ms: u32,
    gossip_overlays: &mut HashMap<String, super::gossip::GossipOverlay>,
) {
    // Update peer score with latest RTT measurement.
    for overlay in gossip_overlays.values_mut() {
        if let Some(score) = overlay.peer_scores.get_mut(&peer_id) {
            score.update_latency(rtt_ms);
        }
    }
}

// ── WebRtcRouteReport ────────────────────────────────────────────────

/// Tier 3 (reachability-aware overlay): record the ICE route class Dart
/// measured for a live connection. Direct (host/srflx/LAN) peers score above
/// TURN-relayed ones in `PeerScore::composite`, so the 300s rotation drifts
/// the mesh toward peers that offload the relay instead of leaning on TURN.
pub(crate) fn handle_webrtc_route_report(
    peer_id: String,
    is_direct: bool,
    gossip_overlays: &mut HashMap<String, super::gossip::GossipOverlay>,
) {
    for overlay in gossip_overlays.values_mut() {
        if let Some(score) = overlay.peer_scores.get_mut(&peer_id) {
            score.is_direct = Some(is_direct);
        }
    }
}

// ── check_voice_mode_transition ──────────────────────────────────────

/// Check if a voice channel should transition between mesh and gossip mode.
/// Uses hysteresis: mesh→gossip at 6 participants, gossip→mesh at 4.
pub(crate) async fn check_voice_mode_transition(
    vc_key: &str,
    server_id: &str,
    channel_id: &str,
    voice_channel_participants: &HashMap<String, std::collections::HashSet<String>>,
    voice_channel_gossip_mode: &mut HashMap<String, bool>,
    gossip_overlays: &HashMap<String, super::gossip::GossipOverlay>,
    local_peer_str: &str,
    event_tx: &mpsc::Sender<NetworkEvent>,
) {
    let count = voice_channel_participants
        .get(vc_key)
        .map(|p| p.len())
        .unwrap_or(0);
    let currently_gossip = *voice_channel_gossip_mode.get(vc_key).unwrap_or(&false);

    let should_gossip = if currently_gossip {
        // Hysteresis: stay in gossip until below threshold_down.
        count >= super::gossip::VOICE_GOSSIP_THRESHOLD_DOWN
    } else {
        // Switch to gossip at threshold_up.
        count >= super::gossip::VOICE_GOSSIP_THRESHOLD_UP
    };

    if should_gossip != currently_gossip {
        voice_channel_gossip_mode.insert(vc_key.to_string(), should_gossip);

        if should_gossip {
            // Switching to gossip mode — compute voice gossip neighbors.
            let participants = voice_channel_participants
                .get(vc_key)
                .cloned()
                .unwrap_or_default();
            let gossip_neighbors = if let Some(overlay) = gossip_overlays.get(server_id) {
                overlay.get_voice_gossip_neighbors(&participants, local_peer_str)
            } else {
                // No gossip overlay — fall back to first 12 participants.
                participants.iter()
                    .filter(|p| p.as_str() != local_peer_str)
                    .take(super::gossip::MAX_GOSSIP_NEIGHBORS)
                    .cloned()
                    .collect()
            };

            hollow_log!(
                "[HOLLOW-VC] Mode transition: mesh → gossip ({count} participants, {} gossip neighbors)",
                gossip_neighbors.len()
            );
            let _ = event_tx.send(NetworkEvent::VoiceChannelModeChanged {
                server_id: server_id.to_string(),
                channel_id: channel_id.to_string(),
                mode: "gossip".to_string(),
                gossip_neighbors,
            }).await;
        } else {
            hollow_log!("[HOLLOW-VC] Mode transition: gossip → mesh ({count} participants)");
            let _ = event_tx.send(NetworkEvent::VoiceChannelModeChanged {
                server_id: server_id.to_string(),
                channel_id: channel_id.to_string(),
                mode: "mesh".to_string(),
                gossip_neighbors: vec![],
            }).await;
        }
    }
}

/// Rate-limit gate for VC signaling envelopes (token bucket per peer).
/// Returns `true` if the call is allowed, `false` if rate-limited.
pub(crate) fn vc_rate_check(
    vc_signal_rate_tokens: &mut HashMap<String, (u32, std::time::Instant)>,
    sender_peer_id: &str,
) -> bool {
    // Evict stale entries (>10 min idle) to prevent unbounded growth.
    if vc_signal_rate_tokens.len() > 16 {
        let cutoff = std::time::Duration::from_secs(600);
        vc_signal_rate_tokens.retain(|_, (_, last)| last.elapsed() < cutoff);
    }

    let entry = vc_signal_rate_tokens
        .entry(sender_peer_id.to_string())
        .or_insert((VC_SIGNAL_RATE_BURST, std::time::Instant::now()));
    let (tokens, last_refill) = entry;
    let elapsed = last_refill.elapsed().as_secs_f64();
    let refill = (elapsed * VC_SIGNAL_RATE_REFILL as f64) as u32;
    if refill > 0 {
        *tokens = (*tokens + refill).min(VC_SIGNAL_RATE_BURST);
        *last_refill = std::time::Instant::now();
    }
    if *tokens == 0 {
        hollow_log!("[HOLLOW-SECURITY] VC signal rate limited for {sender_peer_id} — dropping");
        false
    } else {
        *tokens -= 1;
        true
    }
}

/// Helper: check VC participant membership.
fn is_vc_participant(
    voice_channel_participants: &HashMap<String, std::collections::HashSet<String>>,
    vc_key: &str,
    sender_peer_id: &str,
) -> bool {
    voice_channel_participants.get(vc_key)
        .map(|p| p.contains(sender_peer_id))
        .unwrap_or(false)
}

/// Handle `MessageEnvelope::VoiceChannelJoin` (MLS path).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_voice_channel_join(
    server_states: &HashMap<String, ServerState>,
    voice_channel_participants: &mut HashMap<String, std::collections::HashSet<String>>,
    voice_channel_gossip_mode: &mut HashMap<String, bool>,
    gossip_overlays: &HashMap<String, super::gossip::GossipOverlay>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    local_peer_str: &str,
    sender_peer_id: String,
    sid: String,
    cid: String,
) {
    if sender_peer_id == local_peer_str { return; }
    // Conferences are virtual servers with no CRDT state: this envelope arrived
    // MLS-DECRYPTED under the `conf:{id}` group, so the sender provably holds
    // the group — that IS the membership check (admission = the MLS add). The
    // plaintext HavenMessage::VoiceChannelJoin path keeps its strict CRDT guard
    // and conferences never ride it. Channel is always the synthetic "main".
    let is_conf = super::conference::is_conference_sid(&sid);
    let is_member = if is_conf { true } else {
        server_states.get(&sid)
            .map(|s| s.is_member(&sender_peer_id))
            .unwrap_or(false)
    };
    let is_voice_channel = if is_conf { cid == super::conference::CONF_CHANNEL } else {
        server_states.get(&sid)
            .and_then(|s| s.channels.get(&cid))
            .map(|ch| ch.channel_type == crate::crdt::server_state::ChannelType::Voice)
            .unwrap_or(false)
    };
    if !is_member {
        hollow_log!("[HOLLOW-SECURITY] BLOCKED VoiceChannelJoin from non-member {sender_peer_id} in server {sid}");
        return;
    }
    if !is_voice_channel {
        hollow_log!("[HOLLOW-SECURITY] BLOCKED VoiceChannelJoin for non-voice channel {cid} in server {sid}");
        return;
    }
    hollow_log!("[HOLLOW-VC] {sender_peer_id} joined voice channel {cid} in {sid}");
    let vc_key = format!("{sid}:{cid}");
    // Conference participant sync: a freshly-admitted member's join is the
    // FIRST thing existing participants hear from them — there is no CRDT/
    // room history to learn the pre-existing call roster from (a server
    // member watches every join live; a conference joiner was locked out
    // until admission). Reply with our own join, DIRECT, so the new member's
    // grid shows us. Plaintext (their MLS just minted — no epoch concerns);
    // their receive guard verifies us against the conf group's leaf set.
    if super::conference::is_conference_sid(&sid)
        && voice_channel_participants
            .get(&vc_key)
            .is_some_and(|p| p.contains(local_peer_str))
    {
        super::crypto_handler::send_message_to_peer_in_room(
            ws_cmd_tx, &sid, &sender_peer_id,
            HavenMessage::VoiceChannelJoin {
                server_id: sid.clone(), channel_id: cid.clone(),
            },
        );
    }
    voice_channel_participants.entry(vc_key.clone()).or_default()
        .insert(sender_peer_id.clone());
    let _ = event_tx.send(NetworkEvent::VoiceChannelJoined {
        server_id: sid.clone(), channel_id: cid.clone(),
        peer_id: sender_peer_id,
    }).await;
    check_voice_mode_transition(
        &vc_key, &sid, &cid,
        voice_channel_participants, voice_channel_gossip_mode,
        gossip_overlays, local_peer_str, event_tx,
    ).await;
}

/// Handle `MessageEnvelope::VoiceChannelLeave` (MLS path).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_voice_channel_leave(
    voice_channel_participants: &mut HashMap<String, std::collections::HashSet<String>>,
    voice_channel_gossip_mode: &mut HashMap<String, bool>,
    gossip_overlays: &HashMap<String, super::gossip::GossipOverlay>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    local_peer_str: &str,
    sender_peer_id: String,
    sid: String,
    cid: String,
) {
    if sender_peer_id == local_peer_str { return; }
    hollow_log!("[HOLLOW-VC] {sender_peer_id} left voice channel {cid} in {sid}");
    let vc_key = format!("{sid}:{cid}");
    if let Some(participants) = voice_channel_participants.get_mut(&vc_key) {
        participants.remove(&sender_peer_id);
        if participants.is_empty() {
            voice_channel_participants.remove(&vc_key);
            voice_channel_gossip_mode.remove(&vc_key);
        }
    }
    let _ = event_tx.send(NetworkEvent::VoiceChannelLeft {
        server_id: sid.clone(), channel_id: cid.clone(),
        peer_id: sender_peer_id,
    }).await;
    check_voice_mode_transition(
        &vc_key, &sid, &cid,
        voice_channel_participants, voice_channel_gossip_mode,
        gossip_overlays, local_peer_str, event_tx,
    ).await;
}

/// Helper: emit a VoiceChannelSignal event with sdp-size and participant guards.
async fn emit_vc_sdp_signal(
    voice_channel_participants: &HashMap<String, std::collections::HashSet<String>>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sender_peer_id: String,
    sid: String,
    cid: String,
    sdp: String,
    signal_type: &'static str,
    log_label: &'static str,
) {
    let vc_key = format!("{sid}:{cid}");
    if !is_vc_participant(voice_channel_participants, &vc_key, &sender_peer_id) {
        hollow_log!("[HOLLOW-SECURITY] BLOCKED VC {log_label} from non-participant {sender_peer_id} in {cid}");
        return;
    }
    if sdp.len() > 64 * 1024 {
        hollow_log!("[HOLLOW-SECURITY] BLOCKED VC {log_label} — size {} exceeds limit from {sender_peer_id}", sdp.len());
        return;
    }
    hollow_log!("[HOLLOW-VC] {log_label} from {sender_peer_id} in vc {cid}");
    let payload = serde_json::json!({"sdp": sdp}).to_string();
    let _ = event_tx.send(NetworkEvent::VoiceChannelSignal {
        server_id: sid, channel_id: cid, peer_id: sender_peer_id,
        signal_type: signal_type.to_string(), payload,
    }).await;
}

pub(crate) async fn handle_envelope_voice_channel_sdp_offer(
    voice_channel_participants: &HashMap<String, std::collections::HashSet<String>>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sender_peer_id: String, sid: String, cid: String, sdp: String,
) {
    emit_vc_sdp_signal(voice_channel_participants, event_tx, sender_peer_id, sid, cid, sdp, "sdp_offer", "SDP offer").await;
}

pub(crate) async fn handle_envelope_voice_channel_sdp_answer(
    voice_channel_participants: &HashMap<String, std::collections::HashSet<String>>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sender_peer_id: String, sid: String, cid: String, sdp: String,
) {
    emit_vc_sdp_signal(voice_channel_participants, event_tx, sender_peer_id, sid, cid, sdp, "sdp_answer", "SDP answer").await;
}

pub(crate) async fn handle_envelope_voice_channel_screen_offer(
    voice_channel_participants: &HashMap<String, std::collections::HashSet<String>>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sender_peer_id: String, sid: String, cid: String, sdp: String,
) {
    emit_vc_sdp_signal(voice_channel_participants, event_tx, sender_peer_id, sid, cid, sdp, "screen_offer", "Screen offer").await;
}

pub(crate) async fn handle_envelope_voice_channel_screen_answer(
    voice_channel_participants: &HashMap<String, std::collections::HashSet<String>>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sender_peer_id: String, sid: String, cid: String, sdp: String,
) {
    emit_vc_sdp_signal(voice_channel_participants, event_tx, sender_peer_id, sid, cid, sdp, "screen_answer", "Screen answer").await;
}

pub(crate) async fn handle_envelope_voice_channel_reneg_offer(
    voice_channel_participants: &HashMap<String, std::collections::HashSet<String>>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sender_peer_id: String, sid: String, cid: String, sdp: String,
) {
    emit_vc_sdp_signal(voice_channel_participants, event_tx, sender_peer_id, sid, cid, sdp, "reneg_offer", "Reneg offer").await;
}

pub(crate) async fn handle_envelope_voice_channel_reneg_answer(
    voice_channel_participants: &HashMap<String, std::collections::HashSet<String>>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sender_peer_id: String, sid: String, cid: String, sdp: String,
) {
    emit_vc_sdp_signal(voice_channel_participants, event_tx, sender_peer_id, sid, cid, sdp, "reneg_answer", "Reneg answer").await;
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_voice_channel_ice(
    voice_channel_participants: &HashMap<String, std::collections::HashSet<String>>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sender_peer_id: String,
    sid: String,
    cid: String,
    candidate: String,
    sdp_mid: String,
    sdp_mline_index: u32,
) {
    let vc_key = format!("{sid}:{cid}");
    if !is_vc_participant(voice_channel_participants, &vc_key, &sender_peer_id) {
        hollow_log!("[HOLLOW-SECURITY] BLOCKED VC ICE from non-participant {sender_peer_id} in {cid}");
        return;
    }
    hollow_log!("[HOLLOW-VC] ICE candidate from {sender_peer_id} in vc {cid}");
    let payload = serde_json::json!({
        "candidate": candidate,
        "sdpMid": sdp_mid,
        "sdpMLineIndex": sdp_mline_index,
    }).to_string();
    let _ = event_tx.send(NetworkEvent::VoiceChannelSignal {
        server_id: sid, channel_id: cid, peer_id: sender_peer_id,
        signal_type: "ice".to_string(), payload,
    }).await;
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_voice_channel_screen_ice(
    voice_channel_participants: &HashMap<String, std::collections::HashSet<String>>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sender_peer_id: String,
    sid: String,
    cid: String,
    candidate: String,
    sdp_mid: String,
    sdp_mline_index: u32,
    role: String,
) {
    let vc_key = format!("{sid}:{cid}");
    if !is_vc_participant(voice_channel_participants, &vc_key, &sender_peer_id) {
        hollow_log!("[HOLLOW-SECURITY] BLOCKED VC screen ICE from non-participant {sender_peer_id} in {cid}");
        return;
    }
    hollow_log!("[HOLLOW-VC] Screen ICE from {sender_peer_id} in vc {cid} role={role}");
    let payload = serde_json::json!({
        "candidate": candidate,
        "sdpMid": sdp_mid,
        "sdpMLineIndex": sdp_mline_index,
        "role": role,
    }).to_string();
    let _ = event_tx.send(NetworkEvent::VoiceChannelSignal {
        server_id: sid, channel_id: cid, peer_id: sender_peer_id,
        signal_type: "screen_ice".to_string(), payload,
    }).await;
}

pub(crate) async fn handle_envelope_voice_channel_audio_state(
    voice_channel_participants: &HashMap<String, std::collections::HashSet<String>>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sender_peer_id: String,
    sid: String,
    cid: String,
    muted: bool,
    deafened: bool,
) {
    let vc_key = format!("{sid}:{cid}");
    if !is_vc_participant(voice_channel_participants, &vc_key, &sender_peer_id) {
        hollow_log!("[HOLLOW-SECURITY] BLOCKED VC audio state from non-participant {sender_peer_id} in {cid}");
        return;
    }
    let payload = serde_json::json!({"muted": muted, "deafened": deafened}).to_string();
    let _ = event_tx.send(NetworkEvent::VoiceChannelSignal {
        server_id: sid, channel_id: cid, peer_id: sender_peer_id,
        signal_type: "audio_state".to_string(), payload,
    }).await;
}

pub(crate) async fn handle_envelope_voice_channel_screen_state(
    voice_channel_participants: &HashMap<String, std::collections::HashSet<String>>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sender_peer_id: String,
    sid: String,
    cid: String,
    enabled: bool,
    quality: Option<String>,
) {
    let vc_key = format!("{sid}:{cid}");
    if !is_vc_participant(voice_channel_participants, &vc_key, &sender_peer_id) {
        hollow_log!("[HOLLOW-SECURITY] BLOCKED VC screen state from non-participant {sender_peer_id} in {cid}");
        return;
    }
    hollow_log!("[HOLLOW-VC] Screen state from {sender_peer_id}: enabled={enabled} quality={quality:?}");
    let mut json = serde_json::json!({"enabled": enabled});
    if let Some(q) = &quality {
        json["quality"] = serde_json::Value::String(q.clone());
    }
    let payload = json.to_string();
    let _ = event_tx.send(NetworkEvent::VoiceChannelSignal {
        server_id: sid, channel_id: cid, peer_id: sender_peer_id,
        signal_type: "screen_state".to_string(), payload,
    }).await;
}

pub(crate) async fn handle_envelope_voice_channel_camera_state(
    voice_channel_participants: &HashMap<String, std::collections::HashSet<String>>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sender_peer_id: String,
    sid: String,
    cid: String,
    enabled: bool,
) {
    let vc_key = format!("{sid}:{cid}");
    if !is_vc_participant(voice_channel_participants, &vc_key, &sender_peer_id) {
        hollow_log!("[HOLLOW-SECURITY] BLOCKED VC camera state from non-participant {sender_peer_id} in {cid}");
        return;
    }
    hollow_log!("[HOLLOW-VC] Camera state from {sender_peer_id}: enabled={enabled}");
    let payload = serde_json::json!({"enabled": enabled}).to_string();
    let _ = event_tx.send(NetworkEvent::VoiceChannelSignal {
        server_id: sid, channel_id: cid, peer_id: sender_peer_id,
        signal_type: "camera_state".to_string(), payload,
    }).await;
}
