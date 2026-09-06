//! Embedded peer-forwarder bridge.
//!
//! Runs the same str0m engine as the VPS forwarder inside a desktop app, so
//! STUN-reachable watchers with spare upload serve the TURN-only viewers and the
//! relay carries zero media in the common case. This module is the seam: it
//! feeds the engine from the swarm's Olm dispatch (envelopes arrive already
//! authenticated) and routes the engine's replies back out through our OWN
//! `fwd:{device_id}` room (deterministic-room rule, both directions).
//!
//! Trust model on top of the engine's own admission: `enabled` mirrors the
//! Settings toggle, and a `fwd_stream_register` is admitted only when its origin
//! matches a `(originator, kind)` pair this client advertised `fwd_capable` for
//! on a live `vc_screen_watch`, so a peer forwarder only ever forwards a stream
//! its user explicitly watches. The engine's spoof guard, owner checks,
//! allowlist and caps apply unchanged; there is NO token bucket, because a
//! silent drop is the class Hollow refuses. Refusals here are explicit
//! FwdErrors.
//!
//! The forwarder's OWN display is downstream viewer #0: `ForwarderSendSignal`
//! addressed to our own peer id short-circuits into the engine with no Olm
//! round-trip, and the leg is an ordinary UDP leg on the LAN address.
//!
//! Compiled only under `all(feature = "forwarder", not(android/ios))`; every
//! swarm call site carries the same cfg with a no-op else.

use std::collections::HashSet;
use std::sync::{Arc, RwLock};

use tokio::sync::mpsc;

use crate::forwarder::engine::{EngineCmd, OutSignal};
use crate::hollow_log;

use super::types::{MessageEnvelope, NetworkEvent, NodeCommand, MAX_SDP_SIZE};

pub(crate) struct EmbeddedForwarder {
    device_peer_id: String,
    enabled: bool,
    /// `(originator peer, kind)` pairs we advertised `fwd_capable` for.
    expectations: HashSet<(String, String)>,
    /// Live engine channel; `None` until the first admitted register (lazy)
    /// and after shutdown.
    engine_tx: Option<mpsc::UnboundedSender<EngineCmd>>,
    /// STUN server ("host:port") derived from the relay's TURN credential
    /// URIs — same infrastructure the direct lanes already trust.
    stun_server: Option<String>,
    /// Feeder election: forwarders we are FEEDING, keyed by their peer id.
    ///
    /// A feed leg is an ordinary egress leg whose "viewer" is another forwarder,
    /// because an egress leg's SendOnly OFFER is exactly what an ingest leg
    /// ANSWERS. Only the LABELS differ, and this set is what tells the out-pump
    /// to relabel and to route through the TARGET's room. Shared with that task.
    feed_targets: Arc<RwLock<HashSet<String>>>,
}

impl EmbeddedForwarder {
    pub(crate) fn new(device_peer_id: String) -> Self {
        Self {
            device_peer_id,
            enabled: false,
            expectations: HashSet::new(),
            engine_tx: None,
            stun_server: None,
            feed_targets: Arc::new(RwLock::new(HashSet::new())),
        }
    }

    fn fwd_room(&self) -> String {
        format!("fwd:{}", self.device_peer_id)
    }

    /// Settings toggle. Disabling tears the engine down (downstream viewers heal
    /// via the normal re-watch ladder) and leaves the fwd room; Dart stops
    /// advertising `fwd_capable` in the same breath.
    pub(crate) fn set_enabled(
        &mut self,
        enabled: bool,
        ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ) {
        if self.enabled == enabled {
            return;
        }
        self.enabled = enabled;
        hollow_log!("[HOLLOW-FWD] peer forwarding {}", if enabled { "enabled" } else { "disabled" });
        if !enabled {
            self.expectations.clear();
            self.shutdown_engine();
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom {
                room_code: self.fwd_room(),
            });
        }
    }

    /// Dart advertised (or withdrew) `fwd_capable` for `(origin_peer, kind)`.
    /// The first active expectation joins our own fwd room so a sharer can reach
    /// us the moment it picks us; the last one leaving tears everything down.
    pub(crate) fn set_expectation(
        &mut self,
        origin_peer: String,
        kind: String,
        active: bool,
        ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ) {
        if active {
            if !self.enabled {
                return;
            }
            let was_empty = self.expectations.is_empty();
            self.expectations.insert((origin_peer, kind));
            if was_empty {
                let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
                    room_code: self.fwd_room(),
                });
            }
        } else {
            self.expectations.remove(&(origin_peer, kind));
            if self.expectations.is_empty() {
                self.shutdown_engine();
                let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom {
                    room_code: self.fwd_room(),
                });
            }
        }
    }

    /// The relay's TURN credentials carry the STUN/TURN URIs — harvest a STUN
    /// address for the engine's srflx discovery. Refreshed on every connect.
    pub(crate) fn note_turn_uris(&mut self, uris: &[String]) {
        if let Some(stun) = stun_from_turn_uris(uris) {
            self.stun_server = Some(stun);
        }
    }

    /// Reconnect: the relay forgot our rooms — rejoin the fwd room if we have
    /// live expectations (media legs survive the signaling blip; the VPS
    /// forwarder does the same on its side).
    pub(crate) fn on_ws_connected(
        &self,
        ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ) {
        if self.enabled && !self.expectations.is_empty() {
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
                room_code: self.fwd_room(),
            });
        }
    }

    /// A forwarder-bound fwd envelope arrived over Olm. Returns `true` when
    /// the embedded engine consumed it — `false` falls through to the
    /// pre-phase-2 client ignore arm.
    pub(crate) fn handle_inbound(
        &mut self,
        sender: &str,
        envelope: MessageEnvelope,
        cmd_tx: &mpsc::Sender<NodeCommand>,
    ) -> bool {
        if !self.enabled {
            return false;
        }
        // The expectation gate applies to stream REGISTRATION only: every
        // other op needs a registered stream (engine owner/allowlist checks),
        // which can only exist if a register already passed this gate.
        if let MessageEnvelope::FwdStreamRegister { origin, .. } = &envelope {
            if !self.expectations.contains(&(origin.peer.clone(), origin.kind.clone())) {
                hollow_log!(
                    "[HOLLOW-FWD] register refused — no fwd_capable watch for that origin (from {sender})"
                );
                let refusal = MessageEnvelope::FwdError {
                    origin: origin.clone(),
                    code: "not_authorized".to_string(),
                    detail: "no capability advertised for this stream".to_string(),
                };
                let _ = cmd_tx.try_send(NodeCommand::EmbeddedForwarderOut {
                    to_peer: sender.to_string(),
                    envelope_json: serde_json::to_string(&refusal).unwrap_or_default(),
                    via_target_room: false,
                });
                return true;
            }
        }
        self.ensure_engine(cmd_tx);
        if let Some(tx) = &self.engine_tx {
            let _ = tx.send(EngineCmd::Signal {
                sender: sender.to_string(),
                envelope,
            });
        }
        true
    }

    /// `ForwarderSendSignal` addressed to OURSELVES — the forwarder's own
    /// display attaching to (or detaching from) its embedded engine. Builds
    /// through the same client whitelist and injects with no Olm round-trip.
    pub(crate) fn handle_self_signal(
        &mut self,
        signal_type: &str,
        payload: &str,
        cmd_tx: &mpsc::Sender<NodeCommand>,
    ) {
        let Some(envelope) = super::forwarder_client::build_fwd_signal_envelope(signal_type, payload)
        else {
            return;
        };
        if !self.enabled {
            hollow_log!("[HOLLOW-FWD] self {signal_type} while peer forwarding disabled — dropped");
            return;
        }
        self.ensure_engine(cmd_tx);
        if let Some(tx) = &self.engine_tx {
            let _ = tx.send(EngineCmd::Signal {
                sender: self.device_peer_id.clone(),
                envelope,
            });
        }
    }

    /// Feeder election: start (or stop) feeding `target_forwarder` with the
    /// stream identified by `origin`.
    ///
    /// Driven by the stream OWNER over `vc_screen_assign{feed_target}`: we only
    /// feed a stream we already forward, to a forwarder the owner named, and the
    /// engine's own admission still applies, so this grants no new authority.
    pub(crate) fn set_feed(
        &mut self,
        origin: Box<super::types::StreamOrigin>,
        target_forwarder: String,
        active: bool,
        cmd_tx: &mpsc::Sender<NodeCommand>,
    ) {
        if target_forwarder.is_empty() || target_forwarder == self.device_peer_id {
            return;
        }
        if active {
            if !self.enabled {
                hollow_log!("[HOLLOW-FWD] feed request while peer forwarding disabled — ignored");
                return;
            }
            self.ensure_engine(cmd_tx);
            if let Ok(mut t) = self.feed_targets.write() {
                t.insert(target_forwarder.clone());
            }
            hollow_log!("[HOLLOW-FWD] feeding forwarder {target_forwarder} (delegated by owner)");
            if let Some(tx) = &self.engine_tx {
                // An attach BY the target: the engine builds a SendOnly egress
                // leg whose offer the out-pump relabels into an ingest offer.
                let _ = tx.send(EngineCmd::Signal {
                    sender: target_forwarder,
                    envelope: MessageEnvelope::FwdAttach { origin },
                });
            }
        } else {
            if let Ok(mut t) = self.feed_targets.write() {
                t.remove(&target_forwarder);
            }
            hollow_log!("[HOLLOW-FWD] stopped feeding forwarder {target_forwarder}");
            if let Some(tx) = &self.engine_tx {
                let _ = tx.send(EngineCmd::Signal {
                    sender: target_forwarder,
                    envelope: MessageEnvelope::FwdDetach { origin },
                });
            }
        }
    }

    /// True when `peer` is a forwarder we are currently feeding, so the receive
    /// path routes its `fwd_ingest_answer` into OUR engine as the egress answer
    /// it structurally is, rather than surfacing it to Dart as our own ingest.
    pub(crate) fn is_feed_target(&self, peer: &str) -> bool {
        self.feed_targets
            .read()
            .map(|t| t.contains(peer))
            .unwrap_or(false)
    }

    /// A fed forwarder answered our (relabeled) ingest offer. Inject it as the
    /// egress answer the engine is waiting for. Returns false when it wasn't a
    /// feed answer after all.
    pub(crate) fn handle_feed_answer(&mut self, sender: &str, envelope: MessageEnvelope) -> bool {
        let MessageEnvelope::FwdIngestAnswer { origin, sdp } = envelope else {
            return false;
        };
        if !self.is_feed_target(sender) {
            return false;
        }
        if let Some(tx) = &self.engine_tx {
            let _ = tx.send(EngineCmd::Signal {
                sender: sender.to_string(),
                envelope: MessageEnvelope::FwdEgressAnswer { origin, sdp },
            });
            return true;
        }
        false
    }

    /// Peer presence lost (left our fwd room, or purged by an authoritative
    /// RoomMembers snapshot): their owned streams unregister, their egress
    /// legs detach — same semantics as the VPS signaling loop.
    pub(crate) fn peer_gone(&mut self, peer: &str) {
        if let Some(tx) = &self.engine_tx {
            let _ = tx.send(EngineCmd::PeerGone(peer.to_string()));
        }
    }

    fn ensure_engine(&mut self, cmd_tx: &mpsc::Sender<NodeCommand>) {
        if self.engine_tx.is_some() {
            return;
        }
        let (engine_tx, mut out_rx) = crate::forwarder::spawn_embedded_engine(self.stun_server.clone());
        if self.stun_server.is_none() {
            hollow_log!("[HOLLOW-FWD] embedded engine starting without STUN (no TURN uris seen yet)");
        }
        // Pump engine replies back into the swarm loop as commands; the
        // EmbeddedForwarderOut arm Olm-encrypts (or self-delivers) there,
        // where the OlmManager lives. Task ends when the engine drops out_tx.
        let cmd_tx = cmd_tx.clone();
        let feed_targets = self.feed_targets.clone();
        tokio::spawn(async move {
            while let Some(OutSignal { to_peer, envelope }) = out_rx.recv().await {
                // Feeder election: a reply addressed to a forwarder we FEED is
                // structurally an egress reply that must speak the ingest dialect
                // and ride the TARGET's room.
                let feeding = feed_targets
                    .read()
                    .map(|t| t.contains(&to_peer))
                    .unwrap_or(false);
                let envelope = if feeding {
                    match envelope {
                        MessageEnvelope::FwdEgressOffer { origin, sdp } => {
                            MessageEnvelope::FwdIngestOffer { origin, sdp }
                        }
                        other => other,
                    }
                } else {
                    envelope
                };
                let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();
                if cmd_tx
                    .send(NodeCommand::EmbeddedForwarderOut {
                        to_peer,
                        envelope_json,
                        via_target_room: feeding,
                    })
                    .await
                    .is_err()
                {
                    break;
                }
            }
        });
        self.engine_tx = Some(engine_tx);
    }

    fn shutdown_engine(&mut self) {
        if let Some(tx) = self.engine_tx.take() {
            // Shutdown drains every leg properly (plain drop would leak the
            // spawned pump tasks); dropping the sender afterwards ends the
            // engine loop and its out-pump.
            let _ = tx.send(EngineCmd::Shutdown);
        }
    }
}

/// `NodeCommand::EmbeddedForwarderOut` — deliver an engine reply. Self-bound
/// replies (our own display leg) become `ForwarderSignal` events directly;
/// everything else Olm-encrypts through our own fwd room.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_engine_out(
    olm: &mut crate::crypto::OlmManager,
    crypto_store: &crate::crypto::CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    pending_messages: &mut std::collections::HashMap<String, Vec<String>>,
    key_request_in_flight: &mut std::collections::HashMap<String, std::time::Instant>,
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    to_peer: String,
    envelope_json: String,
    via_target_room: bool,
) {
    if to_peer == device_peer_id {
        let Ok(envelope) = serde_json::from_str::<MessageEnvelope>(&envelope_json) else {
            return;
        };
        if let Some((signal_type, payload)) = fwd_signal_event(&envelope) {
            let _ = event_tx
                .send(NetworkEvent::ForwarderSignal {
                    from_peer: device_peer_id.to_string(),
                    signal_type: signal_type.to_string(),
                    payload,
                })
                .await;
        }
        return;
    }
    // Replies to our own viewers ride OUR room (they joined it to reach us); a
    // feed offer rides the TARGET forwarder's room. Both deterministic, never a
    // `ws_room_for_peer` lookup (the one-way-loss rule).
    let room = if via_target_room {
        format!("fwd:{to_peer}")
    } else {
        format!("fwd:{device_peer_id}")
    };
    let label = if via_target_room { "feed offer" } else { "engine reply" };
    super::forwarder_client::send_fwd_envelope_via_room(
        olm, crypto_store, event_tx, ws_cmd_tx, pending_messages, key_request_in_flight,
        device_keypair, device_peer_id, &room, to_peer, envelope_json, label,
    )
    .await;
}

/// Format a forwarder-sendable envelope the way the swarm's Olm receive arms do,
/// so a self-delivered engine reply is indistinguishable to Dart from a remote
/// forwarder's. SDP size never exceeds the cap: our own engine produced it.
fn fwd_signal_event(envelope: &MessageEnvelope) -> Option<(&'static str, String)> {
    match envelope {
        MessageEnvelope::FwdIngestAnswer { origin, sdp } if sdp.len() <= MAX_SDP_SIZE => Some((
            "fwd_ingest_answer",
            serde_json::json!({
                "origin": {"peer": origin.peer, "kind": origin.kind, "stream": origin.stream},
                "sdp": sdp,
            })
            .to_string(),
        )),
        MessageEnvelope::FwdEgressOffer { origin, sdp } if sdp.len() <= MAX_SDP_SIZE => Some((
            "fwd_egress_offer",
            serde_json::json!({
                "origin": {"peer": origin.peer, "kind": origin.kind, "stream": origin.stream},
                "sdp": sdp,
            })
            .to_string(),
        )),
        MessageEnvelope::FwdError { origin, code, detail } => Some((
            "fwd_error",
            serde_json::json!({
                "origin": {"peer": origin.peer, "kind": origin.kind, "stream": origin.stream},
                "code": code, "detail": detail,
            })
            .to_string(),
        )),
        _ => None,
    }
}

/// Harvest a STUN "host:port" from the relay's TURN credential URIs. Prefers an
/// explicit `stun:` URI, falls back to a `turn:` host on port 3478 (coturn
/// answers unauthenticated bindings there); a `turns:` host gives a hostname too.
fn stun_from_turn_uris(uris: &[String]) -> Option<String> {
    let host_of = |uri: &str| -> Option<(String, Option<u16>)> {
        let rest = uri
            .strip_prefix("stun:")
            .or_else(|| uri.strip_prefix("stuns:"))
            .or_else(|| uri.strip_prefix("turn:"))
            .or_else(|| uri.strip_prefix("turns:"))?;
        let rest = rest.split('?').next().unwrap_or(rest);
        match rest.rsplit_once(':') {
            Some((host, port)) => {
                let port = port.parse::<u16>().ok();
                Some((host.to_string(), port))
            }
            None => Some((rest.to_string(), None)),
        }
    };
    if let Some((host, port)) = uris
        .iter()
        .filter(|u| u.starts_with("stun"))
        .find_map(|u| host_of(u))
    {
        return Some(format!("{host}:{}", port.unwrap_or(3478)));
    }
    uris.iter()
        .find_map(|u| host_of(u))
        .map(|(host, _)| format!("{host}:3478"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stun_derivation_prefers_stun_uri_then_turn_host() {
        assert_eq!(
            stun_from_turn_uris(&["stun:relay.example.com:3478".into()]),
            Some("relay.example.com:3478".into())
        );
        assert_eq!(
            stun_from_turn_uris(&[
                "turn:relay.example.com:3478?transport=udp".into(),
                "turns:relay.example.com:5349?transport=tcp".into(),
            ]),
            Some("relay.example.com:3478".into())
        );
        assert_eq!(
            stun_from_turn_uris(&["turns:relay.example.com:5349?transport=tcp".into()]),
            Some("relay.example.com:3478".into())
        );
        assert_eq!(stun_from_turn_uris(&[]), None);
    }

    #[test]
    fn self_delivery_formats_match_the_olm_arms() {
        let env = MessageEnvelope::FwdError {
            origin: Box::new(super::super::types::StreamOrigin {
                peer: "p".into(),
                kind: "screen".into(),
                stream: "ab".into(),
            }),
            code: "full".into(),
            detail: "d".into(),
        };
        let (t, payload) = fwd_signal_event(&env).unwrap();
        assert_eq!(t, "fwd_error");
        let v: serde_json::Value = serde_json::from_str(&payload).unwrap();
        assert_eq!(v["origin"]["peer"], "p");
        assert_eq!(v["code"], "full");
        // Client-bound envelopes never self-deliver.
        let reg = MessageEnvelope::FwdAttach {
            origin: Box::new(super::super::types::StreamOrigin::default()),
        };
        assert!(fwd_signal_event(&reg).is_none());
    }
}
