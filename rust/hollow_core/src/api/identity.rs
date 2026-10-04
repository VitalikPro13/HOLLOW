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

/// What Settings shows about the duress code. `scope` and `notify_friends` come
/// from the database, which is where the UI can read them; the slot itself carries
/// its own copy, because a cold launch judges the typed code before any database
/// is open.
pub struct DuressStatus {
    pub enabled: bool,
    pub scope: String,
    pub notify_friends: bool,
    /// A duress code needs a password to type it instead of. A keychain-only
    /// install has none; a silent-unlock one still prompts at a re-lock.
    pub available: bool,
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

/// Try every stored keychain candidate and return the first key that actually decrypts
/// THIS identity file, re-storing the winner so every slot self-heals to the active
/// profile. With several profiles on one machine the legacy slot routinely holds the
/// OTHER profile's key, and trusting it unverified funnelled users into mnemonic
/// recovery, which rotates the device key and discards the MLS identity and groups.
fn keychain_key_that_decrypts(bytes: &[u8]) -> Option<[u8; 32]> {
    keychain_key_that_decrypts_opts(bytes, true)
}

/// `heal = false` is the read-only form: it answers "can this machine unwrap this
/// file" WITHOUT re-storing the winning key. Every unlock path wants the healing form;
/// the profile-erase gate must not, because the file it tests belongs to a DIFFERENT
/// profile and writing that key into the shared slots is the overwrite that started
/// all this.
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

/// The one gate for a secret typed on this machine, at the launch prompt, the app
/// lock or any Settings confirmation. A TYPED secret always runs BOTH slots: two
/// derivations, two opens, and only then a decision, so a stopwatch cannot tell a
/// wrong password from a duress code. A duress code returns only AFTER the data is
/// gone; the caller shows nothing and ends the session.
fn open_typed_secret(secret: &str, bytes: &[u8], salt: &[u8; 16]) -> Result<[u8; 32], String> {
    use crate::identity::encryption;
    let identity_key = encryption::derive_wrapping_key_from_password(secret, salt)?;
    let identity_opens = encryption::decrypt_identity(bytes, &identity_key).is_ok();
    let duress = crate::identity::duress::probe(secret);
    match (identity_opens, duress) {
        (true, _) => Ok(identity_key),
        (false, Some(cfg)) => {
            crate::api::wipe::run_duress(&cfg);
            Err("duress".into())
        }
        (false, None) => Err("Wrong password or corrupted identity file".into()),
    }
}

/// Unlock the identity file for this session, before `open_message_store()` or
/// `start_node()`. A plaintext identity loads directly and ignores `password`; an
/// encrypted one decrypts with the password and/or the OS keychain.
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
        }
        encryption::IdentityFormat::Encrypted { flags, salt, .. } => {
            let wrapping_key = if encryption::flags_has_password(flags) && password.is_some() {
                open_typed_secret(password.as_deref().unwrap_or_default(), &bytes, &salt)?
            } else if encryption::flags_has_password(flags)
                && encryption::flags_has_os_keychain(flags)
            {
                // Password + keychain with nothing typed: the silent unlock.
                match keychain_key_that_decrypts(&bytes) {
                    Some(key) => key,
                    None => {
                        return Err(
                            "Identity is password-protected. Provide a password.".into(),
                        );
                    }
                }
            } else if encryption::flags_has_password(flags) {
                return Err("Identity is password-protected. Provide a password.".into());
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

/// The shortest PIN a new app-lock secret may be. A copied data folder lets a short
/// PIN fall to an offline search; a PIN set before this floor keeps unlocking.
const MIN_PIN_DIGITS: usize = 6;

/// A new secret made only of digits is a PIN, and is held to [`MIN_PIN_DIGITS`].
fn refuse_short_pin(secret: &str) -> Result<(), String> {
    if secret.chars().all(char::is_numeric) && secret.chars().count() < MIN_PIN_DIGITS {
        return Err(format!("A PIN needs at least {MIN_PIN_DIGITS} digits."));
    }
    Ok(())
}

/// Enable password protection. With `require_on_launch` the password is needed every
/// launch; without it the password-derived key is also stored in the OS keychain, so
/// the identity is encrypted but the app opens normally on this device.
#[frb]
pub fn enable_password_protection(
    password: String,
    require_on_launch: bool,
) -> Result<(), String> {
    use crate::identity::encryption;
    use crate::identity::platform_keystore;

    refuse_short_pin(&password)?;

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

    // A duress slot exists for the life of password protection, so its presence
    // never reveals whether a duress code is set.
    let _ = forget_duress_code(true);

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

    refuse_short_pin(&new_password)?;

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

    let old_key = open_typed_secret(&old_password, &bytes, &old_salt)?;
    let plaintext = encryption::decrypt_identity(&bytes, &old_key)?;

    // A new password that also opens the duress slot would DISARM the duress code
    // silently: the identity slot is tried first and wins, so the code would never
    // fire again.
    if crate::identity::duress::probe(&new_password).is_some() {
        return Err("That is your duress code. Choose a different password.".into());
    }

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

    let key = open_typed_secret(&password, &bytes, &salt)?;
    let plaintext = encryption::decrypt_identity(&bytes, &key)?;

    // Write plaintext. OS keychain is a separate opt-in from Settings.
    std::fs::write(&path, &plaintext)
        .map_err(|e| format!("Failed to write identity: {e}"))?;

    // Mirror onto the device key file: read with the old key, write plaintext.
    let device = identity::device_key::load_device_keypair_with_key(&key)?;
    identity::device_key::rewrite_device_key_protection(&device, None, false, false)?;

    // No prompt left to type a duress code into.
    let _ = forget_duress_code(false);
    let _ = platform_keystore::delete_key();
    encryption::clear_session_key();

    Ok(())
}

// -- Duress code --

/// Password protection is the whole requirement: silent-unlock installs still
/// prompt at an app lock, which is a real place to type a duress code.
fn duress_available() -> bool {
    use crate::identity::encryption;
    let Ok(dir) = crate::identity::data_dir() else { return false };
    let Ok(bytes) = std::fs::read(dir.join("identity.key")) else { return false };
    match encryption::detect_format(&bytes) {
        Ok(encryption::IdentityFormat::Encrypted { flags, .. }) => {
            encryption::flags_has_password(flags)
        }
        _ => false,
    }
}

/// `password` must open the identity file. A GATE, never an unlock: it proves the
/// person changing the duress code is the owner and not whoever walked past an
/// open Settings window.
fn owner_gate(password: &str) -> Result<(), String> {
    use crate::identity::encryption;
    let dir = crate::identity::data_dir()?;
    let bytes = std::fs::read(dir.join("identity.key"))
        .map_err(|e| format!("Failed to read identity file: {e}"))?;
    let salt = match encryption::detect_format(&bytes)? {
        encryption::IdentityFormat::Encrypted { salt, flags, .. }
            if encryption::flags_has_password(flags) =>
        {
            salt
        }
        _ => return Err("Identity is not password-protected".into()),
    };
    open_typed_secret(password, &bytes, &salt).map(|_| ())
}

/// True when `code` also unwraps the identity: it would unlock instead of
/// destroying, which is the one thing a duress code must never do.
fn code_is_the_password(code: &str) -> bool {
    use crate::identity::encryption;
    let Ok(dir) = crate::identity::data_dir() else { return false };
    let Ok(bytes) = std::fs::read(dir.join("identity.key")) else { return false };
    let salt = match encryption::detect_format(&bytes) {
        Ok(encryption::IdentityFormat::Encrypted { salt, .. }) => salt,
        _ => return false,
    };
    encryption::derive_wrapping_key_from_password(code, &salt)
        .map(|k| encryption::decrypt_identity(&bytes, &k).is_ok())
        .unwrap_or(false)
}

/// Every path that replaces the duress slot with a dummy, or drops it, clears
/// what Settings shows with it, so a code shown as set always opens its slot.
fn forget_duress_code(keep_dummy_slot: bool) -> Result<(), String> {
    if keep_dummy_slot {
        crate::identity::duress::set_dummy()?;
    } else {
        crate::identity::duress::remove()?;
    }
    save_duress_settings("", false);
    Ok(())
}

fn save_duress_settings(scope: &str, notify_friends: bool) {
    let store = crate::api::storage::get_store();
    let Ok(guard) = store.lock() else { return };
    let Some(ms) = guard.as_ref() else { return };
    let _ = ms.save_setting("duress_scope", scope);
    let _ = ms.save_setting("duress_notify_friends", if notify_friends { "1" } else { "0" });
}

/// Set (or replace) the duress code. `scope` is `device`, `device_revoke` or
/// `identity`. The `identity` scope erases every device, which only the recovery
/// phrase may order (design ID-1): `phrase` signs a permission for this device, kept
/// in the slot.
#[frb]
pub fn set_duress_code(
    password: String,
    duress_code: String,
    scope: String,
    notify_friends: bool,
    phrase: Option<String>,
) -> Result<(), String> {
    if duress_code.trim().is_empty() {
        return Err("Enter a duress code.".into());
    }
    if !duress_available() {
        return Err(
            "A duress code needs password protection. Turn it on to use one."
                .into(),
        );
    }
    owner_gate(&password)?;
    if duress_code == password || code_is_the_password(&duress_code) {
        return Err("The duress code has to be different from your password.".into());
    }
    let permission = match (scope.as_str(), phrase.as_deref()) {
        (crate::identity::duress::SCOPE_IDENTITY, Some(p)) => Some(super::roster::destroy_permission(p)?),
        // The phrase stored before 0.12 signs it while it is here, so the code keeps
        // its reach once that copy is erased.
        (crate::identity::duress::SCOPE_IDENTITY, None) => match super::roster::stored_phrase() {
            Some(stored) => Some(super::roster::destroy_permission(&stored)?),
            None => {
                // Only an identity with no recovery key yet can erase everywhere without one.
                super::roster::destroy_order(None, notify_friends)?;
                None
            }
        },
        _ => None,
    };
    crate::identity::duress::set_code(&duress_code, &scope, notify_friends, permission.as_ref())?;
    save_duress_settings(&scope, notify_friends);
    Ok(())
}

/// Remove the duress code. The slot stays, holding random bytes under a random
/// key, so the disk looks the same either way.
#[frb]
pub fn clear_duress_code(password: String) -> Result<(), String> {
    owner_gate(&password)?;
    forget_duress_code(true)
}

#[frb]
pub fn duress_status() -> DuressStatus {
    let store = crate::api::storage::get_store();
    let (scope, notify_friends) = match store.lock() {
        Ok(guard) => match guard.as_ref() {
            Some(ms) => (
                ms.load_setting("duress_scope").ok().flatten().unwrap_or_default(),
                ms.load_setting("duress_notify_friends").ok().flatten().as_deref() == Some("1"),
            ),
            None => (String::new(), false),
        },
        Err(_) => (String::new(), false),
    };
    let available = duress_available();
    DuressStatus {
        // No password, no prompt to type a code into, whatever an older version left set.
        enabled: available && !scope.is_empty(),
        scope,
        notify_friends,
        available,
    }
}

/// Toggle whether the password is required on each launch: on means a prompt every
/// time, off caches the password-derived key in the OS keychain for a silent unlock.
/// The identity must already be password-protected and unlocked.
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

    // Keep the device key file's flags in sync; the session key is unchanged either way.
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
/// The profile switcher needs to know whether the profile it is about to erase is
/// protected, and that profile is by definition not the one this process unlocked, so
/// `get_identity_protection_status` cannot answer it.
#[frb]
pub fn identity_protection_status_at(data_dir: String) -> Result<ProtectionStatus, String> {
    protection_status_of(&std::path::Path::new(&data_dir).join("identity.key"))
}

fn is_running_root(dir: &str) -> bool {
    let canon = |p: &std::path::Path| std::fs::canonicalize(p).ok();
    let Ok(running) = crate::identity::data_dir() else { return false };
    canon(std::path::Path::new(dir)).is_some_and(|d| Some(d) == canon(&running))
}

/// Verify that `password` (or, when it is None, a key this machine's keystore
/// already holds) really unwraps the identity file in `data_dir`.
///
/// A GATE, not an unlock: it never touches the session key and never heals the keystore
/// slots, so asking about another profile cannot disturb the running one. A plaintext
/// identity answers true, a wrong password is `Ok(false)`, and only a missing or
/// malformed file errors, or the running profile's duress code, which wipes as at
/// every prompt.
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
                // Erasing the running profile asks its own password, which is a
                // prompt a duress code may be typed into.
                if is_running_root(&data_dir) {
                    return match open_typed_secret(pw, &bytes, &salt) {
                        Ok(_) => Ok(true),
                        Err(e) if e == "duress" => Err(e),
                        Err(_) => Ok(false),
                    };
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
        let tmp = crate::test_tmp::tempdir().unwrap();
        write_password_protected(tmp.path(), "correct horse");

        let status =
            identity_protection_status_at(tmp.path().to_string_lossy().to_string()).unwrap();
        assert!(status.is_encrypted);
        assert!(status.has_password);
        assert!(!status.has_os_keychain);
    }

    #[test]
    fn status_of_a_profile_with_no_identity_is_unprotected() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let status =
            identity_protection_status_at(tmp.path().to_string_lossy().to_string()).unwrap();
        assert!(!status.is_encrypted);
        assert!(!status.has_password);
    }

    #[test]
    fn verify_accepts_the_right_password_and_rejects_the_wrong_one() {
        let tmp = crate::test_tmp::tempdir().unwrap();
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
        let tmp = crate::test_tmp::tempdir().unwrap();
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
        let tmp = crate::test_tmp::tempdir().unwrap();
        write_password_protected(tmp.path(), "correct horse");
        let dir = tmp.path().to_string_lossy().to_string();

        let before = encryption::get_session_key();
        let _ = verify_identity_password_at(dir.clone(), Some("correct horse".into()));
        let _ = verify_identity_password_at(dir, Some("wrong horse".into()));
        assert_eq!(before, encryption::get_session_key());
    }
}

#[cfg(test)]
mod duress_tests {
    use super::*;
    use crate::identity::{duress, encryption};
    use crate::identity::native_identity::NativeKeypair;

    const PASSWORD: &str = "correct horse battery staple";
    const CODE: &str = "9 1 1 1";

    /// `HOLLOW_DATA_DIR`, the session key and the derive counter are all
    /// process-global, so these share the crate-wide test lock.
    fn temp_identity() -> (std::sync::MutexGuard<'static, ()>, crate::test_tmp::TestDir) {
        temp_identity_of(NativeKeypair::from_secret_bytes(&[0x5a; 32]))
    }

    fn temp_identity_of(master: NativeKeypair) -> (std::sync::MutexGuard<'static, ()>, crate::test_tmp::TestDir) {
        let g = crate::node::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().expect("tempdir");
        // SAFETY: serialized by the lock above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", tmp.path()) };
        encryption::clear_session_key();

        // The master AND the per-device file, both under the same wrapping key: the
        // protection-change flows rewrite the device file too, so a fixture without
        // one exercises a different failure.
        for (name, kp) in [("identity.key", master), ("identity.device", device())] {
            let plaintext = kp.to_protobuf_encoding().expect("encode");
            let blob = encryption::encrypt_identity(&plaintext, &wrapping_key(), &SALT, true, false)
                .expect("encrypt");
            std::fs::write(tmp.path().join(name), blob).expect("write key file");
        }
        duress::set_dummy().expect("dummy slot");
        (g, tmp)
    }

    const SALT: [u8; 16] = [0x21; 16];

    fn wrapping_key() -> [u8; 32] {
        encryption::derive_wrapping_key_from_password(PASSWORD, &SALT).expect("derive")
    }

    fn device() -> NativeKeypair {
        NativeKeypair::from_secret_bytes(&[0x5b; 32])
    }

    /// Settings only runs on an unlocked identity.
    fn unlock() {
        encryption::set_session_key(wrapping_key());
    }

    const PHRASE: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    /// The whole design stands on this: a wrong password and a duress code must
    /// cost the same, so the work is a CONSTANT two derivations whatever happens.
    #[test]
    fn duress_both_slots_always_derived() {
        let (_g, _tmp) = temp_identity();

        for (label, secret) in [("right", PASSWORD), ("wrong", "not the password")] {
            let _ = encryption::take_derive_count();
            let _ = unlock_identity(Some(secret.to_string()));
            assert_eq!(
                encryption::take_derive_count(), 2,
                "{label} password with no duress code set must derive twice",
            );
        }

        duress::set_code(CODE, duress::SCOPE_DEVICE, false, None).expect("set code");
        for (label, secret) in [("right", PASSWORD), ("wrong", "not the password")] {
            let _ = encryption::take_derive_count();
            let _ = unlock_identity(Some(secret.to_string()));
            assert_eq!(
                encryption::take_derive_count(), 2,
                "{label} password with a duress code set must derive twice",
            );
        }

        // An install that predates the slot has no file at all, and must still cost
        // the same: the probe derives against a throwaway salt either way.
        duress::remove().expect("remove slot");
        let _ = encryption::take_derive_count();
        let _ = unlock_identity(Some(PASSWORD.to_string()));
        assert_eq!(
            encryption::take_derive_count(), 2,
            "an identity with no duress slot must derive twice as well",
        );
        encryption::clear_session_key();
    }

    /// A silent-unlock install has a password and an app lock that asks for it,
    /// so the duress code is on offer there too.
    #[test]
    fn duress_available_with_a_silent_keychain_password() {
        let (_g, tmp) = temp_identity();
        assert!(duress_available(), "a launch prompt offers a duress code");

        let salt = [0x21u8; 16];
        let key = encryption::derive_wrapping_key_from_password(PASSWORD, &salt).expect("derive");
        let plaintext = NativeKeypair::from_secret_bytes(&[0x5au8; 32])
            .to_protobuf_encoding()
            .expect("encode");
        let blob = encryption::encrypt_identity(&plaintext, &key, &salt, true, true)
            .expect("encrypt");
        std::fs::write(tmp.path().join("identity.key"), blob).expect("write key file");
        assert!(
            duress_available(),
            "a silent unlock still re-prompts at an app lock"
        );
    }

    /// A new password that opens the duress slot would DISARM the duress code in
    /// silence: the identity slot is tried first and wins, so the code never fires
    /// again and the person believes they still have one.
    #[test]
    fn change_password_refuses_the_duress_code() {
        let (_g, _tmp) = temp_identity();
        duress::set_code(CODE, duress::SCOPE_DEVICE, false, None).expect("set code");

        let err = change_password(PASSWORD.into(), CODE.into())
            .expect_err("the duress code must not become the password");
        assert!(err.contains("duress code"), "unexpected message: {err}");

        // Refused means UNCHANGED: the old password still opens the identity and the
        // duress code still opens its slot.
        assert!(duress::probe(CODE).is_some());
        change_password(PASSWORD.into(), "a different password".into())
            .expect("an unrelated new password is accepted");
        encryption::clear_session_key();
    }

    /// A code that also unwraps the identity would unlock instead of destroying,
    /// which is the one thing it must never do.
    #[test]
    fn duress_code_must_differ_from_password() {
        let (_g, _tmp) = temp_identity();
        unlock();

        let err = set_duress_code(
            PASSWORD.into(), PASSWORD.into(), duress::SCOPE_DEVICE.into(), false, None,
        )
        .expect_err("the password itself must be refused as a duress code");
        assert!(err.contains("different"), "unexpected message: {err}");

        set_duress_code(PASSWORD.into(), CODE.into(), duress::SCOPE_IDENTITY.into(), true, None)
            .expect("a distinct code is accepted");
        let cfg = duress::probe(CODE).expect("the code opens its slot");
        assert_eq!(cfg.scope, duress::SCOPE_IDENTITY);
        assert!(cfg.notify_friends);

        // The wrong owner password is a gate failure, not a silent no-op.
        assert!(set_duress_code(
            "wrong".into(), "another code".into(), duress::SCOPE_DEVICE.into(), false, None,
        ).is_err());
        assert_eq!(duress::probe(CODE).map(|c| c.scope), Some(duress::SCOPE_IDENTITY.into()));
        encryption::clear_session_key();
    }

    /// The "everywhere" scope keeps the phrase's permission for this device in the
    /// slot; a phrase of another identity signs nothing.
    #[test]
    fn duress_everywhere_keeps_the_phrase_permission() {
        let master = crate::identity::recovery::keys_from_phrase(PHRASE).expect("phrase").0;
        let (_g, _tmp) = temp_identity_of(master);
        unlock();

        let other = "legal winner thank year wave sausage worth useful legal winner thank yellow";
        assert!(set_duress_code(
            PASSWORD.into(), CODE.into(), duress::SCOPE_IDENTITY.into(), false, Some(other.into()),
        ).is_err(), "another identity's phrase must be refused");

        set_duress_code(PASSWORD.into(), CODE.into(), duress::SCOPE_IDENTITY.into(), false, Some(PHRASE.into()))
            .expect("the identity's own phrase is accepted");
        let cfg = duress::probe(CODE).expect("the code opens its slot");
        let perm = cfg.permission.expect("the slot holds the permission");
        let recovery = crate::identity::recovery::keys_from_phrase(PHRASE).expect("phrase").1;
        assert_eq!(perm.r_pub, recovery.public_key_bytes(), "signed by this identity's recovery key");
        encryption::clear_session_key();
    }

    /// An identity from before 0.12 still holding its stored phrase: the "everywhere"
    /// scope set without a typed phrase takes the stored one's permission, so the code
    /// keeps its reach once that copy is confirmed and erased.
    #[test]
    fn duress_everywhere_takes_the_stored_phrase_while_it_is_here() {
        let (master, recovery) = crate::identity::recovery::keys_from_phrase(PHRASE).expect("phrase");
        let (_g, tmp) = temp_identity_of(master);
        unlock();
        let db = tmp.path().join("messages.db").to_str().expect("utf-8").to_string();
        let pass = crate::api::storage::derive_db_key_public().expect("db key");
        crate::storage::MessageStore::migrate_auto_vacuum_once(&db, &pass).expect("migrate");
        crate::storage::MessageStore::open(&db, &pass).expect("open").save_setting("recovery_mnemonic", PHRASE).expect("stored phrase");

        set_duress_code(PASSWORD.into(), CODE.into(), duress::SCOPE_IDENTITY.into(), false, None)
            .expect("the stored phrase signs the permission");
        let perm = duress::probe(CODE).and_then(|c| c.permission).expect("the slot holds the permission");
        assert_eq!(perm.r_pub, recovery.public_key_bytes(), "signed by this identity's recovery key");
        encryption::clear_session_key();
    }

    /// Once the phrase is the root, only the phrase orders every device erased: a
    /// duress code set without it would carry an order nobody accepts.
    #[test]
    fn duress_everywhere_on_a_protected_identity_needs_the_phrase() {
        let (master, recovery) = crate::identity::recovery::keys_from_phrase(PHRASE).expect("phrase");
        let (_g, tmp) = temp_identity_of(
            NativeKeypair::from_protobuf_encoding(&master.to_protobuf_encoding().expect("encode")).expect("decode"),
        );
        unlock();
        let db = tmp.path().join("messages.db").to_str().expect("utf-8").to_string();
        let pass = crate::api::storage::derive_db_key_public().expect("db key");
        crate::storage::MessageStore::migrate_auto_vacuum_once(&db, &pass).expect("migrate");
        let store = crate::storage::MessageStore::open(&db, &pass).expect("open");
        let genesis = crate::identity::roster::Roster::genesis(&master, &recovery, &device(), 1_000);
        crate::node::roster_book::merge_for_test(&store, &genesis, &master.peer_id(), &device().peer_id());
        drop(store);

        let err = set_duress_code(PASSWORD.into(), CODE.into(), duress::SCOPE_IDENTITY.into(), false, None)
            .expect_err("a protected identity refuses the scope without the phrase");
        assert!(err.contains("recovery phrase"), "unexpected message: {err}");
        assert!(duress::probe(CODE).is_none(), "refused means no code was stored");

        set_duress_code(PASSWORD.into(), CODE.into(), duress::SCOPE_DEVICE.into(), false, None)
            .expect("the device scope needs no phrase");
        set_duress_code(PASSWORD.into(), CODE.into(), duress::SCOPE_IDENTITY.into(), false, Some(PHRASE.into()))
            .expect("with the phrase it is accepted");
        assert!(duress::probe(CODE).and_then(|c| c.permission).is_some());
        encryption::clear_session_key();
    }

    /// Every Settings prompt that takes the password treats a duress code the way
    /// the launch prompt does: both slots cost the same, the data goes, and the
    /// caller hears only "duress".
    #[test]
    fn a_duress_code_at_any_settings_prompt_wipes_like_the_launch_prompt() {
        type Prompt = fn(&str) -> Result<(), String>;
        let prompts: [(&str, Prompt); 5] = [
            ("change the password", |pw| change_password(pw.into(), "a new password".into())),
            ("turn the password off", |pw| remove_password_protection(pw.into())),
            ("set a duress code", |pw| {
                set_duress_code(pw.into(), "another code".into(), duress::SCOPE_DEVICE.into(), false, None)
            }),
            ("remove the duress code", |pw| clear_duress_code(pw.into())),
            ("erase this profile", |pw| {
                let root = crate::identity::data_dir()?.to_string_lossy().to_string();
                verify_identity_password_at(root, Some(pw.into())).map(|_| ())
            }),
        ];
        for (label, prompt) in prompts {
            let (_g, tmp) = temp_identity();
            let _slots = crate::identity::platform_keystore::SlotGuard::capture();
            unlock();
            duress::set_code(CODE, duress::SCOPE_DEVICE, false, None).expect("set code");

            let _ = encryption::take_derive_count();
            let _ = prompt("not the password");
            assert_eq!(encryption::take_derive_count(), 2, "{label}: a wrong password costs both slots");
            assert!(tmp.path().join("identity.key").exists(), "{label}: a wrong password erases nothing");

            let _ = encryption::take_derive_count();
            let err = prompt(CODE).expect_err("the duress code never passes a prompt");
            assert_eq!(err, "duress", "{label}");
            assert_eq!(encryption::take_derive_count(), 2, "{label}: the duress code costs the same");
            assert!(!tmp.path().join("identity.key").exists(), "{label}: the duress code wipes");
            assert!(!tmp.path().join("identity.duress").exists(), "{label}: the slot goes too");
            encryption::clear_session_key();
        }
    }

    /// Settings shows a duress code only while its slot still opens: turning the
    /// password off and on replaces the slot, so the code is gone and says so.
    #[test]
    fn turning_the_password_off_and_on_never_reports_a_dead_duress_code() {
        let (_g, _tmp) = temp_identity();
        let _s = crate::api::storage::store_test_lock();
        let _slots = crate::identity::platform_keystore::SlotGuard::capture();
        crate::api::storage::set_test_store(
            crate::storage::MessageStore::open(":memory:", &"ab".repeat(32)).expect("store"),
        );
        unlock();
        set_duress_code(PASSWORD.into(), CODE.into(), duress::SCOPE_DEVICE.into(), false, None)
            .expect("set code");
        assert!(duress_status().enabled);

        remove_password_protection(PASSWORD.into()).expect("password off");
        assert!(!duress_status().enabled, "with no password there is no prompt to type it into");
        // An older version left the setting behind: still no prompt, still no code.
        save_duress_settings(duress::SCOPE_DEVICE, false);
        assert!(!duress_status().enabled, "a stale setting must not show a code");

        enable_password_protection(PASSWORD.into(), true).expect("password on");
        assert!(duress::probe(CODE).is_none(), "the slot was replaced");
        assert!(!duress_status().enabled, "Settings shows a duress code that no longer opens");

        if let Ok(mut store) = crate::api::storage::get_store().lock() {
            *store = None;
        }
        encryption::clear_session_key();
    }
}

#[cfg(test)]
mod pin_floor_tests {
    use super::*;
    use crate::identity::encryption;
    use crate::identity::native_identity::NativeKeypair;

    const SALT: [u8; 16] = [0x31; 16];

    /// An identity whose master and device files are wrapped under `secret`, the
    /// way an install from before the PIN floor holds them.
    fn identity_under(secret: &str) -> (std::sync::MutexGuard<'static, ()>, crate::test_tmp::TestDir) {
        let g = crate::node::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().expect("tempdir");
        // SAFETY: serialized by the lock above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", tmp.path()) };
        encryption::clear_session_key();
        let key = encryption::derive_wrapping_key_from_password(secret, &SALT).expect("derive");
        for (name, seed) in [("identity.key", 0x6a), ("identity.device", 0x6b)] {
            let plaintext = NativeKeypair::from_secret_bytes(&[seed; 32])
                .to_protobuf_encoding()
                .expect("encode");
            let blob = encryption::encrypt_identity(&plaintext, &key, &SALT, true, false)
                .expect("encrypt");
            std::fs::write(tmp.path().join(name), blob).expect("write key file");
        }
        crate::identity::duress::set_dummy().expect("dummy slot");
        (g, tmp)
    }

    /// A copied data folder lets a short PIN fall to an offline search, so no new
    /// app-lock secret made only of digits is shorter than six.
    #[test]
    fn a_new_pin_needs_six_digits() {
        let (_g, _tmp) = identity_under("correct horse");

        // Locked, so a refusal is the only thing that can answer here: nothing
        // reaches the keystore whatever the outcome.
        for short in ["1234", "12345", ""] {
            let err = enable_password_protection(short.into(), true)
                .expect_err("a short PIN is refused");
            assert!(err.contains("6 digits"), "unexpected message: {err}");
        }

        unlock_identity(Some("correct horse".into())).expect("unlock");
        for short in ["1234", "12345", ""] {
            let err = change_password("correct horse".into(), short.into())
                .expect_err("a short PIN is refused as the new secret");
            assert!(err.contains("6 digits"), "unexpected message: {err}");
        }
        change_password("correct horse".into(), "123456".into()).expect("six digits is enough");
        encryption::clear_session_key();
        unlock_identity(Some("123456".into())).expect("the new PIN opens the identity");
        // A short secret with a letter in it is a password, not a PIN.
        change_password("123456".into(), "pa55".into()).expect("a password has no digit floor");
        encryption::clear_session_key();
    }

    /// The floor applies to a secret being SET: a PIN chosen before it keeps
    /// opening the identity, and can be traded for a longer one.
    #[test]
    fn an_old_four_digit_pin_still_unlocks() {
        let (_g, _tmp) = identity_under("1234");
        unlock_identity(Some("1234".into())).expect("an existing short PIN keeps unlocking");
        change_password("1234".into(), "246810".into()).expect("the short PIN can be replaced");
        encryption::clear_session_key();
        unlock_identity(Some("246810".into())).expect("the longer PIN opens it");
        encryption::clear_session_key();
    }
}
