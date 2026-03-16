use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};

/// A Hybrid Logical Clock timestamp providing deterministic total ordering.
///
/// Ordering: physical_ms → counter → actor (lexicographic on actor string).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct HlcTimestamp {
    pub physical_ms: u64,
    pub counter: u32,
    pub actor: String,
}

impl HlcTimestamp {
    pub fn zero(actor: &str) -> Self {
        Self {
            physical_ms: 0,
            counter: 0,
            actor: actor.to_string(),
        }
    }
}

impl Ord for HlcTimestamp {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.physical_ms
            .cmp(&other.physical_ms)
            .then(self.counter.cmp(&other.counter))
            .then(self.actor.cmp(&other.actor))
    }
}

impl PartialOrd for HlcTimestamp {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

/// Hybrid Logical Clock — generates monotonically increasing timestamps.
#[derive(Debug, Clone)]
pub struct Hlc {
    latest: HlcTimestamp,
    actor: String,
}

impl Hlc {
    /// Create a new HLC seeded with the current wall clock.
    pub fn new(actor: String) -> Self {
        let physical_ms = wall_clock_ms();
        Self {
            latest: HlcTimestamp {
                physical_ms,
                counter: 0,
                actor: actor.clone(),
            },
            actor,
        }
    }

    /// Restore an HLC from persisted state.
    pub fn from_saved(physical_ms: u64, counter: u32, actor: String) -> Self {
        Self {
            latest: HlcTimestamp {
                physical_ms,
                counter,
                actor: actor.clone(),
            },
            actor,
        }
    }

    /// Generate a new timestamp, guaranteed to be greater than all previously
    /// generated or witnessed timestamps.
    pub fn now(&mut self) -> HlcTimestamp {
        let wall = wall_clock_ms();
        if wall > self.latest.physical_ms {
            self.latest = HlcTimestamp {
                physical_ms: wall,
                counter: 0,
                actor: self.actor.clone(),
            };
        } else {
            self.latest.counter += 1;
            self.latest.actor = self.actor.clone();
        }
        self.latest.clone()
    }

    /// Update the clock after observing a remote timestamp.
    /// Ensures our next `now()` will be strictly greater.
    pub fn witness(&mut self, other: &HlcTimestamp) {
        let wall = wall_clock_ms();

        // SECURITY: Reject timestamps more than 5 minutes ahead of wall clock.
        // Prevents a malicious peer from advancing our HLC to the far future,
        // which would give their LWW values permanent precedence.
        const MAX_DRIFT_MS: u64 = 5 * 60 * 1000; // 5 minutes
        if other.physical_ms > wall + MAX_DRIFT_MS {
            haven_log!("[HAVEN-SECURITY] HLC drift rejected: remote physical_ms {} is {} ms ahead of wall clock {}", other.physical_ms, other.physical_ms - wall, wall);
            return;
        }

        let max_physical = wall.max(self.latest.physical_ms).max(other.physical_ms);

        if max_physical == self.latest.physical_ms
            && max_physical == other.physical_ms
        {
            // All three equal — take max counter + 1
            self.latest.counter = self.latest.counter.max(other.counter) + 1;
        } else if max_physical == self.latest.physical_ms {
            // Our physical time is ahead — just increment
            self.latest.counter += 1;
        } else if max_physical == other.physical_ms {
            // Remote is ahead — adopt their counter + 1
            self.latest.physical_ms = other.physical_ms;
            self.latest.counter = other.counter + 1;
        } else {
            // Wall clock is ahead of both — reset counter
            self.latest.physical_ms = max_physical;
            self.latest.counter = 0;
        }
        self.latest.actor = self.actor.clone();
    }

    /// Current latest timestamp (for persistence).
    pub fn physical_ms(&self) -> u64 {
        self.latest.physical_ms
    }

    /// Current counter value (for persistence).
    pub fn counter(&self) -> u32 {
        self.latest.counter
    }

    /// The actor ID for this clock.
    pub fn actor(&self) -> &str {
        &self.actor
    }
}

fn wall_clock_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn monotonically_increasing() {
        let mut hlc = Hlc::new("peer_a".into());
        let t1 = hlc.now();
        let t2 = hlc.now();
        let t3 = hlc.now();
        assert!(t1 < t2);
        assert!(t2 < t3);
    }

    #[test]
    fn witness_advances_past_remote() {
        let mut hlc_a = Hlc::new("peer_a".into());
        let mut hlc_b = Hlc::new("peer_b".into());

        let t_a1 = hlc_a.now();
        hlc_b.witness(&t_a1);
        let t_b1 = hlc_b.now();

        // B's timestamp must be after A's
        assert!(t_b1 > t_a1);
    }

    #[test]
    fn concurrent_timestamps_ordered_by_actor() {
        let mut hlc_a = Hlc::from_saved(1000, 0, "peer_a".into());
        let mut hlc_b = Hlc::from_saved(1000, 0, "peer_b".into());

        let t_a = hlc_a.now();
        let t_b = hlc_b.now();

        // Same physical time and counter, differ by actor
        assert_ne!(t_a, t_b);
        // Deterministic order: "peer_a" < "peer_b"
        assert!(t_a < t_b);
    }

    #[test]
    fn serde_round_trip() {
        let ts = HlcTimestamp {
            physical_ms: 1709337600000,
            counter: 42,
            actor: "12D3KooW...".into(),
        };
        let json = serde_json::to_string(&ts).unwrap();
        let back: HlcTimestamp = serde_json::from_str(&json).unwrap();
        assert_eq!(ts, back);
    }
}
