//! One call at a time per IDENTITY: which of a friend's devices an outgoing call
//! rang and which one took it, and what this device and its siblings are in.
//!
//! An invite rings every online device of the friend; the first accept wins and
//! every later one is refused, so a call never gets two peer connections.

use std::collections::{BTreeSet, HashMap};
use std::time::{Duration, Instant};

use super::types::CallPresence;

/// A ring nobody took is forgotten after this; a call that was answered lives
/// until either end hangs up.
const UNANSWERED_TTL: Duration = Duration::from_secs(90);

/// Calls this device dials at once. Far above real use; bounds a runaway caller.
const MAX_RINGS: usize = 16;

/// Longest presence field a sibling may hand us.
const MAX_FIELD: usize = 128;

struct Ring {
    master: String,
    rung: BTreeSet<String>,
    answered: Option<String>,
    at: Instant,
}

/// What an accept from one of the rung devices decides.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum AcceptVerdict {
    /// The first accept: these other devices are told to stop ringing.
    Won { others: Vec<String> },
    /// The device that already won, again.
    Again,
    /// Another device took the call first; this one is told so and dropped.
    Late,
    /// Not a ring of ours.
    Unknown,
}

/// What a decline, busy or hang-up from a callee device decides.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum EndVerdict {
    /// It ends the call; these other rung devices still ring and are told.
    Ends { others: Vec<String> },
    /// A device that did not take the call has no say over it.
    Ignored,
    /// Not a ring of ours.
    Unknown,
}

#[derive(Default)]
pub(crate) struct CallBook {
    rings: HashMap<String, Ring>,
    /// Calls that rang us: the caller's device, which every answer goes back to
    /// (the UI addresses the caller by master, and the caller may have several).
    incoming: HashMap<String, (String, Instant)>,
    own: Option<CallPresence>,
    siblings: HashMap<String, CallPresence>,
}

impl CallBook {
    fn prune(&mut self) {
        self.rings
            .retain(|_, r| r.answered.is_some() || r.at.elapsed() < UNANSWERED_TTL);
    }

    /// `device` rang us for `call_id`.
    pub(crate) fn note_incoming(&mut self, call_id: &str, device: &str) {
        if self.incoming.len() >= MAX_RINGS
            && let Some(oldest) = self.incoming.iter().min_by_key(|(_, (_, at))| *at).map(|(k, _)| k.clone())
        {
            self.incoming.remove(&oldest);
        }
        self.incoming.insert(call_id.to_string(), (device.to_string(), Instant::now()));
    }

    /// The device that rang us for `call_id`.
    pub(crate) fn caller_device(&self, call_id: &str) -> Option<&str> {
        self.incoming.get(call_id).map(|(d, _)| d.as_str())
    }

    pub(crate) fn forget_incoming(&mut self, call_id: &str) {
        self.incoming.remove(call_id);
    }

    /// An invite to `master` went to `devices`.
    pub(crate) fn start_ring(&mut self, call_id: &str, master: &str, devices: &[String]) {
        self.prune();
        if self.rings.len() >= MAX_RINGS
            && let Some(oldest) = self.rings.iter().min_by_key(|(_, r)| r.at).map(|(k, _)| k.clone())
        {
            self.rings.remove(&oldest);
        }
        self.rings.insert(
            call_id.to_string(),
            Ring { master: master.to_string(), rung: devices.iter().cloned().collect(), answered: None, at: Instant::now() },
        );
    }

    /// Where a signal of ours for `call_id` goes once the call was answered.
    pub(crate) fn answered_device(&self, call_id: &str) -> Option<&str> {
        self.rings.get(call_id).and_then(|r| r.answered.as_deref())
    }

    /// The answered device of our only live call with `master`, for a signal that
    /// names no call id.
    pub(crate) fn answered_device_for_master(&self, master: &str) -> Option<&str> {
        let mut hits = self.rings.values().filter(|r| r.master == master).filter_map(|r| r.answered.as_deref());
        match (hits.next(), hits.next()) {
            (Some(d), None) => Some(d),
            _ => None,
        }
    }

    /// Every device a still-unanswered ring reached, for our hang-up.
    pub(crate) fn rung_devices(&self, call_id: &str) -> Vec<String> {
        self.rings.get(call_id).map(|r| r.rung.iter().cloned().collect()).unwrap_or_default()
    }

    pub(crate) fn is_ring(&self, call_id: &str) -> bool {
        self.rings.contains_key(call_id)
    }

    pub(crate) fn accept(&mut self, call_id: &str, device: &str) -> AcceptVerdict {
        let Some(ring) = self.rings.get_mut(call_id) else { return AcceptVerdict::Unknown };
        match ring.answered.as_deref() {
            Some(d) if d == device => AcceptVerdict::Again,
            Some(_) => AcceptVerdict::Late,
            None if !ring.rung.contains(device) => AcceptVerdict::Late,
            None => {
                ring.answered = Some(device.to_string());
                AcceptVerdict::Won { others: ring.rung.iter().filter(|d| *d != device).cloned().collect() }
            }
        }
    }

    /// A decline, busy or hang-up from `device`.
    pub(crate) fn ended_by(&mut self, call_id: &str, device: &str) -> EndVerdict {
        let Some(ring) = self.rings.get(call_id) else { return EndVerdict::Unknown };
        let verdict = match ring.answered.as_deref() {
            Some(d) if d != device => return EndVerdict::Ignored,
            Some(_) => EndVerdict::Ends { others: Vec::new() },
            None if !ring.rung.contains(device) => return EndVerdict::Ignored,
            None => EndVerdict::Ends { others: ring.rung.iter().filter(|d| *d != device).cloned().collect() },
        };
        self.rings.remove(call_id);
        verdict
    }

    /// Whether a signal from `device` about `call_id` belongs to the call: always,
    /// unless another device took it (ours to them) or rang it (theirs to us).
    pub(crate) fn is_call_device(&self, call_id: &str, device: &str) -> bool {
        self.rings
            .get(call_id)
            .and_then(|r| r.answered.as_deref())
            .is_none_or(|d| d == device)
            && self.caller_device(call_id).is_none_or(|d| d == device)
    }

    pub(crate) fn forget(&mut self, call_id: &str) {
        self.rings.remove(call_id);
    }

    pub(crate) fn set_own(&mut self, presence: Option<CallPresence>) -> bool {
        let presence = presence.and_then(clean_presence);
        if self.own == presence {
            return false;
        }
        self.own = presence;
        true
    }

    pub(crate) fn own(&self) -> Option<&CallPresence> {
        self.own.as_ref()
    }

    /// A sibling's report. Returns the presence to tell Dart about, when it changed.
    pub(crate) fn set_sibling(&mut self, device: &str, presence: Option<CallPresence>) -> Option<Option<CallPresence>> {
        let presence = presence.and_then(clean_presence);
        let changed = match &presence {
            Some(p) => self.siblings.insert(device.to_string(), p.clone()).as_ref() != Some(p),
            None => self.siblings.remove(device).is_some(),
        };
        changed.then_some(presence)
    }

    /// A sibling went offline: whatever it was in, it no longer answers for it.
    pub(crate) fn sibling_gone(&mut self, device: &str) -> bool {
        self.siblings.remove(device).is_some()
    }

    pub(crate) fn clear_siblings(&mut self) -> Vec<String> {
        self.siblings.drain().map(|(d, _)| d).collect()
    }

    /// What this device does with an invite from `caller_master`. A sibling in a
    /// DM call with someone else makes the identity busy. A sibling in a voice
    /// channel or a meeting rings there alone (answering leaves the room, #49), and
    /// a sibling dialling this same person settles the glare itself, so both leave
    /// this device silent. Our own DM call and voice channel are the call screen's.
    pub(crate) fn invite_verdict(&self, caller_master: &str) -> InviteVerdict {
        let dm_call_elsewhere = |p: &CallPresence| p.kind == "call" && p.with != caller_master;
        if self.siblings.values().any(dm_call_elsewhere) {
            InviteVerdict::Busy
        } else if !self.siblings.is_empty() {
            InviteVerdict::LeaveToSibling
        } else {
            InviteVerdict::Ring
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum InviteVerdict {
    Ring,
    Busy,
    LeaveToSibling,
}

fn clean_presence(p: CallPresence) -> Option<CallPresence> {
    let ok = matches!(p.kind.as_str(), "call" | "voice" | "meeting")
        && !p.with.is_empty()
        && p.with.len() <= MAX_FIELD
        && p.channel.len() <= MAX_FIELD;
    ok.then_some(p)
}

/// This build's device kind, as siblings show it.
pub(crate) fn own_device_kind() -> &'static str {
    if cfg!(any(target_os = "android", target_os = "ios")) { "phone" } else { "desktop" }
}

/// A kind another device reported, or "" for anything else.
pub(crate) fn device_kind(kind: &str) -> &'static str {
    match kind {
        "desktop" => "desktop",
        "phone" => "phone",
        _ => "",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn devs(names: &[&str]) -> Vec<String> {
        names.iter().map(|s| s.to_string()).collect()
    }

    fn presence(kind: &str, with: &str) -> CallPresence {
        CallPresence { kind: kind.into(), with: with.into(), channel: String::new(), started_ms: 0 }
    }

    #[test]
    fn the_first_accept_wins_and_every_later_one_is_late() {
        let mut book = CallBook::default();
        book.start_ring("c1", "friend", &devs(&["d1", "d2", "d3"]));
        assert_eq!(book.accept("c1", "d2"), AcceptVerdict::Won { others: devs(&["d1", "d3"]) });
        assert_eq!(book.accept("c1", "d2"), AcceptVerdict::Again);
        assert_eq!(book.accept("c1", "d1"), AcceptVerdict::Late);
        assert_eq!(book.answered_device("c1"), Some("d2"));
        assert!(book.is_call_device("c1", "d2"));
        assert!(!book.is_call_device("c1", "d3"), "a device that lost the race has no say in the call");
        assert_eq!(book.accept("other", "d1"), AcceptVerdict::Unknown);
    }

    #[test]
    fn a_device_that_was_never_rung_cannot_take_the_call() {
        let mut book = CallBook::default();
        book.start_ring("c1", "friend", &devs(&["d1"]));
        assert_eq!(book.accept("c1", "stranger"), AcceptVerdict::Late);
        assert_eq!(book.answered_device("c1"), None);
    }

    #[test]
    fn a_decline_before_anyone_answers_ends_it_for_every_device() {
        let mut book = CallBook::default();
        book.start_ring("c1", "friend", &devs(&["d1", "d2"]));
        assert_eq!(book.ended_by("c1", "d1"), EndVerdict::Ends { others: devs(&["d2"]) });
        assert!(!book.is_ring("c1"));
    }

    #[test]
    fn only_the_device_in_the_call_can_end_it() {
        let mut book = CallBook::default();
        book.start_ring("c1", "friend", &devs(&["d1", "d2"]));
        book.accept("c1", "d1");
        assert_eq!(book.ended_by("c1", "d2"), EndVerdict::Ignored);
        assert_eq!(book.ended_by("c1", "d1"), EndVerdict::Ends { others: Vec::new() });
        assert_eq!(book.ended_by("c1", "d1"), EndVerdict::Unknown);
    }

    #[test]
    fn an_answer_goes_back_to_the_device_that_rang() {
        let mut book = CallBook::default();
        book.note_incoming("c1", "caller-d2");
        assert_eq!(book.caller_device("c1"), Some("caller-d2"));
        assert!(book.is_call_device("c1", "caller-d2"));
        assert!(!book.is_call_device("c1", "caller-d1"), "the caller's sibling is not in this call");
        book.forget_incoming("c1");
        assert_eq!(book.caller_device("c1"), None);
    }

    #[test]
    fn only_a_sibling_in_a_dm_call_makes_the_identity_busy() {
        let mut book = CallBook::default();
        assert_eq!(book.invite_verdict("x"), InviteVerdict::Ring);
        book.set_sibling("s1", Some(presence("call", "x")));
        assert_eq!(book.invite_verdict("x"), InviteVerdict::LeaveToSibling, "glare is the callers' to settle");
        assert_eq!(book.invite_verdict("y"), InviteVerdict::Busy);
        book.set_sibling("s1", Some(presence("voice", "server")));
        assert_eq!(book.invite_verdict("x"), InviteVerdict::LeaveToSibling, "the device in the room rings alone");
        book.set_sibling("s1", None);
        book.set_own(Some(presence("voice", "server")));
        assert_eq!(book.invite_verdict("x"), InviteVerdict::Ring, "our own room rings with its warning");
        book.set_own(Some(presence("call", "y")));
        assert_eq!(book.invite_verdict("x"), InviteVerdict::Ring, "our own DM call is the call screen's to answer busy");
    }

    #[test]
    fn a_malformed_presence_is_nothing() {
        let mut book = CallBook::default();
        assert_eq!(book.set_sibling("s1", Some(presence("party", "x"))), None);
        assert_eq!(book.set_sibling("s1", Some(presence("call", ""))), None);
        assert_eq!(book.invite_verdict("y"), InviteVerdict::Ring);
        assert_eq!(book.set_sibling("s1", Some(presence("call", "x"))), Some(Some(presence("call", "x"))));
        assert_eq!(book.set_sibling("s1", Some(presence("call", "x"))), None, "an unchanged report is not news");
        assert!(book.sibling_gone("s1"));
        assert_eq!(book.invite_verdict("y"), InviteVerdict::Ring);
    }

    #[test]
    fn device_kinds_are_only_desktop_or_phone() {
        assert_eq!(device_kind("phone"), "phone");
        assert_eq!(device_kind("DESKTOP-OL94Q8K"), "");
        assert_eq!(device_kind("windows"), "");
    }
}
