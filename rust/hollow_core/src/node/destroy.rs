//! Destruction orders: who may act on one, and what a friend does when it is somebody
//! else's identity that is gone. Two lanes carry the same self-authenticating payload
//! (Olm, and the relay's kill list for a device Olm did not reach), so the verify and
//! judge step lives here once. The recovery phrase is the authority (design ID-1): an
//! order counts only under the identity's pinned recovery key, or from a member device
//! holding the phrase's permission; the master key alone speaks only for an identity
//! whose phrase was never typed on 0.12.

use tokio::sync::mpsc;

use crate::storage::MessageStore;
use super::crypto_handler::{
    destroy_order_authorised, online_devices_for, send_encrypted_message,
    send_encrypted_message_in_room, verify_destroy_identity, MAX_FUTURE_SKEW_MS,
};
use super::types::*;

/// An order older than this was issued against a device that no longer exists, so
/// acting on it would wipe a machine the user linked afterwards.
fn link_key(device_peer_id: &str) -> String {
    format!("device_linked_at_ms:{device_peer_id}")
}

/// The newest order each local device acted on this SESSION, keyed by device id so
/// harness nodes sharing a process stay independent.
///
/// Deliberately NOT persisted: the stamp is written BEFORE the wipe runs, so a disk
/// copy would turn "the wipe never finished" into a permanent refusal, acked, and
/// the device would survive forever. In RAM it only dedups the two copies of one
/// order within a session. A wiped device boots to Welcome and never authenticates
/// as that id again, so nothing is lost by forgetting it.
fn applied() -> &'static std::sync::Mutex<std::collections::HashMap<String, i64>> {
    static APPLIED: std::sync::OnceLock<
        std::sync::Mutex<std::collections::HashMap<String, i64>>,
    > = std::sync::OnceLock::new();
    APPLIED.get_or_init(Default::default)
}

fn last_applied(device_peer_id: &str) -> i64 {
    applied()
        .lock()
        .map(|m| m.get(device_peer_id).copied().unwrap_or(0))
        .unwrap_or(0)
}

fn mark_applied(device_peer_id: &str, issued_at_ms: i64) {
    if let Ok(mut m) = applied().lock() {
        m.insert(device_peer_id.to_string(), issued_at_ms);
    }
}

fn destroyed_key(master: &str) -> String {
    format!("identity_destroyed:{master}")
}

/// The newest friend order ever applied for `master`. Unlike the banner stamp it
/// is never cleared, so an order replayed after the identity came back stays old.
fn destroy_floor_key(master: &str) -> String {
    format!("identity_destroy_floor:{master}")
}

pub(crate) fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

fn read_i64(store: &MessageStore, key: &str) -> i64 {
    store
        .load_setting(key)
        .ok()
        .flatten()
        .and_then(|v| v.parse::<i64>().ok())
        .unwrap_or(0)
}

/// Stamped once, at the first start after `identity.device` was created. A re-linked
/// device has a NEW id and no row in the imported database, so it stamps fresh.
pub(crate) fn stamp_device_link(db_path: &str, db_passphrase: &str, device_peer_id: &str) {
    let Ok(store) = MessageStore::open(db_path, db_passphrase) else { return };
    let key = link_key(device_peer_id);
    if store.load_setting(&key).ok().flatten().is_some() {
        return;
    }
    let _ = store.save_setting(&key, &now_ms().to_string());
}

/// Whether the identity's authority stands behind `order`, judged against the roster
/// we hold for it: its pinned recovery key, and its members for a permission. `None`
/// when it cannot be judged: what we hold does not read, or for our own identity we
/// hold neither a roster nor a 0.11 list, so the master key alone never stands in.
fn authorised(store: &MessageStore, order: &DestroyIdentity, own: bool) -> Option<bool> {
    match super::roster_book::load_strict(store, &order.master_peer_id) {
        Ok(Some(roster)) => {
            let state = super::roster_book::fold(store, &roster);
            Some(destroy_order_authorised(order, &roster.r_pub, &state))
        }
        Ok(None) if own && !matches!(store.load_device_list(&order.master_peer_id), Ok(Some(_))) => None,
        Ok(None) => Some(destroy_order_authorised(order, "", &Default::default())),
        Err(e) => {
            hollow_log!("[HOLLOW-DESTROY] The roster an order is judged against does not read: {e}");
            None
        }
    }
}

/// An order dated past our clock by more than any signed statement may be: it would
/// outlive every device linked before its date and floor every genuine order after it.
fn from_the_future(order: &DestroyIdentity) -> bool {
    order.issued_at_ms > now_ms().saturating_add(MAX_FUTURE_SKEW_MS)
}

pub(crate) fn identity_destroyed_at(store: &MessageStore, master: &str) -> Option<i64> {
    store
        .load_setting(&destroyed_key(master))
        .ok()
        .flatten()
        .and_then(|v| v.parse::<i64>().ok())
}

pub(crate) enum Verdict {
    Apply,
    /// The order can never become valid for us. The relay is acked anyway, so it
    /// stops re-sending a blob we will refuse for a year.
    RejectPermanent(&'static str),
    /// Something local failed. NEVER acked: the order was not judged, so the relay
    /// must keep it and hand it over again on the next auth.
    RejectTransient(&'static str),
}

/// Signature, the phrase's authority, targeting, and freshness against both the link
/// time and the last order applied.
pub(crate) fn judge_own_order(
    order: &DestroyIdentity,
    local_master: &str,
    local_device: &str,
    db_path: &str,
    db_passphrase: &str,
) -> Verdict {
    if !verify_destroy_identity(order) {
        return Verdict::RejectPermanent("bad signature");
    }
    if order.master_peer_id != local_master {
        return Verdict::RejectPermanent("foreign master");
    }
    if !order.targets.is_empty() && !order.targets.iter().any(|t| t == local_device) {
        return Verdict::RejectPermanent("targets do not name this device");
    }
    if from_the_future(order) {
        return Verdict::RejectPermanent("dated in the future");
    }
    let Ok(store) = MessageStore::open(db_path, db_passphrase) else {
        return Verdict::RejectTransient("database unavailable");
    };
    match authorised(&store, order, true) {
        Some(true) => {}
        Some(false) => return Verdict::RejectPermanent("not signed with the recovery phrase"),
        None => return Verdict::RejectTransient("our roster could not be read"),
    }
    let linked_at = read_i64(&store, &link_key(local_device));
    if linked_at > 0 && order.issued_at_ms < linked_at {
        return Verdict::RejectPermanent("older than this device's link time");
    }
    if order.issued_at_ms <= last_applied(local_device) {
        return Verdict::RejectPermanent("older than the last applied destroy");
    }
    mark_applied(local_device, order.issued_at_ms);
    Verdict::Apply
}

/// The wipe itself runs in `api::wipe`, shared with the fetch isolate.
async fn apply_own_order(
    event_tx: &mpsc::Sender<NetworkEvent>,
    order: &DestroyIdentity,
    local_master: &str,
    local_device: &str,
    db_path: &str,
    db_passphrase: &str,
) -> Verdict {
    let verdict = judge_own_order(order, local_master, local_device, db_path, db_passphrase);
    match verdict {
        Verdict::Apply => {
            hollow_log!("[HOLLOW-DESTROY] Destruction order accepted for this device");
            let _ = event_tx.send(NetworkEvent::DestroyReceived {
                scope: crate::identity::duress::SCOPE_IDENTITY.to_string(),
            }).await;
        }
        Verdict::RejectPermanent(reason) | Verdict::RejectTransient(reason) => {
            hollow_log!("[HOLLOW-DESTROY] Refused a destruction order: {reason}");
        }
    }
    verdict
}

/// SECURITY: the order proves itself, so who delivered it does not matter. What does
/// matter is that a stranger cannot make us write a row for an identity we have never
/// met, so the stamp is only recorded for a master we already know.
async fn apply_friend_order(
    event_tx: &mpsc::Sender<NetworkEvent>,
    order: &DestroyIdentity,
    db_path: &str,
    db_passphrase: &str,
) {
    if !verify_destroy_identity(order) {
        hollow_log!("[HOLLOW-DESTROY] Refused a friend destruction order: bad signature");
        return;
    }
    if from_the_future(order) {
        hollow_log!("[HOLLOW-DESTROY] Refused a friend destruction order: dated in the future");
        return;
    }
    let Ok(store) = MessageStore::open(db_path, db_passphrase) else { return };
    if authorised(&store, order, false) != Some(true) {
        hollow_log!("[HOLLOW-DESTROY] Refused a friend destruction order: not signed with the recovery phrase");
        return;
    }
    let master = order.master_peer_id.clone();
    let known = store.get_friend_status(&master).ok().flatten().is_some()
        || store.load_device_list(&master).ok().flatten().is_some();
    if !known {
        hollow_log!("[HOLLOW-DESTROY] Ignored a destruction order for an identity we do not know");
        return;
    }
    let floor = read_i64(&store, &destroy_floor_key(&master))
        .max(identity_destroyed_at(&store, &master).unwrap_or(0));
    if order.issued_at_ms <= floor {
        return;
    }
    let _ = store.save_setting(&destroy_floor_key(&master), &order.issued_at_ms.to_string());
    let _ = store.save_setting(&destroyed_key(&master), &order.issued_at_ms.to_string());
    let _ = store.remove_peer_verified(&master);
    hollow_log!("[HOLLOW-DESTROY] Friend identity {master} reported destroyed");
    let _ = event_tx.send(NetworkEvent::IdentityDestroyedByFriend {
        master_peer_id: master,
        issued_at_ms: order.issued_at_ms,
    }).await;
}

/// The mnemonic recreated a destroyed identity: a device list naming a device we
/// had never seen for it. Warn, and clear the banner.
pub(crate) async fn note_identity_reappeared(
    event_tx: &mpsc::Sender<NetworkEvent>,
    db_path: &str,
    db_passphrase: &str,
    master: &str,
) {
    let Ok(store) = MessageStore::open(db_path, db_passphrase) else { return };
    if identity_destroyed_at(&store, master).is_none() {
        return;
    }
    let _ = store.save_setting(&destroyed_key(master), "");
    drop(store);
    super::security_alerts::note_identity_reappeared(
        event_tx, db_path, db_passphrase, master,
    ).await;
}

// -- Receive lanes --

pub(crate) async fn handle_envelope_destroy_identity(
    event_tx: &mpsc::Sender<NetworkEvent>,
    order: &DestroyIdentity,
    local_master: &str,
    local_device: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    apply_own_order(event_tx, order, local_master, local_device, db_path, db_passphrase).await;
}

pub(crate) async fn handle_identity_destroyed(
    event_tx: &mpsc::Sender<NetworkEvent>,
    order: &DestroyIdentity,
    local_master: &str,
    local_device: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    if order.master_peer_id == local_master {
        apply_own_order(event_tx, order, local_master, local_device, db_path, db_passphrase).await;
    } else {
        apply_friend_order(event_tx, order, db_path, db_passphrase).await;
    }
}

/// ACK RULE: ack after a wipe (`api::wipe` sends that one) and after a PERMANENT
/// rejection, never after a transient one. Without the ack the relay re-sends on
/// every auth for a year, and any authed peer's junk deposit rides along.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_kill_signal(
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &WsCmdTx,
    blob: &str,
    signal: super::ws_client::KillSignalId,
    local_master: &str,
    local_device: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    let ack = super::ws_client::WsCommand::KillAck { signal: Some(signal) };
    let Some(order) = decode_kill_blob(blob) else {
        hollow_log!("[HOLLOW-DESTROY] Kill signal blob is not a destruction order, acked and dropped");
        let _ = ws_cmd_tx.send(ack);
        return;
    };
    let verdict = apply_own_order(
        event_tx, &order, local_master, local_device, db_path, db_passphrase,
    ).await;
    if matches!(verdict, Verdict::RejectPermanent(_)) {
        let _ = ws_cmd_tx.send(ack);
    }
}

pub(crate) fn decode_kill_blob(blob: &str) -> Option<DestroyIdentity> {
    use base64::Engine;
    let raw = base64::engine::general_purpose::STANDARD.decode(blob).ok()?;
    serde_json::from_slice::<DestroyIdentity>(&raw).ok()
}

pub(crate) fn encode_kill_blob(order: &DestroyIdentity) -> Option<String> {
    use base64::Engine;
    let json = serde_json::to_vec(order).ok()?;
    Some(base64::engine::general_purpose::STANDARD.encode(json))
}

// -- Send lanes --

/// Scope (b). This device removes itself: siblings drop it on ingest and friends stop
/// encrypting to it.
#[allow(clippy::too_many_arguments)]
pub(crate) fn handle_publish_self_revocation(
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    server_states: &std::collections::HashMap<String, crate::crdt::server_state::ServerState>,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    local_master: &str,
    local_device: &str,
    is_invisible: bool,
    db_path: &str,
    db_passphrase: &str,
) -> bool {
    let Some(signed) = super::roster_book::remove_self(master_keypair, device_keypair, db_path, db_passphrase) else {
        return false;
    };
    let peers: Vec<String> = ws_room_peers.values().flat_map(|p| p.iter().cloned()).collect();
    let mut sent = 0;
    for pid in peers {
        if pid == local_master || pid == local_device {
            continue;
        }
        super::social::send_own_profile_with_device_list(
            ws_cmd_tx, ws_room_peers, server_states, local_master, master_keypair,
            &pid, signed.clone(), is_invisible, db_path, db_passphrase,
        );
        sent += 1;
    }
    hollow_log!("[HOLLOW-DESTROY] Self-revocation published to {sent} peer(s)");
    sent > 0
}

/// One signed order to our other devices and, when it says so, our friends. A sibling
/// the Olm lane did not reach (offline, or no session) is parked on the relay's kill
/// list instead. The order arrives signed: the phrase never enters the node.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_publish_destroy_identity(
    olm: &mut crate::crypto::OlmManager,
    crypto_store: &crate::crypto::CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    local_master: &str,
    local_device: &str,
    order: DestroyIdentity,
    db_path: &str,
    db_passphrase: &str,
) -> u32 {
    let notify_friends = order.notify_friends;
    let envelope = serde_json::to_string(&MessageEnvelope::DestroyIdentityOrder {
        destroy: Box::new(order.clone()),
    })
    .unwrap_or_default();

    let mut reached_devices: Vec<String> = Vec::new();
    for dev in online_devices_for(ws_room_peers, local_master) {
        if dev == local_device || !olm.has_session(&dev) {
            continue;
        }
        if send_encrypted_message(olm, crypto_store, &dev, &envelope, event_tx, ws_cmd_tx, ws_room_peers).await {
            reached_devices.push(dev);
        }
    }

    let parked: Vec<String> = super::resolver::devices_for(local_master)
        .into_iter()
        .filter(|d| d != local_device && !reached_devices.contains(d))
        .collect();
    if !parked.is_empty()
        && let Some(blob) = encode_kill_blob(&order)
    {
        for chunk in parked.chunks(16) {
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::KillDeposit {
                targets: chunk.to_vec(),
                issued_at_ms: order.issued_at_ms,
                blob: blob.clone(),
            });
        }
    }
    hollow_log!(
        "[HOLLOW-DESTROY] Destruction order: {} sibling session(s), {} parked",
        reached_devices.len(),
        parked.len()
    );

    if notify_friends {
        announce_to_friends(olm, crypto_store, event_tx, ws_cmd_tx, local_master, &order, db_path, db_passphrase).await;
    }
    reached_devices.len() as u32
}

/// Every friend device we hold a session with, inside its DM room so the relay
/// buffers it for one that is offline. The issuer is seconds from being wiped, so a
/// retry queue could never drain: a device we never keyed with hears nothing.
#[allow(clippy::too_many_arguments)]
async fn announce_to_friends(
    olm: &mut crate::crypto::OlmManager,
    crypto_store: &crate::crypto::CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &WsCmdTx,
    local_master: &str,
    order: &DestroyIdentity,
    db_path: &str,
    db_passphrase: &str,
) {
    let Ok(store) = MessageStore::open(db_path, db_passphrase) else { return };
    let Ok(friends) = store.load_friends(Some("accepted")) else { return };
    let Some(carried) = super::olm_lane::carried_json(&HavenMessage::IdentityDestroyed {
        destroy: Box::new(order.clone()),
    }) else {
        return;
    };
    let mut told = 0;
    for (peer_id, _status, _dir, _req, _upd) in friends {
        let master = super::resolver::resolve(&peer_id);
        let room = dm_room_code(local_master, &master);
        // The bare master is a device too for a single-device identity of old.
        let mut devices = super::resolver::devices_for(&master);
        devices.push(master.clone());
        devices.sort();
        devices.dedup();
        for device in devices {
            if olm.has_session(&device)
                && send_encrypted_message_in_room(olm, crypto_store, &device, &room, &carried, event_tx, ws_cmd_tx).await
            {
                told += 1;
            }
        }
    }
    hollow_log!("[HOLLOW-DESTROY] Destruction announced to {told} friend device(s)");
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::native_identity::NativeKeypair;
    use super::super::crypto_handler::build_destroy_identity;

    fn temp_db() -> (crate::test_tmp::TestDir, String, String) {
        let dir = crate::test_tmp::tempdir().expect("tempdir");
        let path = dir.path().join("destroy.db").to_string_lossy().to_string();
        let pass = "7b".repeat(32);
        MessageStore::open(&path, &pass).expect("open");
        (dir, path, pass)
    }

    /// Our own identity as a node holds it before its phrase was typed on 0.12: a
    /// roster with no recovery key, so the master key still speaks for it.
    fn legacy_own(path: &str, pass: &str, master: &str) {
        let row = serde_json::json!({ "master": master }).to_string();
        MessageStore::open(path, pass).unwrap().save_device_list(master, &row, 0, &[], 0).unwrap();
    }

    fn is_apply(v: &Verdict) -> bool {
        matches!(v, Verdict::Apply)
    }

    fn reason(v: &Verdict) -> &'static str {
        match v {
            Verdict::Apply => "apply",
            Verdict::RejectPermanent(r) | Verdict::RejectTransient(r) => r,
        }
    }

    /// Each clause is a way a captured or forged order could wipe a machine it has
    /// no business touching.
    #[test]
    fn destroy_identity_signature_and_freshness_rules() {
        let (_dir, path, pass) = temp_db();
        let master = NativeKeypair::from_secret_bytes(&[0x11u8; 32]);
        let stranger = NativeKeypair::from_secret_bytes(&[0x22u8; 32]);
        let me = master.peer_id();
        let device = NativeKeypair::from_secret_bytes(&[0x12u8; 32]).peer_id();
        let other = NativeKeypair::from_secret_bytes(&[0x13u8; 32]).peer_id();
        legacy_own(&path, &pass, &me);

        let mut tampered = build_destroy_identity(&master, None, 5_000, Vec::new(), false);
        tampered.issued_at_ms = 6_000;
        assert_eq!(
            reason(&judge_own_order(&tampered, &me, &device, &path, &pass)),
            "bad signature",
        );

        let foreign = build_destroy_identity(&stranger, None, 5_000, Vec::new(), false);
        assert_eq!(
            reason(&judge_own_order(&foreign, &me, &device, &path, &pass)),
            "foreign master",
        );

        let elsewhere = build_destroy_identity(&master, None, 5_000, vec![other.clone()], false);
        assert_eq!(
            reason(&judge_own_order(&elsewhere, &me, &device, &path, &pass)),
            "targets do not name this device",
        );

        // Issued against a device that no longer exists.
        stamp_device_link(&path, &pass, &device);
        let ancient = build_destroy_identity(&master, None, 1, Vec::new(), false);
        assert_eq!(
            reason(&judge_own_order(&ancient, &me, &device, &path, &pass)),
            "older than this device's link time",
        );

        let good = build_destroy_identity(&master, None, now_ms() + 1_000, Vec::new(), false);
        assert!(is_apply(&judge_own_order(&good, &me, &device, &path, &pass)));

        // The kill list re-sends until acked, so neither the same order nor an
        // older one may run twice.
        assert_eq!(
            reason(&judge_own_order(&good, &me, &device, &path, &pass)),
            "older than the last applied destroy",
        );
        let older = build_destroy_identity(&master, None, good.issued_at_ms - 1, Vec::new(), false);
        assert_eq!(
            reason(&judge_own_order(&older, &me, &device, &path, &pass)),
            "older than the last applied destroy",
        );

        let mine = build_destroy_identity(&master, None, good.issued_at_ms + 1, vec![device.clone(), other], false);
        assert!(is_apply(&judge_own_order(&mine, &me, &device, &path, &pass)));
    }

    /// The targets join with ',' under the signature, so a carrier must not be able to
    /// re-split them: ["A","B"] as ["A,B"] names nobody, and an every-device order []
    /// would sign the same as [""].
    #[test]
    fn a_destroy_orders_targets_cannot_be_re_split_under_its_signature() {
        let master = NativeKeypair::from_secret_bytes(&[0x14u8; 32]);
        let (a, b) = (
            NativeKeypair::from_secret_bytes(&[0x15u8; 32]).peer_id(),
            NativeKeypair::from_secret_bytes(&[0x16u8; 32]).peer_id(),
        );
        let order = build_destroy_identity(&master, None, 5_000, vec![a.clone(), b.clone()], false);
        assert!(verify_destroy_identity(&order), "control");

        let mut merged = order.clone();
        merged.targets = vec![format!("{},{}", merged.targets[0], merged.targets[1])];
        assert!(!verify_destroy_identity(&merged), "two targets re-split as one still verified");

        let everyone = build_destroy_identity(&master, None, 5_000, Vec::new(), false);
        let mut blank = everyone.clone();
        blank.targets = vec![String::new()];
        assert!(!verify_destroy_identity(&blank), "an every-device order verified as naming \"\"");
    }

    /// A never-stamped device (a pre-upgrade install) must not be immune: with no
    /// link time the applied stamp is the only freshness rule left.
    #[test]
    fn destroy_without_a_link_stamp_still_applies_once() {
        let (_dir, path, pass) = temp_db();
        let master = NativeKeypair::from_secret_bytes(&[0x33u8; 32]);
        let me = master.peer_id();
        legacy_own(&path, &pass, &me);
        let order = build_destroy_identity(&master, None, 42, Vec::new(), false);
        assert!(is_apply(&judge_own_order(&order, &me, "dev-nostamp", &path, &pass)));
        assert!(!is_apply(&judge_own_order(&order, &me, "dev-nostamp", &path, &pass)));
    }

    /// The stamp is written BEFORE the wipe runs, so persisting it would turn "the
    /// wipe never finished" into a permanent refusal that gets acked, and the device
    /// would survive forever. A FRESH process must act on the same order again.
    #[test]
    fn destroy_applied_stamp_does_not_survive_a_restart() {
        let (_dir, path, pass) = temp_db();
        let master = NativeKeypair::from_secret_bytes(&[0x55u8; 32]);
        let me = master.peer_id();
        legacy_own(&path, &pass, &me);
        let device = "dev-restart";
        let order = build_destroy_identity(&master, None, 4_242, Vec::new(), false);

        assert!(is_apply(&judge_own_order(&order, &me, device, &path, &pass)));
        assert!(!is_apply(&judge_own_order(&order, &me, device, &path, &pass)));

        // What a relaunch does to it.
        applied().lock().unwrap().clear();
        assert!(
            is_apply(&judge_own_order(&order, &me, device, &path, &pass)),
            "a re-delivery after a wipe that never completed must fire again",
        );
        assert_eq!(
            crate::storage::MessageStore::open(&path, &pass)
                .unwrap()
                .load_setting("destroy_applied_at_ms")
                .unwrap(),
            None,
            "nothing about an order in flight may be persisted",
        );
    }

    /// HOL-SEC-034. Clearing the banner on reappearance erased the stamp, so the old
    /// order, which every notified friend and the relay hold, applied again: banner
    /// back and verified flag gone, as often as anyone replayed it.
    #[tokio::test]
    async fn authz_a_friend_destroy_order_applies_once_even_after_the_identity_returns() {
        let (_dir, path, pass) = temp_db();
        let friend = NativeKeypair::from_secret_bytes(&[0x66u8; 32]);
        let master = friend.peer_id();
        let store = || MessageStore::open(&path, &pass).unwrap();
        store().save_friend(&master, "accepted", "outgoing", 1).unwrap();
        let (event_tx, _event_rx) = mpsc::channel::<NetworkEvent>(16);

        let order = build_destroy_identity(&friend, None, 7_000, Vec::new(), true);
        apply_friend_order(&event_tx, &order, &path, &pass).await;
        assert_eq!(identity_destroyed_at(&store(), &master), Some(7_000));
        note_identity_reappeared(&event_tx, &path, &pass, &master).await;
        assert_eq!(identity_destroyed_at(&store(), &master), None);

        store().set_peer_verified(&master).unwrap();
        apply_friend_order(&event_tx, &order, &path, &pass).await;
        assert_eq!(
            identity_destroyed_at(&store(), &master),
            None,
            "HOL-SEC-034: a replayed destroy order raised the banner again",
        );
        assert!(
            store().is_peer_verified(&master).unwrap(),
            "HOL-SEC-034: a replayed destroy order removed the verified flag",
        );

        let newer = build_destroy_identity(&friend, None, 8_000, Vec::new(), true);
        apply_friend_order(&event_tx, &newer, &path, &pass).await;
        assert_eq!(identity_destroyed_at(&store(), &master), Some(8_000));
    }

    #[test]
    fn kill_blob_round_trips_and_rejects_junk() {
        let master = NativeKeypair::from_secret_bytes(&[0x44u8; 32]);
        let order = build_destroy_identity(&master, None, 9, vec!["a".into()], true);
        let blob = encode_kill_blob(&order).expect("encode");
        let back = decode_kill_blob(&blob).expect("decode");
        assert_eq!(back.sig_b64, order.sig_b64);
        assert_eq!(back.targets, order.targets);
        assert!(decode_kill_blob("not base64 at all !!").is_none());
    }

    /// C-IDENTITY-10. An order dated past our clock by more than any signed statement
    /// may be is refused for good, on our own devices and at friends: it would outlive
    /// every device linked before its date and floor every genuine order after it.
    #[tokio::test]
    async fn a_destroy_order_from_the_future_is_refused() {
        let (_dir, path, pass) = temp_db();
        let master = NativeKeypair::from_secret_bytes(&[0x77u8; 32]);
        let me = master.peer_id();
        legacy_own(&path, &pass, &me);
        let ahead = now_ms() + super::super::crypto_handler::MAX_FUTURE_SKEW_MS + 60_000;
        let order = build_destroy_identity(&master, None, ahead, Vec::new(), false);
        assert!(
            matches!(judge_own_order(&order, &me, "dev-future", &path, &pass), Verdict::RejectPermanent(_)),
            "an order from the future wiped this device",
        );

        let friend = NativeKeypair::from_secret_bytes(&[0x78u8; 32]);
        MessageStore::open(&path, &pass).unwrap().save_friend(&friend.peer_id(), "accepted", "outgoing", 1).unwrap();
        let (event_tx, _event_rx) = mpsc::channel::<NetworkEvent>(16);
        let order = build_destroy_identity(&friend, None, ahead, Vec::new(), true);
        apply_friend_order(&event_tx, &order, &path, &pass).await;
        let store = MessageStore::open(&path, &pass).unwrap();
        assert_eq!(identity_destroyed_at(&store, &friend.peer_id()), None, "a friend's order from the future applied");
    }

    /// C-IDENTITY-11. Our own roster unread is never "no recovery key yet": an order
    /// waits (never acked) until it can be judged, and only a 0.11 list still lets the
    /// master key speak alone.
    #[test]
    fn a_destroy_order_is_never_judged_without_our_roster() {
        let (_dir, path, pass) = temp_db();
        let master = NativeKeypair::from_secret_bytes(&[0x79u8; 32]);
        let me = master.peer_id();
        let order = build_destroy_identity(&master, None, now_ms(), Vec::new(), false);
        let judge = || judge_own_order(&order, &me, "dev-unread", &path, &pass);
        assert!(matches!(judge(), Verdict::RejectTransient(_)), "no roster at all judged as legacy");

        let store = MessageStore::open(&path, &pass).unwrap();
        store.save_device_list(&me, r#"{"master": 5}"#, 0, &[], 0).unwrap();
        assert!(matches!(judge(), Verdict::RejectTransient(_)), "a roster that does not read judged as legacy");

        let old = super::super::crypto_handler::build_signed_device_list(&master, 3, vec!["12D3KooWOld".into()], vec![]);
        store.save_device_list(&me, &serde_json::to_string(&old).unwrap(), 3, &old.devices, 0).unwrap();
        assert!(is_apply(&judge()), "a 0.11 list is the legacy identity's");
    }

    /// C-IDENTITY-11 at a friend: a roster we hold for it that does not read never lets
    /// the master key alone report the identity destroyed.
    #[tokio::test]
    async fn a_friend_order_is_never_judged_without_its_roster() {
        let (_dir, path, pass) = temp_db();
        let store = MessageStore::open(&path, &pass).unwrap();
        let (event_tx, _event_rx) = mpsc::channel::<NetworkEvent>(16);
        for (tag, row) in [(0x7au8, r#"{"master": 5}"#), (0x7b, "{not json")] {
            let friend = NativeKeypair::from_secret_bytes(&[tag; 32]);
            let master = friend.peer_id();
            store.save_friend(&master, "accepted", "outgoing", 1).unwrap();
            store.save_device_list(&master, row, 0, &[], 0).unwrap();
            apply_friend_order(&event_tx, &build_destroy_identity(&friend, None, 7_000, Vec::new(), true), &path, &pass).await;
            assert_eq!(identity_destroyed_at(&store, &master), None, "{row}: an unread roster judged as legacy");
        }
    }
}
