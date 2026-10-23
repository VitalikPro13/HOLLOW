//! The asker side of channel sync: one holder per channel at a time, so a joiner takes
//! one copy of the history instead of one per member device. Only pages we asked for
//! keep an ask, and each new ask starts at another member in an order random per
//! process and channel, so no one member decides for long, or for everyone, what a
//! channel's history looks like (a holder leaving rows out is the residual, B1 L2).

use std::collections::{HashMap, HashSet};
use std::hash::{Hash, Hasher};
use std::time::{Duration, Instant};

use crate::crdt::server_state::ServerState;

/// Wide enough for a holder working through many channels' asks in turn.
pub(crate) const CHANNEL_ASK_SILENCE: Duration =
    if cfg!(test) { Duration::from_secs(3) } else { Duration::from_secs(20) };

/// However it pages; the next holder takes up from where we got to.
pub(crate) const MAX_TENURE: Duration =
    if cfg!(test) { Duration::from_secs(120) } else { Duration::from_secs(600) };

/// Before an open or a Welcome asks for a channel again: a new ask re-serves the
/// 30 minute watermark lookback, and posts since arrived live.
pub(crate) const RECENTLY_SYNCED: Duration =
    if cfg!(test) { Duration::from_secs(8) } else { Duration::from_secs(30) };

/// Peers appearing one after another would each set off another lookback page.
const CATCH_UP_QUIET: Duration = Duration::from_secs(5);

/// A member this new may not hold the history yet (no MLS leaf, posts it missed).
pub(crate) const FRESH_MEMBER_MS: u64 = 10 * 60 * 1000;

/// Asks one sweep may move on, so a holder that leaves never sets off a burst.
const MAX_MOVES_PER_SWEEP: usize = 8;

const NEXT_PAGE_TTL: Duration = Duration::from_secs(300);

/// Asks are ours alone, so this only guards against a bug.
const MAX_ASKS: usize = 4096;

type Key = (String, String);

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Holder {
    pub(crate) device: String,
    pub(crate) master: String,
    pub(crate) standing: Standing,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Standing {
    Established,
    New(u64),
    /// No open span (a count-capped legacy log): asked last.
    Unknown,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Page {
    Last,
    Next(i64),
    /// More follows, but from where this page ends it would come again.
    Stuck,
}

impl Page {
    pub(crate) fn of(has_more: Option<bool>, end: Option<&super::sync_handler::ChannelPageEnd>) -> Self {
        match (has_more == Some(true), end) {
            (false, _) => Page::Last,
            (true, Some(end)) => Page::Next(end.last()),
            (true, None) => Page::Stuck,
        }
    }
}

/// `follow` = ask the sender for the next page; `continued` = not a chain's first page.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct Heard {
    pub(crate) follow: bool,
    pub(crate) continued: bool,
}

struct Ask {
    holder: String,
    tried: Vec<String>,
    tried_people: Vec<String>,
    heard_at: Instant,
    stalled: bool,
}

/// Pages we asked one device for in one channel.
struct Chain {
    began: Instant,
    at: Instant,
    last_end: Option<i64>,
    pages: u32,
}

pub(crate) struct ChannelAsks {
    seed: u64,
    asks: HashMap<Key, Ask>,
    turn: HashMap<Key, usize>,
    chains: HashMap<(String, String, String), Chain>,
    synced_at: HashMap<Key, Instant>,
    started_at: HashMap<Key, Instant>,
    swept_at: Option<Instant>,
}

impl Default for ChannelAsks {
    fn default() -> Self {
        let mut seed = [0u8; 8];
        let _ = getrandom::fill(&mut seed);
        Self::with_seed(u64::from_le_bytes(seed))
    }
}

/// Every online device of a member, other than our own identity and a bare master id
/// (G1), that may be asked for `channel_id`'s history.
pub(crate) fn holders(
    ws_room_peers: &HashMap<String, HashSet<String>>,
    state: &ServerState,
    local_master: &str,
    channel_id: &str,
) -> Vec<Holder> {
    let devices = ws_room_peers
        .values()
        .flatten()
        .filter(|d| !super::resolver::same_identity(d, local_master) && !super::resolver::is_bare_master(d));
    holders_among(state, devices, channel_id)
}

pub(crate) fn holders_among<'a>(
    state: &ServerState,
    devices: impl Iterator<Item = &'a String>,
    channel_id: &str,
) -> Vec<Holder> {
    let now_ms = super::types::now_ms().max(0) as u64;
    let mut seen = HashSet::new();
    devices
        .filter(|d| seen.insert(d.as_str()))
        .filter(|d| super::crypto_handler::sync_partner(Some(state), d, Some(channel_id)))
        .map(|d| {
            let master = super::resolver::resolve(d);
            let standing = match state.member_since(&master) {
                Some(since) if now_ms.saturating_sub(since) >= FRESH_MEMBER_MS => Standing::Established,
                Some(since) => Standing::New(since),
                None => Standing::Unknown,
            };
            Holder { device: d.clone(), master, standing }
        })
        .collect()
}

pub(crate) fn reachable(ws_room_peers: &HashMap<String, HashSet<String>>, device: &str) -> bool {
    ws_room_peers.values().any(|peers| peers.contains(device))
}

/// (device, channel) the committer asks: a re-added leaf may hold posts we missed at a
/// stale epoch, a member that just joined only what it took from us. Never a channel
/// the device's person may not read, as the ask names what we hold of it.
pub(crate) fn post_commit_asks(
    state: &ServerState,
    added: &[String],
    removals: &[String],
    add_masters: &HashMap<String, String>,
    channels: &[String],
    now_ms: u64,
    reachable: impl Fn(&str) -> bool,
) -> Vec<(String, String)> {
    let joined_just_now = |device: &str| {
        !removals.iter().any(|r| r == device)
            && add_masters
                .get(device)
                .and_then(|m| state.member_since(m))
                .is_some_and(|since| now_ms.saturating_sub(since) < FRESH_MEMBER_MS)
    };
    added
        .iter()
        .filter(|d| reachable(d) && !joined_just_now(d))
        .flat_map(|d| {
            channels
                .iter()
                .filter(|c| super::crypto_handler::sync_partner(Some(state), d, Some(c)))
                .map(|c| (d.clone(), c.clone()))
        })
        .collect()
}

fn keyed(seed: u64, parts: &[&str]) -> u64 {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    seed.hash(&mut hasher);
    parts.hash(&mut hasher);
    hasher.finish()
}

/// `holders` grouped by person in this channel's ask order (random per process and
/// channel within a standing, new members oldest first), and how many of them a new
/// ask picks from: those of the best standing present.
fn people_in_order<'a>(seed: u64, key: &Key, holders: &'a [Holder]) -> (Vec<Vec<&'a Holder>>, usize) {
    let rank = |h: &Holder| match h.standing {
        Standing::Established => (0, 0, keyed(seed, &[&key.0, &key.1, &h.master])),
        Standing::New(since) => (1, since, keyed(seed, &[&key.0, &key.1, &h.master])),
        Standing::Unknown => (2, 0, keyed(seed, &[&key.0, &key.1, &h.master])),
    };
    let mut by_person: HashMap<&str, Vec<&Holder>> = HashMap::new();
    for h in holders {
        by_person.entry(h.master.as_str()).or_default().push(h);
    }
    let mut people: Vec<Vec<&Holder>> = by_person.into_values().collect();
    for devices in &mut people {
        devices.sort_by_key(|h| (keyed(seed, &[&key.0, &key.1, &h.device]), h.device.clone()));
        devices.dedup_by(|a, b| a.device == b.device);
    }
    people.sort_by_cached_key(|devices| (rank(devices[0]), devices[0].master.clone()));
    let best = people.first().map(|p| rank(p[0]).0);
    let picks = people.iter().take_while(|p| Some(rank(p[0]).0) == best).count();
    (people, picks)
}

impl ChannelAsks {
    pub(crate) fn with_seed(seed: u64) -> Self {
        Self {
            seed,
            asks: HashMap::new(),
            turn: HashMap::new(),
            chains: HashMap::new(),
            synced_at: HashMap::new(),
            started_at: HashMap::new(),
            swept_at: None,
        }
    }

    fn in_flight(&self, key: &Key, now: Instant) -> bool {
        self.asks.get(key).is_some_and(|a| !a.stalled && !silent(a, now))
    }

    fn synced_within(&self, key: &Key, now: Instant, within: Duration) -> bool {
        self.synced_at.get(key).is_some_and(|at| now.saturating_duration_since(*at) < within)
    }

    /// The device an open asks, or `None` while an ask is under way, just after the
    /// history came in, or with nobody to ask.
    pub(crate) fn start(&mut self, server_id: &str, channel_id: &str, holders: &[Holder], now: Instant) -> Option<String> {
        let key = (server_id.to_string(), channel_id.to_string());
        if self.synced_within(&key, now, RECENTLY_SYNCED) {
            return None;
        }
        self.start_catch_up(server_id, channel_id, holders, now)
    }

    /// [`Self::start`] for a catch-up after a return, however recently the channel synced.
    pub(crate) fn start_catch_up(&mut self, server_id: &str, channel_id: &str, holders: &[Holder], now: Instant) -> Option<String> {
        let key = (server_id.to_string(), channel_id.to_string());
        let just_started = self.started_at.get(&key).is_some_and(|at| now.saturating_duration_since(*at) < CATCH_UP_QUIET);
        if self.in_flight(&key, now) || just_started {
            return None;
        }
        let (people, picks) = people_in_order(self.seed, &key, holders);
        if picks == 0 {
            return None;
        }
        let turn = self.turn.entry(key.clone()).or_insert(0);
        let holder = people[*turn % picks][0].clone();
        *turn = turn.wrapping_add(1);
        if self.started_at.len() >= MAX_ASKS {
            self.started_at.retain(|_, at| now.saturating_duration_since(*at) < CATCH_UP_QUIET);
        }
        self.started_at.insert(key.clone(), now);
        self.insert(key, &holder.device, &holder.master, now);
        Some(holder.device)
    }

    /// Whether the member whose Welcome let us in may be asked for a channel now.
    pub(crate) fn start_with(&mut self, server_id: &str, channel_id: &str, device: &str, master: &str, now: Instant) -> bool {
        let key = (server_id.to_string(), channel_id.to_string());
        if self.in_flight(&key, now) || self.synced_within(&key, now, RECENTLY_SYNCED) {
            return false;
        }
        self.insert(key, device, master, now);
        true
    }

    /// An ask outside the one-holder ask (a re-added leaf, a frame we could not read).
    pub(crate) fn asked_aside(&mut self, server_id: &str, channel_id: &str, device: &str, now: Instant) {
        self.open_chain(server_id, channel_id, device, now);
    }

    fn insert(&mut self, key: Key, device: &str, master: &str, now: Instant) {
        if self.asks.len() >= MAX_ASKS && !self.asks.contains_key(&key) {
            let oldest = self.asks.iter().min_by_key(|(_, a)| a.heard_at).map(|(k, _)| k.clone());
            if let Some(oldest) = oldest {
                self.asks.remove(&oldest);
            }
        }
        self.open_chain(&key.0, &key.1, device, now);
        self.asks.insert(
            key,
            Ask {
                holder: device.to_string(),
                tried: vec![device.to_string()],
                tried_people: vec![master.to_string()],
                heard_at: now,
                stalled: false,
            },
        );
    }

    fn open_chain(&mut self, server_id: &str, channel_id: &str, device: &str, now: Instant) {
        if self.chains.len() >= MAX_ASKS {
            self.chains.retain(|_, c| now.saturating_duration_since(c.at) < NEXT_PAGE_TTL);
        }
        if self.chains.len() < MAX_ASKS {
            let chain = Chain { began: now, at: now, last_end: None, pages: 0 };
            self.chains.insert((server_id.to_string(), channel_id.to_string(), device.to_string()), chain);
        }
    }

    /// Only a page we asked `from` for counts, while each ends past the one before within
    /// [`MAX_TENURE`]. Answers name no ask, so a page ending no further (a replay, a
    /// second answer) is ignored and a last page ends the ask, not the chain.
    pub(crate) fn heard(&mut self, server_id: &str, channel_id: &str, from: &str, page: Page, now: Instant) -> Heard {
        let chain_key = (server_id.to_string(), channel_id.to_string(), from.to_string());
        let Some(chain) = self.chains.get_mut(&chain_key) else { return Heard::default() };
        if now.saturating_duration_since(chain.at) >= NEXT_PAGE_TTL {
            self.chains.remove(&chain_key);
            return Heard::default();
        }
        let continued = chain.pages > 0;
        let key = (server_id.to_string(), channel_id.to_string());
        let ours = self.asks.get_mut(&key).filter(|a| a.holder == from);
        if now.saturating_duration_since(chain.began) >= MAX_TENURE {
            self.chains.remove(&chain_key);
            if let Some(ask) = ours {
                ask.stalled = true;
            }
            return Heard { follow: false, continued };
        }
        match page {
            Page::Next(end) if chain.last_end.is_none_or(|last| end > last) => {
                chain.last_end = Some(end);
                chain.pages += 1;
                chain.at = now;
                if let Some(ask) = ours {
                    ask.heard_at = now;
                }
                return Heard { follow: true, continued };
            }
            Page::Next(_) => {}
            Page::Stuck => {
                if let Some(ask) = ours {
                    ask.stalled = true;
                }
            }
            Page::Last => {
                if ours.is_some() {
                    self.asks.remove(&key);
                    if self.synced_at.len() >= MAX_ASKS {
                        self.synced_at.retain(|_, at| now.saturating_duration_since(*at) < RECENTLY_SYNCED);
                    }
                    self.synced_at.insert(key, now);
                }
            }
        }
        Heard { follow: false, continued }
    }

    /// Asks whose holder went silent, out of reach or stalled, moved to a person not yet
    /// tried (else a device): `(server, channel, holder)` to ask now.
    pub(crate) fn sweep(
        &mut self,
        now: Instant,
        reachable: &dyn Fn(&str) -> bool,
        holders_of: &dyn Fn(&str, &str) -> Vec<Holder>,
    ) -> Vec<(String, String, String)> {
        if self.swept_at.is_some_and(|at| now.saturating_duration_since(at) < Duration::from_secs(1)) {
            return Vec::new();
        }
        self.swept_at = Some(now);
        self.chains.retain(|_, c| now.saturating_duration_since(c.at) < NEXT_PAGE_TTL);
        self.synced_at.retain(|_, at| now.saturating_duration_since(*at) < RECENTLY_SYNCED);
        self.started_at.retain(|_, at| now.saturating_duration_since(*at) < CATCH_UP_QUIET);
        let mut moved = Vec::new();
        let mut ended = Vec::new();
        for (key, ask) in self.asks.iter_mut() {
            if moved.len() >= MAX_MOVES_PER_SWEEP {
                break;
            }
            if !ask.stalled && !silent(ask, now) && reachable(&ask.holder) {
                continue;
            }
            let holders = holders_of(&key.0, &key.1);
            let (people, _) = people_in_order(self.seed, key, &holders);
            let next = people
                .iter()
                .find(|p| !ask.tried_people.contains(&p[0].master))
                .map(|p| p[0])
                .or_else(|| people.iter().flatten().copied().find(|h| !ask.tried.contains(&h.device)));
            match next {
                Some(next) => {
                    ask.holder = next.device.clone();
                    ask.tried.push(next.device.clone());
                    ask.tried_people.push(next.master.clone());
                    ask.heard_at = now;
                    ask.stalled = false;
                    moved.push((key.0.clone(), key.1.clone(), next.device.clone()));
                }
                None => ended.push(key.clone()),
            }
        }
        for key in ended {
            self.asks.remove(&key);
        }
        for (sid, cid, device) in &moved {
            self.open_chain(sid, cid, device, now);
        }
        moved
    }
}

fn silent(ask: &Ask, now: Instant) -> bool {
    now.saturating_duration_since(ask.heard_at) >= CHANNEL_ASK_SILENCE
}

#[cfg(test)]
mod tests {
    use super::*;

    fn people(names: &[&str]) -> Vec<Holder> {
        names
            .iter()
            .map(|n| Holder { device: n.to_string(), master: n.to_string(), standing: Standing::Established })
            .collect()
    }

    fn other(holders: &[Holder], not: &str) -> String {
        holders.iter().find(|h| h.device != not).unwrap().device.clone()
    }

    #[test]
    fn one_ask_per_channel_at_a_time_and_the_next_ask_rotates() {
        let mut asks = ChannelAsks::with_seed(7);
        let holders = people(&["a", "b", "c"]);
        let t0 = Instant::now();
        let first = asks.start("s", "c", &holders, t0).expect("a holder");
        assert_eq!(asks.start("s", "c", &holders, t0), None, "one ask at a time");
        assert!(!asks.start_with("s", "c", "b", "b", t0), "a Welcome's ask waits for the one under way");
        assert!(!asks.heard("s", "c", &first, Page::Last, t0).continued, "a first page continues nothing");
        assert_eq!(asks.start("s", "c", &holders, t0), None, "an open right after the history came in asks nobody");
        assert!(!asks.start_with("s", "c", "b", "b", t0), "nor does a Welcome");
        let quiet = t0 + CATCH_UP_QUIET;
        let caught_up = asks.start_catch_up("s", "c", &holders, quiet).expect("a catch-up asks anyway");
        assert_ne!(caught_up, first, "at the next holder in turn");
        asks.heard("s", "c", &caught_up, Page::Last, quiet);
        let later = quiet + RECENTLY_SYNCED;
        let third = asks.start("s", "c", &holders, later).expect("a later open asks");
        assert!(third != first && third != caught_up, "and the turn goes round every holder");
    }

    #[test]
    fn a_catch_up_right_after_another_started_asks_nobody() {
        let mut asks = ChannelAsks::with_seed(1);
        let holders = people(&["a", "b"]);
        let t0 = Instant::now();
        let first = asks.start_catch_up("s", "c", &holders, t0).unwrap();
        asks.heard("s", "c", &first, Page::Last, t0);
        assert_eq!(asks.start_catch_up("s", "c", &holders, t0 + CATCH_UP_QUIET / 2), None);
        assert!(asks.start_catch_up("s", "c", &holders, t0 + CATCH_UP_QUIET).is_some());
        // A Welcome's ask is no catch-up: the return right after the join asks again.
        assert!(asks.start_with("s", "d", "a", "a", t0));
        asks.heard("s", "d", "a", Page::Last, t0);
        assert!(asks.start_catch_up("s", "d", &holders, t0).is_some());
    }

    #[test]
    fn a_silent_holder_hands_the_ask_on_and_its_pages_keep_it() {
        let mut asks = ChannelAsks::with_seed(2);
        let holders = people(&["a", "b"]);
        let t0 = Instant::now();
        let first = asks.start("s", "c", &holders, t0).unwrap();
        let of = |_: &str, _: &str| people(&["a", "b"]);
        let up = |_: &str| true;
        assert!(asks.sweep(t0 + CHANNEL_ASK_SILENCE / 2, &up, &of).is_empty());
        assert!(asks.heard("s", "c", &first, Page::Next(10), t0 + CHANNEL_ASK_SILENCE / 2).follow);
        assert!(asks.sweep(t0 + CHANNEL_ASK_SILENCE, &up, &of).is_empty(), "a page of the ask keeps it");
        let moved = asks.sweep(t0 + CHANNEL_ASK_SILENCE * 2, &up, &of);
        assert_eq!(moved, vec![("s".to_string(), "c".to_string(), other(&holders, &first))]);
        let late = asks.heard("s", "c", &first, Page::Next(20), t0 + CHANNEL_ASK_SILENCE * 2);
        assert!(late.follow, "a late answer from the holder it left is still ours to follow");
        let late_again = asks.heard("s", "c", &first, Page::Next(30), t0 + CHANNEL_ASK_SILENCE * 3);
        assert!(late_again.follow);
        assert!(
            asks.start_catch_up("s", "c", &holders, t0 + CHANNEL_ASK_SILENCE * 3).is_some(),
            "but they do not keep the ask it left",
        );
    }

    #[test]
    fn a_holder_that_leaves_hands_the_ask_on_at_once() {
        let mut asks = ChannelAsks::with_seed(3);
        let holders = people(&["a", "b"]);
        let t0 = Instant::now();
        let first = asks.start("s", "c", &holders, t0).unwrap();
        let next = other(&holders, &first);
        let left = |d: &str| d != first;
        let of = |_: &str, _: &str| people(&[next.as_str()]);
        let moved = asks.sweep(t0 + Duration::from_secs(2), &left, &of);
        assert_eq!(moved, vec![("s".to_string(), "c".to_string(), next.clone())]);
    }

    /// Review HIGH 1: unsolicited pages of another channel every two seconds once held
    /// every ask of their sender forever.
    #[test]
    fn pages_nobody_asked_for_never_keep_an_ask() {
        let mut asks = ChannelAsks::with_seed(4);
        let holders = people(&["mal", "honest1", "honest2"]);
        let t0 = Instant::now();
        let mal = asks.start("s", "general", &holders, t0).unwrap();
        let of = |_: &str, _: &str| people(&["mal", "honest1", "honest2"]);
        let mut moved = None;
        for step in 1..=10u64 {
            let now = t0 + Duration::from_secs(2 * step);
            for page in [Page::Last, Page::Next(step as i64), Page::Stuck] {
                assert_eq!(asks.heard("s", "offtopic", &mal, page, now), Heard::default(), "a page nobody asked for is not followed");
            }
            if let Some(m) = asks.sweep(now, &|_| true, &of).into_iter().next() {
                moved = Some((m.2, now));
                break;
            }
        }
        let (next, at) = moved.expect("the ask moved on");
        assert_ne!(next, mal);
        assert!(!asks.heard("s", "general", &next, Page::Last, at).follow);
        assert_eq!(asks.start("s", "general", &holders, at), None, "its history came in from the next holder");
    }

    /// Review HIGH 1: a replayed page claiming more follows (here every second, against
    /// a 3 s silence) once kept the ask forever. A page ending no further than the one
    /// before is not followed and keeps nothing; a later page that moves on still is
    /// (an answer can come twice when we asked twice).
    #[test]
    fn a_page_that_ends_no_further_keeps_no_ask() {
        let of = |_: &str, _: &str| people(&["mal", "honest"]);
        for replay in [100, 99] {
            let mut asks = ChannelAsks::with_seed(5);
            let holders = people(&["mal", "honest"]);
            let t0 = Instant::now();
            let mal = asks.start("s", "general", &holders, t0).unwrap();
            assert_eq!(asks.heard("s", "general", &mal, Page::Next(100), t0), Heard { follow: true, continued: false });
            let mut moved = None;
            for step in 1..=10u64 {
                let now = t0 + Duration::from_secs(step);
                let heard = asks.heard("s", "general", &mal, Page::Next(replay), now);
                assert_eq!(heard, Heard { follow: false, continued: true }, "a replay of {replay} is followed");
                if let Some(m) = asks.sweep(now, &|_| true, &of).into_iter().next() {
                    moved = Some((m, step));
                    break;
                }
            }
            let ((_, _, next), step) = moved.expect("the ask moved on");
            assert_eq!((next, step), (other(&holders, &mal), 3), "after its silence, replays or not");
            assert!(asks.heard("s", "general", &mal, Page::Next(200), t0).follow, "the chain itself goes on");
        }
    }

    /// Review LOW 6: a page that claims more follows but cannot advance hands the ask on
    /// at once, and does not count as the history having come in.
    #[test]
    fn a_page_that_cannot_advance_hands_the_ask_on() {
        let of = |_: &str, _: &str| people(&["mal", "honest"]);
        let mut asks = ChannelAsks::with_seed(5);
        let holders = people(&["mal", "honest"]);
        let t0 = Instant::now();
        let mal = asks.start("s", "general", &holders, t0).unwrap();
        assert!(asks.heard("s", "general", &mal, Page::Next(100), t0).follow);
        assert_eq!(asks.heard("s", "general", &mal, Page::Stuck, t0), Heard { follow: false, continued: true });
        let moved = asks.sweep(t0 + Duration::from_millis(10), &|_| true, &of);
        assert_eq!(moved, vec![("s".into(), "general".into(), other(&holders, &mal))]);
        asks.sweep(t0 + CHANNEL_ASK_SILENCE * 2, &|_| true, &of);
        assert!(asks.start_with("s", "general", "honest", "honest", t0 + CHANNEL_ASK_SILENCE * 2), "not synced");
    }

    /// An answer to an earlier ask of ours (here an empty last page, sent before the
    /// rows existed) ends the ask, but the answer to the later ask still pages through.
    #[test]
    fn an_answer_to_an_earlier_ask_does_not_end_what_follows() {
        let mut asks = ChannelAsks::with_seed(8);
        let holders = people(&["o"]);
        let t0 = Instant::now();
        let o = asks.start("s", "c", &holders, t0).unwrap();
        assert!(!asks.heard("s", "c", &o, Page::Last, t0).follow);
        assert_eq!(asks.start("s", "c", &holders, t0), None, "the ask ended with a last page");
        assert!(asks.heard("s", "c", &o, Page::Next(10), t0).follow, "the next answer is still ours to follow");
        assert!(asks.heard("s", "c", &o, Page::Next(20), t0).follow);
    }

    #[test]
    fn a_holder_keeps_an_ask_no_longer_than_its_tenure() {
        let mut asks = ChannelAsks::with_seed(6);
        let holders = people(&["slow", "other"]);
        let t0 = Instant::now();
        let slow = asks.start("s", "c", &holders, t0).unwrap();
        let of = |_: &str, _: &str| people(&["slow", "other"]);
        let step = CHANNEL_ASK_SILENCE / 2;
        let mut now = t0;
        let mut end = 0;
        while now + step < t0 + MAX_TENURE {
            now += step;
            end += 1;
            assert!(asks.heard("s", "c", &slow, Page::Next(end), now).follow);
            assert!(asks.sweep(now, &|_| true, &of).is_empty(), "moved before its tenure ran out");
        }
        let past = t0 + MAX_TENURE;
        assert!(!asks.heard("s", "c", &slow, Page::Next(end + 1), past).follow, "a chain past its tenure is not followed");
        assert_eq!(asks.sweep(past + Duration::from_secs(1), &|_| true, &of), vec![("s".into(), "c".into(), other(&holders, &slow))]);
    }

    /// Review MED 2: every process started each channel at the same first holder.
    #[test]
    fn first_asks_spread_over_holders_by_process_and_channel() {
        let holders = people(&["oldest", "b", "c", "d"]);
        let now = Instant::now();
        let mut firsts: HashMap<String, usize> = HashMap::new();
        for seed in 0..5 {
            let mut asks = ChannelAsks::with_seed(seed);
            for ch in 0..20 {
                *firsts.entry(asks.start_catch_up("s", &format!("ch{ch}"), &holders, now).unwrap()).or_default() += 1;
            }
        }
        assert_eq!(firsts.len(), 4, "{firsts:?}");
        assert!(firsts.values().all(|n| *n >= 10), "{firsts:?}");
        let random: HashSet<String> =
            (0..5).map(|_| ChannelAsks::default().start_catch_up("s", "ch", &holders, now).unwrap()).collect();
        let more: HashSet<String> = (0..20)
            .map(|ch| ChannelAsks::default().start_catch_up("s", &format!("ch{ch}"), &holders, now).unwrap())
            .chain(random)
            .collect();
        assert!(more.len() > 1, "every fresh process asks the same holder first");
    }

    /// Review MED 2: the hand-on went device by device, so a person with k devices was
    /// tried k times before anyone else.
    #[test]
    fn a_person_with_many_devices_is_tried_once_before_the_others() {
        let mut holders: Vec<Holder> = (1..=4)
            .map(|i| Holder { device: format!("m-dev{i}"), master: "m".into(), standing: Standing::Established })
            .collect();
        holders.extend(people(&["honest"]));
        for seed in 0..8 {
            let mut asks = ChannelAsks::with_seed(seed);
            let t0 = Instant::now();
            let mut order = vec![asks.start("s", "c", &holders, t0).unwrap()];
            let of = |_: &str, _: &str| holders.clone();
            for k in 1..=5u32 {
                order.extend(asks.sweep(t0 + CHANNEL_ASK_SILENCE * k, &|_| true, &of).into_iter().map(|m| m.2));
            }
            let person = |d: &str| if d.starts_with("m-dev") { "m" } else { "honest" };
            assert_ne!(person(&order[0]), person(&order[1]), "seed {seed}: {order:?}");
            assert_eq!(order.len(), 5, "then the person's other devices: {order:?}");
        }
    }

    /// Members of standing are asked before new ones (which may not hold the history
    /// yet), new ones oldest first, and members with no span last.
    #[test]
    fn standing_decides_who_is_asked_first() {
        let h = |d: &str, standing| Holder { device: d.into(), master: d.into(), standing };
        let all = vec![
            h("u", Standing::Unknown),
            h("n1", Standing::New(5)),
            h("n2", Standing::New(1)),
            h("e1", Standing::Established),
            h("e2", Standing::Established),
        ];
        let now = Instant::now();
        for ch in 0..20 {
            let mut asks = ChannelAsks::with_seed(ch);
            let cid = format!("ch{ch}");
            let first = asks.start_catch_up("s", &cid, &all, now).unwrap();
            assert!(first.starts_with('e'), "{first}");
            let of = |_: &str, _: &str| all.clone();
            let rest: Vec<String> = (1..=4u32)
                .flat_map(|k| asks.sweep(now + CHANNEL_ASK_SILENCE * k, &|_| true, &of))
                .map(|m| m.2)
                .collect();
            assert!(rest[0].starts_with('e') && rest[0] != first);
            assert_eq!(rest[1..], ["n2", "n1", "u"]);
            // New asks go round the members of standing only.
            for k in 1..=3u32 {
                let at = now + CHANNEL_ASK_SILENCE * 5 + RECENTLY_SYNCED * k;
                let next = asks.start("s", &cid, &all, at).unwrap();
                assert!(next.starts_with('e'), "ask {k} went to {next}");
                asks.heard("s", &cid, &next, Page::Last, at);
            }
        }
        // With nobody of standing, the oldest member is everyone's first ask.
        let fresh: Vec<Holder> = all.iter().filter(|x| !x.device.starts_with('e')).cloned().collect();
        for ch in 0..20 {
            assert_eq!(ChannelAsks::default().start_catch_up("s", &format!("ch{ch}"), &fresh, now).as_deref(), Some("n2"));
        }
    }

    #[test]
    fn asks_aside_are_followed_and_pages_nobody_asked_for_are_not() {
        let mut asks = ChannelAsks::with_seed(9);
        let t0 = Instant::now();
        asks.asked_aside("s", "c", "a", t0);
        assert_eq!(asks.heard("s", "c", "b", Page::Next(5), t0), Heard::default());
        assert_eq!(asks.heard("s", "c", "a", Page::Next(5), t0), Heard { follow: true, continued: false });
        assert_eq!(asks.heard("s", "c", "a", Page::Next(6), t0), Heard { follow: true, continued: true });
        assert_eq!(asks.heard("s", "c", "a", Page::Last, t0), Heard { follow: false, continued: true });
        assert_eq!(asks.heard("s", "c", "a", Page::Next(6), t0), Heard { follow: false, continued: true }, "no further than before");
        assert!(asks.start_with("s", "c", "a", "a", t0), "an ask aside ends no one-holder ask");
    }

    fn server_with_member() -> (ServerState, String, String) {
        use crate::crdt::operations::{CrdtPayload, JoinAsk};
        use crate::crdt::testkeys::keys;
        let (kp, owner, pk) = keys(1);
        let (mut state, _) = ServerState::found("S".into(), owner.clone(), kp, pk);
        let sid = state.server_id.clone();
        let member = keys(2).1;
        let ask = JoinAsk::sign(&sid, 1, &keys(2).0);
        state
            .author_checked(CrdtPayload::MemberAdded { peer_id: member.clone(), display_name: "m".into(), follow: None, ask: Some(ask) })
            .expect("the owner admits");
        (state, owner, member)
    }

    #[test]
    fn holders_are_members_devices_never_a_stranger_in_the_room_nor_ourselves() {
        let (state, owner, member) = server_with_member();
        let sid = state.server_id.clone();
        let stranger = crate::crdt::testkeys::keys(3).1;
        let rooms = HashMap::from([(sid.clone(), HashSet::from([owner.clone(), member.clone(), stranger]))]);
        let general = format!("{}-general", &sid[..8]);
        let found: Vec<String> = holders(&rooms, &state, &owner, &general).into_iter().map(|h| h.device).collect();
        assert_eq!(found, vec![member.clone()]);
        let mine = holders_among(&state, [member.clone()].iter(), &general);
        assert_eq!(mine[0].master, member);
        assert!(matches!(mine[0].standing, Standing::New(_)), "a member who joined just now is new");
    }

    /// Review LOW 4: the committer asked a re-added device for channels its person may
    /// not read, naming what we hold of them.
    #[test]
    fn a_commit_asks_an_added_device_only_for_channels_it_may_read() {
        let (mut state, _owner, member) = server_with_member();
        let sid = state.server_id.clone();
        let general = format!("{}-general", &sid[..8]);
        let mut secret = state.channels[&general].clone();
        secret.visibility = crate::crdt::server_state::ChannelVisibility::AdminPlus;
        state.channels.insert("secret".into(), secret);
        let channels = vec![general.clone(), "secret".to_string()];
        let masters = HashMap::from([(member.clone(), member.clone())]);
        let added = vec![member.clone()];
        let now_ms = super::super::types::now_ms() as u64;
        let up = |_: &str| true;
        assert_eq!(
            post_commit_asks(&state, &added, &added, &masters, &channels, now_ms, up),
            vec![(member.clone(), general.clone())],
            "a re-added leaf is asked for what it may read",
        );
        assert!(post_commit_asks(&state, &added, &[], &masters, &channels, now_ms, up).is_empty(), "a new member is not asked");
        assert!(post_commit_asks(&state, &added, &added, &masters, &channels, now_ms, |_| false).is_empty(), "nor one out of reach");
        let later = now_ms + FRESH_MEMBER_MS;
        assert_eq!(post_commit_asks(&state, &added, &[], &masters, &channels, later, up), vec![(member, general)]);
    }
}
