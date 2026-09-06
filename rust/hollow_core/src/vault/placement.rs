use sha2::{Digest, Sha256};
use std::collections::HashMap;

use super::adaptive::VaultMode;
use super::content_store::shard_key;

/// Output: which peer should store which shard.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShardPlacement {
    pub shard_index: u16,
    pub target_peer: String,
    pub shard_key: String,
}

/// Compute deterministic shard placements for erasure-coded content.
///
/// For each shard, the closest eligible member by XOR distance that has not exceeded
/// its weighted cap. Members with pledge == 0 are excluded, and the list is sorted
/// internally so tie-breaking is deterministic across peers.
pub fn compute_shard_placements(
    content_id: &str,
    n: usize,
    members: &[String],
    pledges: &HashMap<String, u64>,
) -> Vec<ShardPlacement> {
    if n == 0 {
        return Vec::new();
    }

    let mut eligible: Vec<&String> = members
        .iter()
        .filter(|m| pledges.get(*m).copied().unwrap_or(0) > 0)
        .collect();
    eligible.sort();

    if eligible.is_empty() {
        return Vec::new();
    }

    // Per-member shard cap: ceil(n * pledge / total_pledge), min 1
    let total_pledge: u64 = eligible
        .iter()
        .map(|m| pledges.get(*m).copied().unwrap_or(0))
        .sum();

    let caps: HashMap<&String, usize> = eligible
        .iter()
        .map(|m| {
            let pledge = pledges.get(*m).copied().unwrap_or(0);
            let cap =
                ((n as u128 * pledge as u128 + total_pledge as u128 - 1) / total_pledge as u128)
                    as usize;
            (*m, cap.max(1))
        })
        .collect();

    let peer_hashes: HashMap<&String, [u8; 32]> = eligible
        .iter()
        .map(|m| (*m, Sha256::digest(m.as_bytes()).into()))
        .collect();

    let mut assignments: HashMap<&String, usize> = HashMap::new();
    let mut placements = Vec::with_capacity(n);

    for idx in 0..n {
        let shard_idx = idx as u16;
        let sk = shard_key(content_id, shard_idx);

        let shard_bytes: [u8; 32] = hex::decode(&sk)
            .expect("shard_key is valid hex")
            .try_into()
            .expect("shard_key is 32 bytes");

        let mut scored: Vec<(&String, [u8; 32])> = eligible
            .iter()
            .map(|m| {
                let peer_hash = peer_hashes[m];
                let mut dist = [0u8; 32];
                for i in 0..32 {
                    dist[i] = shard_bytes[i] ^ peer_hash[i];
                }
                (*m, dist)
            })
            .collect();
        scored.sort_by(|a, b| a.1.cmp(&b.1));

        let mut placed = false;
        for (peer, _) in &scored {
            let count = assignments.get(peer).copied().unwrap_or(0);
            if count < caps[peer] {
                *assignments.entry(peer).or_insert(0) += 1;
                placements.push(ShardPlacement {
                    shard_index: shard_idx,
                    target_peer: peer.to_string(),
                    shard_key: sk.clone(),
                });
                placed = true;
                break;
            }
        }

        // Fallback: all at cap (rounding edge case), assign to closest regardless
        if !placed {
            if let Some((peer, _)) = scored.first() {
                *assignments.entry(peer).or_insert(0) += 1;
                placements.push(ShardPlacement {
                    shard_index: shard_idx,
                    target_peer: peer.to_string(),
                    shard_key: sk,
                });
            }
        }
    }

    placements
}

/// Compute placements for full-replication mode.
/// Every member with non-zero pledge stores the full file (shard_index=0).
pub fn compute_full_replication_placements(
    content_id: &str,
    members: &[String],
    pledges: &HashMap<String, u64>,
) -> Vec<ShardPlacement> {
    let sk = shard_key(content_id, 0);
    let mut sorted: Vec<&String> = members
        .iter()
        .filter(|m| pledges.get(*m).copied().unwrap_or(0) > 0)
        .collect();
    sorted.sort();

    sorted
        .into_iter()
        .map(|m| ShardPlacement {
            shard_index: 0,
            target_peer: m.clone(),
            shard_key: sk.clone(),
        })
        .collect()
}

/// Unified placement entry point. Branches on VaultMode.
///
/// - FullReplication: every eligible member stores the full file
/// - ErasureCoding { k, m }: n=k+m shards distributed via XOR distance
///
/// Pure function — no I/O, no DB. Fully deterministic.
pub fn place(
    content_id: &str,
    mode: &VaultMode,
    members: &[String],
    pledges: &HashMap<String, u64>,
) -> Vec<ShardPlacement> {
    match mode {
        VaultMode::FullReplication => {
            compute_full_replication_placements(content_id, members, pledges)
        }
        VaultMode::ErasureCoding { k, m } => {
            compute_shard_placements(content_id, k + m, members, pledges)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn members(names: &[&str]) -> Vec<String> {
        names.iter().map(|s| s.to_string()).collect()
    }

    fn pledges_equal(names: &[&str], amount: u64) -> HashMap<String, u64> {
        names.iter().map(|s| (s.to_string(), amount)).collect()
    }

    fn pledges_map(pairs: &[(&str, u64)]) -> HashMap<String, u64> {
        pairs.iter().map(|(s, a)| (s.to_string(), *a)).collect()
    }

    // ── Full replication ─────────────────────────────────────

    #[test]
    fn full_replication_returns_all_eligible() {
        let m = members(&["peer1", "peer2", "peer3"]);
        let p = pledges_equal(&["peer1", "peer2", "peer3"], 1000);
        let placements = compute_full_replication_placements("cid1", &m, &p);
        assert_eq!(placements.len(), 3);
        for pl in &placements {
            assert_eq!(pl.shard_index, 0);
        }
    }

    #[test]
    fn full_replication_skips_zero_pledge() {
        let m = members(&["peer1", "peer2", "peer3"]);
        let p = pledges_map(&[("peer1", 1000), ("peer2", 0), ("peer3", 1000)]);
        let placements = compute_full_replication_placements("cid1", &m, &p);
        assert_eq!(placements.len(), 2);
        let targets: Vec<&str> = placements.iter().map(|p| p.target_peer.as_str()).collect();
        assert!(!targets.contains(&"peer2"));
    }

    // ── Erasure coding placement ─────────────────────────────

    #[test]
    fn erasure_places_n_shards_on_n_different_peers() {
        let m: Vec<String> = (0..10).map(|i| format!("peer_{i}")).collect();
        let p: HashMap<String, u64> = m.iter().map(|s| (s.clone(), 1000)).collect();
        let placements = compute_shard_placements("content_abc", 5, &m, &p);
        assert_eq!(placements.len(), 5);

        let targets: std::collections::HashSet<&str> =
            placements.iter().map(|p| p.target_peer.as_str()).collect();
        assert_eq!(targets.len(), 5, "5 shards should be on 5 different peers");
    }

    #[test]
    fn erasure_deterministic() {
        let m: Vec<String> = (0..8).map(|i| format!("member_{i}")).collect();
        let p: HashMap<String, u64> = m.iter().map(|s| (s.clone(), 500)).collect();
        let p1 = compute_shard_placements("same_content", 5, &m, &p);
        let p2 = compute_shard_placements("same_content", 5, &m, &p);
        assert_eq!(p1, p2);
    }

    #[test]
    fn erasure_skips_zero_pledge() {
        let m = members(&["peer1", "peer2", "peer3"]);
        let p = pledges_map(&[("peer1", 1000), ("peer2", 0), ("peer3", 1000)]);
        let placements = compute_shard_placements("cid1", 2, &m, &p);
        assert_eq!(placements.len(), 2);
        for pl in &placements {
            assert_ne!(pl.target_peer, "peer2");
        }
    }

    #[test]
    fn erasure_fewer_members_than_shards() {
        let m = members(&["pA", "pB", "pC"]);
        let p = pledges_equal(&["pA", "pB", "pC"], 1000);
        let placements = compute_shard_placements("cid1", 5, &m, &p);
        assert_eq!(placements.len(), 5);
        let indices: Vec<u16> = placements.iter().map(|p| p.shard_index).collect();
        for i in 0..5u16 {
            assert!(indices.contains(&i));
        }
    }

    #[test]
    fn single_member_gets_all_shards() {
        let m = members(&["solo"]);
        let p = pledges_equal(&["solo"], 5000);
        let placements = compute_shard_placements("cid1", 5, &m, &p);
        assert_eq!(placements.len(), 5);
        for pl in &placements {
            assert_eq!(pl.target_peer, "solo");
        }
    }

    #[test]
    fn placement_varies_by_content_id() {
        let m: Vec<String> = (0..20).map(|i| format!("peer_{i}")).collect();
        let p: HashMap<String, u64> = m.iter().map(|s| (s.clone(), 1000)).collect();
        let p1 = compute_shard_placements("content_aaa", 5, &m, &p);
        let p2 = compute_shard_placements("content_bbb", 5, &m, &p);
        let t1: Vec<&str> = p1.iter().map(|p| p.target_peer.as_str()).collect();
        let t2: Vec<&str> = p2.iter().map(|p| p.target_peer.as_str()).collect();
        assert_ne!(t1, t2);
    }

    #[test]
    fn weighted_larger_pledge_more_shards() {
        // 2 members: "large" has 3x the pledge of "small"
        let m = members(&["large", "small"]);
        let p = pledges_map(&[("small", 1000), ("large", 3000)]);
        let placements = compute_shard_placements("cid1", 8, &m, &p);
        assert_eq!(placements.len(), 8);
        let large_count = placements.iter().filter(|p| p.target_peer == "large").count();
        let small_count = placements.iter().filter(|p| p.target_peer == "small").count();
        // large cap = ceil(8 * 3000 / 4000) = ceil(6.0) = 6
        // small cap = ceil(8 * 1000 / 4000) = ceil(2.0) = 2
        assert!(large_count >= 6, "large got {large_count}, expected >= 6");
        assert!(small_count <= 2, "small got {small_count}, expected <= 2");
    }

    #[test]
    fn empty_members_returns_empty() {
        let placements = compute_shard_placements("cid1", 5, &[], &HashMap::new());
        assert!(placements.is_empty());
    }

    #[test]
    fn zero_shards_returns_empty() {
        let m = members(&["peer1"]);
        let p = pledges_equal(&["peer1"], 1000);
        let placements = compute_shard_placements("cid1", 0, &m, &p);
        assert!(placements.is_empty());
    }

    // ── place() unified ──────────────────────────────────────

    #[test]
    fn place_full_replication() {
        let m = members(&["a", "b", "c"]);
        let p = pledges_equal(&["a", "b", "c"], 100);
        let placements = place("cid", &VaultMode::FullReplication, &m, &p);
        assert_eq!(placements.len(), 3);
    }

    #[test]
    fn place_erasure_coding() {
        let m: Vec<String> = (0..10).map(|i| format!("p{i}")).collect();
        let p: HashMap<String, u64> = m.iter().map(|s| (s.clone(), 1000)).collect();
        let placements = place(
            "cid",
            &VaultMode::ErasureCoding { k: 3, m: 2 },
            &m,
            &p,
        );
        assert_eq!(placements.len(), 5);
    }

}
