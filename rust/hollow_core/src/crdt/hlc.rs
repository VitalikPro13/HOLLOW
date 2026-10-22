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
/// `ServerState::ingest_remote` refuses the op outright: a `physical_ms = u64::MAX`
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

/// How many counter lanes the siblings of one identity spread over. A WIRE constant:
/// every device of an identity must agree on it, so it never changes.
pub(crate) const LANES: u32 = 1 << 24;

/// The counter lane a device mints in. Siblings share the HLC actor (the master, which
/// `verify_signed` binds to the author), so without their own lanes two of them can
/// mint the same (master, stamp), and replicas keep whichever copy arrived first.
pub(crate) fn lane_of(device_peer_id: &str) -> u32 {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(format!("hollow-hlc-lane1:{device_peer_id}").as_bytes());
    u32::from_be_bytes([digest[0], digest[1], digest[2], digest[3]]) % LANES
}

/// Hybrid Logical Clock — generates monotonically increasing timestamps.
#[derive(Debug, Clone)]
pub struct Hlc {
    latest: HlcTimestamp,
    actor: String,
    /// `None` = the lane-less clock of 0.12.2 and earlier, kept for tests of that shape.
    lane: Option<u32>,
}

impl Hlc {
    /// The clock a device signs its master's ops with: every counter it mints is
    /// congruent to its own lane, so no sibling can mint the same stamp.
    pub fn for_device(master: String, device_peer_id: &str) -> Self {
        Self::seeded(master, Some(lane_of(device_peer_id)))
    }

    /// A lane-less clock, as every client before 0.13 ran.
    #[cfg(test)]
    pub fn new(actor: String) -> Self {
        Self::seeded(actor, None)
    }

    fn seeded(actor: String, lane: Option<u32>) -> Self {
        Self {
            latest: HlcTimestamp { physical_ms: wall_clock_ms(), counter: 0, actor: actor.clone() },
            actor,
            lane,
        }
    }

    /// A device's clock last stepped at `(physical_ms, 0)`.
    #[cfg(test)]
    pub fn for_device_at(master: String, device_peer_id: &str, physical_ms: u64) -> Self {
        let mut hlc = Self::for_device(master, device_peer_id);
        hlc.step_to((physical_ms, 0));
        hlc
    }

    /// The lane this clock mints in, `None` for a lane-less one.
    #[cfg(test)]
    pub fn lane(&self) -> Option<u32> {
        self.lane
    }

    /// A lane-less clock restored at a given point.
    #[cfg(test)]
    pub fn from_saved(physical_ms: u64, counter: u32, actor: String) -> Self {
        Self {
            latest: HlcTimestamp { physical_ms, counter, actor: actor.clone() },
            actor,
            lane: None,
        }
    }

    /// Generate a new timestamp, guaranteed to be greater than all previously
    /// generated or witnessed timestamps.
    pub fn now(&mut self) -> HlcTimestamp {
        self.now_at(wall_clock_ms())
    }

    fn now_at(&mut self, wall: u64) -> HlcTimestamp {
        let next = if wall > self.latest.physical_ms {
            (wall, self.lane.unwrap_or(0))
        } else {
            self.next_after(self.latest.physical_ms, self.latest.counter)
        };
        self.step_to(next);
        self.latest.clone()
    }

    /// Update the clock after observing a remote timestamp.
    /// Ensures our next `now()` will be strictly greater.
    pub fn witness(&mut self, other: &HlcTimestamp) {
        self.witness_at(other, wall_clock_ms());
    }

    fn witness_at(&mut self, other: &HlcTimestamp, wall: u64) {
        // SECURITY: a peer that advanced our HLC to the far future would give their LWW
        // values permanent precedence. This protects OUR clock only; the op itself is
        // refused against the same bound by `ServerState::ingest_remote`.
        if other.physical_ms > wall + MAX_DRIFT_MS {
            hollow_log!("[HOLLOW-SECURITY] HLC drift rejected: remote physical_ms {} is {} ms ahead of wall clock {}", other.physical_ms, other.physical_ms - wall, wall);
            return;
        }
        if self.lane.is_some() {
            // Only remember the newest point seen: `now_at` steps past it into our lane,
            // so a sync batch of old ops cannot stride our counter into the next ms.
            if (other.physical_ms, other.counter) > (self.latest.physical_ms, self.latest.counter) {
                self.step_to((other.physical_ms, other.counter));
            }
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

    /// The first stamp after `(physical_ms, counter)` that is ours to mint.
    fn next_after(&self, physical_ms: u64, counter: u32) -> (u64, u32) {
        let Some(lane) = self.lane else { return successor(physical_ms, counter) };
        let (counter, lane64, lanes) = (u64::from(counter), u64::from(lane), u64::from(LANES));
        let in_block = counter - counter % lanes + lane64;
        let next = if in_block > counter { in_block } else { in_block + lanes };
        match u32::try_from(next) {
            Ok(next) => (physical_ms, next),
            Err(_) => (physical_ms.saturating_add(1), lane),
        }
    }

    fn step_to(&mut self, (physical_ms, counter): (u64, u32)) {
        self.latest.physical_ms = physical_ms;
        self.latest.counter = counter;
        self.latest.actor = self.actor.clone();
    }

    /// The millisecond of the newest stamp minted or witnessed.
    #[cfg(test)]
    pub fn physical_ms(&self) -> u64 {
        self.latest.physical_ms
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

    /// Two siblings' clocks, last stepped just before `wall`.
    fn two_lanes(wall: u64) -> (Hlc, Hlc) {
        let (mut a, mut b) = (Hlc::for_device("M".into(), "desktop"), Hlc::for_device("M".into(), "phone"));
        assert_ne!(a.lane, b.lane, "fixture devices must hash to different lanes");
        a.step_to((wall - 1, 0));
        b.step_to((wall - 1, 0));
        (a, b)
    }

    fn in_lane(hlc: &Hlc, ts: &HlcTimestamp) -> bool {
        ts.counter % LANES == hlc.lane.unwrap()
    }

    /// g13-h: the reviewer's probe. Two siblings witnessed the same op from a peer whose
    /// clock runs ahead, then mint seconds apart: the lane-less clocks mint one stamp.
    #[test]
    fn siblings_after_a_peer_ahead_mint_distinct_stamps() {
        let wall = 1_000_000_000;
        let ahead = HlcTimestamp { physical_ms: wall + 120_000, counter: 0, actor: "other".into() };

        let (mut old_desktop, mut old_phone) = (Hlc::new("M".into()), Hlc::new("M".into()));
        old_desktop.witness_at(&ahead, wall);
        old_phone.witness_at(&ahead, wall);
        assert_eq!(old_desktop.now_at(wall + 37), old_phone.now_at(wall + 537), "control: the 0.12.2 clock collides");

        let (mut desktop, mut phone) = two_lanes(wall);
        desktop.witness_at(&ahead, wall);
        phone.witness_at(&ahead, wall);
        let (a, b) = (desktop.now_at(wall + 37), phone.now_at(wall + 537));
        assert_ne!(a, b);
        assert!(a > ahead && b > ahead, "both still follow what they witnessed");
        assert!(in_lane(&desktop, &a) && in_lane(&phone, &b));
    }

    /// g13-h: two siblings minting in the same wall millisecond.
    #[test]
    fn siblings_in_one_millisecond_mint_distinct_stamps() {
        let wall = 1_000_000_000;
        let (mut old_a, mut old_b) = (Hlc::from_saved(wall - 1, 0, "M".into()), Hlc::from_saved(wall - 1, 0, "M".into()));
        assert_eq!(old_a.now_at(wall), old_b.now_at(wall), "control: the 0.12.2 clock collides");

        let (mut a, mut b) = two_lanes(wall);
        for _ in 0..300 {
            let (ta, tb) = (a.now_at(wall), b.now_at(wall));
            assert_ne!(ta, tb);
            assert!(in_lane(&a, &ta) && in_lane(&b, &tb));
        }
    }

    /// g13-h: whatever the clock witnesses, each stamp is in the device's lane and above
    /// everything before it, including at the counter's ceiling.
    #[test]
    fn every_stamp_stays_in_the_lane_and_climbs() {
        let wall = 1_000_000_000;
        let (mut hlc, _) = two_lanes(wall);
        let mut last = hlc.now_at(wall);
        assert!(in_lane(&hlc, &last));
        let seen = [0, 1, LANES - 1, LANES, LANES + 1, 7 * LANES + 3, u32::MAX - 1, u32::MAX];
        for counter in seen {
            let remote = HlcTimestamp { physical_ms: last.physical_ms, counter, actor: "r".into() };
            hlc.witness_at(&remote, wall);
            let ts = hlc.now_at(wall);
            assert!(ts > last && ts > remote, "{ts:?} after {last:?} and {remote:?}");
            assert!(in_lane(&hlc, &ts), "{ts:?} left the lane");
            last = ts;
        }
    }

    /// g13-h: old stamps a sync batch replays do not stride the counter: the next mint is
    /// one lane step, not one per witnessed op.
    #[test]
    fn witnessing_older_stamps_does_not_move_the_clock() {
        let wall = 1_000_000_000;
        let (mut hlc, _) = two_lanes(wall);
        let first = hlc.now_at(wall);
        for i in 0..1000u32 {
            hlc.witness_at(&HlcTimestamp { physical_ms: wall - 1, counter: i, actor: "r".into() }, wall);
        }
        let next = hlc.now_at(wall);
        assert_eq!((next.physical_ms, next.counter), (wall, first.counter + LANES));
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
