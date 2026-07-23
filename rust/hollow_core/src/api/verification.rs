//! Contact verification FFI — safety numbers, the verified flag, and the
//! key/device change alerts (Issue 1-C + 1-D).
//!
//! Everything the "is this really them?" UI needs lives here rather than being
//! spread across the storage API, so the rules below can be audited in one
//! place:
//!
//! 1. **Everything is MASTER-keyed.** Verification is about a PERSON. A peer_id
//!    arriving from Dart may be a per-device id, so every entry point resolves
//!    device → master before touching the DB. A verified flag stored under a
//!    device id would silently stop applying the moment that contact linked or
//!    dropped a device — a badge that quietly stops reflecting reality is worse
//!    than no badge at all.
//! 2. **Never invent a number.** A malformed peer_id returns `Err`, not a
//!    plausible-looking string.

use flutter_rust_bridge::frb;

use crate::crypto::safety_number as sn;

use super::storage::{get_peer_id, get_store};

/// Collapse a possibly-per-device peer_id to the MASTER identity it belongs to.
///
/// Delegates to [`super::network::identity_for_persisted`], which falls back to
/// the persisted `device_links` when the in-memory resolver is still cold. That
/// fallback matters here: the Verify screen is reachable from a push tap or
/// straight after launch, before the first device-list ingest of the session —
/// and resolving to a DEVICE id there would compute a safety number for "one of
/// their machines" instead of for the person.
fn to_master(peer_id: &str) -> String {
    super::network::identity_for_persisted(peer_id.to_string())
}

// ── Safety numbers (Issue 1-D) ──────────────────────────────────────

/// The 60-digit safety number shared by this identity and `peer_id`.
///
/// Both people see the IDENTICAL number, so verification is a single "do these
/// match?" — there is no yours/theirs ordering to get wrong.
///
/// Derived purely from the two MASTER Ed25519 keys, so it is stable across
/// reinstalls and across the contact adding or removing devices. It changes only
/// when the master identity does — i.e. when it is genuinely a different person.
#[frb]
pub fn safety_number_with(peer_id: String) -> Result<String, String> {
    let local = get_peer_id()?;
    let theirs = to_master(&peer_id);
    sn::safety_number(local, &theirs)
}

/// Group a 60-digit safety number into 12 blocks of 5 for display.
///
/// Lives in Rust so desktop and mobile cannot drift into showing the same
/// number two different ways — two people comparing differently-grouped digits
/// is exactly the confusion this screen exists to remove. Input that is not the
/// expected length is returned untouched rather than mangled.
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

/// Compare a number the contact read out (or pasted) against `expected`.
///
/// Both sides are normalized to digits first, so spacing, line breaks or a
/// trailing newline never produce a false mismatch. A false alarm on a security
/// screen teaches users to ignore it.
#[frb(sync)]
pub fn safety_numbers_match(expected: String, provided: String) -> bool {
    sn::safety_numbers_match(&expected, &provided)
}

// ── The verified flag ───────────────────────────────────────────────

/// Mark a contact as identity-verified (their safety number was confirmed out
/// of band). Stored against the MASTER identity, so it survives their device
/// changes — which is the whole point of a master-derived safety number.
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
    /// `new_device` (a device joined their identity — the one that carries an
    /// attack signal) or `identity_key_changed` (a device re-keyed, i.e. they
    /// reinstalled).
    pub kind: String,
    /// The device id that appeared, or the device whose key changed.
    pub detail: String,
    pub created_at: i64,
    /// `None` while still unread.
    pub acknowledged_at: Option<i64>,
}

/// All recorded alerts, newest first — read AND dismissed alike, so the history
/// survives scrollback rather than vanishing on dismiss.
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

/// Mark every outstanding alert for one contact as read (the conversation
/// banner's Dismiss, which speaks for all of them at once).
#[frb]
pub fn acknowledge_security_alerts_for_peer(peer_id: String) -> Result<(), String> {
    let master = to_master(&peer_id);
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.acknowledge_security_alerts_for_peer(&master)
}
