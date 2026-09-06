//! Client-side media-forwarder control plane.
//!
//! Builds and sends the Olm-encrypted `fwd_*` envelopes a client exchanges with
//! a media forwarder in its dedicated `fwd:{peer_id}` relay room. The forwarder
//! is NOT a group member and never holds group keys, so this lane is
//! deliberately separate from the `vc_*` signal path.
//!
//! The first signal after joining races Olm key exchange, so a no-session send
//! queues in `pending_messages` and fires a throttled signed KeyRequest. Unlike
//! DMs there is NO re-queue after a successful send: replaying a stale
//! `fwd_ingest_offer` after a session re-establishment would open a bogus leg.

use std::collections::HashMap;

use tokio::sync::mpsc;

use super::crypto_handler::{
    persist_olm_session, send_message_to_peer_in_room, signed_key_request,
};
use super::types::{HavenMessage, MessageEnvelope, NetworkEvent, StreamOrigin, MAX_SDP_SIZE};
use crate::crypto::{CryptoStore, OlmManager};
use crate::hollow_log;

fn jstr(v: &serde_json::Value, key: &str) -> String {
    v[key].as_str().unwrap_or("").to_string()
}

fn jvec(v: &serde_json::Value, key: &str) -> Vec<String> {
    v[key]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|x| x.as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default()
}

/// Parse the REQUIRED `origin` sub-object of a fwd signal payload. Unlike the
/// vc lane (where absent = "sender is the originator", old-client compat), a
/// fwd signal without an origin addresses no stream — refuse to build it.
fn parse_required_origin(v: &serde_json::Value) -> Option<Box<StreamOrigin>> {
    let o = v.get("origin")?;
    if !o.is_object() {
        return None;
    }
    let origin = StreamOrigin {
        peer: jstr(o, "peer"),
        kind: jstr(o, "kind"),
        stream: jstr(o, "stream"),
    };
    if origin.peer.is_empty() {
        return None;
    }
    Some(Box::new(origin))
}

/// Build the outbound fwd control envelope. Signal types are WHITELISTED to the
/// client-sendable set; the forwarder-sendable types are deliberately absent.
/// Unknown type or malformed payload logs and yields `None`.
pub(crate) fn build_fwd_signal_envelope(
    signal_type: &str,
    payload: &str,
) -> Option<MessageEnvelope> {
    let v = serde_json::from_str::<serde_json::Value>(payload).ok()?;
    let origin = match parse_required_origin(&v) {
        Some(o) => o,
        None => {
            hollow_log!("[HOLLOW-FWD] {signal_type} payload missing origin — dropped");
            return None;
        }
    };
    let sdp_of = |v: &serde_json::Value| -> Option<String> {
        let sdp = jstr(v, "sdp");
        if sdp.is_empty() || sdp.len() > MAX_SDP_SIZE {
            hollow_log!(
                "[HOLLOW-FWD] {signal_type} SDP size {} out of bounds — dropped",
                sdp.len()
            );
            return None;
        }
        Some(sdp)
    };
    match signal_type {
        "fwd_stream_register" => Some(MessageEnvelope::FwdStreamRegister {
            origin,
            allowed_viewers: jvec(&v, "allowed_viewers"),
            low_viewers: jvec(&v, "low_viewers"),
            feeder: jstr(&v, "feeder"),
        }),
        "fwd_stream_auth" => Some(MessageEnvelope::FwdStreamAuth {
            origin,
            add: jvec(&v, "add"),
            remove: jvec(&v, "remove"),
        }),
        "fwd_stream_unregister" => Some(MessageEnvelope::FwdStreamUnregister { origin }),
        "fwd_ingest_offer" => sdp_of(&v).map(|sdp| MessageEnvelope::FwdIngestOffer { origin, sdp }),
        "fwd_attach" => Some(MessageEnvelope::FwdAttach { origin }),
        "fwd_detach" => Some(MessageEnvelope::FwdDetach { origin }),
        "fwd_egress_answer" => {
            sdp_of(&v).map(|sdp| MessageEnvelope::FwdEgressAnswer { origin, sdp })
        }
        // TEST-ONLY: the harness impersonates the FORWARDER role to drive the
        // client receive path over a real Olm session. Production forwarders run
        // their own signaling loop, never this FFI path.
        #[cfg(test)]
        "fwd_ingest_answer" => sdp_of(&v).map(|sdp| MessageEnvelope::FwdIngestAnswer { origin, sdp }),
        #[cfg(test)]
        "fwd_egress_offer" => sdp_of(&v).map(|sdp| MessageEnvelope::FwdEgressOffer { origin, sdp }),
        #[cfg(test)]
        "fwd_error" => Some(MessageEnvelope::FwdError {
            origin,
            code: jstr(&v, "code"),
            detail: jstr(&v, "detail"),
        }),
        _ => {
            hollow_log!("[HOLLOW-FWD] Unknown fwd signal type: {signal_type}");
            None
        }
    }
}

/// `NodeCommand::ForwarderSendSignal` — Olm-encrypt a fwd envelope to the
/// forwarder, or queue it + fire a signed KeyRequest when no session exists
/// yet (see module doc).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_forwarder_send_signal(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    key_request_in_flight: &mut HashMap<String, std::time::Instant>,
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    forwarder_peer_id: String,
    signal_type: String,
    payload: String,
) {
    let Some(envelope) = build_fwd_signal_envelope(&signal_type, &payload) else {
        return;
    };
    let env_json = serde_json::to_string(&envelope).unwrap_or_default();
    // The fwd lane has a DETERMINISTIC room, so route through it explicitly and
    // never `ws_room_for_peer` (the one-way-loss rule,
    // `feedback_dm_friend_establishment_bugs_2026_07`): the first signal of a
    // share is emitted before the relay's members snapshot reaches
    // `ws_room_peers`, so the lookup finds no shared room and drops it silently.
    let room = format!("fwd:{forwarder_peer_id}");
    send_fwd_envelope_via_room(
        olm, crypto_store, event_tx, ws_cmd_tx, pending_messages, key_request_in_flight,
        device_keypair, device_peer_id, &room, forwarder_peer_id, env_json, &signal_type,
    )
    .await;
}

/// Olm-encrypt an already-built fwd envelope to `target_peer` through an
/// explicit room, queueing and firing a throttled signed KeyRequest when no
/// session exists. Shared by the client path (room `fwd:{target}`) and the
/// embedded engine's replies (room `fwd:{our own device id}`).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn send_fwd_envelope_via_room(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    key_request_in_flight: &mut HashMap<String, std::time::Instant>,
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    room: &str,
    target_peer: String,
    env_json: String,
    label: &str,
) {
    if olm.has_session(&target_peer) {
        match olm.encrypt(&target_peer, env_json.as_bytes()) {
            Ok((msg_type, ciphertext)) => {
                persist_olm_session(olm, crypto_store, &target_peer);
                let haven = HavenMessage::Encrypted {
                    message_type: msg_type,
                    body: OlmManager::encode_base64(&ciphertext),
                    identity_key: if msg_type == 0 {
                        Some(olm.identity_key_base64())
                    } else {
                        None
                    },
                };
                let json = serde_json::to_string(&haven).unwrap_or_default();
                // Send-side observability: splits send-side from transit and
                // receive-side. Envelope TYPE and sizes only, never content.
                hollow_log!(
                    "[HOLLOW-FWD] send {label} -> {target_peer} via {room}: plain {} B, frame {} B, msg_type {msg_type}",
                    env_json.len(), json.len()
                );
                let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
                    room_code: room.to_string(),
                    target_peer,
                    data: json.into_bytes(),
                });
            }
            Err(e) => {
                hollow_log!("[HOLLOW-FWD] encrypt of {label} failed: {e}");
                let _ = event_tx
                    .send(NetworkEvent::MessageSendFailed {
                        to_peer: target_peer,
                        error: format!("Encryption failed: {e}"),
                    })
                    .await;
            }
        }
        return;
    }

    // No session yet: queue for the post-key-exchange drain and fire a throttled
    // signed KeyRequest. Unlike the DM path we KNOW the room, so the request goes
    // through it UNCONDITIONALLY rather than gated on our `ws_room_peers`
    // snapshot, which reports the forwarder offline in the just-joined window.
    pending_messages
        .entry(target_peer.clone())
        .or_default()
        .push(env_json);
    let req_fresh = key_request_in_flight
        .get(&target_peer)
        .is_some_and(|t| t.elapsed() < std::time::Duration::from_secs(10));
    if !req_fresh {
        hollow_log!(
            "[HOLLOW-FWD] No session for {target_peer}, queueing {label} + KeyRequest"
        );
        send_message_to_peer_in_room(
            ws_cmd_tx,
            room,
            &target_peer,
            signed_key_request(device_keypair, device_peer_id, &target_peer),
        );
        key_request_in_flight.insert(target_peer, std::time::Instant::now());
    }
}
