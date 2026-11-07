//! The join lock as a member's replica holds it (`CrdtPayload::JoinLock`): the chain
//! it republishes, the door secrets that open requests, and the sealed change keys.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

use super::hlc::HlcTimestamp;
use super::operations::JoinSecret;
use crate::node::join_lock::{self, LockLink};

/// Door secrets kept below the newest one, so a request sealed just before a
/// change still opens.
const DOORS_KEPT: u64 = 8;
/// Grants kept per master and change key: a garbage grant cannot push out a real one
/// unless it is repeated this often.
const GRANTS_PER_MASTER: usize = 4;

#[derive(Clone, Serialize, Deserialize)]
struct Door {
    n: u64,
    secret: JoinSecret,
}

#[derive(Clone, Default, Serialize, Deserialize)]
pub struct JoinLockState {
    /// Chain links by number, owner-signed ones included. Two links may share a
    /// number: a fork, or a lock and the owner's re-signing of it.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    links: Vec<LockLink>,
    /// Door secrets by the door's public half.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    doors: BTreeMap<String, Door>,
    /// Sealed change keys: change key -> master -> grants.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    grants: BTreeMap<String, BTreeMap<String, Vec<String>>>,
    /// Clock of the newest op that set a door, and of the newest removal from the
    /// server or from its moderation: the lock is due to move when the second is later.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    door_hlc: Option<HlcTimestamp>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    removal_hlc: Option<HlcTimestamp>,
    /// The clock of the op that carried each grant: a master keeps its newest few by
    /// clock, never by the order they arrived in.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    grant_at: BTreeMap<String, HlcTimestamp>,
    /// The clock of the op that first applied each owner-signed base (by its door): what
    /// tells a new start below a frozen chain from an old base.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    base_at: BTreeMap<String, HlcTimestamp>,
}

impl std::fmt::Debug for JoinLockState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "JoinLockState(links={}, doors={}, due={})", self.links.len(), self.doors.len(), self.rotation_due())
    }
}

impl JoinLockState {
    pub fn is_empty(&self) -> bool {
        self.links.is_empty() && self.doors.is_empty() && self.removal_hlc.is_none()
    }

    pub fn has_lock(&self) -> bool {
        !self.links.is_empty()
    }

    /// Whether `link` may enter: the owner's own signature on a base, or a successor
    /// of a link we hold. A link we already hold (a later op adding grants) passes. A
    /// new base must be made by an owner device `counts` (master, device), and so must
    /// any link with a device proof or after one (DEVICE_PROOF_DESIGN section 12 item 1,
    /// t14-lock REQUESTS R3).
    pub fn link_allowed(&self, server_id: &str, link: &LockLink, owner: &str, counts: &dyn Fn(&str, &str) -> bool) -> bool {
        if self.links.iter().any(|l| l == link) {
            return true;
        }
        let made_counted = || join_lock::link_device(server_id, link).is_some_and(|(m, d)| counts(&m, &d));
        if link.is_base() {
            return join_lock::base_owner(server_id, link).as_deref() == Some(owner)
                && join_lock::link_device(server_id, link).is_some_and(|(m, _)| m == owner)
                && made_counted();
        }
        self.links
            .iter()
            .filter(|prev| join_lock::extends(server_id, prev, link))
            .any(|prev| (prev.dev.is_none() && link.dev.is_none()) || made_counted())
    }

    pub(super) fn apply(&mut self, link: &LockLink, door: Option<&JoinSecret>, grants: &BTreeMap<String, String>, hlc: &HlcTimestamp) {
        if !self.links.iter().any(|l| l == link) {
            let at = self.links.partition_point(|l| l.n <= link.n);
            self.links.insert(at, link.clone());
        }
        if link.is_base() {
            let at = self.base_at.entry(link.door.clone()).or_insert_with(|| hlc.clone());
            if hlc < at {
                *at = hlc.clone();
            }
        }
        if let Some(secret) = door.filter(|s| door_matches(s, link)) {
            self.doors.insert(link.door.clone(), Door { n: link.n, secret: secret.clone() });
            if self.door_hlc.as_ref().is_none_or(|h| hlc > h) {
                self.door_hlc = Some(hlc.clone());
            }
        }
        for (master, grant) in grants {
            let at = self.grant_at.entry(grant.clone()).or_insert_with(|| hlc.clone());
            if hlc < at {
                *at = hlc.clone();
            }
            let held = self.grants.entry(link.change.clone()).or_default().entry(master.clone()).or_default();
            if !held.contains(grant) {
                held.push(grant.clone());
            }
            let when = |g: &String| self.grant_at.get(g).cloned();
            held.sort_by(|a, b| when(a).cmp(&when(b)).then_with(|| a.cmp(b)));
            if held.len() > GRANTS_PER_MASTER {
                let excess = held.len() - GRANTS_PER_MASTER;
                held.drain(..excess);
            }
        }
        self.prune();
    }

    /// Whether this lock already holds everything `JoinLock { link, door, grants }`
    /// writes: the link, its door (or one too old to keep) and every grant (or one whose
    /// change key is gone or that four newer ones pushed out).
    pub(super) fn decides(&self, link: &LockLink, door: Option<&JoinSecret>, grants: &BTreeMap<String, String>, at: &HlcTimestamp) -> bool {
        let top = self.doors.values().map(|d| d.n).max().unwrap_or(0);
        let floor = top.saturating_sub(DOORS_KEPT);
        self.links.iter().any(|l| l == link)
            && door.is_none_or(|_| self.doors.contains_key(&link.door) || link.n < floor)
            && grants.iter().all(|(master, grant)| {
                let held = self.grants_for(&link.change, master);
                held.contains(grant)
                    || !self.grants.contains_key(&link.change)
                    || held.len() >= GRANTS_PER_MASTER && self.grant_at.get(&held[0]).is_some_and(|oldest| at < oldest)
            })
    }

    /// A member left, was removed or banned, or an owner, admin or mod lost that rank.
    pub(super) fn note_removal(&mut self, hlc: &HlcTimestamp) {
        if self.removal_hlc.as_ref().is_none_or(|h| hlc > h) {
            self.removal_hlc = Some(hlc.clone());
        }
    }

    /// Someone who held the door or the change key lost the right to since the newest
    /// door was set.
    pub fn rotation_due(&self) -> bool {
        match (&self.removal_hlc, &self.door_hlc) {
            (Some(removed), Some(set)) => removed > set,
            _ => false,
        }
    }

    /// The newest door we hold: its number, public half and secret.
    pub fn newest_door(&self) -> Option<(u64, [u8; 32], Zeroizing<[u8; 32]>)> {
        let (public, door) = self.newest()?;
        Some((door.n, crate::node::sealed_box::key_from_text(public)?, secret_bytes(&door.secret)?))
    }

    /// [`Self::newest_door`]'s number and public half as text, decoding nothing.
    pub fn newest_door_id(&self) -> Option<(u64, &str)> {
        self.newest().map(|(public, door)| (door.n, public.as_str()))
    }

    fn newest(&self) -> Option<(&String, &Door)> {
        self.doors.iter().max_by(|a, b| a.1.n.cmp(&b.1.n).then_with(|| b.0.cmp(a.0)))
    }

    /// Every door secret with number `n` (a fork can hold two).
    pub fn door_secrets(&self, n: u64) -> Vec<Zeroizing<[u8; 32]>> {
        self.doors.values().filter(|d| d.n == n).filter_map(|d| secret_bytes(&d.secret)).collect()
    }

    /// The link holding this exact lock (number, door and change key), if we hold it.
    pub fn find(&self, lock: &LockLink) -> Option<&LockLink> {
        self.links.iter().find(|l| l.same_lock(lock))
    }

    /// The secret of the door `link` names, if we hold it.
    pub fn door_of(&self, link: &LockLink) -> Option<JoinSecret> {
        self.doors.get(&link.door).map(|d| d.secret.clone())
    }

    pub fn holds_door(&self, door: &str) -> bool {
        self.doors.contains_key(door)
    }

    /// The chain we republish: from the newest owner-signed link, each next lock one
    /// we hold the door of where a fork offers two.
    pub fn chain(&self) -> Vec<LockLink> {
        let Some(base) = self.start() else {
            return Vec::new();
        };
        let mut chain = vec![base.clone()];
        loop {
            let last = chain.last().expect("never empty");
            let next = self
                .links
                .iter()
                .filter(|l| !l.is_base() && l.n == last.n + 1)
                .max_by_key(|l| self.holds_door(&l.door));
            let Some(next) = next.cloned() else { break };
            chain.push(next);
            if chain.len() >= join_lock::MAX_CHAIN {
                break;
            }
        }
        chain
    }

    /// The grants sealed to `master` for this change key.
    pub fn grants_for(&self, change: &str, master: &str) -> &[String] {
        self.grants.get(change).and_then(|m| m.get(master)).map(Vec::as_slice).unwrap_or(&[])
    }

    pub(super) fn clamp_hlcs(&mut self, max_ms: u64) -> usize {
        let mut clamped = 0;
        for hlc in [&mut self.door_hlc, &mut self.removal_hlc].into_iter().flatten().chain(self.grant_at.values_mut()) {
            if hlc.physical_ms > max_ms {
                hlc.physical_ms = max_ms;
                clamped += 1;
            }
        }
        clamped
    }

    /// Where the chain starts: the newest owner-signed link, unless it is frozen (past
    /// `FROZEN_FROM`, where no successor fits) and an op later than the one that applied
    /// it brought a base below the line (any dated base, when the frozen one came from a
    /// state that dates nothing): then the latest such base starts over (t14-lock
    /// REQUESTS R2, the relay's `relay_put`).
    fn start(&self) -> Option<&LockLink> {
        let top = self.links.iter().filter(|l| l.is_base()).max_by_key(|l| l.n)?;
        if top.n <= join_lock::FROZEN_FROM {
            return Some(top);
        }
        let top_at = self.base_at.get(&top.door);
        let restart = self
            .links
            .iter()
            .filter(|l| l.is_base() && l.n <= join_lock::FROZEN_FROM)
            .filter_map(|l| self.base_at.get(&l.door).map(|at| (at, l)))
            .filter(|(at, _)| top_at.is_none_or(|t| *at > t))
            .max_by(|a, b| a.0.cmp(b.0).then_with(|| a.1.n.cmp(&b.1.n)));
        Some(restart.map_or(top, |(_, l)| l))
    }

    /// Links from the chain's start on, doors and grants for the newest few numbers.
    fn prune(&mut self) {
        if let Some(start) = self.start().cloned() {
            let restarted = start.n <= join_lock::FROZEN_FROM;
            self.links.retain(|l| l.n >= start.n && !(restarted && l.n > join_lock::FROZEN_FROM));
            let doors: std::collections::HashSet<&str> = self.links.iter().map(|l| l.door.as_str()).collect();
            self.base_at.retain(|door, _| doors.contains(door.as_str()));
        }
        if self.links.len() > join_lock::MAX_CHAIN {
            let excess = self.links.len() - join_lock::MAX_CHAIN;
            self.links.drain(..excess);
        }
        let Some(top) = self.doors.values().map(|d| d.n).max() else { return };
        let floor = top.saturating_sub(DOORS_KEPT);
        self.doors.retain(|_, d| d.n >= floor);
        let live: std::collections::HashSet<&str> =
            self.links.iter().filter(|l| l.n >= floor).map(|l| l.change.as_str()).collect();
        self.grants.retain(|change, _| live.contains(change.as_str()));
        let kept: std::collections::HashSet<&String> = self.grants.values().flat_map(|m| m.values().flatten()).collect();
        self.grant_at.retain(|g, _| kept.contains(g));
    }
}

fn secret_bytes(secret: &JoinSecret) -> Option<Zeroizing<[u8; 32]>> {
    if secret.0.len() != 64 {
        return None;
    }
    let bytes = Zeroizing::new(hex::decode(&secret.0).ok()?);
    Some(Zeroizing::new(bytes.as_slice().try_into().ok()?))
}

/// Whether `secret` is the door `link` names.
pub fn door_matches(secret: &JoinSecret, link: &LockLink) -> bool {
    secret_bytes(secret)
        .is_some_and(|s| Some(crate::node::sealed_box::public_of(&s)) == link.door_key())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::native_identity::NativeKeypair;
    use crate::node::join_lock::{mint_owner_base, mint_successor, FROZEN_FROM, MAX_N};

    fn at(ms: u64) -> HlcTimestamp {
        HlcTimestamp { physical_ms: ms, counter: 0, actor: "o".into() }
    }

    /// t14-lock REQUESTS R2: a chain a master-key holder froze at the ceiling gives way to
    /// the owner's later base below the line, and only to a later one.
    #[test]
    fn a_frozen_chain_gives_way_to_a_later_base_below_the_line() {
        let owner = NativeKeypair::from_secret_bytes(&[1; 32]);
        let device = NativeKeypair::from_secret_bytes(&[11; 32]);
        let nonce = "00112233445566778899aabbccddeeff".to_string();
        let server = crate::crdt::anchor::derive_server_id(&owner.peer_id(), &nonce);
        let frozen = mint_owner_base(&server, MAX_N, &owner, Some(&nonce), &device).unwrap();
        let early = mint_owner_base(&server, 1, &owner, Some(&nonce), &device).unwrap();
        let none = BTreeMap::new();

        let mut lock = JoinLockState::default();
        lock.apply(&early.link, None, &none, &at(1));
        lock.apply(&frozen.link, None, &none, &at(2));
        assert_eq!(lock.chain().first().map(|l| l.n), Some(MAX_N), "an older base below the line starts nothing over");

        let restart = mint_owner_base(&server, 1, &owner, Some(&nonce), &device).unwrap();
        lock.apply(&restart.link, None, &none, &at(3));
        assert_eq!(lock.chain().first(), Some(&restart.link), "a later base below the line is the start");
        assert!(lock.links.iter().all(|l| l.n <= FROZEN_FROM), "and the frozen links go");
        let next = mint_successor(&server, &restart.link, &restart.change, &owner.peer_id(), &device).unwrap();
        lock.apply(&next.link, None, &none, &at(4));
        assert_eq!(lock.chain().len(), 2, "members follow the new chain");

        let mut below = JoinLockState::default();
        let high = mint_owner_base(&server, FROZEN_FROM, &owner, Some(&nonce), &device).unwrap();
        below.apply(&high.link, None, &none, &at(1));
        below.apply(&restart.link, None, &none, &at(2));
        assert_eq!(below.chain().first().map(|l| l.n), Some(FROZEN_FROM), "a chain below the line is not frozen");
    }

    /// t14-lock REQUESTS R3: the fold takes a new base only from an owner device the view
    /// counts, and a link with a device proof (or after one) only from a counted device.
    #[test]
    fn a_link_enters_only_from_a_device_the_view_counts() {
        let owner = NativeKeypair::from_secret_bytes(&[1; 32]);
        let device = NativeKeypair::from_secret_bytes(&[11; 32]);
        let removed = NativeKeypair::from_secret_bytes(&[12; 32]);
        let nonce = "00112233445566778899aabbccddeeff".to_string();
        let server = crate::crdt::anchor::derive_server_id(&owner.peer_id(), &nonce);
        let o = owner.peer_id();
        let counted = |m: &str, d: &str| m == o && d == device.peer_id();
        let empty = JoinLockState::default();

        let base = mint_owner_base(&server, 1, &owner, Some(&nonce), &device).unwrap();
        assert!(empty.link_allowed(&server, &base.link, &o, &counted));
        let mut bare = base.link.clone();
        bare.dev = None;
        assert!(!empty.link_allowed(&server, &bare, &o, &counted), "a base with no device proof (the master key alone)");
        let by_removed = mint_owner_base(&server, 1, &owner, Some(&nonce), &removed).unwrap();
        assert!(!empty.link_allowed(&server, &by_removed.link, &o, &counted), "a base by a device the view does not count");

        let mut lock = JoinLockState::default();
        lock.apply(&base.link, None, &BTreeMap::new(), &at(1));
        let next = mint_successor(&server, &base.link, &base.change, &o, &device).unwrap();
        assert!(lock.link_allowed(&server, &next.link, &o, &counted));
        let stolen = mint_successor(&server, &base.link, &base.change, &o, &removed).unwrap();
        assert!(!lock.link_allowed(&server, &stolen.link, &o, &counted), "a successor by an uncounted device");
        let mut no_dev = next.link.clone();
        no_dev.dev = None;
        assert!(!lock.link_allowed(&server, &no_dev, &o, &counted), "a successor after a proven link needs its own proof");
        assert!(lock.link_allowed(&server, &base.link, &o, &|_: &str, _: &str| false), "a link already held stays");
    }
}
