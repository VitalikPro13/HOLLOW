//! Per-device key: the transport identity of THIS physical device, distinct from
//! the mnemonic-derived MASTER key that carries display, friendships, message
//! signing and the DB passphrase. A device peer_id comes from the same
//! `compute_peer_id()` and is indistinguishable to the relay, rooms and Olm, so
//! two devices of one identity never clobber each other's socket or crypto
//! sessions. It is ALWAYS fresh random, never seeded from the master: a device
//! whose transport id equals the master collides with every sibling's
//! `local_peer_str` and each sibling then filters the other out as "self".

use std::fs;
use std::path::PathBuf;

use super::keys::{device_keypair_path, save_keypair_to};
use super::native_identity::NativeKeypair;

/// Load the per-device keypair from `identity.device`, creating it if absent.
///
/// `master` is used ONLY to spot a LEGACY keystone file (device id == master id)
/// and rotate it in place to a fresh random id, so pass `Some` whenever one is
/// available. An absent file yields a fresh random key. The transport id changing
/// once on that rotation is safe: friendships, threads, room codes, signing and
/// the DB passphrase are all master-derived.
pub(crate) fn load_or_create_device_keypair(
    master: Option<&NativeKeypair>,
) -> Result<NativeKeypair, String> {
    load_or_create_device_keypair_at(&device_keypair_path()?, master)
}

/// Path-parameterized core of [`load_or_create_device_keypair`], so unit tests can
/// pass a temp path instead of racing on the global `HOLLOW_DATA_DIR`.
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

        // Legacy keystone file: rotate it, or it collides with sibling masters.
        if let Some(m) = master {
            if device.peer_id() == m.peer_id() {
                let mut secret = zeroize::Zeroizing::new([0u8; 32]);
                getrandom::fill(&mut secret[..]).map_err(|e| format!("RNG failed: {e}"))?;
                let fresh = NativeKeypair::from_secret_bytes(&secret);
                save_keypair_to(path, &fresh)?;
                return Ok(fresh);
            }
        }
        return Ok(device);
    }

    let mut secret = zeroize::Zeroizing::new([0u8; 32]);
    getrandom::fill(&mut secret[..]).map_err(|e| format!("RNG failed: {e}"))?;
    let device = NativeKeypair::from_secret_bytes(&secret);

    save_keypair_to(path, &device)?;
    Ok(device)
}

/// Load the device keypair decrypting with an EXPLICIT wrapping key rather than
/// the global session key, for protection-change flows that must read the file
/// before the session key rotates. Falls back to plaintext if the file is
/// unencrypted.
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
/// Both files are wrapped with the SAME session key, so a password or keychain
/// change that rotates it must rewrite this one too or the device key becomes
/// undecryptable on the next unlock. `wrapping_key` is the NEW key, `None` to
/// write plaintext.
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

    /// First run ALWAYS generates a key DISTINCT from the master, so a device's
    /// transport id never collides with a sibling's `local_peer_str`.
    #[test]
    fn fresh_and_distinct_from_master_when_absent() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("identity.device");
        let master = master_kp();

        let device = load_or_create_device_keypair_at(&path, Some(&master)).unwrap();
        assert_ne!(device.peer_id(), master.peer_id());
        assert_ne!(device.secret_key_bytes(), master.secret_key_bytes());

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

    /// Two independent installs get DISTINCT keys, the property that lets two
    /// devices of one identity coexist on the relay.
    #[test]
    fn two_fresh_devices_are_distinct() {
        let tmp_a = tempfile::tempdir().unwrap();
        let tmp_b = tempfile::tempdir().unwrap();
        let a = load_or_create_device_keypair_at(&tmp_a.path().join("d"), None).unwrap();
        let b = load_or_create_device_keypair_at(&tmp_b.path().join("d"), None).unwrap();
        assert_ne!(a.peer_id(), b.peer_id());
    }

    /// A LEGACY keystone file (device == master) is rotated to a distinct id on
    /// the next load, and is then stable.
    #[test]
    fn legacy_keystone_file_is_rotated() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("identity.device");
        let master = master_kp();

        // The old keystone: device file == master key.
        let legacy = NativeKeypair::from_secret_bytes(&master.secret_key_bytes());
        save_keypair_to(&path, &legacy).unwrap();
        assert_eq!(legacy.peer_id(), master.peer_id());

        let rotated = load_or_create_device_keypair_at(&path, Some(&master)).unwrap();
        assert_ne!(rotated.peer_id(), master.peer_id());

        let again = load_or_create_device_keypair_at(&path, Some(&master)).unwrap();
        assert_eq!(again.peer_id(), rotated.peer_id());
    }
}
