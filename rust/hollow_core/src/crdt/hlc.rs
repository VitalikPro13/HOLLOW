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

/// How far ahead of our wall clock a remote timestamp may sit before we treat it as
/// hostile. `Hlc::witness` refuses to advance OUR clock past it and
/// `ServerState::admit_remote_op` refuses the op outright: a `physical_ms = u64::MAX`
/// would otherwise win every future LWW comparison and lock the field forever.
pub(crate) const MAX_DRIFT_MS: u64 = 5 * 60 * 1000; // 5 minutes

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
            self.step_to(successor(self.latest.physical_ms, self.latest.counter));
        }
        self.latest.clone()
    }

    /// Update the clock after observing a remote timestamp.
    /// Ensures our next `now()` will be strictly greater.
    pub fn witness(&mut self, other: &HlcTimestamp) {
        let wall = wall_clock_ms();

        // SECURITY: a peer that advanced our HLC to the far future would give their LWW
        // values permanent precedence. This protects OUR clock only; the op itself is
        // refused against the same bound by `ServerState::admit_remote_op`.
        if other.physical_ms > wall + MAX_DRIFT_MS {
            hollow_log!("[HOLLOW-SECURITY] HLC drift rejected: remote physical_ms {} is {} ms ahead of wall clock {}", other.physical_ms, other.physical_ms - wall, wall);
            return;
        }

        let max_physical = wall.max(self.latest.physical_ms).max(other.physical_ms);

        let next = if max_physical == self.latest.physical_ms
            && max_physical == other.physical_ms
        {
            // All three equal — take max counter + 1
            successor(max_physical, self.latest.counter.max(other.counter))
        } else if max_physical == self.latest.physical_ms {
            // Our physical time is ahead — just increment
            successor(max_physical, self.latest.counter)
        } else if max_physical == other.physical_ms {
            // Remote is ahead — adopt their counter + 1
            successor(max_physical, other.counter)
        } else {
            // Wall clock is ahead of both — reset counter
            (max_physical, 0)
        };
        self.step_to(next);
    }

    fn step_to(&mut self, (physical_ms, counter): (u64, u32)) {
        self.latest.physical_ms = physical_ms;
        self.latest.counter = counter;
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

/// The timestamp right after `(physical_ms, counter)`. A remote peer picks its own
/// counter, so at `u32::MAX` the millisecond steps instead: the clock can neither
/// panic nor wrap below a timestamp it has already witnessed.
fn successor(physical_ms: u64, counter: u32) -> (u64, u32) {
    match counter.checked_add(1) {
        Some(counter) => (physical_ms, counter),
        None => (physical_ms.saturating_add(1), 0),
    }
}

pub(crate) fn wall_clock_ms() -> u64 {
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

    /// E14: a remote counter at its ceiling must neither panic the clock nor wrap it
    /// below what it witnessed, on every witness branch and on the next `now()`.
    #[test]
    fn a_counter_at_its_ceiling_moves_the_clock_forward() {
        let ahead = wall_clock_ms() + 60_000;
        let remote = HlcTimestamp { physical_ms: ahead, counter: u32::MAX, actor: "remote".into() };

        let mut behind = Hlc::new("local".into());
        behind.witness(&remote);
        assert!(behind.now() > remote, "adopting a remote counter at its ceiling");

        let mut level = Hlc::from_saved(ahead, 7, "local".into());
        level.witness(&remote);
        assert!(level.now() > remote, "equal physical times, remote counter at its ceiling");

        let mut own = Hlc::from_saved(ahead, u32::MAX, "local".into());
        let before = HlcTimestamp { physical_ms: ahead, counter: u32::MAX, actor: "local".into() };
        assert!(own.now() > before, "our own counter at its ceiling");
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
