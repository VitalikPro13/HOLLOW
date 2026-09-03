use std::fs;
use std::path::PathBuf;
use std::sync::OnceLock;

use bip39::Mnemonic;
use super::native_identity::NativeKeypair;

/// The result of identity generation/loading.
pub(crate) struct IdentityData {
    /// Master keypair (from the mnemonic). The cross-device IDENTITY: drives
    /// display, friendships, message-content signing, and the DB passphrase.
    pub keypair: NativeKeypair,
    /// Master peer_id — the identity-level id shared across all devices.
    pub peer_id: String,
    /// Per-device keypair (random, NOT from the mnemonic). Drives this device's
    /// transport-level peer_id (relay/rooms/Olm). See `device_key.rs`.
    pub device_keypair: NativeKeypair,
    /// This device's peer_id = `compute_peer_id(device_keypair)`. On an existing
    /// (pre-multi-device) install this equals `peer_id` (migration keystone).
    pub device_peer_id: String,
    pub mnemonic: Option<String>,
}

static DATA_DIR_OVERRIDE: OnceLock<String> = OnceLock::new();

/// Set the data directory path from Dart (Android/iOS pass their app data dir).
/// Must be called before any identity or storage operations.
pub fn set_data_dir(path: String) -> Result<(), String> {
    let _ = DATA_DIR_OVERRIDE.set(path);
    Ok(())
}

/// Get the Hollow data directory.
/// Priority: set_data_dir() override → HOLLOW_DATA_DIR env var → dirs::data_dir().
pub fn data_dir() -> Result<PathBuf, String> {
    let dir = if let Some(override_path) = DATA_DIR_OVERRIDE.get() {
        PathBuf::from(override_path)
    } else if let Ok(custom) = std::env::var("HOLLOW_DATA_DIR") {
        PathBuf::from(custom)
    } else {
        let base = dirs::data_dir().ok_or("Could not find app data directory")?;
        base.join("hollow")
    };
    fs::create_dir_all(&dir).map_err(|e| format!("Failed to create data dir: {e}"))?;
    Ok(dir)
}

/// Path to the stored identity keypair file (master key).
fn keypair_path() -> Result<PathBuf, String> {
    Ok(data_dir()?.join("identity.key"))
}

/// Path to the stored per-device keypair file. Sibling of `identity.key`,
/// encrypted with the same session key. See `device_key.rs`.
pub(crate) fn device_keypair_path() -> Result<PathBuf, String> {
    Ok(data_dir()?.join("identity.device"))
}

/// Generate a brand new identity from a fresh BIP-39 mnemonic.
pub(crate) fn generate_new_identity() -> Result<IdentityData, String> {
    // Generate 24-word mnemonic (256 bits of entropy). The entropy IS the
    // identity, so the buffer is wiped when this returns rather than left in
    // freed stack memory.
    let mut entropy = zeroize::Zeroizing::new([0u8; 32]);
    getrandom::fill(&mut entropy[..]).map_err(|e| format!("RNG failed: {e}"))?;
    let mnemonic = Mnemonic::from_entropy(&entropy[..])
        .map_err(|e| format!("Mnemonic generation failed: {e}"))?;
    let mnemonic_phrase = mnemonic.to_string();

    let keypair = NativeKeypair::from_mnemonic(&mnemonic)?;
    let peer_id = keypair.peer_id();

    // Save the keypair to disk.
    save_keypair(&keypair)?;

    // Brand-new identity → fresh random device key, ALWAYS distinct from the master
    // AND overwriting any stale `identity.device` left from a PREVIOUS identity on
    // this install. (The old `load_or_create_device_keypair(None)` REUSED a leftover
    // device file without rotation — if that file was a legacy keystone where
    // device == old master, the new identity inherited a device id equal to some
    // unrelated master, which then got published as a master-as-device entry in the
    // device list and broke friend/DM keying for peers. Mirror
    // `restore_identity_from_mnemonic`, which already mints fresh + overwrites.)
    let mut device_secret = zeroize::Zeroizing::new([0u8; 32]);
    getrandom::fill(&mut device_secret[..]).map_err(|e| format!("RNG failed: {e}"))?;
    let device_keypair = NativeKeypair::from_secret_bytes(&device_secret);
    save_keypair_to(&device_keypair_path()?, &device_keypair)?;
    let device_peer_id = device_keypair.peer_id();

    Ok(IdentityData {
        keypair,
        peer_id,
        device_keypair,
        device_peer_id,
        mnemonic: Some(mnemonic_phrase),
    })
}

/// Restore an identity from an existing mnemonic phrase.
pub(crate) fn restore_identity_from_mnemonic(phrase: &str) -> Result<IdentityData, String> {
    let mnemonic: Mnemonic = phrase
        .parse()
        .map_err(|e| format!("Invalid mnemonic: {e}"))?;

    let keypair = NativeKeypair::from_mnemonic(&mnemonic)?;
    let peer_id = keypair.peer_id();

    // Save the restored keypair to disk.
    save_keypair(&keypair)?;

    // Restoring the mnemonic onto a device IS the multi-device case ("import my
    // identity here"). This device MUST get a FRESH random device key so its
    // peer_id is distinct from the originating device — seeding from master
    // would recreate the same-peer_id collision we are fixing. We overwrite any
    // stale identity.device left over from a previous identity on this install.
    let mut device_secret = zeroize::Zeroizing::new([0u8; 32]);
    getrandom::fill(&mut device_secret[..]).map_err(|e| format!("RNG failed: {e}"))?;
    let device_keypair = NativeKeypair::from_secret_bytes(&device_secret);
    save_keypair_to(&device_keypair_path()?, &device_keypair)?;
    let device_peer_id = device_keypair.peer_id();

    Ok(IdentityData {
        keypair,
        peer_id,
        device_keypair,
        device_peer_id,
        mnemonic: Some(mnemonic.to_string()),
    })
}

/// Load existing identity from disk, or create a new one if none exists.
/// If the identity file is encrypted, requires a session wrapping key
/// (set via `unlock_identity()` FFI call) to decrypt.
pub(crate) fn load_or_create_identity() -> Result<IdentityData, String> {
    let path = keypair_path()?;

    if path.exists() {
        let bytes = fs::read(&path).map_err(|e| format!("Failed to read identity file: {e}"))?;

        let plaintext = match super::encryption::detect_format(&bytes)? {
            super::encryption::IdentityFormat::Plaintext => bytes,
            super::encryption::IdentityFormat::Encrypted { .. } => {
                let key = super::encryption::get_session_key()
                    .ok_or("Identity is encrypted. Call unlock_identity() first.")?;
                super::encryption::decrypt_identity(&bytes, &key)?
            }
        };

        let keypair = NativeKeypair::from_protobuf_encoding(&plaintext)
            .map_err(|e| format!("Failed to decode identity: {e}"))?;
        let peer_id = keypair.peer_id();

        // Existing install → device key seeds from the master on first run
        // (migration keystone: device_peer_id == legacy peer_id), or loads the
        // already-persisted device key on subsequent runs.
        let device_keypair = super::device_key::load_or_create_device_keypair(Some(&keypair))?;
        let device_peer_id = device_keypair.peer_id();

        Ok(IdentityData {
            keypair,
            peer_id,
            device_keypair,
            device_peer_id,
            mnemonic: None,
        })
    } else {
        generate_new_identity()
    }
}

/// Load an existing identity from disk WITHOUT falling back to generating a
/// new one. Returns Ok(None) if no identity file exists yet.
///
/// Used by background push handlers (FCM fetch): generating a fresh identity
/// there would yield a different peer_id and a different DB passphrase, which
/// silently opens an empty database (no cached profiles, wrong decrypt keys).
/// The background isolate must use the REAL identity or do nothing.
pub(crate) fn load_existing_identity() -> Result<Option<IdentityData>, String> {
    let path = keypair_path()?;
    if !path.exists() {
        return Ok(None);
    }

    let bytes = fs::read(&path).map_err(|e| format!("Failed to read identity file: {e}"))?;

    let plaintext = match super::encryption::detect_format(&bytes)? {
        super::encryption::IdentityFormat::Plaintext => bytes,
        super::encryption::IdentityFormat::Encrypted { .. } => {
            let key = super::encryption::get_session_key()
                .ok_or("Identity is encrypted. Call unlock_identity() first.")?;
            super::encryption::decrypt_identity(&bytes, &key)?
        }
    };

    let keypair = NativeKeypair::from_protobuf_encoding(&plaintext)
        .map_err(|e| format!("Failed to decode identity: {e}"))?;
    let peer_id = keypair.peer_id();

    // Background isolates (FCM fetch) need the real device key too. Seed from
    // master if absent (consistent with the foreground load path).
    let device_keypair = super::device_key::load_or_create_device_keypair(Some(&keypair))?;
    let device_peer_id = device_keypair.peer_id();

    Ok(Some(IdentityData {
        keypair,
        peer_id,
        device_keypair,
        device_peer_id,
        mnemonic: None,
    }))
}

/// Save a keypair to disk. If encryption is active (session key set),
/// the file is written as an encrypted HKEYV1 envelope. Otherwise plaintext protobuf.
fn save_keypair(keypair: &NativeKeypair) -> Result<(), String> {
    save_keypair_to(&keypair_path()?, keypair)
}

/// Save a keypair to an arbitrary path, mirroring the protection mode of the
/// file already at that path (so the device key file matches the master file's
/// password/keychain state independently). Used for both `identity.key` and
/// `identity.device`.
pub(crate) fn save_keypair_to(path: &PathBuf, keypair: &NativeKeypair) -> Result<(), String> {
    let plaintext = keypair.to_protobuf_encoding()
        .map_err(|e| format!("Failed to encode keypair: {e}"))?;

    let bytes_to_write = if let Some(key) = super::encryption::get_session_key() {
        // Determine current protection flags by reading existing file (if any).
        let (password_used, os_keychain_used) = if path.exists() {
            let existing = fs::read(path).unwrap_or_default();
            match super::encryption::detect_format(&existing) {
                Ok(super::encryption::IdentityFormat::Encrypted { flags, .. }) => {
                    (super::encryption::flags_has_password(flags),
                     super::encryption::flags_has_os_keychain(flags))
                }
                _ => (false, true), // Default: OS keychain only
            }
        } else {
            (false, true)
        };
        let mut salt = [0u8; 16];
        if password_used {
            getrandom::fill(&mut salt).map_err(|e| format!("RNG error: {e}"))?;
        }
        super::encryption::encrypt_identity(&plaintext, &key, &salt, password_used, os_keychain_used)?
    } else {
        plaintext
    };

    fs::write(path, bytes_to_write).map_err(|e| format!("Failed to write identity file: {e}"))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn data_dir_respects_env_override() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("hollow_test");
        // SAFETY: test runs single-threaded (cargo test default); no other
        // thread reads HOLLOW_DATA_DIR concurrently.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", path.to_str().unwrap()) };

        let result = data_dir();
        assert!(result.is_ok());
        let dir = result.unwrap();
        assert!(dir.exists());

        unsafe { std::env::remove_var("HOLLOW_DATA_DIR") };
    }

    #[test]
    fn mnemonic_round_trip_produces_same_identity() {
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

        let id1 = {
            let mnemonic: Mnemonic = phrase.parse().unwrap();
            let keypair = NativeKeypair::from_mnemonic(&mnemonic).unwrap();
            (keypair.peer_id(), keypair.secret_key_bytes(), keypair.public_key_bytes())
        };

        let id2 = {
            let mnemonic: Mnemonic = phrase.parse().unwrap();
            let keypair = NativeKeypair::from_mnemonic(&mnemonic).unwrap();
            (keypair.peer_id(), keypair.secret_key_bytes(), keypair.public_key_bytes())
        };

        assert_eq!(id1.0, id2.0);
        assert_eq!(id1.1, id2.1);
        assert_eq!(id1.2, id2.2);
    }

    #[test]
    fn different_mnemonics_produce_different_identities() {
        let phrase1 = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let phrase2 = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong";

        let m1: Mnemonic = phrase1.parse().unwrap();
        let m2: Mnemonic = phrase2.parse().unwrap();
        let kp1 = NativeKeypair::from_mnemonic(&m1).unwrap();
        let kp2 = NativeKeypair::from_mnemonic(&m2).unwrap();

        assert_ne!(kp1.peer_id(), kp2.peer_id());
        assert_ne!(kp1.secret_key_bytes(), kp2.secret_key_bytes());
    }

    #[test]
    fn invalid_mnemonic_rejected() {
        assert!("not a valid mnemonic phrase".parse::<Mnemonic>().is_err());
        assert!("".parse::<Mnemonic>().is_err());
    }
}
