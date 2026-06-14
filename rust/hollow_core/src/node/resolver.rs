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

use std::collections::HashMap;
use std::sync::{OnceLock, RwLock};

/// device_peer_id → master_peer_id. Only contains entries learned from verified
/// device lists (plus our own devices, self-seeded at startup).
static LINKS: OnceLock<RwLock<HashMap<String, String>>> = OnceLock::new();

fn links() -> &'static RwLock<HashMap<String, String>> {
    LINKS.get_or_init(|| RwLock::new(HashMap::new()))
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

#[cfg(test)]
pub(crate) fn clear_for_test() {
    if let Ok(mut map) = links().write() {
        map.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // The resolver is process-global; serialize tests so they don't race on the
    // shared map (cargo runs tests in parallel). Each test takes this guard,
    // then clears, so it sees a clean map regardless of order.
    static TEST_GUARD: Mutex<()> = Mutex::new(());

    fn guarded() -> std::sync::MutexGuard<'static, ()> {
        let g = TEST_GUARD.lock().unwrap_or_else(|e| e.into_inner());
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
}
