//! Visible key/device change warnings (Issue 1-C).
//!
//! Not "warn when the Olm key changes": since key exchange is authenticated
//! ([`super::crypto_handler::REQUIRE_SIGNED_KEY_EXCHANGE`]) a changed key must
//! have been signed by that device's real Ed25519 key, so it means the contact
//! REINSTALLED. The signal that still carries information is a NEW DEVICE
//! appearing for a contact: that is the real-world attack shape, and it is
//! detectable because the device list is master-signed. So [`KIND_NEW_DEVICE`]
//! is a WARNING and [`KIND_KEY_CHANGED`] only a notice.
//!
//! Deliberately NOT alerted: first contact (a baseline, not a change, and
//! alerting there trains users to dismiss without reading), our own devices
//! (the linked-devices UI is where the user is the actor), and device REMOVAL
//! (revocation is the user cutting a device off, a safe act).
//!
//! Alerts are deduplicated by a deterministic id, because device lists are
//! re-ingested on every reconnect: a dismissed warning stays dismissed.

use tokio::sync::mpsc;

use super::types::NetworkEvent;

/// A device was added to a contact's master-signed device list.
pub(crate) const KIND_NEW_DEVICE: &str = "new_device";

/// A contact's per-device Olm identity key changed — they reinstalled or re-keyed.
pub(crate) const KIND_KEY_CHANGED: &str = "identity_key_changed";

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

/// Persist an alert and, if it is new, emit it live.
///
/// Returns `true` when the alert was newly recorded. The store write is the
/// dedup authority — emitting is downstream of it, so a re-ingested device list
/// can never re-raise a warning the user already dismissed.
async fn record(
    event_tx: &mpsc::Sender<NetworkEvent>,
    db_path: &str,
    db_passphrase: &str,
    master_peer_id: &str,
    kind: &str,
    detail: &str,
) -> bool {
    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else {
        return false;
    };
    let created_at = now_ms();
    match store.record_security_alert(master_peer_id, kind, detail, created_at) {
        Ok(true) => {
            hollow_log!(
                "[HOLLOW-SECURITY] Alert for {master_peer_id}: {kind} ({detail})"
            );
            let _ = event_tx
                .send(NetworkEvent::SecurityAlert {
                    peer_id: master_peer_id.to_string(),
                    kind: kind.to_string(),
                    detail: detail.to_string(),
                    created_at,
                })
                .await;
            true
        }
        Ok(false) => false,
        Err(e) => {
            hollow_log!("[HOLLOW-SECURITY] Failed to record alert: {e}");
            false
        }
    }
}

/// Warn that devices joined a CONTACT's identity.
///
/// `previously_known` is the device set held BEFORE this ingest; an empty set
/// means first contact, which records nothing, because "this person has
/// devices" is not news. `local_master_peer_id` guards the self case: our own
/// siblings surface in linked-devices, not as a warning.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn note_new_devices(
    event_tx: &mpsc::Sender<NetworkEvent>,
    db_path: &str,
    db_passphrase: &str,
    local_master_peer_id: &str,
    master_peer_id: &str,
    previously_known: &[String],
    now_known: &[String],
) {
    if master_peer_id == local_master_peer_id {
        return; // our own device set — the user is the actor
    }
    if previously_known.is_empty() {
        return; // first contact establishes the baseline, it is not a change
    }
    for device in now_known {
        if previously_known.iter().any(|d| d == device) {
            continue;
        }
        record(
            event_tx, db_path, db_passphrase, master_peer_id, KIND_NEW_DEVICE, device,
        )
        .await;
    }
}

/// Pin a contact device's Olm identity key, and notice when it changes.
///
/// Trust-on-first-use: the first key we complete an exchange with is pinned
/// silently. A LATER, DIFFERENT key for the same device is a notice and the pin
/// moves forward, because the exchange was authenticated, so the user is being
/// told they reinstalled rather than asked to adjudicate an attack. The alert is
/// filed under `master_peer_id`; the pin itself is keyed by DEVICE.
pub(crate) async fn note_olm_identity_key(
    event_tx: &mpsc::Sender<NetworkEvent>,
    db_path: &str,
    db_passphrase: &str,
    local_master_peer_id: &str,
    master_peer_id: &str,
    device_peer_id: &str,
    identity_key: &str,
) {
    if master_peer_id == local_master_peer_id || identity_key.is_empty() {
        return;
    }
    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else {
        return;
    };
    let previous = match store.get_olm_key_pin(device_peer_id) {
        Ok(p) => p,
        Err(e) => {
            hollow_log!("[HOLLOW-SECURITY] Failed to read olm key pin: {e}");
            return;
        }
    };
    match previous {
        // Unchanged — the overwhelmingly common path. No write, no event.
        Some(ref pinned) if pinned == identity_key => {}
        Some(_) => {
            // Move the pin forward FIRST: if the alert write fails we still
            // must not re-warn about the same change on every reconnect.
            let _ = store.set_olm_key_pin(device_peer_id, identity_key);
            drop(store);
            record(
                event_tx, db_path, db_passphrase, master_peer_id, KIND_KEY_CHANGED,
                device_peer_id,
            )
            .await;
        }
        // First exchange with this device — establish the pin silently.
        None => {
            let _ = store.set_olm_key_pin(device_peer_id, identity_key);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::MessageStore;

    fn temp_db() -> (tempfile::TempDir, String, String) {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("alerts.db").to_string_lossy().to_string();
        let pass = "0123456789abcdef0123456789abcdef".to_string();
        // Force schema creation.
        MessageStore::open(&path, &pass).expect("open");
        (dir, path, pass)
    }

    fn channel() -> (mpsc::Sender<NetworkEvent>, mpsc::Receiver<NetworkEvent>) {
        mpsc::channel(32)
    }

    #[tokio::test]
    async fn first_contact_does_not_warn() {
        let (_dir, path, pass) = temp_db();
        let (tx, mut rx) = channel();
        note_new_devices(
            &tx, &path, &pass, "me", "friend", &[], &["devA".into(), "devB".into()],
        )
        .await;
        assert!(rx.try_recv().is_err(), "baseline must not raise a warning");
        let store = MessageStore::open(&path, &pass).unwrap();
        assert!(store.get_security_alerts().unwrap().is_empty());
    }

    #[tokio::test]
    async fn a_device_added_later_warns_once() {
        let (_dir, path, pass) = temp_db();
        let (tx, mut rx) = channel();
        let before = vec!["devA".to_string()];
        let after = vec!["devA".to_string(), "devB".to_string()];

        note_new_devices(&tx, &path, &pass, "me", "friend", &before, &after).await;
        match rx.try_recv() {
            Ok(NetworkEvent::SecurityAlert { peer_id, kind, detail, .. }) => {
                assert_eq!(peer_id, "friend");
                assert_eq!(kind, KIND_NEW_DEVICE);
                assert_eq!(detail, "devB");
            }
            _ => panic!("expected a SecurityAlert event"),
        }

        // A reconnect re-ingests the same list — must NOT warn again.
        note_new_devices(&tx, &path, &pass, "me", "friend", &before, &after).await;
        assert!(rx.try_recv().is_err(), "re-ingest must not re-warn");

        let store = MessageStore::open(&path, &pass).unwrap();
        assert_eq!(store.get_security_alerts().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn our_own_devices_never_warn() {
        let (_dir, path, pass) = temp_db();
        let (tx, mut rx) = channel();
        note_new_devices(
            &tx, &path, &pass, "me", "me", &["devA".into()],
            &["devA".into(), "devB".into()],
        )
        .await;
        assert!(rx.try_recv().is_err(), "own siblings are not a warning");
    }

    #[tokio::test]
    async fn removing_a_device_is_not_an_alert() {
        let (_dir, path, pass) = temp_db();
        let (tx, mut rx) = channel();
        note_new_devices(
            &tx, &path, &pass, "me", "friend",
            &["devA".into(), "devB".into()], &["devA".into()],
        )
        .await;
        assert!(rx.try_recv().is_err(), "revocation is a safe act");
    }

    #[tokio::test]
    async fn olm_key_pins_on_first_use_then_notices_a_change() {
        let (_dir, path, pass) = temp_db();
        let (tx, mut rx) = channel();

        // First exchange — silent pin.
        note_olm_identity_key(&tx, &path, &pass, "me", "friend", "devA", "key1").await;
        assert!(rx.try_recv().is_err(), "first use must be silent");
        let store = MessageStore::open(&path, &pass).unwrap();
        assert_eq!(store.get_olm_key_pin("devA").unwrap().as_deref(), Some("key1"));
        drop(store);

        // Same key again — still silent, no churn.
        note_olm_identity_key(&tx, &path, &pass, "me", "friend", "devA", "key1").await;
        assert!(rx.try_recv().is_err(), "unchanged key must not alert");

        // Re-key — one notice, and the pin moves forward.
        note_olm_identity_key(&tx, &path, &pass, "me", "friend", "devA", "key2").await;
        match rx.try_recv() {
            Ok(NetworkEvent::SecurityAlert { peer_id, kind, detail, .. }) => {
                assert_eq!(peer_id, "friend");
                assert_eq!(kind, KIND_KEY_CHANGED);
                assert_eq!(detail, "devA");
            }
            _ => panic!("expected a SecurityAlert event"),
        }
        let store = MessageStore::open(&path, &pass).unwrap();
        assert_eq!(store.get_olm_key_pin("devA").unwrap().as_deref(), Some("key2"));
        drop(store);

        // The new key is now the pin — no repeat on the next exchange.
        note_olm_identity_key(&tx, &path, &pass, "me", "friend", "devA", "key2").await;
        assert!(rx.try_recv().is_err(), "the moved pin must not re-alert");
    }

    #[tokio::test]
    async fn distinct_devices_of_one_contact_keep_separate_pins() {
        let (_dir, path, pass) = temp_db();
        let (tx, mut rx) = channel();
        // Two devices of one identity legitimately have different Olm keys.
        note_olm_identity_key(&tx, &path, &pass, "me", "friend", "devA", "keyA").await;
        note_olm_identity_key(&tx, &path, &pass, "me", "friend", "devB", "keyB").await;
        assert!(rx.try_recv().is_err(), "per-device keys must not cross-trigger");
    }

    #[tokio::test]
    async fn acknowledging_clears_only_that_peer() {
        let (_dir, path, pass) = temp_db();
        let (tx, _rx) = channel();
        note_new_devices(&tx, &path, &pass, "me", "alice", &["a1".into()], &["a1".into(), "a2".into()]).await;
        note_new_devices(&tx, &path, &pass, "me", "bob", &["b1".into()], &["b1".into(), "b2".into()]).await;

        let store = MessageStore::open(&path, &pass).unwrap();
        store.acknowledge_security_alerts_for_peer("alice").unwrap();
        let alerts = store.get_security_alerts().unwrap();
        assert_eq!(alerts.len(), 2, "acknowledging keeps the history");
        for a in alerts {
            match a.peer_id.as_str() {
                "alice" => assert!(a.acknowledged_at.is_some()),
                "bob" => assert!(a.acknowledged_at.is_none(), "other peers untouched"),
                other => panic!("unexpected peer {other}"),
            }
        }
    }
}
