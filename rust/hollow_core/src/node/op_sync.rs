//! CRDT catch-up asks: which form each peer device reads, and the digest asks still open.
//!
//! A 0.13 device asks with a range digest (`crdt::digest`), an older one only understands
//! the per-author state vector. A device's own sync frames say which it is (`dg`); one not
//! heard from yet gets the digest with an empty vector, which an older build cannot parse
//! and leaves unanswered, so a silent ask, or a request showing the device is older, is
//! asked again with the vector. A digest answer that splits a range is followed only for
//! the ask it names, while that ask is open.

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
/// A device of unknown form that has not answered a digest in this long is asked with the
/// vector.
const SILENT_FALLBACK: Duration = Duration::from_secs(if cfg!(test) { 2 } else { 5 });
/// An ask no answer continued in this long is closed.
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
    mls_epoch: Option<u64>,
    sent_at: Instant,
    /// The device's form was unknown when asked, and nothing came back yet.
    unconfirmed: bool,
    /// The ranges the last round asked: a split may only cover them.
    asked: Vec<(u64, u64)>,
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
        self.asks.insert(
            key,
            Ask { id, salt, round: 0, nonce, mls_epoch, sent_at: Instant::now(), unconfirmed: reads == Reads::Unknown, asked },
        );
        HavenMessage::SyncRequest {
            server_id: state.server_id.clone(),
            state_vector_json: String::new(),
            mls_epoch,
            nonce,
            full: None,
            digest: Some(d),
            dg: Some(DG),
        }
    }

    /// A request from `device` arrived; one without the mark shows it reads only the
    /// vector, and the servers of our open digest asks to it are returned to ask again
    /// with the vector now, as (server, nonce, mls_epoch).
    pub(crate) fn heard_request(&mut self, device: &str, dg: Option<u8>) -> Vec<(String, Option<u64>, Option<u64>)> {
        let digest = dg.is_some_and(|v| v >= DG);
        self.learn(device, digest);
        if digest {
            return Vec::new();
        }
        let open: Vec<(String, String)> = self.asks.keys().filter(|(_, d)| d == device).cloned().collect();
        open.into_iter()
            .filter_map(|key| self.asks.remove(&key).map(|a| (key.0, a.nonce, a.mls_epoch)))
            .collect()
    }

    /// The next step for a digest answer from `device` about `state`.
    pub(crate) fn answered(&mut self, state: &ServerState, kept: &[KeptRef<'_>], device: &str, reply: &DigestReply) -> Step {
        let key = (state.server_id.clone(), device.to_string());
        let Some(ask) = self.asks.get_mut(&key).filter(|a| a.id == reply.ask && a.round == reply.round) else {
            return Step::Unasked;
        };
        ask.unconfirmed = false;
        if reply.vector {
            let ask = self.asks.remove(&key).expect("open");
            return Step::Again(Box::new(vector_ask(state, ask.nonce, ask.mls_epoch)));
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
        // Sent even when empty: its answer is the final one a held join waits for.
        Step::Again(Box::new(HavenMessage::SyncRequest {
            server_id: state.server_id.clone(),
            state_vector_json: String::new(),
            mls_epoch: None,
            nonce: ask.nonce,
            full: None,
            digest: Some(OpDigest { ask: ask.id, salt: ask.salt.clone(), base, from: None, ranges, round: ask.round }),
            dg: Some(DG),
        }))
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

    /// Asks to send the vector to (silent devices of unknown form), as (server, device,
    /// nonce, mls_epoch), and the servers whose post-join follow-up is due.
    #[allow(clippy::type_complexity)]
    pub(crate) fn tick(
        &mut self,
        now: Instant,
        lane_holds: &dyn Fn(&str) -> bool,
    ) -> (Vec<(String, String, Option<u64>, Option<u64>)>, Vec<String>) {
        let mut silent = Vec::new();
        self.asks.retain(|(server, device), ask| {
            // An ask still paced out has not left: its silence clock has not started.
            if lane_holds(device) {
                ask.sent_at = now;
                return true;
            }
            let age = now.saturating_duration_since(ask.sent_at);
            if ask.unconfirmed && age >= SILENT_FALLBACK {
                silent.push((server.clone(), device.clone(), ask.nonce, ask.mls_epoch));
                return false;
            }
            age < ASK_TTL
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
        assert_eq!(book.heard_request("dev", Some(DG)), Vec::new(), "a 0.13 request resends nothing");
        let _ = book.ask(&s, &[], "old", Some(4), Some(2));
        let again = book.heard_request("old", None);
        assert_eq!(again, vec![(s.server_id.clone(), Some(4), Some(2))]);
        assert_eq!(book.reads("old"), Reads::Vector);
        assert!(vector_of(&book.ask(&s, &[], "old", None, None)).is_some_and(|v| !v.is_empty()), "an older device got a digest");
    }

    /// A device of unknown form that stays silent is asked with the vector; one we know
    /// reads digests is not.
    #[test]
    fn a_silent_unknown_device_gets_the_vector() {
        let s = server();
        let mut book = OpSync::default();
        let _ = book.ask(&s, &[], "quiet", None, None);
        book.learn("known", true);
        let _ = book.ask(&s, &[], "known", None, None);
        let (silent, _) = book.tick(Instant::now() + SILENT_FALLBACK, &|_| false);
        assert_eq!(silent.iter().map(|(_, d, _, _)| d.as_str()).collect::<Vec<_>>(), ["quiet"]);
        assert_eq!(book.open_asks(), 1, "the known device's ask stays open");
        let _ = book.ask(&s, &[], "paced", None, None);
        let later = Instant::now() + SILENT_FALLBACK * 2;
        let (silent, _) = book.tick(later, &|d| d == "paced");
        assert!(silent.is_empty(), "an ask still held by the pacer fell back");
        let (silent, _) = book.tick(later + SILENT_FALLBACK, &|_| false);
        assert_eq!(silent.iter().map(|(_, d, _, _)| d.as_str()).collect::<Vec<_>>(), ["paced"], "its clock starts once it leaves");
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
        assert!(matches!(book.answered(&s, &[], "other", &split(id, 0)), Step::Unasked), "another device's split");
        assert!(matches!(book.answered(&s, &[], "dev", &split(id ^ 1, 0)), Step::Unasked), "a split for another ask");
        assert!(matches!(book.answered(&s, &[], "dev", &split(id, 3)), Step::Unasked), "a split for another round");
        match book.answered(&s, &[], "dev", &split(id, 0)) {
            Step::Again(next) => {
                let d = digest_of(&next).expect("a digest follow-up");
                assert_eq!((d.ask, d.round, d.from), (id, 1, None));
            }
            _ => panic!("the split was not followed"),
        }
        let done = DigestReply { ask: id, round: 1, groups: Vec::new(), vector: false };
        assert!(matches!(book.answered(&s, &[], "dev", &done), Step::Done));
        assert!(matches!(book.answered(&s, &[], "dev", &done), Step::Unasked), "a closed ask answered twice");
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
        assert!(matches!(book.answered(&s, &[], "dev", &outside), Step::Malformed));
        assert_eq!(book.open_asks(), 0);
        let ask = book.ask(&s, &[], "dev", None, None);
        let d = digest_of(&ask).unwrap();
        let Range(lo, hi, _, _) = d.ranges[0].clone();
        let overlapping = DigestReply { ask: d.ask, round: 0, groups: vec![vec![Range(lo, hi, 1, "x".into()), Range(lo, hi, 1, "y".into())]], vector: false };
        assert!(matches!(book.answered(&s, &[], "dev", &overlapping), Step::Malformed));
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
        match book.answered(&s, &[], "dev", &DigestReply { ask: id, round: 0, groups: Vec::new(), vector: true }) {
            Step::Again(next) => assert!(vector_of(&next).is_some_and(|v| !v.is_empty())),
            _ => panic!("no vector ask"),
        }
    }
}
