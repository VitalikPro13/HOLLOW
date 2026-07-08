//! Local user block list (MASTER-keyed), enforced at ingest.
//!
//! Process-global mirror of the SQLCipher `blocked_peers` table (same shape as
//! the resolver's REVOKED set) so the DM/friend-request/call hot paths do a
//! lock-read instead of opening the DB per message. Warmed at node startup
//! alongside `resolver::warm_from_links`; mutated only via the Block/Unblock
//! node commands, which persist first and then update this set.
//!
//! Blocking is receiver-side self-protection: the blocked identity's traffic
//! still arrives at the socket — these checks drop it before store + emit so
//! it never reaches the DB, UI, or notifications. Always check via
//! `is_blocked(sender_device_id)` — it collapses device→master through the
//! resolver, so a blocked person can't sidestep the block from a second device.

use std::collections::HashSet;
use std::sync::{OnceLock, RwLock};

static BLOCKED: OnceLock<RwLock<HashSet<String>>> = OnceLock::new();

fn blocked() -> &'static RwLock<HashSet<String>> {
    BLOCKED.get_or_init(|| RwLock::new(HashSet::new()))
}

/// Warm the set from persisted rows at startup (before the event loop).
pub(crate) fn warm(masters: &[String]) {
    if let Ok(mut set) = blocked().write() {
        for m in masters {
            set.insert(m.clone());
        }
    }
}

pub(crate) fn block(master_peer_id: &str) {
    if let Ok(mut set) = blocked().write() {
        set.insert(master_peer_id.to_string());
    }
}

pub(crate) fn unblock(master_peer_id: &str) {
    if let Ok(mut set) = blocked().write() {
        set.remove(master_peer_id);
    }
}

/// True iff this peer (device OR master id) resolves to a blocked master.
/// A poisoned lock degrades to "not blocked" rather than crashing a handler.
pub(crate) fn is_blocked(peer_id: &str) -> bool {
    let master = super::resolver::resolve(peer_id);
    blocked()
        .read()
        .map(|s| s.contains(&master))
        .unwrap_or(false)
}

#[cfg(test)]
pub(crate) fn clear_for_test() {
    if let Ok(mut set) = blocked().write() {
        set.clear();
    }
}
