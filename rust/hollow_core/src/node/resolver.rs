//! Device → master identity resolver (multi-device, Phase 6).
//!
//! Maps any device peer_id to the MASTER identity peer_id it belongs to, so all
//! "is this me / is this my friend" and attribution logic works in terms of the
//! one identity rather than the per-device peer_id.
//!
//! Backward-compat invariant: an UNKNOWN peer_id (old single-device client,
//! stranger, or a friend whose device list we haven't received yet) resolves to
//! ITSELF. Single-device behavior is therefore identical to pre-multi-device —
//! nothing breaks until a signed device list is actually ingested.
//!
//! Process-global state (mirrors the existing `CACHED_PEER_ID` / `SESSION_KEY`
//! globals) so handlers can call `resolve()` without threading a map through
//! every function signature.
//!
//! ## Architecture decision (locked, Step 8) — where the device id lives
//! The per-device key drives the identity ONLY at the WS/signaling TRANSPORT
//! layer (relay auth → a distinct socket per device; `RoomMembers`/`PeerJoined`
//! therefore report device peer_ids). EVERYWHERE ELSE — `local_peer_str` in the
//! event loop, server/MLS membership, permission lookups, message-content
//! signing, the DB passphrase — stays the MASTER id. The rooms a device joins
//! are MASTER-derived (`inbox:{master}`, `dm_room_code` resolves both ends to
//! masters, `server_id`), so a device authenticates as itself yet sits in its
//! identity's rooms. Consequences:
//!   - The dozens of `member == &local_peer { continue }` self-skips and
//!     `has_permission(&local_peer, …)` lookups need NO resolver call — both
//!     sides are masters.
//!   - The resolver is needed only where a REMOTE peer's *device* id arrives and
//!     must be mapped to its master: DM conversation keys, the friend-request
//!     self-guard, profile/device-list ingest, and `is_mine` attribution.
//! This is why Step 7 (key routing) is small: swap the WS/signaling keypair to
//! the device key; leave `local_peer_str` master.

use std::collections::HashMap;
use std::sync::{OnceLock, RwLock};

/// device_peer_id → master_peer_id. Only contains entries learned from verified
/// device lists (plus our own devices, self-seeded at startup).
static LINKS: OnceLock<RwLock<HashMap<String, String>>> = OnceLock::new();

fn links() -> &'static RwLock<HashMap<String, String>> {
    LINKS.get_or_init(|| RwLock::new(HashMap::new()))
}

/// Device peer_ids we've seen REVOKED in a signed tombstone (Step 7). Kept process-
/// global so the DM/typing receive path can DROP messages from a just-revoked device
/// that is still alive and talking (a phantom-chat guard) until it self-nukes or
/// disconnects. Cleared on `clear_all`. We never tombstone our own running device id
/// here (the caller filters that).
static REVOKED: OnceLock<RwLock<std::collections::HashSet<String>>> = OnceLock::new();

fn revoked() -> &'static RwLock<std::collections::HashSet<String>> {
    REVOKED.get_or_init(|| RwLock::new(std::collections::HashSet::new()))
}

/// Resolve a device peer_id to its master identity. Unknown peers resolve to
/// themselves (backward-compat). Never panics; a poisoned lock degrades to
/// identity-passthrough rather than crashing a message handler.
pub(crate) fn resolve(peer_id: &str) -> String {
    match links().read() {
        Ok(map) => map.get(peer_id).cloned().unwrap_or_else(|| peer_id.to_string()),
        Err(_) => peer_id.to_string(),
    }
}

/// True iff two peer_ids resolve to the same master identity — the generalized
/// replacement for `a == b` self/friend checks across the node.
pub(crate) fn same_identity(a: &str, b: &str) -> bool {
    a == b || resolve(a) == resolve(b)
}

/// Record a verified (device → master) link. Idempotent.
pub(crate) fn update(device_peer_id: &str, master_peer_id: &str) {
    if let Ok(mut map) = links().write() {
        map.insert(device_peer_id.to_string(), master_peer_id.to_string());
    }
}

/// Record many links at once (e.g. all devices from one ingested list).
pub(crate) fn update_many<'a>(
    master_peer_id: &str,
    device_peer_ids: impl IntoIterator<Item = &'a str>,
) {
    if let Ok(mut map) = links().write() {
        for d in device_peer_ids {
            map.insert(d.to_string(), master_peer_id.to_string());
        }
    }
}

/// Seed our OWN devices → our master, so self-checks recognize our other
/// devices immediately (even before any device list round-trips). On a
/// pre-multi-device install `device_peer_id == master_peer_id`, so this is a
/// harmless self-mapping.
pub(crate) fn seed_self(master_peer_id: &str, device_peer_ids: &[String]) {
    if let Ok(mut map) = links().write() {
        for d in device_peer_ids {
            map.insert(d.clone(), master_peer_id.to_string());
        }
        // Master maps to itself (so resolving the master id is stable).
        map.insert(master_peer_id.to_string(), master_peer_id.to_string());
    }
}

/// Warm the resolver from persisted device links at startup. MUST run before the
/// event loop processes incoming messages, or early messages misattribute
/// (hazard R4).
pub(crate) fn warm_from_links(pairs: &[(String, String)]) {
    if let Ok(mut map) = links().write() {
        for (device, master) in pairs {
            map.insert(device.clone(), master.clone());
        }
    }
}

/// Snapshot all known (device → master) links for the FFI / Dart attribution
/// layer. Only contains entries learned from verified device lists plus our own
/// devices; a single-device install yields just self-mappings (or empty).
pub(crate) fn all_links() -> Vec<(String, String)> {
    match links().read() {
        Ok(map) => map.iter().map(|(d, m)| (d.clone(), m.clone())).collect(),
        Err(_) => Vec::new(),
    }
}

/// Reverse lookup: all known device peer_ids belonging to `master_peer_id`
/// (multi-device DM fan-out, Step 3). The inverse of `resolve()`. Includes the
/// master id itself iff it appears as a key (it does for our own identity via
/// `seed_self`, and for any device list that lists the master). Excludes the
/// master id when it is ONLY a value (a friend's master we know via its devices
/// but that never authenticates as itself) so we never fan a send out to an id
/// no device connects as.
///
/// Returns EMPTY when the master is unknown (single-device friend, or a device
/// list we haven't ingested yet) — callers fall back to sending to the master id
/// as-is, which is byte-for-byte the pre-multi-device behavior.
pub(crate) fn devices_for(master_peer_id: &str) -> Vec<String> {
    match links().read() {
        Ok(map) => map
            .iter()
            .filter(|(device, master)| {
                master.as_str() == master_peer_id && device.as_str() != master_peer_id
            })
            .map(|(device, _)| device.clone())
            .collect(),
        Err(_) => Vec::new(),
    }
}

/// Forget a single device → master link (Step 7 revocation). The map is otherwise
/// insert-only; without this a revoked device keeps resolving to its master (and so
/// stays a fan-out / presence-collapse target) until the next restart. After this,
/// `resolve(device)` returns the device id itself again (unknown → self). Safe to
/// call for an id that isn't present.
pub(crate) fn forget(device_peer_id: &str) {
    if let Ok(mut map) = links().write() {
        map.remove(device_peer_id);
    }
}

/// Forget many device → master links at once (Step 7 revocation).
pub(crate) fn forget_many(device_peer_ids: &[String]) {
    if let Ok(mut map) = links().write() {
        for d in device_peer_ids {
            map.remove(d);
        }
    }
}

/// Mark device ids as revoked (Step 7) so the DM/typing receive path can drop
/// messages from a just-revoked device that's still alive (phantom-chat guard).
pub(crate) fn mark_revoked(device_peer_ids: &[String]) {
    if let Ok(mut set) = revoked().write() {
        for d in device_peer_ids {
            set.insert(d.clone());
        }
    }
}

/// True iff this device id has been seen revoked in a signed tombstone — callers
/// drop inbound DMs/typing from it (it's a forgotten device that hasn't yet
/// self-nuked / disconnected). Unknown ids return false (normal peers unaffected).
pub(crate) fn is_revoked(device_peer_id: &str) -> bool {
    revoked()
        .read()
        .map(|s| s.contains(device_peer_id))
        .unwrap_or(false)
}

/// Process-wide lock for EVERY test that mutates the global resolver map
/// (`update`/`seed_self`/`clear_all`/`clear_for_test`) or asserts on state that
/// depends on it (`resolve`, `peer_is_reachable`, elections, `ServerState`
/// accessors via the crdt hook). cargo runs tests in parallel; without one
/// shared lock, a test calling `clear_all` wipes another test's links mid-assert
/// (a real intermittent failure — `master_with_online_device_is_reachable` lost
/// exactly that race). The harness `test_guard` and the resolver-module tests
/// both funnel through this same lock.
#[cfg(test)]
pub(crate) fn test_lock() -> std::sync::MutexGuard<'static, ()> {
    static GLOBAL_RESOLVER_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    GLOBAL_RESOLVER_TEST_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner())
}

#[cfg(test)]
pub(crate) fn clear_for_test() {
    if let Ok(mut map) = links().write() {
        map.clear();
    }
    if let Ok(mut set) = revoked().write() {
        set.clear();
    }
}

/// Clear the in-memory resolver (multi-device testing/maintenance aid; pairs
/// with `MessageStore::clear_all_device_lists`). Devices re-learn from live
/// siblings on the next profile exchange.
pub(crate) fn clear_all() {
    if let Ok(mut map) = links().write() {
        map.clear();
    }
    if let Ok(mut set) = revoked().write() {
        set.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // The resolver is process-global; serialize tests so they don't race on the
    // shared map (cargo runs tests in parallel). Each test takes the PROCESS-WIDE
    // resolver lock (shared with the harness + crypto_handler/server_state tests
    // that also touch the global map), then clears, so it sees a clean map
    // regardless of order.
    fn guarded() -> std::sync::MutexGuard<'static, ()> {
        let g = test_lock();
        clear_for_test();
        g
    }

    #[test]
    fn unknown_peer_resolves_to_itself() {
        let _g = guarded();
        assert_eq!(resolve("12D3KooWstranger"), "12D3KooWstranger");
    }

    #[test]
    fn linked_device_resolves_to_master() {
        let _g = guarded();
        update("12D3KooWphone", "12D3KooWmaster");
        assert_eq!(resolve("12D3KooWphone"), "12D3KooWmaster");
        assert_eq!(resolve("12D3KooWmaster"), "12D3KooWmaster"); // unknown → self
    }

    #[test]
    fn same_identity_across_devices() {
        let _g = guarded();
        update_many("M", ["devA", "devB"]);
        assert!(same_identity("devA", "devB"));
        assert!(same_identity("devA", "M")); // device vs its own master
        assert!(!same_identity("devA", "stranger"));
    }

    #[test]
    fn seed_self_maps_devices_and_master() {
        let _g = guarded();
        seed_self("M", &["M".into(), "devB".into()]);
        assert_eq!(resolve("devB"), "M");
        assert_eq!(resolve("M"), "M");
        assert!(same_identity("M", "devB"));
    }

    #[test]
    fn warm_from_links_populates() {
        let _g = guarded();
        warm_from_links(&[("d1".into(), "m1".into()), ("d2".into(), "m1".into())]);
        assert!(same_identity("d1", "d2"));
        assert_eq!(resolve("d1"), "m1");
    }

    #[test]
    fn devices_for_returns_device_set_excluding_master() {
        let _g = guarded();
        update_many("M", ["devA", "devB"]);
        let mut devs = devices_for("M");
        devs.sort();
        assert_eq!(devs, vec!["devA".to_string(), "devB".to_string()]);
        // Unknown master → empty (caller falls back to sending to the id as-is).
        assert!(devices_for("stranger").is_empty());
    }

    #[test]
    fn devices_for_excludes_self_master_seed() {
        let _g = guarded();
        // seed_self inserts master→master plus our other devices.
        seed_self("M", &["M".into(), "devB".into()]);
        let devs = devices_for("M");
        // The bare master must NOT appear (no device authenticates as it).
        assert_eq!(devs, vec!["devB".to_string()]);
    }

    #[test]
    fn forget_drops_a_device_back_to_self() {
        let _g = guarded();
        update_many("M", ["devA", "devB"]);
        forget("devA");
        // The forgotten device resolves to itself again, no longer same-identity.
        assert_eq!(resolve("devA"), "devA");
        assert!(!same_identity("devA", "devB"));
        // The surviving device is untouched.
        assert_eq!(resolve("devB"), "M");
        assert_eq!(devices_for("M"), vec!["devB".to_string()]);
    }

    #[test]
    fn forget_many_drops_a_revoked_set() {
        let _g = guarded();
        update_many("M", ["devA", "devB", "devC"]);
        forget_many(&["devA".into(), "devC".into()]);
        assert_eq!(resolve("devA"), "devA");
        assert_eq!(resolve("devC"), "devC");
        assert_eq!(devices_for("M"), vec!["devB".to_string()]);
    }

    #[test]
    fn forget_is_idempotent_for_unknown_id() {
        let _g = guarded();
        update_many("M", ["devA"]);
        forget("never-seen"); // no panic, no effect
        assert_eq!(resolve("devA"), "M");
    }

    #[test]
    fn revoked_guard_marks_and_clears() {
        let _g = guarded();
        assert!(!is_revoked("devX"));
        mark_revoked(&["devX".into(), "devY".into()]);
        assert!(is_revoked("devX"));
        assert!(is_revoked("devY"));
        assert!(!is_revoked("devZ")); // unrelated id unaffected
        clear_all();
        assert!(!is_revoked("devX")); // cleared with the resolver
    }
}
