//! Presence audits (g13): instead of asking the relay for every room's full peer list
//! every 30 s, a device asks now and then for a DIGEST of what the relay would list to
//! it, compares it with what its socket was told, and re-joins only on a difference.
//!
//! The comparison runs in ws_client against its own record of the presence frames, at
//! the moment the answer is READ: the relay writes presence and the answer on one
//! socket in order, so every frame the digest counts arrived before it. The digest is
//! pinned with the relay (`relay-uws/src/presence_view.h`).

use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use sha2::{Digest as _, Sha256};

/// Rebootstrap ticks (30 s each) between two audits of one room.
pub(crate) const AUDIT_TICKS: u64 = 10;
/// A difference is asked once more after this long before it counts: a frame the
/// relay sent just before the answer can explain a single miss.
const RECHECK_MS: (u64, u64) = (6_000, 10_000);
/// An ask whose answer never came (a socket that died without a session).
const ASK_TIMEOUT: Duration = Duration::from_secs(60);
/// A room that still differs right after the re-join a drift caused waits this long
/// before the next audit, doubling up to [`BACKOFF_CAP`].
const BACKOFF_BASE: Duration = Duration::from_secs(300);
const BACKOFF_CAP: Duration = Duration::from_secs(30 * 60);

/// A peer id's share of a digest: the first 8 bytes, little endian, of
/// SHA-256("hollow-presence1\n" || id).
pub(crate) fn tag(id: &str) -> u64 {
    let mut h = Sha256::new();
    h.update(b"hollow-presence1\n");
    h.update(id.as_bytes());
    let out = h.finalize();
    u64::from_le_bytes(out[..8].try_into().unwrap_or([0; 8]))
}

/// The wrapping tag sum of `ids` and how many there are.
pub(crate) fn digest<'a>(ids: impl IntoIterator<Item = &'a String>) -> (u64, u64) {
    ids.into_iter().fold((0u64, 0u64), |(sum, n), id| (sum.wrapping_add(tag(id)), n + 1))
}

/// Whether `room` is audited by `device` on rebootstrap tick `tick`: once every
/// [`AUDIT_TICKS`], each room and device on its own phase.
pub(crate) fn due_on_tick(room: &str, device: &str, tick: u64) -> bool {
    tag(&format!("{room}\n{device}")) % AUDIT_TICKS == tick % AUDIT_TICKS
}

/// The relay's answer to a digest ask.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Answer {
    Digest { sum: u64, count: u64 },
    /// This socket does not hold the room's slot.
    NotJoined,
}

/// What an answer means for the room.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Verdict {
    /// No ask of ours was waiting for it, or a `members` since made it stale.
    Ignored,
    Same,
    /// It differs once: asked again shortly.
    Recheck,
    /// It still differs: the node re-joins the room.
    Drift,
    /// It differs right after the drift's re-join: audits of the room pause this long.
    Backoff(Duration),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Check {
    Regular,
    Recheck,
    /// The first check after a drift's re-join.
    Verify,
}

#[derive(Debug)]
struct Asked {
    check: Check,
    at: Instant,
    /// A `members` for the room arrived after the ask: its answer may predate it.
    stale: bool,
}

#[derive(Debug, Default)]
struct RoomAudit {
    asked: Option<Asked>,
    /// A check this side owes, and when.
    owed: Option<(Check, Instant)>,
    /// Re-joined for a drift; that join's `members` arms the verify.
    rejoining: bool,
    /// Drifts in a row that a re-join did not settle.
    strikes: u32,
    quiet_until: Option<Instant>,
}

/// What this socket was told of each room's presence, and the audits in flight.
#[derive(Debug, Default)]
pub(crate) struct Audit {
    told: HashMap<String, HashSet<String>>,
    rooms: HashMap<String, RoomAudit>,
}

impl Audit {
    #[cfg(test)]
    pub(crate) fn told(&self, room: &str) -> Option<&HashSet<String>> {
        self.told.get(room)
    }

    /// Whether this socket was told `peer` is in `room`.
    pub(crate) fn told_has(&self, room: &str, peer: &str) -> bool {
        self.told.get(room).is_some_and(|t| t.contains(peer))
    }

    /// How many peers this socket was told are in `room`.
    pub(crate) fn told_count(&self, room: &str) -> Option<usize> {
        self.told.get(room).map(HashSet::len)
    }

    /// A `members` snapshot: the room's record is replaced, without ourselves.
    pub(crate) fn on_members(&mut self, room: &str, peers: &[String], me: &str, now: Instant) {
        self.told.insert(room.to_string(), peers.iter().filter(|p| p.as_str() != me).cloned().collect());
        let Some(r) = self.rooms.get_mut(room) else { return };
        if let Some(asked) = r.asked.as_mut() {
            asked.stale = true;
        }
        if std::mem::take(&mut r.rejoining) {
            r.owed = Some((Check::Verify, now + recheck_delay()));
        }
    }

    pub(crate) fn on_joined(&mut self, room: &str, peer: &str) {
        self.told.entry(room.to_string()).or_default().insert(peer.to_string());
    }

    pub(crate) fn on_left(&mut self, room: &str, peer: &str) {
        if let Some(peers) = self.told.get_mut(room) {
            peers.remove(peer);
        }
    }

    /// A join that will bring no `members` (dropped as the echo of a replay): the
    /// drift it answered is settled by that replay's own `members`, so no verify waits.
    pub(crate) fn rejoin_dropped(&mut self, room: &str) {
        if let Some(r) = self.rooms.get_mut(room) {
            r.rejoining = false;
        }
    }

    /// We left the room.
    pub(crate) fn forget(&mut self, room: &str) {
        self.told.remove(room);
        self.rooms.remove(room);
    }

    /// The session is gone: nothing told on it stands.
    pub(crate) fn clear(&mut self) {
        self.told.clear();
        self.rooms.clear();
    }

    /// The node's periodic audit of `room`: false (nothing to send) while the room
    /// pauses after failed re-joins, or a check of it is already under way.
    pub(crate) fn start(&mut self, room: &str, now: Instant) -> bool {
        let r = self.rooms.entry(room.to_string()).or_default();
        if r.asked.as_ref().is_some_and(|a| now.saturating_duration_since(a.at) >= ASK_TIMEOUT) {
            r.asked = None;
        }
        if r.asked.is_some() || r.owed.is_some() || r.quiet_until.is_some_and(|t| now < t) {
            return false;
        }
        r.quiet_until = None;
        r.asked = Some(Asked { check: Check::Regular, at: now, stale: false });
        true
    }

    /// The owed checks that fell due: each is asked now.
    pub(crate) fn due(&mut self, now: Instant) -> Vec<String> {
        let mut out = Vec::new();
        for (room, r) in self.rooms.iter_mut() {
            if let Some((check, at)) = r.owed
                && at <= now
            {
                r.owed = None;
                r.asked = Some(Asked { check, at: now, stale: false });
                out.push(room.clone());
            }
        }
        out.sort();
        out
    }

    /// When the next owed check falls due.
    pub(crate) fn next_due(&self) -> Option<Instant> {
        self.rooms.values().filter_map(|r| r.owed.map(|(_, at)| at)).min()
    }

    /// Owed checks are dropped while the app is in the background (the relay withholds
    /// presence from us then).
    pub(crate) fn pause(&mut self) {
        for r in self.rooms.values_mut() {
            r.owed = None;
            r.asked = None;
        }
    }

    /// The relay answered for `room`. `holds` = the node still wants the room.
    pub(crate) fn on_answer(&mut self, room: &str, answer: Answer, holds: bool, now: Instant) -> Verdict {
        let Some(r) = self.rooms.get_mut(room) else { return Verdict::Ignored };
        let Some(asked) = r.asked.take() else { return Verdict::Ignored };
        if asked.stale {
            return Verdict::Ignored;
        }
        let same = match answer {
            Answer::NotJoined => !holds,
            Answer::Digest { sum, count } => {
                digest(self.told.get(room).into_iter().flatten()) == (sum, count)
            }
        };
        if same {
            r.strikes = 0;
            r.quiet_until = None;
            return Verdict::Same;
        }
        match asked.check {
            Check::Regular => {
                r.owed = Some((Check::Recheck, now + recheck_delay()));
                Verdict::Recheck
            }
            Check::Recheck => {
                r.rejoining = true;
                Verdict::Drift
            }
            Check::Verify => {
                r.strikes = r.strikes.saturating_add(1);
                let wait = BACKOFF_BASE.saturating_mul(1u32 << (r.strikes - 1).min(8)).min(BACKOFF_CAP);
                r.quiet_until = Some(now + wait);
                Verdict::Backoff(wait)
            }
        }
    }
}

fn recheck_delay() -> Duration {
    let mut buf = [0u8; 8];
    let _ = getrandom::fill(&mut buf);
    let (lo, hi) = RECHECK_MS;
    Duration::from_millis(lo + u64::from_le_bytes(buf) % (hi - lo + 1))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    fn answer_for(v: &[&str]) -> Answer {
        let set: Vec<String> = ids(v);
        let (sum, count) = digest(set.iter());
        Answer::Digest { sum, count }
    }

    #[test]
    fn tag_matches_the_relays_pinned_vector() {
        assert_eq!(tag("12D3KooWPresenceKatA"), 11532386673268010517);
        assert_eq!(tag("12D3KooWPresenceKatB"), 16287333660574689903);
        assert_eq!(tag("12D3KooWPresenceKatC"), 10475476554576081470);
        let all = ids(&["12D3KooWPresenceKatA", "12D3KooWPresenceKatB", "12D3KooWPresenceKatC"]);
        assert_eq!(digest(all.iter()), (1401708740999678658, 3), "the sum wraps");
        assert_eq!(tag("room\ndev"), 2571280644734662145);
    }

    #[test]
    fn each_room_is_audited_once_per_period() {
        for room in ["a", "b", "0123456789abcdef0123456789abcdef01234567", "inbox:x"] {
            let hits = (0..AUDIT_TICKS * 3).filter(|t| due_on_tick(room, "dev", *t)).count();
            assert_eq!(hits as u64, 3, "{room}");
        }
    }

    #[test]
    fn the_record_follows_members_joins_and_leaves() {
        let now = Instant::now();
        let mut a = Audit::default();
        a.on_members("r", &ids(&["me", "x", "y"]), "me", now);
        assert_eq!(a.told("r").unwrap(), &ids(&["x", "y"]).into_iter().collect::<HashSet<_>>(), "never ourselves");
        a.on_joined("r", "z");
        a.on_left("r", "x");
        assert_eq!(a.told("r").unwrap(), &ids(&["y", "z"]).into_iter().collect::<HashSet<_>>());
        a.forget("r");
        assert!(a.told("r").is_none());
        a.on_joined("s", "q");
        a.clear();
        assert!(a.told("s").is_none());
    }

    #[test]
    fn a_matching_answer_is_quiet() {
        let now = Instant::now();
        let mut a = Audit::default();
        a.on_members("r", &ids(&["me", "x"]), "me", now);
        assert!(a.start("r", now));
        assert!(!a.start("r", now), "one check at a time");
        assert_eq!(a.on_answer("r", answer_for(&["x"]), true, now), Verdict::Same);
        assert_eq!(a.on_answer("r", answer_for(&["x"]), true, now), Verdict::Ignored, "no ask waits");
    }

    #[test]
    fn a_difference_is_rechecked_then_drifts() {
        let now = Instant::now();
        let mut a = Audit::default();
        a.on_members("r", &ids(&["me", "x"]), "me", now);
        assert!(a.start("r", now));
        assert_eq!(a.on_answer("r", answer_for(&["x", "y"]), true, now), Verdict::Recheck);
        let at = a.next_due().expect("a recheck is owed");
        assert!(at >= now + Duration::from_millis(6_000) && at <= now + Duration::from_millis(10_000));
        assert!(a.due(now).is_empty(), "not before its time");
        assert!(!a.start("r", now), "the node's audit waits for the recheck");
        assert_eq!(a.due(at), vec!["r".to_string()]);
        assert_eq!(a.on_answer("r", answer_for(&["x", "y"]), true, at), Verdict::Drift);
    }

    #[test]
    fn a_recheck_that_matches_settles() {
        let now = Instant::now();
        let mut a = Audit::default();
        a.on_members("r", &ids(&["me", "x"]), "me", now);
        a.start("r", now);
        a.on_answer("r", answer_for(&["x", "y"]), true, now);
        let at = a.next_due().unwrap();
        a.due(at);
        a.on_joined("r", "y");
        assert_eq!(a.on_answer("r", answer_for(&["x", "y"]), true, at), Verdict::Same);
    }

    #[test]
    fn a_members_between_ask_and_answer_voids_it() {
        let now = Instant::now();
        let mut a = Audit::default();
        a.on_members("r", &ids(&["me", "x"]), "me", now);
        a.start("r", now);
        a.on_members("r", &ids(&["me", "x", "y"]), "me", now);
        assert_eq!(a.on_answer("r", answer_for(&["x"]), true, now), Verdict::Ignored);
        assert!(a.start("r", now), "the next audit goes out");
    }

    #[test]
    fn not_joined_differs_only_for_a_room_we_hold() {
        let now = Instant::now();
        let mut a = Audit::default();
        a.start("r", now);
        assert_eq!(a.on_answer("r", Answer::NotJoined, false, now), Verdict::Same);
        a.start("r", now);
        assert_eq!(a.on_answer("r", Answer::NotJoined, true, now), Verdict::Recheck);
    }

    #[test]
    fn a_room_that_still_differs_after_its_rejoin_backs_off() {
        let mut now = Instant::now();
        let mut a = Audit::default();
        a.on_members("r", &ids(&["me"]), "me", now);
        let mut waits = Vec::new();
        for _ in 0..5 {
            assert!(a.start("r", now), "audited again once the pause is over");
            assert_eq!(a.on_answer("r", answer_for(&["ghost"]), true, now), Verdict::Recheck);
            now = a.next_due().unwrap();
            a.due(now);
            assert_eq!(a.on_answer("r", answer_for(&["ghost"]), true, now), Verdict::Drift);
            a.on_members("r", &ids(&["me"]), "me", now);
            now = a.next_due().expect("the re-join's members arms a verify");
            assert_eq!(a.due(now), vec!["r".to_string()]);
            match a.on_answer("r", answer_for(&["ghost"]), true, now) {
                Verdict::Backoff(w) => waits.push(w),
                v => panic!("{v:?}"),
            }
            assert!(!a.start("r", now), "paused");
            now += waits.last().copied().unwrap();
        }
        let mins: Vec<u64> = waits.iter().map(|w| w.as_secs() / 60).collect();
        assert_eq!(mins, vec![5, 10, 20, 30, 30], "doubling to 30 minutes");
        a.start("r", now);
        assert_eq!(a.on_answer("r", answer_for(&[]), true, now), Verdict::Same);
        assert!(a.start("r", now), "a match ends the pause");
    }

    #[test]
    fn a_rejoin_that_brings_no_members_arms_no_verify() {
        let now = Instant::now();
        let mut a = Audit::default();
        a.on_members("r", &ids(&["me"]), "me", now);
        a.start("r", now);
        a.on_answer("r", answer_for(&["x"]), true, now);
        let at = a.next_due().unwrap();
        a.due(at);
        assert_eq!(a.on_answer("r", answer_for(&["x"]), true, at), Verdict::Drift);
        a.rejoin_dropped("r");
        a.on_members("r", &ids(&["me", "x"]), "me", at);
        assert!(a.next_due().is_none(), "a later members is no answer to a join that never went out");
    }

    #[test]
    fn a_lost_answer_does_not_block_the_room() {
        let now = Instant::now();
        let mut a = Audit::default();
        assert!(a.start("r", now));
        assert!(!a.start("r", now + Duration::from_secs(30)));
        assert!(a.start("r", now + ASK_TIMEOUT), "an answer that never came is given up");
    }

    #[test]
    fn pause_drops_owed_checks() {
        let now = Instant::now();
        let mut a = Audit::default();
        a.start("r", now);
        a.on_answer("r", answer_for(&["x"]), true, now);
        assert!(a.next_due().is_some());
        a.pause();
        assert!(a.next_due().is_none());
        assert!(a.start("r", now));
    }
}
