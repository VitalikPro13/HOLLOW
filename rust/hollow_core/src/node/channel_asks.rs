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

/// A holder that could not help a hole is asked for it again after this: it may have
/// filled its own history meanwhile.
const SHORT_TTL: Duration = Duration::from_secs(30 * 60);

/// Holders remembered as short of one hole; past them the rest are asked again.
const MAX_SHORT_HOLDERS: usize = 64;

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

/// What an ask asks for: everything past our watermarks, or the part of the history
/// below a page that vouched only for its newest stretch (`channel_hole_request`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum Kind {
    #[default]
    Catch,
    Hole,
}

/// `follow` = ask the sender for the next page; `continued` = not a chain's first page;
/// `filled` = the page ended the ask for the hole, which is no more; `again` = ask the
/// sender now, for this.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct Heard {
    pub(crate) follow: bool,
    pub(crate) continued: bool,
    pub(crate) filled: bool,
    pub(crate) again: Option<Kind>,
}

struct Ask {
    holder: String,
    tried: Vec<String>,
    tried_people: Vec<String>,
    heard_at: Instant,
    stalled: bool,
    kind: Kind,
}

/// Pages we asked one device for in one channel.
struct Chain {
    began: Instant,
    at: Instant,
    last_end: Option<i64>,
    pages: u32,
    kind: Kind,
    /// Where the chain's first partial page started vouching: its later pages, asked
    /// from past it, say nothing of what lies below.
    held: Option<i64>,
}

pub(crate) struct ChannelAsks {
    seed: u64,
    asks: HashMap<Key, Ask>,
    turn: HashMap<Key, usize>,
    chains: HashMap<(String, String, String), Chain>,
    synced_at: HashMap<Key, Instant>,
    started_at: HashMap<Key, Instant>,
    swept_at: Option<Instant>,
    /// Per channel, the holders that vouched from at or above its hole's top (the top).
    short: HashMap<Key, (i64, HashMap<String, Instant>)>,
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
            short: HashMap::new(),
        }
    }

    fn in_flight(&self, key: &Key, now: Instant) -> bool {
        self.asks.get(key).is_some_and(|a| !a.stalled && !silent(a, now))
    }

    fn synced_within(&self, key: &Key, now: Instant, within: Duration) -> bool {
        self.synced_at.get(key).is_some_and(|at| now.saturating_duration_since(*at) < within)
    }

    /// The device an open asks, or `None` while an ask is under way, just after the
    /// history came in, or with nobody to ask. Every ask catches up first: a hole waits
    /// for the new posts, never the other way round.
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
        self.open_chain(server_id, channel_id, device, Kind::Catch, now);
    }

    /// Of a page from `from`: `None` when we opened no ask of it (nothing it says is
    /// noted), else where it vouches from (its own `held_from`, else where its chain's
    /// first partial page began vouching) and which ask it answers.
    pub(crate) fn page_held(&mut self, server_id: &str, channel_id: &str, from: &str, held_from: Option<i64>, now: Instant) -> Option<(Option<i64>, Kind)> {
        let chain_key = (server_id.to_string(), channel_id.to_string(), from.to_string());
        let chain = self.chains.get_mut(&chain_key).filter(|c| now.saturating_duration_since(c.at) < NEXT_PAGE_TTL)?;
        if chain.held.is_none() {
            chain.held = held_from;
        }
        Some((held_from.or(chain.held), chain.kind))
    }

    fn insert(&mut self, key: Key, device: &str, master: &str, now: Instant) {
        if self.asks.len() >= MAX_ASKS && !self.asks.contains_key(&key) {
            let oldest = self.asks.iter().min_by_key(|(_, a)| a.heard_at).map(|(k, _)| k.clone());
            if let Some(oldest) = oldest {
                self.asks.remove(&oldest);
            }
        }
        self.open_chain(&key.0, &key.1, device, Kind::Catch, now);
        self.asks.insert(
            key,
            Ask {
                holder: device.to_string(),
                tried: vec![device.to_string()],
                tried_people: vec![master.to_string()],
                heard_at: now,
                stalled: false,
                kind: Kind::Catch,
            },
        );
    }

    fn open_chain(&mut self, server_id: &str, channel_id: &str, device: &str, kind: Kind, now: Instant) {
        if self.chains.len() >= MAX_ASKS {
            self.chains.retain(|_, c| now.saturating_duration_since(c.at) < NEXT_PAGE_TTL);
        }
        if self.chains.len() < MAX_ASKS {
            let chain = Chain { began: now, at: now, last_end: None, pages: 0, kind, held: None };
            self.chains.insert((server_id.to_string(), channel_id.to_string(), device.to_string()), chain);
        }
    }

    /// Only a page we asked `from` for counts, while each ends past the one before within
    /// [`MAX_TENURE`]. Answers name no ask, so a page ending no further (a replay, a
    /// second answer) is ignored and a last page ends the ask, not the chain. `held` is
    /// where the page vouches from ([`Self::page_held`]), `hole` the top of our hole once
    /// it is noted: a last catch-up page moves the ask on to the hole (at the same holder
    /// unless it vouched only for part), a hole ask ending whole or narrowing it away
    /// fills it, and a holder vouching from at or above the top is skipped for that hole.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn hear(&mut self, server_id: &str, channel_id: &str, from: &str, page: Page, held: Option<i64>, hole: Option<i64>, now: Instant) -> Heard {
        let chain_key = (server_id.to_string(), channel_id.to_string(), from.to_string());
        let Some(chain) = self.chains.get_mut(&chain_key) else { return Heard::default() };
        if now.saturating_duration_since(chain.at) >= NEXT_PAGE_TTL {
            self.chains.remove(&chain_key);
            return Heard::default();
        }
        let continued = chain.pages > 0;
        let kind = chain.kind;
        let key = (server_id.to_string(), channel_id.to_string());
        if let (Some(held), Some(top)) = (held, hole)
            && held >= top
        {
            note_short(&mut self.short, &key, from, top, now);
        }
        let short_of_hole = hole.is_some_and(|top| is_short(&self.short, &key, from, top, now));
        let ours = self.asks.get_mut(&key).filter(|a| a.holder == from);
        if now.saturating_duration_since(chain.began) >= MAX_TENURE {
            self.chains.remove(&chain_key);
            if let Some(ask) = ours {
                ask.stalled = true;
            }
            return Heard { follow: false, continued, ..Heard::default() };
        }
        match page {
            Page::Next(end) if chain.last_end.is_none_or(|last| end > last) => {
                chain.last_end = Some(end);
                chain.at = now;
                chain.pages += 1;
                if let Some(ask) = ours {
                    ask.heard_at = now;
                }
                return Heard { follow: true, continued, ..Heard::default() };
            }
            Page::Next(_) => {}
            Page::Stuck => {
                if let Some(ask) = ours {
                    ask.stalled = true;
                }
            }
            Page::Last => {
                let filled = kind == Kind::Hole && (held.is_none() || hole.is_none());
                let Some(ask) = ours else { return Heard { continued, filled, ..Heard::default() } };
                let mut again = None;
                if kind == Kind::Catch && hole.is_some() {
                    // The rest is the hole: from the same holder unless it vouched only for
                    // part, now or lately (a catch-up page from it may not reach its X).
                    ask.kind = Kind::Hole;
                    ask.heard_at = now;
                    if held.is_some() || short_of_hole {
                        ask.stalled = true;
                    } else {
                        again = Some(Kind::Hole);
                    }
                } else if (kind == Kind::Hole && !filled) || (kind == Kind::Catch && held.is_some()) {
                    // Another holder may hold what this one could not vouch for.
                    ask.stalled = true;
                } else {
                    self.asks.remove(&key);
                    if self.synced_at.len() >= MAX_ASKS {
                        self.synced_at.retain(|_, at| now.saturating_duration_since(*at) < RECENTLY_SYNCED);
                    }
                    self.synced_at.insert(key.clone(), now);
                }
                if filled {
                    self.short.remove(&key);
                }
                if let Some(kind) = again {
                    self.open_chain(server_id, channel_id, from, kind, now);
                }
                return Heard { follow: false, continued, filled, again };
            }
        }
        Heard { follow: false, continued, ..Heard::default() }
    }

    /// Asks whose holder went silent, out of reach or stalled, moved to a person not yet
    /// tried (else a device): `(server, channel, holder, kind)` to ask now. A hole skips
    /// the holders that lately vouched from at or above its top.
    pub(crate) fn sweep_asks(
        &mut self,
        now: Instant,
        reachable: &dyn Fn(&str) -> bool,
        holders_of: &dyn Fn(&str, &str) -> Vec<Holder>,
    ) -> Vec<(String, String, String, Kind)> {
        if self.swept_at.is_some_and(|at| now.saturating_duration_since(at) < Duration::from_secs(1)) {
            return Vec::new();
        }
        self.swept_at = Some(now);
        self.chains.retain(|_, c| now.saturating_duration_since(c.at) < NEXT_PAGE_TTL);
        self.synced_at.retain(|_, at| now.saturating_duration_since(*at) < RECENTLY_SYNCED);
        self.started_at.retain(|_, at| now.saturating_duration_since(*at) < CATCH_UP_QUIET);
        for (_, devices) in self.short.values_mut() {
            devices.retain(|_, at| now.saturating_duration_since(*at) < SHORT_TTL);
        }
        self.short.retain(|_, (_, devices)| !devices.is_empty());
        let mut moved = Vec::new();
        let mut ended = Vec::new();
        for (key, ask) in self.asks.iter_mut() {
            if moved.len() >= MAX_MOVES_PER_SWEEP {
                break;
            }
            if !ask.stalled && !silent(ask, now) && reachable(&ask.holder) {
                continue;
            }
            let mut holders = holders_of(&key.0, &key.1);
            if ask.kind == Kind::Hole
                && let Some((_, short)) = self.short.get(key)
            {
                holders.retain(|h| !short.contains_key(&h.device));
            }
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
                    moved.push((key.0.clone(), key.1.clone(), next.device.clone(), ask.kind));
                }
                None => ended.push(key.clone()),
            }
        }
        for key in ended {
            self.asks.remove(&key);
        }
        for (sid, cid, device, kind) in &moved {
            self.open_chain(sid, cid, device, *kind, now);
        }
        moved
    }
}

/// A holder that vouched from at or above a hole's top `top`: skipped for that hole for
/// [`SHORT_TTL`]. A hole that narrowed starts the list again.
fn note_short(short: &mut HashMap<Key, (i64, HashMap<String, Instant>)>, key: &Key, device: &str, top: i64, now: Instant) {
    if short.len() >= MAX_ASKS && !short.contains_key(key) {
        return;
    }
    let (at_top, devices) = short.entry(key.clone()).or_insert_with(|| (top, HashMap::new()));
    if *at_top != top {
        *at_top = top;
        devices.clear();
    }
    if devices.len() < MAX_SHORT_HOLDERS || devices.contains_key(device) {
        devices.insert(device.to_string(), now);
    }
}

/// Whether `device` lately vouched from at or above the hole's top `top`.
fn is_short(short: &HashMap<Key, (i64, HashMap<String, Instant>)>, key: &Key, device: &str, top: i64, now: Instant) -> bool {
    short.get(key).is_some_and(|(at_top, devices)| {
        *at_top == top && devices.get(device).is_some_and(|at| now.saturating_duration_since(*at) < SHORT_TTL)
    })
}

/// The page-level calls without `held_from`, for tests of the one-holder ask.
#[cfg(test)]
impl ChannelAsks {
    pub(crate) fn heard(&mut self, server_id: &str, channel_id: &str, from: &str, page: Page, now: Instant) -> Heard {
        self.hear(server_id, channel_id, from, page, None, None, now)
    }

    pub(crate) fn sweep(
        &mut self,
        now: Instant,
        reachable: &dyn Fn(&str) -> bool,
        holders_of: &dyn Fn(&str, &str) -> Vec<Holder>,
    ) -> Vec<(String, String, String)> {
        self.sweep_asks(now, reachable, holders_of).into_iter().map(|(s, c, d, _)| (s, c, d)).collect()
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
            assert_eq!(asks.heard("s", "general", &mal, Page::Next(100), t0), Heard { follow: true, continued: false, ..Heard::default() });
            let mut moved = None;
            for step in 1..=10u64 {
                let now = t0 + Duration::from_secs(step);
                let heard = asks.heard("s", "general", &mal, Page::Next(replay), now);
                assert_eq!(heard, Heard { follow: false, continued: true, ..Heard::default() }, "a replay of {replay} is followed");
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
        assert_eq!(asks.heard("s", "general", &mal, Page::Stuck, t0), Heard { follow: false, continued: true, ..Heard::default() });
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
        assert_eq!(asks.heard("s", "c", "a", Page::Next(5), t0), Heard { follow: true, continued: false, ..Heard::default() });
        assert_eq!(asks.heard("s", "c", "a", Page::Next(6), t0), Heard { follow: true, continued: true, ..Heard::default() });
        assert_eq!(asks.heard("s", "c", "a", Page::Last, t0), Heard { follow: false, continued: true, ..Heard::default() });
        assert_eq!(asks.heard("s", "c", "a", Page::Next(6), t0), Heard { follow: false, continued: true, ..Heard::default() }, "no further than before");
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

    // w3-ar39

    #[test]
    fn ar39_a_page_vouching_for_part_hands_the_hole_to_the_next_holder() {
        let mut asks = ChannelAsks::with_seed(3);
        let of = |_: &str, _: &str| people(&["a", "b", "c"]);
        let t0 = Instant::now();
        let first = asks.start("s", "c", &of("", ""), t0).unwrap();
        assert_eq!(asks.page_held("s", "c", &first, Some(50), t0), Some((Some(50), Kind::Catch)));
        assert!(asks.hear("s", "c", &first, Page::Next(60), Some(50), Some(50), t0).follow);
        assert_eq!(asks.page_held("s", "c", &first, None, t0), Some((Some(50), Kind::Catch)), "a later page of a partial chain vouches for all");
        let heard = asks.hear("s", "c", &first, Page::Last, Some(50), Some(50), t0);
        assert_eq!((heard.filled, heard.again), (false, None));
        let t1 = t0 + Duration::from_secs(1);
        let moved = asks.sweep_asks(t1, &|_| true, &of);
        let [(_, _, second, Kind::Hole)] = moved.as_slice() else { panic!("the hole goes to another holder: {moved:?}") };
        assert_ne!(*second, first);
        assert_eq!(asks.page_held("s", "c", second, Some(40), t1), Some((Some(40), Kind::Hole)));
        assert!(!asks.hear("s", "c", second, Page::Last, Some(40), Some(40), t1).filled, "a partial answer to the hole filled it");
        let t2 = t1 + Duration::from_secs(1);
        let moved = asks.sweep_asks(t2, &|_| true, &of);
        let [(_, _, third, Kind::Hole)] = moved.as_slice() else { panic!("the hole goes on: {moved:?}") };
        assert!(*third != first && third != second);
        let heard = asks.hear("s", "c", third, Page::Last, None, Some(40), t2);
        assert_eq!((heard.filled, heard.again), (true, None), "the catch-up came first, so the ask ends");
        assert_eq!(asks.start("s", "c", &of("", ""), t2), None, "the channel just synced");
    }

    /// A catch-up page vouching from below the hole's top holds only part of the hole, so
    /// the hole goes to the next holder rather than to it again.
    #[test]
    fn ar39_a_catch_up_vouching_for_part_of_the_hole_hands_it_on() {
        let mut asks = ChannelAsks::with_seed(5);
        let of = |_: &str, _: &str| people(&["a", "b", "c"]);
        let t0 = Instant::now();
        let first = asks.start("s", "c", &of("", ""), t0).unwrap();
        let heard = asks.hear("s", "c", &first, Page::Last, Some(5), Some(9), t0);
        assert_eq!(heard.again, None, "a holder vouching for part of the hole was asked for it again");
        let moved = asks.sweep_asks(t0 + Duration::from_secs(1), &|_| true, &of);
        let [(_, _, second, Kind::Hole)] = moved.as_slice() else { panic!("the hole goes to another holder: {moved:?}") };
        assert_ne!(*second, first);
    }

    /// The catch-up of new posts never waits for the hole: it is asked for first, and
    /// the holder that served it whole is asked for the hole next.
    #[test]
    fn ar39_catch_up_of_new_posts_is_not_delayed_by_an_open_hole() {
        let mut asks = ChannelAsks::with_seed(4);
        let holders = people(&["a", "b"]);
        let t0 = Instant::now();
        let first = asks.start("s", "c", &holders, t0).unwrap();
        assert_eq!(asks.page_held("s", "c", &first, None, t0), Some((None, Kind::Catch)), "an open hole asked before the new posts");
        let heard = asks.hear("s", "c", &first, Page::Last, None, Some(70), t0);
        assert_eq!((heard.filled, heard.again), (false, Some(Kind::Hole)), "the holder that served the catch-up whole is asked for the hole");
        assert_eq!(asks.page_held("s", "c", &first, None, t0), Some((None, Kind::Hole)));
        let heard = asks.hear("s", "c", &first, Page::Last, None, Some(70), t0);
        assert_eq!((heard.filled, heard.again), (true, None));
        assert_eq!(asks.start("s", "c", &holders, t0), None);
        assert!(asks.start_with("s", "d", "b", "b", t0));
        assert_eq!(asks.page_held("s", "d", "b", None, t0), Some((None, Kind::Catch)), "a Welcome's ask catches up first too");
    }

    /// Nobody left for the hole ends the ask: the catch-up already came in.
    #[test]
    fn ar39_nobody_left_for_the_hole_ends_the_ask() {
        let mut asks = ChannelAsks::with_seed(5);
        let of = |_: &str, _: &str| people(&["a", "b"]);
        let t0 = Instant::now();
        let first = asks.start("s", "c", &of("", ""), t0).unwrap();
        asks.hear("s", "c", &first, Page::Last, Some(9), Some(9), t0);
        let t1 = t0 + Duration::from_secs(1);
        let moved = asks.sweep_asks(t1, &|_| true, &of);
        let [(_, _, second, Kind::Hole)] = moved.as_slice() else { panic!("the other holder: {moved:?}") };
        asks.hear("s", "c", second, Page::Last, Some(9), Some(9), t1);
        assert!(asks.sweep_asks(t1 + Duration::from_secs(1), &|_| true, &of).is_empty(), "the ask ended");
    }

    /// A holder that vouched short of the hole's top is skipped for it on later rounds,
    /// until the hole narrows or the memory runs out.
    #[test]
    fn ar39_holders_short_of_the_hole_are_skipped_on_later_rounds() {
        let mut asks = ChannelAsks::with_seed(7);
        let of = |_: &str, _: &str| people(&["a", "b", "c"]);
        let t0 = Instant::now();
        let first = asks.start("s", "c", &of("", ""), t0).unwrap();
        asks.hear("s", "c", &first, Page::Last, Some(9), Some(9), t0);
        let t1 = t0 + Duration::from_secs(1);
        let moved = asks.sweep_asks(t1, &|_| true, &of);
        let [(_, _, second, Kind::Hole)] = moved.as_slice() else { panic!("{moved:?}") };
        let second = second.clone();
        asks.hear("s", "c", &second, Page::Last, Some(9), Some(9), t1);
        let t2 = t1 + Duration::from_secs(1);
        let moved = asks.sweep_asks(t2, &|_| true, &of);
        let [(_, _, third, Kind::Hole)] = moved.as_slice() else { panic!("{moved:?}") };
        let third = third.clone();
        asks.hear("s", "c", &third, Page::Last, Some(9), Some(9), t2);
        assert!(asks.sweep_asks(t2 + Duration::from_secs(1), &|_| true, &of).is_empty());
        // A later round: the catch-up goes to anyone, the hole to nobody already short.
        let t3 = t2 + RECENTLY_SYNCED + CATCH_UP_QUIET;
        let catch = asks.start_catch_up("s", "c", &of("", ""), t3).unwrap();
        let heard = asks.hear("s", "c", &catch, Page::Last, None, Some(9), t3);
        assert_eq!(heard.again, None, "a holder short of the hole was asked for it again");
        assert!(asks.sweep_asks(t3 + Duration::from_secs(1), &|_| true, &of).is_empty(), "a short holder was asked for the hole");
        // A narrowed hole asks them again.
        let t4 = t3 + RECENTLY_SYNCED + CATCH_UP_QUIET;
        let catch = asks.start_catch_up("s", "c", &of("", ""), t4).unwrap();
        asks.hear("s", "c", &catch, Page::Last, Some(5), Some(5), t4);
        let moved = asks.sweep_asks(t4 + Duration::from_secs(1), &|_| true, &of);
        assert_eq!(moved.len(), 1, "a narrowed hole skipped the holders short of the old one: {moved:?}");
        // And the memory runs out.
        let t5 = t4 + SHORT_TTL + Duration::from_secs(2);
        let catch = asks.start_catch_up("s", "c", &of("", ""), t5).unwrap();
        assert_eq!(asks.hear("s", "c", &catch, Page::Last, None, Some(5), t5).again, Some(Kind::Hole), "a short holder stayed skipped forever");
    }

    #[test]
    fn ar39_a_partial_holder_hands_the_catch_up_on() {
        let mut asks = ChannelAsks::with_seed(6);
        let of = |_: &str, _: &str| people(&["a", "b"]);
        let t0 = Instant::now();
        let first = asks.start("s", "c", &of("", ""), t0).unwrap();
        // It served nothing we lacked a hole for, and may hold nothing we asked for at all.
        let heard = asks.hear("s", "c", &first, Page::Last, Some(9), None, t0);
        assert_eq!((heard.filled, heard.again), (false, None));
        let t1 = t0 + Duration::from_secs(1);
        let moved = asks.sweep_asks(t1, &|_| true, &of);
        let [(_, _, second, Kind::Catch)] = moved.as_slice() else { panic!("the catch-up goes on: {moved:?}") };
        assert_ne!(*second, first);
        assert!(!asks.hear("s", "c", second, Page::Last, None, None, t1).follow);
        assert!(asks.sweep_asks(t1 + Duration::from_secs(1), &|_| true, &of).is_empty(), "a whole answer ends the ask");
    }

    /// Only a page of a chain we opened is noted at all.
    #[test]
    fn ar39_an_unasked_page_names_no_chain() {
        let mut asks = ChannelAsks::with_seed(8);
        assert_eq!(asks.page_held("s", "c", "mallory", Some(5), Instant::now()), None);
    }
}
