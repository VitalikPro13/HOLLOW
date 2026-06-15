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

#[cfg(test)]
pub(crate) fn clear_for_test() {
    if let Ok(mut map) = links().write() {
        map.clear();
    }
}

/// Clear the in-memory resolver (multi-device testing/maintenance aid; pairs
/// with `MessageStore::clear_all_device_lists`). Devices re-learn from live
/// siblings on the next profile exchange.
pub(crate) fn clear_all() {
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
}
