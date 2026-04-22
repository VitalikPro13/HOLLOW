use std::collections::HashMap;

use super::content_store::StorageTier;
use crate::crdt::admin_lww::AdminLwwReg;

/// Vault operating mode — determined automatically from server member count.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VaultMode {
    /// Every member stores every file. Used for <6 members.
    FullReplication,
    /// Reed-Solomon erasure coding with adaptive k/m parameters.
    ErasureCoding { k: usize, m: usize },
}

/// Compute the vault mode and erasure coding parameters for a server.
///
/// Below 6 members: full replication (everyone gets every file).
/// 6+ members: erasure coding with k/m scaling logarithmically.
/// k scales with log(member_count), m = ceil(k/2), overhead converges to 1.5x.
/// Total shards n = k + m never exceeds 30.
pub fn compute_adaptive_params(member_count: usize) -> VaultMode {
    match member_count {
        0..6 => VaultMode::FullReplication,
        6..=8 => VaultMode::ErasureCoding { k: 3, m: 2 },
        9..=15 => VaultMode::ErasureCoding { k: 5, m: 3 },
        16..=30 => VaultMode::ErasureCoding { k: 8, m: 4 },
        31..=60 => VaultMode::ErasureCoding { k: 10, m: 5 },
        61..=150 => VaultMode::ErasureCoding { k: 12, m: 6 },
        151..=500 => VaultMode::ErasureCoding { k: 16, m: 8 },
        _ => VaultMode::ErasureCoding { k: 20, m: 10 },
    }
}

/// Apply a storage tier multiplier to the parity shard count.
///
/// All tiers now use the same multiplier (1.0x — no change).
/// `StorageTier::Low` is kept for backward compatibility with existing DB rows
/// but behaves identically to Standard.
///
/// k is never modified — only m changes.
pub fn apply_tier_multiplier(k: usize, m: usize, _tier: StorageTier) -> (usize, usize) {
    (k, m)
}

/// Determine the storage tier from a MIME type.
///
/// All files use Standard tier. `StorageTier::Low` is kept in the enum for
/// backward compatibility with existing DB rows but is no longer produced.
pub fn determine_tier(_mime_type: &str) -> StorageTier {
    StorageTier::Standard
}

// ── Retention policy helpers ─────────────────────────────

/// Parse a retention policy string into days. Returns None for "permanent".
/// Valid values: "permanent", "365d", "180d", "90d", "30d", or custom like "60d".
pub fn parse_retention_days(policy: &str) -> Option<u32> {
    match policy {
        "permanent" | "" => None,
        "365d" => Some(365),
        "180d" => Some(180),
        "90d" => Some(90),
        "30d" => Some(30),
        other => other.trim_end_matches('d').parse().ok(),
    }
}

/// Get the retention policy string from server settings.
///
/// All tiers use `retention_files` (default "365d"). The `tier` parameter is
/// accepted for backward compatibility but ignored — Low is treated as Standard.
pub fn retention_for_tier(
    _tier: StorageTier,
    settings: &HashMap<String, AdminLwwReg<String>>,
) -> String {
    settings
        .get("retention_files")
        .map(|r| r.read().clone())
        .unwrap_or_else(|| "365d".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── compute_adaptive_params ──────────────────────────────

    #[test]
    fn below_6_full_replication() {
        for count in [0, 1, 2, 3, 4, 5] {
            assert_eq!(
                compute_adaptive_params(count),
                VaultMode::FullReplication,
                "member_count={count} should be FullReplication"
            );
        }
    }

    #[test]
    fn exactly_6_erasure() {
        assert_eq!(
            compute_adaptive_params(6),
            VaultMode::ErasureCoding { k: 3, m: 2 }
        );
    }

    #[test]
    fn bracket_6_8() {
        for count in [6, 7, 8] {
            assert_eq!(
                compute_adaptive_params(count),
                VaultMode::ErasureCoding { k: 3, m: 2 },
                "member_count={count}"
            );
        }
    }

    #[test]
    fn bracket_9_15() {
        assert_eq!(
            compute_adaptive_params(9),
            VaultMode::ErasureCoding { k: 5, m: 3 }
        );
        assert_eq!(
            compute_adaptive_params(15),
            VaultMode::ErasureCoding { k: 5, m: 3 }
        );
    }

    #[test]
    fn bracket_16_30() {
        assert_eq!(
            compute_adaptive_params(16),
            VaultMode::ErasureCoding { k: 8, m: 4 }
        );
        assert_eq!(
            compute_adaptive_params(30),
            VaultMode::ErasureCoding { k: 8, m: 4 }
        );
    }

    #[test]
    fn bracket_31_60() {
        assert_eq!(
            compute_adaptive_params(31),
            VaultMode::ErasureCoding { k: 10, m: 5 }
        );
        assert_eq!(
            compute_adaptive_params(60),
            VaultMode::ErasureCoding { k: 10, m: 5 }
        );
    }

    #[test]
    fn bracket_61_150() {
        assert_eq!(
            compute_adaptive_params(61),
            VaultMode::ErasureCoding { k: 12, m: 6 }
        );
        assert_eq!(
            compute_adaptive_params(150),
            VaultMode::ErasureCoding { k: 12, m: 6 }
        );
    }

    #[test]
    fn bracket_151_500() {
        assert_eq!(
            compute_adaptive_params(151),
            VaultMode::ErasureCoding { k: 16, m: 8 }
        );
        assert_eq!(
            compute_adaptive_params(500),
            VaultMode::ErasureCoding { k: 16, m: 8 }
        );
    }

    #[test]
    fn above_500() {
        for count in [501, 1000, 10000, 100000] {
            assert_eq!(
                compute_adaptive_params(count),
                VaultMode::ErasureCoding { k: 20, m: 10 },
                "member_count={count}"
            );
        }
    }

    // ── apply_tier_multiplier ────────────────────────────────

    #[test]
    fn standard_no_change() {
        assert_eq!(apply_tier_multiplier(10, 5, StorageTier::Standard), (10, 5));
        assert_eq!(apply_tier_multiplier(3, 2, StorageTier::Standard), (3, 2));
    }

    #[test]
    fn low_same_as_standard() {
        assert_eq!(apply_tier_multiplier(10, 5, StorageTier::Low), (10, 5));
        assert_eq!(apply_tier_multiplier(5, 3, StorageTier::Low), (5, 3));
        assert_eq!(apply_tier_multiplier(8, 4, StorageTier::Low), (8, 4));
        assert_eq!(apply_tier_multiplier(3, 1, StorageTier::Low), (3, 1));
    }

    // ── determine_tier ───────────────────────────────────────

    #[test]
    fn all_types_standard() {
        assert_eq!(determine_tier("audio/mp3"), StorageTier::Standard);
        assert_eq!(determine_tier("audio/ogg"), StorageTier::Standard);
        assert_eq!(determine_tier("image/webp"), StorageTier::Standard);
        assert_eq!(determine_tier("image/png"), StorageTier::Standard);
        assert_eq!(determine_tier("application/pdf"), StorageTier::Standard);
        assert_eq!(determine_tier("video/mp4"), StorageTier::Standard);
        assert_eq!(determine_tier(""), StorageTier::Standard);
    }

    // ── retention policy helpers ─────────────────────────────

    #[test]
    fn parse_permanent() {
        assert_eq!(parse_retention_days("permanent"), None);
        assert_eq!(parse_retention_days(""), None);
    }

    #[test]
    fn parse_known_policies() {
        assert_eq!(parse_retention_days("365d"), Some(365));
        assert_eq!(parse_retention_days("180d"), Some(180));
        assert_eq!(parse_retention_days("90d"), Some(90));
        assert_eq!(parse_retention_days("30d"), Some(30));
    }

    #[test]
    fn parse_custom() {
        assert_eq!(parse_retention_days("60d"), Some(60));
        assert_eq!(parse_retention_days("7d"), Some(7));
    }

    #[test]
    fn default_retention_standard() {
        let settings: HashMap<String, AdminLwwReg<String>> = HashMap::new();
        assert_eq!(retention_for_tier(StorageTier::Standard, &settings), "365d");
    }

    #[test]
    fn default_retention_low_same_as_standard() {
        let settings: HashMap<String, AdminLwwReg<String>> = HashMap::new();
        assert_eq!(retention_for_tier(StorageTier::Low, &settings), "365d");
    }
}
