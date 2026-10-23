//! Pacing against the relay's circuit breaker (relay-uws/src/breaker.h, phase G2).
//!
//! The relay charges every frame in work units (W) from buckets on our session and trips
//! a frame its bucket cannot pay for. This mirror keeps a level never above the relay's,
//! from the published numbers (pinned against relay-uws/test/breaker_vectors.json), and
//! prices each frame at no less than the relay charges for it, so a frame that goes while
//! `mirror - price >= RESERVE` never trips. Pure: no socket and no clock of its own.

use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};

use super::relay_session::Frame;

pub(crate) const W_START: i64 = 400_000;
pub(crate) const W_CAP: i64 = 800_000;
pub(crate) const W_REFILL_PER_S: i64 = 1_000;
pub(crate) const JOINS_START: i64 = 2_500;
pub(crate) const JOINS_CAP: i64 = 5_000;
pub(crate) const JOINS_REFILL_MILLI_PER_S: i64 = 2_000;
/// The relay's W level never goes below this, so neither does the mirror.
pub(crate) const DEBT_FLOOR: i64 = -100_000;
pub(crate) const SIG_W: i64 = 6;
pub(crate) const DH_W: i64 = 4;
pub(crate) const IDS_PER_W: i64 = 32;
pub(crate) const RESUME_W_PER_ROOM: i64 = 4;
/// New deposit targets the client allows in ten minutes: 80% of the relay's 50,000, whose
/// sketch errs by about 3% where this count is exact.
pub(crate) const DISTINCT_STOP: usize = 40_000;
/// What a frame leaves in the mirror: refill skew from network jitter (16 s of refill) and
/// the frames whose price only bounds the relay's charge loosely.
pub(crate) const RESERVE: i64 = 16_000;
/// A call signal or another small frame may go ahead of a paced bulk frame down to this.
pub(crate) const PRIORITY_RESERVE: i64 = RESERVE / 2;
/// The most a frame may cost and still pass a paced one (a direct, a small room's post).
pub(crate) const PRIORITY_MAX_W: i64 = 64;
const JOINS_RESERVE: i64 = 16;
/// A room the node has given no bound for: the biggest server (512 ids x 3 devices).
pub(crate) const UNKNOWN_SERVER_DEVICES: u32 = 1_536;
pub(crate) const UNKNOWN_ROOM_DEVICES: u32 = 64;
const TOPIC_CATCHUP_W: i64 = 202;
const CHECK_PEERS_W: i64 = 2_050;
/// Any other text frame: the frame, its answer and one signature check.
const OTHER_W: i64 = 10;
/// A destroy order's roster checks, as many as a big roster holds.
const KILL_SIGS: i64 = 64;
const WINDOW: Duration = Duration::from_secs(600);

/// What the client knows of a room's audience.
pub(crate) trait RoomSizes {
    /// Devices this socket was told are in the room (presence).
    fn told(&self, room: &str) -> Option<u32>;
    /// The node's upper bound on the room's devices (`WsCommand::RoomBound`).
    fn bound(&self, room: &str) -> Option<u32>;
    /// The largest list the relay sent for the room lately.
    fn floor(&self, room: &str) -> Option<u32>;
    fn joined(&self) -> usize;
}

/// What one frame costs at the relay: W, and a join.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct Cost {
    pub w: i64,
    pub joins: i64,
}

impl Cost {
    fn w(w: i64) -> Self {
        Self { w, joins: 0 }
    }
}

fn server_shaped(room: &str) -> bool {
    room.starts_with("conf:")
        || ((room.len() == 32 || room.len() == 40) && room.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)))
}

/// The devices a frame into `room` is priced for. Hidden, held and fetch receivers are
/// never in presence, so without the node's bound a room is priced as the biggest of its
/// kind.
pub(crate) fn devices(rooms: &impl RoomSizes, room: &str) -> i64 {
    let seen = rooms.told(room).max(rooms.floor(room)).unwrap_or(0);
    let base = rooms.bound(room).unwrap_or(if server_shaped(room) { UNKNOWN_SERVER_DEVICES } else { UNKNOWN_ROOM_DEVICES });
    i64::from(base.max(seen))
}

/// The deliveries priced for `n` devices: a pad of an eighth (at least 8) covers a kicked
/// member's devices through the relay's door grace.
pub(crate) fn padded(n: i64) -> i64 {
    n + 8.max((n + 7) / 8)
}

fn reach(rooms: &impl RoomSizes, room: &str) -> i64 {
    padded(devices(rooms, room))
}

fn ids_w(n: i64) -> i64 {
    (n + IDS_PER_W - 1) / IDS_PER_W
}

/// A join of `room`: the frame and the answer's list, a door check, the announcement to
/// whoever sees it, and the shown roster checked with the one the relay holds.
pub(crate) fn join_cost(rooms: &impl RoomSizes, room: &str, roster_sigs: i64) -> Cost {
    let e = reach(rooms, room);
    Cost { w: 2 + DH_W + ids_w(e) + e + SIG_W * (2 * roster_sigs + 2 * i64::from(roster_sigs > 0)), joins: 1 }
}

/// What a join's answer lets the mirror take back: the relay announced it to at most the
/// listed peers or the node's bound, whichever is larger.
pub(crate) fn join_refund(rooms: &impl RoomSizes, room: &str, listed: u32, spent: Cost, roster_sigs: i64) -> i64 {
    let n = i64::from(listed.max(rooms.bound(room).unwrap_or(0)));
    let e = padded(n);
    let actual = 2 + DH_W + ids_w(e) + e + SIG_W * (2 * roster_sigs + 2 * i64::from(roster_sigs > 0));
    (spent.w - actual).max(0)
}

fn count_sigs(text: &str) -> i64 {
    text.matches("\"sig\"").count() as i64
}

/// The NUL-ended fields at the head of a client binary frame.
fn fields(frame: &[u8], n: usize) -> Option<Vec<&str>> {
    let mut rest = frame.get(1..)?;
    let mut out = Vec::with_capacity(n);
    for _ in 0..n {
        let at = rest.iter().position(|&b| b == 0)?;
        out.push(std::str::from_utf8(&rest[..at]).ok()?);
        rest = &rest[at + 1..];
    }
    Some(out)
}

fn direct_w(room: &str, rooms: &impl RoomSizes) -> i64 {
    // The frame, one write to the target live and one into its ring in grace; a deposit
    // into an `inbox:` room also reaches its owners online now.
    if room.starts_with("inbox:") {
        3 + rooms.bound(room).max(rooms.told(room)).map_or(8, |n| i64::from(n).max(8))
    } else {
        3
    }
}

/// A room broadcast (0x03, 0x07, 0x0A, `msg`) or a leave's announcement.
pub(crate) fn broadcast_cost(rooms: &impl RoomSizes, room: &str) -> Cost {
    Cost::w(1 + reach(rooms, room))
}

/// A direct (0x02, 0x04, 0x08, `direct`) through `room`.
pub(crate) fn direct_cost(rooms: &impl RoomSizes, room: &str) -> Cost {
    Cost::w(direct_w(room, rooms))
}

/// The price of one frame as it goes on the wire.
pub(crate) fn cost(frame: &Frame, rooms: &impl RoomSizes) -> Cost {
    match frame {
        Frame::Binary(b) => binary_cost(b, rooms),
        Frame::Text(t) => text_cost(t, rooms),
    }
}

fn binary_cost(b: &[u8], rooms: &impl RoomSizes) -> Cost {
    match b.first() {
        Some(0x03 | 0x0A) => fields(b, 1).map_or(Cost::w(1), |f| Cost::w(1 + reach(rooms, f[0]))),
        Some(0x07) => fields(b, 2).map_or(Cost::w(1), |f| Cost::w(1 + reach(rooms, f[0]))),
        Some(0x02 | 0x04 | 0x08) => fields(b, 2).map_or(Cost::w(3), |f| Cost::w(direct_w(f[0], rooms))),
        Some(0x09) => Cost::w(1),
        _ => Cost::w(1),
    }
}

fn text_cost(text: &str, rooms: &impl RoomSizes) -> Cost {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(text) else { return Cost::w(1) };
    let field = |k: &str| v.get(k).and_then(serde_json::Value::as_str).unwrap_or("");
    let len = |k: &str| v.get(k).and_then(serde_json::Value::as_array).map_or(0, |a| a.len() as i64);
    match field("type") {
        "hb" | "ack" | "end" => Cost::w(1),
        "inactive" | "active" => Cost::w(1 + rooms.joined() as i64),
        "join" => join_cost(rooms, field("room"), v.get("inbox_roster").map_or(0, |r| count_sigs(&r.to_string()))),
        "leave" | "msg" => Cost::w(1 + reach(rooms, field("room"))),
        "direct" => Cost::w(direct_w(field("room"), rooms)),
        "topic_catchup" => Cost::w(TOPIC_CATCHUP_W),
        "lock_put" => Cost::w(2 + SIG_W * len("links") + DH_W * reach(rooms, field("server"))),
        "lock_get" => Cost::w(1 + 2 * len("locks").min(256)),
        "check_peers" => Cost::w(CHECK_PEERS_W),
        "discover_peers" => Cost::w(2 + ids_w(reach(rooms, field("room")))),
        "kill_deposit" => Cost::w(2 + SIG_W * (KILL_SIGS + 2) + len("targets")),
        _ => Cost::w(OTHER_W),
    }
}

/// The deposit target a frame may name (the relay counts strangers among them).
pub(crate) fn target(frame: &Frame) -> Option<String> {
    match frame {
        Frame::Binary(b) => match b.first() {
            Some(0x04 | 0x08 | 0x09) => fields(b, 2).map(|f| f[1].to_string()),
            _ => None,
        },
        Frame::Text(t) => {
            let v = serde_json::from_str::<serde_json::Value>(t).ok()?;
            (v.get("type")?.as_str()? == "direct").then(|| v.get("target")?.as_str().map(str::to_string))?
        }
    }
}

/// The one device a frame is written to (a direct of any kind, a file chunk), for keeping
/// each device's frames in order.
pub(crate) fn device_of(frame: &Frame) -> Option<String> {
    match frame {
        Frame::Binary(b) => match b.first() {
            Some(0x02 | 0x04 | 0x08 | 0x09) => fields(b, 2).map(|f| f[1].to_string()),
            _ => None,
        },
        Frame::Text(_) => target(frame),
    }
}

/// The room a frame is about, for keeping each room's frames in order.
pub(crate) fn room_of(frame: &Frame) -> Option<String> {
    match frame {
        Frame::Binary(b) => match b.first() {
            Some(0x02 | 0x03 | 0x04 | 0x07 | 0x08 | 0x09 | 0x0A) => fields(b, 1).map(|f| f[0].to_string()),
            _ => None,
        },
        Frame::Text(t) => {
            let v = serde_json::from_str::<serde_json::Value>(t).ok()?;
            v.get("room").or_else(|| v.get("server"))?.as_str().map(str::to_string)
        }
    }
}

/// One bucket's mirror, in millionths of a unit like the relay's.
#[derive(Clone, Debug)]
struct Mirror {
    u: i64,
    at: Instant,
    cap: i64,
    refill_m: i64,
    /// The relay's floor for this bucket: spending stops there on both sides, so the mirror
    /// stays at or below the relay's level.
    floor: i64,
}

const M: i64 = 1_000_000;

impl Mirror {
    fn new(level: i64, cap: i64, refill_m: i64, floor: i64, now: Instant) -> Self {
        Self { u: level * M, at: now, cap, refill_m, floor }
    }

    fn refill(&mut self, now: Instant) {
        let ms = now.saturating_duration_since(self.at).as_millis().min(864_000_000) as i64;
        self.u = (self.u + ms * self.refill_m).min(self.cap * M);
        self.at = self.at.max(now);
    }

    #[cfg(test)]
    fn level(&self) -> i64 {
        self.u.div_euclid(M)
    }

    fn spend(&mut self, units: i64) {
        self.u = (self.u - units * M).max(self.floor * M);
    }

    fn give_back(&mut self, units: i64) {
        self.u = (self.u + units * M).min(self.cap * M);
    }

    fn at_most(&mut self, level: i64) {
        self.u = self.u.min(level * M);
    }

    /// When the level reaches `target` at the refill.
    fn reaches(&self, target: i64) -> Instant {
        let need = target * M - self.u;
        if need <= 0 {
            return self.at;
        }
        self.at + Duration::from_millis(((need + self.refill_m - 1) / self.refill_m) as u64)
    }
}

/// Deposit targets seen in the last ten minutes, exactly.
#[derive(Debug, Default)]
struct Targets {
    last: HashMap<String, Instant>,
    order: VecDeque<(Instant, String)>,
}

impl Targets {
    fn prune(&mut self, now: Instant) {
        while let Some((at, _)) = self.order.front() {
            if now.saturating_duration_since(*at) < WINDOW {
                break;
            }
            let (at, t) = self.order.pop_front().unwrap_or((now, String::new()));
            if self.last.get(&t) == Some(&at) {
                self.last.remove(&t);
            }
        }
    }

    /// When `target` may be written: now if seen lately or there is room for one more.
    fn ready(&mut self, target: &str, now: Instant) -> Option<Instant> {
        self.prune(now);
        if self.last.contains_key(target) || self.last.len() < DISTINCT_STOP {
            return None;
        }
        self.order.front().map(|(at, _)| *at + WINDOW)
    }

    fn note(&mut self, target: &str, now: Instant) {
        self.last.insert(target.to_string(), now);
        self.order.push_back((now, target.to_string()));
    }
}

/// The mirror of our buckets at the relay.
#[derive(Debug)]
pub(crate) struct Pacer {
    w: Mirror,
    joins: Mirror,
    targets: Targets,
    /// The relay closes a socket that overspends: frames wait. A shadow relay only counts,
    /// so the mirror runs and nothing waits (MED 4 of the G2 review).
    enforced: bool,
}

impl Pacer {
    /// A fresh session the relay started at `credit` (its `auth_ok`).
    pub(crate) fn fresh(credit: i64, enforced: bool, now: Instant) -> Self {
        Self {
            w: Mirror::new(credit.clamp(0, W_CAP), W_CAP, W_REFILL_PER_S * 1_000, DEBT_FLOOR, now),
            joins: Mirror::new(JOINS_START, JOINS_CAP, JOINS_REFILL_MILLI_PER_S, 0, now),
            targets: Targets::default(),
            enforced,
        }
    }

    /// What the relay said of its breaker on a resume (a restart may have changed it).
    pub(crate) fn enforce(&mut self, enforced: bool) {
        self.enforced = enforced;
    }

    /// A resume: the relay charged each room held.
    pub(crate) fn resumed(&mut self, rooms: usize, now: Instant) {
        self.refill(now);
        self.w.spend(RESUME_W_PER_ROOM * rooms as i64);
    }

    /// A resume after a breaker pause: the relay let it in at a level of zero or more and
    /// charged nothing; zero is all the mirror may assume.
    pub(crate) fn after_breaker(&mut self, now: Instant) {
        self.refill(now);
        self.w.at_most(0);
    }

    /// A resume of a session a relay restart restored: it starts at the relay's start
    /// again, whatever the mirror held.
    pub(crate) fn restored(&mut self, now: Instant) {
        self.refill(now);
        self.w.at_most(W_START);
        self.joins.at_most(JOINS_START);
    }

    fn refill(&mut self, now: Instant) {
        self.w.refill(now);
        self.joins.refill(now);
    }

    /// When a frame costing `cost` (to `target`) may go: None for now, and always on a
    /// relay that does not enforce. A priority frame may use half the reserve. A price above
    /// what a full bucket holds past the reserve waits for a full bucket, which the relay
    /// judges it by (LOW 6); it is still spent in full.
    pub(crate) fn wait(&mut self, cost: Cost, target: Option<&str>, now: Instant, priority: bool) -> Option<Instant> {
        if !self.enforced {
            return None;
        }
        self.refill(now);
        let reserve = if priority { PRIORITY_RESERVE } else { RESERVE };
        let cost = Cost { w: cost.w.min(W_CAP - reserve), ..cost };
        let mut at = None::<Instant>;
        let mut later = |t: Instant| {
            if t > now {
                at = Some(at.map_or(t, |a| a.max(t)));
            }
        };
        later(self.w.reaches(cost.w + reserve));
        if cost.joins > 0 {
            later(self.joins.reaches(cost.joins + JOINS_RESERVE));
        }
        if let Some(t) = target
            && let Some(when) = self.targets.ready(t, now)
        {
            later(when);
        }
        at
    }

    /// The frame went: what the relay charges for it.
    pub(crate) fn spend(&mut self, cost: Cost, target: Option<&str>, now: Instant) {
        self.refill(now);
        self.w.spend(cost.w);
        self.joins.spend(cost.joins);
        if let Some(t) = target {
            self.targets.note(t, now);
        }
    }

    /// Part of a price turned out above what the relay charged (a join's answer).
    pub(crate) fn refund(&mut self, w: i64) {
        self.w.give_back(w.max(0));
    }

    #[cfg(test)]
    pub(crate) fn level(&mut self, now: Instant) -> i64 {
        self.refill(now);
        self.w.level()
    }

    #[cfg(test)]
    pub(crate) fn joins_level(&mut self, now: Instant) -> i64 {
        self.refill(now);
        self.joins.level()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[derive(Default)]
    struct Sizes {
        told: HashMap<String, u32>,
        bound: HashMap<String, u32>,
        floor: HashMap<String, u32>,
        joined: usize,
    }

    impl RoomSizes for Sizes {
        fn told(&self, room: &str) -> Option<u32> {
            self.told.get(room).copied()
        }
        fn bound(&self, room: &str) -> Option<u32> {
            self.bound.get(room).copied()
        }
        fn floor(&self, room: &str) -> Option<u32> {
            self.floor.get(room).copied()
        }
        fn joined(&self) -> usize {
            self.joined
        }
    }

    fn vectors() -> serde_json::Value {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../relay-uws/test/breaker_vectors.json");
        serde_json::from_str(&std::fs::read_to_string(path).expect("breaker_vectors.json")).expect("vectors parse")
    }

    fn binary(op: u8, fields: &[&str]) -> Frame {
        let mut v = vec![op];
        for f in fields {
            v.extend_from_slice(f.as_bytes());
            v.push(0);
        }
        v.extend_from_slice(b"payload");
        Frame::Binary(v.into())
    }

    #[test]
    fn the_published_numbers_match_the_relays() {
        let v = vectors();
        let c = &v["constants"];
        let n = |k: &str| c[k].as_i64().unwrap_or_else(|| panic!("{k}"));
        assert_eq!(n("w_start"), W_START);
        assert_eq!(n("w_cap"), W_CAP);
        assert_eq!(n("w_refill_per_s"), W_REFILL_PER_S);
        assert_eq!(n("joins_start"), JOINS_START);
        assert_eq!(n("joins_cap"), JOINS_CAP);
        assert_eq!(n("joins_refill_milli_per_s"), JOINS_REFILL_MILLI_PER_S);
        assert_eq!(n("sig_w"), SIG_W);
        assert_eq!(n("dh_w"), DH_W);
        assert_eq!(n("ids_per_w"), IDS_PER_W);
        assert_eq!(n("resume_w_per_room"), RESUME_W_PER_ROOM);
        assert_eq!(n("client_distinct_stop"), DISTINCT_STOP as i64);
        assert_eq!(n("client_reserve"), RESERVE);
        assert_eq!(n("debt_floor"), DEBT_FLOOR);
        assert_eq!(n("unknown_server_devices"), i64::from(UNKNOWN_SERVER_DEVICES));
        assert_eq!(n("unknown_room_devices"), i64::from(UNKNOWN_ROOM_DEVICES));
        assert!(DISTINCT_STOP as i64 * 10 <= n("distinct_limit") * 8, "the client stops well below the relay");
    }

    #[test]
    fn every_price_matches_the_pinned_vectors() {
        for case in vectors()["costs"].as_array().expect("costs") {
            let name = case["name"].as_str().unwrap_or("?");
            let room = case["room"].as_str().unwrap_or("");
            let mut sizes = Sizes { joined: case["rooms_joined"].as_u64().unwrap_or(0) as usize, ..Sizes::default() };
            for (key, map) in [("told", &mut sizes.told), ("bound", &mut sizes.bound), ("floor", &mut sizes.floor)] {
                if let Some(n) = case[key].as_u64() {
                    map.insert(room.to_string(), n as u32);
                }
            }
            let frame = if let Some(op) = case["hex_op"].as_u64() {
                match op {
                    3 | 10 => binary(op as u8, &[room]),
                    7 => binary(7, &[room, case["topic"].as_str().unwrap_or("t")]),
                    9 => binary(9, &[room, case["target"].as_str().unwrap_or("t"), "chan"]),
                    _ => binary(op as u8, &[room, case["target"].as_str().unwrap_or("t")]),
                }
            } else {
                Frame::text(case["text"].as_str().expect("text").to_string())
            };
            let got = cost(&frame, &sizes);
            assert_eq!(got.w, case["w"].as_i64().unwrap(), "{name}: W");
            assert_eq!(got.joins, case["joins"].as_i64().unwrap(), "{name}: joins");
            assert!(
                got.w > case["relay_deliveries"].as_i64().unwrap_or(0),
                "{name}: the price covers a delivery per receiver"
            );
        }
    }

    #[test]
    fn targets_and_rooms_are_read_off_the_wire() {
        assert_eq!(target(&binary(4, &["dm-a", "peer"])).as_deref(), Some("peer"));
        assert_eq!(target(&binary(9, &["srv", "peer", "chan"])).as_deref(), Some("peer"));
        assert_eq!(target(&binary(3, &["srv"])), None);
        assert_eq!(target(&Frame::text(r#"{"type":"direct","room":"r","target":"t","data":"x"}"#)).as_deref(), Some("t"));
        assert_eq!(room_of(&binary(7, &["srv", "chan"])).as_deref(), Some("srv"));
        assert_eq!(room_of(&Frame::text(r#"{"type":"lock_put","server":"s"}"#)).as_deref(), Some("s"));
        assert_eq!(room_of(&Frame::text(r#"{"type":"check_peers"}"#)), None);
    }

    /// The relay's side of the invariant, simulated: a bucket that starts when the relay
    /// minted the session, refills from then, and is charged exactly the relay's share of
    /// each price (never more than the price).
    struct Relay {
        u: i64,
        at: Instant,
    }

    impl Relay {
        fn level(&mut self, now: Instant) -> i64 {
            let ms = now.saturating_duration_since(self.at).as_millis() as i64;
            self.u = (self.u + ms * W_REFILL_PER_S * 1_000).min(W_CAP * M);
            self.at = now;
            self.u.div_euclid(M)
        }
    }

    #[test]
    fn a_paced_client_never_trips_and_stays_below_the_relay() {
        let t0 = Instant::now();
        // The relay mints first; the client hears `auth_ok` 300 ms later.
        let mut relay = Relay { u: 100_000 * M, at: t0 };
        let mut pace = Pacer::fresh(100_000, true, t0 + Duration::from_millis(300));
        let sizes = Sizes { joined: 50, ..Sizes::default() };
        let mut now = t0 + Duration::from_millis(300);
        let mut sent = 0;
        // A reconnect burst: 400 joins of big servers and 20,000 directs, written as fast
        // as the mirror allows, each charged at the relay a moment after it leaves.
        for i in 0..20_400 {
            let frame = if i < 400 {
                Frame::text(format!(r#"{{"type":"join","room":"{:040x}"}}"#, i))
            } else {
                binary(4, &[&format!("dm-{}", i % 300), &format!("peer{}", i % 300)])
            };
            let c = cost(&frame, &sizes);
            let to = target(&frame);
            if let Some(at) = pace.wait(c, to.as_deref(), now, false) {
                now = at;
            }
            assert!(pace.wait(c, to.as_deref(), now, false).is_none());
            pace.spend(c, to.as_deref(), now);
            let arrives = now + Duration::from_millis(40);
            let level = relay.level(arrives);
            assert!(level - c.w >= 0, "frame {i} would trip: relay {level}, price {}", c.w);
            relay.u -= c.w * M;
            assert!(pace.level(arrives) <= relay.level(arrives), "the mirror stays at or below the relay");
            sent += 1;
        }
        assert_eq!(sent, 20_400);
    }

    #[test]
    fn a_frame_waits_for_its_price_and_the_reserve() {
        let t0 = Instant::now();
        let mut pace = Pacer::fresh(24_000, true, t0);
        let sizes = Sizes::default();
        let join = Frame::text(r#"{"type":"join","room":"0123456789abcdef0123456789abcdef01234567"}"#);
        let c = cost(&join, &sizes);
        let mut went = 0;
        while pace.wait(c, None, t0, false).is_none() {
            pace.spend(c, None, t0);
            went += 1;
        }
        assert_eq!(went, (24_000 - RESERVE - c.w) / c.w + 1, "joins go while the price and the reserve are covered");
        let at = pace.wait(c, None, t0, false).expect("the next waits for the refill");
        let need = c.w + RESERVE - pace.level(t0);
        assert_eq!(at, t0 + Duration::from_millis((need * 1000 / W_REFILL_PER_S) as u64));
        let call = binary(4, &["dm-a", "peer"]);
        assert!(pace.wait(cost(&call, &sizes), None, t0, true).is_none(), "a small priority frame still goes");
    }

    /// MED 4: a relay that only counts never makes a frame wait, but the mirror still runs
    /// (down to the relay's floor), so a resume that says `enforced` paces from the truth.
    #[test]
    fn a_shadow_mirror_runs_but_never_waits() {
        let t0 = Instant::now();
        let mut pace = Pacer::fresh(1_000, false, t0);
        let big = Cost { w: 300_000, joins: 1 };
        assert!(pace.wait(big, Some("t"), t0, false).is_none(), "a shadow relay's client never waits");
        pace.spend(big, Some("t"), t0);
        assert_eq!(pace.level(t0), DEBT_FLOOR, "the mirror stops at the relay's floor");
        pace.enforce(true);
        assert!(pace.wait(big, None, t0, false).is_some(), "an enforcing relay's client waits");
    }

    /// LOW 6: a frame dearer than a full bucket less the reserve waits for a full bucket,
    /// not forever, and is spent in full.
    #[test]
    fn an_oversized_price_waits_for_a_full_bucket() {
        let t0 = Instant::now();
        let mut pace = Pacer::fresh(0, true, t0);
        let huge = Cost::w(2_000_000);
        let at = pace.wait(huge, None, t0, false).expect("it waits");
        assert_eq!(at, t0 + Duration::from_secs((W_CAP / W_REFILL_PER_S) as u64), "until the bucket is full");
        assert!(pace.wait(huge, None, at, false).is_none(), "and then goes");
        pace.spend(huge, None, at);
        assert_eq!(pace.level(at), DEBT_FLOOR);
    }

    #[test]
    fn resumes_and_restarts_move_the_mirror_down_only() {
        let t0 = Instant::now();
        let mut pace = Pacer::fresh(400_000, true, t0);
        pace.resumed(100, t0);
        assert_eq!(pace.level(t0), 400_000 - 400);
        let later = t0 + Duration::from_secs(1_000);
        assert_eq!(pace.level(later), W_CAP);
        pace.restored(later);
        assert_eq!(pace.level(later), W_START, "a restored session starts at the relay's start");
        assert_eq!(pace.joins_level(later), JOINS_START);
        pace.after_breaker(later);
        assert_eq!(pace.level(later), 0, "after a breaker pause the mirror assumes nothing");
    }

    #[test]
    fn joins_and_new_targets_have_their_own_limits() {
        let t0 = Instant::now();
        let mut pace = Pacer::fresh(800_000, true, t0);
        let join = Cost { w: 10, joins: 1 };
        for _ in 0..(JOINS_START - JOINS_RESERVE) {
            assert!(pace.wait(join, None, t0, false).is_none());
            pace.spend(join, None, t0);
        }
        let at = pace.wait(join, None, t0, false).expect("out of joins");
        assert_eq!(at, t0 + Duration::from_millis(500), "a join refills every half second");
        let mut p2 = Pacer::fresh(800_000, true, t0);
        for i in 0..DISTINCT_STOP {
            p2.targets.note(&format!("t{i}"), t0);
        }
        assert!(p2.wait(Cost::w(3), Some("t1"), t0, false).is_none(), "a target seen lately goes");
        assert_eq!(p2.wait(Cost::w(3), Some("new"), t0, false), Some(t0 + WINDOW), "a new one waits for the window");
    }

    #[test]
    fn a_joins_answer_gives_back_what_the_guess_overpaid() {
        let mut sizes = Sizes::default();
        let room = "0123456789abcdef0123456789abcdef01234567";
        let spent = join_cost(&sizes, room, 0);
        assert_eq!(spent.w, 1_788);
        let back = join_refund(&sizes, room, 10, spent, 0);
        assert_eq!(back, 1_788 - (6 + 1 + 18));
        sizes.bound.insert(room.to_string(), 100);
        assert_eq!(join_refund(&sizes, room, 10, spent, 0), 1_788 - (6 + 4 + 113), "never below the node's bound");
    }
}
