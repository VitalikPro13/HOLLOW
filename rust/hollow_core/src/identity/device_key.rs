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
//! ## Migration keystone (do NOT break)
//! On an install that already has `identity.key` but no `identity.device`, the
//! device key is SEEDED FROM THE MASTER KEY (not generated fresh). This makes
//! `device_peer_id == master_peer_id == legacy peer_id`, so every existing
//! friendship, DM thread, and room code keeps resolving to the same value.
//! Generating a fresh device-1 key here would orphan all history.

use std::fs;
use std::path::PathBuf;

use super::keys::{device_keypair_path, save_keypair_to};
use super::native_identity::NativeKeypair;

/// Load the per-device keypair from `identity.device`, creating it if absent.
///
/// - File present  → decode (decrypting via the session key if encrypted).
/// - File absent, master key provided → SEED FROM MASTER (migration keystone).
/// - File absent, no master (brand-new identity) → generate fresh random key.
///
/// `master` is the already-loaded master keypair; pass `Some` whenever it is
/// available so an upgrading install adopts its legacy id as the device id.
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
        return NativeKeypair::from_protobuf_encoding(&plaintext)
            .map_err(|e| format!("Failed to decode device key: {e}"));
    }

    // No device key file yet.
    let device = match master {
        // Migration keystone: adopt the master key as device-1's key so the
        // device peer_id equals the legacy peer_id and nothing is orphaned.
        Some(m) => NativeKeypair::from_secret_bytes(&m.secret_key_bytes()),
        // Brand-new identity (no master available): fresh random device key.
        None => {
            let mut secret = [0u8; 32];
            getrandom::fill(&mut secret).map_err(|e| format!("RNG failed: {e}"))?;
            NativeKeypair::from_secret_bytes(&secret)
        }
    };

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

    /// With a master present and no device file, the device key SEEDS FROM the
    /// master (migration keystone): device peer_id == master peer_id.
    #[test]
    fn seeds_from_master_when_absent() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("identity.device");
        let master = master_kp();

        let device = load_or_create_device_keypair_at(&path, Some(&master)).unwrap();
        assert_eq!(device.peer_id(), master.peer_id());
        assert_eq!(device.secret_key_bytes(), master.secret_key_bytes());

        // Second load reads the persisted file and is stable.
        let again = load_or_create_device_keypair_at(&path, Some(&master)).unwrap();
        assert_eq!(again.peer_id(), device.peer_id());
    }

    /// With no master (brand-new identity), the device key is fresh + random and
    /// therefore DISTINCT from any master, but stable across reloads.
    #[test]
    fn fresh_random_when_no_master() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("identity.device");

        let device = load_or_create_device_keypair_at(&path, None).unwrap();
        let again = load_or_create_device_keypair_at(&path, None).unwrap();
        assert_eq!(device.peer_id(), again.peer_id());
        assert_ne!(device.peer_id(), master_kp().peer_id());
    }

    /// Two independent installs (no master) get DISTINCT random device keys —
    /// the property that lets two devices of one identity coexist on the relay.
    #[test]
    fn two_fresh_devices_are_distinct() {
        let tmp_a = tempfile::tempdir().unwrap();
        let tmp_b = tempfile::tempdir().unwrap();
        let a = load_or_create_device_keypair_at(&tmp_a.path().join("d"), None).unwrap();
        let b = load_or_create_device_keypair_at(&tmp_b.path().join("d"), None).unwrap();
        assert_ne!(a.peer_id(), b.peer_id());
    }
}
