//! Master-signed destruction orders: who may act on one, and what a friend does when
//! it is somebody else's identity that is gone. Three lanes carry the same
//! self-authenticating payload (the Olm sibling lane, its plaintext twin, the relay's
//! kill list), so the verify and judge step lives here once.

use tokio::sync::mpsc;

use crate::storage::MessageStore;
use super::crypto_handler::{
    build_destroy_identity, online_devices_for, revoke_self_device, send_encrypted_message,
    send_raw_to_peer, verify_destroy_identity,
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

/// Signature, targeting, and freshness against both the link time and the last
/// order applied.
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
    let Ok(store) = MessageStore::open(db_path, db_passphrase) else {
        return Verdict::RejectTransient("database unavailable");
    };
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
    let Ok(store) = MessageStore::open(db_path, db_passphrase) else { return };
    let master = order.master_peer_id.clone();
    let known = store.get_friend_status(&master).ok().flatten().is_some()
        || store.load_device_list(&master).ok().flatten().is_some();
    if !known {
        hollow_log!("[HOLLOW-DESTROY] Ignored a destruction order for an identity we do not know");
        return;
    }
    if identity_destroyed_at(&store, &master).is_some_and(|prev| order.issued_at_ms <= prev) {
        return;
    }
    let _ = store.save_setting(&destroyed_key(&master), &order.issued_at_ms.to_string());
    let _ = store.remove_peer_verified(&master);
    hollow_log!("[HOLLOW-DESTROY] Friend identity {master} reported destroyed");
    let _ = event_tx.send(NetworkEvent::IdentityDestroyedByFriend {
        master_peer_id: master,
        issued_at_ms: order.issued_at_ms,
    }).await;
}

/// The mnemonic recreated a destroyed identity. Warn, and clear the banner.
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
    local_master: &str,
    local_device: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    let Some(order) = decode_kill_blob(blob) else {
        hollow_log!("[HOLLOW-DESTROY] Kill signal blob is not a destruction order, acked and dropped");
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::KillAck);
        return;
    };
    let verdict = apply_own_order(
        event_tx, &order, local_master, local_device, db_path, db_passphrase,
    ).await;
    if matches!(verdict, Verdict::RejectPermanent(_)) {
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::KillAck);
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

/// Scope (b). Siblings drop the device on ingest, friends stop encrypting to it, and
/// a revoked device that somehow keeps running self-nukes on its own ingest.
#[allow(clippy::too_many_arguments)]
pub(crate) fn handle_publish_self_revocation(
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    local_master: &str,
    local_device: &str,
    is_invisible: bool,
    db_path: &str,
    db_passphrase: &str,
) -> bool {
    let signed = revoke_self_device(master_keypair, local_device, db_path, db_passphrase);
    let peers: Vec<String> = ws_room_peers.values().flat_map(|p| p.iter().cloned()).collect();
    let mut sent = 0;
    for pid in peers {
        if pid == local_master || pid == local_device {
            continue;
        }
        super::social::send_own_profile_with_device_list(
            ws_cmd_tx, ws_room_peers, local_master, master_keypair, local_device,
            &pid, signed.clone(), is_invisible, db_path, db_passphrase,
        );
        sent += 1;
    }
    hollow_log!("[HOLLOW-DESTROY] Self-revocation published to {sent} peer(s)");
    sent > 0
}

/// One signed order down all three lanes. The plaintext twin ALWAYS follows the Olm
/// envelope: a sibling with no live session would otherwise hear nothing. Devices not
/// in a room are parked on the relay's kill list.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_publish_destroy_identity(
    olm: &mut crate::crypto::OlmManager,
    crypto_store: &crate::crypto::CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    local_master: &str,
    local_device: &str,
    targets: Vec<String>,
    notify_friends: bool,
    db_path: &str,
    db_passphrase: &str,
) -> u32 {
    let order = build_destroy_identity(master_keypair, now_ms(), targets, notify_friends);
    let plain = serde_json::to_vec(&HavenMessage::IdentityDestroyed {
        destroy: Box::new(order.clone()),
    })
    .unwrap_or_default();
    let envelope = serde_json::to_string(&MessageEnvelope::DestroyIdentityOrder {
        destroy: Box::new(order.clone()),
    })
    .unwrap_or_default();

    let online: Vec<String> = online_devices_for(ws_room_peers, local_master)
        .into_iter()
        .filter(|d| d != local_device)
        .collect();
    let mut reached = 0u32;
    for dev in &online {
        let encrypted = send_encrypted_message(
            olm, crypto_store, dev, &envelope, event_tx, ws_cmd_tx, ws_room_peers,
        ).await;
        send_raw_to_peer(ws_cmd_tx, ws_room_peers, dev, plain.clone());
        if encrypted {
            reached += 1;
        }
    }

    let offline: Vec<String> = super::resolver::devices_for(local_master)
        .into_iter()
        .filter(|d| d != local_device && !online.contains(d))
        .collect();
    if !offline.is_empty()
        && let Some(blob) = encode_kill_blob(&order)
    {
        for chunk in offline.chunks(16) {
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::KillDeposit {
                targets: chunk.to_vec(),
                issued_at_ms: order.issued_at_ms,
                blob: blob.clone(),
            });
        }
    }
    hollow_log!(
        "[HOLLOW-DESTROY] Destruction order: {reached} sibling session(s), {} parked",
        offline.len()
    );

    if notify_friends {
        announce_to_friends(ws_cmd_tx, local_master, &plain, db_path, db_passphrase);
    }
    reached
}

/// Each known device AND the bare master: the relay buffers under an absent target,
/// and a master-keyed buffer is replayed to whichever device next proves it owns that
/// inbox. The issuer is seconds from being wiped, so a retry queue could never drain.
fn announce_to_friends(
    ws_cmd_tx: &WsCmdTx,
    local_master: &str,
    plain: &[u8],
    db_path: &str,
    db_passphrase: &str,
) {
    let Ok(store) = MessageStore::open(db_path, db_passphrase) else { return };
    let Ok(friends) = store.load_friends(Some("accepted")) else { return };
    let mut told = 0;
    for (peer_id, _status, _dir, _req, _upd) in friends {
        let master = super::resolver::resolve(&peer_id);
        let room = dm_room_code(local_master, &master);
        let mut targets: Vec<String> = super::resolver::devices_for(&master);
        targets.push(master.clone());
        targets.sort();
        targets.dedup();
        for t in targets {
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
                room_code: room.clone(),
                target_peer: t,
                data: plain.to_vec(),
            });
        }
        told += 1;
    }
    hollow_log!("[HOLLOW-DESTROY] Destruction announced to {told} friend(s)");
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::native_identity::NativeKeypair;
    use super::super::crypto_handler::build_destroy_identity;

    fn temp_db() -> (tempfile::TempDir, String, String) {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("destroy.db").to_string_lossy().to_string();
        let pass = "7b".repeat(32);
        MessageStore::open(&path, &pass).expect("open");
        (dir, path, pass)
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
        let device = "12D3KooWThisDevice".to_string();

        let mut tampered = build_destroy_identity(&master, 5_000, Vec::new(), false);
        tampered.issued_at_ms = 6_000;
        assert_eq!(
            reason(&judge_own_order(&tampered, &me, &device, &path, &pass)),
            "bad signature",
        );

        let foreign = build_destroy_identity(&stranger, 5_000, Vec::new(), false);
        assert_eq!(
            reason(&judge_own_order(&foreign, &me, &device, &path, &pass)),
            "foreign master",
        );

        let elsewhere =
            build_destroy_identity(&master, 5_000, vec!["12D3KooWOther".into()], false);
        assert_eq!(
            reason(&judge_own_order(&elsewhere, &me, &device, &path, &pass)),
            "targets do not name this device",
        );

        // Issued against a device that no longer exists.
        stamp_device_link(&path, &pass, &device);
        let ancient = build_destroy_identity(&master, 1, Vec::new(), false);
        assert_eq!(
            reason(&judge_own_order(&ancient, &me, &device, &path, &pass)),
            "older than this device's link time",
        );

        let good = build_destroy_identity(&master, now_ms() + 1_000, Vec::new(), false);
        assert!(is_apply(&judge_own_order(&good, &me, &device, &path, &pass)));

        // The kill list re-sends until acked, so neither the same order nor an
        // older one may run twice.
        assert_eq!(
            reason(&judge_own_order(&good, &me, &device, &path, &pass)),
            "older than the last applied destroy",
        );
        let older = build_destroy_identity(&master, good.issued_at_ms - 1, Vec::new(), false);
        assert_eq!(
            reason(&judge_own_order(&older, &me, &device, &path, &pass)),
            "older than the last applied destroy",
        );

        let mine = build_destroy_identity(
            &master, good.issued_at_ms + 1, vec![device.clone(), "12D3KooWOther".into()], false,
        );
        assert!(is_apply(&judge_own_order(&mine, &me, &device, &path, &pass)));
    }

    /// A never-stamped device (a pre-upgrade install) must not be immune: with no
    /// link time the applied stamp is the only freshness rule left.
    #[test]
    fn destroy_without_a_link_stamp_still_applies_once() {
        let (_dir, path, pass) = temp_db();
        let master = NativeKeypair::from_secret_bytes(&[0x33u8; 32]);
        let me = master.peer_id();
        let order = build_destroy_identity(&master, 42, Vec::new(), false);
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
        let device = "dev-restart";
        let order = build_destroy_identity(&master, 4_242, Vec::new(), false);

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

    #[test]
    fn kill_blob_round_trips_and_rejects_junk() {
        let master = NativeKeypair::from_secret_bytes(&[0x44u8; 32]);
        let order = build_destroy_identity(&master, 9, vec!["a".into()], true);
        let blob = encode_kill_blob(&order).expect("encode");
        let back = decode_kill_blob(&blob).expect("decode");
        assert_eq!(back.sig_b64, order.sig_b64);
        assert_eq!(back.targets, order.targets);
        assert!(decode_kill_blob("not base64 at all !!").is_none());
    }
}
