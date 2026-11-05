//! Join asks a member left to another member to answer (HOL-SEC-192).
//!
//! A live ask reaches several members and only one answers. The others still need the
//! asker's roster once it is admitted, or its MLS add waits on a device they cannot
//! place, but an ask nobody admits must leave nothing behind: anyone holding an invite
//! link can seal one, and identities are free. So a member that steps aside holds the
//! ask's roster and card here, in RAM, and lands them only when the asker's admission
//! has folded into its own server state.

use std::cell::RefCell;
use std::collections::HashMap;
use std::time::{Duration, Instant};

use crate::identity::roster::Roster;

use super::types::SignedCard;

/// The most one held ask may weigh: an honest roster and card are a few KiB. An avatar
/// past it is dropped together with its card, since a card stored without the picture
/// it signs would wait on that picture.
pub(crate) const ENTRY_MAX_BYTES: usize = 32 * 1024;
/// The most held asks, and their total weight.
pub(crate) const MAX_HELD: usize = 128;
pub(crate) const MAX_HELD_BYTES: usize = 512 * 1024;
/// An admission lands within seconds of its ask; one that never does is forgotten.
pub(crate) const HOLD_FOR: Duration = Duration::from_secs(600);

/// The asker's card as its ask carried it: the avatar its hash signs, if any, and the
/// latest stamp the ask's frame allows.
pub(crate) struct HeldCard {
    pub card: SignedCard,
    pub avatar: Option<Vec<u8>>,
    pub ceiling: i64,
}

/// One ask's roster and card, delivered by `sender`, one of the asker's devices.
pub(crate) struct Held {
    pub server_id: String,
    pub sender: String,
    pub roster: Roster,
    pub card: Option<HeldCard>,
    bytes: usize,
    seq: u64,
    at: Instant,
}

/// What a server says of a held asker: admitted, not (yet), or the server is gone.
pub(crate) enum Standing {
    Admitted,
    Waiting,
    Gone,
}

#[derive(Default)]
pub(crate) struct JoinStash {
    held: HashMap<(String, String), Held>,
    seq: u64,
}

fn weight_of(roster: &Roster, card: Option<&HeldCard>) -> Option<usize> {
    let roster = serde_json::to_vec(roster).ok()?.len();
    let card = card.map_or(Some(0), |c| {
        serde_json::to_vec(&c.card).ok().map(|b| b.len() + c.avatar.as_ref().map_or(0, Vec::len))
    })?;
    Some(roster + card)
}

impl JoinStash {
    /// Hold `master`'s ask for `server_id`, replacing an earlier one of theirs there.
    /// Whether anything was held.
    pub(crate) fn hold(
        &mut self,
        server_id: &str,
        master: &str,
        sender: &str,
        roster: Roster,
        card: Option<HeldCard>,
        now: Instant,
    ) -> bool {
        self.expire(now);
        let Some(bare) = weight_of(&roster, None).filter(|b| *b <= ENTRY_MAX_BYTES) else { return false };
        let (card, bytes) = match weight_of(&roster, card.as_ref()) {
            Some(b) if b <= ENTRY_MAX_BYTES => (card, b),
            _ => (None, bare),
        };
        self.seq += 1;
        let key = (server_id.to_string(), master.to_string());
        self.held.insert(
            key,
            Held {
                server_id: server_id.to_string(),
                sender: sender.to_string(),
                roster,
                card,
                bytes,
                seq: self.seq,
                at: now,
            },
        );
        self.trim();
        true
    }

    /// The held asks whose askers `standing` now finds admitted, taken out; those of
    /// servers gone are dropped.
    pub(crate) fn take_admitted(&mut self, standing: impl Fn(&str, &str) -> Standing, now: Instant) -> Vec<Held> {
        self.expire(now);
        let mut landed = Vec::new();
        let keys: Vec<(String, String)> = self.held.keys().cloned().collect();
        for key in keys {
            match standing(&key.0, &key.1) {
                Standing::Waiting => {}
                Standing::Gone => {
                    self.held.remove(&key);
                }
                Standing::Admitted => landed.extend(self.held.remove(&key)),
            }
        }
        landed
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.held.is_empty()
    }

    fn expire(&mut self, now: Instant) {
        self.held.retain(|_, h| now.saturating_duration_since(h.at) < HOLD_FOR);
    }

    /// Bring the stash within its bounds: the server holding the most of what is over
    /// (asks or bytes) gives up its oldest ask first. The server is the share because
    /// it is the one thing a flood cannot mint here: asks come only through the doors of
    /// servers we are in, so one server's flood pushes out only that server's asks.
    fn trim(&mut self) {
        loop {
            let by_count = self.held.len() > MAX_HELD;
            if !by_count && self.held.values().map(|h| h.bytes).sum::<usize>() <= MAX_HELD_BYTES {
                return;
            }
            let mut shares: HashMap<&str, (usize, usize)> = HashMap::new();
            for h in self.held.values() {
                let share = shares.entry(h.server_id.as_str()).or_default();
                share.0 += 1;
                share.1 += h.bytes;
            }
            let weight = |&(n, bytes): &(usize, usize)| if by_count { (n, bytes) } else { (bytes, n) };
            let Some(heaviest) = shares
                .into_iter()
                .max_by(|a, b| weight(&a.1).cmp(&weight(&b.1)).then(a.0.cmp(b.0)))
                .map(|(s, _)| s.to_string())
            else {
                return;
            };
            let Some(oldest) = self
                .held
                .iter()
                .filter(|(_, h)| h.server_id == heaviest)
                .min_by_key(|(_, h)| h.seq)
                .map(|(k, _)| k.clone())
            else {
                return;
            };
            self.held.remove(&oldest);
        }
    }
}

tokio::task_local! {
    /// One stash per node loop.
    static STASH: RefCell<JoinStash>;
}

/// Run a node loop with its own stash of the asks it stepped aside from.
pub(crate) fn with_join_stash<F: std::future::Future>(loop_: F) -> impl std::future::Future<Output = F::Output> {
    STASH.scope(RefCell::new(JoinStash::default()), loop_)
}

/// [`JoinStash::hold`] on this node's stash; outside a node loop nothing is held.
pub(crate) fn hold(server_id: &str, master: &str, sender: &str, roster: Roster, card: Option<HeldCard>) -> bool {
    STASH
        .try_with(|s| s.borrow_mut().hold(server_id, master, sender, roster, card, Instant::now()))
        .unwrap_or(false)
}

/// [`JoinStash::take_admitted`] on this node's stash.
pub(crate) fn take_admitted(standing: impl Fn(&str, &str) -> Standing) -> Vec<Held> {
    STASH
        .try_with(|s| {
            let mut s = s.borrow_mut();
            if s.is_empty() { Vec::new() } else { s.take_admitted(standing, Instant::now()) }
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::native_identity::NativeKeypair;

    fn kp(seed: u8, i: u32) -> NativeKeypair {
        let mut bytes = [seed; 32];
        bytes[..4].copy_from_slice(&i.to_be_bytes());
        NativeKeypair::from_secret_bytes(&bytes)
    }

    fn roster(i: u32) -> (String, String, Roster) {
        let (m, d) = (kp(0x41, i), kp(0x42, i));
        (m.peer_id(), d.peer_id(), Roster::legacy_for_test(&m, &[&d]))
    }

    fn card(master: &str, avatar: usize) -> HeldCard {
        let card = SignedCard { master: master.into(), display_name: "t14f".into(), ..Default::default() };
        HeldCard { card, avatar: (avatar > 0).then(|| vec![7u8; avatar]), ceiling: 0 }
    }

    fn admitted<'a>(of: &'a [&'a str]) -> impl Fn(&str, &str) -> Standing + 'a {
        move |_, m| if of.contains(&m) { Standing::Admitted } else { Standing::Waiting }
    }

    /// HOL-SEC-192: a held ask lands only once its asker is admitted, and only once.
    #[test]
    fn t14f_a_held_ask_lands_only_once_admitted() {
        let mut stash = JoinStash::default();
        let now = Instant::now();
        let (m, d, r) = roster(1);
        assert!(stash.hold("s", &m, &d, r, Some(card(&m, 0)), now));
        assert!(stash.take_admitted(admitted(&[]), now).is_empty(), "nobody admitted it yet");
        let landed = stash.take_admitted(admitted(&[&m]), now);
        assert_eq!(landed.len(), 1);
        assert!(landed[0].card.is_some() && landed[0].sender == d && landed[0].roster.master == m);
        assert!(stash.take_admitted(admitted(&[&m]), now).is_empty(), "it lands once");
        let (m2, d2, r2) = roster(2);
        stash.hold("gone", &m2, &d2, r2, None, now);
        assert!(stash.take_admitted(|_, _| Standing::Gone, now).is_empty() && stash.is_empty(), "a server gone drops its asks");
        let (m3, d3, r3) = roster(3);
        stash.hold("s", &m3, &d3, r3, None, now);
        assert!(stash.take_admitted(admitted(&[&m3]), now + HOLD_FOR).is_empty(), "an ask nobody admitted in time is forgotten");
    }

    /// One held ask weighs at most a few KiB: a card too heavy for it goes, a roster too
    /// heavy is never held.
    #[test]
    fn t14f_a_held_ask_weighs_at_most_its_entry_cap() {
        let mut stash = JoinStash::default();
        let now = Instant::now();
        let (m, d, r) = roster(1);
        assert!(stash.hold("s", &m, &d, r, Some(card(&m, ENTRY_MAX_BYTES)), now));
        let landed = stash.take_admitted(admitted(&[&m]), now);
        assert!(landed[0].card.is_none(), "the card whose avatar overweighs the entry is dropped with it");
        let master = kp(0x43, 9);
        let devices: Vec<NativeKeypair> = (0..200).map(|i| kp(0x44, i)).collect();
        let big = Roster::legacy_for_test(&master, &devices.iter().collect::<Vec<_>>());
        assert!(serde_json::to_vec(&big).unwrap().len() > ENTRY_MAX_BYTES);
        assert!(!stash.hold("s", &master.peer_id(), &devices[0].peer_id(), big, None, now), "an overweight roster");
        assert!(stash.is_empty());
    }

    /// A flood through one server's door pushes out only that server's asks.
    #[test]
    fn t14f_a_flood_through_one_server_keeps_the_others_asks() {
        let mut stash = JoinStash::default();
        let now = Instant::now();
        let (m, d, r) = roster(1);
        stash.hold("honest", &m, &d, r, None, now);
        for i in 0..(MAX_HELD as u32 * 2) {
            let (fm, fd, fr) = roster(1000 + i);
            stash.hold("flooded", &fm, &fd, fr, Some(card(&fm, 0)), now);
            assert!(stash.held.len() <= MAX_HELD, "the count bound");
            assert!(stash.held.values().map(|h| h.bytes).sum::<usize>() <= MAX_HELD_BYTES, "the byte bound");
        }
        assert_eq!(stash.take_admitted(admitted(&[&m]), now).len(), 1, "the other server's ask survives the flood");
        let newest = roster(1000 + MAX_HELD as u32 * 2 - 1).0;
        let oldest = roster(1000).0;
        assert!(stash.held.contains_key(&("flooded".to_string(), newest)), "the flood's newest ask is held");
        assert!(!stash.held.contains_key(&("flooded".to_string(), oldest)), "its oldest gave way");
    }
}
