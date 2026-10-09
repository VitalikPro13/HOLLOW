use std::fs;
use std::path::PathBuf;
use std::sync::OnceLock;

use bip39::Mnemonic;
use super::native_identity::NativeKeypair;

/// The result of identity generation/loading.
pub(crate) struct IdentityData {
    /// Master keypair from the mnemonic: the cross-device IDENTITY behind display,
    /// friendships, message signing and the DB passphrase.
    pub keypair: NativeKeypair,
    /// Master peer_id — the identity-level id shared across all devices.
    pub peer_id: String,
    /// Per-device keypair (random, NOT from the mnemonic). Drives this device's
    /// transport-level peer_id (relay/rooms/Olm). See `device_key.rs`.
    pub device_keypair: NativeKeypair,
    /// This device's peer_id. On a pre-multi-device install it equals `peer_id`.
    pub device_peer_id: String,
    pub mnemonic: Option<String>,
}

static DATA_DIR_OVERRIDE: OnceLock<String> = OnceLock::new();

/// Set the data directory from Dart, before any identity or storage operation.
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
    // The entropy IS the identity, so the buffer is wiped on return rather than left
    // in freed stack memory.
    let mut entropy = zeroize::Zeroizing::new([0u8; 32]);
    getrandom::fill(&mut entropy[..]).map_err(|e| format!("RNG failed: {e}"))?;
    let mnemonic = Mnemonic::from_entropy(&entropy[..])
        .map_err(|e| format!("Mnemonic generation failed: {e}"))?;
    let mnemonic_phrase = mnemonic.to_string();

    let keypair = NativeKeypair::from_mnemonic(&mnemonic)?;
    let peer_id = keypair.peer_id();

    save_keypair(&keypair)?;

    // A brand-new identity gets a fresh random device key that also OVERWRITES any
    // stale `identity.device` from a previous identity: reusing a leftover keystone
    // file would give this identity a device id equal to some unrelated master, which
    // then publishes as a master-as-device entry and breaks friend and DM keying.
    let mut device_secret = zeroize::Zeroizing::new([0u8; 32]);
    getrandom::fill(&mut device_secret[..]).map_err(|e| format!("RNG failed: {e}"))?;
    let device_keypair = NativeKeypair::from_secret_bytes(&device_secret);
    save_keypair_to(&device_keypair_path()?, &device_keypair)?;
    let device_peer_id = device_keypair.peer_id();

    // The phrase exists only now, so the recovery key signs the identity's genesis
    // here: this device alone, the phrase as the root (design ID-1).
    let seed = zeroize::Zeroizing::new(mnemonic.to_seed(""));
    let recovery = super::recovery::recovery_keypair_from_seed(&seed);
    let genesis = super::roster::Roster::genesis(&keypair, &recovery, &device_keypair, now_ms());
    crate::node::roster_book::write_bootstrap(&data_dir()?, &genesis)?;

    Ok(IdentityData {
        keypair,
        peer_id,
        device_keypair,
        device_peer_id,
        mnemonic: Some(mnemonic_phrase),
    })
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

/// The names an encrypted key file is kept under once a phrase restore replaces it.
pub(crate) const LOCKED_KEY_FILES: [(&str, &str); 2] = [
    ("identity.key", "identity.key.locked"),
    ("identity.device", "identity.device.locked"),
];

/// Keeps encrypted key files a phrase restore is about to replace, so a keychain key
/// that comes back later still opens the old device. Plaintext files are not kept:
/// the restore rebuilds the master and mints a new device either way.
pub(crate) fn set_aside_locked_keys(root: &std::path::Path) {
    for (name, aside) in LOCKED_KEY_FILES {
        let path = root.join(name);
        let Ok(bytes) = fs::read(&path) else { continue };
        if matches!(
            super::encryption::detect_format(&bytes),
            Ok(super::encryption::IdentityFormat::Encrypted { .. })
        ) {
            let _ = fs::rename(&path, root.join(aside));
        }
    }
}

/// Restore an identity from an existing mnemonic phrase.
pub(crate) fn restore_identity_from_mnemonic(phrase: &str) -> Result<IdentityData, String> {
    let mnemonic: Mnemonic = phrase
        .parse()
        .map_err(|e| format!("Invalid mnemonic: {e}"))?;

    let keypair = NativeKeypair::from_mnemonic(&mnemonic)?;
    let peer_id = keypair.peer_id();

    set_aside_locked_keys(&data_dir()?);
    save_keypair(&keypair)?;

    // Restoring a mnemonic onto a device IS the multi-device case, so this device MUST
    // mint a FRESH random device key (seeding from master recreates the same-peer_id
    // collision) and overwrite any stale identity.device left by a previous identity.
    let mut device_secret = zeroize::Zeroizing::new([0u8; 32]);
    getrandom::fill(&mut device_secret[..]).map_err(|e| format!("RNG failed: {e}"))?;
    let device_keypair = NativeKeypair::from_secret_bytes(&device_secret);
    save_keypair_to(&device_keypair_path()?, &device_keypair)?;
    let device_peer_id = device_keypair.peer_id();

    // The phrase was typed on this device, so it admits it (design ID-1).
    let seed = zeroize::Zeroizing::new(mnemonic.to_seed(""));
    let recovery = super::recovery::recovery_keypair_from_seed(&seed);
    let mut roster = super::roster::Roster::new(&peer_id);
    roster.add_consent(super::roster::sign_consent(&device_keypair, &peer_id));
    roster.add_phrase_statement(
        &super::roster::r_pub_of(&recovery),
        None,
        Some(super::roster::sign_phrase_admit(&keypair, &recovery, now_ms(), &device_peer_id)),
    )?;
    crate::node::roster_book::write_bootstrap(&data_dir()?, &roster)?;

    Ok(IdentityData {
        keypair,
        peer_id,
        device_keypair,
        device_peer_id,
        mnemonic: Some(mnemonic.to_string()),
    })
}

/// Load the identity from disk, creating one if none exists. An encrypted file needs
/// the session wrapping key from `unlock_identity()`.
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

        // An existing install seeds the device key from the master on first run, then
        // loads the persisted one.
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
        // A wipe the next launch finishes (a destruction order mid-boot, a database
        // something held), or a link or restore between moving the old identity out
        // and the new one in: a key minted now would sit beside a database it never
        // opens, or in a root about to be cleared.
        if crate::api::storage::has_pending_wipe().unwrap_or(false)
            || crate::api::storage::landing_in_progress()
        {
            return Err(crate::api::storage::IDENTITY_NOT_READY.into());
        }
        generate_new_identity()
    }
}

/// Load an existing identity from disk WITHOUT falling back to generating a
/// new one. Returns Ok(None) if no identity file exists yet.
///
/// Used by background push handlers: generating a fresh identity there would yield a
/// different peer_id and DB passphrase, silently opening an empty database. The
/// background isolate must use the REAL identity or do nothing.
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

    // Background isolates need the real device key too, seeded from master if absent.
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

/// Save a keypair to disk: an encrypted HKEYV1 envelope when a session key is set,
/// otherwise plaintext protobuf.
fn save_keypair(keypair: &NativeKeypair) -> Result<(), String> {
    save_keypair_to(&keypair_path()?, keypair)
}

/// Save a keypair to an arbitrary path, mirroring the protection mode of whatever is
/// already there, so the device file matches the master file's password or keychain
/// state independently.
pub(crate) fn save_keypair_to(path: &PathBuf, keypair: &NativeKeypair) -> Result<(), String> {
    let plaintext = keypair.to_protobuf_encoding()
        .map_err(|e| format!("Failed to encode keypair: {e}"))?;

    let bytes_to_write = if let Some(key) = super::encryption::get_session_key() {
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
        let tmp = crate::test_tmp::tempdir().unwrap();
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

    /// The key-missing screen's phrase restore keeps the locked files, so the device
    /// they hold is not lost if the keychain key comes back.
    #[test]
    fn a_phrase_restore_keeps_locked_keys_aside() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path();
        let mut locked = b"HKEYV1".to_vec();
        locked.push(0x02);
        locked.resize(119, 7);
        let mut plain = vec![0x08, 0x01, 0x12, 0x40];
        plain.resize(68, 9);
        fs::write(root.join("identity.key"), &locked).unwrap();
        fs::write(root.join("identity.device"), &plain).unwrap();

        set_aside_locked_keys(root);

        assert_eq!(fs::read(root.join("identity.key.locked")).unwrap(), locked, "the locked master was not kept");
        assert!(!root.join("identity.key").exists(), "the locked master stayed in place");
        assert_eq!(fs::read(root.join("identity.device")).unwrap(), plain, "a plaintext key was moved");
        assert!(!root.join("identity.device.locked").exists());
    }
}
