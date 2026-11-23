//! A retire is minted from a converged view (DEVICE_PROOF_DESIGN 8.2 step 1, M4, H4): the
//! remover first asks member identities of every server it holds past the cut and waits
//! until two of them (or every one it could ask) ended a digest round, or 10 s. A round
//! that ran on the timeout mints again when a second identity's round ends later. A lost
//! or stolen removal waits the same way (8.3 step 1), its asks naming the restore point R
//! as their base, and never mints again late: its settling is written once.

use std::time::{Duration, Instant};

/// H4: the longest a retire waits for its round.
pub(crate) const ROUND_WAIT: Duration = Duration::from_secs(10);
/// Member identities a round waits for per server.
pub(crate) const IDENTITIES: usize = 2;
/// Identities asked per server, one more than waited for, so one slow answerer does
/// not hold the removal to the timeout.
pub(crate) const ASKED: usize = IDENTITIES + 1;
/// A retire that ran on the timeout mints again for a late second identity this long.
const LATE_FOR: Duration = Duration::from_secs(600);
/// Removals waiting at once: each is a person's own action on this device.
const OPEN_MAX: usize = 64;
const LATE_MAX: usize = 256;
/// A removal held when the app quit starts its round again this long after the next
/// start, once the rooms are joined (lead decision 11-05: nobody removes a device twice).
pub(crate) const RESUME_AFTER: Duration = Duration::from_secs(5);
/// `app_settings` prefix of a held removal; this device's own, never in a link snapshot.
pub(crate) const HELD_PREFIX: &str = "retire_held:";

/// A removal the round holds back: what `NodeCommand::RevokeDevice` carried.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Removal {
    pub(crate) device: String,
    pub(crate) with_dependents: bool,
    /// Lost or stolen since this time (ms), else a retire.
    pub(crate) lost_t_ms: Option<i64>,
}

impl Removal {
    pub(crate) fn mode(&self) -> super::roster_book::RemoveMode {
        super::roster_book::RemoveMode::from_lost_since(self.lost_t_ms)
    }
}

#[derive(Debug)]
struct Wait {
    server: String,
    need: usize,
}

#[derive(Debug)]
struct Round {
    removal: Removal,
    waits: Vec<Wait>,
    started: Instant,
}

#[derive(Debug)]
struct Late {
    server: String,
    device: String,
    started: Instant,
    until: Instant,
}

/// What the event loop does next.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum RetireStep {
    /// The round ended: mint the retires of `device` and remove it.
    Remove(Removal),
    /// A removal held when the app quit: start its round again.
    Restart(Removal),
    /// A second identity's round ended after a timed-out retire: mint again on `server`.
    Again { server: String, device: String },
}

#[derive(Debug, Default)]
pub(crate) struct RetireRounds {
    open: Vec<Round>,
    late: Vec<Late>,
    /// Removals whose round ended and that the event loop runs next.
    released: Vec<String>,
    /// Released removals the event loop could not queue: due again at the next tick.
    ready: Vec<Removal>,
    /// Removals held when the app last quit, and when they start again.
    resumed: Vec<Removal>,
    resume_at: Option<Instant>,
}

/// Devices a round was started for in this process. Tests only.
#[cfg(test)]
static STARTED: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

/// Whether a retire round was started for `device`. Tests only.
#[cfg(test)]
pub(crate) fn round_started_for_test(device: &str) -> bool {
    STARTED.lock().unwrap_or_else(|e| e.into_inner()).iter().any(|d| d == device)
}

/// Note `removal` as held, so a restart finishes it.
pub(crate) fn save_held(store: &crate::storage::MessageStore, removal: &Removal) {
    let deps = if removal.with_dependents { "deps" } else { "one" };
    let value = match removal.lost_t_ms {
        Some(t) => format!("{deps};lost={t}"),
        None => deps.to_string(),
    };
    let _ = store.save_setting(&format!("{HELD_PREFIX}{}", removal.device), &value);
}

/// The removal of `device` was signed or given up: nothing to finish after a restart.
pub(crate) fn clear_held(store: &crate::storage::MessageStore, device: &str) {
    let _ = store.delete_setting(&format!("{HELD_PREFIX}{device}"));
}

/// The removals held when the app last quit.
pub(crate) fn load_held(store: &crate::storage::MessageStore) -> Vec<Removal> {
    let rows = store.load_settings_with_prefix(HELD_PREFIX).unwrap_or_default();
    rows.into_iter()
        .filter_map(|(k, v)| {
            let device = k.strip_prefix(HELD_PREFIX).filter(|d| !d.is_empty())?;
            let (deps, lost) = v.split_once(";lost=").map_or((v.as_str(), None), |(d, t)| (d, Some(t)));
            let lost_t_ms = match lost {
                Some(t) => Some(t.parse::<i64>().ok()?.max(0)),
                None => None,
            };
            Some(Removal { device: device.to_string(), with_dependents: deps == "deps", lost_t_ms })
        })
        .take(OPEN_MAX)
        .collect()
}

impl RetireRounds {
    /// Removals held when the app last quit start their rounds again `RESUME_AFTER` from `now`.
    pub(crate) fn resume(&mut self, held: Vec<Removal>, now: Instant) {
        if !held.is_empty() {
            self.resumed.extend(held);
            self.resume_at.get_or_insert(now + RESUME_AFTER);
        }
    }

    /// Hold `removal` until its round ends; `asked` lists, per server, how many member
    /// identities other than ours were asked. The removal comes back when nothing waits.
    pub(crate) fn start(&mut self, removal: Removal, asked: Vec<(String, usize)>, now: Instant) -> Option<Removal> {
        #[cfg(test)]
        STARTED.lock().unwrap_or_else(|e| e.into_inner()).push(removal.device.clone());
        if self.open.iter().any(|r| r.removal.device == removal.device) {
            return None;
        }
        let waits: Vec<Wait> =
            asked.into_iter().filter(|(_, n)| *n > 0).map(|(server, n)| Wait { server, need: n.min(IDENTITIES) }).collect();
        if waits.is_empty() || self.open.len() >= OPEN_MAX {
            return Some(removal);
        }
        self.open.push(Round { removal, waits, started: now });
        None
    }

    /// Whether this `RevokeDevice` of `device` is one the round released.
    pub(crate) fn take_released(&mut self, device: &str) -> bool {
        let before = self.released.len();
        self.released.retain(|d| d != device);
        self.released.len() != before
    }

    /// A retire of `device` waiting or minting late gives way to its lost-or-stolen removal.
    pub(crate) fn cancel(&mut self, device: &str) {
        self.open.retain(|r| r.removal.device != device);
        self.resumed.retain(|r| r.device != device);
        self.late.retain(|l| l.device != device);
    }

    /// The steps due now. `heard(server, since)` counts the member identities other than
    /// ours whose digest round on `server` ended at or after `since`.
    pub(crate) fn due(&mut self, now: Instant, heard: &dyn Fn(&str, Instant) -> usize) -> Vec<RetireStep> {
        let mut out: Vec<RetireStep> = self.ready.drain(..).map(RetireStep::Remove).collect();
        if self.resume_at.is_some_and(|at| now >= at) {
            self.resume_at = None;
            out.extend(self.resumed.drain(..).map(RetireStep::Restart));
        }
        self.late.retain(|l| {
            if now >= l.until {
                return false;
            }
            if heard(&l.server, l.started) < IDENTITIES {
                return true;
            }
            out.push(RetireStep::Again { server: l.server.clone(), device: l.device.clone() });
            false
        });
        let mut late = Vec::new();
        self.open.retain(|r| {
            let timed_out = now.saturating_duration_since(r.started) >= ROUND_WAIT;
            if !timed_out && !r.waits.iter().all(|w| heard(&w.server, r.started) >= w.need) {
                return true;
            }
            for w in r.waits.iter().filter(|w| r.removal.lost_t_ms.is_none() && heard(&w.server, r.started) < IDENTITIES) {
                late.push(Late { server: w.server.clone(), device: r.removal.device.clone(), started: r.started, until: now + LATE_FOR });
            }
            out.push(RetireStep::Remove(r.removal.clone()));
            false
        });
        self.late.extend(late);
        if self.late.len() > LATE_MAX {
            let extra = self.late.len() - LATE_MAX;
            self.late.drain(..extra);
        }
        for step in &out {
            if let RetireStep::Remove(r) = step {
                self.released.push(r.device.clone());
            }
        }
        out
    }

    /// A released removal the event loop could not queue: it is due at the next tick.
    pub(crate) fn requeue(&mut self, removal: Removal) {
        let _ = self.take_released(&removal.device);
        self.ready.push(removal);
    }

    /// Every held removal, released now (the app is shutting down).
    pub(crate) fn release_all(&mut self) -> Vec<Removal> {
        let all: Vec<Removal> = self.open.drain(..).map(|r| r.removal).collect();
        self.released.extend(all.iter().map(|r| r.device.clone()));
        all
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::collections::HashMap;

    fn removal(d: &str) -> Removal {
        Removal { device: d.into(), with_dependents: false, lost_t_ms: None }
    }

    /// (server -> identities heard, each with when its round ended).
    struct Heard(RefCell<HashMap<String, Vec<Instant>>>);
    impl Heard {
        fn new() -> Self {
            Self(RefCell::new(HashMap::new()))
        }
        fn ended(&self, server: &str, at: Instant) {
            self.0.borrow_mut().entry(server.into()).or_default().push(at);
        }
        fn count(&self, server: &str, since: Instant) -> usize {
            self.0.borrow().get(server).map(|v| v.iter().filter(|t| **t >= since).count()).unwrap_or(0)
        }
    }

    #[test]
    fn a_retire_waits_for_two_identities_on_every_server() {
        let t0 = Instant::now();
        let heard = Heard::new();
        let mut rounds = RetireRounds::default();
        assert_eq!(rounds.start(removal("d"), vec![("s1".into(), 3), ("s2".into(), 2)], t0), None, "held");
        heard.ended("s1", t0 + Duration::from_millis(100));
        heard.ended("s1", t0 + Duration::from_millis(200));
        heard.ended("s2", t0 + Duration::from_millis(300));
        assert!(rounds.due(t0 + Duration::from_secs(1), &|s, at| heard.count(s, at)).is_empty(), "one server still waits");
        assert!(!rounds.take_released("d"), "nothing released yet");
        heard.ended("s2", t0 + Duration::from_millis(1500));
        let steps = rounds.due(t0 + Duration::from_secs(2), &|s, at| heard.count(s, at));
        assert_eq!(steps, vec![RetireStep::Remove(removal("d"))]);
        assert!(rounds.take_released("d") && !rounds.take_released("d"), "released once");
        assert!(rounds.due(t0 + Duration::from_secs(700), &|s, at| heard.count(s, at)).is_empty(), "nothing late");
    }

    #[test]
    fn a_round_counts_only_rounds_that_ended_after_it_started() {
        let t0 = Instant::now();
        let heard = Heard::new();
        heard.ended("s", t0);
        heard.ended("s", t0);
        let start = t0 + Duration::from_secs(1);
        let mut rounds = RetireRounds::default();
        assert_eq!(rounds.start(removal("d"), vec![("s".into(), 2)], start), None);
        assert!(rounds.due(start + Duration::from_secs(2), &|s, at| heard.count(s, at)).is_empty(), "earlier rounds prove nothing about now");
    }

    #[test]
    fn a_server_with_one_identity_to_ask_waits_for_that_one() {
        let t0 = Instant::now();
        let heard = Heard::new();
        let mut rounds = RetireRounds::default();
        assert_eq!(rounds.start(removal("d"), vec![("s".into(), 1)], t0), None);
        assert!(rounds.due(t0 + Duration::from_secs(1), &|s, at| heard.count(s, at)).is_empty());
        heard.ended("s", t0 + Duration::from_secs(1));
        assert_eq!(rounds.due(t0 + Duration::from_secs(2), &|s, at| heard.count(s, at)).len(), 1);
    }

    #[test]
    fn nothing_to_ask_removes_at_once() {
        let mut rounds = RetireRounds::default();
        let now = Instant::now();
        assert_eq!(rounds.start(removal("d"), Vec::new(), now), Some(removal("d")));
        assert_eq!(rounds.start(removal("e"), vec![("s".into(), 0)], now), Some(removal("e")));
        assert!(!rounds.take_released("d"), "a removal that never waited needs no release");
    }

    #[test]
    fn a_timed_out_round_removes_and_mints_again_for_a_late_second_identity() {
        let t0 = Instant::now();
        let heard = Heard::new();
        let mut rounds = RetireRounds::default();
        assert_eq!(rounds.start(removal("d"), vec![("s".into(), 3)], t0), None);
        heard.ended("s", t0 + Duration::from_secs(1));
        assert!(rounds.due(t0 + ROUND_WAIT - Duration::from_millis(1), &|s, at| heard.count(s, at)).is_empty(), "within the bound it waits");
        assert_eq!(rounds.due(t0 + ROUND_WAIT, &|s, at| heard.count(s, at)), vec![RetireStep::Remove(removal("d"))], "the bound releases it");
        assert!(rounds.due(t0 + ROUND_WAIT + Duration::from_secs(1), &|s, at| heard.count(s, at)).is_empty(), "one identity is not two");
        heard.ended("s", t0 + Duration::from_secs(30));
        assert_eq!(
            rounds.due(t0 + Duration::from_secs(31), &|s, at| heard.count(s, at)),
            vec![RetireStep::Again { server: "s".into(), device: "d".into() }],
            "the second identity's round mints again",
        );
        assert!(rounds.due(t0 + Duration::from_secs(32), &|s, at| heard.count(s, at)).is_empty(), "once");
    }

    #[test]
    fn a_late_second_identity_counts_only_within_its_window() {
        let t0 = Instant::now();
        let heard = Heard::new();
        let mut rounds = RetireRounds::default();
        rounds.start(removal("d"), vec![("s".into(), 2)], t0);
        assert_eq!(rounds.due(t0 + ROUND_WAIT, &|s, at| heard.count(s, at)).len(), 1);
        heard.ended("s", t0 + ROUND_WAIT + LATE_FOR + Duration::from_secs(1));
        heard.ended("s", t0 + ROUND_WAIT + LATE_FOR + Duration::from_secs(1));
        assert!(rounds.due(t0 + ROUND_WAIT + LATE_FOR + Duration::from_secs(2), &|s, at| heard.count(s, at)).is_empty());
    }

    #[test]
    fn a_lost_removal_cancels_the_retire_and_a_repeat_waits_once() {
        let t0 = Instant::now();
        let mut rounds = RetireRounds::default();
        assert_eq!(rounds.start(removal("d"), vec![("s".into(), 2)], t0), None);
        assert_eq!(rounds.start(removal("d"), vec![("s".into(), 2)], t0), None, "a repeat joins the held removal");
        rounds.cancel("d");
        assert!(rounds.due(t0 + ROUND_WAIT, &|_, _| 0).is_empty(), "a cancelled retire mints nothing");
    }

    #[test]
    fn a_removal_the_loop_could_not_queue_is_due_again() {
        let t0 = Instant::now();
        let mut rounds = RetireRounds::default();
        rounds.start(removal("d"), vec![("s".into(), 2)], t0);
        assert_eq!(rounds.due(t0 + ROUND_WAIT, &|_, _| 0).len(), 1);
        rounds.requeue(removal("d"));
        assert!(!rounds.take_released("d"), "not released while it waits to be queued");
        let again = rounds.due(t0 + ROUND_WAIT + Duration::from_secs(2), &|_, _| 0);
        assert!(again.contains(&RetireStep::Remove(removal("d"))), "{again:?}");
        assert!(rounds.take_released("d"));
    }

    /// Section 8.3 step 1: a lost-or-stolen removal waits for its round as a retire does,
    /// keeps its T across a restart, and writes its settling once (no late re-mint).
    #[test]
    fn a_lost_removal_waits_for_its_round_keeps_its_t_and_never_mints_late() {
        let lost = Removal { device: "d".into(), with_dependents: false, lost_t_ms: Some(1_234) };
        let store = crate::storage::MessageStore::open(":memory:", &"ab".repeat(32)).expect("store");
        save_held(&store, &lost);
        assert_eq!(load_held(&store), vec![lost.clone()], "T survives the restart");
        assert_eq!(lost.mode(), super::super::roster_book::RemoveMode::Lost { t_ms: 1_234 });

        let t0 = Instant::now();
        let mut rounds = RetireRounds::default();
        assert!(rounds.start(lost.clone(), vec![("s".into(), 2)], t0).is_none(), "held for its round");
        assert!(rounds.due(t0 + Duration::from_secs(1), &|_, _| 1).is_empty(), "one identity is not enough");
        assert_eq!(rounds.due(t0 + ROUND_WAIT, &|_, _| 1), vec![RetireStep::Remove(lost.clone())], "the bound releases it");
        assert!(rounds.due(t0 + ROUND_WAIT + Duration::from_secs(5), &|_, _| 2).is_empty(), "a late identity mints nothing for it");
    }

    #[test]
    fn shutdown_releases_every_held_removal() {
        let t0 = Instant::now();
        let mut rounds = RetireRounds::default();
        rounds.start(removal("d"), vec![("s".into(), 2)], t0);
        assert_eq!(rounds.release_all(), vec![removal("d")]);
        assert!(rounds.take_released("d"));
        assert!(rounds.due(t0 + ROUND_WAIT, &|_, _| 0).is_empty());
    }

    /// Lead decision 11-05: what was held at quit is saved, restarts after the resume
    /// delay, and a lost-or-stolen removal of the same device cancels it.
    #[test]
    fn a_removal_held_at_quit_restarts_after_the_delay_unless_lost() {
        let store = crate::storage::MessageStore::open(":memory:", &"ab".repeat(32)).expect("store");
        save_held(&store, &removal("d"));
        save_held(&store, &Removal { device: "e".into(), with_dependents: true, lost_t_ms: None });
        let held = load_held(&store);
        assert_eq!(held, vec![removal("d"), Removal { device: "e".into(), with_dependents: true, lost_t_ms: None }]);
        let t0 = Instant::now();
        let mut rounds = RetireRounds::default();
        rounds.resume(held, t0);
        assert!(rounds.due(t0 + RESUME_AFTER - Duration::from_millis(1), &|_, _| 0).is_empty(), "the rooms come first");
        rounds.cancel("e");
        assert_eq!(rounds.due(t0 + RESUME_AFTER, &|_, _| 0), vec![RetireStep::Restart(removal("d"))]);
        assert!(rounds.due(t0 + RESUME_AFTER * 2, &|_, _| 0).is_empty(), "once");
        clear_held(&store, "d");
        clear_held(&store, "e");
        assert!(load_held(&store).is_empty());
    }
}
