use std::collections::HashMap;

use tokio::sync::mpsc;

use crate::crdt::server_state::ServerState;
use crate::crypto::{MlsManager, OlmManager, CryptoStore};
use crate::identity::native_identity::NativeKeypair;
use super::crypto_handler::{
    peer_is_reachable, send_mls_broadcast,
    send_encrypted_message, send_message_to_peer, send_raw_to_peer,
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
        _ => {
            hollow_log!("[HOLLOW-WEBRTC] Unknown signal type: {signal_type}");
            return;
        }
    };
    send_message_to_peer(ws_cmd_tx, ws_room_peers, &peer_id, msg);
}

// ── CallSendSignal ───────────────────────────────────────────────────

pub(crate) fn handle_call_send_signal(
    peer_id: String,
    signal_type: String,
    payload: String,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) {
    let msg = match signal_type.as_str() {
        "invite" => {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) {
                HavenMessage::CallInvite {
                    call_id: v["call_id"].as_str().unwrap_or("").to_string(),
                    video: v["video"].as_bool().unwrap_or(false),
                    sframe_key: v["sframe_key"].as_str().unwrap_or("").to_string(),
                }
            } else {
                HavenMessage::CallInvite { call_id: payload, video: false, sframe_key: String::new() }
            }
        }
        "accept" => {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) {
                HavenMessage::CallAccept {
                    call_id: v["call_id"].as_str().unwrap_or(&payload).to_string(),
                    sframe_key: v["sframe_key"].as_str().unwrap_or("").to_string(),
                }
            } else {
                HavenMessage::CallAccept { call_id: payload, sframe_key: String::new() }
            }
        }
        "reject" => HavenMessage::CallReject { call_id: payload },
        "end" => HavenMessage::CallEnd { call_id: payload },
        "busy" => HavenMessage::CallBusy { call_id: payload },
        "sdp_offer" => {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) {
                HavenMessage::CallSdpOffer {
                    call_id: v["call_id"].as_str().unwrap_or("").to_string(),
                    sdp: v["sdp"].as_str().unwrap_or("").to_string(),
                }
            } else {
                hollow_log!("[HOLLOW-CALL] Failed to parse sdp_offer payload");
                return;
            }
        }
        "sdp_answer" => {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) {
                HavenMessage::CallSdpAnswer {
                    call_id: v["call_id"].as_str().unwrap_or("").to_string(),
                    sdp: v["sdp"].as_str().unwrap_or("").to_string(),
                }
            } else {
                hollow_log!("[HOLLOW-CALL] Failed to parse sdp_answer payload");
                return;
            }
        }
        "ice" => {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) {
                HavenMessage::CallIceCandidate {
                    call_id: v["call_id"].as_str().unwrap_or("").to_string(),
                    candidate: v["candidate"].as_str().unwrap_or("").to_string(),
                    sdp_mid: v["sdpMid"].as_str().unwrap_or("").to_string(),
                    sdp_mline_index: v["sdpMLineIndex"].as_u64().unwrap_or(0) as u32,
                }
            } else {
                hollow_log!("[HOLLOW-CALL] Failed to parse ICE payload");
                return;
            }
        }
        "video_state" => {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) {
                HavenMessage::CallVideoState {
                    call_id: v["call_id"].as_str().unwrap_or("").to_string(),
                    enabled: v["enabled"].as_bool().unwrap_or(false),
                }
            } else {
                hollow_log!("[HOLLOW-CALL] Failed to parse video_state payload");
                return;
            }
        }
        "audio_state" => {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) {
                HavenMessage::CallAudioState {
                    call_id: v["call_id"].as_str().unwrap_or("").to_string(),
                    muted: v["muted"].as_bool().unwrap_or(false),
                    deafened: v["deafened"].as_bool().unwrap_or(false),
                }
            } else {
                hollow_log!("[HOLLOW-CALL] Failed to parse audio_state payload");
                return;
            }
        }
        "screen_state" => {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) {
                HavenMessage::CallScreenState {
                    call_id: v["call_id"].as_str().unwrap_or("").to_string(),
                    enabled: v["enabled"].as_bool().unwrap_or(false),
                    quality: v["quality"].as_str().map(|s| s.to_string()),
                }
            } else {
                hollow_log!("[HOLLOW-CALL] Failed to parse screen_state payload");
                return;
            }
        }
        "screen_offer" => {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) {
                HavenMessage::CallScreenOffer {
                    call_id: v["call_id"].as_str().unwrap_or("").to_string(),
                    sdp: v["sdp"].as_str().unwrap_or("").to_string(),
                }
            } else {
                hollow_log!("[HOLLOW-CALL] Failed to parse screen_offer payload");
                return;
            }
        }
        "screen_answer" => {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) {
                HavenMessage::CallScreenAnswer {
                    call_id: v["call_id"].as_str().unwrap_or("").to_string(),
                    sdp: v["sdp"].as_str().unwrap_or("").to_string(),
                }
            } else {
                hollow_log!("[HOLLOW-CALL] Failed to parse screen_answer payload");
                return;
            }
        }
        "screen_ice" => {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) {
                HavenMessage::CallScreenIce {
                    call_id: v["call_id"].as_str().unwrap_or("").to_string(),
                    candidate: v["candidate"].as_str().unwrap_or("").to_string(),
                    sdp_mid: v["sdpMid"].as_str().unwrap_or("").to_string(),
                    sdp_mline_index: v["sdpMLineIndex"].as_u64().unwrap_or(0) as u32,
                    role: v["role"].as_str().unwrap_or("").to_string(),
                }
            } else {
                hollow_log!("[HOLLOW-CALL] Failed to parse screen_ice payload");
                return;
            }
        }
        _ => {
            hollow_log!("[HOLLOW-CALL] Unknown call signal type: {signal_type}");
            return;
        }
    };
    send_message_to_peer(ws_cmd_tx, ws_room_peers, &peer_id, msg);
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
    // MLS broadcast + always plaintext — voice joins must arrive even with stale MLS epochs.
    let envelope = MessageEnvelope::VoiceChannelJoin {
        sid: server_id.clone(),
        cid: channel_id.clone(),
    };
    let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
    if mls_ok {
        let _ = send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &envelope, crypto_store);
    }
    if let Some(state) = server_states.get(&server_id) {
        let local_peer = local_peer_str.to_string();
        for member in state.members.keys() {
            if member == &local_peer { continue; }
            if peer_is_reachable(ws_room_peers, member) {
                send_message_to_peer(ws_cmd_tx, ws_room_peers, member, HavenMessage::VoiceChannelJoin {
                    server_id: server_id.clone(), channel_id: channel_id.clone(),
                });
            }
        }
    }
    // Track participant.
    let vc_key = format!("{}:{}", server_id, channel_id);
    voice_channel_participants.entry(vc_key.clone()).or_default()
        .insert(local_peer_str.to_string());
    // Emit current MLS epoch key BEFORE the join event — Dart caches it,
    // then applies it after creating the VoiceChannelService.
    match mls.as_ref() {
        Some(mls_mgr) => {
            let has_group = mls_mgr.has_group(&server_id);
            hollow_log!("[HOLLOW-VC-SFRAME] MLS exists, has_group({server_id})={has_group}");
            if has_group {
                match mls_mgr.export_secret(&server_id, "sframe", b"", 32) {
                    Ok(sframe_key) => {
                        let epoch = mls_mgr.epoch(&server_id).unwrap_or(0);
                        hollow_log!("[HOLLOW-VC-SFRAME] Emitting SFrame key for epoch {epoch}");
                        let _ = event_tx.send(NetworkEvent::MlsEpochChanged {
                            server_id: server_id.clone(), epoch, sframe_key,
                        }).await;
                    }
                    Err(e) => hollow_log!("[HOLLOW-VC-SFRAME] export_secret FAILED: {e}"),
                }
            }
        }
        None => hollow_log!("[HOLLOW-VC-SFRAME] MLS is None — no SFrame key"),
    }
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
    let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
    if mls_ok {
        let _ = send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &envelope, crypto_store);
    }
    if let Some(state) = server_states.get(&server_id) {
        let local_peer = local_peer_str.to_string();
        for member in state.members.keys() {
            if member == &local_peer { continue; }
            if peer_is_reachable(ws_room_peers, member) {
                send_message_to_peer(ws_cmd_tx, ws_room_peers, member, HavenMessage::VoiceChannelLeave {
                    server_id: server_id.clone(), channel_id: channel_id.clone(),
                });
            }
        }
    }
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
    let envelope = match signal_type.as_str() {
        "sdp_offer" => {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) {
                MessageEnvelope::VoiceChannelSdpOffer {
                    sid: server_id.clone(),
                    cid: channel_id.clone(),
                    sdp: v["sdp"].as_str().unwrap_or("").to_string(),
                    target: None,
                }
            } else { return; }
        }
        "sdp_answer" => {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) {
                MessageEnvelope::VoiceChannelSdpAnswer {
                    sid: server_id.clone(),
                    cid: channel_id.clone(),
                    sdp: v["sdp"].as_str().unwrap_or("").to_string(),
                    target: None,
                }
            } else { return; }
        }
        "ice" => {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) {
                MessageEnvelope::VoiceChannelIce {
                    sid: server_id.clone(),
                    cid: channel_id.clone(),
                    candidate: v["candidate"].as_str().unwrap_or("").to_string(),
                    sdp_mid: v["sdpMid"].as_str().unwrap_or("").to_string(),
                    sdp_mline_index: v["sdpMLineIndex"].as_u64().unwrap_or(0) as u32,
                    target: None,
                }
            } else { return; }
        }
        "audio_state" => {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) {
                MessageEnvelope::VoiceChannelAudioState {
                    sid: server_id.clone(),
                    cid: channel_id.clone(),
                    muted: v["muted"].as_bool().unwrap_or(false),
                    deafened: v["deafened"].as_bool().unwrap_or(false),
                    target: None,
                }
            } else { return; }
        }
        "screen_offer" => {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) {
                MessageEnvelope::VoiceChannelScreenOffer {
                    sid: server_id.clone(),
                    cid: channel_id.clone(),
                    sdp: v["sdp"].as_str().unwrap_or("").to_string(),
                    target: None,
                }
            } else { return; }
        }
        "screen_answer" => {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) {
                MessageEnvelope::VoiceChannelScreenAnswer {
                    sid: server_id.clone(),
                    cid: channel_id.clone(),
                    sdp: v["sdp"].as_str().unwrap_or("").to_string(),
                    target: None,
                }
            } else { return; }
        }
        "screen_ice" => {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) {
                MessageEnvelope::VoiceChannelScreenIce {
                    sid: server_id.clone(),
                    cid: channel_id.clone(),
                    candidate: v["candidate"].as_str().unwrap_or("").to_string(),
                    sdp_mid: v["sdpMid"].as_str().unwrap_or("").to_string(),
                    sdp_mline_index: v["sdpMLineIndex"].as_u64().unwrap_or(0) as u32,
                    role: v["role"].as_str().unwrap_or("").to_string(),
                    target: None,
                }
            } else { return; }
        }
        "screen_state" => {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) {
                MessageEnvelope::VoiceChannelScreenState {
                    sid: server_id.clone(),
                    cid: channel_id.clone(),
                    enabled: v["enabled"].as_bool().unwrap_or(false),
                    target: None,
                    quality: v["quality"].as_str().map(|s| s.to_string()),
                }
            } else { return; }
        }
        "reneg_offer" => {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) {
                MessageEnvelope::VoiceChannelRenegOffer {
                    sid: server_id.clone(),
                    cid: channel_id.clone(),
                    sdp: v["sdp"].as_str().unwrap_or("").to_string(),
                    target: None,
                }
            } else { return; }
        }
        "reneg_answer" => {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) {
                MessageEnvelope::VoiceChannelRenegAnswer {
                    sid: server_id.clone(),
                    cid: channel_id.clone(),
                    sdp: v["sdp"].as_str().unwrap_or("").to_string(),
                    target: None,
                }
            } else { return; }
        }
        "camera_state" => {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) {
                MessageEnvelope::VoiceChannelCameraState {
                    sid: server_id.clone(),
                    cid: channel_id.clone(),
                    enabled: v["enabled"].as_bool().unwrap_or(false),
                    target: None,
                }
            } else { return; }
        }
        _ => {
            hollow_log!("[HOLLOW-VC] Unknown signal type: {signal_type}");
            return;
        }
    };
    // Broadcast state signals (audio/screen/camera state) → MLS broadcast + plaintext fallback.
    // Targeted SDP/ICE signals → MLS targeted + Olm fallback (IPs are sensitive).
    let is_broadcast = matches!(signal_type.as_str(), "audio_state" | "screen_state" | "camera_state");
    let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));

    if is_broadcast {
        let mls_sent = mls_ok && send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &envelope, crypto_store).is_ok();
        if !mls_sent {
            // Plaintext fallback: iterate members.
            let plaintext_msg = match signal_type.as_str() {
                "audio_state" => {
                    if let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) {
                        Some(HavenMessage::VoiceChannelAudioState {
                            server_id: server_id.clone(), channel_id: channel_id.clone(),
                            muted: v["muted"].as_bool().unwrap_or(false),
                            deafened: v["deafened"].as_bool().unwrap_or(false),
                        })
                    } else { None }
                }
                "screen_state" => {
                    if let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) {
                        Some(HavenMessage::VoiceChannelScreenState {
                            server_id: server_id.clone(), channel_id: channel_id.clone(),
                            enabled: v["enabled"].as_bool().unwrap_or(false),
                            quality: v["quality"].as_str().map(|s| s.to_string()),
                        })
                    } else { None }
                }
                "camera_state" => {
                    if let Ok(v) = serde_json::from_str::<serde_json::Value>(&payload) {
                        Some(HavenMessage::VoiceChannelCameraState {
                            server_id: server_id.clone(), channel_id: channel_id.clone(),
                            enabled: v["enabled"].as_bool().unwrap_or(false),
                        })
                    } else { None }
                }
                _ => None,
            };
            if let Some(msg) = plaintext_msg
                && let Some(state) = server_states.get(&server_id)
            {
                let local_peer = local_peer_str.to_string();
                let data = serde_json::to_vec(&msg).unwrap_or_default();
                for member in state.members.keys() {
                    if member == &local_peer { continue; }
                    if peer_is_reachable(ws_room_peers, member) {
                        send_raw_to_peer(ws_cmd_tx, ws_room_peers, member, data.clone());
                    }
                }
            }
        }
    } else {
        // Targeted SDP/ICE: Olm encrypted + SendDirect.
        let env_json = serde_json::to_string(&envelope).unwrap_or_default();
        send_encrypted_message(olm, crypto_store, &peer_id, &env_json, event_tx, ws_cmd_tx, ws_room_peers).await;
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
    event_tx: &mpsc::Sender<NetworkEvent>,
    local_peer_str: &str,
    sender_peer_id: String,
    sid: String,
    cid: String,
) {
    if sender_peer_id == local_peer_str { return; }
    let is_member = server_states.get(&sid)
        .map(|s| s.members.contains_key(&sender_peer_id))
        .unwrap_or(false);
    let is_voice_channel = server_states.get(&sid)
        .and_then(|s| s.channels.get(&cid))
        .map(|ch| ch.channel_type == crate::crdt::server_state::ChannelType::Voice)
        .unwrap_or(false);
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
