//! Contact verification FFI: safety numbers, the verified flag and the key/device
//! change alerts. Everything is MASTER-keyed because verification is about a
//! PERSON: a flag stored under a device id would silently stop applying the moment
//! that contact linked or dropped a device. A malformed peer_id returns `Err`
//! rather than a plausible-looking number.

use flutter_rust_bridge::frb;

use crate::crypto::safety_number as sn;

use super::storage::{get_peer_id, get_store};

/// Collapse a possibly-per-device peer_id to the MASTER identity it belongs to.
///
/// Falls back to persisted `device_links` while the in-memory resolver is cold:
/// the Verify screen is reachable from a push tap before the first device-list
/// ingest, and a DEVICE id there would number one machine instead of the person.
fn to_master(peer_id: &str) -> String {
    super::network::identity_for_persisted(peer_id.to_string())
}

// ── Safety numbers (Issue 1-D) ──────────────────────────────────────

/// The 60-digit safety number shared by this identity and `peer_id`.
///
/// Both people see the IDENTICAL number, and it is derived from the two MASTER
/// keys only, so it survives reinstalls and device changes and moves only when
/// the person does.
#[frb]
pub fn safety_number_with(peer_id: String) -> Result<String, String> {
    let local = get_peer_id()?;
    let theirs = to_master(&peer_id);
    sn::safety_number(local, &theirs)
}

/// Group a 60-digit safety number into 12 blocks of 5 for display.
///
/// In Rust so desktop and mobile cannot show the same number two different ways.
/// Input that is not 60 digits is returned untouched.
#[frb(sync)]
pub fn format_safety_number(number: String) -> String {
    let digits = sn::normalize_safety_number(&number);
    if digits.len() != 60 {
        return number;
    }
    digits
        .as_bytes()
        .chunks(5)
        .map(|c| String::from_utf8_lossy(c).to_string())
        .collect::<Vec<_>>()
        .join(" ")
}

/// Compare a number the contact read out against `expected`, ignoring spacing.
#[frb(sync)]
pub fn safety_numbers_match(expected: String, provided: String) -> bool {
    sn::safety_numbers_match(&expected, &provided)
}

// ── The verified flag ───────────────────────────────────────────────

/// Mark a contact as identity-verified, stored against the MASTER identity so it
/// survives their device changes.
#[frb]
pub fn set_peer_verified(peer_id: String) -> Result<(), String> {
    let master = to_master(&peer_id);
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.set_peer_verified(&master)
}

/// Withdraw a contact's verified status.
#[frb]
pub fn remove_peer_verified(peer_id: String) -> Result<(), String> {
    let master = to_master(&peer_id);
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.remove_peer_verified(&master)
}

/// Whether this contact has been identity-verified.
#[frb]
pub fn is_peer_verified(peer_id: String) -> Result<bool, String> {
    let master = to_master(&peer_id);
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.is_peer_verified(&master)
}

/// Every verified contact as `(master_peer_id, verified_at_ms)`.
#[frb]
pub fn get_verified_peers() -> Result<Vec<(String, i64)>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.get_verified_peers()
}

// ── Security alerts (Issue 1-C) ─────────────────────────────────────

/// A recorded identity change for a contact.
pub struct SecurityAlertFfi {
    /// Stable id — pass to [`acknowledge_security_alert`].
    pub alert_id: String,
    /// MASTER peer_id of the contact the alert is about.
    pub peer_id: String,
    /// `new_device` (a device joined their identity, the signal an attack shows
    /// up in) or `identity_key_changed` (a device re-keyed, i.e. a reinstall).
    pub kind: String,
    /// The device id that appeared, or the device whose key changed.
    pub detail: String,
    pub created_at: i64,
    /// `None` while still unread.
    pub acknowledged_at: Option<i64>,
}

/// All recorded alerts, newest first, read and dismissed alike.
#[frb]
pub fn get_security_alerts() -> Result<Vec<SecurityAlertFfi>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    Ok(ms
        .get_security_alerts()?
        .into_iter()
        .map(|r| SecurityAlertFfi {
            alert_id: r.alert_id,
            peer_id: r.peer_id,
            kind: r.kind,
            detail: r.detail,
            created_at: r.created_at,
            acknowledged_at: r.acknowledged_at,
        })
        .collect())
}

/// Mark one alert as read.
#[frb]
pub fn acknowledge_security_alert(alert_id: String) -> Result<(), String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.acknowledge_security_alert(&alert_id)
}

/// Mark every outstanding alert for one contact as read.
#[frb]
pub fn acknowledge_security_alerts_for_peer(peer_id: String) -> Result<(), String> {
    let master = to_master(&peer_id);
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.acknowledge_security_alerts_for_peer(&master)
}
