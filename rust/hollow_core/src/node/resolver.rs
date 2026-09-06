//! Device to master identity resolver.
//!
//! Maps any device peer_id to the MASTER identity it belongs to. An UNKNOWN
//! peer_id (old single-device client, stranger, a device list not yet ingested)
//! resolves to ITSELF, which is what keeps single-device behaviour unchanged.
//! The device key drives identity ONLY at the WS/signaling transport layer, so
//! `RoomMembers`/`PeerJoined` report device ids while `local_peer_str`, server
//! and MLS membership, permission lookups, message signing and the DB passphrase
//! all stay MASTER; the resolver is needed only where a REMOTE device id arrives
//! and has to be mapped. Process-global, so no map is threaded through handlers.

use std::collections::HashMap;
use std::sync::{OnceLock, RwLock};

/// device_peer_id → master_peer_id. Only contains entries learned from verified
/// device lists (plus our own devices, self-seeded at startup).
static LINKS: OnceLock<RwLock<HashMap<String, String>>> = OnceLock::new();

fn links() -> &'static RwLock<HashMap<String, String>> {
    LINKS.get_or_init(|| RwLock::new(HashMap::new()))
}

/// Device peer_ids seen REVOKED in a signed tombstone, kept process-global so
/// the DM/typing receive path can DROP a just-revoked device that is still alive
/// and talking. Cleared on `clear_all`; our own running device id is never here.
static REVOKED: OnceLock<RwLock<std::collections::HashSet<String>>> = OnceLock::new();

fn revoked() -> &'static RwLock<std::collections::HashSet<String>> {
    REVOKED.get_or_init(|| RwLock::new(std::collections::HashSet::new()))
}

/// Resolve a device peer_id to its master identity; unknown peers resolve to
/// themselves. A poisoned lock degrades to passthrough rather than panicking.
pub(crate) fn resolve(peer_id: &str) -> String {
    match links().read() {
        Ok(map) => map.get(peer_id).cloned().unwrap_or_else(|| peer_id.to_string()),
        Err(_) => peer_id.to_string(),
    }
}

/// True iff two peer_ids resolve to the same master identity; the replacement
/// for a bare `a == b` self or friend check anywhere in the node.
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

/// Seed our OWN devices to our master so self-checks recognise them before any
/// device list round-trips. On a pre-multi-device install device == master, so
/// this is a harmless self-mapping.
pub(crate) fn seed_self(master_peer_id: &str, device_peer_ids: &[String]) {
    if let Ok(mut map) = links().write() {
        for d in device_peer_ids {
            map.insert(d.clone(), master_peer_id.to_string());
        }
        // Master maps to itself (so resolving the master id is stable).
        map.insert(master_peer_id.to_string(), master_peer_id.to_string());
    }
}

/// Warm the resolver from persisted device links. MUST run before the event loop
/// takes incoming messages, or early messages misattribute.
pub(crate) fn warm_from_links(pairs: &[(String, String)]) {
    if let Ok(mut map) = links().write() {
        for (device, master) in pairs {
            map.insert(device.clone(), master.clone());
        }
    }
}

/// Snapshot all known (device, master) links for the FFI attribution layer. A
/// single-device install yields just self-mappings, or nothing.
pub(crate) fn all_links() -> Vec<(String, String)> {
    match links().read() {
        Ok(map) => map.iter().map(|(d, m)| (d.clone(), m.clone())).collect(),
        Err(_) => Vec::new(),
    }
}

/// All known device peer_ids belonging to `master_peer_id`, the inverse of
/// `resolve()`. Excludes the master id when it is ONLY a value (a friend's
/// master known through its devices but never authenticating as itself), so a
/// send is never fanned out to an id no device connects as. EMPTY for an
/// unknown master, and callers then fall back to the master id as-is.
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

/// Forget one device link. The map is otherwise insert-only, so without this a
/// revoked device keeps resolving to its master, and so stays a fan-out and
/// presence-collapse target, until the next restart. Safe for an absent id.
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

/// Mark device ids revoked so the DM/typing receive path drops a just-revoked
/// device that is still alive (phantom-chat guard).
pub(crate) fn mark_revoked(device_peer_ids: &[String]) {
    if let Ok(mut set) = revoked().write() {
        for d in device_peer_ids {
            set.insert(d.clone());
        }
    }
}

/// True iff this device id was seen revoked in a signed tombstone; callers drop
/// inbound DMs and typing from it. Unknown ids are false.
pub(crate) fn is_revoked(device_peer_id: &str) -> bool {
    revoked()
        .read()
        .map(|s| s.contains(device_peer_id))
        .unwrap_or(false)
}

/// Process-wide lock for EVERY test that mutates the global resolver map or
/// asserts on state that depends on it. cargo runs tests in parallel, so without
/// one shared lock a `clear_all` wipes another test's links mid-assert. The
/// harness `test_guard` funnels through this same lock.
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

/// Clear the in-memory resolver (testing and maintenance aid; pairs with
/// `MessageStore::clear_all_device_lists`). Devices re-learn on the next
/// profile exchange.
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

    // The resolver is process-global: take the PROCESS-WIDE lock, shared with the
    // harness and the crypto_handler/server_state tests, then clear, so test order
    // never matters.
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
        assert_eq!(resolve("12D3KooWmaster"), "12D3KooWmaster");
    }

    #[test]
    fn same_identity_across_devices() {
        let _g = guarded();
        update_many("M", ["devA", "devB"]);
        assert!(same_identity("devA", "devB"));
        assert!(same_identity("devA", "M"));
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
        // Unknown master is empty; the caller then sends to the id as-is.
        assert!(devices_for("stranger").is_empty());
    }

    #[test]
    fn devices_for_excludes_self_master_seed() {
        let _g = guarded();
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
        assert_eq!(resolve("devA"), "devA");
        assert!(!same_identity("devA", "devB"));
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
        forget("never-seen");
        assert_eq!(resolve("devA"), "M");
    }

    #[test]
    fn revoked_guard_marks_and_clears() {
        let _g = guarded();
        assert!(!is_revoked("devX"));
        mark_revoked(&["devX".into(), "devY".into()]);
        assert!(is_revoked("devX"));
        assert!(is_revoked("devY"));
        assert!(!is_revoked("devZ"));
        clear_all();
        assert!(!is_revoked("devX"));
    }
}
