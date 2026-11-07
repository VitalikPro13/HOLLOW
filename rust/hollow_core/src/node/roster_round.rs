//! When a roster trade may move a server's fold (DEVICE_PROOF_DESIGN section 9, H4), and
//! the roster asks an op from a device we do not count earns.
//!
//! One withholding answerer must not keep a replica on a stale view: a rebuild a roster
//! ingest triggers waits for finished rounds with two distinct member identities or 10 s,
//! and one that ran on the timeout with fewer runs again when a second identity answers.

use std::collections::{BTreeSet, HashMap};
use std::time::{Duration, Instant};

/// How long a rebuild waits for a second identity.
pub(crate) const WAIT: Duration = Duration::from_secs(10);
/// Identities whose finished rounds let a rebuild run at once.
pub(crate) const IDENTITIES: usize = 2;
/// One roster ask per (server, master) in this long.
pub(crate) const UNCOUNTED_EVERY: Duration = Duration::from_secs(10 * 60);
const UNCOUNTED_MAX: usize = 4096;
const SERVERS_MAX: usize = 4096;
/// How long a rebuild that ran short waits for a second identity to run it again.
pub(crate) const RERUN_FOR: Duration = Duration::from_secs(10 * 60);

#[derive(Debug)]
struct Pending {
    since: Instant,
    answered: BTreeSet<String>,
    /// Ran on the timeout with fewer than two identities: runs once more on the second.
    ran_short: bool,
}

/// A roster asked for a member whose post or change the post gate refused.
#[derive(Debug)]
struct PostAsk {
    at: Instant,
    /// The one device asked: only its answer may bring a roster outside the authority set.
    device: String,
    /// Channels to catch up once the roster lands.
    channels: BTreeSet<String>,
}

/// Channels one post ask catches up.
const POST_CHANNELS_MAX: usize = 16;
/// A landed roster's catch-up waits this long: a responder answers the same ask from one
/// device once per 2 s, and a join's own catch-up names the same watermark.
pub(crate) const CATCH_UP_AFTER: Duration = Duration::from_secs(3);

#[derive(Default)]
pub(crate) struct RosterRound {
    pending: HashMap<String, Pending>,
    asked: HashMap<(String, String), Instant>,
    posts: HashMap<(String, String), PostAsk>,
    /// (due, server, channel, device): history catch-ups a landed post roster owes.
    catch_ups: Vec<(Instant, String, String, String)>,
}

impl RosterRound {
    /// A roster ingest changed the view of a master in `server`'s authority set. A change
    /// after a short run opens a fresh round: it waits on its own answers.
    pub(crate) fn changed(&mut self, server: &str, now: Instant) {
        if self.pending.len() >= SERVERS_MAX && !self.pending.contains_key(server) {
            // Rounds that already ran short give way first, the oldest of them.
            let oldest = self.pending.iter().filter(|(_, p)| p.ran_short).min_by_key(|(_, p)| p.since).map(|(s, _)| s.clone());
            match oldest {
                Some(s) => {
                    self.pending.remove(&s);
                }
                None => return,
            }
        }
        let fresh = || Pending { since: now, answered: BTreeSet::new(), ran_short: false };
        let p = self.pending.entry(server.to_string()).or_insert_with(fresh);
        if p.ran_short {
            *p = fresh();
        }
    }

    /// A digest round with `identity` for `server` finished.
    pub(crate) fn answered(&mut self, server: &str, identity: &str) {
        if let Some(p) = self.pending.get_mut(server) {
            p.answered.insert(identity.to_string());
        }
    }

    /// Servers whose rebuild is due now: two identities answered, or the wait ran out
    /// (once), or a short run's second identity arrived. A short run stops waiting for
    /// that identity after [`RERUN_FOR`].
    pub(crate) fn due(&mut self, now: Instant) -> Vec<String> {
        let mut out = Vec::new();
        self.pending.retain(|server, p| {
            let enough = p.answered.len() >= IDENTITIES;
            if enough {
                out.push(server.clone());
                return false;
            }
            let waited = now.saturating_duration_since(p.since);
            if p.ran_short {
                return waited < RERUN_FOR;
            }
            if waited >= WAIT {
                out.push(server.clone());
                p.ran_short = true;
            }
            true
        });
        out.sort();
        out
    }

    /// A live op from `master` reads `Missing` or `Uncounted` (section 9): the devices to
    /// ask for its roster, the carrier and one other member, once per (server, master)
    /// per [`UNCOUNTED_EVERY`].
    pub(crate) fn uncounted_seen(
        &mut self,
        server: &str,
        master: &str,
        carrier: &str,
        other: Option<&str>,
        now: Instant,
    ) -> Vec<(String, super::types::HavenMessage)> {
        self.uncounted_targets(server, master, carrier, other, now)
            .into_iter()
            .map(|d| (d, super::op_sync::roster_ask(server, None, vec![master.to_string()])))
            .collect()
    }

    /// A post or change of `master` in `channel` was refused with no roster of `master`
    /// held: the ask for it, of `device` (a member of another identity), once per
    /// (server, master) per [`UNCOUNTED_EVERY`]. Later refusals add their channel.
    pub(crate) fn post_refused(
        &mut self,
        server: &str,
        master: &str,
        channel: &str,
        device: &str,
        now: Instant,
    ) -> Option<(String, super::types::HavenMessage)> {
        let key = (server.to_string(), master.to_string());
        if let Some(p) = self.posts.get_mut(&key).filter(|p| now.saturating_duration_since(p.at) < UNCOUNTED_EVERY) {
            if p.channels.len() < POST_CHANNELS_MAX {
                p.channels.insert(channel.to_string());
            }
            return None;
        }
        if self.posts.len() >= UNCOUNTED_MAX && !self.posts.contains_key(&key) {
            self.posts.retain(|_, p| now.saturating_duration_since(p.at) < UNCOUNTED_EVERY);
            if self.posts.len() >= UNCOUNTED_MAX {
                return None;
            }
        }
        let channels = BTreeSet::from([channel.to_string()]);
        self.posts.insert(key, PostAsk { at: now, device: device.to_string(), channels });
        Some((device.to_string(), super::op_sync::roster_ask(server, None, vec![master.to_string()])))
    }

    /// Whether `device` is the one we asked for `master`'s roster for a refused post.
    pub(crate) fn post_asked_of(&self, server: &str, master: &str, device: &str, now: Instant) -> bool {
        self.posts
            .get(&(server.to_string(), master.to_string()))
            .is_some_and(|p| p.device == device && now.saturating_duration_since(p.at) < UNCOUNTED_EVERY)
    }

    /// `master`'s roster we asked for a refused post landed: its channels are caught up
    /// again from the device that answered, after [`CATCH_UP_AFTER`].
    pub(crate) fn post_roster_landed(&mut self, server: &str, master: &str, now: Instant) {
        if let Some(p) = self.posts.remove(&(server.to_string(), master.to_string())) {
            let due = now + CATCH_UP_AFTER;
            self.catch_ups.extend(p.channels.into_iter().map(|c| (due, server.to_string(), c, p.device.clone())));
        }
    }

    /// The catch-ups [`Self::post_roster_landed`] queued that are due.
    pub(crate) fn take_catch_ups(&mut self, now: Instant) -> Vec<(String, String, String)> {
        let (due, later): (Vec<_>, Vec<_>) = std::mem::take(&mut self.catch_ups).into_iter().partition(|c| c.0 <= now);
        self.catch_ups = later;
        due.into_iter().map(|(_, s, c, d)| (s, c, d)).collect()
    }

    fn uncounted_targets(&mut self, server: &str, master: &str, carrier: &str, other: Option<&str>, now: Instant) -> Vec<String> {
        let key = (server.to_string(), master.to_string());
        if self.asked.get(&key).is_some_and(|at| now.saturating_duration_since(*at) < UNCOUNTED_EVERY) {
            return Vec::new();
        }
        if self.asked.len() >= UNCOUNTED_MAX {
            self.asked.retain(|_, at| now.saturating_duration_since(*at) < UNCOUNTED_EVERY);
            if self.asked.len() >= UNCOUNTED_MAX {
                return Vec::new();
            }
        }
        self.asked.insert(key, now);
        let mut out = vec![carrier.to_string()];
        out.extend(other.filter(|o| *o != carrier).map(str::to_string));
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_timed_out_rebuild_runs_again_when_a_second_identity_answers() {
        let t0 = Instant::now();
        let mut r = RosterRound::default();
        r.changed("s", t0);
        r.answered("s", "a");
        assert!(r.due(t0 + WAIT / 2).is_empty(), "one identity let the rebuild run");
        assert_eq!(r.due(t0 + WAIT), vec!["s".to_string()], "the wait did not end it");
        assert!(r.due(t0 + WAIT * 3).is_empty(), "the timeout ran twice");
        r.answered("s", "a");
        assert!(r.due(t0 + WAIT * 3).is_empty(), "the same identity counted twice");
        r.answered("s", "b");
        assert_eq!(r.due(t0 + WAIT * 3), vec!["s".to_string()], "the second identity did not re-run it");
        assert!(r.due(t0 + WAIT * 9).is_empty(), "a finished round stayed open");
    }

    #[test]
    fn two_identities_run_the_rebuild_before_the_wait() {
        let t0 = Instant::now();
        let mut r = RosterRound::default();
        r.answered("s", "a");
        r.changed("s", t0);
        r.answered("s", "a");
        r.answered("s", "b");
        assert_eq!(r.due(t0), vec!["s".to_string()]);
    }

    #[test]
    fn an_uncounted_author_earns_one_roster_ask_per_ten_minutes() {
        let t0 = Instant::now();
        let mut r = RosterRound::default();
        let to = |v: Vec<(String, super::super::types::HavenMessage)>| v.into_iter().map(|(d, _)| d).collect::<Vec<_>>();
        let first = r.uncounted_seen("s", "m", "c", Some("o"), t0);
        assert!(first.iter().all(|(_, m)| matches!(m, super::super::types::HavenMessage::SyncRequest { x: Some(x), .. } if x.rosters_wanted == ["m"])));
        assert_eq!(to(first), vec!["c".to_string(), "o".to_string()]);
        assert!(r.uncounted_seen("s", "m", "c2", Some("o"), t0 + UNCOUNTED_EVERY / 2).is_empty());
        assert_eq!(to(r.uncounted_seen("s2", "m", "c", Some("c"), t0)), vec!["c".to_string()], "per server");
        assert_eq!(r.uncounted_seen("s", "m", "c", None, t0 + UNCOUNTED_EVERY).len(), 1);
    }
    /// REVIEW probe: after one rebuild ran on the timeout, a later roster change in a
    /// server where no second identity ever answers (a two-member server) must still
    /// rebuild once its wait ends.
    #[test]
    fn review_a_change_after_a_short_run_still_rebuilds_on_its_own_wait() {
        let t0 = Instant::now();
        let mut r = RosterRound::default();
        r.changed("s", t0);
        r.answered("s", "a");
        assert_eq!(r.due(t0 + WAIT), vec!["s".to_string()], "precondition: the first change ran on the timeout");
        let t1 = t0 + WAIT * 6;
        r.changed("s", t1);
        r.answered("s", "a");
        assert_eq!(r.due(t1 + WAIT), vec!["s".to_string()], "a second roster change never marked the server for a rebuild");
    }

    #[test]
    fn finished_rounds_leave_and_a_full_table_still_tracks_a_new_change() {
        let t0 = Instant::now();
        let mut r = RosterRound::default();
        for i in 0..SERVERS_MAX {
            r.changed(&format!("s{i}"), t0);
        }
        assert_eq!(r.due(t0 + WAIT).len(), SERVERS_MAX, "precondition: every round ran short");
        r.changed("new", t0 + WAIT);
        assert!(r.pending.contains_key("new"), "a full table of finished rounds tracked nothing new");
        assert_eq!(r.due(t0 + WAIT * 2), vec!["new".to_string()]);
        r.due(t0 + RERUN_FOR + WAIT * 2);
        assert!(r.pending.is_empty(), "short runs waited forever for a second identity");
    }

    /// Lead decision 1: one roster ask per (server, member) per [`UNCOUNTED_EVERY`], only
    /// the device asked may bring it, and its landing catches up each refused channel once.
    #[test]
    fn lead_c_a_refused_posts_roster_is_asked_once_and_lands_once() {
        let t0 = Instant::now();
        let mut r = RosterRound::default();
        let ask = r.post_refused("s", "m", "c1", "dev-j", t0).expect("the first refusal asks");
        assert_eq!(ask.0, "dev-j");
        assert!(r.post_refused("s", "m", "c2", "dev-k", t0 + WAIT).is_none(), "a second refusal asked again within the pace");
        assert!(r.post_asked_of("s", "m", "dev-j", t0 + WAIT), "the device asked");
        assert!(!r.post_asked_of("s", "m", "dev-k", t0 + WAIT), "a device never asked may not bring the roster");
        assert!(!r.post_asked_of("s", "other", "dev-j", t0), "another member was never asked");
        assert!(!r.post_asked_of("s", "m", "dev-j", t0 + UNCOUNTED_EVERY), "an ask stands forever");
        r.post_roster_landed("s", "m", t0);
        assert!(r.take_catch_ups(t0).is_empty(), "a catch-up left before a responder answers the same ask again");
        let mut owed = r.take_catch_ups(t0 + CATCH_UP_AFTER);
        owed.sort();
        assert_eq!(owed, vec![("s".into(), "c1".into(), "dev-j".into()), ("s".into(), "c2".into(), "dev-j".into())]);
        r.post_roster_landed("s", "m", t0);
        assert!(r.take_catch_ups(t0 + CATCH_UP_AFTER).is_empty(), "a landing caught up twice");
        assert!(!r.post_asked_of("s", "m", "dev-j", t0 + WAIT), "a landed ask still admits rosters");
        assert!(r.post_refused("s", "m", "c1", "dev-j", t0 + UNCOUNTED_EVERY).is_some(), "the pace never lets a new ask out");
    }
}
