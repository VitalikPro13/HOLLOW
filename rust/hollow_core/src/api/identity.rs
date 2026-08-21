use flutter_rust_bridge::frb;

use crate::identity;

/// Result of creating or loading an identity.
pub struct IdentityInfo {
    /// Master peer_id — the cross-device IDENTITY (display, friendships).
    pub peer_id: String,
    /// This device's transport peer_id. Equals `peer_id` on a pre-multi-device
    /// install (migration keystone); distinct on a freshly-linked device.
    pub device_peer_id: String,
    /// The 24-word mnemonic phrase. Only present on first creation — save it!
    pub mnemonic: Option<String>,
}

/// Current protection status of the identity file.
pub struct ProtectionStatus {
    pub is_encrypted: bool,
    pub has_password: bool,
    pub has_os_keychain: bool,
    pub os_keychain_available: bool,
}

/// Set the data directory path (Android/iOS: pass app documents dir).
/// Must be called before load_or_create_identity() or start_node().
#[frb]
pub fn set_data_dir(path: String) -> Result<(), String> {
    crate::identity::set_data_dir(path)
}

/// Load the saved identity from disk, or create a new one if none exists.
/// On first run, returns the mnemonic phrase for the user to back up.
/// On subsequent runs, returns just the peer ID (mnemonic is not stored).
#[frb]
pub fn load_or_create_identity() -> Result<IdentityInfo, String> {
    let data = identity::load_or_create_identity()?;
    Ok(IdentityInfo {
        peer_id: data.peer_id,
        device_peer_id: data.device_peer_id,
        mnemonic: data.mnemonic,
    })
}

/// Generate a fresh identity, replacing any existing one.
/// Returns the new peer ID and mnemonic phrase.
#[frb]
pub fn generate_new_identity() -> Result<IdentityInfo, String> {
    let data = identity::generate_new_identity()?;
    Ok(IdentityInfo {
        peer_id: data.peer_id,
        device_peer_id: data.device_peer_id,
        mnemonic: data.mnemonic,
    })
}

/// Restore an identity from a 24-word mnemonic phrase.
/// Replaces any existing identity on disk.
#[frb]
pub fn restore_identity_from_mnemonic(phrase: String) -> Result<IdentityInfo, String> {
    let data = identity::restore_identity_from_mnemonic(&phrase)?;
    Ok(IdentityInfo {
        peer_id: data.peer_id,
        device_peer_id: data.device_peer_id,
        mnemonic: data.mnemonic,
    })
}

/// Try every stored keychain candidate (per-profile slot, legacy machine
/// slot, Windows DPAPI blob) and return the first key that actually decrypts
/// THIS identity file. On success the verified key is re-stored so every slot
/// self-heals to the active profile — with multiple profiles on one machine
/// the legacy slot routinely holds the OTHER profile's key, and trusting it
/// unverified funneled users into mnemonic recovery, which rotates the
/// device key, discards the MLS identity + groups, and turns voice into
/// undecryptable garbage audio (issue #47 → #27).
fn keychain_key_that_decrypts(bytes: &[u8]) -> Option<[u8; 32]> {
    keychain_key_that_decrypts_opts(bytes, true)
}

/// `heal = false` is the read-only form: it answers "can this machine unwrap
/// this file" WITHOUT re-storing the winning key. Every unlock path wants the
/// healing form; the profile-erase gate must not use it, because the file it
/// is testing belongs to a DIFFERENT profile and writing that key back into
/// the shared slots is exactly the overwrite that caused issue #47 -> #27.
fn keychain_key_that_decrypts_opts(bytes: &[u8], heal: bool) -> Option<[u8; 32]> {
    use crate::identity::{encryption, platform_keystore};
    let candidates = platform_keystore::retrieve_key_candidates().ok()?;
    for key_vec in candidates {
        if key_vec.len() != 32 {
            continue;
        }
        let mut key = [0u8; 32];
        key.copy_from_slice(&key_vec);
        if encryption::decrypt_identity(bytes, &key).is_ok() {
            if heal {
                let _ = platform_keystore::store_key(&key);
            }
            return Some(key);
        }
    }
    None
}

/// Unlock the identity file for this session.
/// For plaintext identities: loads directly (password ignored).
/// For encrypted identities: decrypts using password and/or OS keychain.
/// Must be called before open_message_store() or start_node().
#[frb]
pub fn unlock_identity(password: Option<String>) -> Result<IdentityInfo, String> {
    use crate::identity::encryption;

    let dir = crate::identity::data_dir()?;
    let path = dir.join("identity.key");

    if !path.exists() {
        return Err("No identity file found".into());
    }

    let bytes = std::fs::read(&path)
        .map_err(|e| format!("Failed to read identity file: {e}"))?;

    let format = encryption::detect_format(&bytes)?;

    match format {
        encryption::IdentityFormat::Plaintext => {
            // No encryption — load directly. OS keychain is opt-in from Settings.
        }
        encryption::IdentityFormat::Encrypted { flags, salt, .. } => {
            let wrapping_key = if encryption::flags_has_password(flags)
                && encryption::flags_has_os_keychain(flags)
            {
                // Password + keychain (flags=0x03): try silent keychain first,
                // fall back to password prompt if no stored key decrypts.
                match keychain_key_that_decrypts(&bytes) {
                    Some(key) => key,
                    None => {
                        let pw = password.as_deref()
                            .ok_or("Identity is password-protected. Provide a password.")?;
                        encryption::derive_wrapping_key_from_password(pw, &salt)?
                    }
                }
            } else if encryption::flags_has_password(flags) {
                // Password-only (flags=0x01): always prompt.
                let pw = password.as_deref()
                    .ok_or("Identity is password-protected. Provide a password.")?;
                encryption::derive_wrapping_key_from_password(pw, &salt)?
            } else if encryption::flags_has_os_keychain(flags) {
                // Keychain-only (flags=0x02): silent unlock on same machine.
                match keychain_key_that_decrypts(&bytes) {
                    Some(key) => key,
                    None => {
                        return Err(
                            "Identity was protected with this device's credentials which are no longer available. Restore from backup or mnemonic."
                                .into(),
                        );
                    }
                }
            } else {
                return Err("Unknown identity protection flags".into());
            };

            // Verify the key actually decrypts before storing.
            encryption::decrypt_identity(&bytes, &wrapping_key)?;
            encryption::set_session_key(wrapping_key);
        }
    }

    // Now load the identity normally (will use session key if encrypted).
    let data = identity::load_or_create_identity()?;
    Ok(IdentityInfo {
        peer_id: data.peer_id,
        device_peer_id: data.device_peer_id,
        mnemonic: data.mnemonic,
    })
}

/// Clear the session wrapping key. After this, all identity operations
/// will fail until unlock_identity() is called again.
#[frb]
pub fn lock_identity() -> Result<(), String> {
    crate::identity::encryption::clear_session_key();
    Ok(())
}

/// Enable password protection on the current identity.
/// If `require_on_launch` is true (flags=0x01), the password is required every launch.
/// If false (flags=0x03), the password-derived key is also stored in OS keychain
/// for silent unlock — identity is encrypted but app opens normally on this device.
#[frb]
pub fn enable_password_protection(
    password: String,
    require_on_launch: bool,
) -> Result<(), String> {
    use crate::identity::encryption;
    use crate::identity::platform_keystore;

    let data = identity::load_or_create_identity()?;
    let plaintext = data
        .keypair
        .to_protobuf_encoding()
        .map_err(|e| format!("Failed to encode keypair: {e}"))?;

    let mut salt = [0u8; 16];
    getrandom::fill(&mut salt).map_err(|e| format!("RNG error: {e}"))?;

    let wrapping_key = encryption::derive_wrapping_key_from_password(&password, &salt)?;

    let use_keychain = !require_on_launch && platform_keystore::is_available();
    let encrypted = encryption::encrypt_identity(
        &plaintext,
        &wrapping_key,
        &salt,
        true,
        use_keychain,
    )?;

    if use_keychain {
        platform_keystore::store_key(&wrapping_key)?;
    } else {
        let _ = platform_keystore::delete_key();
    }

    let dir = crate::identity::data_dir()?;
    let path = dir.join("identity.key");
    std::fs::write(&path, &encrypted)
        .map_err(|e| format!("Failed to write encrypted identity: {e}"))?;

    encryption::set_session_key(wrapping_key);

    // Mirror the new protection onto the per-device key file (hazard R2).
    identity::device_key::rewrite_device_key_protection(
        &data.device_keypair,
        Some(&wrapping_key),
        true,
        use_keychain,
    )?;
    Ok(())
}

/// Change the app password. Requires the current password for verification.
/// Preserves the current require_on_launch setting (keychain flag).
#[frb]
pub fn change_password(old_password: String, new_password: String) -> Result<(), String> {
    use crate::identity::encryption;
    use crate::identity::platform_keystore;

    let dir = crate::identity::data_dir()?;
    let path = dir.join("identity.key");
    let bytes = std::fs::read(&path)
        .map_err(|e| format!("Failed to read identity file: {e}"))?;

    let format = encryption::detect_format(&bytes)?;
    let (old_salt, had_keychain) = match format {
        encryption::IdentityFormat::Encrypted { salt, flags, .. }
            if encryption::flags_has_password(flags) =>
        {
            (salt, encryption::flags_has_os_keychain(flags))
        }
        _ => return Err("Identity is not password-protected".into()),
    };

    // Verify old password.
    let old_key = encryption::derive_wrapping_key_from_password(&old_password, &old_salt)?;
    let plaintext = encryption::decrypt_identity(&bytes, &old_key)?;

    // Re-encrypt with new password, preserving keychain flag.
    let mut new_salt = [0u8; 16];
    getrandom::fill(&mut new_salt).map_err(|e| format!("RNG error: {e}"))?;
    let new_key = encryption::derive_wrapping_key_from_password(&new_password, &new_salt)?;

    let encrypted =
        encryption::encrypt_identity(&plaintext, &new_key, &new_salt, true, had_keychain)?;

    if had_keychain {
        let _ = platform_keystore::store_key(&new_key);
    }

    std::fs::write(&path, &encrypted)
        .map_err(|e| format!("Failed to write encrypted identity: {e}"))?;

    // Re-encrypt the device key file under the new key (hazard R2). Read it with
    // the OLD key first, while we still have it.
    let device = identity::device_key::load_device_keypair_with_key(&old_key)?;
    encryption::set_session_key(new_key);
    identity::device_key::rewrite_device_key_protection(
        &device,
        Some(&new_key),
        true,
        had_keychain,
    )?;
    Ok(())
}

/// Remove password protection. If OS keychain is available, transitions to
/// keychain-only protection. Otherwise writes plaintext.
#[frb]
pub fn remove_password_protection(password: String) -> Result<(), String> {
    use crate::identity::encryption;
    use crate::identity::platform_keystore;

    let dir = crate::identity::data_dir()?;
    let path = dir.join("identity.key");
    let bytes = std::fs::read(&path)
        .map_err(|e| format!("Failed to read identity file: {e}"))?;

    let format = encryption::detect_format(&bytes)?;
    let salt = match format {
        encryption::IdentityFormat::Encrypted { salt, flags, .. } => {
            if !encryption::flags_has_password(flags) {
                return Err("Identity is not password-protected".into());
            }
            salt
        }
        _ => return Err("Identity is not encrypted".into()),
    };

    // Verify password.
    let key = encryption::derive_wrapping_key_from_password(&password, &salt)?;
    let plaintext = encryption::decrypt_identity(&bytes, &key)?;

    // Write plaintext. OS keychain is a separate opt-in from Settings.
    std::fs::write(&path, &plaintext)
        .map_err(|e| format!("Failed to write identity: {e}"))?;

    // Mirror onto the device key file: read with the old key, write plaintext.
    let device = identity::device_key::load_device_keypair_with_key(&key)?;
    identity::device_key::rewrite_device_key_protection(&device, None, false, false)?;

    let _ = platform_keystore::delete_key();
    encryption::clear_session_key();

    Ok(())
}

/// Toggle whether the password is required on each app launch.
/// When true (flags=0x01): password prompt on every launch.
/// When false (flags=0x03): password-derived key cached in OS keychain, silent unlock.
/// Requires the identity to already be password-protected and unlocked.
#[frb]
pub fn set_require_password_on_launch(require: bool) -> Result<(), String> {
    use crate::identity::encryption;
    use crate::identity::platform_keystore;

    let dir = crate::identity::data_dir()?;
    let path = dir.join("identity.key");
    let bytes =
        std::fs::read(&path).map_err(|e| format!("Failed to read identity file: {e}"))?;

    let format = encryption::detect_format(&bytes)?;
    let (salt, had_keychain) = match format {
        encryption::IdentityFormat::Encrypted { salt, flags, .. }
            if encryption::flags_has_password(flags) =>
        {
            (salt, encryption::flags_has_os_keychain(flags))
        }
        _ => return Err("Identity is not password-protected".into()),
    };

    let want_keychain = !require && platform_keystore::is_available();
    if want_keychain == had_keychain {
        return Ok(());
    }

    let session_key = encryption::get_session_key()
        .ok_or("Identity is not unlocked. Cannot change launch setting.")?;

    let plaintext = encryption::decrypt_identity(&bytes, &session_key)?;

    let encrypted =
        encryption::encrypt_identity(&plaintext, &session_key, &salt, true, want_keychain)?;

    if want_keychain {
        platform_keystore::store_key(&session_key)?;
    } else {
        let _ = platform_keystore::delete_key();
    }

    std::fs::write(&path, &encrypted)
        .map_err(|e| format!("Failed to write identity: {e}"))?;

    // Keep the device key file's flags in sync. Session key is unchanged, so the
    // device key remains decryptable regardless; this keeps the files consistent.
    let device = identity::device_key::load_device_keypair_with_key(&session_key)?;
    identity::device_key::rewrite_device_key_protection(
        &device,
        Some(&session_key),
        true,
        want_keychain,
    )?;

    Ok(())
}

/// Enable OS keychain (DPAPI/Keychain) protection on the current identity.
/// This is opt-in — the user must explicitly choose this from Settings.
/// Requires the identity to be currently unlocked and unencrypted (or keychain-already).
#[frb]
pub fn enable_os_keychain_protection() -> Result<(), String> {
    use crate::identity::encryption;
    use crate::identity::platform_keystore;

    if !platform_keystore::is_available() {
        return Err("OS keychain is not available on this platform".into());
    }

    let data = identity::load_or_create_identity()?;
    let plaintext = data
        .keypair
        .to_protobuf_encoding()
        .map_err(|e| format!("Failed to encode keypair: {e}"))?;

    let dir = crate::identity::data_dir()?;
    let path = dir.join("identity.key");

    let bytes = std::fs::read(&path).map_err(|e| format!("Failed to read identity file: {e}"))?;
    let format = encryption::detect_format(&bytes)?;

    match format {
        encryption::IdentityFormat::Plaintext => {}
        encryption::IdentityFormat::Encrypted { flags, .. } => {
            if encryption::flags_has_password(flags) {
                return Err(
                    "Cannot enable OS keychain while password protection is active. Remove password first."
                        .into(),
                );
            }
            if encryption::flags_has_os_keychain(flags) {
                return Ok(());
            }
        }
    }

    let mut wrapping_key = [0u8; 32];
    getrandom::fill(&mut wrapping_key).map_err(|e| format!("RNG error: {e}"))?;
    let salt = [0u8; 16];

    let encrypted =
        encryption::encrypt_identity(&plaintext, &wrapping_key, &salt, false, true)?;

    platform_keystore::store_key(&wrapping_key)?;

    std::fs::write(&path, &encrypted)
        .map_err(|e| format!("Failed to write encrypted identity: {e}"))?;

    encryption::set_session_key(wrapping_key);

    // Mirror keychain protection onto the device key file (hazard R2).
    identity::device_key::rewrite_device_key_protection(
        &data.device_keypair,
        Some(&wrapping_key),
        false,
        true,
    )?;
    wrapping_key.fill(0);
    Ok(())
}

/// Disable OS keychain protection — writes identity back as plaintext.
/// Requires the identity to be currently unlocked.
#[frb]
pub fn disable_os_keychain_protection() -> Result<(), String> {
    use crate::identity::encryption;
    use crate::identity::platform_keystore;

    let data = identity::load_or_create_identity()?;
    let plaintext = data
        .keypair
        .to_protobuf_encoding()
        .map_err(|e| format!("Failed to encode keypair: {e}"))?;

    let dir = crate::identity::data_dir()?;
    let path = dir.join("identity.key");

    std::fs::write(&path, &plaintext)
        .map_err(|e| format!("Failed to write identity: {e}"))?;

    // Mirror onto the device key file: write plaintext (hazard R2).
    identity::device_key::rewrite_device_key_protection(&data.device_keypair, None, false, false)?;

    let _ = platform_keystore::delete_key();
    encryption::clear_session_key();
    Ok(())
}

/// Get the current protection status of the identity file.
#[frb]
pub fn get_identity_protection_status() -> Result<ProtectionStatus, String> {
    let dir = crate::identity::data_dir()?;
    protection_status_of(&dir.join("identity.key"))
}

/// Protection status of the identity file inside an ARBITRARY data root.
///
/// The profile switcher (issue #47) needs to know whether the profile it is
/// about to erase is protected, and that profile is by definition not the one
/// this process unlocked, so `get_identity_protection_status` (which only ever
/// looks at the running `data_dir()`) cannot answer it.
#[frb]
pub fn identity_protection_status_at(data_dir: String) -> Result<ProtectionStatus, String> {
    protection_status_of(&std::path::Path::new(&data_dir).join("identity.key"))
}

/// Verify that `password` (or, when it is None, a key this machine's keystore
/// already holds) really unwraps the identity file in `data_dir`.
///
/// A GATE, not an unlock: it never touches the session key and never heals the
/// keystore slots, so asking about another profile cannot disturb the running
/// one. A plaintext identity has nothing to prove and answers true. A wrong
/// password is `Ok(false)`, not an error - only a missing or malformed file
/// errors.
#[frb]
pub fn verify_identity_password_at(
    data_dir: String,
    password: Option<String>,
) -> Result<bool, String> {
    use crate::identity::encryption;

    let path = std::path::Path::new(&data_dir).join("identity.key");
    if !path.exists() {
        return Err("No identity file found".into());
    }
    let bytes =
        std::fs::read(&path).map_err(|e| format!("Failed to read identity file: {e}"))?;

    match encryption::detect_format(&bytes)? {
        encryption::IdentityFormat::Plaintext => Ok(true),
        encryption::IdentityFormat::Encrypted { flags, salt, .. } => {
            if let Some(pw) = password.as_deref() {
                if !encryption::flags_has_password(flags) {
                    return Ok(false);
                }
                let key = encryption::derive_wrapping_key_from_password(pw, &salt)?;
                return Ok(encryption::decrypt_identity(&bytes, &key).is_ok());
            }
            if encryption::flags_has_os_keychain(flags) {
                return Ok(keychain_key_that_decrypts_opts(&bytes, false).is_some());
            }
            Ok(false)
        }
    }
}

fn protection_status_of(path: &std::path::Path) -> Result<ProtectionStatus, String> {
    use crate::identity::encryption;

    if !path.exists() {
        return Ok(ProtectionStatus {
            is_encrypted: false,
            has_password: false,
            has_os_keychain: false,
            os_keychain_available: crate::identity::platform_keystore::is_available(),
        });
    }

    let bytes =
        std::fs::read(path).map_err(|e| format!("Failed to read identity file: {e}"))?;

    match encryption::detect_format(&bytes)? {
        encryption::IdentityFormat::Plaintext => Ok(ProtectionStatus {
            is_encrypted: false,
            has_password: false,
            has_os_keychain: false,
            os_keychain_available: crate::identity::platform_keystore::is_available(),
        }),
        encryption::IdentityFormat::Encrypted { flags, .. } => Ok(ProtectionStatus {
            is_encrypted: true,
            has_password: encryption::flags_has_password(flags),
            has_os_keychain: encryption::flags_has_os_keychain(flags),
            os_keychain_available: crate::identity::platform_keystore::is_available(),
        }),
    }
}

/// Check if the identity is currently unlocked (session wrapping key is set).
#[frb]
pub fn is_identity_unlocked() -> Result<bool, String> {
    Ok(crate::identity::encryption::get_session_key().is_some())
}

#[cfg(test)]
mod profile_erase_gate_tests {
    use super::*;
    use crate::identity::encryption;

    /// A protobuf-shaped keypair blob, the shape `decrypt_identity` insists on
    /// seeing after a successful unwrap.
    fn dummy_keypair() -> Vec<u8> {
        let mut buf = vec![0x08, 0x01, 0x12, 0x40];
        buf.extend_from_slice(&[0xAA; 32]);
        buf.extend_from_slice(&[0xBB; 32]);
        buf
    }

    fn write_password_protected(dir: &std::path::Path, password: &str) {
        let salt = [0x07u8; 16];
        let key = encryption::derive_wrapping_key_from_password(password, &salt).unwrap();
        let blob = encryption::encrypt_identity(&dummy_keypair(), &key, &salt, true, false).unwrap();
        std::fs::write(dir.join("identity.key"), blob).unwrap();
    }

    #[test]
    fn status_reads_a_foreign_profile() {
        let tmp = tempfile::tempdir().unwrap();
        write_password_protected(tmp.path(), "correct horse");

        let status =
            identity_protection_status_at(tmp.path().to_string_lossy().to_string()).unwrap();
        assert!(status.is_encrypted);
        assert!(status.has_password);
        assert!(!status.has_os_keychain);
    }

    #[test]
    fn status_of_a_profile_with_no_identity_is_unprotected() {
        let tmp = tempfile::tempdir().unwrap();
        let status =
            identity_protection_status_at(tmp.path().to_string_lossy().to_string()).unwrap();
        assert!(!status.is_encrypted);
        assert!(!status.has_password);
    }

    #[test]
    fn verify_accepts_the_right_password_and_rejects_the_wrong_one() {
        let tmp = tempfile::tempdir().unwrap();
        write_password_protected(tmp.path(), "correct horse");
        let dir = tmp.path().to_string_lossy().to_string();

        assert!(verify_identity_password_at(dir.clone(), Some("correct horse".into())).unwrap());
        // A wrong password is an ANSWER, not an error - the erase dialog shows
        // it inline instead of a red toast about a failed call.
        assert!(!verify_identity_password_at(dir.clone(), Some("wrong horse".into())).unwrap());
        // No password offered and no keychain flag set: nothing to verify with.
        assert!(!verify_identity_password_at(dir, None).unwrap());
    }

    #[test]
    fn verify_passes_a_plaintext_identity_and_errors_on_a_missing_one() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().to_string_lossy().to_string();
        assert!(verify_identity_password_at(dir.clone(), None).is_err());

        std::fs::write(tmp.path().join("identity.key"), dummy_keypair()).unwrap();
        assert!(verify_identity_password_at(dir.clone(), None).unwrap());
        assert!(verify_identity_password_at(dir, Some("anything".into())).unwrap());
    }

    /// The session key belongs to the RUNNING profile. Asking about another
    /// profile must not set, clear or otherwise disturb it.
    #[test]
    fn verify_leaves_the_session_key_alone() {
        let tmp = tempfile::tempdir().unwrap();
        write_password_protected(tmp.path(), "correct horse");
        let dir = tmp.path().to_string_lossy().to_string();

        let before = encryption::get_session_key();
        let _ = verify_identity_password_at(dir.clone(), Some("correct horse".into()));
        let _ = verify_identity_password_at(dir, Some("wrong horse".into()));
        assert_eq!(before, encryption::get_session_key());
    }
}
