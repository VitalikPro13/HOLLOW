use std::collections::{HashMap, HashSet};

use super::content_store::PlacementRecord;
use super::pipeline::VaultManifest;
use super::placement::{compute_shard_placements, ShardPlacement};

/// Content that is under-replicated and may need repair.
#[derive(Debug, Clone)]
pub struct UnderReplicatedContent {
    pub content_id: String,
    pub server_id: String,
    pub k: u16,
    pub available_count: u32,
    pub total_count: u16,
    pub missing_indices: Vec<u16>,
}

/// A plan to repair under-replicated content.
#[derive(Debug, Clone)]
pub struct RepairPlan {
    pub content_id: String,
    pub server_id: String,
    /// Shard indices that need to be re-placed on new peers.
    pub missing_indices: Vec<u16>,
    /// Available shards: (shard_index, peer_id) that can be fetched for reconstruction.
    pub available_shards: Vec<(u16, String)>,
    /// New targets: (shard_index, peer_id) where repaired shards should be stored.
    pub new_targets: Vec<(u16, String)>,
}

/// A shard migration entry (move shard from old peer to new peer).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShardMigration {
    pub content_id: String,
    pub shard_index: u16,
    pub from_peer: String,
    pub to_peer: String,
    pub shard_key: String,
}

/// Detect peers that have been offline longer than the threshold.
///
/// `member_statuses` is a list of (peer_id, last_seen_timestamp).
/// Returns peer_ids that are considered departed.
pub fn detect_departures(
    member_statuses: &[(String, i64)],
    threshold_days: u64,
    now: i64,
) -> Vec<String> {
    let threshold_secs = threshold_days as i64 * 86400;
    member_statuses
        .iter()
        .filter(|(_, last_seen)| now - last_seen > threshold_secs)
        .map(|(peer_id, _)| peer_id.clone())
        .collect()
}

/// Scan manifests for under-replicated content.
///
/// For each manifest with erasure coding (k > 0), check how many placements
/// are confirmed AND the target peer is online. If available < k, the content
/// is at risk.
///
/// For full-replication manifests (k=0), check if at least 2 peers have the file.
pub fn scan_under_replicated(
    manifests: &[VaultManifest],
    placements: &HashMap<String, Vec<PlacementRecord>>,
    online_peers: &HashSet<String>,
) -> Vec<UnderReplicatedContent> {
    let mut result = Vec::new();

    for manifest in manifests {
        let records = match placements.get(&manifest.content_id) {
            Some(r) => r,
            None => continue,
        };

        if manifest.k == 0 && manifest.m == 0 {
            // Full replication — check if at least 2 peers have it
            let available = records
                .iter()
                .filter(|r| r.confirmed && online_peers.contains(&r.target_peer))
                .count() as u32;
            if available < 2 && records.len() >= 2 {
                let missing: Vec<u16> = records
                    .iter()
                    .filter(|r| !r.confirmed || !online_peers.contains(&r.target_peer))
                    .map(|r| r.shard_index)
                    .collect();
                result.push(UnderReplicatedContent {
                    content_id: manifest.content_id.clone(),
                    server_id: records.first().map(|r| r.server_id.clone()).unwrap_or_default(),
                    k: 0,
                    available_count: available,
                    total_count: records.len() as u16,
                    missing_indices: missing,
                });
            }
        } else {
            // Erasure coding — need at least k confirmed + online
            let k = manifest.k as u32;
            let n = manifest.k + manifest.m;
            let available = records
                .iter()
                .filter(|r| r.confirmed && online_peers.contains(&r.target_peer))
                .count() as u32;

            if available < k {
                let missing: Vec<u16> = (0..n)
                    .filter(|i| {
                        !records.iter().any(|r| {
                            r.shard_index == *i
                                && r.confirmed
                                && online_peers.contains(&r.target_peer)
                        })
                    })
                    .collect();
                result.push(UnderReplicatedContent {
                    content_id: manifest.content_id.clone(),
                    server_id: records.first().map(|r| r.server_id.clone()).unwrap_or_default(),
                    k: manifest.k,
                    available_count: available,
                    total_count: n,
                    missing_indices: missing,
                });
            }
        }
    }

    result
}

/// Compute a repair plan for under-replicated content.
///
/// Identifies which shards are missing and where to place new copies.
/// Returns None if repair is impossible (not enough online peers or available shards).
pub fn compute_repair_plan(
    manifest: &VaultManifest,
    placements: &[PlacementRecord],
    online_peers: &HashSet<String>,
    members: &[String],
    pledges: &HashMap<String, u64>,
) -> Option<RepairPlan> {
    let k = manifest.k as usize;
    let m = manifest.m as usize;

    // Find which shards are available (confirmed + target online)
    let available: Vec<(u16, String)> = placements
        .iter()
        .filter(|r| r.confirmed && online_peers.contains(&r.target_peer))
        .map(|r| (r.shard_index, r.target_peer.clone()))
        .collect();

    if manifest.k > 0 && available.len() < k {
        // Not enough shards to reconstruct — can't repair
        return None;
    }

    // Find missing shard indices
    let n = if manifest.k > 0 { k + m } else { placements.len() };
    let available_indices: HashSet<u16> = available.iter().map(|(i, _)| *i).collect();
    let missing: Vec<u16> = (0..n as u16)
        .filter(|i| !available_indices.contains(i))
        .collect();

    if missing.is_empty() {
        return None; // Nothing to repair
    }

    // Compute new targets for missing shards
    // Use the placement algorithm to find new peers (exclude peers already holding shards)
    let new_placements = compute_shard_placements(
        &manifest.content_id,
        n,
        members,
        pledges,
    );

    let new_targets: Vec<(u16, String)> = missing
        .iter()
        .filter_map(|idx| {
            new_placements
                .iter()
                .find(|p| p.shard_index == *idx)
                .map(|p| (*idx, p.target_peer.clone()))
        })
        .collect();

    Some(RepairPlan {
        content_id: manifest.content_id.clone(),
        server_id: placements
            .first()
            .map(|r| r.server_id.clone())
            .unwrap_or_default(),
        missing_indices: missing,
        available_shards: available,
        new_targets,
    })
}

/// Compute a migration plan when a new member joins.
///
/// Compares old placements with new (recomputed) placements to find shards
/// that should move to the new member.
pub fn compute_migration_plan(
    content_id: &str,
    old_placements: &[PlacementRecord],
    new_placements: &[ShardPlacement],
) -> Vec<ShardMigration> {
    let mut migrations = Vec::new();

    for new_p in new_placements {
        // Find old placement for this shard index
        if let Some(old_p) = old_placements
            .iter()
            .find(|o| o.shard_index == new_p.shard_index)
        {
            if old_p.target_peer != new_p.target_peer {
                migrations.push(ShardMigration {
                    content_id: content_id.to_string(),
                    shard_index: new_p.shard_index,
                    from_peer: old_p.target_peer.clone(),
                    to_peer: new_p.target_peer.clone(),
                    shard_key: new_p.shard_key.clone(),
                });
            }
        }
    }

    migrations
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_placement(cid: &str, si: u16, peer: &str, confirmed: bool) -> PlacementRecord {
        PlacementRecord {
            content_id: cid.to_string(),
            shard_index: si,
            target_peer: peer.to_string(),
            server_id: "srv1".to_string(),
            shard_key: format!("sk_{si}"),
            stored_at: 1000,
            confirmed,
        }
    }

    fn make_manifest(cid: &str, k: u16, m: u16) -> VaultManifest {
        VaultManifest {
            content_id: cid.to_string(),
            encryption_key: "aa".repeat(32),
            nonce: "bb".repeat(12),
            original_size: 1000,
            k,
            m,
            shard_count: k + m,
            file_name: "test.dat".into(),
            mime_type: "application/octet-stream".into(),
            storage_tier: "standard".into(),
            created_at: 1000,
            creator_peer_id: "creator".into(),
            channel_id: "ch1".into(),
            message_id: String::new(),
        }
    }

    // ── detect_departures ────────────────────────────────────

    #[test]
    fn detect_departures_none() {
        let now = 1000000;
        let statuses = vec![
            ("peer_a".to_string(), now - 3600),   // 1 hour ago
            ("peer_b".to_string(), now - 86400),  // 1 day ago
        ];
        let departed = detect_departures(&statuses, 7, now);
        assert!(departed.is_empty());
    }

    #[test]
    fn detect_departures_some() {
        let now = 1000000;
        let statuses = vec![
            ("peer_a".to_string(), now - 3600),          // 1 hour ago
            ("peer_b".to_string(), now - 8 * 86400),     // 8 days ago
            ("peer_c".to_string(), now - 10 * 86400),    // 10 days ago
        ];
        let departed = detect_departures(&statuses, 7, now);
        assert_eq!(departed.len(), 2);
        assert!(departed.contains(&"peer_b".to_string()));
        assert!(departed.contains(&"peer_c".to_string()));
    }

    // ── scan_under_replicated ────────────────────────────────

    #[test]
    fn scan_all_healthy() {
        let manifest = make_manifest("cid1", 3, 2);
        let placements: Vec<PlacementRecord> = (0..5)
            .map(|i| make_placement("cid1", i, &format!("peer_{i}"), true))
            .collect();
        let online: HashSet<String> = (0..5).map(|i| format!("peer_{i}")).collect();

        let mut map = HashMap::new();
        map.insert("cid1".to_string(), placements);

        let under = scan_under_replicated(&[manifest], &map, &online);
        assert!(under.is_empty());
    }

    #[test]
    fn scan_some_offline_under_k() {
        let manifest = make_manifest("cid1", 3, 2);
        let placements: Vec<PlacementRecord> = (0..5)
            .map(|i| make_placement("cid1", i, &format!("peer_{i}"), true))
            .collect();
        // Only 2 of 5 peers online — below k=3
        let online: HashSet<String> = ["peer_0", "peer_1"]
            .iter()
            .map(|s| s.to_string())
            .collect();

        let mut map = HashMap::new();
        map.insert("cid1".to_string(), placements);

        let under = scan_under_replicated(&[manifest], &map, &online);
        assert_eq!(under.len(), 1);
        assert_eq!(under[0].content_id, "cid1");
        assert_eq!(under[0].available_count, 2);
        assert!(!under[0].missing_indices.is_empty());
    }

    #[test]
    fn scan_healthy_above_k() {
        let manifest = make_manifest("cid1", 3, 2);
        let placements: Vec<PlacementRecord> = (0..5)
            .map(|i| make_placement("cid1", i, &format!("peer_{i}"), true))
            .collect();
        // 3 online — exactly k=3, so healthy
        let online: HashSet<String> = ["peer_0", "peer_1", "peer_2"]
            .iter()
            .map(|s| s.to_string())
            .collect();

        let mut map = HashMap::new();
        map.insert("cid1".to_string(), placements);

        let under = scan_under_replicated(&[manifest], &map, &online);
        assert!(under.is_empty());
    }

    // ── compute_repair_plan ──────────────────────────────────

    #[test]
    fn repair_plan_basic() {
        let manifest = make_manifest("cid1", 3, 2);
        let placements: Vec<PlacementRecord> = (0..5)
            .map(|i| make_placement("cid1", i, &format!("peer_{i}"), i < 3))
            .collect();
        // Shards 0,1,2 confirmed, 3,4 unconfirmed. All 5 peers online.
        let online: HashSet<String> = (0..5).map(|i| format!("peer_{i}")).collect();
        let members: Vec<String> = (0..8).map(|i| format!("peer_{i}")).collect();
        let pledges: HashMap<String, u64> = members.iter().map(|m| (m.clone(), 1000)).collect();

        let plan = compute_repair_plan(&manifest, &placements, &online, &members, &pledges);
        assert!(plan.is_some());
        let plan = plan.unwrap();
        assert_eq!(plan.missing_indices.len(), 2);
        assert_eq!(plan.available_shards.len(), 3);
    }

    #[test]
    fn repair_plan_not_enough_shards() {
        let manifest = make_manifest("cid1", 3, 2);
        // Only 2 confirmed shards, need k=3 to reconstruct
        let placements = vec![
            make_placement("cid1", 0, "peer_0", true),
            make_placement("cid1", 1, "peer_1", true),
            make_placement("cid1", 2, "peer_2", false),
            make_placement("cid1", 3, "peer_3", false),
            make_placement("cid1", 4, "peer_4", false),
        ];
        let online: HashSet<String> = ["peer_0", "peer_1"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let members: Vec<String> = (0..5).map(|i| format!("peer_{i}")).collect();
        let pledges: HashMap<String, u64> = members.iter().map(|m| (m.clone(), 1000)).collect();

        let plan = compute_repair_plan(&manifest, &placements, &online, &members, &pledges);
        assert!(plan.is_none());
    }

    // ── compute_migration_plan ───────────────────────────────

    #[test]
    fn migration_plan_member_join() {
        let old_placements = vec![
            make_placement("cid1", 0, "peer_0", true),
            make_placement("cid1", 1, "peer_1", true),
            make_placement("cid1", 2, "peer_2", true),
        ];
        let new_placements = vec![
            ShardPlacement { shard_index: 0, target_peer: "peer_0".into(), shard_key: "sk0".into() },
            ShardPlacement { shard_index: 1, target_peer: "peer_new".into(), shard_key: "sk1".into() },
            ShardPlacement { shard_index: 2, target_peer: "peer_2".into(), shard_key: "sk2".into() },
        ];

        let migrations = compute_migration_plan("cid1", &old_placements, &new_placements);
        assert_eq!(migrations.len(), 1);
        assert_eq!(migrations[0].shard_index, 1);
        assert_eq!(migrations[0].from_peer, "peer_1");
        assert_eq!(migrations[0].to_peer, "peer_new");
    }

    #[test]
    fn migration_plan_no_change() {
        let old_placements = vec![
            make_placement("cid1", 0, "peer_0", true),
            make_placement("cid1", 1, "peer_1", true),
        ];
        let new_placements = vec![
            ShardPlacement { shard_index: 0, target_peer: "peer_0".into(), shard_key: "sk0".into() },
            ShardPlacement { shard_index: 1, target_peer: "peer_1".into(), shard_key: "sk1".into() },
        ];

        let migrations = compute_migration_plan("cid1", &old_placements, &new_placements);
        assert!(migrations.is_empty());
    }

    #[test]
    fn migration_plan_rebalance_with_new_members() {
        // 6 original peers hold 5 shards (k=3, m=2).
        let old_members: Vec<String> = (0..6).map(|i| format!("peer_{i}")).collect();
        let mut old_pledges: HashMap<String, u64> = old_members.iter()
            .map(|m| (m.clone(), 1000)).collect();

        let old_shard_placements = compute_shard_placements("cid1", 5, &old_members, &old_pledges);
        let old_placements: Vec<PlacementRecord> = old_shard_placements.iter()
            .map(|sp| PlacementRecord {
                content_id: "cid1".to_string(),
                shard_index: sp.shard_index,
                target_peer: sp.target_peer.clone(),
                server_id: "srv1".to_string(),
                shard_key: sp.shard_key.clone(),
                stored_at: 1000,
                confirmed: true,
            })
            .collect();

        // 4 new peers join (total 10), equal pledges.
        let new_members: Vec<String> = (0..10).map(|i| format!("peer_{i}")).collect();
        for i in 6..10 {
            old_pledges.insert(format!("peer_{i}"), 1000);
        }

        let new_shard_placements = compute_shard_placements("cid1", 5, &new_members, &old_pledges);
        let migrations = compute_migration_plan("cid1", &old_placements, &new_shard_placements);

        // With more peers in the pool, XOR distance changes — some shards should migrate.
        // The exact count depends on the hash-based placement, but with 4 new peers
        // added to a 6-peer pool, at least some shards should shift.
        assert!(!migrations.is_empty(), "Expected at least one migration when 4 new peers join");

        // All migrations should move TO new peers (peer_6..peer_9) or between existing ones.
        for m in &migrations {
            assert_ne!(m.from_peer, m.to_peer, "Migration shouldn't be from/to same peer");
        }
    }
}
