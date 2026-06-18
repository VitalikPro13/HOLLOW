use std::collections::HashMap;
use std::sync::{OnceLock, Mutex};
use std::time::Instant;

use base64::Engine;
use tokio::sync::mpsc;

use crate::crypto::{CryptoStore, MlsManager, OlmManager};
use super::types::*;

/// Per-sibling cooldown for multi-device DM backfill requests (Step 5.1).
/// Sibling detection fires from TWO independent paths (the swarm.rs inbox-proof
/// AND `ingest_sibling_device_list`), and each re-fires on reconnect — so without
/// a cooldown one sibling-appearance triggers 2-4 full `DmSiblingSyncRequest`s,
/// each making the responder sweep EVERY conversation. This collapses the burst:
/// at most one request per sibling per `SIBLING_BACKFILL_COOLDOWN`. The pull is
/// still incremental (per-convo high-water) + idempotent, so a skipped redundant
/// request loses nothing — the next genuine reconnect past the cooldown re-syncs.
static SIBLING_BACKFILL_LAST: OnceLock<Mutex<HashMap<String, Instant>>> = OnceLock::new();
const SIBLING_BACKFILL_COOLDOWN: std::time::Duration = std::time::Duration::from_secs(15);

/// Send a `DmSiblingSyncRequest` to a sibling device, throttled per-sibling so the
/// two detection paths + reconnect re-fires collapse into one. Shared by BOTH
/// trigger sites (swarm.rs inbox-proof + `ingest_sibling_device_list`) so the
/// cooldown can't be bypassed. Reads our per-conversation high-water marks from
/// the DB and asks the sibling for anything newer across all conversations.
pub(crate) fn request_sibling_dm_backfill(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    sibling_peer_id: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    {
        let map = SIBLING_BACKFILL_LAST.get_or_init(|| Mutex::new(HashMap::new()));
        let mut guard = match map.lock() {
            Ok(g) => g,
            Err(p) => p.into_inner(), // poison-safe
        };
        if let Some(last) = guard.get(sibling_peer_id) {
            if last.elapsed() < SIBLING_BACKFILL_COOLDOWN {
                return; // within cooldown — the recent request still covers us
            }
        }
        guard.insert(sibling_peer_id.to_string(), Instant::now());
    }

    let per_convo_since: Vec<(String, i64)> =
        match crate::storage::MessageStore::open(db_path, db_passphrase) {
            Ok(store) => store.get_dm_peer_ids()
                .into_iter()
                .map(|c| {
                    let ts = store
                        .get_latest_dm_timestamp_any(&c)
                        .unwrap_or(None)
                        .unwrap_or(0);
                    (c, ts)
                })
                .collect(),
            Err(_) => Vec::new(),
        };
    hollow_log!(
        "[HOLLOW-SYNC] Requesting sibling DM backfill from {sibling_peer_id} ({} known convo(s))",
        per_convo_since.len()
    );
    send_message_to_peer(
        ws_cmd_tx, ws_room_peers,
        sibling_peer_id, HavenMessage::DmSiblingSyncRequest { per_convo_since },
    );
}

// -- Per-message Ed25519 signing helpers --

/// Build canonical payload for message signing.
/// Format: "hollow-msg:{type}:{context}:{sender}:{ts}:{text}"
/// - Channel: type="ch", context="{sid}:{cid}"
/// - DM:      type="dm", context="{recipient_peer_id}"
pub(crate) fn message_signing_payload(
    msg_type: &str,
    context: &str,
    sender: &str,
    ts: i64,
    text: &str,
) -> String {
    format!("hollow-msg:{msg_type}:{context}:{sender}:{ts}:{text}")
}

// -- Multi-device signed device list (Phase 6) --

/// Canonical payload for signing a device list.
/// Format:
/// "hollow-devices:{master_peer_id}:{version}:{sorted_device_csv}:{sorted_revoked_csv}".
/// Both `devices` and `revoked` MUST be sorted before calling so the payload is
/// deterministic. The trailing `:{revoked_csv}` segment is present even when
/// `revoked` is empty (Step 7) — one signature thus covers adds AND removes under
/// one version. NOTE: this means a pre-Step-7 4-segment signature will not verify
/// under this code; safe because lists are verified ONLY at receive time and stored
/// lists keep their incoming sig (never re-verified), so both ends ship together.
pub(crate) fn device_list_signing_payload(
    master_peer_id: &str,
    version: u64,
    devices: &[String],
    revoked: &[String],
) -> String {
    format!(
        "hollow-devices:{master_peer_id}:{version}:{}:{}",
        devices.join(","),
        revoked.join(",")
    )
}

/// Build a master-signed [`SignedDeviceList`] for the given device peer_ids and
/// revoked tombstones. `master` is the master keypair (the cross-device identity).
/// Both `devices` and `revoked` are sorted/deduped internally so the signed payload
/// is canonical. Any id present in `revoked` is removed from `devices` (a revoked id
/// can never coexist as an active device).
pub(crate) fn build_signed_device_list(
    master: &crate::identity::native_identity::NativeKeypair,
    version: u64,
    mut devices: Vec<String>,
    mut revoked: Vec<String>,
) -> SignedDeviceList {
    use base64::engine::general_purpose::STANDARD as B64;
    revoked.sort();
    revoked.dedup();
    // A revoked id is never an active device.
    devices.retain(|d| !revoked.iter().any(|r| r == d));
    devices.sort();
    devices.dedup();
    let master_peer_id = master.peer_id();
    let payload = device_list_signing_payload(&master_peer_id, version, &devices, &revoked);
    let sig = master.sign(payload.as_bytes());
    SignedDeviceList {
        master_pubkey_b64: B64.encode(master.public_key_protobuf()),
        master_peer_id,
        devices,
        revoked,
        version,
        sig_b64: B64.encode(sig),
    }
}

/// Verify a received [`SignedDeviceList`]: the master pubkey must derive to the
/// claimed `master_peer_id`, and the signature must validate over the canonical
/// payload. Does NOT enforce version monotonicity — that is the DB layer's job
/// (it has the previously-seen version). Returns true iff cryptographically sound.
pub(crate) fn verify_device_list(list: &SignedDeviceList) -> bool {
    use base64::engine::general_purpose::STANDARD as B64;
    use crate::identity::native_identity::NativeKeypair;

    let Ok(pk_bytes) = B64.decode(&list.master_pubkey_b64) else {
        return false;
    };
    // Bind pubkey → claimed master peer_id.
    match NativeKeypair::peer_id_from_pubkey_protobuf(&pk_bytes) {
        Some(derived) if derived == list.master_peer_id => {}
        _ => return false,
    }
    let Ok(sig_bytes) = B64.decode(&list.sig_b64) else {
        return false;
    };
    // Devices AND revoked must be sorted as signed; verify over the canonical
    // payload using sorted copies so an attacker can't reorder/strip either array
    // post-signing.
    let mut devices = list.devices.clone();
    devices.sort();
    let mut revoked = list.revoked.clone();
    revoked.sort();
    let payload =
        device_list_signing_payload(&list.master_peer_id, list.version, &devices, &revoked);
    NativeKeypair::verify_peer_signature(&pk_bytes, &sig_bytes, payload.as_bytes())
        .unwrap_or(false)
}

/// Build OUR OWN master-signed device list to attach to outbound profile syncs.
///
/// Reads the current device set + version persisted under our master peer_id and
/// re-signs it with the master key. On a brand-new/single-device install the set
/// is just `[device_peer_id]`; QR-linking (Step 4) adds devices and bumps the
/// version. If we have never persisted a self list yet, this seeds version 1 with
/// the single local device and persists it so future reads are monotonic.
///
/// Returns `None` only if the DB is unavailable — callers send the profile
/// without a device list in that case (back-compat, no crash).
pub(crate) fn build_local_device_list(
    master: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    db_path: &str,
    db_passphrase: &str,
) -> Option<SignedDeviceList> {
    let store = crate::storage::MessageStore::open(db_path, db_passphrase).ok()?;
    let master_peer_id = master.peer_id();

    // Load whatever we've persisted for ourselves (devices + revoked + version).
    // Absent = first run → seed version 1 with just this device, no revocations.
    let (devices, revoked, version) = match store.load_device_list(&master_peer_id) {
        Ok(Some(list)) => {
            // Ensure THIS device is in the set (migration/first-publish safety) and
            // never tombstoned (we can't revoke the device we're running on).
            let mut revoked = list.revoked.clone();
            revoked.retain(|r| r != device_peer_id);
            let mut devs = list.devices.clone();
            let self_added = !devs.iter().any(|d| d == device_peer_id);
            if self_added {
                devs.push(device_peer_id.to_string());
            }
            // Membership changed → bump version so peers accept the update.
            if self_added || revoked.len() != list.revoked.len() {
                (devs, revoked, list.version.saturating_add(1))
            } else {
                (devs, revoked, list.version.max(1))
            }
        }
        _ => (vec![device_peer_id.to_string()], Vec::new(), 1),
    };

    let signed = build_signed_device_list(master, version, devices, revoked);

    // Persist our own list so device_list_version() stays monotonic across
    // restarts and the resolver warms our own devices on next boot.
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    if let Ok(json) = serde_json::to_string(&signed) {
        let _ = store.save_device_list(
            &signed.master_peer_id, &json, signed.version, &signed.devices, now,
        );
    }
    // Keep the resolver in sync with our own devices immediately.
    super::resolver::seed_self(&signed.master_peer_id, &signed.devices);

    Some(signed)
}

/// Revoke one of OUR OWN devices (Step 7). Mutates our master-signed device list:
/// removes `target_device` from `devices`, adds it to `revoked` (tombstone), bumps
/// the version, re-signs with the master key, persists, prunes the resolver. Returns
/// the freshly re-signed list (`None` on a guard failure or DB error).
///
/// Guards: refuses to revoke the device we're running on (`local_device_peer_id`),
/// and refuses an id that does not currently belong to us (not in our `devices` and
/// not already a resolver-known device of our master). Idempotent for an id already
/// revoked (returns the current signed list unchanged in `revoked`).
pub(crate) fn revoke_own_device(
    master: &crate::identity::native_identity::NativeKeypair,
    local_device_peer_id: &str,
    target_device: &str,
    db_path: &str,
    db_passphrase: &str,
) -> Option<SignedDeviceList> {
    if target_device == local_device_peer_id {
        hollow_log!("[HOLLOW-REVOKE] Refused to revoke the device we are running on");
        return None;
    }
    let store = crate::storage::MessageStore::open(db_path, db_passphrase).ok()?;
    let master_peer_id = master.peer_id();
    let (mut devices, mut revoked, version): (Vec<String>, Vec<String>, u64) =
        match store.load_device_list(&master_peer_id) {
            Ok(Some(list)) => (list.devices.clone(), list.revoked.clone(), list.version),
            _ => (vec![local_device_peer_id.to_string()], Vec::new(), 0),
        };
    // Ensure THIS device stays present (never tombstoned).
    if !devices.iter().any(|d| d == local_device_peer_id) {
        devices.push(local_device_peer_id.to_string());
    }
    // The target must be one of OUR devices (in the active set, or a resolver-known
    // device of our master — covers a live device id not yet folded into the list).
    let belongs = devices.iter().any(|d| d == target_device)
        || super::resolver::resolve(target_device) == master_peer_id;
    if !belongs {
        hollow_log!("[HOLLOW-REVOKE] Refused to revoke {target_device}: not one of our devices");
        return None;
    }
    if revoked.iter().any(|r| r == target_device) && !devices.iter().any(|d| d == target_device) {
        // Already revoked and not active — nothing to change. Re-sign current state
        // so the caller still has a list to re-announce (idempotent).
        let signed = build_signed_device_list(master, version.max(1), devices, revoked);
        super::resolver::seed_self(&signed.master_peer_id, &signed.devices);
        return Some(signed);
    }
    devices.retain(|d| d != target_device);
    if !revoked.iter().any(|r| r == target_device) {
        revoked.push(target_device.to_string());
    }
    let next_version = version.saturating_add(1).max(1);
    let signed = build_signed_device_list(master, next_version, devices, revoked);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    let json = serde_json::to_string(&signed).ok()?;
    if let Err(e) = store.save_device_list(
        &signed.master_peer_id, &json, signed.version, &signed.devices, now,
    ) {
        hollow_log!("[HOLLOW-REVOKE] Failed to persist revocation: {e}");
        return None;
    }
    // Drop the revoked device from the in-memory resolver, then re-seed our survivors.
    super::resolver::forget(target_device);
    // Phantom-chat guard on the revoker too: drop any lingering DMs/typing from the
    // device we just revoked until it self-nukes / disconnects.
    super::resolver::mark_revoked(std::slice::from_ref(&target_device.to_string()));
    super::resolver::seed_self(&signed.master_peer_id, &signed.devices);
    hollow_log!(
        "[HOLLOW-REVOKE] Revoked own device {target_device} → list now {} devices, {} revoked (v{})",
        signed.devices.len(), signed.revoked.len(), signed.version
    );
    Some(signed)
}

/// Union a single sibling device id into OUR OWN master-signed device list.
///
/// Used by the inbox-proof path: a peer joining our own `inbox:{master}` room is,
/// by definition, our own device — but a freshly-imported sibling has no profile
/// and never sends a ProfileUpdate carrying a device list, so the normal
/// `ingest_sibling_device_list` merge never fires for it and our list would stay
/// at one device forever. This adds the proven sibling id directly: union, re-sign
/// with a bumped version, persist, seed the resolver. Returns `true` if the id was
/// new (so the caller re-announces our profile to friends).
pub(crate) fn merge_sibling_device_id(
    master: &crate::identity::native_identity::NativeKeypair,
    local_device_peer_id: &str,
    sibling_device_peer_id: &str,
    db_path: &str,
    db_passphrase: &str,
) -> bool {
    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else {
        return false;
    };
    let master_peer_id = master.peer_id();
    let (mut devices, revoked, version): (Vec<String>, Vec<String>, u64) =
        match store.load_device_list(&master_peer_id) {
            Ok(Some(list)) => (list.devices.clone(), list.revoked.clone(), list.version),
            _ => (vec![local_device_peer_id.to_string()], Vec::new(), 0),
        };
    if !devices.iter().any(|d| d == local_device_peer_id) {
        devices.push(local_device_peer_id.to_string());
    }
    // A revoked sibling id must never be re-admitted by the inbox proof — this is
    // the same-peer-id resurrection guard. A reinstalled phone comes back with a
    // FRESH random device id and so is not blocked here.
    if revoked.iter().any(|r| r == sibling_device_peer_id) {
        super::resolver::seed_self(&master_peer_id, &devices);
        return false;
    }
    if devices.iter().any(|d| d == sibling_device_peer_id) {
        // Already known — keep the resolver warm, but nothing to re-announce.
        super::resolver::seed_self(&master_peer_id, &devices);
        return false;
    }
    devices.push(sibling_device_peer_id.to_string());
    let next_version = version.saturating_add(1).max(1);
    let signed = build_signed_device_list(master, next_version, devices, revoked);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    if let Ok(json) = serde_json::to_string(&signed) {
        let _ = store.save_device_list(
            &signed.master_peer_id, &json, signed.version, &signed.devices, now,
        );
    }
    super::resolver::seed_self(&signed.master_peer_id, &signed.devices);
    hollow_log!(
        "[HOLLOW-DEVICES] Merged inbox sibling {sibling_device_peer_id} → own device set now {} (v{})",
        signed.devices.len(), signed.version
    );
    true
}

/// Outcome of ingesting a device list. The swarm call site consumes this to drive
/// crypto enforcement (Step 7) and self-re-announce.
/// - `our_devices_grew`: a sibling merge added one of OUR OWN device ids (caller
///   re-announces our profile so friends converge — the historical `bool` return).
/// - `newly_revoked`: device ids that became tombstoned THIS ingest. The caller
///   (which holds `&mut olm`/`&mut mls`) drops the Olm session to each and, if it
///   is the MLS coordinator for a shared server, enqueues the single leaf for
///   removal. Empty on every pre-Step-7 / single-device path.
#[derive(Default)]
pub(crate) struct IngestOutcome {
    pub our_devices_grew: bool,
    pub newly_revoked: Vec<String>,
}

/// Ingest a device list received on a peer's profile sync.
///
/// Verifies the signature, unions devices (replay-safe — see body), applies
/// revocation tombstones (Step 7, max-version-wins), and on a change persists it +
/// updates the resolver + emits `DeviceListUpdated`. A `None` list (old client, or
/// a self-profile we sent) is a no-op. A list for our OWN master goes to the
/// sibling-merge path (we are the authority for our own list, a friend can't
/// rewrite it — but a sibling can union into it).
pub(crate) async fn ingest_device_list(
    event_tx: &mpsc::Sender<NetworkEvent>,
    local_master_peer_id: &str,
    local_device_peer_id: &str,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    sender_peer_id: &str,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    list: Option<SignedDeviceList>,
    db_path: &str,
    db_passphrase: &str,
) -> IngestOutcome {
    let Some(list) = list else { return IngestOutcome::default() };
    if list.master_peer_id.is_empty() || list.devices.is_empty() {
        return IngestOutcome::default();
    }
    // Multi-device: a list for OUR OWN master came from one of our other devices
    // (a sibling, same imported mnemonic → same master key, so it is validly
    // signed). We must NOT blindly replace our list, but we MUST learn about the
    // sibling's device id — otherwise the resolver never maps sibling→master,
    // `same_identity` stays false, and neither sibling sync nor a friend's
    // device-collapse can work. Merge (union) the sibling's devices into ours,
    // re-sign with a bumped version, persist, update the resolver, re-publish so
    // friends converge on the full set, and (if the sibling is new) hand it our
    // friend list so it can join their DM rooms.
    if list.master_peer_id == local_master_peer_id {
        let (grew, newly_revoked) = ingest_sibling_device_list(
            event_tx, local_master_peer_id, local_device_peer_id, master_keypair,
            sender_peer_id, ws_cmd_tx, ws_room_peers, list, db_path, db_passphrase,
        ).await;
        return IngestOutcome { our_devices_grew: grew, newly_revoked };
    }
    if !verify_device_list(&list) {
        hollow_log!(
            "[HOLLOW-DEVICES] Rejected device list for {}: bad signature",
            list.master_peer_id
        );
        return IngestOutcome::default();
    }
    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else {
        return IngestOutcome::default();
    };
    // Load what we already hold for this master (devices + revoked + version).
    let (prev_devices, prev_revoked, prev_version): (Vec<String>, Vec<String>, u64) =
        match store.load_device_list(&list.master_peer_id) {
            Ok(Some(cur)) => (cur.devices.clone(), cur.revoked.clone(), cur.version),
            _ => (Vec::new(), Vec::new(), 0),
        };
    // TOMBSTONES — max-version-wins (Step 7). A higher-version list is the latest
    // master word and may both add AND un-revoke; a replay (version <= prev) keeps
    // our prev revoked set, so it can never shrink the tombstones (can't un-revoke).
    let new_revoked: Vec<String> = if list.version > prev_version {
        let mut r = list.revoked.clone();
        r.sort();
        r.dedup();
        r
    } else {
        prev_revoked.clone()
    };
    let is_revoked = |id: &str| new_revoked.iter().any(|r| r == id);
    // SELF-NUKE (Step 7): if THIS device appears in the revoked set, the identity has
    // cut us off. Tear ourselves down (Dart wipes the data dir + relaunches to a clean
    // Welcome). Defensive here — a friend's list is for a different master so this
    // normally never matches; the real path is the sibling merge below.
    if is_revoked(local_device_peer_id) {
        hollow_log!("[HOLLOW-REVOKE] This device was revoked (friend list) — self-nuking");
        let _ = event_tx.send(NetworkEvent::SelfRevoked).await;
        return IngestOutcome::default();
    }
    // Guard the DM/typing receive path against a just-revoked-but-still-alive device
    // (phantom-chat guard): mark every revoked id of this master so inbound messages
    // from it are dropped until it self-nukes / disconnects.
    if !new_revoked.is_empty() {
        super::resolver::mark_revoked(&new_revoked);
    }
    // Ids that became tombstoned THIS ingest (drive Olm/MLS enforcement at the caller).
    let newly_revoked: Vec<String> = new_revoked
        .iter()
        .filter(|r| !prev_revoked.iter().any(|p| &p == r))
        .cloned()
        .collect();
    // Register the SENDER device → master link. The list is master-signed and
    // arrived over this device's authenticated socket in the master's room, so
    // the delivering device provably belongs to that master EVEN IF it is not
    // (yet) listed in `list.devices`. SKIP if the sender is revoked (a revoked
    // device must not re-register itself by delivering a stale list).
    if sender_peer_id != list.master_peer_id && !is_revoked(sender_peer_id) {
        super::resolver::update(sender_peer_id, &list.master_peer_id);
    }
    // Fold the live sender device into the merge set too, so it's persisted and
    // surfaced to Dart (presence). A device that delivered a master-signed list IS
    // a member of that identity — unless it has been revoked.
    let sender_is_new_member = sender_peer_id != list.master_peer_id
        && !is_revoked(sender_peer_id)
        && !prev_devices.iter().any(|d| d == sender_peer_id);

    // UNION-merge MINUS tombstones, do NOT reject-on-stale. Two devices of one
    // identity each start their list at version 1, so a naive `version <= current`
    // guard makes the SECOND device's list look like a replay and drops it — the
    // friend then only ever learns ONE device (the "offline when the other device
    // is up" bug). Adding device ids is safe; REMOVAL is the signed `revoked` set.
    // So: union(prev, incoming) − new_revoked, keeping the highest version seen.
    let mut merged: Vec<String> = prev_devices.iter().filter(|d| !is_revoked(d)).cloned().collect();
    let mut known: std::collections::HashSet<String> = merged.iter().cloned().collect();
    let mut added = 0u32;
    for d in &list.devices {
        if !is_revoked(d) && !known.contains(d) {
            merged.push(d.clone());
            known.insert(d.clone());
            added += 1;
        }
    }
    // The delivering device proves membership — include it even if absent from the
    // signed `devices` (stale list / rotated id). Counts as "new" so we persist.
    if sender_is_new_member && !known.contains(sender_peer_id) {
        merged.push(sender_peer_id.to_string());
        added += 1;
    }
    // A revocation removed one or more of our previously-known devices.
    let removed_any = prev_devices.iter().any(|d| is_revoked(d));
    let revoked_changed = new_revoked.len() != prev_revoked.len();
    let nothing_new = added == 0 && !removed_any && !revoked_changed
        && list.version <= prev_version;
    if nothing_new {
        // Truly redundant on the RUST side (same/older list, no new devices) — skip
        // the DB write, but STILL re-warm the resolver AND emit DeviceListUpdated.
        // The event is the load-bearing part: Dart's `deviceLinkProvider` warms
        // ONCE at startup (event_provider) by pulling `get_device_links()`, which
        // RACES the Rust resolver warm-up (`warm_from_links` from `device_links`).
        // If Dart wins that race it caches an empty/partial map and, because a
        // redundant re-ingest used to return here WITHOUT an event, it never
        // refreshed again — so a friend whose device id ≠ master (rotated keystone,
        // e.g. AL = device BVoC / master JJU9) showed OFFLINE until a manual Device
        // List reset forced a fresh (version-bumping) ingest. A peer re-sends its
        // (unchanged v1) list on every room join, so emitting here makes Dart
        // re-pull the now-warm map within seconds of every reconnect — the
        // self-heal that removes the need to ever reset. Cheap + idempotent.
        super::resolver::update_many(
            &list.master_peer_id,
            merged.iter().map(|s| s.as_str()),
        );
        let _ = event_tx.send(NetworkEvent::DeviceListUpdated {
            master_peer_id: list.master_peer_id.clone(),
        }).await;
        return IngestOutcome::default();
    }

    // Persist the union-minus-tombstones. We are NOT this master (self lists go
    // through the sibling path), so we cannot re-sign — store under the higher
    // version with the INCOMING signature/pubkey AND the resolved `new_revoked`
    // set. Verification on re-broadcast is sender-side; observers trust the
    // per-device profile sig path.
    let version = prev_version.max(list.version).max(1);
    let stored = SignedDeviceList {
        master_pubkey_b64: list.master_pubkey_b64.clone(),
        master_peer_id: list.master_peer_id.clone(),
        devices: merged.clone(),
        revoked: new_revoked.clone(),
        version,
        sig_b64: list.sig_b64.clone(),
    };
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    let json = match serde_json::to_string(&stored) {
        Ok(j) => j,
        Err(_) => return IngestOutcome::default(),
    };
    // save_device_list rebuilds the device_links reverse index from `devices`, so a
    // revoked id (now absent from `merged`) is dropped from device_links for free.
    if let Err(e) = store.save_device_list(
        &stored.master_peer_id, &json, stored.version, &stored.devices, now,
    ) {
        hollow_log!("[HOLLOW-DEVICES] Failed to save device list: {e}");
        return IngestOutcome::default();
    }
    // Prune the in-memory resolver for revoked ids (the map is insert-only; without
    // this a revoked device keeps resolving to its master until restart), then warm
    // the surviving devices so attribution/self-checks pick them up at once.
    if !new_revoked.is_empty() {
        super::resolver::forget_many(&new_revoked);
    }
    super::resolver::update_many(
        &stored.master_peer_id,
        stored.devices.iter().map(|s| s.as_str()),
    );
    hollow_log!(
        "[HOLLOW-DEVICES] Ingested device list for {} (v{}, {} devices, {} revoked, +{} new)",
        stored.master_peer_id, stored.version, stored.devices.len(),
        stored.revoked.len(), added
    );
    let _ = event_tx.send(NetworkEvent::DeviceListUpdated {
        master_peer_id: stored.master_peer_id,
    }).await;
    // A FRIEND's device set changed — no self re-broadcast needed (that's for our
    // OWN sibling merges, handled on the self path above). Surface any freshly
    // revoked ids so the caller drops Olm sessions + removes MLS leaves.
    IngestOutcome { our_devices_grew: false, newly_revoked }
}

/// Merge a sibling device's list (for our OWN master) into ours.
///
/// The sibling holds the same master key (imported mnemonic), so its list is
/// validly signed by our master. We take the UNION of device ids — never a
/// removal (removal = revocation, Step 7) — re-sign with a bumped version,
/// persist, update the resolver, and re-publish to friends so they converge on
/// the full device set (fixes the v1-vs-v1 collision where a friend only ever
/// learned ONE of two devices). When the merge reveals a brand-new sibling
/// device, we also hand it our accepted-friend list so it can join their DM
/// rooms (presence on-ramp, Step 2.5).
/// Returns `(our_devices_grew_or_revoked, newly_revoked)`. The first is `true` if
/// OUR OWN list changed (device added OR a tombstone applied) so callers re-broadcast
/// our profile to friends; the second is device ids freshly tombstoned this merge so
/// the caller drops their Olm sessions + removes MLS leaves.
#[allow(clippy::too_many_arguments)]
async fn ingest_sibling_device_list(
    event_tx: &mpsc::Sender<NetworkEvent>,
    local_master_peer_id: &str,
    local_device_peer_id: &str,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    sender_peer_id: &str,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    list: SignedDeviceList,
    db_path: &str,
    db_passphrase: &str,
) -> (bool, Vec<String>) {
    // The list claims our master — verify it's actually signed by our master key
    // (a forgery would fail; only a real sibling holding the mnemonic can sign).
    if !verify_device_list(&list) {
        hollow_log!(
            "[HOLLOW-DEVICES] Rejected sibling device list from {sender_peer_id}: bad signature"
        );
        return (false, Vec::new());
    }
    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else {
        return (false, Vec::new());
    };

    // Our currently-known device set (+ revoked + version) for our master.
    let (mut devices, our_revoked, our_version): (Vec<String>, Vec<String>, u64) =
        match store.load_device_list(local_master_peer_id) {
            Ok(Some(cur)) => (cur.devices.clone(), cur.revoked.clone(), cur.version),
            _ => (vec![local_device_peer_id.to_string()], Vec::new(), 0),
        };
    // Always include ourselves.
    if !devices.iter().any(|d| d == local_device_peer_id) {
        devices.push(local_device_peer_id.to_string());
    }

    // TOMBSTONES — max-version-wins (Step 7). A sibling's higher-version list is the
    // latest master word (it holds the same master key, all our devices are equal):
    // adopt its revoked set; otherwise keep ours (replay can't un-revoke). We never
    // revoke the device we're running on.
    // SELF-NUKE (Step 7): a sibling (same master key, equal authority) revoked THIS
    // device — our own id is in a HIGHER-version signed revoked set. The identity has
    // cut us off; tear ourselves down (Dart wipes the data dir + relaunches to a clean
    // Welcome). Check the INCOMING revoked set BEFORE we strip self below — we never
    // tombstone ourselves in our OWN published list, but we DO obey a sibling's order.
    if list.version > our_version && list.revoked.iter().any(|r| r == local_device_peer_id) {
        hollow_log!("[HOLLOW-REVOKE] This device was revoked by a sibling (v{} > v{}) — self-nuking", list.version, our_version);
        let _ = event_tx.send(NetworkEvent::SelfRevoked).await;
        return (false, Vec::new());
    }

    let mut merged_revoked: Vec<String> = if list.version > our_version {
        list.revoked.clone()
    } else {
        our_revoked.clone()
    };
    merged_revoked.retain(|r| r != local_device_peer_id);
    merged_revoked.sort();
    merged_revoked.dedup();
    // Phantom-chat guard: mark revoked ids so inbound DMs/typing from a still-alive
    // revoked sibling are dropped until it self-nukes / disconnects.
    if !merged_revoked.is_empty() {
        super::resolver::mark_revoked(&merged_revoked);
    }
    let is_revoked = |id: &str| merged_revoked.iter().any(|r| r == id);
    let newly_revoked: Vec<String> = merged_revoked
        .iter()
        .filter(|r| !our_revoked.iter().any(|p| &p == r))
        .cloned()
        .collect();

    // Union in the sibling's devices, MINUS tombstones; also drop any of our own
    // previously-known devices that are now revoked.
    devices.retain(|d| !is_revoked(d));
    let before: std::collections::HashSet<String> = devices.iter().cloned().collect();
    for d in &list.devices {
        if !is_revoked(d) && !before.contains(d) {
            devices.push(d.clone());
        }
    }

    // Prune the resolver for revoked ids, then learn the surviving union NOW (cheap,
    // keeps same_identity correct after a restart even when nothing changed).
    if !merged_revoked.is_empty() {
        super::resolver::forget_many(&merged_revoked);
    }
    super::resolver::update_many(
        local_master_peer_id,
        devices.iter().map(|s| s.as_str()),
    );

    let removed_any = our_revoked.len() != merged_revoked.len();
    let changed = devices.len() != before.len() || removed_any;
    if changed {
        // Re-sign the merged set with a version strictly greater than both ours
        // and the sibling's, so every observer (and the sibling) accepts it.
        let next_version = our_version.max(list.version).saturating_add(1);
        let signed = build_signed_device_list(
            master_keypair, next_version, devices, merged_revoked.clone(),
        );
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        if let Ok(json) = serde_json::to_string(&signed) {
            let _ = store.save_device_list(
                &signed.master_peer_id, &json, signed.version, &signed.devices, now,
            );
        }
        super::resolver::seed_self(&signed.master_peer_id, &signed.devices);
        hollow_log!(
            "[HOLLOW-MULTIDEV] Merged sibling {sender_peer_id} → device set now {} ({} revoked, v{})",
            signed.devices.len(), signed.revoked.len(), signed.version
        );

        // The merged list is now persisted. We RETURN `changed=true` so the caller
        // (the ProfileUpdate handler, which HAS profile context) re-broadcasts our
        // profile to all current room peers — friends converge on the full device
        // set WHILE we're online, instead of only when our substitute device later
        // joins their DM room (racy, and too late if our original device quits).
        let _ = event_tx.send(NetworkEvent::DeviceListUpdated {
            master_peer_id: signed.master_peer_id,
        }).await;
    }

    // Hand our friend list to the sibling that JUST contacted us (the live
    // `sender_peer_id`), not to whichever ids look "new" in the merged list.
    // Gating on list-diff was fragile: across repeated wipe+reimport tests the
    // stored list accumulates dead device ids, so a reconnecting sibling can
    // already be "known" → no send → the fresh device never gets the friends.
    // The connected sender is the device that actually needs them right now, and
    // the receiver is idempotent (skips friends it already has), so an
    // occasional redundant send is harmless. Skip if the sender is OUR own device
    // id (shouldn't happen — self lists don't reach here) OR if it is revoked (a
    // revoked sibling must not be handed our friend list / pulled from).
    if sender_peer_id != local_device_peer_id && !is_revoked(sender_peer_id) {
        if let Ok(friends) = store.load_friends(Some("accepted")) {
            if !friends.is_empty() {
                let entries: Vec<FriendListEntry> = friends
                    .into_iter()
                    .map(|(pid, status, direction, requested_at, _u)| FriendListEntry {
                        peer_id: pid, status, direction, requested_at,
                    })
                    .collect();
                hollow_log!(
                    "[HOLLOW-MULTIDEV] Sharing {} friends with sibling {sender_peer_id}",
                    entries.len()
                );
                send_message_to_peer(
                    ws_cmd_tx, ws_room_peers,
                    sender_peer_id, HavenMessage::FriendListSync { friends: entries.clone() },
                );
            }
        }
        // Also PULL: ask the sibling for ITS friends. Covers the case where WE
        // are the fresh/empty device and the sibling's push didn't reach us (join
        // timing). Responder replies with FriendListSync. Idempotent + cheap.
        hollow_log!("[HOLLOW-MULTIDEV] Requesting friend list from sibling {sender_peer_id}");
        send_message_to_peer(
            ws_cmd_tx, ws_room_peers,
            sender_peer_id, HavenMessage::FriendListRequest,
        );

        // Multi-device backfill (Step 5): also ask this live sibling for our missed
        // DM history. CRITICAL — sibling detection has TWO paths: the swarm.rs
        // `inbox:{master}` join-proof AND this device-list-ingest (fired by a
        // ProfileUpdate carrying a device list). A sibling may be detected via
        // EITHER, so the DM-backfill request must fire from BOTH or it silently
        // never runs (e.g. when the device list arrives before/without an inbox
        // join). `request_sibling_dm_backfill` throttles per-sibling so the two
        // paths + reconnect re-fires collapse into one request (Step 5.1).
        request_sibling_dm_backfill(
            ws_cmd_tx, ws_room_peers, sender_peer_id, db_path, db_passphrase,
        );
    }

    (changed, newly_revoked)
}

/// Sign a message payload with the local keypair.
/// Returns (signature_base64, public_key_base64).
pub(crate) fn sign_message(
    keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    payload: &str,
) -> (Option<String>, Option<String>) {
    let sig = keypair.sign(payload.as_bytes());
    let sig_b64 = base64::engine::general_purpose::STANDARD.encode(&sig);
    (Some(sig_b64), Some(pub_key_b64.to_string()))
}

/// Verify an Ed25519 signature on a message.
/// Checks: public key decodes, PeerId matches sender, signature is valid.
pub(crate) fn verify_message_signature(
    sender_peer_str: &str,
    sig_b64: Option<&str>,
    pk_b64: Option<&str>,
    payload: &str,
) -> bool {
    use crate::identity::native_identity::NativeKeypair;

    let (sig, pk) = match (sig_b64, pk_b64) {
        (Some(s), Some(p)) => (s, p),
        _ => return false,
    };

    let Ok(pk_bytes) = base64::engine::general_purpose::STANDARD.decode(pk) else {
        return false;
    };

    // Verify PeerId matches the public key (derive PeerId from pubkey protobuf).
    if pk_bytes.len() >= 36 && pk_bytes[0] == 0x08 && pk_bytes[1] == 0x01 {
        // Build a temporary NativeKeypair-style PeerId from the pubkey protobuf.
        let mut multihash = Vec::with_capacity(2 + pk_bytes.len());
        multihash.push(0x00); // Identity multihash code
        multihash.push(pk_bytes.len() as u8);
        multihash.extend_from_slice(&pk_bytes);
        let derived_pid = bs58::encode(&multihash).with_alphabet(bs58::Alphabet::BITCOIN).into_string();
        if derived_pid != sender_peer_str {
            return false;
        }
    } else {
        return false;
    }

    // Verify the signature.
    let Ok(sig_bytes) = base64::engine::general_purpose::STANDARD.decode(sig) else {
        return false;
    };
    NativeKeypair::verify_peer_signature(&pk_bytes, &sig_bytes, payload.as_bytes())
        .unwrap_or(false)
}

/// Batch-optimized variant that caches decoded+verified pk_bytes across calls.
/// The cache maps pk_b64 → pk_bytes (only inserted after PeerId derivation succeeds).
pub(crate) fn verify_message_signature_cached(
    sender_peer_str: &str,
    sig_b64: Option<&str>,
    pk_b64: Option<&str>,
    payload: &str,
    pk_cache: &mut HashMap<String, Vec<u8>>,
) -> bool {
    use crate::identity::native_identity::NativeKeypair;

    let (sig, pk) = match (sig_b64, pk_b64) {
        (Some(s), Some(p)) => (s, p),
        _ => return false,
    };

    let pk_bytes = if let Some(cached) = pk_cache.get(pk) {
        cached.clone()
    } else {
        let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(pk) else {
            return false;
        };
        if bytes.len() >= 36 && bytes[0] == 0x08 && bytes[1] == 0x01 {
            let mut multihash = Vec::with_capacity(2 + bytes.len());
            multihash.push(0x00);
            multihash.push(bytes.len() as u8);
            multihash.extend_from_slice(&bytes);
            let derived_pid = bs58::encode(&multihash).with_alphabet(bs58::Alphabet::BITCOIN).into_string();
            if derived_pid != sender_peer_str {
                return false;
            }
        } else {
            return false;
        }
        pk_cache.insert(pk.to_string(), bytes.clone());
        bytes
    };

    let Ok(sig_bytes) = base64::engine::general_purpose::STANDARD.decode(sig) else {
        return false;
    };
    NativeKeypair::verify_peer_signature(&pk_bytes, &sig_bytes, payload.as_bytes())
        .unwrap_or(false)
}

/// Persist MLS state (signer + credential + storage) via the CryptoStore actor.
pub(crate) fn persist_mls_state(mls: &MlsManager, crypto_store: &crate::crypto::CryptoStore) {
    let signer = match mls.signer_bytes() {
        Ok(s) => s,
        Err(e) => { hollow_log!("[HOLLOW-MLS] Failed to serialize signer: {e}"); return; }
    };
    let cred = match mls.credential_bytes() {
        Ok(c) => c,
        Err(e) => { hollow_log!("[HOLLOW-MLS] Failed to serialize credential: {e}"); return; }
    };
    let storage = match mls.serialize_storage() {
        Ok(s) => s,
        Err(e) => { hollow_log!("[HOLLOW-MLS] Failed to serialize storage: {e}"); return; }
    };
    crypto_store.save_mls_identity(signer, cred, storage);
}

/// Check if a peer is reachable via WS relay.
///
/// Multi-device (Phase 6): the relay reports DEVICE peer_ids in rooms, but the
/// caller often asks about a MASTER id (server members, friends). A master is
/// reachable if ANY of its devices is currently in a room. The fast path (exact
/// membership) covers the common single-device case with no resolver cost; the
/// slow path only runs when the exact id isn't present, and resolves room peers
/// to compare identities. `resolve()` returns the input unchanged for unknown
/// peers, so single-device behavior is unaffected.
pub(crate) fn peer_is_reachable(
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    peer_str: &str,
) -> bool {
    // Fast path: the exact id is in some room.
    if ws_room_peers.values().any(|peers| peers.contains(peer_str)) {
        return true;
    }
    // Slow path: is any connected device of the SAME identity present?
    let target_master = super::resolver::resolve(peer_str);
    // No links for this peer (resolve == self) → fast path already settled it.
    if target_master == peer_str {
        return false;
    }
    ws_room_peers.values().any(|peers| {
        peers.iter().any(|p| super::resolver::resolve(p) == target_master)
    })
}

/// Multi-device: the set of LIVE device peer_ids (currently in some WS room) that
/// belong to the same identity as `peer_str`. `peer_str` may be a master id (the
/// friend-list/UI key — no socket authenticates as it) or a device id; either way
/// this returns the concrete online devices to actually send to.
///
/// Used by every TARGETED P2P-signaling send that the UI addresses by master id
/// (call signaling, WebRTC offer/answer/ICE, file requests). Without it those
/// sends hit the bare master, which no socket authenticates as, and are silently
/// dropped — the whole class of "calls/files don't reach a multi-device peer" bug.
///
/// Single-device parity: if `peer_str` is itself online (the exact id is in a
/// room) it's returned as-is, so a pre-multi-device peer (device == master) is
/// handled identically to before. If NOTHING is online for the identity the vec
/// is empty and the caller can fall back to the raw id (offline send / queue).
pub(crate) fn online_devices_for(
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    peer_str: &str,
) -> Vec<String> {
    let master = super::resolver::resolve(peer_str);
    let mut set: std::collections::HashSet<String> = std::collections::HashSet::new();
    for peers in ws_room_peers.values() {
        for p in peers {
            // Match the exact id OR any device that resolves to the same master.
            if p == peer_str || super::resolver::resolve(p) == master {
                set.insert(p.clone());
            }
        }
    }
    // Never include the bare master (no socket authenticates as it).
    set.remove(&master);
    set.into_iter().collect()
}

/// Collapse a list of online MLS leaf credential ids (device ids, post-Step-6;
/// or master ids for legacy leaves) into the SORTED, deduped set of distinct
/// MASTER identities that are online. `local_peer` (the master) is always
/// treated as online. A member is online if it (or any sibling device) is
/// reachable. Used by the coordinator elections so a human with N leaves counts
/// ONCE and the election is stable per-identity rather than per-device.
fn online_master_identities(
    mls_members: &[String],
    local_peer: &str,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) -> Vec<String> {
    let mut masters: Vec<String> = mls_members
        .iter()
        .filter(|p| p.as_str() == local_peer || peer_is_reachable(ws_room_peers, p))
        .map(|p| super::resolver::resolve(p))
        .collect();
    // `local_peer` is the master and always counts as online (it may not appear
    // in `mls_members` if our own leaf is device-credentialed — group_members
    // returns the device id, which resolves back to us, but be explicit).
    masters.push(local_peer.to_string());
    masters.sort();
    masters.dedup();
    masters
}

/// Deterministic MLS coordinator: lowest MASTER identity among online MLS group
/// members (multi-device: device leaves collapse to their master, so one human
/// = one candidate). Returns the elected master id.
/// Security: only MLS group members participate — non-members can't become coordinator.
/// Testable without MlsManager dependency.
pub(crate) fn elect_coordinator(
    mls_members: &[String],
    local_peer: &str,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) -> Option<String> {
    let masters = online_master_identities(mls_members, local_peer, ws_room_peers);
    masters.into_iter().next()
}

pub(crate) fn is_mls_coordinator(
    mls: &MlsManager,
    server_id: &str,
    local_peer: &str,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) -> bool {
    if !mls.has_group(server_id) {
        return false;
    }
    let members = mls.group_members(server_id);
    elect_coordinator(&members, local_peer, ws_room_peers).as_deref() == Some(local_peer)
}

/// Vault coordinator: 2nd-lowest online MASTER identity (distributes work away
/// from the MLS coordinator). Falls back to lowest if only one identity is online.
pub(crate) fn elect_vault_coordinator(
    mls_members: &[String],
    local_peer: &str,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) -> Option<String> {
    let masters = online_master_identities(mls_members, local_peer, ws_room_peers);
    if masters.is_empty() {
        return None;
    }
    if masters.len() >= 2 {
        Some(masters[1].clone())
    } else {
        Some(masters[0].clone())
    }
}

pub(crate) fn is_vault_coordinator(
    mls: &MlsManager,
    server_id: &str,
    local_peer: &str,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) -> bool {
    if !mls.has_group(server_id) {
        return false;
    }
    let members = mls.group_members(server_id);
    elect_vault_coordinator(&members, local_peer, ws_room_peers).as_deref() == Some(local_peer)
}

/// Find a WS room containing the given peer.
pub(crate) fn ws_room_for_peer(
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    peer_str: &str,
) -> Option<String> {
    for (room, peers) in ws_room_peers {
        if peers.contains(peer_str) {
            return Some(room.clone());
        }
    }
    None
}

/// MLS-encrypt an envelope and broadcast to the server room via WS relay.
/// One encrypt → one WS send → relay fans out to all room members.
/// Returns Ok(()) on success, Err(reason) on failure (caller can fall back).
pub(crate) fn send_mls_broadcast(
    mls: &mut MlsManager,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    server_id: &str,
    envelope: &MessageEnvelope,
    crypto_store: &CryptoStore,
) -> Result<(), String> {
    let json = serde_json::to_string(envelope).map_err(|e| format!("serialize: {e}"))?;
    let ciphertext = mls.encrypt(server_id, json.as_bytes()).map_err(|e| format!("encrypt: {e}"))?;
    let body_b64 = base64::engine::general_purpose::STANDARD.encode(&ciphertext);
    persist_mls_state(mls, crypto_store);
    let msg = HavenMessage::MlsChannelMessage {
        server_id: server_id.to_string(),
        body: body_b64,
    };
    let data = serde_json::to_vec(&msg).map_err(|e| format!("serialize msg: {e}"))?;
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom {
        room_code: server_id.to_string(),
        data,
    });
    Ok(())
}

/// MLS-encrypt an envelope and broadcast to subscribed peers only (topic = channel_id).
/// Peers not subscribed to this topic won't receive the message in real-time
/// but will sync it when they navigate to the channel.
///
/// Returns the serialized `HavenMessage::MlsChannelMessage` wire bytes on
/// success so callers can re-deliver the SAME group ciphertext to offline
/// members (relay offline buffer via 0x09 frames) — MLS application messages
/// are decryptable by every member, so one encryption serves both paths.
pub(crate) fn send_mls_broadcast_topic(
    mls: &mut MlsManager,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    server_id: &str,
    topic: &str,
    envelope: &MessageEnvelope,
    crypto_store: &CryptoStore,
) -> Result<Vec<u8>, String> {
    let json = serde_json::to_string(envelope).map_err(|e| format!("serialize: {e}"))?;
    let ciphertext = mls.encrypt(server_id, json.as_bytes()).map_err(|e| format!("encrypt: {e}"))?;
    let body_b64 = base64::engine::general_purpose::STANDARD.encode(&ciphertext);
    persist_mls_state(mls, crypto_store);
    let msg = HavenMessage::MlsChannelMessage {
        server_id: server_id.to_string(),
        body: body_b64,
    };
    let data = serde_json::to_vec(&msg).map_err(|e| format!("serialize msg: {e}"))?;
    hollow_log!("[HOLLOW-TOPIC] Broadcast room={server_id} topic={topic} ({} bytes)", data.len());
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoomTopic {
        room_code: server_id.to_string(),
        topic: topic.to_string(),
        data: data.clone(),
    });
    Ok(data)
}

/// MLS-encrypt a targeted envelope and broadcast to the server room.
/// All members decrypt (keeping ratchets in sync) but only `target_peer` processes it.
/// Retained for backward compatibility — new code uses Olm+SendDirect instead.
#[allow(dead_code)]
pub(crate) fn send_mls_to_peer(
    mls: &mut MlsManager,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    server_id: &str,
    target_peer: &str,
    envelope: &MessageEnvelope,
    crypto_store: &CryptoStore,
) -> Result<(), String> {
    // Clone envelope and inject target — callers construct without target, we add it here.
    let mut json_value = serde_json::to_value(envelope).map_err(|e| format!("serialize: {e}"))?;
    if let Some(obj) = json_value.as_object_mut() {
        obj.insert("target".to_string(), serde_json::Value::String(target_peer.to_string()));
    }
    let json = serde_json::to_string(&json_value).map_err(|e| format!("re-serialize: {e}"))?;
    let ciphertext = mls.encrypt(server_id, json.as_bytes()).map_err(|e| format!("encrypt: {e}"))?;
    let body_b64 = base64::engine::general_purpose::STANDARD.encode(&ciphertext);
    let msg = HavenMessage::MlsChannelMessage {
        server_id: server_id.to_string(),
        body: body_b64,
    };
    let data = serde_json::to_vec(&msg).map_err(|e| format!("serialize msg: {e}"))?;
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom {
        room_code: server_id.to_string(),
        data,
    });
    Ok(())
}

/// Encrypt and send a message to a peer via WS relay.
/// Returns `true` on success, `false` if encryption failed.
pub(crate) async fn send_encrypted_message(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    peer_id_str: &str,
    text: &str,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) -> bool {
    match olm.encrypt(peer_id_str, text.as_bytes()) {
        Ok((msg_type, ciphertext)) => {
            persist_olm_session(olm, crypto_store, peer_id_str);

            if msg_type == 0 {
                hollow_log!("[HOLLOW-CRYPTO] Sending PreKey (type 0) to {peer_id_str}");
            }

            let identity_key = if msg_type == 0 {
                Some(olm.identity_key_base64())
            } else {
                None
            };

            let haven_msg = HavenMessage::Encrypted {
                message_type: msg_type,
                body: OlmManager::encode_base64(&ciphertext),
                identity_key,
            };

            if let Some(room) = ws_room_for_peer(ws_room_peers, peer_id_str) {
                let json = serde_json::to_string(&haven_msg).unwrap_or_default();
                let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
                    room_code: room,
                    target_peer: peer_id_str.to_string(),
                    data: json.into_bytes(),
                });
                true
            } else {
                hollow_log!("[HOLLOW-CRYPTO] Encrypted message for {peer_id_str} but peer unreachable — not delivered");
                false
            }
        }
        Err(e) => {
            let _ = event_tx
                .send(NetworkEvent::MessageSendFailed {
                    to_peer: peer_id_str.to_string(),
                    error: format!("Encryption failed: {e}"),
                })
                .await;
            false
        }
    }
}

/// Like `send_encrypted_message`, but routes through `SendDirectImage` (0x08)
/// so the relay buffers it under the per-peer IMAGE cap when the recipient is
/// offline. Used to deliver a small image's Olm-encrypted FileHeader (with the
/// bytes inlined) to an offline peer, so the FCM fetch node can render it.
///
/// CRITICAL: the caller passes the explicit `dm_room` (from `dm_room_code`),
/// NOT a `ws_room_for_peer` lookup. An OFFLINE peer is not a member of any room
/// in `ws_room_peers`, so a lookup returns None and the message is dropped —
/// which is exactly the deterministic DM-room code the relay needs to buffer it
/// (mirrors the offline text-DM path in message_ops.rs).
pub(crate) async fn send_encrypted_image_to_peer(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    peer_id_str: &str,
    dm_room: String,
    text: &str,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
) -> bool {
    match olm.encrypt(peer_id_str, text.as_bytes()) {
        Ok((msg_type, ciphertext)) => {
            persist_olm_session(olm, crypto_store, peer_id_str);
            let identity_key = if msg_type == 0 {
                Some(olm.identity_key_base64())
            } else {
                None
            };
            let haven_msg = HavenMessage::Encrypted {
                message_type: msg_type,
                body: OlmManager::encode_base64(&ciphertext),
                identity_key,
            };
            let json = serde_json::to_string(&haven_msg).unwrap_or_default();
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirectImage {
                room_code: dm_room,
                target_peer: peer_id_str.to_string(),
                data: json.into_bytes(),
            });
            true
        }
        Err(e) => {
            let _ = event_tx
                .send(NetworkEvent::MessageSendFailed {
                    to_peer: peer_id_str.to_string(),
                    error: format!("Encryption failed: {e}"),
                })
                .await;
            false
        }
    }
}

/// Send an Olm-encrypted TEXT DM directly to an explicit DM room (0x04), without
/// the `ws_room_for_peer` reachability check that `send_encrypted_message` does.
/// Used for the CAPTION of an offline image DM: the recipient is in no known
/// room, so the normal send drops it — but the relay still buffers a 0x04 frame
/// addressed to the deterministic DM room (under the TEXT cap, independent of the
/// image cap). The caption shares its `message_id` with the inlined-image
/// FileHeader, so the fetch node merges them (preferring the real caption over
/// the "[file:...]" sentinel). Mirrors [`send_encrypted_image_to_peer`] but emits
/// SendDirect (0x04) instead of SendDirectImage (0x08).
pub(crate) async fn send_encrypted_text_to_peer(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    peer_id_str: &str,
    dm_room: String,
    text: &str,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
) -> bool {
    match olm.encrypt(peer_id_str, text.as_bytes()) {
        Ok((msg_type, ciphertext)) => {
            persist_olm_session(olm, crypto_store, peer_id_str);
            let identity_key = if msg_type == 0 {
                Some(olm.identity_key_base64())
            } else {
                None
            };
            let haven_msg = HavenMessage::Encrypted {
                message_type: msg_type,
                body: OlmManager::encode_base64(&ciphertext),
                identity_key,
            };
            let json = serde_json::to_string(&haven_msg).unwrap_or_default();
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
                room_code: dm_room,
                target_peer: peer_id_str.to_string(),
                data: json.into_bytes(),
            });
            true
        }
        Err(e) => {
            let _ = event_tx
                .send(NetworkEvent::MessageSendFailed {
                    to_peer: peer_id_str.to_string(),
                    error: format!("Encryption failed: {e}"),
                })
                .await;
            false
        }
    }
}

/// Persist both account and session state to DB (fire-and-forget).
/// Use for session creation/destruction events where account state changes.
pub(crate) fn persist_crypto_state(olm: &OlmManager, crypto_store: &CryptoStore, peer_id: &str) {
    if let Ok(account_json) = olm.account_pickle_json() {
        crypto_store.save_account(account_json);
    }
    if let Ok(Some(session_json)) = olm.session_pickle_json(peer_id) {
        crypto_store.save_session(peer_id.to_string(), session_json);
    }
}

/// Persist only the session ratchet state (skip account pickle).
/// Use for per-message encrypt/decrypt where only the ratchet advances.
pub(crate) fn persist_olm_session(olm: &OlmManager, crypto_store: &CryptoStore, peer_id: &str) {
    if let Ok(Some(session_json)) = olm.session_pickle_json(peer_id) {
        crypto_store.save_session(peer_id.to_string(), session_json);
    }
}

/// Send a HavenMessage to a specific peer via the WS relay.
/// Silently drops the message if the peer is not reachable.
pub(crate) fn send_message_to_peer(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    peer_str: &str,
    msg: HavenMessage,
) {
    if let Some(room) = ws_room_for_peer(ws_room_peers, peer_str) {
        let json = serde_json::to_string(&msg).unwrap_or_default();
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
            room_code: room,
            target_peer: peer_str.to_string(),
            data: json.into_bytes(),
        });
    }
    // else: peer unreachable — drop silently
}

/// Send pre-serialized bytes to a specific peer via the WS relay.
/// Use in broadcast loops to serialize once and send the same bytes to each peer.
pub(crate) fn send_raw_to_peer(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    peer_str: &str,
    data: Vec<u8>,
) {
    if let Some(room) = ws_room_for_peer(ws_room_peers, peer_str) {
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
            room_code: room,
            target_peer: peer_str.to_string(),
            data,
        });
    }
}

/// Send pre-serialized bytes to EVERY online device of an identity.
///
/// Multi-device (Step 6): server members are keyed by MASTER, but no socket
/// authenticates as the bare master — a `send_raw_to_peer(master)` is silently
/// dropped (the master is in no room). This fans the same bytes out to each
/// online device of `member_id`'s identity. If `member_id` is itself a live
/// device id (single-device, or a non-collapsed id) it is reached directly.
/// No-op if the identity has no online device. Returns the number of devices
/// the bytes were dispatched to.
pub(crate) fn send_raw_to_identity(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    member_id: &str,
    data: Vec<u8>,
) -> usize {
    let mut devices = online_devices_for(ws_room_peers, member_id);
    // online_devices_for excludes the bare master; if member_id is itself a live
    // device (no link known) include it directly.
    if devices.is_empty() && ws_room_for_peer(ws_room_peers, member_id).is_some() {
        devices.push(member_id.to_string());
    }
    let mut sent = 0;
    for dev in &devices {
        if let Some(room) = ws_room_for_peer(ws_room_peers, dev) {
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
                room_code: room,
                target_peer: dev.clone(),
                data: data.clone(),
            });
            sent += 1;
        }
    }
    sent
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::{HashMap, HashSet};

    fn make_room_peers(rooms: &[(&str, &[&str])]) -> HashMap<String, HashSet<String>> {
        rooms.iter().map(|(room, peers)| {
            (room.to_string(), peers.iter().map(|p| p.to_string()).collect())
        }).collect()
    }

    #[test]
    fn coordinator_election_lowest_wins() {
        let members = vec!["peer_c".into(), "peer_a".into(), "peer_b".into()];
        let rooms = make_room_peers(&[("srv1", &["peer_a", "peer_b", "peer_c"])]);
        // peer_a is lowest → coordinator
        assert_eq!(elect_coordinator(&members, "peer_a", &rooms).as_deref(), Some("peer_a"));
        assert_eq!(elect_coordinator(&members, "peer_b", &rooms).as_deref(), Some("peer_a"));
        assert_eq!(elect_coordinator(&members, "peer_c", &rooms).as_deref(), Some("peer_a"));
    }

    #[test]
    fn coordinator_election_single_member() {
        let members = vec!["peer_x".into()];
        let rooms = HashMap::new(); // no room peers, but local peer is always "online"
        assert_eq!(elect_coordinator(&members, "peer_x", &rooms).as_deref(), Some("peer_x"));
    }

    #[test]
    fn coordinator_election_offline_skipped() {
        let members = vec!["peer_a".into(), "peer_b".into(), "peer_c".into()];
        // peer_a is offline (not in any room), peer_b is lowest online
        let rooms = make_room_peers(&[("srv1", &["peer_b", "peer_c"])]);
        assert_eq!(elect_coordinator(&members, "peer_b", &rooms).as_deref(), Some("peer_b"));
        assert_eq!(elect_coordinator(&members, "peer_c", &rooms).as_deref(), Some("peer_b"));
        // peer_a calls elect but is not in rooms — however local_peer is always included
        assert_eq!(elect_coordinator(&members, "peer_a", &rooms).as_deref(), Some("peer_a"));
    }

    #[test]
    fn coordinator_election_empty_members() {
        let members: Vec<String> = vec![];
        let rooms = HashMap::new();
        // local_peer is always counted as online → it wins alone (never None when
        // local_peer is present; None only if local_peer were filtered, which it
        // can't be). With an empty member list, local wins.
        assert_eq!(elect_coordinator(&members, "peer_x", &rooms).as_deref(), Some("peer_x"));
    }

    #[test]
    fn coordinator_election_collapses_devices_to_master() {
        // Multi-device: master M1 has two online device leaves (D1a, D1b); master
        // M2 has one (D2). The MLS group lists DEVICE ids. Election must collapse
        // to masters and pick the lowest MASTER — counting M1 once, not twice.
        super::super::resolver::clear_all();
        super::super::resolver::update("dev_m1_a", "master1");
        super::super::resolver::update("dev_m1_b", "master1");
        super::super::resolver::update("dev_m2", "master2");

        let members = vec!["dev_m1_a".into(), "dev_m1_b".into(), "dev_m2".into()];
        let rooms = make_room_peers(&[("srv1", &["dev_m1_a", "dev_m1_b", "dev_m2"])]);

        // master1 < master2 → master1 is coordinator regardless of which device queries.
        assert_eq!(elect_coordinator(&members, "master1", &rooms).as_deref(), Some("master1"));
        assert_eq!(elect_coordinator(&members, "master2", &rooms).as_deref(), Some("master1"));

        // Vault coordinator = 2nd master (master2), NOT a 2nd device of master1.
        assert_eq!(elect_vault_coordinator(&members, "master1", &rooms).as_deref(), Some("master2"));

        super::super::resolver::clear_all();
    }

    fn test_master() -> crate::identity::native_identity::NativeKeypair {
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let m: bip39::Mnemonic = phrase.parse().unwrap();
        crate::identity::native_identity::NativeKeypair::from_mnemonic(&m).unwrap()
    }

    #[test]
    fn device_list_sign_verify_roundtrip() {
        let master = test_master();
        let list = build_signed_device_list(
            &master,
            1,
            vec!["12D3KooWdevA".into(), "12D3KooWdevB".into()],
            vec![],
        );
        assert_eq!(list.master_peer_id, master.peer_id());
        assert!(verify_device_list(&list));
    }

    #[test]
    fn device_list_devices_are_sorted_and_deduped() {
        let master = test_master();
        let list = build_signed_device_list(
            &master,
            3,
            vec!["zzz".into(), "aaa".into(), "aaa".into(), "mmm".into()],
            vec![],
        );
        assert_eq!(list.devices, vec!["aaa", "mmm", "zzz"]);
        assert!(verify_device_list(&list));
    }

    #[test]
    fn device_list_tampered_devices_fail() {
        let master = test_master();
        let mut list = build_signed_device_list(&master, 1, vec!["aaa".into()], vec![]);
        // Inject a device the master never signed.
        list.devices.push("evil".into());
        assert!(!verify_device_list(&list), "tampered device list must not verify");
    }

    #[test]
    fn device_list_wrong_master_peer_id_fails() {
        let master = test_master();
        let mut list = build_signed_device_list(&master, 1, vec!["aaa".into()], vec![]);
        // Claim a different identity than the pubkey derives to.
        list.master_peer_id = "12D3KooWnotme".into();
        assert!(!verify_device_list(&list));
    }

    #[test]
    fn device_list_bumped_version_changes_signature() {
        let master = test_master();
        let v1 = build_signed_device_list(&master, 1, vec!["aaa".into()], vec![]);
        let v2 = build_signed_device_list(&master, 2, vec!["aaa".into()], vec![]);
        assert_ne!(v1.sig_b64, v2.sig_b64, "version is part of the signed payload");
        assert!(verify_device_list(&v1));
        assert!(verify_device_list(&v2));
    }

    // ---- Step 7: revocation tombstones ----

    #[test]
    fn revoked_device_removed_from_devices_and_signed() {
        let master = test_master();
        // Build with b also present in devices — it must be stripped because it's revoked.
        let list = build_signed_device_list(
            &master, 2,
            vec!["aaa".into(), "bbb".into()],
            vec!["bbb".into()],
        );
        assert_eq!(list.devices, vec!["aaa"], "revoked id stripped from active devices");
        assert_eq!(list.revoked, vec!["bbb"]);
        assert!(verify_device_list(&list), "signature covers devices+revoked");
    }

    #[test]
    fn revoked_set_is_sorted_and_signature_covers_it() {
        let master = test_master();
        let list = build_signed_device_list(
            &master, 5,
            vec!["aaa".into()],
            vec!["zzz".into(), "ccc".into(), "ccc".into()],
        );
        assert_eq!(list.revoked, vec!["ccc", "zzz"], "revoked sorted + deduped");
        assert!(verify_device_list(&list));
    }

    #[test]
    fn tampered_revoked_set_fails_verify() {
        let master = test_master();
        let mut list = build_signed_device_list(
            &master, 2, vec!["aaa".into()], vec!["bbb".into()],
        );
        // Attacker strips the tombstone post-signing to try to un-revoke bbb.
        list.revoked.clear();
        assert!(!verify_device_list(&list), "stripping the revoked array must fail verify");
    }

    #[test]
    fn revocation_changes_signature_vs_plain_list() {
        let master = test_master();
        let plain = build_signed_device_list(&master, 2, vec!["aaa".into()], vec![]);
        let revoking = build_signed_device_list(&master, 2, vec!["aaa".into()], vec!["bbb".into()]);
        assert_ne!(plain.sig_b64, revoking.sig_b64, "revoked set is part of the signed payload");
        assert!(verify_device_list(&plain));
        assert!(verify_device_list(&revoking));
    }
}
