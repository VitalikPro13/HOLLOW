//! Per-device key — the transport-level identity of THIS physical device.
//!
//! Multi-device model: the mnemonic-derived MASTER key is the cross-device
//! identity (display, friendships, message signing, DB passphrase). Each
//! physical device additionally holds its OWN random Ed25519 key whose peer_id
//! is produced by the SAME `compute_peer_id()` — so a device peer_id is
//! byte-for-byte the same `12D3KooW…` format and is indistinguishable to the
//! relay, rooms, and Olm. Two devices of one identity therefore present DISTINCT
//! peer_ids and never clobber each other's relay socket or crypto sessions.
//!
//! ## Every device gets a FRESH, distinct id (no keystone)
//! On first run (no `identity.device`), the device key is ALWAYS generated fresh
//! random — even on an upgrading single-device install. We deliberately do NOT
//! seed it from the master.
//!
//! Why not the old "migration keystone" (device==master on existing installs)?
//! Because the master id is shared across an identity's devices, so a device
//! whose transport id EQUALS the master collides with every other device's
//! `local_peer_str` (master): each sibling then filters the keystone device out
//! as "self" and they can never see each other. Distinct-per-device ids are the
//! whole point of the model; the keystone reintroduced the very collision it was
//! meant to avoid the moment a second device appeared.
//!
//! Cost of dropping it: an existing install's TRANSPORT peer_id changes once on
//! upgrade. That is safe — friendships, DM threads, room codes, message signing,
//! and the DB passphrase are all MASTER-derived (unchanged). Only peer-keyed
//! transient state (presence dots, Olm sessions) re-establishes, which it does
//! automatically on reconnect/key-exchange.

use std::fs;
use std::path::PathBuf;

use super::keys::{device_keypair_path, save_keypair_to};
use super::native_identity::NativeKeypair;

/// Load the per-device keypair from `identity.device`, creating it if absent.
///
/// - File present → decode. If it's a LEGACY keystone file (device id == master
///   id, written by the old code), ROTATE it to a fresh random id in place — see
///   the migration note below.
/// - File absent → generate a FRESH random key (distinct from the master and
///   from every other device). No master-seeding — see the module docs.
///
/// `master` is the loaded master keypair, used ONLY to detect (and rotate) a
/// legacy keystone device file. Pass `Some` whenever it's available.
///
/// ## One-time keystone rotation (existing installs)
/// The old code seeded `identity.device` from the master, so upgrading installs
/// already have a file with `device_id == master_id`. That collides with every
/// sibling's `local_peer_str` (= master) and breaks multi-device. So on load, if
/// we detect that legacy equality, we regenerate a fresh random device key and
/// overwrite the file (preserving its at-rest protection via `save_keypair_to`).
/// This happens exactly once; subsequent loads read the rotated file. The
/// transport id changes once — safe, since all durable state is master-keyed.
pub(crate) fn load_or_create_device_keypair(
    master: Option<&NativeKeypair>,
) -> Result<NativeKeypair, String> {
    load_or_create_device_keypair_at(&device_keypair_path()?, master)
}

/// Path-parameterized core of [`load_or_create_device_keypair`]. Separated so
/// unit tests can use an explicit temp path and avoid racing on the global
/// `HOLLOW_DATA_DIR` env var that the default path derivation reads.
fn load_or_create_device_keypair_at(
    path: &PathBuf,
    master: Option<&NativeKeypair>,
) -> Result<NativeKeypair, String> {
    if path.exists() {
        let bytes =
            fs::read(path).map_err(|e| format!("Failed to read device key file: {e}"))?;
        let plaintext = match super::encryption::detect_format(&bytes)? {
            super::encryption::IdentityFormat::Plaintext => bytes,
            super::encryption::IdentityFormat::Encrypted { .. } => {
                let key = super::encryption::get_session_key()
                    .ok_or("Device key is encrypted. Call unlock_identity() first.")?;
                super::encryption::decrypt_identity(&bytes, &key)?
            }
        };
        let device = NativeKeypair::from_protobuf_encoding(&plaintext)
            .map_err(|e| format!("Failed to decode device key: {e}"))?;

        // One-time keystone rotation: a legacy file where device == master must
        // become a fresh distinct id, or it collides with sibling masters.
        if let Some(m) = master {
            if device.peer_id() == m.peer_id() {
                let mut secret = [0u8; 32];
                getrandom::fill(&mut secret).map_err(|e| format!("RNG failed: {e}"))?;
                let fresh = NativeKeypair::from_secret_bytes(&secret);
                save_keypair_to(path, &fresh)?;
                return Ok(fresh);
            }
        }
        return Ok(device);
    }

    // No device key file yet → fresh random key, ALWAYS distinct from the master.
    let mut secret = [0u8; 32];
    getrandom::fill(&mut secret).map_err(|e| format!("RNG failed: {e}"))?;
    let device = NativeKeypair::from_secret_bytes(&secret);

    save_keypair_to(path, &device)?;
    Ok(device)
}

/// Load the device keypair decrypting with an EXPLICIT wrapping key (rather than
/// the global session key). Used by protection-change flows that hold the old
/// key directly (e.g. `change_password` verifying the old password) and must
/// read the device file before the session key rotates. Falls back to plaintext
/// if the file is unencrypted.
pub(crate) fn load_device_keypair_with_key(
    wrapping_key: &[u8; 32],
) -> Result<NativeKeypair, String> {
    let path = device_keypair_path()?;
    let bytes = fs::read(&path).map_err(|e| format!("Failed to read device key file: {e}"))?;
    let plaintext = match super::encryption::detect_format(&bytes)? {
        super::encryption::IdentityFormat::Plaintext => bytes,
        super::encryption::IdentityFormat::Encrypted { .. } => {
            super::encryption::decrypt_identity(&bytes, wrapping_key)?
        }
    };
    NativeKeypair::from_protobuf_encoding(&plaintext)
        .map_err(|e| format!("Failed to decode device key: {e}"))
}

/// Re-encrypt `identity.device` to match a protection change just applied to
/// `identity.key`. The device key file is wrapped with the SAME session key as
/// the master file, so any password/keychain change that rotates the session key
/// must rewrite the device file too — otherwise the device key becomes
/// undecryptable on the next unlock (hazard R2).
///
/// `device` is the in-memory device keypair (already loaded). `wrapping_key`
/// is the NEW session key (`None` to write plaintext, e.g. after removing
/// protection). `password_used` / `os_keychain_used` mirror the new master flags.
pub(crate) fn rewrite_device_key_protection(
    device: &NativeKeypair,
    wrapping_key: Option<&[u8; 32]>,
    password_used: bool,
    os_keychain_used: bool,
) -> Result<(), String> {
    let path = device_keypair_path()?;
    let plaintext = device
        .to_protobuf_encoding()
        .map_err(|e| format!("Failed to encode device key: {e}"))?;

    let bytes = match wrapping_key {
        Some(key) => {
            let mut salt = [0u8; 16];
            if password_used {
                getrandom::fill(&mut salt).map_err(|e| format!("RNG error: {e}"))?;
            }
            super::encryption::encrypt_identity(
                &plaintext,
                key,
                &salt,
                password_used,
                os_keychain_used,
            )?
        }
        None => plaintext,
    };

    fs::write(&path, bytes).map_err(|e| format!("Failed to write device key file: {e}"))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn master_kp() -> NativeKeypair {
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let mnemonic: bip39::Mnemonic = phrase.parse().unwrap();
        NativeKeypair::from_mnemonic(&mnemonic).unwrap()
    }

    /// First run (no device file) ALWAYS generates a fresh key DISTINCT from the
    /// master — no keystone — so a device's transport id never collides with the
    /// shared master id (which is another device's `local_peer_str`).
    #[test]
    fn fresh_and_distinct_from_master_when_absent() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("identity.device");
        let master = master_kp();

        let device = load_or_create_device_keypair_at(&path, Some(&master)).unwrap();
        assert_ne!(device.peer_id(), master.peer_id());
        assert_ne!(device.secret_key_bytes(), master.secret_key_bytes());

        // Second load reads the persisted file and is stable.
        let again = load_or_create_device_keypair_at(&path, Some(&master)).unwrap();
        assert_eq!(again.peer_id(), device.peer_id());
    }

    /// Stable across reloads and distinct from the master.
    #[test]
    fn fresh_random_stable_across_reloads() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("identity.device");

        let device = load_or_create_device_keypair_at(&path, None).unwrap();
        let again = load_or_create_device_keypair_at(&path, None).unwrap();
        assert_eq!(device.peer_id(), again.peer_id());
        assert_ne!(device.peer_id(), master_kp().peer_id());
    }

    /// Two independent installs get DISTINCT random device keys — the property
    /// that lets two devices of one identity coexist on the relay.
    #[test]
    fn two_fresh_devices_are_distinct() {
        let tmp_a = tempfile::tempdir().unwrap();
        let tmp_b = tempfile::tempdir().unwrap();
        let a = load_or_create_device_keypair_at(&tmp_a.path().join("d"), None).unwrap();
        let b = load_or_create_device_keypair_at(&tmp_b.path().join("d"), None).unwrap();
        assert_ne!(a.peer_id(), b.peer_id());
    }

    /// A LEGACY keystone file (device == master, written by the old code) is
    /// rotated to a fresh distinct id on the next load, and is then stable.
    #[test]
    fn legacy_keystone_file_is_rotated() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("identity.device");
        let master = master_kp();

        // Simulate the old keystone: device file == master key.
        let legacy = NativeKeypair::from_secret_bytes(&master.secret_key_bytes());
        save_keypair_to(&path, &legacy).unwrap();
        assert_eq!(legacy.peer_id(), master.peer_id());

        // Load with master present → must rotate to a distinct id.
        let rotated = load_or_create_device_keypair_at(&path, Some(&master)).unwrap();
        assert_ne!(rotated.peer_id(), master.peer_id());

        // Stable afterwards (file now holds the rotated key).
        let again = load_or_create_device_keypair_at(&path, Some(&master)).unwrap();
        assert_eq!(again.peer_id(), rotated.peer_id());
    }
}
