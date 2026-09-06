//! Local user block list (MASTER-keyed), enforced at ingest.
//!
//! Process-global mirror of the SQLCipher `blocked_peers` table so the DM,
//! friend-request and call hot paths do a lock-read instead of a DB open.
//! Blocking is receiver-side: the traffic still arrives, and these checks drop
//! it before store and emit. Always ask `is_blocked(sender_device_id)`, which
//! collapses device to master, so a block survives a move to a second device.

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
