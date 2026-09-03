use std::collections::HashMap;

use tokio::sync::mpsc;

use super::crypto_handler::{peer_is_reachable, send_message_to_peer, send_raw_to_peer};
use super::types::*;

/// Handle a WebRTC broadcast received from a gossip neighbor.
/// Checks all overlays for the broadcast_id, and relays to gossip targets if TTL > 0.
pub(crate) async fn handle_webrtc_broadcast_received(
    gossip_overlays: &mut HashMap<String, super::gossip::GossipOverlay>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    webrtc_peers: &std::collections::HashSet<String>,
    broadcast_id: String,
    ttl: u8,
    origin_peer_id: String,
    sender_peer_id: String,
    temp_path: String,
    total_size: u64,
    kind: String,
    shard_index: u16,
) {
    // SECURITY (TRANSPORT-3): the TTL is a wire field. Unclamped, a neighbor
    // could hand us 255 and have the mesh forward the same broadcast 255 hops
    // deep. Cap it the way the BroadcastMeta path already does.
    let ttl = ttl.min(MAX_BROADCAST_TTL);

    // Find which server this broadcast belongs to by checking overlays.
    // For now, check all overlays for the broadcast_id.
    let mut relayed = false;
    for overlay in gossip_overlays.values_mut() {
        if overlay.should_relay_broadcast(&broadcast_id) {
            if ttl > 0 {
                let relay_targets = overlay.get_relay_targets(Some(&sender_peer_id));
                for target in &relay_targets {
                    if webrtc_peers.contains(target) {
                        let _ = event_tx.send(NetworkEvent::GossipRelayFile {
                            broadcast_id: broadcast_id.clone(),
                            ttl: ttl - 1,
                            origin_peer_id: origin_peer_id.clone(),
                            file_path: temp_path.clone(),
                            total_size,
                            kind: kind.clone(),
                            shard_index,
                            exclude_peer_id: sender_peer_id.clone(),
                            server_id: overlay.server_id.clone(),
                            channel_id: String::new(),
                        }).await;
                    }
                }
            }
            relayed = true;
            break;
        }
    }
    if !relayed {
        hollow_log!("[HOLLOW-GOSSIP] Broadcast {broadcast_id} already seen or no overlay, skipping relay");
    }
}

/// Tier 2 (large-server scaling, `reports/LARGE_SERVER_SCALING_2026.md`):
/// flood a plaintext CRDT op to this server's gossip neighbors over WebRTC
/// data channels instead of the relay. Returns the number of neighbors the
/// frame was dispatched to — 0 means the mesh isn't usable here (no overlay /
/// no live channels / oversized op) and the caller MUST fall back to the
/// relay path so the op still gets out.
///
/// Uses `try_send` so this stays callable from sync send helpers; a full
/// event channel returns 0 and the relay fallback carries the op instead.
pub(crate) fn flood_crdt_op(
    gossip_overlays: &mut HashMap<String, super::gossip::GossipOverlay>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    server_id: &str,
    op_json: &str,
    exclude_peer: Option<&str>,
) -> usize {
    let Some(overlay) = gossip_overlays.get_mut(server_id) else {
        return 0;
    };
    let targets = overlay.connected_relay_targets(exclude_peer);
    if targets.is_empty() {
        return 0;
    }
    let frame = super::gossip::GossipCrdtOp {
        broadcast_id: super::gossip::generate_broadcast_id(),
        server_id: server_id.to_string(),
        ttl: super::gossip::DEFAULT_BROADCAST_TTL,
        op_json: op_json.to_string(),
    };
    let payload = match serde_json::to_vec(&frame) {
        Ok(p) => p,
        Err(_) => return 0,
    };
    if payload.len() > super::gossip::MAX_GOSSIP_OP_BYTES {
        return 0;
    }
    overlay.mark_broadcast_seen(&frame.broadcast_id);
    let n = targets.len();
    match event_tx.try_send(NetworkEvent::GossipRelayOp { targets, payload }) {
        Ok(()) => {
            hollow_log!("[HOLLOW-GOSSIP] Flooded CRDT op for {server_id} to {n} mesh neighbor(s)");
            n
        }
        Err(_) => 0,
    }
}

/// Ingest gate for a gossip CRDT-op frame received on a data channel (0x04).
/// Parses + dedups by broadcast_id. Returns `Some((server_id, op_json))` when
/// the frame is fresh — the caller ingests it through the SAME validated path
/// as a relay `CrdtOpBroadcast` (permission checks on op.author, op_log dedup,
/// mesh re-flood gated on op-newness). A missing overlay still ingests: the
/// op_log dedups, and refusing would drop valid ops during overlay churn.
pub(crate) fn accept_gossip_op(
    gossip_overlays: &mut HashMap<String, super::gossip::GossipOverlay>,
    payload: &[u8],
) -> Option<(String, String)> {
    if payload.len() > super::gossip::MAX_GOSSIP_OP_BYTES {
        return None;
    }
    let frame: super::gossip::GossipCrdtOp = serde_json::from_slice(payload).ok()?;
    if let Some(overlay) = gossip_overlays.get_mut(&frame.server_id) {
        if !overlay.should_relay_broadcast(&frame.broadcast_id) {
            return None; // exact duplicate frame — already ingested
        }
    }
    Some((frame.server_id, frame.op_json))
}

/// Handle gossip overlay rotation timer tick.
/// Rotates neighbors for large servers and emits connect/disconnect events.
pub(crate) async fn handle_gossip_rotation(
    gossip_overlays: &mut HashMap<String, super::gossip::GossipOverlay>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    global_webrtc_count: usize,
) {
    for overlay in gossip_overlays.values_mut() {
        if overlay.known_peers.len() < super::gossip::GOSSIP_ACTIVATION_THRESHOLD {
            continue; // skip small servers
        }
        let (to_connect, to_disconnect) = overlay.rotate_with_budget(global_webrtc_count);
        for peer_id in to_connect {
            hollow_log!("[HOLLOW-GOSSIP] Rotation: connect to {peer_id} (server={})", overlay.server_id);
            let _ = event_tx.send(NetworkEvent::GossipConnect { peer_id }).await;
        }
        for peer_id in to_disconnect {
            hollow_log!("[HOLLOW-GOSSIP] Rotation: disconnect {peer_id} (server={})", overlay.server_id);
            let _ = event_tx.send(NetworkEvent::GossipDisconnect { peer_id }).await;
        }
    }
}

/// Handle gossip broadcast dedup eviction timer tick.
/// Evicts stale broadcasts and falls back to direct request for timed-out relays.
pub(crate) fn handle_gossip_eviction(
    gossip_overlays: &mut HashMap<String, super::gossip::GossipOverlay>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) {
    for overlay in gossip_overlays.values_mut() {
        // Check for timed-out pending relays — file didn't arrive via gossip.
        let timed_out = overlay.get_timed_out_relays();
        for file_id in &timed_out {
            if let Some(relay) = overlay.pending_relays.get(file_id) {
                hollow_log!(
                    "[HOLLOW-GOSSIP] Broadcast timeout for file {} (bid={}) — requesting directly from origin {}",
                    file_id, relay.broadcast_id, relay.origin
                );
                // Fall back: request the file from the origin via normal FileRequest.
                if peer_is_reachable(ws_room_peers, &relay.origin) {
                    send_message_to_peer(
                        ws_cmd_tx, ws_room_peers,
                        &relay.origin,
                        HavenMessage::FileProbe { file_id: file_id.clone() },
                    );
                }
            }
        }
        overlay.evict_stale_broadcasts();
    }
}

/// Handle gossip peer exchange timer tick.
/// Sends neighbor list only to gossip neighbors (not the entire room).
pub(crate) fn handle_gossip_exchange(
    gossip_overlays: &HashMap<String, super::gossip::GossipOverlay>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) {
    for overlay in gossip_overlays.values() {
        if overlay.neighbors.is_empty() { continue; }
        let peers_list: Vec<String> = overlay.neighbors.iter().cloned().collect();
        let msg = HavenMessage::PeerExchange {
            server_id: overlay.server_id.clone(),
            peers: peers_list,
        };
        let data = serde_json::to_vec(&msg).unwrap_or_default();
        for neighbor in &overlay.neighbors {
            if peer_is_reachable(ws_room_peers, neighbor) {
                send_raw_to_peer(ws_cmd_tx, ws_room_peers, neighbor, data.clone());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// TRANSPORT-3 regression: a neighbor sets the hop count, so a relay that
    /// forwarded `ttl - 1` verbatim would carry a broadcast 255 hops deep on
    /// one peer's say-so. What we forward is bounded by our own ceiling.
    #[tokio::test]
    async fn webrtc_broadcast_ttl_is_clamped() {
        const NEIGHBOR: &str = "12D3KooW-relay-neighbor";
        const SENDER: &str = "12D3KooW-gossip-sender";

        let mut overlay = super::super::gossip::GossipOverlay::new("srv-ttl".into());
        overlay.neighbors.insert(NEIGHBOR.to_string());
        let mut overlays = HashMap::from([("srv-ttl".to_string(), overlay)]);

        let (event_tx, mut event_rx) = mpsc::channel(8);
        let webrtc_peers = std::collections::HashSet::from([NEIGHBOR.to_string()]);

        handle_webrtc_broadcast_received(
            &mut overlays,
            &event_tx,
            &webrtc_peers,
            "bcast-ttl-1".to_string(),
            u8::MAX,
            "12D3KooW-origin".to_string(),
            SENDER.to_string(),
            "/tmp/does-not-need-to-exist".to_string(),
            1024,
            "file".to_string(),
            0,
        )
        .await;

        let ev = event_rx.try_recv().expect("a reachable neighbor gets a relay event");
        let NetworkEvent::GossipRelayFile { ttl, .. } = ev else {
            panic!("expected a GossipRelayFile event");
        };
        assert!(
            ttl < MAX_BROADCAST_TTL,
            "relayed ttl {ttl} must be under MAX_BROADCAST_TTL ({MAX_BROADCAST_TTL})",
        );
    }
}
