use std::collections::{HashMap, HashSet};
use std::time::Instant;

use serde::{Deserialize, Serialize};

// ── Constants ────────────────────────────────────────────────────────────────

/// Minimum gossip neighbors per server overlay.
pub const MIN_GOSSIP_NEIGHBORS: usize = 6;

/// Maximum gossip neighbors per server overlay.
pub const MAX_GOSSIP_NEIGHBORS: usize = 12;

/// Global cap on total WebRTC data channel connections across all servers.
pub const MAX_TOTAL_WEBRTC: usize = 50;

/// How often to rotate gossip neighbors (seconds).
pub const ROTATION_INTERVAL_SECS: u64 = 300; // 5 minutes

/// How long to keep broadcast IDs in the dedup cache (seconds).
pub const BROADCAST_DEDUP_TTL_SECS: u64 = 60;

/// Server member count at which the gossip overlay activates.
pub const GOSSIP_ACTIVATION_THRESHOLD: usize = 6;

/// Default broadcast TTL (max hops).
pub const DEFAULT_BROADCAST_TTL: u8 = 4;

/// Voice channel: switch to gossip mode at this participant count.
pub const VOICE_GOSSIP_THRESHOLD_UP: usize = 6;

/// Voice channel: switch back to mesh mode at this participant count (hysteresis).
pub const VOICE_GOSSIP_THRESHOLD_DOWN: usize = 4;

/// How long to wait for gossip file data before falling back to direct request (seconds).
pub const BROADCAST_FALLBACK_TIMEOUT_SECS: u64 = 30;

/// Adaptive gossip exchange interval based on max server member count.
pub fn gossip_exchange_interval_secs(max_member_count: usize) -> u64 {
    match max_member_count {
        0..=99 => 120,
        100..=499 => 180,
        _ => 240,
    }
}

/// Max serialized `GossipCrdtOp` payload the mesh will carry in one frame.
/// CRDT ops are typically well under 2 KB; anything bigger falls back to the
/// relay path rather than fighting the data channel's chunking conventions.
pub const MAX_GOSSIP_OP_BYTES: usize = 15_000;

// ── Small-message gossip frame (Tier 2 large-server scaling) ────────────────

/// Wire frame for a CRDT op flooded over the WebRTC data-channel mesh
/// (type byte 0x04 on 'hollow-data'). See `reports/LARGE_SERVER_SCALING_2026.md`.
///
/// Propagation model: a receiving node re-floods ONLY when the op was NEW to
/// its own op_log (validated + applied first), so each node forwards a given
/// op at most once — the flood is bounded by op-newness, not by `ttl`.
/// `broadcast_id` suppresses re-ingest of exact duplicate frames; `ttl` is a
/// reserved safety bound carried on the wire.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GossipCrdtOp {
    pub broadcast_id: String,
    pub server_id: String,
    pub ttl: u8,
    pub op_json: String,
}

// ── Peer Scoring ─────────────────────────────────────────────────────────────

/// Scoring data for a known peer in a server overlay.
#[derive(Debug, Clone)]
pub struct PeerScore {
    /// Connection uptime ratio (0.0-1.0). Tracks how long peer stays connected.
    pub uptime_ratio: f64,
    /// Average RTT in ms (from data channel keepalive ping).
    pub avg_latency_ms: f64,
    /// Bandwidth score (bytes/sec observed throughput from file transfers).
    pub bandwidth_score: f64,
    /// Number of vault shards this peer holds that we recently accessed.
    pub shard_overlap: u32,
    /// ICE route reachability (Tier 3, `reports/LARGE_SERVER_SCALING_2026.md`):
    /// `Some(true)` = direct route (host/srflx/LAN), `Some(false)` = TURN-relayed,
    /// `None` = not yet measured. Reported by Dart from `getStats()` once per
    /// connection. Direct peers are preferred neighbors — a TURN-relayed mesh
    /// "offload" still burns relay-class bandwidth.
    pub is_direct: Option<bool>,
    /// When this peer's data channel connected (None if not currently connected).
    pub connected_since: Option<Instant>,
    /// Total time connected (accumulated across sessions).
    pub total_connected_secs: f64,
    /// Total time tracked (connected + disconnected).
    pub total_tracked_secs: f64,
    /// When we last updated this score.
    pub last_updated: Instant,
}

impl PeerScore {
    pub fn new() -> Self {
        let now = Instant::now();
        Self {
            uptime_ratio: 0.0,
            avg_latency_ms: 100.0, // default assumption
            bandwidth_score: 0.0,
            shard_overlap: 0,
            is_direct: None,
            connected_since: None,
            total_connected_secs: 0.0,
            total_tracked_secs: 0.0,
            last_updated: now,
        }
    }

    /// Composite score: higher is better. Used for neighbor selection & rotation.
    ///
    /// Weights:
    /// - Shard overlap is heavily weighted (priority connections for vault)
    /// - Low latency is important for real-time (voice, fast file delivery)
    /// - Uptime matters for reliability
    /// - Bandwidth matters for file transfers
    pub fn composite(&self) -> f64 {
        let latency_score = if self.avg_latency_ms > 0.0 {
            // Invert: lower latency = higher score. Cap at 500ms.
            1.0 - (self.avg_latency_ms / 500.0).min(1.0)
        } else {
            0.5 // unknown
        };

        let bw_score = (self.bandwidth_score / 10_000_000.0).min(1.0); // normalize to 10 MB/s

        // Reachability (Tier 3): known-direct > unmeasured > TURN-relayed.
        // The neutral midpoint keeps unmeasured peers from being starved of
        // the connection they need to GET measured; the ±0.075 spread clears
        // the rotation's 10% improvement margin for otherwise-similar peers,
        // so the mesh drifts toward directly-reachable neighbors.
        let reach_score = match self.is_direct {
            Some(true) => 0.15,
            None => 0.075,
            Some(false) => 0.0,
        };

        // Weights: shard_overlap(0.10 each) + latency(30%) + uptime(20%)
        //          + bandwidth(10%) + reachability(15%)
        (self.shard_overlap as f64 * 0.10) // each shard overlap adds 0.10
            + latency_score * 0.30
            + self.uptime_ratio * 0.20
            + bw_score * 0.10
            + reach_score
    }

    /// Update uptime ratio based on accumulated tracking time.
    pub fn refresh_uptime(&mut self) {
        let now = Instant::now();
        let elapsed = now.duration_since(self.last_updated).as_secs_f64();
        self.total_tracked_secs += elapsed;
        if self.connected_since.is_some() {
            self.total_connected_secs += elapsed;
        }
        if self.total_tracked_secs > 0.0 {
            self.uptime_ratio = self.total_connected_secs / self.total_tracked_secs;
        }
        self.last_updated = now;
    }

    /// Record that this peer's data channel connected.
    pub fn mark_connected(&mut self) {
        self.refresh_uptime();
        self.connected_since = Some(Instant::now());
    }

    /// Record that this peer's data channel disconnected.
    pub fn mark_disconnected(&mut self) {
        self.refresh_uptime();
        self.connected_since = None;
    }

    /// Update latency with exponential moving average (alpha=0.3).
    pub fn update_latency(&mut self, rtt_ms: u32) {
        const ALPHA: f64 = 0.3;
        self.avg_latency_ms = ALPHA * (rtt_ms as f64) + (1.0 - ALPHA) * self.avg_latency_ms;
    }

    /// Update bandwidth score from a completed transfer.
    pub fn update_bandwidth(&mut self, bytes: u64, duration_secs: f64) {
        if duration_secs > 0.0 {
            let throughput = bytes as f64 / duration_secs;
            const ALPHA: f64 = 0.3;
            self.bandwidth_score = ALPHA * throughput + (1.0 - ALPHA) * self.bandwidth_score;
        }
    }
}

// ── Gossip Overlay ───────────────────────────────────────────────────────────

/// Info about a broadcast file that we received via MLS but haven't yet
/// received the actual file data for. Once the file arrives via data channel,
/// we relay it to our gossip neighbors.
#[derive(Debug, Clone)]
pub struct PendingRelay {
    pub broadcast_id: String,
    pub file_id: String,
    pub ttl: u8,
    pub origin: String,
    pub channel_id: String,
    pub sender_peer_id: String,
    pub created: Instant,
}

/// Per-server gossip overlay state.
///
/// Manages which peers we maintain WebRTC data channels with (our "gossip
/// neighbors"), peer scoring for selection/rotation, and broadcast dedup.
#[derive(Debug)]
pub struct GossipOverlay {
    pub server_id: String,
    /// Peers we should have WebRTC data channels with (our gossip neighbors).
    pub neighbors: HashSet<String>,
    /// All known online peers for this server (superset of neighbors).
    pub known_peers: HashSet<String>,
    /// Peer scoring data.
    pub peer_scores: HashMap<String, PeerScore>,
    /// Broadcast dedup cache: broadcast_id -> first_seen time.
    seen_broadcasts: HashMap<String, Instant>,
    /// Pending relay: file_id -> PendingRelay.
    /// Populated when BroadcastMeta arrives via MLS. Consumed when the
    /// actual file data arrives via data channel (WebRtcTransferComplete).
    pub pending_relays: HashMap<String, PendingRelay>,
    /// Last rotation timestamp.
    pub last_rotation: Instant,
}

impl GossipOverlay {
    pub fn new(server_id: String) -> Self {
        Self {
            server_id,
            neighbors: HashSet::new(),
            known_peers: HashSet::new(),
            peer_scores: HashMap::new(),
            seen_broadcasts: HashMap::new(),
            pending_relays: HashMap::new(),
            last_rotation: Instant::now(),
        }
    }

    /// Register a peer as online in this server.
    /// Returns `Some(peer_id)` if this peer should become a new neighbor.
    pub fn add_known_peer(&mut self, peer_id: &str) -> Option<String> {
        let owned = peer_id.to_string();
        self.known_peers.insert(owned.clone());
        self.peer_scores
            .entry(owned.clone())
            .or_insert_with(PeerScore::new);

        if self.neighbors.len() < MIN_GOSSIP_NEIGHBORS
            && !self.neighbors.contains(peer_id)
        {
            self.neighbors.insert(owned.clone());
            return Some(owned);
        }

        None
    }

    /// Remove a peer from the known set (they went offline).
    /// Returns `Some(replacement_peer_id)` if a neighbor was lost and replaced.
    pub fn remove_known_peer(
        &mut self,
        peer_id: &str,
    ) -> (bool, Option<String>) {
        self.known_peers.remove(peer_id);

        let was_neighbor = self.neighbors.remove(peer_id);

        if was_neighbor {
            // Pick a replacement from known_peers that isn't already a neighbor.
            let replacement = self.pick_best_non_neighbor();
            if let Some(ref repl) = replacement {
                self.neighbors.insert(repl.clone());
            }
            (true, replacement)
        } else {
            (false, None)
        }
    }

    /// Select initial neighbors when the overlay is first created.
    /// Picks the best-scoring peers up to MAX_GOSSIP_NEIGHBORS, respecting the
    /// global WebRTC cap as a hard limit.
    pub fn select_initial_neighbors(
        &mut self,
        global_webrtc_count: usize,
    ) -> Vec<String> {
        let budget = MAX_TOTAL_WEBRTC.saturating_sub(global_webrtc_count);
        if budget == 0 {
            return Vec::new();
        }
        let target = budget
            .min(MAX_GOSSIP_NEIGHBORS)
            .max(MIN_GOSSIP_NEIGHBORS.min(budget))
            .min(self.known_peers.len());

        let mut candidates: Vec<_> = self
            .known_peers
            .iter()
            .map(|p| {
                let score = self
                    .peer_scores
                    .get(p)
                    .map(|s| s.composite())
                    .unwrap_or(0.0);
                (p.clone(), score)
            })
            .collect();

        // Sort by score descending.
        candidates.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

        let selected: Vec<String> = candidates.into_iter().take(target).map(|(p, _)| p).collect();

        self.neighbors = selected.iter().cloned().collect();
        selected
    }

    /// Periodic rotation: drop lowest-scoring neighbor, connect highest-scoring
    /// non-neighbor. Max 1 swap per call for stability.
    ///
    /// Returns `(to_connect, to_disconnect)`.
    pub fn rotate_with_budget(&mut self, global_webrtc_count: usize) -> (Vec<String>, Vec<String>) {
        self.last_rotation = Instant::now();

        // Refresh uptime for all scored peers.
        for score in self.peer_scores.values_mut() {
            score.refresh_uptime();
        }

        let mut to_connect = Vec::new();
        let mut to_disconnect = Vec::new();

        // If under minimum, fill up — but respect the global WebRTC cap.
        let budget = MAX_TOTAL_WEBRTC.saturating_sub(global_webrtc_count);
        let fill_target = MIN_GOSSIP_NEIGHBORS.min(self.neighbors.len() + budget);
        while self.neighbors.len() < fill_target {
            if let Some(peer) = self.pick_best_non_neighbor() {
                self.neighbors.insert(peer.clone());
                to_connect.push(peer);
            } else {
                break;
            }
        }

        // If over maximum, drop worst.
        while self.neighbors.len() > MAX_GOSSIP_NEIGHBORS {
            if let Some(peer) = self.pick_worst_neighbor() {
                self.neighbors.remove(&peer);
                to_disconnect.push(peer);
            } else {
                break;
            }
        }

        // If in range [MIN, MAX], do at most 1 swap: drop worst, add best non-neighbor.
        if self.neighbors.len() >= MIN_GOSSIP_NEIGHBORS
            && self.neighbors.len() <= MAX_GOSSIP_NEIGHBORS
            && !self.neighbors.is_empty()
        {
            let worst = self.pick_worst_neighbor();
            let best_candidate = self.pick_best_non_neighbor();

            if let (Some(worst_peer), Some(best_peer)) = (worst, best_candidate) {
                let worst_score = self
                    .peer_scores
                    .get(&worst_peer)
                    .map(|s| s.composite())
                    .unwrap_or(0.0);
                let best_score = self
                    .peer_scores
                    .get(&best_peer)
                    .map(|s| s.composite())
                    .unwrap_or(0.0);

                // Only swap if the candidate is meaningfully better (10% margin).
                if best_score > worst_score * 1.1 {
                    self.neighbors.remove(&worst_peer);
                    self.neighbors.insert(best_peer.clone());
                    to_disconnect.push(worst_peer);
                    to_connect.push(best_peer);
                }
            }
        }

        (to_connect, to_disconnect)
    }

    /// Check if a broadcast has been seen before. If not, insert it.
    /// Returns `true` if we should relay this broadcast (first time seeing it).
    pub fn should_relay_broadcast(&mut self, broadcast_id: &str) -> bool {
        if self.seen_broadcasts.contains_key(broadcast_id) {
            return false;
        }
        self.seen_broadcasts
            .insert(broadcast_id.to_string(), Instant::now());
        true
    }

    /// Mark a broadcast as seen without relaying (e.g., the originator marks
    /// their own broadcast).
    pub fn mark_broadcast_seen(&mut self, broadcast_id: &str) {
        self.seen_broadcasts
            .entry(broadcast_id.to_string())
            .or_insert_with(Instant::now);
    }

    /// Evict stale broadcast entries and expired pending relays.
    pub fn evict_stale_broadcasts(&mut self) {
        let cutoff = Instant::now()
            - std::time::Duration::from_secs(BROADCAST_DEDUP_TTL_SECS);
        self.seen_broadcasts.retain(|_, seen_at| *seen_at > cutoff);

        // Evict pending relays older than 30 seconds (file didn't arrive).
        let relay_cutoff = Instant::now()
            - std::time::Duration::from_secs(BROADCAST_FALLBACK_TIMEOUT_SECS);
        self.pending_relays
            .retain(|_, relay| relay.created > relay_cutoff);
    }

    /// Register a pending relay: we got BroadcastMeta via MLS, now waiting
    /// for the actual file data to arrive via data channel.
    pub fn add_pending_relay(
        &mut self,
        file_id: &str,
        broadcast_id: &str,
        ttl: u8,
        origin: &str,
        channel_id: &str,
        sender_peer_id: &str,
    ) {
        self.pending_relays.insert(
            file_id.to_string(),
            PendingRelay {
                broadcast_id: broadcast_id.to_string(),
                file_id: file_id.to_string(),
                ttl,
                origin: origin.to_string(),
                channel_id: channel_id.to_string(),
                sender_peer_id: sender_peer_id.to_string(),
                created: Instant::now(),
            },
        );
    }

    /// Check if a completed file transfer has a pending relay, and consume it.
    /// Returns the relay info if the file should be relayed onward.
    pub fn take_pending_relay(&mut self, file_id: &str) -> Option<PendingRelay> {
        self.pending_relays.remove(file_id)
    }

    /// Get file_ids of pending relays that have timed out (30s).
    /// These files didn't arrive via gossip — the peer should request them
    /// directly from the origin or any available peer.
    pub fn get_timed_out_relays(&self) -> Vec<String> {
        let cutoff = Instant::now()
            - std::time::Duration::from_secs(BROADCAST_FALLBACK_TIMEOUT_SECS);
        self.pending_relays
            .iter()
            .filter(|(_, relay)| relay.created <= cutoff)
            .map(|(fid, _)| fid.clone())
            .collect()
    }

    /// Gossip neighbors with a LIVE data channel right now (`mark_connected`
    /// fired, no disconnect since), excluding a specific peer (the sender).
    /// Flood targets for small-message gossip: a neighbor whose channel is
    /// still dialing can't carry a frame, and the caller falls back to the
    /// relay when this comes back empty.
    pub fn connected_relay_targets(&self, exclude_peer: Option<&str>) -> Vec<String> {
        self.neighbors
            .iter()
            .filter(|p| exclude_peer != Some(p.as_str()))
            .filter(|p| {
                self.peer_scores
                    .get(p.as_str())
                    .is_some_and(|s| s.connected_since.is_some())
            })
            .cloned()
            .collect()
    }

    /// Get gossip neighbors to relay to, excluding a specific peer (the sender).
    pub fn get_relay_targets(&self, exclude_peer: Option<&str>) -> Vec<String> {
        self.neighbors
            .iter()
            .filter(|p| {
                if let Some(exc) = exclude_peer {
                    p.as_str() != exc
                } else {
                    true
                }
            })
            .cloned()
            .collect()
    }

    /// Get gossip neighbors that are also in a specific set (e.g., voice
    /// channel participants). Used for voice channel gossip neighbors.
    pub fn get_voice_gossip_neighbors(
        &self,
        voice_participants: &HashSet<String>,
        local_peer_id: &str,
    ) -> Vec<String> {
        self.neighbors
            .iter()
            .filter(|p| {
                voice_participants.contains(p.as_str()) && p.as_str() != local_peer_id
            })
            .cloned()
            .collect()
    }

    // ── Private helpers ──────────────────────────────────────────────────

    /// Pick the best-scoring peer that is known but not a current neighbor.
    fn pick_best_non_neighbor(&self) -> Option<String> {
        self.known_peers
            .iter()
            .filter(|p| !self.neighbors.contains(p.as_str()))
            .max_by(|a, b| {
                let sa = self
                    .peer_scores
                    .get(a.as_str())
                    .map(|s| s.composite())
                    .unwrap_or(0.0);
                let sb = self
                    .peer_scores
                    .get(b.as_str())
                    .map(|s| s.composite())
                    .unwrap_or(0.0);
                sa.partial_cmp(&sb).unwrap_or(std::cmp::Ordering::Equal)
            })
            .cloned()
    }

    /// Pick the worst-scoring current neighbor (candidate for removal).
    /// Peers with high shard_overlap are protected (never returned).
    fn pick_worst_neighbor(&self) -> Option<String> {
        self.neighbors
            .iter()
            .filter(|p| {
                // Protect priority peers (high shard overlap).
                let overlap = self
                    .peer_scores
                    .get(p.as_str())
                    .map(|s| s.shard_overlap)
                    .unwrap_or(0);
                overlap < 3 // only consider peers with fewer than 3 shared shards
            })
            .min_by(|a, b| {
                let sa = self
                    .peer_scores
                    .get(a.as_str())
                    .map(|s| s.composite())
                    .unwrap_or(0.0);
                let sb = self
                    .peer_scores
                    .get(b.as_str())
                    .map(|s| s.composite())
                    .unwrap_or(0.0);
                sa.partial_cmp(&sb).unwrap_or(std::cmp::Ordering::Equal)
            })
            .cloned()
    }
}

/// Generate a unique broadcast ID (32 hex chars = 16 random bytes).
pub fn generate_broadcast_id() -> String {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).unwrap_or(());
    hex::encode(bytes)
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn make_overlay(n_peers: usize) -> GossipOverlay {
        let mut overlay = GossipOverlay::new("server-1".to_string());
        for i in 0..n_peers {
            let peer = format!("peer-{i}");
            overlay.known_peers.insert(peer.clone());
            overlay.peer_scores.insert(peer, PeerScore::new());
        }
        overlay
    }

    #[test]
    fn test_select_initial_neighbors_respects_max() {
        let mut overlay = make_overlay(20);
        let selected = overlay.select_initial_neighbors(0);
        assert!(selected.len() <= MAX_GOSSIP_NEIGHBORS);
        assert!(selected.len() >= MIN_GOSSIP_NEIGHBORS);
        assert_eq!(overlay.neighbors.len(), selected.len());
    }

    #[test]
    fn test_select_initial_neighbors_few_peers() {
        let mut overlay = make_overlay(3);
        let selected = overlay.select_initial_neighbors(0);
        assert_eq!(selected.len(), 3); // only 3 available
    }

    #[test]
    fn test_select_initial_neighbors_respects_global_budget() {
        let mut overlay = make_overlay(20);
        // Global count near limit: only 4 slots left.
        let selected = overlay.select_initial_neighbors(MAX_TOTAL_WEBRTC - 4);
        // Hard cap: only 4 slots available, so at most 4 neighbors.
        assert!(selected.len() <= 4);
    }

    #[test]
    fn test_select_initial_neighbors_zero_budget() {
        let mut overlay = make_overlay(20);
        let selected = overlay.select_initial_neighbors(MAX_TOTAL_WEBRTC);
        assert!(selected.is_empty());
    }

    #[test]
    fn test_add_known_peer_fills_below_min() {
        let mut overlay = GossipOverlay::new("server-1".to_string());
        // Add peers one by one — first MIN should all become neighbors.
        for i in 0..MIN_GOSSIP_NEIGHBORS {
            let peer = format!("peer-{i}");
            let result = overlay.add_known_peer(&peer);
            assert!(result.is_some(), "peer-{i} should become a neighbor");
        }
        assert_eq!(overlay.neighbors.len(), MIN_GOSSIP_NEIGHBORS);

        // Next peer should NOT auto-add (we're at MIN).
        let result = overlay.add_known_peer("peer-extra");
        assert!(result.is_none());
    }

    #[test]
    fn test_remove_known_peer_replaces_neighbor() {
        let mut overlay = make_overlay(10);
        overlay.select_initial_neighbors(0);
        let initial_count = overlay.neighbors.len();

        // Pick a neighbor to remove.
        let neighbor = overlay.neighbors.iter().next().cloned().unwrap();
        let (was_neighbor, replacement) = overlay.remove_known_peer(&neighbor);
        assert!(was_neighbor);
        // Should have a replacement (9 remaining peers, some not neighbors).
        if initial_count < 10 {
            // There were non-neighbors to pick from.
            assert!(replacement.is_some());
            assert_eq!(overlay.neighbors.len(), initial_count);
        }
    }

    #[test]
    fn test_rotation_swaps_worst_for_best() {
        let mut overlay = make_overlay(15);
        overlay.select_initial_neighbors(0);

        // Make a non-neighbor have a great score.
        let non_neighbor: String = overlay
            .known_peers
            .iter()
            .find(|p| !overlay.neighbors.contains(p.as_str()))
            .cloned()
            .unwrap();
        if let Some(score) = overlay.peer_scores.get_mut(&non_neighbor) {
            score.avg_latency_ms = 5.0;
            score.uptime_ratio = 1.0;
            score.bandwidth_score = 9_000_000.0;
            score.shard_overlap = 5;
        }

        // Make a current neighbor have a terrible score.
        let bad_neighbor = overlay.neighbors.iter().next().cloned().unwrap();
        if let Some(score) = overlay.peer_scores.get_mut(&bad_neighbor) {
            score.avg_latency_ms = 400.0;
            score.uptime_ratio = 0.1;
            score.bandwidth_score = 100.0;
            score.shard_overlap = 0;
        }

        let (to_connect, to_disconnect) = overlay.rotate_with_budget(0);
        // The non-neighbor with great score should be added.
        assert!(
            to_connect.contains(&non_neighbor),
            "best non-neighbor should be connected"
        );
        // The bad neighbor should be dropped.
        assert!(
            to_disconnect.contains(&bad_neighbor),
            "worst neighbor should be disconnected"
        );
    }

    #[test]
    fn test_rotation_no_swap_when_similar_scores() {
        let mut overlay = make_overlay(15);
        overlay.select_initial_neighbors(0);
        // All scores are default (identical) — no swap should happen.
        let (to_connect, to_disconnect) = overlay.rotate_with_budget(0);
        assert!(to_connect.is_empty());
        assert!(to_disconnect.is_empty());
    }

    #[test]
    fn test_rotation_fills_below_min() {
        let mut overlay = make_overlay(10);
        // Manually set only 3 neighbors (below MIN).
        overlay.neighbors.clear();
        for p in overlay.known_peers.iter().take(3) {
            overlay.neighbors.insert(p.clone());
        }
        assert_eq!(overlay.neighbors.len(), 3);

        let (to_connect, _) = overlay.rotate_with_budget(0);
        assert!(!to_connect.is_empty());
        assert!(overlay.neighbors.len() >= MIN_GOSSIP_NEIGHBORS);
    }

    #[test]
    fn test_broadcast_dedup() {
        let mut overlay = GossipOverlay::new("server-1".to_string());
        assert!(overlay.should_relay_broadcast("broadcast-1"));
        assert!(!overlay.should_relay_broadcast("broadcast-1")); // duplicate
        assert!(overlay.should_relay_broadcast("broadcast-2")); // different
    }

    #[test]
    fn test_broadcast_eviction() {
        let mut overlay = GossipOverlay::new("server-1".to_string());
        // Insert a broadcast with a very old timestamp.
        overlay.seen_broadcasts.insert(
            "old-broadcast".to_string(),
            Instant::now() - std::time::Duration::from_secs(120),
        );
        overlay
            .seen_broadcasts
            .insert("new-broadcast".to_string(), Instant::now());

        overlay.evict_stale_broadcasts();
        assert!(!overlay.seen_broadcasts.contains_key("old-broadcast"));
        assert!(overlay.seen_broadcasts.contains_key("new-broadcast"));
    }

    #[test]
    fn test_relay_targets_exclude_sender() {
        let mut overlay = GossipOverlay::new("server-1".to_string());
        overlay.neighbors.insert("peer-a".to_string());
        overlay.neighbors.insert("peer-b".to_string());
        overlay.neighbors.insert("peer-c".to_string());

        let targets = overlay.get_relay_targets(Some("peer-b"));
        assert_eq!(targets.len(), 2);
        assert!(!targets.contains(&"peer-b".to_string()));
    }

    #[test]
    fn test_voice_gossip_neighbors() {
        let mut overlay = GossipOverlay::new("server-1".to_string());
        overlay.neighbors.insert("peer-a".to_string());
        overlay.neighbors.insert("peer-b".to_string());
        overlay.neighbors.insert("peer-c".to_string());
        overlay.neighbors.insert("peer-d".to_string());

        let voice_participants: HashSet<String> =
            ["peer-a", "peer-c", "peer-e"] // peer-e not a neighbor
                .iter()
                .map(|s| s.to_string())
                .collect();

        let voice_neighbors =
            overlay.get_voice_gossip_neighbors(&voice_participants, "local");
        assert_eq!(voice_neighbors.len(), 2); // peer-a and peer-c
        assert!(voice_neighbors.contains(&"peer-a".to_string()));
        assert!(voice_neighbors.contains(&"peer-c".to_string()));
    }

    #[test]
    fn test_peer_score_composite() {
        let mut score = PeerScore::new();
        // Default: should give a reasonable mid-range score.
        let default_composite = score.composite();
        assert!(default_composite > 0.0);

        // Great peer: low latency, high uptime, high bandwidth, shard overlap.
        score.avg_latency_ms = 10.0;
        score.uptime_ratio = 0.99;
        score.bandwidth_score = 9_000_000.0;
        score.shard_overlap = 5;
        let great_composite = score.composite();
        assert!(great_composite > default_composite);

        // Bad peer: high latency, low uptime, no bandwidth, no shards.
        let mut bad_score = PeerScore::new();
        bad_score.avg_latency_ms = 450.0;
        bad_score.uptime_ratio = 0.1;
        bad_score.bandwidth_score = 0.0;
        bad_score.shard_overlap = 0;
        let bad_composite = bad_score.composite();
        assert!(bad_composite < great_composite);
    }

    #[test]
    fn test_peer_score_reachability_ordering() {
        // Tier 3: for otherwise-identical peers, direct > unmeasured > TURN,
        // and the direct-vs-TURN spread clears the rotation's 10% margin.
        let mut direct = PeerScore::new();
        direct.is_direct = Some(true);
        let unknown = PeerScore::new(); // is_direct: None
        let mut turn = PeerScore::new();
        turn.is_direct = Some(false);

        assert!(direct.composite() > unknown.composite());
        assert!(unknown.composite() > turn.composite());
        assert!(
            direct.composite() > turn.composite() * 1.1,
            "direct must beat TURN by more than the 10% rotation margin"
        );
    }

    #[test]
    fn test_connected_relay_targets_filters_live_channels() {
        let mut overlay = make_overlay(8);
        overlay.select_initial_neighbors(0);
        assert!(!overlay.neighbors.is_empty());

        // No channel has connected yet — nothing can carry a gossip frame.
        assert!(overlay.connected_relay_targets(None).is_empty());

        // Mark two neighbors' channels live.
        let live: Vec<String> = overlay.neighbors.iter().take(2).cloned().collect();
        for p in &live {
            overlay.peer_scores.get_mut(p).unwrap().mark_connected();
        }
        let targets = overlay.connected_relay_targets(None);
        assert_eq!(targets.len(), 2);

        // Excluding the frame's sender drops it from the target set.
        let targets = overlay.connected_relay_targets(Some(&live[0]));
        assert_eq!(targets.len(), 1);
        assert_eq!(targets[0], live[1]);

        // A disconnect removes the peer from flood targets again.
        overlay.peer_scores.get_mut(&live[1]).unwrap().mark_disconnected();
        assert_eq!(overlay.connected_relay_targets(None).len(), 1);
    }

    #[test]
    fn test_peer_score_latency_update() {
        let mut score = PeerScore::new();
        score.avg_latency_ms = 100.0;
        score.update_latency(20);
        // EMA: 0.3 * 20 + 0.7 * 100 = 76
        assert!((score.avg_latency_ms - 76.0).abs() < 0.1);
    }

    #[test]
    fn test_peer_score_bandwidth_update() {
        let mut score = PeerScore::new();
        score.bandwidth_score = 1_000_000.0;
        score.update_bandwidth(5_000_000, 1.0); // 5 MB/s
        // EMA: 0.3 * 5M + 0.7 * 1M = 2.2M
        assert!((score.bandwidth_score - 2_200_000.0).abs() < 100.0);
    }

    #[test]
    fn test_priority_peer_protection() {
        let mut overlay = make_overlay(15);
        overlay.select_initial_neighbors(0);

        // Give ALL neighbors high shard overlap — they should all be protected.
        for neighbor in overlay.neighbors.clone() {
            if let Some(score) = overlay.peer_scores.get_mut(&neighbor) {
                score.shard_overlap = 5;
                score.avg_latency_ms = 400.0; // terrible latency
                score.uptime_ratio = 0.1; // terrible uptime
            }
        }

        // Give a non-neighbor a great score.
        let non_neighbor: String = overlay
            .known_peers
            .iter()
            .find(|p| !overlay.neighbors.contains(p.as_str()))
            .cloned()
            .unwrap();
        if let Some(score) = overlay.peer_scores.get_mut(&non_neighbor) {
            score.avg_latency_ms = 5.0;
            score.uptime_ratio = 1.0;
        }

        let (to_connect, to_disconnect) = overlay.rotate_with_budget(0);
        // No neighbors should be dropped because they're all protected by shard overlap.
        assert!(to_disconnect.is_empty(), "protected peers should not be dropped");
        assert!(to_connect.is_empty(), "can't add without dropping");
    }

    #[test]
    fn test_generate_broadcast_id() {
        let id1 = generate_broadcast_id();
        let id2 = generate_broadcast_id();
        assert_eq!(id1.len(), 32); // 16 bytes = 32 hex chars
        assert_ne!(id1, id2); // should be unique
    }

    #[test]
    fn test_pending_relay_add_and_take() {
        let mut overlay = GossipOverlay::new("server-1".to_string());
        overlay.add_pending_relay("file-1", "broadcast-1", 3, "origin-peer", "ch-1", "sender-1");
        assert_eq!(overlay.pending_relays.len(), 1);

        let relay = overlay.take_pending_relay("file-1");
        assert!(relay.is_some());
        let r = relay.unwrap();
        assert_eq!(r.broadcast_id, "broadcast-1");
        assert_eq!(r.ttl, 3);
        assert_eq!(r.origin, "origin-peer");
        assert_eq!(r.channel_id, "ch-1");
        assert_eq!(r.sender_peer_id, "sender-1");

        // Second take should return None (consumed).
        assert!(overlay.take_pending_relay("file-1").is_none());
        assert_eq!(overlay.pending_relays.len(), 0);
    }

    #[test]
    fn test_pending_relay_timeout() {
        let mut overlay = GossipOverlay::new("server-1".to_string());

        // Insert a relay with an old timestamp.
        overlay.pending_relays.insert(
            "old-file".to_string(),
            PendingRelay {
                broadcast_id: "old-bid".to_string(),
                file_id: "old-file".to_string(),
                ttl: 3,
                origin: "origin".to_string(),
                channel_id: "ch".to_string(),
                sender_peer_id: "sender".to_string(),
                created: Instant::now() - std::time::Duration::from_secs(60),
            },
        );
        // Insert a fresh relay.
        overlay.add_pending_relay("new-file", "new-bid", 2, "origin", "ch", "sender");

        let timed_out = overlay.get_timed_out_relays();
        assert_eq!(timed_out.len(), 1);
        assert!(timed_out.contains(&"old-file".to_string()));
    }

    #[test]
    fn test_pending_relay_eviction() {
        let mut overlay = GossipOverlay::new("server-1".to_string());
        overlay.pending_relays.insert(
            "stale-file".to_string(),
            PendingRelay {
                broadcast_id: "stale-bid".to_string(),
                file_id: "stale-file".to_string(),
                ttl: 3,
                origin: "origin".to_string(),
                channel_id: "ch".to_string(),
                sender_peer_id: "sender".to_string(),
                created: Instant::now() - std::time::Duration::from_secs(120),
            },
        );
        overlay.add_pending_relay("fresh-file", "fresh-bid", 2, "origin", "ch", "sender");

        overlay.evict_stale_broadcasts();
        // Stale relay should be evicted, fresh one kept.
        assert!(!overlay.pending_relays.contains_key("stale-file"));
        assert!(overlay.pending_relays.contains_key("fresh-file"));
    }

    #[test]
    fn test_full_broadcast_relay_flow() {
        // Simulates: originator broadcasts → relay peer receives BroadcastMeta
        // → file arrives → relay takes pending → forwards
        let mut overlay = make_overlay(10);
        overlay.select_initial_neighbors(0);

        // 1. BroadcastMeta arrives — register pending relay.
        let broadcast_id = generate_broadcast_id();
        overlay.mark_broadcast_seen(&broadcast_id);
        overlay.add_pending_relay("file-42", &broadcast_id, 3, "origin-peer", "ch-general", "sender-peer");

        // 2. File arrives via data channel (simulated).
        let relay = overlay.take_pending_relay("file-42");
        assert!(relay.is_some());
        let r = relay.unwrap();
        assert_eq!(r.ttl, 3);

        // 3. Get relay targets (excluding the sender).
        let targets = overlay.get_relay_targets(Some(&r.sender_peer_id));
        // Should have neighbors minus the sender.
        assert!(!targets.is_empty());
        for t in &targets {
            assert_ne!(t, &r.sender_peer_id);
        }

        // 4. Dedup: if same broadcast arrives again, should_relay returns false.
        assert!(!overlay.should_relay_broadcast(&broadcast_id));
    }

    #[test]
    fn test_voice_gossip_neighbors_subset() {
        let mut overlay = make_overlay(20);
        overlay.select_initial_neighbors(0);

        // Voice channel has 8 participants, some of which are gossip neighbors.
        let voice_participants: HashSet<String> = (0..8)
            .map(|i| format!("peer-{i}"))
            .collect();

        let voice_neighbors =
            overlay.get_voice_gossip_neighbors(&voice_participants, "local");

        // Should only return peers that are BOTH neighbors AND voice participants.
        for n in &voice_neighbors {
            assert!(overlay.neighbors.contains(n));
            assert!(voice_participants.contains(n));
        }
    }

    #[test]
    fn test_score_composite_ordering() {
        // Verify that better peers get higher scores for correct rotation.
        let mut great = PeerScore::new();
        great.avg_latency_ms = 10.0;
        great.uptime_ratio = 0.99;
        great.bandwidth_score = 8_000_000.0;
        great.shard_overlap = 3;

        let mut ok = PeerScore::new();
        ok.avg_latency_ms = 50.0;
        ok.uptime_ratio = 0.7;
        ok.bandwidth_score = 2_000_000.0;
        ok.shard_overlap = 1;

        let mut bad = PeerScore::new();
        bad.avg_latency_ms = 300.0;
        bad.uptime_ratio = 0.2;
        bad.bandwidth_score = 100_000.0;
        bad.shard_overlap = 0;

        assert!(great.composite() > ok.composite());
        assert!(ok.composite() > bad.composite());
    }

    #[test]
    fn test_overlay_global_budget_cap() {
        let mut overlay = make_overlay(20);
        // Global count is 48 out of 50 — only 2 slots available.
        // Hard cap: at most 2 neighbors.
        let selected = overlay.select_initial_neighbors(48);
        assert!(selected.len() <= 2);
        assert!(!selected.is_empty());
    }

    #[test]
    fn test_pending_relay_take_returns_none_for_unknown() {
        let mut overlay = GossipOverlay::new("server-1".to_string());
        assert!(overlay.take_pending_relay("nonexistent").is_none());
    }

    #[test]
    fn test_multiple_servers_independent_overlays() {
        let mut overlay_a = GossipOverlay::new("server-a".to_string());
        let mut overlay_b = GossipOverlay::new("server-b".to_string());

        // Add different peers to each.
        for i in 0..10 {
            overlay_a.add_known_peer(&format!("peer-a{i}"));
        }
        for i in 0..8 {
            overlay_b.add_known_peer(&format!("peer-b{i}"));
        }

        overlay_a.select_initial_neighbors(0);
        overlay_b.select_initial_neighbors(overlay_a.neighbors.len());

        // Independent neighbor sets.
        for n in &overlay_a.neighbors {
            assert!(!overlay_b.neighbors.contains(n));
        }

        // Independent dedup caches.
        overlay_a.mark_broadcast_seen("bid-1");
        assert!(overlay_a.seen_broadcasts.contains_key("bid-1"));
        assert!(!overlay_b.seen_broadcasts.contains_key("bid-1"));
    }
}
