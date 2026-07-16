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
                    // Lookback overlap — a high-watermark skips messages
                    // missed while a newer one arrived; the overlap is
                    // mid-deduplicated on receipt.
                    let ts = (store
                        .get_latest_dm_timestamp_any(&c)
                        .unwrap_or(None)
                        .unwrap_or(0)
                        - crate::storage::messages::SYNC_LOOKBACK_MS)
                        .max(0);
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

// --- Sibling proof handshake (anti-mis-link) -------------------------------------
//
// A peer joining our own `inbox:{master}` room used to be trusted DIRECTLY as our
// sibling device. But the friend-request protocol makes the REQUESTER join the
// TARGET's inbox to deliver the request (social.rs), so a STRANGER lands in our
// inbox and was mis-merged as our device (resolver poisoning + device-list merge +
// friend-list leak + auto snapshot/link). The fix: before any merge we challenge an
// unproven inbox peer to sign a fresh nonce with the SHARED MASTER key. Only a
// genuine sibling holds it; a stranger holds only its own master key and fails the
// pubkey→our-master binding. Mirrors the device-list sign/verify template above.

/// Canonical signing payload for the sibling proof. Binds the proof to OUR master
/// peer_id, the CHALLENGED device id, and a fresh nonce so a captured response can't
/// be replayed against a different master/device/nonce.
pub(crate) fn sibling_proof_payload(
    master_peer_id: &str,
    device_peer_id: &str,
    nonce: &str,
) -> String {
    format!("hollow-sibling:{master_peer_id}:{device_peer_id}:{nonce}")
}

/// Sign a sibling proof with the (shared) master key. `device_peer_id` is OUR OWN
/// device id (the responder's). Returns `(sig_b64, master_pubkey_b64)` to put in a
/// [`HavenMessage::SiblingProveResponse`].
pub(crate) fn build_sibling_proof(
    master: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    nonce: &str,
) -> (String, String) {
    use base64::engine::general_purpose::STANDARD as B64;
    let payload = sibling_proof_payload(&master.peer_id(), device_peer_id, nonce);
    let sig = master.sign(payload.as_bytes());
    (B64.encode(sig), B64.encode(master.public_key_protobuf()))
}

/// Verify a sibling proof. `claimed_master_peer_id` is OUR OWN master peer_id (the
/// challenger): the response's pubkey must derive to it (proving the responder holds
/// OUR master key), and the signature must validate over the canonical payload built
/// from our master + the device id WE challenged (`challenged_device_peer_id`, taken
/// from the routing layer — never a value the responder self-reports) + the nonce.
pub(crate) fn verify_sibling_proof(
    claimed_master_peer_id: &str,
    challenged_device_peer_id: &str,
    nonce: &str,
    sig_b64: &str,
    master_pubkey_b64: &str,
) -> bool {
    use base64::engine::general_purpose::STANDARD as B64;
    use crate::identity::native_identity::NativeKeypair;

    let Ok(pk_bytes) = B64.decode(master_pubkey_b64) else {
        return false;
    };
    // Bind pubkey → OUR claimed master peer_id (a stranger's own-key pubkey derives
    // to a different peer_id and is rejected here).
    match NativeKeypair::peer_id_from_pubkey_protobuf(&pk_bytes) {
        Some(derived) if derived == claimed_master_peer_id => {}
        _ => return false,
    }
    let Ok(sig_bytes) = B64.decode(sig_b64) else {
        return false;
    };
    let payload =
        sibling_proof_payload(claimed_master_peer_id, challenged_device_peer_id, nonce);
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
            // Strip a stale MASTER-as-device entry. A legacy keystone install (where
            // `device_peer_id == master`) wrote `devices = [master]`; once a DISTINCT
            // device key exists (a re-import / rotation, so `device != master`), the
            // bare master is NOT a transport device — no socket ever authenticates as
            // it, so a friend who only learns `[master]` can never map our real device
            // → master and our DMs/presence/friend-row key wrong. Drop it so we publish
            // only real device ids. NEVER strip when device == master (a genuine sole
            // keystone that legitimately is its own device + owns its MLS leaf).
            let master_stripped = device_peer_id != master_peer_id
                && devs.iter().any(|d| d == &master_peer_id);
            if master_stripped {
                devs.retain(|d| d != &master_peer_id);
            }
            // Membership changed → bump version so peers accept the update.
            if self_added || master_stripped || revoked.len() != list.revoked.len() {
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

/// Tombstone EVERY one of our devices EXCEPT the one we're running on — a single
/// version bump that revokes all siblings at once. This is the real, propagating
/// teardown behind the "Reset Device List" button: unlike a blunt local wipe (which
/// the grow-only merge simply regrows on the next profile exchange), every sibling
/// becomes a permanent `revoked` tombstone in our master-signed list, so friends
/// converge and can never un-revoke them, and each revoked sibling self-nukes on
/// receiving the v+1 list. Returns the re-signed list + the ids that were tombstoned
/// this call (so the caller can push the list to each for `SelfRevoked`). `None` on
/// a DB error or when there's nothing to revoke (already sole device).
pub(crate) fn revoke_all_other_devices(
    master: &crate::identity::native_identity::NativeKeypair,
    local_device_peer_id: &str,
    db_path: &str,
    db_passphrase: &str,
) -> Option<(SignedDeviceList, Vec<String>)> {
    let store = crate::storage::MessageStore::open(db_path, db_passphrase).ok()?;
    let master_peer_id = master.peer_id();
    let (mut devices, mut revoked, version): (Vec<String>, Vec<String>, u64) =
        match store.load_device_list(&master_peer_id) {
            Ok(Some(list)) => (list.devices.clone(), list.revoked.clone(), list.version),
            _ => (vec![local_device_peer_id.to_string()], Vec::new(), 0),
        };
    // Fold in any resolver-known device ids of ours that haven't made it into the
    // persisted list yet (live siblings, ghosts from re-link cycles) so they ALL get
    // tombstoned — not just the ones already written down.
    for d in super::resolver::devices_for(&master_peer_id) {
        if d != local_device_peer_id && !devices.contains(&d) && !revoked.contains(&d) {
            devices.push(d);
        }
    }
    // Everything that isn't this device becomes a tombstone.
    let to_revoke: Vec<String> = devices
        .iter()
        .filter(|d| d.as_str() != local_device_peer_id)
        .cloned()
        .collect();
    if to_revoke.is_empty() {
        hollow_log!("[HOLLOW-REVOKE] Reset device list: already the sole device, nothing to revoke");
        return None;
    }
    for d in &to_revoke {
        if !revoked.iter().any(|r| r == d) {
            revoked.push(d.clone());
        }
    }
    // Sole surviving device = us.
    let devices = vec![local_device_peer_id.to_string()];
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
        hollow_log!("[HOLLOW-REVOKE] Reset device list: failed to persist: {e}");
        return None;
    }
    // Prune every revoked id from the in-memory resolver + guard against phantom
    // chats from any that are still momentarily alive, then re-seed our survivor.
    for d in &to_revoke {
        super::resolver::forget(d);
    }
    super::resolver::mark_revoked(&to_revoke);
    super::resolver::seed_self(&signed.master_peer_id, &signed.devices);
    hollow_log!(
        "[HOLLOW-REVOKE] Reset device list: revoked {} sibling(s) → sole device (v{})",
        to_revoke.len(), signed.version
    );
    Some((signed, to_revoke))
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
        // Re-key any friend row stranded under one of this master's DEVICE ids (a
        // friend added by temporary nickname lands under the device id). Even on the
        // redundant-ingest path, do this — the friend row may have been created AFTER
        // a prior ingest warmed the resolver but BEFORE this re-key existed. Include
        // the SENDER device explicitly: a stale legacy device list can advertise only
        // the master-as-device while the friend actually transmits from a distinct
        // device id (the nickname/WS-auth id), so the sender is the id the friend row
        // is keyed under — and it may NOT appear in `merged`.
        for dev in merged.iter().map(|s| s.as_str()).chain(std::iter::once(sender_peer_id)) {
            if let Ok(true) = store.migrate_friend_to_master(dev, &list.master_peer_id) {
                hollow_log!(
                    "[HOLLOW-FRIENDS] Re-keyed friend {dev} → master {}", list.master_peer_id
                );
            }
        }
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
    // Re-key any friend row stranded under one of this master's DEVICE ids → the
    // master (a friend added by temporary nickname keys under the device id; the
    // friend system is the one place that stores the raw id). Include the SENDER
    // device explicitly — a stale legacy device list may advertise only the
    // master-as-device while the friend transmits from a distinct device id, so the
    // sender (the id the friend row is keyed under) may NOT be in `stored.devices`.
    // Idempotent.
    for dev in stored.devices.iter().map(|s| s.as_str()).chain(std::iter::once(sender_peer_id)) {
        if let Ok(true) = store.migrate_friend_to_master(dev, &stored.master_peer_id) {
            hollow_log!(
                "[HOLLOW-FRIENDS] Re-keyed friend {dev} → master {}", stored.master_peer_id
            );
        }
    }
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
    // Slow path: is any connected device of the SAME identity present? The input
    // may be a DEVICE id (resolve maps it to its master) or a bare MASTER id
    // (resolve returns it UNCHANGED — masters are only VALUES in the link map,
    // never keys except the self-seed). Either way, compare room peers against
    // the resolved target. There must be NO `resolve(peer) == peer → false`
    // early-return here: it would fire for every master id, making a friend or
    // server member with online devices permanently "unreachable" — which
    // silently disabled the owner-preferred coordinator election, MLS recovery
    // targeting, subgroup self-bootstrap, and offline-push classification for
    // every modern (device != master) identity. A genuinely offline
    // single-device peer still returns false: no room peer resolves to it.
    let target_master = super::resolver::resolve(peer_str);
    ws_room_peers.values().any(|peers| {
        peers.iter().any(|p| super::resolver::resolve(p) == target_master)
    })
}

/// The single concrete DEVICE id to address when a caller holds a (possibly
/// master) peer id and needs ONE socket-addressable target. The exact id wins
/// when it is itself in a room (single-device / legacy keystone); otherwise the
/// deterministic lowest online device of the identity. `None` when nothing is
/// online. Pairs with `peer_is_reachable`: reachable ⇒ this returns `Some`.
pub(crate) fn preferred_online_device(
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    peer_str: &str,
) -> Option<String> {
    if ws_room_peers.values().any(|peers| peers.contains(peer_str)) {
        return Some(peer_str.to_string());
    }
    let mut devices = online_devices_for(ws_room_peers, peer_str);
    devices.sort();
    devices.into_iter().next()
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
    let mut master_is_socket = false;
    for peers in ws_room_peers.values() {
        for p in peers {
            // Match the exact id OR any device that resolves to the same master.
            if p == peer_str || super::resolver::resolve(p) == master {
                if *p == master {
                    // Room membership is socket-authenticated, so the master
                    // id appearing IN a room means a socket really does
                    // authenticate as it — a LEGACY single-device identity
                    // (device == master, pre-multi-device install).
                    master_is_socket = true;
                }
                set.insert(p.clone());
            }
        }
    }
    // Never include a bare master no socket authenticates as (sends to it are
    // silently dropped) — but KEEP it when it IS a live socket (legacy
    // device==master), else those identities get an empty vec and callers
    // without a raw-id fallback silently skip them (channel file replication
    // never streamed bytes to legacy members).
    if !master_is_socket {
        set.remove(&master);
    }
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

/// Server-group MLS coordinator with OWNER PREFERENCE. The owner always holds the
/// server group and is the natural single authority, so when the owner is online,
/// holds a leaf, and isn't the excluded sender, the owner is the sole committer for
/// server-group adds. This keeps server-group epochs LINEAR and owner-authoritative
/// — a non-owner committer can add a member and then fail to fan the Commit out to
/// some other leaf (e.g. the owner), which then diverges permanently with no retry.
/// (Distinct-identity 3+ member deadlock.) Falls back to the deterministic
/// lowest-master election when the owner is offline / not a leaf / is the sender.
pub(crate) fn elect_server_coordinator(
    server: &crate::crdt::server_state::ServerState,
    mls_members: &[String],
    local_peer: &str,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) -> Option<String> {
    // The owner master id (members are master-keyed).
    let owner = server.members.keys().find(|m| {
        server.roles.get(*m)
            .map(|r| *r.read() == crate::crdt::operations::MemberRole::Owner)
            .unwrap_or(false)
    });
    if let Some(owner) = owner {
        let owner_online = owner.as_str() == local_peer || peer_is_reachable(ws_room_peers, owner);
        // The owner must be a candidate of THIS election: it holds a leaf AND isn't
        // the excluded sender (the caller pre-filters the sender's identity out of
        // `mls_members`, so an owner that sent the KP won't appear here).
        let owner_is_candidate = mls_members.iter().any(|p| super::resolver::same_identity(p, owner));
        if owner_online && owner_is_candidate {
            return Some(owner.clone());
        }
    }
    // Owner unavailable — deterministic lowest-master fallback.
    elect_coordinator(mls_members, local_peer, ws_room_peers)
}

/// Where a member sends its server-group bootstrap/recovery KeyPackage. The OWNER
/// always holds the server group, so it's the always-valid recovery target — when
/// online (and not us) we target the owner; otherwise fall back to the lowest
/// online master among CRDT members (excluding us). This pairs with
/// `elect_server_coordinator` so the owner is both the committer and the recovery
/// target, closing the 3+-distinct-member recovery deadlock.
pub(crate) fn server_bootstrap_target(
    server: &crate::crdt::server_state::ServerState,
    local_peer: &str,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) -> Option<String> {
    let owner = server.members.keys().find(|m| {
        server.roles.get(*m)
            .map(|r| *r.read() == crate::crdt::operations::MemberRole::Owner)
            .unwrap_or(false)
    });
    if let Some(owner) = owner {
        if owner.as_str() != local_peer && peer_is_reachable(ws_room_peers, owner) {
            return Some(owner.clone());
        }
    }
    let members: Vec<String> = server.members.keys().cloned().collect();
    elect_coordinator(&members, local_peer, ws_room_peers).filter(|c| c != local_peer)
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

/// Elect the coordinator for a per-channel MLS subgroup (Option B). Unlike the
/// server group — whose membership the elector reads from `mls.group_members` —
/// a subgroup may not exist yet on any node, so candidates are the CRDT members
/// who QUALIFY for the channel (`can_see_channel`) and are online. Lowest online
/// qualifying master wins, mirroring `elect_coordinator`. Returns the elected
/// master id, or None if nobody (incl. us) qualifies online.
pub(crate) fn elect_subgroup_coordinator(
    server: &crate::crdt::server_state::ServerState,
    channel_id: &str,
    local_peer: &str,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) -> Option<String> {
    // Prefer the OWNER (always qualifies — Owner sees every channel) when online: a
    // globally-agreed single coordinator that needs no per-node leaf knowledge, so
    // two nodes can't each elect themselves and fork the subgroup. Lowest-qualifying
    // master only when the owner is offline.
    let owner = server.members.keys().find(|m| {
        server.roles.get(*m)
            .map(|r| *r.read() == crate::crdt::operations::MemberRole::Owner)
            .unwrap_or(false)
    });
    if let Some(owner) = owner {
        if owner.as_str() == local_peer || peer_is_reachable(ws_room_peers, owner) {
            return Some(owner.clone());
        }
    }
    let mut masters: Vec<String> = server.members.keys()
        .filter(|m| server.can_see_channel(m, channel_id))
        .filter(|m| m.as_str() == local_peer || peer_is_reachable(ws_room_peers, m))
        .cloned()
        .collect();
    masters.sort();
    masters.dedup();
    masters.into_iter().next()
}

/// Send our KeyPackage to a restricted channel's subgroup coordinator so we can
/// be added to (or bootstrap) the subgroup. No-op when WE are the coordinator
/// (the membership reconciler creates+populates the group on our side) or when
/// nobody qualifying is online. The KeyPackage is tagged with `channel_id` so
/// the coordinator adds us to the SUBGROUP, not the server group.
pub(crate) fn request_subgroup_bootstrap(
    mls: &mut MlsManager,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server: &crate::crdt::server_state::ServerState,
    server_id: &str,
    channel_id: &str,
    local_peer: &str,
) {
    let coordinator = match elect_subgroup_coordinator(server, channel_id, local_peer, ws_room_peers) {
        Some(c) if c != local_peer => c,
        _ => return, // we're the coordinator (reconciler handles it) or nobody online
    };
    let kp_bytes = match mls.generate_key_package() {
        Ok(kp) => kp,
        Err(e) => { hollow_log!("[HOLLOW-MLS] subgroup KP gen failed: {e}"); return; }
    };
    let kp_b64 = base64::engine::general_purpose::STANDARD.encode(&kp_bytes);
    let data = serde_json::to_vec(&HavenMessage::MlsKeyPackage {
        server_id: server_id.to_string(),
        key_package: kp_b64,
        channel_id: Some(channel_id.to_string()),
    }).unwrap_or_default();
    let sent = send_raw_to_identity(ws_cmd_tx, ws_room_peers, &coordinator, data);
    if sent > 0 {
        hollow_log!("[HOLLOW-MLS] Sent subgroup KeyPackage to coordinator {coordinator} for {server_id}#{channel_id} ({sent} device(s))");
    }
}

/// Reconcile per-channel MLS subgroup membership against the CRDT after a
/// lifecycle event (role change, visibility change, channel create/delete,
/// kick/ban/leave). Runs the desired-vs-actual diff for every restricted channel
/// (or just `only_channel` when given) and drives the existing batch queues:
///
///   * REMOVALS (we do these directly — we already hold the leaf credentials):
///     any current subgroup leaf whose MASTER is no longer a server member OR no
///     longer qualifies for the channel is queued into `pending_mls_removals`
///     (`{master} ∪ devices_for(master)` so all of a human's leaves drop at once).
///   * ADDITIONS (pull-based — we lack the new member's KeyPackage): any online
///     qualifying member with no leaf is sent an `MlsKeyPackageRequest{channel_id}`;
///     it replies with a KeyPackage tagged for the subgroup, which the
///     MlsKeyPackage handler queues into `pending_mls_key_packages`.
///
/// Only the subgroup coordinator acts (idempotent under races — see the
/// deterministic election). A channel that stops being restricted is torn down
/// by the visibility handler via `remove_group`, not here.
#[allow(clippy::too_many_arguments)]
pub(crate) fn reconcile_subgroups_for_server(
    mls: &mut MlsManager,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    pending_mls_key_packages: &mut HashMap<String, Vec<(String, Vec<u8>)>>,
    pending_mls_removals: &mut HashMap<String, Vec<String>>,
    server: &crate::crdt::server_state::ServerState,
    server_id: &str,
    local_peer: &str,
    only_channel: Option<&str>,
) {
    let channels: Vec<String> = match only_channel {
        Some(cid) if server.channel_uses_subgroup(cid) => vec![cid.to_string()],
        Some(_) => return, // not (or no longer) a restricted channel
        None => server.subgroup_channel_ids(),
    };

    for cid in channels {
        let group_key = crate::crypto::subgroup_id(server_id, &cid);
        // Elect a STABLE, demotion-safe coordinator: the lowest online master who
        // (a) still QUALIFIES for the channel AND (b) already holds a subgroup leaf.
        // This excludes a just-demoted member (no longer qualifies → can't be the
        // remover, and it never removes its own leaf) AND a just-promoted member
        // (doesn't hold the group yet → can't add others without their KeyPackage).
        // If nobody holds the group yet (first restriction), fall back to the lowest
        // qualifying online master to bootstrap creation.
        // Prefer the OWNER as the single subgroup coordinator when online. The owner
        // ALWAYS qualifies (Owner sees every channel) and is a globally-agreed choice
        // from the CRDT — no node needs to know who locally holds a subgroup leaf.
        // This avoids SPLIT-BRAIN: the per-node leaf-holder heuristic below disagrees
        // across nodes (each only knows its OWN MLS leaves), so two qualifying masters
        // could each elect themselves and create divergent groups with the same id.
        // Fall back to the leaf-holder/lowest-qualifying election only when the owner
        // is offline.
        let coord = {
            let owner = server.members.keys().find(|m| {
                server.roles.get(*m)
                    .map(|r| *r.read() == crate::crdt::operations::MemberRole::Owner)
                    .unwrap_or(false)
            });
            let owner_online = owner.is_some_and(|o| {
                o.as_str() == local_peer || peer_is_reachable(ws_room_peers, o)
            });
            if owner_online {
                owner.cloned()
            } else {
                // Owner offline: lowest online master who still QUALIFIES AND already
                // holds a subgroup leaf (demotion-safe); else lowest qualifying master.
                let leaf_masters: std::collections::HashSet<String> = mls.group_members(&group_key)
                    .iter().map(|l| super::resolver::resolve(l)).collect();
                let mut holders: Vec<String> = server.members.keys()
                    .filter(|mm| server.can_see_channel(mm, &cid))
                    .filter(|mm| mm.as_str() == local_peer || peer_is_reachable(ws_room_peers, mm))
                    .filter(|mm| leaf_masters.contains(*mm))
                    .cloned()
                    .collect();
                holders.sort();
                holders.into_iter().next()
                    .or_else(|| elect_subgroup_coordinator(server, &cid, local_peer, ws_room_peers))
            }
        };
        if coord.as_deref() != Some(local_peer) { continue; }

        // The coordinator must hold the group to commit. Create it lazily (we are
        // its founding member). If we ourselves don't qualify we can't be coord.
        if !server.can_see_channel(local_peer, &cid) { continue; }
        if !mls.has_group(&group_key) {
            if let Err(e) = mls.create_group(&group_key) {
                hollow_log!("[HOLLOW-MLS] reconcile: failed to create subgroup {group_key}: {e}");
                continue;
            }
            hollow_log!("[HOLLOW-MLS] reconcile: created subgroup {group_key}");
        }

        // REMOVALS: existing leaves whose master is gone or no longer qualifies.
        for leaf in mls.group_members(&group_key) {
            if super::resolver::same_identity(&leaf, local_peer) { continue; } // never self
            let leaf_master = super::resolver::resolve(&leaf);
            let still_ok = server.is_member(&leaf_master) && server.can_see_channel(&leaf_master, &cid);
            if !still_ok {
                hollow_log!("[HOLLOW-MLS] reconcile: queue remove {leaf} from {group_key} (master no longer qualifies)");
                pending_mls_removals.entry(group_key.clone()).or_default().push(leaf);
            }
        }

        // ADDITIONS: online qualifying members with no leaf yet → request their KP.
        // (We can't add without their KeyPackage; pull it.) Dedup against members
        // we've already queued a KeyPackage for this round.
        let current_leaf_masters: std::collections::HashSet<String> = mls.group_members(&group_key)
            .iter().map(|l| super::resolver::resolve(l)).collect();
        let already_queued: std::collections::HashSet<String> = pending_mls_key_packages
            .get(&group_key)
            .map(|v| v.iter().map(|(p, _)| super::resolver::resolve(p)).collect())
            .unwrap_or_default();
        for member in server.members.keys() {
            if super::resolver::same_identity(member, local_peer) { continue; }
            if !server.can_see_channel(member, &cid) { continue; }
            if current_leaf_masters.contains(member) { continue; }
            if already_queued.contains(member) { continue; }
            if !peer_is_reachable(ws_room_peers, member) { continue; } // offline → pulls itself later
            let data = serde_json::to_vec(&HavenMessage::MlsKeyPackageRequest {
                server_id: server_id.to_string(),
                channel_id: Some(cid.clone()),
            }).unwrap_or_default();
            let sent = send_raw_to_identity(ws_cmd_tx, ws_room_peers, member, data);
            if sent > 0 {
                hollow_log!("[HOLLOW-MLS] reconcile: requested KeyPackage from {member} for {group_key} ({sent} device(s))");
            }
        }
    }
}

/// Remove every leaf of `target_master`'s identity from ALL of a server's
/// per-channel MLS subgroups (Option B), one commit per subgroup, broadcasting
/// each commit to the subgroup's remaining qualifying members + our own siblings.
/// Used by kick/ban/leave so a removed human loses access to restricted channels,
/// not just the server-wide group. Mirrors the server-group removal in the
/// kick handler. No-op for subgroups we don't hold or where the target has no leaf.
pub(crate) async fn remove_identity_from_subgroups(
    mls: &mut MlsManager,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    crypto_store: &CryptoStore,
    server: &crate::crdt::server_state::ServerState,
    server_id: &str,
    target_master: &str,
) {
    // credential ids of the removed human = {master} ∪ all known devices.
    let id_set: Vec<String> = {
        let mut v = super::resolver::devices_for(target_master);
        v.push(target_master.to_string());
        v
    };
    for cid in server.subgroup_channel_ids() {
        let group_key = crate::crypto::subgroup_id(server_id, &cid);
        if !mls.has_group(&group_key) { continue; }
        // Only the leaves that actually exist in this subgroup.
        let present: Vec<&str> = {
            let leaves = mls.group_members(&group_key);
            id_set.iter()
                .filter(|c| leaves.iter().any(|l| l == *c))
                .map(|s| s.as_str())
                .collect()
        };
        if present.is_empty() { continue; }

        match mls.remove_identity_leaves(&group_key, &present) {
            Ok(commit_bytes) => {
                if let Err(e) = mls.merge_pending_commit(&group_key) {
                    hollow_log!("[HOLLOW-MLS] subgroup remove merge failed for {group_key}: {e}");
                    continue;
                }
                persist_mls_state(mls, crypto_store);
                if let Ok(sframe_key) = mls.export_secret(&group_key, "sframe", b"", 32) {
                    let epoch = mls.epoch(&group_key).unwrap_or(0);
                    let _ = event_tx.send(NetworkEvent::MlsEpochChanged {
                        server_id: server_id.to_string(), epoch, sframe_key,
                        channel_id: Some(cid.clone()),
                    }).await;
                }
                let commit_b64 = base64::engine::general_purpose::STANDARD.encode(&commit_bytes);
                // Tier 1: single room broadcast (covers qualifying members AND our
                // siblings); non-qualifiers ignore it via has_group on receive.
                broadcast_mls_commit(
                    ws_cmd_tx, server_id, Some(cid.clone()), commit_b64,
                    mls.epoch(&group_key).ok(),
                );
                hollow_log!("[HOLLOW-MLS] Removed {target_master}'s leaves from subgroup {group_key}");
            }
            Err(e) => hollow_log!("[HOLLOW-MLS] subgroup remove failed for {group_key}: {e}"),
        }
    }
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
    // MLS rule: persist on encrypt — SEND-side ratchet state must never be
    // debounced. A receive ratchet that regresses (app killed before a
    // deferred flush) can ratchet FORWARD again, but a regressed send ratchet
    // re-uses generations receivers already consumed → every live message
    // fails with SecretTreeError(TooDistantInThePast) on the other side.
    // (Tried a 2s debounce here 2026-07; it wedged live channel messages
    // from mobile senders exactly this way. Do not retry.)
    persist_mls_state(mls, crypto_store);
    let msg = HavenMessage::MlsChannelMessage {
        server_id: server_id.to_string(),
        body: body_b64,
        channel_id: None,
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
///
/// `use_subgroup`: when true, the channel is restricted (Option B) and the
/// message is encrypted under the per-channel MLS subgroup
/// (`subgroup_id(server_id, topic)`) and stamped with `channel_id = Some(topic)`
/// so the receiver decrypts under the same subgroup. When false the message uses
/// the server-wide group (`channel_id = None`, byte-for-byte legacy behavior).
/// The relay routing `topic` is always the channel id regardless.
pub(crate) fn send_mls_broadcast_topic(
    mls: &mut MlsManager,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    server_id: &str,
    topic: &str,
    use_subgroup: bool,
    envelope: &MessageEnvelope,
    crypto_store: &CryptoStore,
) -> Result<Vec<u8>, String> {
    let group_key = if use_subgroup {
        crate::crypto::subgroup_id(server_id, topic)
    } else {
        server_id.to_string()
    };
    let channel_id = if use_subgroup { Some(topic.to_string()) } else { None };
    let json = serde_json::to_string(envelope).map_err(|e| format!("serialize: {e}"))?;
    let ciphertext = mls.encrypt(&group_key, json.as_bytes()).map_err(|e| format!("encrypt: {e}"))?;
    let body_b64 = base64::engine::general_purpose::STANDARD.encode(&ciphertext);
    // MLS rule: persist on encrypt — send-side ratchet state must never be
    // debounced (see send_mls_broadcast for the full why).
    persist_mls_state(mls, crypto_store);
    let msg = HavenMessage::MlsChannelMessage {
        server_id: server_id.to_string(),
        body: body_b64,
        channel_id,
    };
    let data = serde_json::to_vec(&msg).map_err(|e| format!("serialize msg: {e}"))?;
    hollow_log!("[HOLLOW-TOPIC] Broadcast room={server_id} topic={topic} group={group_key} ({} bytes)", data.len());
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
        channel_id: None,
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

/// Like `send_message_to_peer` but routes into an EXPLICIT room (the
/// deterministic `dm_room_code`), not a `ws_room_for_peer` first-match lookup.
/// Use for DM-scoped sends (typing, etc.) where the recipient device may be
/// co-present in several of our rooms and the first-match could pick one the
/// recipient has since left → the frame is buffered against a room they never
/// rejoin and lost. Every device of the recipient is a member of the DM room.
pub(crate) fn send_message_to_peer_in_room(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    room_code: &str,
    peer_str: &str,
    msg: HavenMessage,
) {
    let json = serde_json::to_string(&msg).unwrap_or_default();
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
        room_code: room_code.to_string(),
        target_peer: peer_str.to_string(),
        data: json.into_bytes(),
    });
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

/// Broadcast an MLS Commit to the ENTIRE server WS room in ONE 0x03 frame.
///
/// Large-server scaling Tier 1 (`reports/LARGE_SERVER_SCALING_2026.md`): commit
/// bytes are byte-identical for every recipient, so the historical per-device
/// `SendDirect` loop was O(N) coordinator upload per membership change — the
/// relay fans a single room broadcast out instead. Over-delivery is harmless:
/// receivers that don't hold the group ignore it (`has_group`), receivers
/// already at/past the commit's epoch skip it (wire `epoch` guard — including
/// fresh joiners whose Welcome lands them at the post-commit epoch), and a
/// kicked/removed identity that errors into re-bootstrap is refused by the
/// MlsKeyPackage non-member check. Our own siblings are in the room and now
/// get the commit for free (the relay excludes only this device's socket).
pub(crate) fn broadcast_mls_commit(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    server_id: &str,
    channel_id: Option<String>,
    commit_b64: String,
    epoch: Option<u64>,
) {
    let data = serde_json::to_vec(&HavenMessage::MlsCommit {
        server_id: server_id.to_string(),
        commit: commit_b64,
        channel_id,
        epoch,
    })
    .unwrap_or_default();
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom {
        room_code: server_id.to_string(),
        data,
    });
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
        let _lock = super::super::resolver::test_lock();
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

    #[test]
    fn master_with_online_device_is_reachable() {
        // THE regression test for the early-return bug: `resolve(master) ==
        // master` always (masters are only VALUES in the link map), so an
        // early "resolve == self → false" made every bare MASTER id
        // unreachable even with its device online — silently disabling the
        // owner-preferred election, MLS recovery targeting, subgroup
        // self-bootstrap and offline-push classification for every modern
        // (device != master) identity. The resolver map is process-global —
        // hold the shared test lock so a parallel test's clear_all can't wipe
        // the links mid-assert.
        let _lock = super::super::resolver::test_lock();
        super::super::resolver::update("pir_dev_a", "pir_master_a");
        let rooms = make_room_peers(&[("srvP", &["pir_dev_a"])]);

        // The bare master IS reachable through its online device...
        assert!(peer_is_reachable(&rooms, "pir_master_a"));
        // ...and the device id itself stays reachable (exact fast path).
        assert!(peer_is_reachable(&rooms, "pir_dev_a"));
        // A master whose devices are all offline is NOT reachable.
        super::super::resolver::update("pir_dev_b", "pir_master_b");
        assert!(!peer_is_reachable(&rooms, "pir_master_b"));
        // An unknown single-device peer not in any room is NOT reachable.
        assert!(!peer_is_reachable(&rooms, "pir_stranger"));
    }

    #[test]
    fn preferred_online_device_picks_socket_addressable_id() {
        let _lock = super::super::resolver::test_lock();
        super::super::resolver::update("pod_dev_1", "pod_master");
        super::super::resolver::update("pod_dev_2", "pod_master");
        let rooms = make_room_peers(&[("srvQ", &["pod_dev_2", "pod_dev_1"])]);

        // Master input → deterministic lowest online device.
        assert_eq!(
            preferred_online_device(&rooms, "pod_master").as_deref(),
            Some("pod_dev_1")
        );
        // Exact id in a room wins as-is (single-device / legacy keystone).
        assert_eq!(
            preferred_online_device(&rooms, "pod_dev_2").as_deref(),
            Some("pod_dev_2")
        );
        // Nothing online → None (reachable ⇒ Some invariant holds inversely).
        assert_eq!(preferred_online_device(&rooms, "pod_ghost_master"), None);
    }

    fn test_master() -> crate::identity::native_identity::NativeKeypair {
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let m: bip39::Mnemonic = phrase.parse().unwrap();
        crate::identity::native_identity::NativeKeypair::from_mnemonic(&m).unwrap()
    }

    /// A legacy keystone wrote `devices = [master]`. Once a DISTINCT device key
    /// exists (device != master), `build_local_device_list` must STRIP the
    /// master-as-device entry and publish only the real device id — otherwise a
    /// friend who only learns `[master]` can never map our real device → master
    /// (broke nickname-added friend keying). A genuine sole keystone (device ==
    /// master) keeps its single entry untouched (it owns its MLS leaf).
    #[test]
    fn local_device_list_strips_master_as_device() {
        let _lock = super::super::resolver::test_lock();
        super::super::resolver::clear_all();
        let master = test_master();
        let master_id = master.peer_id();
        let device_id = "12D3KooWrealDeviceXYZ".to_string();

        let tmp = tempfile::tempdir().unwrap();
        let db = tmp.path().join("m.db").to_str().unwrap().to_string();
        let pass = "ab".repeat(32);
        crate::storage::MessageStore::migrate_auto_vacuum_once(&db, &pass).unwrap();

        // Seed a STALE legacy keystone list: devices = [master], v1.
        {
            let store = crate::storage::MessageStore::open(&db, &pass).unwrap();
            let stale = build_signed_device_list(&master, 1, vec![master_id.clone()], vec![]);
            let json = serde_json::to_string(&stale).unwrap();
            store.save_device_list(&master_id, &json, 1, &stale.devices, 0).unwrap();
        }

        // Publish from the REAL distinct device → master must be stripped, device added.
        let signed = build_local_device_list(&master, &device_id, &db, &pass).unwrap();
        assert!(
            !signed.devices.contains(&master_id),
            "master-as-device must be stripped, got {:?}", signed.devices
        );
        assert!(
            signed.devices.contains(&device_id),
            "the real device id must be published, got {:?}", signed.devices
        );
        assert!(signed.version >= 2, "membership changed → version bumped");
        assert!(verify_device_list(&signed), "re-signed list must verify");

        super::super::resolver::clear_all();
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
    fn sibling_proof_sign_verify_roundtrip() {
        let master = test_master();
        let our_master = master.peer_id();
        let challenged_device = "12D3KooWsiblingDevice";
        let nonce = "deadbeefcafef00d";

        // The genuine sibling holds the SAME master key, signs with its own device id.
        let (sig, pk) = build_sibling_proof(&master, challenged_device, nonce);
        assert!(
            verify_sibling_proof(&our_master, challenged_device, nonce, &sig, &pk),
            "a valid master-signed proof must verify"
        );

        // A stranger signs with a DIFFERENT master key → pubkey binds to the wrong
        // master peer_id → rejected.
        let stranger = {
            let phrase = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong";
            let m: bip39::Mnemonic = phrase.parse().unwrap();
            crate::identity::native_identity::NativeKeypair::from_mnemonic(&m).unwrap()
        };
        let (bad_sig, bad_pk) = build_sibling_proof(&stranger, challenged_device, nonce);
        assert!(
            !verify_sibling_proof(&our_master, challenged_device, nonce, &bad_sig, &bad_pk),
            "a stranger's signature must NOT verify against our master"
        );

        // A tampered nonce / device id breaks the signature.
        assert!(
            !verify_sibling_proof(&our_master, challenged_device, "wrongnonce", &sig, &pk),
            "wrong nonce must not verify"
        );
        assert!(
            !verify_sibling_proof(&our_master, "12D3KooWotherDevice", nonce, &sig, &pk),
            "wrong challenged device must not verify"
        );
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
