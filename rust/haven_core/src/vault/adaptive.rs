use super::content_store::StorageTier;

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
/// - Standard (images, files): 1.0x m — no change.
/// - Low (voice recordings): 0.6x m — rounded up, min 1.
///
/// k is never modified — only m changes.
pub fn apply_tier_multiplier(k: usize, m: usize, tier: StorageTier) -> (usize, usize) {
    let adjusted_m = match tier {
        StorageTier::Standard => m,
        StorageTier::Low => {
            let reduced = ((m as f64) * 0.6).ceil() as usize;
            reduced.max(1)
        }
    };
    (k, adjusted_m)
}

/// Determine the storage tier from a MIME type.
///
/// audio/* → Low (less redundancy, shorter retention).
/// Everything else → Standard.
pub fn determine_tier(mime_type: &str) -> StorageTier {
    if mime_type.starts_with("audio/") {
        StorageTier::Low
    } else {
        StorageTier::Standard
    }
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
    fn low_reduces_m() {
        // ceil(5 * 0.6) = ceil(3.0) = 3
        assert_eq!(apply_tier_multiplier(10, 5, StorageTier::Low), (10, 3));
    }

    #[test]
    fn low_rounds_up() {
        // ceil(3 * 0.6) = ceil(1.8) = 2
        assert_eq!(apply_tier_multiplier(5, 3, StorageTier::Low), (5, 2));
        // ceil(4 * 0.6) = ceil(2.4) = 3
        assert_eq!(apply_tier_multiplier(8, 4, StorageTier::Low), (8, 3));
    }

    #[test]
    fn low_min_m_1() {
        // ceil(1 * 0.6) = ceil(0.6) = 1
        assert_eq!(apply_tier_multiplier(3, 1, StorageTier::Low), (3, 1));
    }

    // ── determine_tier ───────────────────────────────────────

    #[test]
    fn audio_is_low() {
        assert_eq!(determine_tier("audio/mp3"), StorageTier::Low);
        assert_eq!(determine_tier("audio/ogg"), StorageTier::Low);
        assert_eq!(determine_tier("audio/wav"), StorageTier::Low);
        assert_eq!(determine_tier("audio/webm"), StorageTier::Low);
    }

    #[test]
    fn everything_else_standard() {
        assert_eq!(determine_tier("image/webp"), StorageTier::Standard);
        assert_eq!(determine_tier("image/png"), StorageTier::Standard);
        assert_eq!(determine_tier("application/pdf"), StorageTier::Standard);
        assert_eq!(determine_tier("video/mp4"), StorageTier::Standard);
        assert_eq!(determine_tier(""), StorageTier::Standard);
    }
}
