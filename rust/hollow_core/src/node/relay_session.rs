//! The client half of resumable relay sessions (RESUMABLE_SESSIONS_PLAN.md section 9) as
//! plain state with no socket and no clock of its own: what counts, when to ack, what
//! to keep and resend, when a socket is dead, how long to wait before the next try.
//! `ws_client` drives it; every rule here is tested by handing it instants.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use serde::Deserialize;
use tokio_tungstenite::tungstenite::{Bytes, Message, Utf8Bytes};

/// A sid is 128 random bits as lowercase hex.
pub(crate) const SID_HEX_LEN: usize = 32;
/// Stream frames that may arrive before an ack goes out.
pub(crate) const ACK_EVERY: u64 = 16;
pub(crate) const MAX_INFLIGHT_FRAMES: usize = 4096;
pub(crate) const MAX_INFLIGHT_BYTES: usize = 8 * 1024 * 1024;
pub(crate) const MAX_UNWRITTEN_ENTRIES: usize = 20_000;
pub(crate) const MAX_UNWRITTEN_BYTES: usize = 32 * 1024 * 1024;
/// The longest drain wait honoured: a relay names 2 to 10 s.
pub(crate) const MAX_DRAIN_WAIT: Duration = Duration::from_secs(30);

/// Every interval the client keeps (section 9.9); tests shrink them.
#[derive(Clone, Debug)]
pub(crate) struct Timing {
    pub heartbeat: Duration,
    pub heartbeat_background: Duration,
    pub dead_after: Duration,
    pub nudge_quiet: Duration,
    pub probe: Duration,
    pub ack_after: Duration,
    pub suspend_wait: Duration,
    pub sleep_jump: Duration,
    pub backoff_base: Duration,
    pub backoff_cap: Duration,
    /// The backoff cap while a held session can still be resumed (`grace`).
    pub resume_backoff_cap: Duration,
    /// The relay's grace, counted here from our own `Suspended`.
    pub grace: Duration,
    pub realtime_retry: Duration,
    /// Each auth reply.
    pub auth_reply: Duration,
    /// TCP, TLS and the WebSocket upgrade together.
    pub handshake: Duration,
    /// How long after a fresh session's replay wrote a room's join the node's identical
    /// join of that room is taken for an echo of it.
    pub replay_echo: Duration,
}

impl Default for Timing {
    fn default() -> Self {
        Self {
            heartbeat: Duration::from_secs(15),
            heartbeat_background: Duration::from_secs(60),
            dead_after: Duration::from_secs(10),
            nudge_quiet: Duration::from_secs(2),
            probe: Duration::from_secs(1),
            ack_after: Duration::from_secs(2),
            suspend_wait: Duration::from_secs(2),
            sleep_jump: Duration::from_secs(5),
            backoff_base: Duration::from_millis(500),
            backoff_cap: Duration::from_secs(30),
            resume_backoff_cap: Duration::from_secs(5),
            grace: Duration::from_secs(120),
            realtime_retry: Duration::from_secs(1),
            auth_reply: Duration::from_secs(5),
            handshake: Duration::from_secs(10),
            replay_echo: Duration::from_secs(5),
        }
    }
}

impl Timing {
    pub(crate) fn heartbeat_every(&self, background: bool) -> Duration {
        if background { self.heartbeat_background } else { self.heartbeat }
    }

    /// The heartbeat for the app's state: a call keeps the fast one in the background too,
    /// because its signalling needs a dead path found in seconds.
    pub(crate) fn heartbeat_for(&self, background: bool, realtime: bool) -> Duration {
        self.heartbeat_every(background && !realtime)
    }
}

/// One data message as it goes on the wire, kept byte for byte.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Frame {
    Text(Utf8Bytes),
    Binary(Bytes),
}

impl Frame {
    pub(crate) fn text(s: impl Into<Utf8Bytes>) -> Self {
        Self::Text(s.into())
    }

    pub(crate) fn len(&self) -> usize {
        match self {
            Self::Text(t) => t.len(),
            Self::Binary(b) => b.len(),
        }
    }

    pub(crate) fn to_message(&self) -> Message {
        match self {
            Self::Text(t) => Message::Text(t.clone()),
            Self::Binary(b) => Message::Binary(b.clone()),
        }
    }
}

// -- Counting (section 9.3) --

/// The `type` of a JSON object frame, and a gap's `n`. Anything else (not JSON, not an
/// object, a type that is not a string) has no type and counts as one.
#[derive(Deserialize)]
struct Typed {
    #[serde(rename = "type")]
    kind: Option<String>,
    #[serde(default)]
    n: Option<u64>,
}

fn typed(text: &str) -> Option<(String, Option<u64>)> {
    // serde reads a JSON array into a struct field by field; only an object has a type.
    if !text.trim_start().starts_with('{') {
        return None;
    }
    let t = serde_json::from_str::<Typed>(text).ok()?;
    Some((t.kind?, t.n))
}

const RELAY_UNCOUNTED: [&str; 11] = [
    "auth_challenge", "auth_ok", "auth_failed", "resumed", "hb_ack", "ack",
    "reconnect", "members", "peer_joined", "peer_left", "kill_signal",
];

const CLIENT_UNCOUNTED: [&str; 7] = ["auth_hello", "auth", "hb", "ack", "inactive", "active", "end"];

pub(crate) fn relay_text_counts(text: &str) -> u64 {
    match typed(text) {
        None => 1,
        Some((kind, n)) if kind == "gap" => n.unwrap_or(1),
        Some((kind, _)) => u64::from(!RELAY_UNCOUNTED.contains(&kind.as_str())),
    }
}

pub(crate) fn client_text_counts(text: &str) -> u64 {
    match typed(text) {
        None => 1,
        Some((kind, _)) => u64::from(!CLIENT_UNCOUNTED.contains(&kind.as_str())),
    }
}

/// How many stream frames a relay-to-client frame stands for.
pub(crate) fn relay_frame_counts(frame: &Frame) -> u64 {
    match frame {
        Frame::Text(t) => relay_text_counts(t),
        Frame::Binary(_) => 1,
    }
}

/// How many stream frames a client-to-relay frame stands for.
pub(crate) fn client_frame_counts(frame: &Frame) -> u64 {
    match frame {
        Frame::Text(t) => client_text_counts(t),
        Frame::Binary(_) => 1,
    }
}

// -- Auth v3 (sections 9.1, 9.2) --

pub(crate) fn is_sid_shape(s: &str) -> bool {
    s.len() == SID_HEX_LEN && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// The relay's shape rule for the v3 `session` field: only a full socket has a session.
#[cfg(test)]
pub(crate) fn auth_session_ok(mode: &str, session: &str) -> bool {
    match mode {
        "full" => session == "new" || is_sid_shape(session),
        "fetch" | "guest" => session == "none",
        _ => false,
    }
}

/// The exact bytes a v3 auth signature covers; pinned with the relay's `auth_frame.h`
/// through `relay-uws/test/session_vectors.json`.
#[allow(clippy::too_many_arguments)]
pub(crate) fn auth_v3_message(
    domain: &str,
    nonce: &str,
    peer_id: &str,
    timestamp: u64,
    mode: &str,
    license_digest: &str,
    session: &str,
    in_h: u64,
) -> String {
    format!("hollow-ws-auth3\n{domain}\n{nonce}\n{peer_id}\n{timestamp}\n{mode}\n{license_digest}\n{session}\n{in_h}")
}

/// What one auth frame asks of the relay.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Ask {
    /// Today's v2 frame: no session.
    V2,
    New,
    Resume { sid: String, in_h: u64 },
}

impl Ask {
    /// v3 only to a relay that offered sessions, and only for a full socket.
    pub(crate) fn choose(advertised: bool, fetch: bool, held: Option<(&str, u64)>) -> Ask {
        if !advertised || fetch {
            return Ask::V2;
        }
        match held {
            Some((sid, in_h)) => Ask::Resume { sid: sid.to_string(), in_h },
            None => Ask::New,
        }
    }

    /// The v3 frame's `session` and `in_h`; none for a v2 frame.
    pub(crate) fn session_field(&self) -> Option<(String, u64)> {
        match self {
            Ask::V2 => None,
            Ask::New => Some(("new".to_string(), 0)),
            Ask::Resume { sid, in_h } => Some((sid.clone(), *in_h)),
        }
    }
}

/// The frames the handshake reads.
#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub(crate) enum AuthReply {
    AuthChallenge {
        nonce: String,
        #[serde(default)]
        door_key: String,
        #[serde(default)]
        session: Option<serde_json::Value>,
    },
    AuthOk {
        #[serde(default)]
        sid: Option<String>,
        #[serde(default)]
        resume_failed: Option<String>,
    },
    Resumed {
        h: u64,
        #[serde(default)]
        gap: bool,
        #[serde(default)]
        reprove: bool,
    },
    AuthFailed {
        #[serde(default)]
        error: String,
    },
}

impl AuthReply {
    /// A challenge advertising sessions carries exactly the number 1.
    pub(crate) fn offers_sessions(&self) -> bool {
        matches!(self, Self::AuthChallenge { session: Some(v), .. } if v.as_u64() == Some(1))
    }
}

/// What a socket came up as.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Established {
    /// A fresh session; `sid` none when the relay keeps no session for this socket.
    /// `lost`: the session we held is gone.
    Fresh { sid: Option<String>, lost: bool },
    Resumed { h: u64, gap: bool, reprove: bool },
}

/// The relay's answer to our auth frame, read against what we asked and whether we
/// held a session going in.
pub(crate) fn judge(ask: &Ask, held: bool, reply: AuthReply) -> Result<Established, String> {
    match (ask, reply) {
        (_, AuthReply::AuthFailed { error }) => Err(error),
        (Ask::Resume { .. }, AuthReply::Resumed { h, gap, reprove }) => Ok(Established::Resumed { h, gap, reprove }),
        (_, AuthReply::Resumed { .. }) => Err("the relay resumed a session nobody asked for".to_string()),
        (Ask::V2, AuthReply::AuthOk { .. }) => Ok(Established::Fresh { sid: None, lost: held }),
        (_, AuthReply::AuthOk { sid, resume_failed }) => Ok(Established::Fresh {
            sid: sid.filter(|s| is_sid_shape(s)),
            lost: held || resume_failed.is_some(),
        }),
        (_, AuthReply::AuthChallenge { .. }) => Err("a second challenge instead of an answer".to_string()),
    }
}

// -- What the node hears (section 9.8) --

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Note {
    Suspended,
    Resumed { gap: bool },
    SessionLost,
    Connected,
}

/// A socket went: the session waits for a resume, or there never was one.
pub(crate) fn on_drop(held: bool) -> Vec<Note> {
    vec![if held { Note::Suspended } else { Note::SessionLost }]
}

/// A socket came up. A resume is never a fresh session.
pub(crate) fn on_established(e: &Established) -> Vec<Note> {
    match e {
        Established::Resumed { gap, .. } => vec![Note::Resumed { gap: *gap }],
        Established::Fresh { lost: true, .. } => vec![Note::SessionLost, Note::Connected],
        Established::Fresh { lost: false, .. } => vec![Note::Connected],
    }
}

/// The relay resumed a session whose numbers are not ours: a fresh one follows on a new
/// socket, and its `Connected` with it.
pub(crate) fn on_resume_refused() -> Vec<Note> {
    vec![Note::SessionLost]
}

// -- Inbound count and acks (section 9.4) --

#[derive(Debug, Default)]
pub(crate) struct Inbound {
    h: u64,
    acked: u64,
    first_unacked: Option<Instant>,
}

impl Inbound {
    /// Stream frames received in this session.
    pub(crate) fn h(&self) -> u64 {
        self.h
    }

    /// Count `n` stream frames arriving at `now`; true when an ack is due at once.
    pub(crate) fn received(&mut self, n: u64, now: Instant) -> bool {
        if n == 0 {
            return false;
        }
        self.h = self.h.saturating_add(n);
        self.first_unacked.get_or_insert(now);
        self.h - self.acked >= ACK_EVERY
    }

    pub(crate) fn ack_due_at(&self, t: &Timing) -> Option<Instant> {
        self.first_unacked.map(|at| at + t.ack_after)
    }

    /// An ack, or a heartbeat (which carries the count), is going out: the `h` it says.
    pub(crate) fn acked(&mut self) -> u64 {
        self.acked = self.h;
        self.first_unacked = None;
        self.h
    }
}

// -- The outbound queue (section 9.4) --

/// How the prune ranks an unwritten entry.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Class {
    /// Joins, leaves, subscriptions: what a fresh session's replay rebuilds. Pruned last.
    RoomState,
    Ordinary,
    /// A frame its receiver refuses once the seal is older than the live window.
    LiveOnly { sealed_ms: i64 },
}

pub(crate) trait Queued {
    fn bytes(&self) -> usize;
    /// Asked only when the queue overflows, at most once per entry.
    fn class(&self) -> Class;
    fn frame_class(frame: &Frame) -> Class;
}

#[derive(Debug)]
pub(crate) enum Entry<C> {
    Command(C),
    /// A command the client queued itself for a fresh session's replay.
    Replay(C),
    /// A frame written in a session that was lost, sent again as it was.
    Frame(Frame),
}

struct Unwritten<C> {
    entry: Entry<C>,
    bytes: usize,
    class: Option<Class>,
}

impl<C: Queued> Unwritten<C> {
    fn new(entry: Entry<C>) -> Self {
        let bytes = match &entry {
            Entry::Command(c) | Entry::Replay(c) => c.bytes(),
            Entry::Frame(f) => f.len(),
        };
        Self { entry, bytes, class: None }
    }

    fn class(&mut self) -> Class {
        let entry = &self.entry;
        *self.class.get_or_insert_with(|| match entry {
            Entry::Command(c) | Entry::Replay(c) => c.class(),
            Entry::Frame(f) => C::frame_class(f),
        })
    }
}

struct Written {
    seq: u64,
    frame: Frame,
    room_state: bool,
}

/// Unwritten commands, then the frames written and not yet acked. A written frame is
/// never dropped while the session lives: only an ack removes it.
pub(crate) struct Outbound<C> {
    unwritten: VecDeque<Unwritten<C>>,
    unwritten_bytes: usize,
    inflight: VecDeque<Written>,
    inflight_bytes: usize,
    written: u64,
    acked: u64,
}

impl<C> Default for Outbound<C> {
    fn default() -> Self {
        Self {
            unwritten: VecDeque::new(),
            unwritten_bytes: 0,
            inflight: VecDeque::new(),
            inflight_bytes: 0,
            written: 0,
            acked: 0,
        }
    }
}

impl<C: Queued> Outbound<C> {
    /// Queue a command; how many unwritten entries the bounds pushed out.
    pub(crate) fn push(&mut self, cmd: C, now_ms: i64) -> usize {
        let u = Unwritten::new(Entry::Command(cmd));
        self.unwritten_bytes += u.bytes;
        self.unwritten.push_back(u);
        self.prune(now_ms)
    }

    /// Put `entries` ahead of everything unwritten, in their order.
    pub(crate) fn push_front(&mut self, entries: Vec<Entry<C>>, now_ms: i64) -> usize {
        for entry in entries.into_iter().rev() {
            let u = Unwritten::new(entry);
            self.unwritten_bytes += u.bytes;
            self.unwritten.push_front(u);
        }
        self.prune(now_ms)
    }

    fn prune(&mut self, now_ms: i64) -> usize {
        let mut pruned = 0;
        while self.unwritten.len() > MAX_UNWRITTEN_ENTRIES || self.unwritten_bytes > MAX_UNWRITTEN_BYTES {
            let Some(at) = self.prune_pick(now_ms) else { break };
            if let Some(u) = self.unwritten.remove(at) {
                self.unwritten_bytes -= u.bytes;
                pruned += 1;
            }
        }
        pruned
    }

    /// A live-only frame its receiver would refuse first, then the oldest entry, room
    /// state only when nothing else is left.
    fn prune_pick(&mut self, now_ms: i64) -> Option<usize> {
        let mut ordinary = None;
        let mut room_state = None;
        for (i, u) in self.unwritten.iter_mut().enumerate() {
            match u.class() {
                Class::LiveOnly { sealed_ms } if super::frame_auth::is_stale(sealed_ms, now_ms) => return Some(i),
                Class::RoomState => {
                    room_state.get_or_insert(i);
                }
                _ => {
                    ordinary.get_or_insert(i);
                }
            }
        }
        ordinary.or(room_state)
    }

    /// Flow control: at 4096 written-unacked frames or 8 MiB, wait for an ack. A frame
    /// bigger than the window still goes once nothing waits.
    pub(crate) fn can_write(&self) -> bool {
        self.inflight.is_empty()
            || (self.inflight.len() < MAX_INFLIGHT_FRAMES && self.inflight_bytes < MAX_INFLIGHT_BYTES)
    }

    pub(crate) fn has_unwritten(&self) -> bool {
        !self.unwritten.is_empty()
    }

    /// Whether to take more from the node while a socket drains the queue: below half of
    /// either bound, so a burst (a file stream) waits upstream instead of being pruned.
    pub(crate) fn has_room(&self) -> bool {
        self.unwritten.len() < MAX_UNWRITTEN_ENTRIES / 2 && self.unwritten_bytes < MAX_UNWRITTEN_BYTES / 2
    }

    pub(crate) fn pop(&mut self) -> Option<Entry<C>> {
        let u = self.unwritten.pop_front()?;
        self.unwritten_bytes -= u.bytes;
        Some(u.entry)
    }

    /// Put back an entry that never reached the wire, ahead of the rest.
    pub(crate) fn unpop(&mut self, entry: Entry<C>) {
        let u = Unwritten::new(entry);
        self.unwritten_bytes += u.bytes;
        self.unwritten.push_front(u);
    }

    /// `frame` goes on the wire now: its number in the session, kept until acked.
    pub(crate) fn record(&mut self, frame: Frame, room_state: bool) -> u64 {
        self.written += 1;
        self.inflight_bytes += frame.len();
        self.inflight.push_back(Written { seq: self.written, frame, room_state });
        self.written
    }

    /// The relay handled every frame up to `h`. An `h` above what we wrote or below its
    /// last ack changes nothing.
    pub(crate) fn ack(&mut self, h: u64) -> bool {
        if h < self.acked || h > self.written {
            return false;
        }
        while self.inflight.front().is_some_and(|w| w.seq <= h) {
            if let Some(w) = self.inflight.pop_front() {
                self.inflight_bytes -= w.frame.len();
            }
        }
        self.acked = h;
        true
    }

    /// The relay resumed us at `h`: what to write again, in order and byte for byte.
    /// None when `h` cannot be about our session.
    pub(crate) fn resume(&mut self, h: u64) -> Option<Vec<Frame>> {
        if !self.ack(h) {
            return None;
        }
        Some(self.inflight.iter().map(|w| w.frame.clone()).collect())
    }

    /// The session is gone: its unacked data goes ahead of the queue for the next
    /// session to send again, its room state to that session's replay.
    pub(crate) fn lose_session(&mut self) {
        let carried: Vec<Entry<C>> = self
            .inflight
            .drain(..)
            .filter(|w| !w.room_state)
            .map(|w| Entry::Frame(w.frame))
            .collect();
        self.inflight_bytes = 0;
        self.written = 0;
        self.acked = 0;
        for entry in carried.into_iter().rev() {
            self.unpop(entry);
        }
    }

    #[cfg(test)]
    pub(crate) fn written(&self) -> u64 {
        self.written
    }

    #[cfg(test)]
    pub(crate) fn acked(&self) -> u64 {
        self.acked
    }

    #[cfg(test)]
    pub(crate) fn inflight_len(&self) -> usize {
        self.inflight.len()
    }

    #[cfg(test)]
    pub(crate) fn unwritten_len(&self) -> usize {
        self.unwritten.len()
    }

    pub(crate) fn all_acked(&self) -> bool {
        self.inflight.is_empty()
    }
}

// -- Liveness (sections 9.5, 9.6) --

/// When this socket last proved it carries data, and what we are waiting on.
#[derive(Debug)]
pub(crate) struct Liveness {
    last_heard: Instant,
    beat_out: Option<Instant>,
    probe_until: Option<Instant>,
}

impl Liveness {
    pub(crate) fn new(now: Instant) -> Self {
        Self { last_heard: now, beat_out: None, probe_until: None }
    }

    /// Any inbound frame, a busy download's included, answers every heartbeat.
    pub(crate) fn heard(&mut self, now: Instant) {
        self.last_heard = now;
        self.beat_out = None;
        self.probe_until = None;
    }

    pub(crate) fn beat_sent(&mut self, now: Instant) {
        self.beat_out.get_or_insert(now);
    }

    /// Dead: nothing at all heard for `dead_after` since a heartbeat went out.
    pub(crate) fn dead_at(&self, t: &Timing) -> Option<Instant> {
        self.beat_out.map(|at| at + t.dead_after)
    }

    /// Whether a nudge should probe: nothing heard for `nudge_quiet` and no probe out.
    pub(crate) fn wants_probe(&self, now: Instant, t: &Timing) -> bool {
        self.probe_until.is_none() && now.saturating_duration_since(self.last_heard) >= t.nudge_quiet
    }

    pub(crate) fn probe_sent(&mut self, now: Instant, t: &Timing) {
        self.beat_sent(now);
        self.probe_until = Some(now + t.probe);
    }

    /// Past this, a new socket races the old one (make before break).
    pub(crate) fn probe_missed_at(&self) -> Option<Instant> {
        self.probe_until
    }

    pub(crate) fn probe_given_up(&mut self) {
        self.probe_until = None;
    }

    /// Stop judging this socket: it is left unread while a move is under way.
    pub(crate) fn pause(&mut self) {
        self.beat_out = None;
        self.probe_until = None;
    }
}

// -- Nudges (section 9.6) --

/// The reason an app nudge carries; anything unknown is `other`.
pub(crate) fn app_reason(reason: &str) -> &'static str {
    match reason {
        "foreground" => "foreground",
        "focus" => "focus",
        "network" => "network",
        "wake" => "wake",
        "call" => "call",
        "push" => "push",
        _ => "other",
    }
}

/// Whether a nudge reopens a socket the app closed on purpose: only the app coming back
/// does, a call that needs the socket and a push wake (the ring holds what woke it)
/// included. A network change or a wake is no reason to undo what the app decided, and
/// the client's own nudges never are.
pub(crate) fn ends_suspend(reason: &str, external: bool) -> bool {
    external && matches!(reason, "foreground" | "focus" | "call" | "push")
}

// -- The app's background flag (section 9.7 `inactive` / `active`) --

/// What the relay holds of the app's `inactive` flag (`true` = inactive). The flag frames
/// are uncounted and never resent, so a write is known to have arrived only once the
/// relay answered a heartbeat written after it on the same socket; until then the next
/// socket writes the app's flag again.
#[derive(Debug, Default)]
pub(crate) struct Flag {
    /// What the relay is known to hold; None while a write may or may not have arrived.
    held: Option<bool>,
    /// The last write on this socket not yet known to have arrived, with how many
    /// heartbeats this socket had written before it.
    written: Option<(bool, u64)>,
    beats: u64,
    answers: u64,
    /// The session may have moved off this socket, whose answers then prove nothing.
    doubted: bool,
}

impl Flag {
    /// The relay starts every session active.
    pub(crate) fn fresh_session(&mut self) {
        *self = Self { held: Some(false), ..Self::default() };
    }

    /// The session goes on over a new socket.
    pub(crate) fn new_socket(&mut self) {
        let held = if self.written.is_some() { None } else { self.held };
        *self = Self { held, ..Self::default() };
    }

    /// Whether the relay must be told `inactive` for it to hold it.
    pub(crate) fn needs(&self, inactive: bool) -> bool {
        match self.written {
            Some((written, _)) => written != inactive,
            None => self.held != Some(inactive),
        }
    }

    pub(crate) fn wrote(&mut self, inactive: bool) {
        self.written = Some((inactive, self.beats));
    }

    pub(crate) fn beat_sent(&mut self) {
        self.beats += 1;
    }

    /// The relay answered this socket's next heartbeat (it answers each, in order).
    pub(crate) fn answered(&mut self) {
        self.answers += 1;
        if let Some((written, beats_before)) = self.written
            && !self.doubted
            && self.answers > beats_before
        {
            self.held = Some(written);
            self.written = None;
        }
    }

    /// A second socket may take the session over from this one.
    pub(crate) fn doubt(&mut self) {
        self.doubted = true;
    }
}

/// A wall-clock reading next to a monotonic one.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Clocks {
    pub wall_ms: i64,
    pub mono: Instant,
}

impl Clocks {
    /// Whether the machine slept between `self` and `now`: the monotonic tick stops in
    /// suspend on Linux and macOS, so the two drift apart by the time asleep.
    pub(crate) fn slept(&self, now: &Clocks, t: &Timing) -> bool {
        let wall = i128::from(now.wall_ms) - i128::from(self.wall_ms);
        let mono = now.mono.saturating_duration_since(self.mono).as_millis() as i128;
        (wall - mono).abs() > t.sleep_jump.as_millis() as i128
    }
}

// -- Reconnect waits --

#[derive(Debug, Default)]
pub(crate) struct Backoff {
    attempt: u32,
}

impl Backoff {
    pub(crate) fn reset(&mut self) {
        self.attempt = 0;
    }

    #[cfg(test)]
    pub(crate) fn attempt(&self) -> u32 {
        self.attempt
    }

    /// [`Self::next_within`] the normal cap.
    #[cfg(test)]
    pub(crate) fn next(&mut self, roll: u64, t: &Timing) -> Duration {
        self.next_within(roll, t, t.backoff_cap)
    }

    /// Full jitter: uniform in `[0, min(cap, base * 2^attempt)]` for a `roll` uniform
    /// over u64, so a reconnect wave spreads out.
    pub(crate) fn next_within(&mut self, roll: u64, t: &Timing, cap: Duration) -> Duration {
        let factor = 1u32.checked_shl(self.attempt).unwrap_or(u32::MAX);
        let ceiling = t.backoff_base.checked_mul(factor).unwrap_or(cap).min(cap);
        self.attempt = self.attempt.saturating_add(1);
        let span = u64::try_from(ceiling.as_nanos()).unwrap_or(u64::MAX);
        Duration::from_nanos(roll % span.saturating_add(1).max(1))
    }
}

/// The backoff cap for the next try. While the relay can still resume the session we hold
/// (inside its grace, counted from our own `Suspended`), a path that comes back by itself
/// must not wait out a long backoff; once the relay refused us, every socket spends its
/// per-address budget, so the full cap applies again.
pub(crate) fn backoff_cap(t: &Timing, holding: bool, since_suspended: Option<Duration>, refused: bool) -> Duration {
    let resumable = holding && !refused && since_suspended.is_some_and(|d| d < t.grace);
    if resumable { t.resume_backoff_cap.min(t.backoff_cap) } else { t.backoff_cap }
}

/// How long the drain hint says to wait before resuming elsewhere.
pub(crate) fn drain_wait(after_ms: u64) -> Duration {
    Duration::from_millis(after_ms).min(MAX_DRAIN_WAIT)
}

// -- Protocol frames (uncounted) --

pub(crate) fn hb_frame(h: u64) -> Frame {
    Frame::text(format!(r#"{{"type":"hb","h":{h}}}"#))
}

pub(crate) fn ack_frame(h: u64) -> Frame {
    Frame::text(format!(r#"{{"type":"ack","h":{h}}}"#))
}

pub(crate) const INACTIVE: &str = r#"{"type":"inactive"}"#;
pub(crate) const ACTIVE: &str = r#"{"type":"active"}"#;
pub(crate) const END: &str = r#"{"type":"end"}"#;

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::rc::Rc;

    const SID: &str = "00112233445566778899aabbccddeeff";
    const SID2: &str = "ffeeddccbbaa99887766554433221100";

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    fn secs(n: u64) -> Duration {
        Duration::from_secs(n)
    }

    fn text(s: &str) -> Frame {
        Frame::text(s.to_string())
    }

    fn vectors() -> serde_json::Value {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../relay-uws/test/session_vectors.json");
        serde_json::from_str(&std::fs::read_to_string(path).expect("session_vectors.json")).expect("the vectors parse")
    }

    /// Section 9.1: the bytes a v3 auth signature covers, pinned with the relay.
    #[test]
    fn auth_v3_message_matches_the_pinned_vectors() {
        let v = vectors();
        let cases = v["auth_v3"].as_array().expect("auth_v3");
        assert!(cases.len() >= 3);
        for c in cases {
            let s = |k: &str| c[k].as_str().unwrap_or_default().to_string();
            let digest = super::super::ws_client::license_digest(c["license_key"].as_str());
            let got = auth_v3_message(
                &s("domain"),
                &s("nonce"),
                &s("peer_id"),
                c["timestamp"].as_u64().unwrap(),
                &s("mode"),
                &digest,
                &s("session"),
                c["in_h"].as_u64().unwrap(),
            );
            assert_eq!(got, s("message"), "{c}");
        }
    }

    #[test]
    fn auth_v3_session_shapes_match_the_vectors() {
        let v = vectors();
        let cases = v["auth_v3_shape"].as_array().expect("auth_v3_shape");
        assert!(cases.len() >= 10);
        for c in cases {
            let ok = auth_session_ok(c["mode"].as_str().unwrap(), c["session"].as_str().unwrap());
            assert_eq!(ok, c["ok"].as_bool().unwrap(), "{c}");
        }
        assert!(is_sid_shape(SID));
        assert!(!is_sid_shape(&SID.to_uppercase()));
        assert!(!is_sid_shape(&SID[1..]));
    }

    /// Section 9.3 in both directions, against the cases the relay reads too.
    #[test]
    fn counted_frames_match_the_vectors() {
        let v = vectors();
        let cases = v["counted"].as_array().expect("counted");
        assert!(cases.len() >= 40);
        for c in cases {
            let frame = match c.get("binary_hex") {
                Some(h) => Frame::Binary(Bytes::from(hex::decode(h.as_str().unwrap()).unwrap())),
                None => text(c["text"].as_str().unwrap()),
            };
            let got = if c["dir"] == "relay_to_client" { relay_frame_counts(&frame) } else { client_frame_counts(&frame) };
            assert_eq!(got, c["counts"].as_u64().unwrap(), "{c}");
        }
        assert_eq!(relay_text_counts(r#"["gap",3]"#), 1, "an array is no typed frame");
        assert_eq!(relay_text_counts(r#"{"type":"gap"}"#), 1);
        assert_eq!(relay_text_counts(r#"{"type":null}"#), 1);
        assert_eq!(relay_text_counts(r#" {"type":"members","room":"r","peers":[]}"#), 0);
        assert_eq!(client_text_counts(r#"  {"type":"hb","h":1}"#), 0);
    }

    /// Section 9.1: a relay that did not offer sessions gets today's v2 frame, and a
    /// fetch socket never asks for one.
    #[test]
    fn v3_is_asked_only_of_a_relay_that_offers_sessions() {
        assert_eq!(Ask::choose(false, false, None), Ask::V2);
        assert_eq!(Ask::choose(false, false, Some((SID, 4))), Ask::V2, "an old relay never sees a sid");
        assert_eq!(Ask::choose(true, true, None), Ask::V2, "fetch sockets never get sessions");
        assert_eq!(Ask::choose(true, false, None), Ask::New);
        assert_eq!(Ask::choose(true, false, Some((SID, 9))), Ask::Resume { sid: SID.into(), in_h: 9 });
        assert_eq!(Ask::V2.session_field(), None);
        assert_eq!(Ask::New.session_field(), Some(("new".into(), 0)));
        assert_eq!(Ask::Resume { sid: SID.into(), in_h: 9 }.session_field(), Some((SID.into(), 9)));

        let offers = |t: &str| serde_json::from_str::<AuthReply>(t).unwrap().offers_sessions();
        let nonce = "ab".repeat(32);
        assert!(offers(&format!(r#"{{"type":"auth_challenge","nonce":"{nonce}","door_key":"k","session":1}}"#)));
        assert!(!offers(&format!(r#"{{"type":"auth_challenge","nonce":"{nonce}","door_key":"k"}}"#)));
        assert!(!offers(&format!(r#"{{"type":"auth_challenge","nonce":"{nonce}","session":0}}"#)));
        assert!(!offers(&format!(r#"{{"type":"auth_challenge","nonce":"{nonce}","session":"1"}}"#)));
        assert!(!offers(r#"{"type":"auth_ok","sid":"00112233445566778899aabbccddeeff"}"#));
    }

    #[test]
    fn the_relays_answers_are_judged_by_what_was_asked() {
        let reply = |t: &str| serde_json::from_str::<AuthReply>(t).unwrap();
        let fresh = |sid: Option<&str>, lost| Ok(Established::Fresh { sid: sid.map(str::to_string), lost });
        let resume = Ask::Resume { sid: SID.into(), in_h: 3 };
        let ok = format!(r#"{{"type":"auth_ok","sid":"{SID}","grace_secs":120,"hb_secs":15}}"#);
        assert_eq!(judge(&Ask::New, false, reply(&ok)), fresh(Some(SID), false));
        let upper = format!(r#"{{"type":"auth_ok","sid":"{}"}}"#, SID.to_uppercase());
        assert_eq!(judge(&Ask::New, false, reply(&upper)), fresh(None, false), "a sid of the wrong shape is no session");
        assert_eq!(judge(&Ask::V2, false, reply(r#"{"type":"auth_ok"}"#)), fresh(None, false));
        assert_eq!(judge(&Ask::V2, false, reply(&ok)), fresh(None, false), "a sid we did not ask for is not ours");
        assert_eq!(
            judge(&Ask::V2, true, reply(r#"{"type":"auth_ok"}"#)),
            fresh(None, true),
            "a relay that stopped offering sessions forgot ours"
        );
        assert_eq!(
            judge(&resume, true, reply(r#"{"type":"resumed","h":7,"gap":true,"reprove":false,"grace_secs":120,"hb_secs":15}"#)),
            Ok(Established::Resumed { h: 7, gap: true, reprove: false })
        );
        let failed = format!(r#"{{"type":"auth_ok","sid":"{SID2}","grace_secs":120,"hb_secs":15,"resume_failed":"unknown"}}"#);
        assert_eq!(judge(&resume, true, reply(&failed)), fresh(Some(SID2), true));
        assert!(judge(&Ask::New, false, reply(r#"{"type":"resumed","h":0}"#)).is_err(), "a resume nobody asked for");
        assert_eq!(
            judge(&Ask::New, false, reply(r#"{"type":"auth_failed","error":"license_key_in_use"}"#)),
            Err("license_key_in_use".to_string())
        );
    }

    /// Section 9.8: a resume never reads as a fresh session, and a held session is only
    /// reported lost once the relay says so.
    #[test]
    fn events_follow_the_order_of_section_9_8() {
        assert_eq!(on_drop(true), vec![Note::Suspended]);
        assert_eq!(on_drop(false), vec![Note::SessionLost]);
        assert_eq!(
            on_established(&Established::Resumed { h: 1, gap: true, reprove: false }),
            vec![Note::Resumed { gap: true }]
        );
        assert_eq!(
            on_established(&Established::Resumed { h: 1, gap: false, reprove: true }),
            vec![Note::Resumed { gap: false }]
        );
        assert_eq!(
            on_established(&Established::Fresh { sid: Some(SID.into()), lost: true }),
            vec![Note::SessionLost, Note::Connected]
        );
        assert_eq!(on_established(&Established::Fresh { sid: None, lost: true }), vec![Note::SessionLost, Note::Connected]);
        assert_eq!(on_established(&Established::Fresh { sid: Some(SID.into()), lost: false }), vec![Note::Connected]);
        assert_eq!(on_resume_refused(), vec![Note::SessionLost]);
    }

    #[test]
    fn acks_go_every_16_frames_or_2_s_after_the_first_unacked() {
        let t = Timing::default();
        let t0 = Instant::now();
        let mut i = Inbound::default();
        for k in 1..16 {
            assert!(!i.received(1, t0 + ms(k)), "frame {k}");
        }
        assert_eq!(i.ack_due_at(&t), Some(t0 + ms(1) + secs(2)));
        assert!(i.received(1, t0 + ms(20)), "the 16th asks for an ack at once");
        assert_eq!(i.acked(), 16);
        assert_eq!(i.ack_due_at(&t), None);
        assert!(!i.received(0, t0 + secs(4)), "uncounted frames ask for nothing");
        assert_eq!(i.ack_due_at(&t), None);
        assert!(!i.received(3, t0 + secs(5)));
        assert_eq!(i.h(), 19, "a gap counts as all it stands for");
        assert_eq!(i.ack_due_at(&t), Some(t0 + secs(7)));
        assert!(i.received(13, t0 + secs(6)));
        assert_eq!(i.acked(), 32);
    }

    struct Item {
        bytes: usize,
        class: Class,
        tag: u32,
        asked: Rc<Cell<u32>>,
    }

    impl Queued for Item {
        fn bytes(&self) -> usize {
            self.bytes
        }
        fn class(&self) -> Class {
            self.asked.set(self.asked.get() + 1);
            self.class
        }
        fn frame_class(_: &Frame) -> Class {
            Class::Ordinary
        }
    }

    fn item(tag: u32, class: Class, asked: &Rc<Cell<u32>>) -> Item {
        Item { bytes: 10, class, tag, asked: asked.clone() }
    }

    fn tags(out: &mut Outbound<Item>) -> Vec<u32> {
        let mut seen = Vec::new();
        while let Some(e) = out.pop() {
            match e {
                Entry::Command(c) | Entry::Replay(c) => seen.push(c.tag),
                Entry::Frame(_) => seen.push(u32::MAX),
            }
        }
        seen
    }

    #[test]
    fn written_frames_are_numbered_kept_and_dropped_only_by_ack() {
        let asked = Rc::new(Cell::new(0));
        let mut out: Outbound<Item> = Outbound::default();
        for k in 1..=5u64 {
            assert_eq!(out.record(text(&format!("f{k}")), false), k);
        }
        assert_eq!(out.written(), 5);
        assert!(!out.ack(6), "an ack above what we wrote is ignored");
        assert_eq!(out.inflight_len(), 5);
        assert!(out.ack(2));
        assert_eq!((out.inflight_len(), out.acked()), (3, 2));
        assert!(!out.ack(1), "an ack below the last one is ignored");
        assert_eq!((out.inflight_len(), out.acked()), (3, 2));
        assert!(out.ack(2), "a repeat changes nothing");
        assert_eq!(out.inflight_len(), 3);
        for k in 0..(MAX_UNWRITTEN_ENTRIES as u32 + 10) {
            out.push(item(k, Class::Ordinary, &asked), 0);
        }
        assert_eq!(out.inflight_len(), 3, "the unwritten bound never reaches a written frame");
        assert_eq!(out.unwritten_len(), MAX_UNWRITTEN_ENTRIES);
        assert!(!out.all_acked());
        assert!(out.ack(5));
        assert!(out.all_acked());
    }

    #[test]
    fn writing_stops_at_4096_unacked_frames_or_8_mib() {
        let mut out: Outbound<Item> = Outbound::default();
        assert!(out.can_write());
        for _ in 0..MAX_INFLIGHT_FRAMES - 1 {
            out.record(text("x"), false);
        }
        assert!(out.can_write());
        out.record(text("x"), false);
        assert!(!out.can_write(), "4096 written and unacked");
        out.ack(1);
        assert!(out.can_write());

        let mut big: Outbound<Item> = Outbound::default();
        big.record(Frame::Binary(Bytes::from(vec![0u8; MAX_INFLIGHT_BYTES - 1])), false);
        assert!(big.can_write());
        big.record(Frame::Binary(Bytes::from(vec![0u8; 1])), false);
        assert!(!big.can_write(), "8 MiB written and unacked");

        let mut huge: Outbound<Item> = Outbound::default();
        assert!(huge.can_write(), "a frame larger than the window still goes when nothing waits");
        huge.record(Frame::Binary(Bytes::from(vec![0u8; MAX_INFLIGHT_BYTES + 1])), false);
        assert!(!huge.can_write());
    }

    #[test]
    fn resume_drops_what_h_covers_and_resends_the_rest_in_order() {
        let frames: Vec<Frame> = (1..=6u8)
            .map(|k| if k % 2 == 0 { Frame::Binary(Bytes::from(vec![k; 3])) } else { text(&format!("t{k}")) })
            .collect();
        let mut out: Outbound<Item> = Outbound::default();
        for f in &frames {
            out.record(f.clone(), false);
        }
        out.ack(1);
        assert_eq!(out.resume(3), Some(frames[3..].to_vec()), "byte for byte, in order, after h");
        assert_eq!((out.acked(), out.inflight_len()), (3, 3));
        assert_eq!(out.resume(3), Some(frames[3..].to_vec()), "a second resume from the same h resends the same");
        assert_eq!(out.resume(7), None, "an h above what we wrote is not our session");
        assert_eq!(out.resume(6), Some(vec![]));
        assert!(out.all_acked());

        let mut back: Outbound<Item> = Outbound::default();
        for f in &frames {
            back.record(f.clone(), false);
        }
        back.ack(4);
        assert_eq!(back.resume(2), None, "an h below the relay's own ack is not our session");
        assert_eq!(back.inflight_len(), 2);
    }

    #[test]
    fn a_lost_session_hands_its_unacked_frames_back_ahead_of_the_queue() {
        let asked = Rc::new(Cell::new(0));
        let mut out: Outbound<Item> = Outbound::default();
        out.push(item(1, Class::Ordinary, &asked), 0);
        out.record(text("acked"), false);
        out.record(text("join"), true);
        out.record(text("a"), false);
        out.record(Frame::Binary(Bytes::from_static(b"b")), false);
        out.ack(1);
        out.lose_session();
        assert_eq!((out.written(), out.acked(), out.inflight_len()), (0, 0, 0));
        let mut order = Vec::new();
        while let Some(e) = out.pop() {
            order.push(match e {
                Entry::Frame(f) => format!("{f:?}"),
                Entry::Command(c) | Entry::Replay(c) => format!("cmd{}", c.tag),
            });
        }
        assert_eq!(
            order,
            vec![format!("{:?}", text("a")), format!("{:?}", Frame::Binary(Bytes::from_static(b"b"))), "cmd1".to_string()],
            "unacked data first in its order, the join left to the fresh session's replay"
        );
        assert_eq!(out.record(text("c"), false), 1, "a fresh session numbers from 1");
    }

    #[test]
    fn prune_takes_stale_live_frames_first_then_the_oldest_and_room_state_last() {
        let now = 1_790_000_000_000i64;
        let asked = Rc::new(Cell::new(0));
        let mut out: Outbound<Item> = Outbound::default();
        const STALE: u32 = 99_999;
        out.push(item(0, Class::RoomState, &asked), now);
        out.push(item(1, Class::Ordinary, &asked), now);
        out.push(item(2, Class::LiveOnly { sealed_ms: now - 1_000 }, &asked), now);
        for k in 3..MAX_UNWRITTEN_ENTRIES as u32 - 1 {
            out.push(item(k, Class::Ordinary, &asked), now);
        }
        out.push(item(STALE, Class::LiveOnly { sealed_ms: now - 301_000 }, &asked), now);
        assert_eq!(asked.get(), 0, "nothing is classed until the queue overflows");
        assert_eq!(out.push(item(100_000, Class::Ordinary, &asked), now), 1);
        assert_eq!(out.push(item(100_001, Class::Ordinary, &asked), now), 1);
        assert_eq!(out.push(item(100_002, Class::Ordinary, &asked), now), 1);
        let classed = asked.get();
        assert!(classed <= MAX_UNWRITTEN_ENTRIES as u32 + 3, "each entry is classed once: {classed}");
        let left = tags(&mut out);
        assert_eq!(left.len(), MAX_UNWRITTEN_ENTRIES);
        assert!(!left.contains(&STALE), "the stale live frame went first, though it was the newest");
        assert_eq!(&left[..3], &[0, 3, 4], "then the oldest, the fresh live frame ranked as any other; room state stayed");

        let mut rooms: Outbound<Item> = Outbound::default();
        let state = |tag| Item { bytes: 20 * 1024 * 1024, class: Class::RoomState, tag, asked: asked.clone() };
        assert_eq!(rooms.push(state(7), now), 0);
        assert_eq!(rooms.push(state(8), now), 1, "the byte bound holds too");
        assert_eq!(tags(&mut rooms), vec![8], "with only room state left, the oldest goes");
    }

    #[test]
    fn an_unwritten_entry_put_back_keeps_its_place() {
        let asked = Rc::new(Cell::new(0));
        let mut out: Outbound<Item> = Outbound::default();
        for k in 0..4 {
            out.push(item(k, Class::Ordinary, &asked), 0);
        }
        let first = out.pop().unwrap();
        out.unpop(first);
        assert!(out.has_unwritten());
        out.push_front(vec![Entry::Replay(item(9, Class::RoomState, &asked)), Entry::Frame(text("f"))], 0);
        assert_eq!(tags(&mut out), vec![9, u32::MAX, 0, 1, 2, 3]);
        assert!(!out.has_unwritten());
    }

    #[test]
    fn the_node_waits_once_half_of_either_bound_is_queued() {
        let asked = Rc::new(Cell::new(0));
        let mut out: Outbound<Item> = Outbound::default();
        for k in 0..MAX_UNWRITTEN_ENTRIES as u32 / 2 - 1 {
            out.push(item(k, Class::Ordinary, &asked), 0);
        }
        assert!(out.has_room());
        out.push(item(0, Class::Ordinary, &asked), 0);
        assert!(!out.has_room(), "half the entries");
        out.pop();
        assert!(out.has_room());

        let mut bytes: Outbound<Item> = Outbound::default();
        let big = |tag| Item { bytes: MAX_UNWRITTEN_BYTES / 2 - 1, class: Class::Ordinary, tag, asked: asked.clone() };
        bytes.push(big(1), 0);
        assert!(bytes.has_room());
        bytes.push(item(2, Class::Ordinary, &asked), 0);
        assert!(!bytes.has_room(), "half the bytes");
    }

    #[test]
    fn a_socket_is_dead_10_s_after_a_heartbeat_with_nothing_heard() {
        let t = Timing::default();
        let t0 = Instant::now();
        let mut l = Liveness::new(t0);
        assert_eq!(l.dead_at(&t), None, "no heartbeat out, nothing to judge");
        l.beat_sent(t0 + secs(15));
        assert_eq!(l.dead_at(&t), Some(t0 + secs(25)));
        l.beat_sent(t0 + secs(20));
        assert_eq!(l.dead_at(&t), Some(t0 + secs(25)), "a second beat does not move the deadline");
        l.heard(t0 + secs(24));
        assert_eq!(l.dead_at(&t), None, "any frame answers");
    }

    #[test]
    fn a_nudge_probes_only_a_socket_quiet_for_2_s_with_a_1_s_deadline() {
        let t = Timing::default();
        let t0 = Instant::now();
        let mut l = Liveness::new(t0);
        assert!(!l.wants_probe(t0 + ms(1999), &t), "a frame in the last 2 s: nothing");
        assert!(l.wants_probe(t0 + secs(2), &t));
        l.probe_sent(t0 + secs(3), &t);
        assert_eq!(l.probe_missed_at(), Some(t0 + secs(4)));
        assert!(!l.wants_probe(t0 + secs(3), &t), "one probe at a time");
        assert_eq!(l.dead_at(&t), Some(t0 + secs(13)), "the probe is a heartbeat too");
        l.probe_given_up();
        assert_eq!(l.probe_missed_at(), None);
        assert_eq!(l.dead_at(&t), Some(t0 + secs(13)), "giving up the probe keeps judging the socket");
        l.probe_sent(t0 + secs(5), &t);
        l.heard(t0 + ms(5500));
        assert_eq!((l.probe_missed_at(), l.dead_at(&t)), (None, None));
    }

    #[test]
    fn a_paused_socket_is_not_judged() {
        let t = Timing::default();
        let t0 = Instant::now();
        let mut l = Liveness::new(t0);
        l.probe_sent(t0 + secs(3), &t);
        l.pause();
        assert_eq!((l.probe_missed_at(), l.dead_at(&t)), (None, None), "no verdict on a socket left unread");
        assert!(l.wants_probe(t0 + secs(3), &t), "the quiet window still runs from what was heard");
    }

    /// Pinned FFI semantics: a suspend ends only when the app comes back (foreground,
    /// focus, a call needing the socket); a network change or a wake never reopens it,
    /// and the client's own nudges never do.
    #[test]
    fn only_the_app_coming_back_ends_a_suspend() {
        for (reason, external, ends) in [
            ("foreground", true, true),
            ("focus", true, true),
            ("call", true, true),
            ("push", true, true),
            ("network", true, false),
            ("wake", true, false),
            ("other", true, false),
            ("foreground", false, false),
            ("push", false, false),
            ("wake", false, false),
        ] {
            assert_eq!(ends_suspend(reason, external), ends, "{reason} external={external}");
        }
        for reason in ["foreground", "focus", "network", "wake", "call", "push"] {
            assert_eq!(app_reason(reason), reason);
        }
        assert_eq!(app_reason("resume"), "other");
        assert_eq!(app_reason(""), "other");
    }

    /// Section 9.7 with uncounted flag frames: a write is known to have reached the relay
    /// only once a heartbeat written after it on the same socket was answered; a new
    /// socket writes the flag again unless the relay is known to hold it.
    #[test]
    fn the_relays_flag_is_known_only_once_a_later_heartbeat_is_answered() {
        let mut f = Flag::default();
        f.fresh_session();
        assert!(!f.needs(false), "a fresh session starts active");
        assert!(f.needs(true));

        f.beat_sent();
        f.wrote(true);
        assert!(!f.needs(true), "written on this socket and in flight");
        assert!(f.needs(false), "the app changed its mind");
        f.answered();
        f.new_socket();
        assert!(f.needs(true) && f.needs(false), "an answer to a beat sent before the write proves nothing");

        f.wrote(true);
        f.beat_sent();
        f.answered();
        f.new_socket();
        assert!(!f.needs(true), "a later beat answered: the relay holds it across sockets");
        assert!(f.needs(false));

        f.wrote(false);
        f.doubt();
        f.beat_sent();
        f.answered();
        f.new_socket();
        assert!(f.needs(false) && f.needs(true), "the session may have moved off a doubted socket");

        f.fresh_session();
        f.wrote(true);
        f.beat_sent();
        f.answered();
        assert!(!f.needs(true));
        f.fresh_session();
        assert!(f.needs(true) && !f.needs(false), "a new session forgets the old one's flag");
    }

    #[test]
    fn heartbeats_are_15_s_in_the_foreground_and_60_s_in_the_background() {
        let t = Timing::default();
        assert_eq!(t.heartbeat_every(false), secs(15));
        assert_eq!(t.heartbeat_every(true), secs(60));
        assert_eq!(t.heartbeat_for(true, false), secs(60));
        assert_eq!(t.heartbeat_for(true, true), secs(15), "a call in the background keeps fast liveness");
        assert_eq!((t.heartbeat_for(false, false), t.heartbeat_for(false, true)), (secs(15), secs(15)));
        assert_eq!((t.dead_after, t.nudge_quiet, t.probe, t.ack_after), (secs(10), secs(2), secs(1), secs(2)));
        assert_eq!((t.suspend_wait, t.sleep_jump, t.backoff_base, t.backoff_cap), (secs(2), secs(5), ms(500), secs(30)));
        assert_eq!(t.realtime_retry, secs(1));
    }

    #[test]
    fn a_wall_clock_jump_of_more_than_5_s_means_the_machine_slept() {
        let t = Timing::default();
        let t0 = Instant::now();
        let at = |wall_ms: i64, mono: Duration| Clocks { wall_ms, mono: t0 + mono };
        let start = at(1_000_000, Duration::ZERO);
        assert!(!start.slept(&at(1_015_000, secs(15)), &t));
        assert!(!start.slept(&at(1_020_000, secs(15)), &t), "5 s apart is not yet a sleep");
        assert!(start.slept(&at(1_020_001, secs(15)), &t));
        assert!(start.slept(&at(3_600_000, secs(15)), &t), "an hour asleep");
        assert!(start.slept(&at(1_000_000, secs(15)), &t), "a clock set back is a jump too");
    }

    #[test]
    fn backoff_is_full_jitter_capped_at_30_s_and_resets() {
        let t = Timing::default();
        let mut b = Backoff::default();
        assert_eq!(b.next(500_000_000, &t), ms(500), "attempt 0 reaches 0.5 s");
        assert_eq!(b.next(1_000_000_000, &t), secs(1));
        assert_eq!(b.next(0, &t), Duration::ZERO, "full jitter starts at zero");
        assert_eq!(b.attempt(), 3);
        assert!(b.next(u64::MAX, &t) <= secs(4));
        for _ in 0..100 {
            assert!(b.next(u64::MAX, &t) <= secs(30));
        }
        assert_eq!(b.next(30_000_000_000, &t), secs(30), "the cap is reachable");
        b.reset();
        assert_eq!(b.attempt(), 0);
        assert!(b.next(u64::MAX, &t) <= ms(500));
        assert_eq!(drain_wait(4_000), secs(4));
        assert_eq!(drain_wait(u64::MAX), MAX_DRAIN_WAIT);
    }

    /// A session the relay still holds is retried within 5 s, so a path that comes back by
    /// itself resumes quickly; past the relay's grace, with no session, or once the relay
    /// refused us (each refused socket costs its per-address budget), the 30 s cap.
    #[test]
    fn a_held_session_retries_within_5_s_until_the_grace_is_over_or_the_relay_refused() {
        let t = Timing::default();
        assert_eq!((t.resume_backoff_cap, t.grace), (secs(5), secs(120)));
        assert_eq!(backoff_cap(&t, true, Some(secs(0)), false), secs(5));
        assert_eq!(backoff_cap(&t, true, Some(secs(119)), false), secs(5));
        assert_eq!(backoff_cap(&t, true, Some(secs(120)), false), secs(30), "the relay's grace is over");
        assert_eq!(backoff_cap(&t, true, Some(secs(3)), true), secs(30), "the relay refused us");
        assert_eq!(backoff_cap(&t, false, Some(secs(3)), false), secs(30), "no session to resume");
        assert_eq!(backoff_cap(&t, true, None, false), secs(30), "never suspended");

        let mut b = Backoff::default();
        for _ in 0..40 {
            assert!(b.next_within(u64::MAX, &t, secs(5)) <= secs(5));
        }
        assert_eq!(b.next_within(5_000_000_000, &t, secs(5)), secs(5), "the cap is reachable");
        assert_eq!(b.next(30_000_000_000, &t), secs(30), "the attempt count carries over to the normal cap");
    }

    #[test]
    fn protocol_frames_carry_the_count_and_are_never_counted() {
        assert_eq!(hb_frame(7), text(r#"{"type":"hb","h":7}"#));
        assert_eq!(ack_frame(3), text(r#"{"type":"ack","h":3}"#));
        for f in [hb_frame(1), ack_frame(1), text(INACTIVE), text(ACTIVE), text(END)] {
            assert_eq!(client_frame_counts(&f), 0, "{f:?}");
        }
        assert_eq!(hb_frame(2).to_message(), Message::Text(r#"{"type":"hb","h":2}"#.into()));
        assert_eq!(Frame::Binary(Bytes::from_static(b"abc")).len(), 3);
    }
}
