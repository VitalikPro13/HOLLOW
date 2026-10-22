//! CRDT catch-up asks: which form each peer device reads, and the digest asks still open.
//!
//! A 0.13 device asks with a range digest (`crdt::digest`), an older one only understands
//! the per-author state vector. A device's own sync frames say which it is (`dg`); one not
//! heard from yet gets the digest with an empty vector, which an older build cannot parse
//! and leaves unanswered. A request showing the device is older is asked again with the
//! vector at once. A silent ask is sent again unchanged, so a late first answer still
//! counts and a lost one is replaced; only a device that never showed it reads digests
//! and stays silent through every copy gets the vector, never a slow 0.13 device (each
//! vector costs one entry per op author). A digest answer that splits a range is followed
//! only for the ask it names, while that ask is open.

use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};

use crate::crdt::digest::{self, DigestReply, KeptRef, OpDigest};
use crate::crdt::server_state::{Anchor, ServerState};
use crate::crdt::sync::StateVector;

use super::types::HavenMessage;

/// Marks a sync frame from a build that reads digests.
pub(crate) const DG: u8 = 1;
/// Devices whose form we remember.
const CAPS_MAX: usize = 4096;
/// An ask nothing answered in this long is sent again; each later wait doubles, and the
/// ask is judged once the last copy waited out its own (35 s, 21 s in tests).
const RESEND_AFTER: Duration = Duration::from_secs(if cfg!(test) { 3 } else { 5 });
/// Copies of a silent ask sent before it is judged.
const RESENDS: u32 = 2;
/// A digest device's ask stays open this long after its round left, copies or not, so a
/// late split is still followed.
const ASK_TTL: Duration = Duration::from_secs(60);
/// How long after our join completes we ask more members what we may have missed.
/// (In the harness, past the joiner's own first-contact syncs, so a test can tell them apart.)
const JOIN_FOLLOW_UP: Duration = Duration::from_secs(if cfg!(test) { 6 } else { 5 });
/// Member devices asked after a join.
pub(crate) const JOIN_FOLLOW_UP_PEERS: usize = 2;

/// What a device reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Reads {
    Digest,
    Vector,
    Unknown,
}

#[derive(Debug, Clone)]
struct Ask {
    id: u64,
    salt: String,
    round: u8,
    nonce: Option<u64>,
    /// The first ask named our MLS epoch. Every later send names the epoch we are at
    /// then: an older one reads as a stale member, and the answerer repairs our leaf.
    hinted: bool,
    sent_at: Instant,
    round_at: Instant,
    /// Every copy went unanswered; kept only for a late answer.
    judged: bool,
    /// The device's form was unknown when asked, and nothing came back yet.
    unconfirmed: bool,
    /// The ranges the last round asked: a split may only cover them.
    asked: Vec<(u64, u64)>,
    /// What the last round sent, and how often it was sent again unanswered.
    last: Box<HavenMessage>,
    resends: u32,
}

/// An open ask the silence clock acted on.
pub(crate) enum Silent {
    /// Send (server, device) this copy of the ask again.
    Again(String, String, Box<HavenMessage>),
    /// A device never seen to read digests left every copy unanswered: ask (server,
    /// device) with the vector, carrying (nonce, mls_epoch). Goes with the vector in 0.14.
    Vector(String, String, Option<u64>, Option<u64>),
    /// A device that reads digests left every copy unanswered: no more copies go.
    Closed(String, String),
}

/// What to do with a digest answer.
pub(crate) enum Step {
    /// No open ask of ours names it: dropped.
    Unasked,
    /// The ask is complete.
    Done,
    /// The answer was not one an honest answerer sends: the ask is closed.
    Malformed,
    /// Ask the same device again, with this.
    Again(Box<HavenMessage>),
}

#[derive(Default)]
pub(crate) struct OpSync {
    caps: HashMap<String, bool>,
    order: VecDeque<String>,
    /// (server, device) -> the open ask.
    asks: HashMap<(String, String), Ask>,
    follow_ups: Vec<(String, Instant)>,
    /// Our own ops on a server whose room we were not in yet when we authored them:
    /// carried to its members once the relay first lists the room for us.
    unseen: HashMap<String, Vec<HavenMessage>>,
    /// This node plays a 0.12.2 build (tests of the mixed-version server only).
    old: bool,
}

/// Ops kept per server for its first room listing.
const UNSEEN_MAX: usize = 16;

#[cfg(test)]
static OLD_BUILDS: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

/// Make the node of `device` speak sync as 0.12.2 did (vector asks, no digest, no mark)
/// while the guard lives. Set before the node starts.
#[cfg(test)]
pub(crate) fn act_old_for_test(device: &str) -> OldBuildGuard {
    OLD_BUILDS.lock().unwrap().push(device.to_string());
    OldBuildGuard(device.to_string())
}

#[cfg(test)]
pub(crate) struct OldBuildGuard(String);

#[cfg(test)]
impl Drop for OldBuildGuard {
    fn drop(&mut self) {
        OLD_BUILDS.lock().unwrap_or_else(|e| e.into_inner()).retain(|d| *d != self.0);
    }
}

fn acts_old(device: &str) -> bool {
    #[cfg(test)]
    {
        OLD_BUILDS.lock().unwrap().iter().any(|d| d == device)
    }
    #[cfg(not(test))]
    {
        let _ = device;
        false
    }
}

/// A request in the old form, for a device or a server that only reads it.
pub(crate) fn vector_ask(state: &ServerState, nonce: Option<u64>, mls_epoch: Option<u64>) -> HavenMessage {
    HavenMessage::SyncRequest {
        server_id: state.server_id.clone(),
        state_vector_json: serde_json::to_string(&StateVector::from_server_state(state)).unwrap_or_default(),
        mls_epoch,
        nonce,
        full: None,
        digest: None,
        dg: Some(DG),
    }
}

fn fresh_id() -> u64 {
    let mut b = [0u8; 8];
    let _ = getrandom::fill(&mut b);
    u64::from_le_bytes(b)
}

impl OpSync {
    /// Called once with this node's device id.
    pub(crate) fn set_local(&mut self, device: &str) {
        self.old = acts_old(device);
    }

    /// This node speaks sync as a 0.12.2 build (tests only).
    pub(crate) fn is_old(&self) -> bool {
        self.old
    }

    /// The `dg` mark our sync frames carry.
    pub(crate) fn mark(&self) -> Option<u8> {
        (!self.old).then_some(DG)
    }

    pub(crate) fn reads(&self, device: &str) -> Reads {
        match self.caps.get(device) {
            Some(true) => Reads::Digest,
            Some(false) => Reads::Vector,
            None => Reads::Unknown,
        }
    }

    /// Whether any device of `identity` (a master) is known to read digests: a 0.13 author
    /// always carries its own ops, so nobody hands them on.
    pub(crate) fn identity_reads_digest(&self, identity: &str) -> bool {
        std::iter::once(identity.to_string())
            .chain(super::resolver::devices_for(identity))
            .any(|d| self.reads(&d) == Reads::Digest)
    }

    /// Note what a device's sync frame shows it reads.
    pub(crate) fn learn(&mut self, device: &str, digest: bool) {
        if self.caps.insert(device.to_string(), digest).is_none() {
            self.order.push_back(device.to_string());
            while self.order.len() > CAPS_MAX {
                if let Some(old) = self.order.pop_front() {
                    self.caps.remove(&old);
                }
            }
        }
        if digest {
            for ((_, d), ask) in self.asks.iter_mut() {
                if d == device {
                    ask.unconfirmed = false;
                }
            }
        }
    }

    /// The sync ask for `state` to `device`: the digest unless the device or the server
    /// only reads the vector.
    pub(crate) fn ask(
        &mut self,
        state: &ServerState,
        kept: &[KeptRef<'_>],
        device: &str,
        nonce: Option<u64>,
        mls_epoch: Option<u64>,
    ) -> HavenMessage {
        let reads = self.reads(device);
        if self.old {
            let HavenMessage::SyncRequest { server_id, state_vector_json, .. } = vector_ask(state, nonce, mls_epoch) else {
                unreachable!("a vector ask is a sync request")
            };
            return HavenMessage::SyncRequest { server_id, state_vector_json, mls_epoch, nonce, full: None, digest: None, dg: None };
        }
        if state.anchor() == Anchor::Legacy || reads == Reads::Vector {
            return vector_ask(state, nonce, mls_epoch);
        }
        let id = fresh_id();
        let salt = digest::new_salt();
        let base = state.checkpoint_hlc.clone();
        let d = digest::first_ask(&digest::entries(state, kept, base.as_ref()), id, salt.clone(), base);
        let key = (state.server_id.clone(), device.to_string());
        // A newer ask replaces the open one, keeping the nonce a held join waits on.
        let nonce = nonce.or_else(|| self.asks.get(&key).and_then(|a| a.nonce));
        let asked = d.ranges.iter().map(|r| (r.0, r.1)).collect();
        let now = Instant::now();
        let msg = HavenMessage::SyncRequest {
            server_id: state.server_id.clone(),
            state_vector_json: String::new(),
            mls_epoch,
            nonce,
            full: None,
            digest: Some(d),
            dg: Some(DG),
        };
        self.asks.insert(
            key,
            Ask {
                id, salt, round: 0, nonce, hinted: mls_epoch.is_some(), sent_at: now, round_at: now, judged: false,
                unconfirmed: reads == Reads::Unknown, asked, last: Box::new(msg.clone()), resends: 0,
            },
        );
        msg
    }

    /// A request from `device` arrived; one without the mark shows it reads only the
    /// vector, and the servers of our open digest asks to it are returned to ask again
    /// with the vector now, as (server, nonce, mls_epoch). `epoch_of` is our MLS epoch of
    /// a server now.
    pub(crate) fn heard_request(
        &mut self,
        device: &str,
        dg: Option<u8>,
        epoch_of: &dyn Fn(&str) -> Option<u64>,
    ) -> Vec<(String, Option<u64>, Option<u64>)> {
        let digest = dg.is_some_and(|v| v >= DG);
        self.learn(device, digest);
        if digest {
            return Vec::new();
        }
        let open: Vec<(String, String)> = self.asks.keys().filter(|(_, d)| d == device).cloned().collect();
        open.into_iter()
            .filter_map(|key| {
                let a = self.asks.remove(&key)?;
                let epoch = a.hinted.then(|| epoch_of(&key.0)).flatten();
                Some((key.0, a.nonce, epoch))
            })
            .collect()
    }

    /// The next step for a digest answer from `device` about `state`; `epoch_now` is our
    /// MLS epoch of it.
    pub(crate) fn answered(
        &mut self,
        state: &ServerState,
        kept: &[KeptRef<'_>],
        device: &str,
        reply: &DigestReply,
        epoch_now: Option<u64>,
    ) -> Step {
        let key = (state.server_id.clone(), device.to_string());
        let Some(ask) = self.asks.get_mut(&key).filter(|a| a.id == reply.ask && a.round == reply.round) else {
            return Step::Unasked;
        };
        ask.unconfirmed = false;
        if reply.vector {
            let ask = self.asks.remove(&key).expect("open");
            return Step::Again(Box::new(vector_ask(state, ask.nonce, epoch_now.filter(|_| ask.hinted))));
        }
        if reply.groups.is_empty() || reply.round >= digest::MAX_ROUNDS {
            self.asks.remove(&key);
            return Step::Done;
        }
        let base = state.checkpoint_hlc.clone();
        let Some(ranges) = digest::follow_up(&digest::entries(state, kept, base.as_ref()), &ask.salt, &ask.asked, reply) else {
            self.asks.remove(&key);
            return Step::Malformed;
        };
        ask.asked = ranges.iter().map(|r| (r.0, r.1)).collect();
        ask.round = reply.round + 1;
        ask.sent_at = Instant::now();
        ask.round_at = ask.sent_at;
        ask.resends = 0;
        ask.judged = false;
        // Sent even when empty: its answer is the final one a held join waits for.
        *ask.last = HavenMessage::SyncRequest {
            server_id: state.server_id.clone(),
            state_vector_json: String::new(),
            mls_epoch: None,
            nonce: ask.nonce,
            full: None,
            digest: Some(OpDigest { ask: ask.id, salt: ask.salt.clone(), base, from: None, ranges, round: ask.round }),
            dg: Some(DG),
        };
        Step::Again(ask.last.clone())
    }

    /// `msg` carries an op we authored on `server` before its room listed anyone for us:
    /// no receiver forwards it, so it goes to the members once the room is listed.
    pub(crate) fn carry_when_listed(&mut self, server: &str, msg: HavenMessage) {
        let kept = self.unseen.entry(server.to_string()).or_default();
        if kept.len() < UNSEEN_MAX {
            kept.push(msg);
        }
    }

    /// The ops waiting for `room`'s first listing.
    pub(crate) fn listed(&mut self, room: &str) -> Vec<HavenMessage> {
        self.unseen.remove(room).unwrap_or_default()
    }

    /// Our join of `server` completed: ask more members soon.
    pub(crate) fn joined(&mut self, server: &str) {
        if !self.follow_ups.iter().any(|(s, _)| s == server) {
            self.follow_ups.push((server.to_string(), Instant::now() + JOIN_FOLLOW_UP));
        }
    }

    /// What the silence clock does to open asks, and the servers whose post-join
    /// follow-up is due. `epoch_of` is our MLS epoch of a server now.
    pub(crate) fn tick(
        &mut self,
        now: Instant,
        lane_holds: &dyn Fn(&str) -> bool,
        epoch_of: &dyn Fn(&str) -> Option<u64>,
    ) -> (Vec<Silent>, Vec<String>) {
        let mut silent = Vec::new();
        self.asks.retain(|(server, device), ask| {
            if ask.judged {
                return now.saturating_duration_since(ask.round_at) < ASK_TTL;
            }
            // An ask still paced out, or waiting for an Olm session, has not left: its
            // silence clock has not started.
            if lane_holds(device) {
                ask.sent_at = now;
                ask.round_at = now;
                return true;
            }
            if now.saturating_duration_since(ask.sent_at) < RESEND_AFTER * (1 << ask.resends) {
                return true;
            }
            if ask.resends < RESENDS {
                ask.resends += 1;
                ask.sent_at = now;
                let mut copy = ask.last.clone();
                if let HavenMessage::SyncRequest { mls_epoch, .. } = copy.as_mut()
                    && mls_epoch.is_some()
                {
                    *mls_epoch = epoch_of(server);
                }
                silent.push(Silent::Again(server.clone(), device.clone(), copy));
                return true;
            }
            // A held join judges after 10 s, before a silent unknown 0.12.2 device gets
            // this; its own unmarked request gets it the vector at once.
            if ask.unconfirmed {
                let epoch = ask.hinted.then(|| epoch_of(server)).flatten();
                silent.push(Silent::Vector(server.clone(), device.clone(), ask.nonce, epoch));
                return false;
            }
            silent.push(Silent::Closed(server.clone(), device.clone()));
            ask.judged = true;
            now.saturating_duration_since(ask.round_at) < ASK_TTL
        });
        let (due, wait): (Vec<_>, Vec<_>) = self.follow_ups.drain(..).partition(|(_, at)| *at <= now);
        self.follow_ups = wait;
        (silent, due.into_iter().map(|(s, _)| s).collect())
    }

    /// The socket went away: no open ask can be answered any more.
    pub(crate) fn went_away(&mut self) {
        self.asks.clear();
    }

    #[cfg(test)]
    pub(crate) fn open_asks(&self) -> usize {
        self.asks.len()
    }

    #[cfg(test)]
    pub(crate) fn debug_caps(&self) -> HashMap<String, bool> {
        self.caps.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crdt::digest::{DigestReply, Range};
    use crate::crdt::testkeys::keys;

    fn server() -> ServerState {
        let (kp, owner, pk) = keys(1);
        let (mut s, _) = ServerState::found("S".into(), owner, kp, pk);
        for i in 0..100 {
            s.author_checked(crate::crdt::operations::CrdtPayload::ServerSettingChanged { key: format!("k{i}"), value: "v".into() });
        }
        s
    }

    fn digest_of(msg: &HavenMessage) -> Option<&OpDigest> {
        match msg {
            HavenMessage::SyncRequest { digest, .. } => digest.as_ref(),
            _ => None,
        }
    }

    fn vector_of(msg: &HavenMessage) -> Option<&str> {
        match msg {
            HavenMessage::SyncRequest { digest: None, state_vector_json, .. } => Some(state_vector_json),
            _ => None,
        }
    }

    /// An unknown device gets the digest with a vector no older build can parse; one whose
    /// own request shows it is older has our open asks sent again with the vector, at once.
    #[test]
    fn an_older_device_is_asked_again_with_the_vector_at_once() {
        let s = server();
        let mut book = OpSync::default();
        let ask = book.ask(&s, &[], "dev", Some(4), Some(2));
        assert!(digest_of(&ask).is_some());
        assert!(matches!(&ask, HavenMessage::SyncRequest { state_vector_json, .. } if state_vector_json.is_empty()));
        assert_eq!(book.heard_request("dev", Some(DG), &|_| None), Vec::new(), "a 0.13 request resends nothing");
        let _ = book.ask(&s, &[], "old", Some(4), Some(2));
        let again = book.heard_request("old", None, &|_| Some(2));
        assert_eq!(again, vec![(s.server_id.clone(), Some(4), Some(2))]);
        assert_eq!(book.reads("old"), Reads::Vector);
        assert!(vector_of(&book.ask(&s, &[], "old", None, None)).is_some_and(|v| !v.is_empty()), "an older device got a digest");
    }

    fn kinds(silent: &[Silent]) -> Vec<String> {
        silent
            .iter()
            .map(|s| match s {
                Silent::Again(_, d, _) => format!("again {d}"),
                Silent::Vector(_, d, _, _) => format!("vector {d}"),
                Silent::Closed(_, d) => format!("closed {d}"),
            })
            .collect()
    }

    /// A silent ask goes again unchanged with a doubling wait; then a device never seen to
    /// read digests gets the vector and one that reads them has its ask closed, never the
    /// vector.
    #[test]
    fn a_silent_ask_goes_again_before_the_vector_and_only_an_unknown_device_gets_it() {
        let s = server();
        let mut book = OpSync::default();
        let t0 = Instant::now();
        let first = book.ask(&s, &[], "quiet", Some(5), Some(1));
        book.learn("known", true);
        let _ = book.ask(&s, &[], "known", None, None);
        let (silent, _) = book.tick(t0 + RESEND_AFTER / 2, &|_| false, &|_| Some(7));
        assert!(silent.is_empty(), "an ask went again before its wait");
        let t1 = t0 + RESEND_AFTER + Duration::from_millis(50);
        let (silent, _) = book.tick(t1, &|_| false, &|_| Some(7));
        let mut k = kinds(&silent);
        k.sort();
        assert_eq!(k, ["again known", "again quiet"]);
        for step in &silent {
            if let Silent::Again(_, d, msg) = step
                && d == "quiet"
            {
                assert_eq!(digest_of(msg).map(|d| (d.ask, d.round)), digest_of(&first).map(|d| (d.ask, d.round)), "not the same ask");
                assert!(matches!(**msg, HavenMessage::SyncRequest { mls_epoch: Some(7), .. }), "the copy kept an old epoch hint");
            }
        }
        let (silent, _) = book.tick(t1 + RESEND_AFTER, &|_| false, &|_| Some(7));
        assert!(silent.is_empty(), "the second copy did not wait twice as long");
        let t2 = t1 + RESEND_AFTER * 2 + Duration::from_millis(50);
        assert_eq!(kinds(&book.tick(t2, &|_| false, &|_| Some(7)).0).len(), 2, "no second copy");
        let (silent, _) = book.tick(t2 + RESEND_AFTER * 3, &|_| false, &|_| Some(7));
        assert!(silent.is_empty(), "judged before the last copy waited four times as long");
        let (silent, _) = book.tick(t2 + RESEND_AFTER * 4 + Duration::from_millis(50), &|_| false, &|_| Some(7));
        let mut k = kinds(&silent);
        k.sort();
        assert_eq!(k, ["closed known", "vector quiet"]);
        assert!(silent.iter().any(|s| matches!(s, Silent::Vector(_, d, Some(5), Some(7)) if d == "quiet")), "the vector ask lost the nonce or kept an old epoch");
        assert_eq!(book.open_asks(), 1, "the digest device's ask closed before a late answer could land");
        let (silent, _) = book.tick(t0 + ASK_TTL - Duration::from_millis(50), &|_| false, &|_| Some(7));
        assert!(silent.is_empty(), "a judged ask was sent again");
        assert_eq!(book.open_asks(), 1);
        let _ = book.tick(t0 + ASK_TTL + Duration::from_millis(50), &|_| false, &|_| Some(7));
        assert_eq!(book.open_asks(), 0, "a judged ask outlived the TTL");
    }

    /// A device that shows it reads digests while its ask waits never gets the vector, and
    /// an answer to the ask restarts its clock.
    #[test]
    fn a_device_heard_reading_digests_while_silent_never_gets_the_vector() {
        let s = server();
        let mut book = OpSync::default();
        let t0 = Instant::now();
        let _ = book.ask(&s, &[], "slow", None, None);
        assert_eq!(book.heard_request("slow", Some(DG), &|_| None), Vec::new());
        let mut silent = Vec::new();
        for i in 1..=8 {
            silent.extend(kinds(&book.tick(t0 + RESEND_AFTER * (i * 5), &|_| false, &|_| Some(7)).0));
        }
        assert_eq!(silent, ["again slow", "again slow", "closed slow"]);
        let ask = book.ask(&s, &[], "dev", None, Some(3));
        let d = digest_of(&ask).unwrap();
        let Range(lo, hi, _, _) = d.ranges[0].clone();
        let split = DigestReply { ask: d.ask, round: 0, groups: vec![vec![Range(lo, lo, 1, "x".into()), Range(lo + 1, hi, 1, "y".into())]], vector: false };
        let t1 = Instant::now();
        let _ = book.tick(t1 + RESEND_AFTER * 2, &|_| false, &|_| Some(7));
        let _ = book.tick(t1 + RESEND_AFTER * 5, &|_| false, &|_| Some(7));
        assert!(matches!(book.answered(&s, &[], "dev", &split, None), Step::Again(_)));
        let (silent, _) = book.tick(Instant::now() + RESEND_AFTER + Duration::from_millis(50), &|_| false, &|_| Some(7));
        match silent.as_slice() {
            [Silent::Again(_, d, msg)] if d == "dev" => {
                assert_eq!(digest_of(msg).map(|d| d.round), Some(1), "not the follow-up");
                assert!(matches!(**msg, HavenMessage::SyncRequest { mls_epoch: None, .. }), "a follow-up copy gained an epoch hint");
            }
            _ => panic!("the follow-up was not sent again: {:?}", kinds(&silent)),
        }
    }

    /// An ask still held by the pacer has not left: its clock starts once it leaves.
    #[test]
    fn a_paced_ask_starts_its_clock_when_it_leaves() {
        let s = server();
        let mut book = OpSync::default();
        let _ = book.ask(&s, &[], "paced", None, None);
        let later = Instant::now() + RESEND_AFTER * 2;
        let (silent, _) = book.tick(later, &|d| d == "paced", &|_| None);
        assert!(silent.is_empty(), "an ask still held by the pacer went again");
        let (silent, _) = book.tick(later + RESEND_AFTER, &|_| false, &|_| Some(7));
        assert_eq!(kinds(&silent), ["again paced"]);
    }

    /// A split continues only the open ask it names, in the round it names; a socket loss
    /// closes every ask.
    #[test]
    fn a_split_continues_only_its_own_open_ask() {
        let s = server();
        let mut book = OpSync::default();
        let ask = book.ask(&s, &[], "dev", Some(1), None);
        let d = digest_of(&ask).unwrap();
        let (id, Range(lo, hi, _, _)) = (d.ask, d.ranges[0].clone());
        assert!(hi > lo, "the first range spans several ms");
        let split = |ask: u64, round: u8| DigestReply {
            ask, round, groups: vec![vec![Range(lo, lo, 1, "x".into()), Range(lo + 1, hi, 1, "y".into())]], vector: false,
        };
        assert!(matches!(book.answered(&s, &[], "other", &split(id, 0), None), Step::Unasked), "another device's split");
        assert!(matches!(book.answered(&s, &[], "dev", &split(id ^ 1, 0), None), Step::Unasked), "a split for another ask");
        assert!(matches!(book.answered(&s, &[], "dev", &split(id, 3), None), Step::Unasked), "a split for another round");
        match book.answered(&s, &[], "dev", &split(id, 0), None) {
            Step::Again(next) => {
                let d = digest_of(&next).expect("a digest follow-up");
                assert_eq!((d.ask, d.round, d.from), (id, 1, None));
            }
            _ => panic!("the split was not followed"),
        }
        let done = DigestReply { ask: id, round: 1, groups: Vec::new(), vector: false };
        assert!(matches!(book.answered(&s, &[], "dev", &done, None), Step::Done));
        assert!(matches!(book.answered(&s, &[], "dev", &done, None), Step::Unasked), "a closed ask answered twice");
        let _ = book.ask(&s, &[], "dev", None, None);
        book.went_away();
        assert_eq!(book.open_asks(), 0);
    }

    /// A split outside what we asked, or overlapping itself, closes the ask unfollowed.
    #[test]
    fn a_malformed_split_closes_the_ask() {
        let s = server();
        let mut book = OpSync::default();
        let ask = book.ask(&s, &[], "dev", None, None);
        let d = digest_of(&ask).unwrap();
        let last = d.ranges.last().unwrap().1;
        let outside = DigestReply {
            ask: d.ask, round: 0, groups: vec![vec![Range(last + 1, last + 1, 1, "x".into()), Range(last + 2, last + 3, 1, "y".into())]], vector: false,
        };
        assert!(matches!(book.answered(&s, &[], "dev", &outside, None), Step::Malformed));
        assert_eq!(book.open_asks(), 0);
        let ask = book.ask(&s, &[], "dev", None, None);
        let d = digest_of(&ask).unwrap();
        let Range(lo, hi, _, _) = d.ranges[0].clone();
        let overlapping = DigestReply { ask: d.ask, round: 0, groups: vec![vec![Range(lo, hi, 1, "x".into()), Range(lo, hi, 1, "y".into())]], vector: false };
        assert!(matches!(book.answered(&s, &[], "dev", &overlapping, None), Step::Malformed));
    }

    /// A newer ask to the same device keeps the nonce a held join waits on.
    #[test]
    fn a_newer_ask_keeps_the_open_asks_nonce() {
        let s = server();
        let mut book = OpSync::default();
        let _ = book.ask(&s, &[], "dev", Some(42), None);
        match book.ask(&s, &[], "dev", None, None) {
            HavenMessage::SyncRequest { nonce, .. } => assert_eq!(nonce, Some(42)),
            _ => panic!("not a sync request"),
        }
    }

    /// An answerer that reads only the vector for this server sends us to it.
    #[test]
    fn a_vector_reply_asks_again_with_the_vector() {
        let s = server();
        let mut book = OpSync::default();
        let ask = book.ask(&s, &[], "dev", Some(8), Some(3));
        let id = digest_of(&ask).unwrap().ask;
        match book.answered(&s, &[], "dev", &DigestReply { ask: id, round: 0, groups: Vec::new(), vector: true }, None) {
            Step::Again(next) => assert!(vector_of(&next).is_some_and(|v| !v.is_empty())),
            _ => panic!("no vector ask"),
        }
    }

    // ---- review (g13w2-g-sync-fallback) ----

    /// The vector re-ask a device's own unmarked request triggers carries our epoch now,
    /// like the copies sent before it, never the one from when the ask first left.
    #[test]
    fn review_heard_request_vector_reask_carries_no_older_epoch_than_its_copies() {
        let s = server();
        let mut book = OpSync::default();
        let t0 = Instant::now();
        let _ = book.ask(&s, &[], "old", Some(5), Some(1));
        let (silent, _) = book.tick(t0 + RESEND_AFTER + Duration::from_millis(50), &|_| false, &|_| Some(7));
        assert!(silent.iter().any(|x| matches!(x, Silent::Again(_, _, m) if matches!(**m, HavenMessage::SyncRequest { mls_epoch: Some(7), .. }))));
        let heard = book.heard_request("old", None, &|_| Some(7));
        assert_eq!(heard.len(), 1);
        assert_eq!(heard[0].2, Some(7), "the vector re-ask names the epoch from the first ask, older than the copy it follows");
    }

    /// A vector reply to a copy re-asks with our epoch now, like the copy it answers.
    #[test]
    fn review_vector_reply_to_a_copy_carries_no_older_epoch_than_the_copy() {
        let s = server();
        let mut book = OpSync::default();
        let t0 = Instant::now();
        let ask = book.ask(&s, &[], "dev", Some(8), Some(1));
        let id = digest_of(&ask).unwrap().ask;
        let _ = book.tick(t0 + RESEND_AFTER + Duration::from_millis(50), &|_| false, &|_| Some(7));
        match book.answered(&s, &[], "dev", &DigestReply { ask: id, round: 0, groups: Vec::new(), vector: true }, Some(7)) {
            Step::Again(next) => assert!(
                matches!(*next, HavenMessage::SyncRequest { mls_epoch: Some(7), .. }),
                "the vector re-ask names the first ask's epoch, older than the copy it answers"
            ),
            _ => panic!("no vector ask"),
        }
    }

    /// A known digest device's split that lands after the verdict but inside the 60 s the
    /// ask used to stay open is still followed.
    #[test]
    fn review_a_late_split_inside_the_old_ttl_is_still_followed() {
        let s = server();
        let mut book = OpSync::default();
        book.learn("dev", true);
        let t0 = Instant::now();
        let ask = book.ask(&s, &[], "dev", None, None);
        let d = digest_of(&ask).unwrap();
        let Range(lo, hi, _, _) = d.ranges[0].clone();
        let split = DigestReply { ask: d.ask, round: 0, groups: vec![vec![Range(lo, lo, 1, "x".into()), Range(lo + 1, hi, 1, "y".into())]], vector: false };
        let mut verdict = Vec::new();
        for i in 1..=8u32 {
            verdict.extend(kinds(&book.tick(t0 + RESEND_AFTER * (i * 2), &|_| false, &|_| None).0));
        }
        assert_eq!(verdict, ["again dev", "again dev", "closed dev"]);
        assert!(matches!(book.answered(&s, &[], "dev", &split, None), Step::Again(_)), "a split 40 s after the ask was dropped as unasked");
    }
}
