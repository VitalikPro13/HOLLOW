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

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{OnceLock, RwLock};

/// device_peer_id → master_peer_id. Only contains entries learned from verified
/// device lists (plus our own devices, self-seeded at startup).
static LINKS: OnceLock<RwLock<HashMap<String, String>>> = OnceLock::new();

fn links() -> &'static RwLock<HashMap<String, String>> {
    LINKS.get_or_init(|| RwLock::new(HashMap::new()))
}

/// Device peer_ids whose signed tombstone we enforced, warmed from the store at
/// boot. Cleared on `clear_all`; our own running device id is never here.
static REVOKED: OnceLock<RwLock<HashSet<String>>> = OnceLock::new();

fn revoked() -> &'static RwLock<HashSet<String>> {
    REVOKED.get_or_init(|| RwLock::new(HashSet::new()))
}

/// Masters whose roster this process holds: their own id is a device only when that
/// roster counts it.
static ROSTERED: OnceLock<RwLock<HashSet<String>>> = OnceLock::new();

fn rostered() -> &'static RwLock<HashSet<String>> {
    ROSTERED.get_or_init(|| RwLock::new(HashSet::new()))
}

/// Moves whenever who is whose device may have changed, so state derived from the
/// resolver (room presence) knows to look again.
static EPOCH: AtomicU64 = AtomicU64::new(0);

fn changed() {
    EPOCH.fetch_add(1, Ordering::Relaxed);
}

/// The current [`EPOCH`].
pub(crate) fn epoch() -> u64 {
    EPOCH.load(Ordering::Relaxed)
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

/// True when `peer_id` is some identity's MASTER here: a device links to it. A
/// master id is never a key of the map, so [`resolve`] alone cannot tell it from a
/// device nobody has claimed yet.
pub(crate) fn is_known_master(peer_id: &str) -> bool {
    links().read().is_ok_and(|map| map.values().any(|m| m == peer_id))
}

/// True when we hold `master`'s roster and `device` is not one of its members: a
/// certificate its master key signed for a device the roster never admitted (design
/// ID-1). A master we hold no devices for is not judged here, so a group whose rosters
/// have not arrived yet keeps working on the certificate alone.
pub(crate) fn disowns(master: &str, device: &str) -> bool {
    if device == master {
        return is_bare_master(master);
    }
    let held = rostered().read().is_ok_and(|set| set.contains(master));
    links().read().is_ok_and(|map| {
        let known = held || map.iter().any(|(d, m)| m == master && d != master);
        known && map.get(device).map(String::as_str) != Some(master)
    })
}

/// True when `peer_id` is the id of a master whose roster we hold and that roster
/// does not count it as a device (G1). Whoever logs in as it holds the master key and
/// nothing more: a restored backup nobody approved, a removed install. It is no device
/// of anyone's; only the roster statements it carries count, since they verify alone.
pub(crate) fn is_bare_master(peer_id: &str) -> bool {
    rostered().read().is_ok_and(|set| set.contains(peer_id)) && !is_device_of(peer_id, peer_id)
}

/// True when `device` links to `master`: a member of the roster we hold for it. Unlike
/// [`resolve`], an id nobody links resolves to no one here, the master's own included.
pub(crate) fn is_device_of(device: &str, master: &str) -> bool {
    links().read().is_ok_and(|map| map.get(device).map(String::as_str) == Some(master))
}

/// Record that we hold `master`'s roster.
pub(crate) fn note_roster(master: &str) {
    if let Ok(mut set) = rostered().write()
        && set.insert(master.to_string())
    {
        changed();
    }
}

/// Record a verified (device → master) link. Idempotent.
#[cfg(test)]
pub(crate) fn update(device_peer_id: &str, master_peer_id: &str) {
    if let Ok(mut map) = links().write() {
        map.insert(device_peer_id.to_string(), master_peer_id.to_string());
    }
    changed();
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
    changed();
}

/// Seed our OWN devices to our master so self-checks recognise them before any
/// device list round-trips. The master id maps to itself only when it is one of
/// `device_peer_ids` (a pre-multi-device install, where device == master).
pub(crate) fn seed_self(master_peer_id: &str, device_peer_ids: &[String]) {
    if let Ok(mut map) = links().write() {
        for d in device_peer_ids {
            map.insert(d.clone(), master_peer_id.to_string());
        }
    }
    changed();
}

/// Warm the resolver from persisted device links. MUST run before the event loop
/// takes incoming messages, or early messages misattribute.
pub(crate) fn warm_from_links(pairs: &[(String, String)]) {
    if let Ok(mut map) = links().write() {
        for (device, master) in pairs {
            map.insert(device.clone(), master.clone());
        }
    }
    changed();
}

/// Warm every process-global trust set from the store: device links, enforced
/// revocations and the block list. Every process that judges inbound frames (the
/// main node, the push fetch node, the iOS extension) runs this first.
pub(crate) fn warm_from_store(store: &crate::storage::MessageStore) {
    if let Ok(links) = store.get_all_device_links() {
        warm_from_links(&links);
    }
    if let Ok(masters) = store.rostered_masters() {
        for master in &masters {
            note_roster(master);
        }
    }
    if let Ok(revoked) = store.get_all_revoked_devices() {
        mark_revoked(&revoked);
    }
    if let Ok(blocked) = store.load_blocked_peers() {
        super::blocklist::warm(&blocked);
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
    changed();
}

/// Mark device ids revoked for this process: DMs, typing and key exchange refuse
/// them. Persist through `record_revoked_devices` as well.
pub(crate) fn mark_revoked(device_peer_ids: &[String]) {
    if let Ok(mut set) = revoked().write() {
        for d in device_peer_ids {
            set.insert(d.clone());
        }
    }
}

/// Lift the mark from devices a recovery brought back.
pub(crate) fn unmark_revoked(device_peer_ids: &[String]) {
    if let Ok(mut set) = revoked().write() {
        for d in device_peer_ids {
            set.remove(d);
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

/// What a node that never met `id` knows of it: no link, and no roster held for it.
/// The harness shares one resolver between its nodes, so [`forget`] alone still leaves
/// the roster mark another node's ingest set.
#[cfg(test)]
pub(crate) fn forget_for_test(id: &str) {
    forget(id);
    if let Ok(mut set) = rostered().write() {
        set.remove(id);
    }
    changed();
}

#[cfg(test)]
pub(crate) fn clear_for_test() {
    clear_all();
}

/// Clear the in-memory resolver between tests.
#[cfg(test)]
pub(crate) fn clear_all() {
    if let Ok(mut map) = links().write() {
        map.clear();
    }
    if let Ok(mut set) = revoked().write() {
        set.clear();
    }
    if let Ok(mut set) = rostered().write() {
        set.clear();
    }
    changed();
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

    #[test]
    fn unmark_lifts_only_the_named_devices() {
        let _g = guarded();
        mark_revoked(&["devX".into(), "devY".into()]);
        unmark_revoked(&["devX".into()]);
        assert!(!is_revoked("devX"));
        assert!(is_revoked("devY"));
    }

    /// A master whose devices we hold disowns every other device claiming it; one we
    /// hold nothing for is not judged, and a single-device identity is its own device.
    #[test]
    fn disowns_judges_only_a_known_master() {
        let _g = guarded();
        update_many("M", ["devA"]);
        assert!(disowns("M", "devStolen"), "a device the roster does not name");
        assert!(!disowns("M", "devA"));
        assert!(!disowns("M", "M"), "no roster held: the master id is not judged");
        assert!(!disowns("Unknown", "devQ"), "nothing held for that master yet");
        update_many("M2", ["devB"]);
        assert!(disowns("M", "devB"), "another identity's device is not M's");
        note_roster("M");
        assert!(disowns("M", "M"), "G1: a held roster that does not count the master id");
        note_roster("L");
        update_many("L", ["L"]);
        assert!(!disowns("L", "L"), "a legacy install whose roster counts its master id");
        assert!(disowns("L", "devQ"), "a held roster judges every device, even one counting only its master id");
    }

    /// G1: the master id is a device only when the roster we hold counts it; seeding our
    /// own devices never makes it one.
    #[test]
    fn a_master_id_is_bare_only_under_a_roster_that_leaves_it_out() {
        let _g = guarded();
        seed_self("M", &["devA".into()]);
        assert!(!is_bare_master("M"), "no roster held for it");
        note_roster("M");
        assert!(is_bare_master("M"));
        assert!(!is_bare_master("devA"));
        assert!(!is_device_of("M", "M"));
        assert_eq!(resolve("M"), "M", "it still names the identity");
        seed_self("M", &["devA".into(), "M".into()]);
        assert!(!is_bare_master("M"), "a legacy seat");
        forget("M");
        assert!(is_bare_master("M"));
    }
}
