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
    /// of a link we hold. A link we already hold (a later op adding grants) passes.
    pub fn link_allowed(&self, server_id: &str, link: &LockLink, owner: &str) -> bool {
        if self.links.iter().any(|l| l == link) {
            return true;
        }
        if link.is_base() {
            return join_lock::base_owner(server_id, link).as_deref() == Some(owner);
        }
        self.links.iter().any(|prev| join_lock::extends(server_id, prev, link))
    }

    pub(super) fn apply(&mut self, link: &LockLink, door: Option<&JoinSecret>, grants: &BTreeMap<String, String>, hlc: &HlcTimestamp) {
        if !self.links.iter().any(|l| l == link) {
            let at = self.links.partition_point(|l| l.n <= link.n);
            self.links.insert(at, link.clone());
        }
        if let Some(secret) = door.filter(|s| door_matches(s, link)) {
            self.doors.insert(link.door.clone(), Door { n: link.n, secret: secret.clone() });
            if self.door_hlc.as_ref().is_none_or(|h| hlc > h) {
                self.door_hlc = Some(hlc.clone());
            }
        }
        for (master, grant) in grants {
            let held = self.grants.entry(link.change.clone()).or_default().entry(master.clone()).or_default();
            if !held.contains(grant) {
                held.push(grant.clone());
                if held.len() > GRANTS_PER_MASTER {
                    held.remove(0);
                }
            }
        }
        self.prune();
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
        let (public, door) = self.doors.iter().max_by(|a, b| a.1.n.cmp(&b.1.n).then_with(|| b.0.cmp(a.0)))?;
        Some((door.n, crate::node::sealed_box::key_from_text(public)?, secret_bytes(&door.secret)?))
    }

    /// Every door secret with number `n` (a fork can hold two).
    pub fn door_secrets(&self, n: u64) -> Vec<Zeroizing<[u8; 32]>> {
        self.doors.values().filter(|d| d.n == n).filter_map(|d| secret_bytes(&d.secret)).collect()
    }

    /// The link holding this exact lock (number, door and change key), if we hold it.
    pub fn find(&self, lock: &LockLink) -> Option<&LockLink> {
        self.links.iter().find(|l| l.same_lock(lock))
    }

    pub fn holds_door(&self, door: &str) -> bool {
        self.doors.contains_key(door)
    }

    /// The chain we republish: from the newest owner-signed link, each next lock one
    /// we hold the door of where a fork offers two.
    pub fn chain(&self) -> Vec<LockLink> {
        let Some(base) = self.links.iter().filter(|l| l.is_base()).max_by_key(|l| l.n) else {
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
        for hlc in [&mut self.door_hlc, &mut self.removal_hlc].into_iter().flatten() {
            if hlc.physical_ms > max_ms {
                hlc.physical_ms = max_ms;
                clamped += 1;
            }
        }
        clamped
    }

    /// Links from the newest owner-signed one on, doors and grants for the newest few
    /// numbers.
    fn prune(&mut self) {
        if let Some(base_n) = self.links.iter().filter(|l| l.is_base()).map(|l| l.n).max() {
            self.links.retain(|l| l.n >= base_n);
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
