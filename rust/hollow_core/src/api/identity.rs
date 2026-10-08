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
    let root = crate::identity::data_dir().ok()?;
    keychain_key_that_decrypts_at(&root, bytes, true)
}

/// `heal = false` is the read-only form: it answers "can this machine unwrap this
/// file" WITHOUT re-storing the winning key. Every unlock path wants the healing form;
/// the profile-erase gate must not, because the file it tests belongs to a DIFFERENT
/// profile. A key already in the profile's own slot is never re-written: a crash in
/// the middle of that write would lose the only copy.
fn keychain_key_that_decrypts_at(
    root: &std::path::Path,
    bytes: &[u8],
    heal: bool,
) -> Option<[u8; 32]> {
    use crate::identity::platform_keystore;
    let (source, key) = platform_keystore::key_that_opens(root, bytes)?;
    if heal && source != platform_keystore::Source::Profile {
        let _ = platform_keystore::store_key_at(root, &key);
    }
    Some(key)
}

/// What unlock answers when a keychain-only identity's key cannot be had. Nothing on
/// disk was touched, so the same files open again once the key is back (the keychain
/// unlocked, the right account signed in). Dart matches the leading marker.
const KEYCHAIN_KEY_MISSING: &str =
    "keychain_key_missing: the key that opens this identity is not in this computer's keychain";

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
                match keychain_key_that_decrypts(&bytes) {
                    Some(key) => key,
                    None => return Err(KEYCHAIN_KEY_MISSING.into()),
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

    let dir = crate::identity::data_dir()?;
    let path = dir.join("identity.key");
    let before = std::fs::read(&path).ok();
    // A key is stored before the file needs it and forgotten only after the file
    // stopped needing it, so no failure in between leaves a file nothing opens.
    if use_keychain {
        platform_keystore::store_key_at(&dir, &wrapping_key)?;
    }
    encryption::write_key_file(&path, &encrypted)?;
    if !use_keychain {
        platform_keystore::forget_key_at(&dir, before.as_deref());
    }

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
        let _ = platform_keystore::store_key_at(&dir, &new_key);
    }

    encryption::write_key_file(&path, &encrypted)?;

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

    // The device file first: a plaintext device beside a still-encrypted master opens,
    // the other way round it does not. OS keychain is a separate opt-in from Settings.
    let device = identity::device_key::load_device_keypair_with_key(&key)?;
    identity::device_key::rewrite_device_key_protection(&device, None, false, false)?;
    encryption::write_key_file(&path, &plaintext)?;

    // No prompt left to type a duress code into.
    let _ = forget_duress_code(false);
    platform_keystore::forget_key_at(&dir, Some(&bytes));
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
        platform_keystore::store_key_at(&dir, &session_key)?;
    }
    encryption::write_key_file(&path, &encrypted)?;
    if !want_keychain {
        platform_keystore::forget_key_at(&dir, Some(&bytes));
    }

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

// -- OS keychain protection --

/// What a failed keychain switch says. The switch only ever ends in the new state or
/// in the old one, so "nothing changed" is always true when this is shown.
const SWITCH_REFUSED: &str =
    "Hollow couldn't lock your identity to this computer, so nothing changed.";
const SWITCH_OFF_REFUSED: &str =
    "Hollow couldn't turn off the lock to this computer, so nothing changed.";

fn refused(base: &str, detail: impl std::fmt::Display) -> String {
    crate::hollow_log!("[HOLLOW-KEYSTORE] {base} ({detail})");
    base.to_string()
}

/// A key file's plaintext, or `None` when there is no file.
fn read_plain_key_file(path: &std::path::Path) -> Result<Option<Vec<u8>>, String> {
    use crate::identity::encryption;
    let bytes = match std::fs::read(path) {
        Ok(b) => b,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(format!("Failed to read {}: {e}", path.display())),
    };
    if encryption::detect_format(&bytes)? != encryption::IdentityFormat::Plaintext {
        return Err(format!("{} is already protected", path.display()));
    }
    identity::native_identity::NativeKeypair::from_protobuf_encoding(&bytes)
        .map_err(|e| format!("{} does not hold a key: {e}", path.display()))?;
    Ok(Some(bytes))
}

/// Seals `plain` for keychain-only protection and proves `key` opens the result.
fn seal_for_keychain(plain: &[u8], key: &[u8; 32]) -> Result<Vec<u8>, String> {
    use crate::identity::encryption;
    let sealed = encryption::encrypt_identity(plain, key, &[0u8; 16], false, true)?;
    if encryption::decrypt_identity(&sealed, key)? != plain {
        return Err("a test envelope did not open to what was sealed".into());
    }
    Ok(sealed)
}

/// True when the file at `path` opens under `key` to exactly `plain`.
fn lands_as(path: &std::path::Path, key: &[u8; 32], plain: &[u8]) -> bool {
    std::fs::read(path)
        .ok()
        .and_then(|b| crate::identity::encryption::decrypt_identity(&b, key).ok())
        .is_some_and(|p| p == plain)
}

/// Plaintext key files to keychain-only protection. The key is stored, read back
/// through a NEW keystore read, and must open test envelopes before either file is
/// replaced; the master goes first (an encrypted master beside a plaintext device
/// still opens), each file through a staged, flushed, read-back rename. Any failure
/// puts the files and this profile's slot back exactly as they were.
fn switch_to_keychain(root: &std::path::Path) -> Result<[u8; 32], String> {
    use crate::identity::{encryption, platform_keystore};
    if !platform_keystore::is_available() {
        return Err("OS keychain is not available on this platform".into());
    }
    let key_path = root.join("identity.key");
    let dev_path = root.join("identity.device");
    let master = read_plain_key_file(&key_path)
        .map_err(|e| refused(SWITCH_REFUSED, e))?
        .ok_or_else(|| refused(SWITCH_REFUSED, "no identity file"))?;
    let device = read_plain_key_file(&dev_path).map_err(|e| refused(SWITCH_REFUSED, e))?;

    let mut fresh_key = zeroize::Zeroizing::new([0u8; 32]);
    getrandom::fill(&mut fresh_key[..]).map_err(|e| format!("RNG error: {e}"))?;
    let before = platform_keystore::snapshot_at(root);
    let undo = |detail: String| {
        platform_keystore::restore_snapshot(root, &before);
        refused(SWITCH_REFUSED, detail)
    };

    platform_keystore::store_key_at(root, &fresh_key[..]).map_err(&undo)?;
    let read_back = match platform_keystore::read_profile_key_at(root) {
        Ok(Some(k)) if k == fresh_key[..] => k,
        Ok(Some(_)) => return Err(undo("the keystore gave back a different key".into())),
        Ok(None) => return Err(undo("the keystore did not keep the key".into())),
        Err(e) => return Err(undo(e)),
    };
    if platform_keystore::read_blob_key_at(root).is_some_and(|b| b != read_back) {
        return Err(undo("the DPAPI copy gave back a different key".into()));
    }
    let key = zeroize::Zeroizing::new(
        <[u8; 32]>::try_from(read_back.as_slice()).map_err(|_| undo("short key".into()))?,
    );
    let sealed_master = seal_for_keychain(&master, &key).map_err(&undo)?;
    let sealed_device = match &device {
        Some(d) => Some(seal_for_keychain(d, &key).map_err(&undo)?),
        None => None,
    };

    let put_back = |detail: String| {
        if let Some(d) = &device {
            let _ = encryption::write_key_file(&dev_path, d);
        }
        let _ = encryption::write_key_file(&key_path, &master);
        undo(detail)
    };
    encryption::write_key_file(&key_path, &sealed_master).map_err(&undo)?;
    if let (Some(sealed), Some(_)) = (&sealed_device, &device) {
        encryption::write_key_file(&dev_path, sealed).map_err(&put_back)?;
    }
    let device_landed = device.as_ref().is_none_or(|d| lands_as(&dev_path, &key, d));
    if !lands_as(&key_path, &key, &master) || !device_landed {
        return Err(put_back("a protected file did not read back".into()));
    }
    encryption::set_session_key(*key);
    Ok(*key)
}

/// Keychain-only protection back to plaintext key files: the device file first (a
/// plaintext device beside a still-encrypted master opens), then the master, then
/// this profile's keys. Any failure leaves the files as they were.
fn switch_to_plaintext(root: &std::path::Path) -> Result<(), String> {
    use crate::identity::{encryption, platform_keystore};
    let key_path = root.join("identity.key");
    let dev_path = root.join("identity.device");
    let sealed_master =
        std::fs::read(&key_path).map_err(|e| refused(SWITCH_OFF_REFUSED, e))?;
    match encryption::detect_format(&sealed_master)? {
        encryption::IdentityFormat::Plaintext => return Ok(()),
        encryption::IdentityFormat::Encrypted { flags, .. }
            if encryption::flags_has_password(flags) =>
        {
            return Err("Your identity is locked with a password. Turn the password off first.".into());
        }
        encryption::IdentityFormat::Encrypted { .. } => {}
    }
    let key = encryption::get_session_key()
        .filter(|k| encryption::decrypt_identity(&sealed_master, k).is_ok())
        .or_else(|| keychain_key_that_decrypts_at(root, &sealed_master, false))
        .ok_or_else(|| refused(SWITCH_OFF_REFUSED, "no key opens the identity"))?;
    let key = zeroize::Zeroizing::new(key);
    let master = encryption::decrypt_identity(&sealed_master, &key)?;
    let device_file = std::fs::read(&dev_path).ok();
    let device = match &device_file {
        Some(bytes) => match encryption::detect_format(bytes)? {
            encryption::IdentityFormat::Plaintext => Some(bytes.clone()),
            encryption::IdentityFormat::Encrypted { .. } => Some(
                encryption::decrypt_identity(bytes, &key).map_err(|e| refused(SWITCH_OFF_REFUSED, e))?,
            ),
        },
        None => None,
    };

    if let Some(d) = &device {
        encryption::write_key_file(&dev_path, d).map_err(|e| refused(SWITCH_OFF_REFUSED, e))?;
    }
    if let Err(e) = encryption::write_key_file(&key_path, &master) {
        if let Some(original) = &device_file {
            let _ = encryption::write_key_file(&dev_path, original);
        }
        return Err(refused(SWITCH_OFF_REFUSED, e));
    }
    platform_keystore::forget_key_at(root, Some(&sealed_master));
    encryption::clear_session_key();
    Ok(())
}

/// Locks the identity to this computer's keychain, from plaintext. Already locked
/// that way is a no-op; a password identity is left alone.
fn lock_to_keychain(root: &std::path::Path) -> Result<(), String> {
    use crate::identity::encryption;
    let bytes = std::fs::read(root.join("identity.key"))
        .map_err(|e| format!("Failed to read identity file: {e}"))?;
    match encryption::detect_format(&bytes)? {
        encryption::IdentityFormat::Plaintext => switch_to_keychain(root).map(|_| ()),
        encryption::IdentityFormat::Encrypted { flags, .. }
            if encryption::flags_has_password(flags) =>
        {
            Err("Cannot enable OS keychain while password protection is active. Remove password first.".into())
        }
        encryption::IdentityFormat::Encrypted { .. } => Ok(()),
    }
}

/// `phrase` is this identity's recovery phrase: it yields this master, and the
/// recovery key the held roster pinned when there is one.
fn phrase_is_this_identitys(root: &std::path::Path, phrase: &str) -> Result<(), String> {
    let id = identity::load_existing_identity()?.ok_or("There is no identity on this device yet.")?;
    let (_, recovery) = crate::identity::recovery::recovery_key_for(&id.peer_id, phrase)?;
    let db = root.join("messages.db");
    if db.exists() {
        let pass = crate::api::storage::derive_db_key_public()?;
        let store = crate::storage::MessageStore::open(db.to_str().ok_or("Invalid path encoding")?, &pass)?;
        if let Some(roster) = crate::node::roster_book::load(&store, &id.peer_id)
            && !roster.r_pub.is_empty()
            && roster.r_pub != crate::identity::roster::r_pub_of(&recovery)
        {
            return Err("That recovery phrase belongs to a different identity.".into());
        }
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum DesktopOs {
    Windows,
    MacOs,
    Other,
}

fn this_os() -> DesktopOs {
    if cfg!(windows) {
        DesktopOs::Windows
    } else if cfg!(target_os = "macos") {
        DesktopOs::MacOs
    } else {
        DesktopOs::Other
    }
}

/// Debug builds only: lets a throwaway fleet peer, which always runs on
/// `HOLLOW_DATA_DIR`, see the default. A release build cannot read it.
fn debug_defaults_hook() -> bool {
    cfg!(debug_assertions)
        && std::env::var("HOLLOW_TEST_KEYCHAIN_DEFAULTS").is_ok_and(|v| v == "1")
}

/// Whether keychain protection is on by default here: Windows and macOS only, and
/// only on the OS's own data root. A data-dir override (`HOLLOW_DATA_DIR`, portable
/// mode, a pinned profile elsewhere, removable media) can move to another machine or
/// account, where the key would not follow.
fn default_eligible_for(
    os: DesktopOs,
    env_override: Option<&str>,
    root: &std::path::Path,
    os_default_root: Option<&std::path::Path>,
    debug_hook: bool,
) -> bool {
    if !matches!(os, DesktopOs::Windows | DesktopOs::MacOs) {
        return false;
    }
    if env_override.is_some_and(|v| !v.is_empty()) {
        return debug_hook;
    }
    let canon = |p: &std::path::Path| std::fs::canonicalize(p).ok();
    os_default_root.is_some_and(|d| canon(d).is_some() && canon(d) == canon(root))
}

fn default_eligible() -> bool {
    let Ok(root) = crate::identity::data_dir() else { return false };
    let env = std::env::var("HOLLOW_DATA_DIR").ok();
    let os_default = dirs::data_dir().map(|d| d.join("hollow"));
    crate::identity::platform_keystore::is_available()
        && default_eligible_for(this_os(), env.as_deref(), &root, os_default.as_deref(), debug_defaults_hook())
}

/// Whether this profile gets keychain protection by default, and the offer to
/// existing identities: Windows and macOS on the OS's own data root.
#[frb]
pub fn keychain_default_eligible() -> bool {
    default_eligible()
}

/// Enable OS keychain protection on a plaintext identity, verified before the files
/// change (see `switch_to_keychain`).
#[frb]
pub fn enable_os_keychain_protection() -> Result<(), String> {
    lock_to_keychain(&crate::identity::data_dir()?)
}

/// The same, for an identity that already exists: the recovery phrase must be typed
/// in full and be this identity's, because if the keychain ever loses the key, the
/// phrase is the way back.
#[frb]
pub fn enable_os_keychain_protection_with_phrase(phrase: String) -> Result<(), String> {
    let root = crate::identity::data_dir()?;
    phrase_is_this_identitys(&root, &phrase)?;
    lock_to_keychain(&root)
}

/// A new identity's default, run once its person confirmed the phrase at onboarding:
/// true when it is now locked to the keychain, false where the default does not apply
/// (see `default_eligible_for`) or the identity is already protected. An error leaves
/// it exactly as it was.
#[frb]
pub fn protect_new_identity_by_default(phrase: String) -> Result<bool, String> {
    use crate::identity::encryption;
    if !default_eligible() {
        return Ok(false);
    }
    let root = crate::identity::data_dir()?;
    let bytes = std::fs::read(root.join("identity.key"))
        .map_err(|e| format!("Failed to read identity file: {e}"))?;
    if encryption::detect_format(&bytes)? != encryption::IdentityFormat::Plaintext {
        return Ok(false);
    }
    phrase_is_this_identitys(&root, &phrase)?;
    switch_to_keychain(&root).map(|_| true)
}

/// Turn keychain protection off: the identity goes back to plaintext files.
#[frb]
pub fn disable_os_keychain_protection() -> Result<(), String> {
    switch_to_plaintext(&crate::identity::data_dir()?)
}

/// Whether `phrase` belongs to the identity whose messages are in this profile: its
/// database key opens `messages.db`. True when there is no database to compare with.
/// Restoring by phrase over a locked identity checks this first, so another
/// identity's phrase cannot take the place of the one on this computer.
#[frb]
pub fn recovery_phrase_fits_this_profile(phrase: String) -> Result<bool, String> {
    let (master, _) = crate::identity::recovery::keys_from_phrase(&phrase)?;
    let db = crate::identity::data_dir()?.join("messages.db");
    if !db.exists() {
        return Ok(true);
    }
    Ok(database_opens_with(&db, &db_key_of(&master)?))
}

/// The database key `api::storage::derive_db_key` gives this master.
fn db_key_of(master: &identity::native_identity::NativeKeypair) -> Result<String, String> {
    let proto = master
        .to_protobuf_encoding()
        .map_err(|e| format!("Failed to encode keypair: {e}"))?;
    Ok(hex::encode(&proto[..32.min(proto.len())]))
}

fn database_opens_with(path: &std::path::Path, db_key: &str) -> bool {
    use rusqlite::{Connection, OpenFlags};
    let Ok(conn) = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_WRITE) else {
        return false;
    };
    conn.execute_batch(&format!("PRAGMA key = \"x'{db_key}'\";")).is_ok()
        && conn
            .query_row("SELECT count(*) FROM sqlite_master", [], |r| r.get::<_, i64>(0))
            .is_ok()
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
                return Ok(keychain_key_that_decrypts_at(std::path::Path::new(&data_dir), &bytes, false).is_some());
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

#[cfg(test)]
mod keychain_tests {
    //! Keychain protection on by default, under the rules agreed for 0.12.1: only
    //! after the phrase is confirmed, never on an override or on Linux, verified
    //! before the files change, a missing key never costs a file, per profile.

    use super::*;
    use crate::identity::encryption::{self, test_faults};
    use crate::identity::native_identity::NativeKeypair;
    use crate::identity::platform_keystore::test_support::*;
    use crate::identity::platform_keystore::{self, test_support::Fault};
    use std::path::{Path, PathBuf};

    const PHRASE: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const OTHER: &str = "legal winner thank year wave sausage worth useful legal winner thank yellow";

    struct Fixture {
        _g: std::sync::MutexGuard<'static, ()>,
        tmp: crate::test_tmp::TestDir,
    }

    impl Fixture {
        fn root(&self) -> &Path {
            self.tmp.path()
        }

        fn files(&self) -> (Vec<u8>, Vec<u8>) {
            (
                std::fs::read(self.root().join("identity.key")).unwrap(),
                std::fs::read(self.root().join("identity.device")).unwrap(),
            )
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            encryption::clear_session_key();
            test_faults::clear();
            clear_faults();
            // SAFETY: still serialized by the guard, which drops after this.
            unsafe { std::env::remove_var("HOLLOW_TEST_KEYCHAIN_DEFAULTS") };
        }
    }

    /// A plaintext identity made from [`PHRASE`], with its device file, as a new
    /// identity or a 0.12.0 install has it.
    fn plaintext_identity() -> Fixture {
        let g = crate::node::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().expect("tempdir");
        // SAFETY: serialized by the lock above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", tmp.path()) };
        encryption::clear_session_key();
        let (master, _) = crate::identity::recovery::keys_from_phrase(PHRASE).unwrap();
        std::fs::write(tmp.path().join("identity.key"), master.to_protobuf_encoding().unwrap()).unwrap();
        let device = NativeKeypair::from_secret_bytes(&[0x6d; 32]);
        std::fs::write(tmp.path().join("identity.device"), device.to_protobuf_encoding().unwrap()).unwrap();
        Fixture { _g: g, tmp }
    }

    fn flags_of(path: PathBuf) -> u8 {
        match encryption::detect_format(&std::fs::read(path).unwrap()).unwrap() {
            encryption::IdentityFormat::Encrypted { flags, .. } => flags,
            encryption::IdentityFormat::Plaintext => 0,
        }
    }

    /// A phrase restore over a locked identity (the key-missing screen) keeps the
    /// locked files aside, so a keychain key that comes back still opens them.
    #[test]
    fn a_phrase_restore_keeps_the_locked_files_aside() {
        let fx = plaintext_identity();
        enable_os_keychain_protection().unwrap();
        let (master, device) = fx.files();
        assert_ne!(flags_of(fx.root().join("identity.key")), 0, "the fixture never locked");
        encryption::clear_session_key();

        restore_identity_from_mnemonic(PHRASE.into()).unwrap();

        assert_eq!(std::fs::read(fx.root().join("identity.key.locked")).unwrap(), master);
        assert_eq!(std::fs::read(fx.root().join("identity.device.locked")).unwrap(), device);
        let (now_master, now_device) = fx.files();
        assert_ne!(now_master, master, "the restore left the locked master in place");
        assert_ne!(now_device, device, "the restore left the locked device in place");
    }

    /// Rule 4: Windows and macOS only, only on the OS's own data root.
    #[test]
    fn the_default_applies_only_on_windows_and_macos_on_the_os_root() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let os_root = tmp.path().join("hollow");
        let elsewhere = tmp.path().join("stick").join("hollow_data");
        for d in [&os_root, &elsewhere] {
            std::fs::create_dir_all(d).unwrap();
        }
        let eligible = |os, env: Option<&str>, root: &Path, hook| {
            default_eligible_for(os, env, root, Some(&os_root), hook)
        };
        assert!(eligible(DesktopOs::Windows, None, &os_root, false));
        assert!(eligible(DesktopOs::MacOs, None, &os_root, false));
        assert!(!eligible(DesktopOs::Other, None, &os_root, false), "Linux stays opt-in");
        assert!(!eligible(DesktopOs::Other, None, &os_root, true), "the debug hook never reaches Linux");
        assert!(!eligible(DesktopOs::Windows, None, &elsewhere, false), "portable or a pinned profile elsewhere");
        let env = os_root.to_string_lossy().to_string();
        assert!(!eligible(DesktopOs::Windows, Some(&env), &os_root, false), "HOLLOW_DATA_DIR is an override");
        assert!(eligible(DesktopOs::Windows, Some(""), &os_root, false), "an empty variable is no override");
        assert!(!default_eligible_for(DesktopOs::Windows, None, &os_root, None, false), "no OS root known");
        let missing = tmp.path().join("never-created");
        assert!(!default_eligible_for(DesktopOs::MacOs, None, &missing, Some(&missing), false));
    }

    /// Every unit test runs on `HOLLOW_DATA_DIR`, which is exactly the override the
    /// default never applies to: the call answers false and changes nothing.
    #[test]
    fn a_data_dir_override_gets_no_default() {
        let fx = plaintext_identity();
        let before = fx.files();
        assert!(!keychain_default_eligible());
        assert_eq!(protect_new_identity_by_default(PHRASE.into()), Ok(false));
        assert_eq!(fx.files(), before);
        assert_eq!(profile_value(fx.root()), None);
    }

    /// Rule 1, the Rust layer: the default needs this identity's phrase (Dart passes
    /// it only once the person typed words of it back); with it the identity is
    /// locked to the keychain and opens again after a restart.
    #[test]
    fn the_default_locks_a_new_identity_once_its_phrase_is_given() {
        let fx = plaintext_identity();
        // SAFETY: serialized by the fixture's lock.
        unsafe { std::env::set_var("HOLLOW_TEST_KEYCHAIN_DEFAULTS", "1") };
        let before = fx.files();
        if this_os() == DesktopOs::Other {
            // Linux stays opt-in, the debug hook included.
            assert_eq!(protect_new_identity_by_default(PHRASE.into()), Ok(false));
            assert_eq!(fx.files(), before);
            return;
        }
        assert!(protect_new_identity_by_default(OTHER.into()).is_err(), "another identity's phrase");
        assert!(protect_new_identity_by_default("not a phrase".into()).is_err());
        assert_eq!(fx.files(), before, "a refused phrase changed the files");

        assert_eq!(protect_new_identity_by_default(PHRASE.into()), Ok(true));
        assert_eq!(flags_of(fx.root().join("identity.key")), 0x02);
        assert_eq!(flags_of(fx.root().join("identity.device")), 0x02);
        assert_eq!(protect_new_identity_by_default(PHRASE.into()), Ok(false), "already protected");

        encryption::clear_session_key();
        let id = unlock_identity(None).expect("opens silently after a restart");
        let (master, _) = crate::identity::recovery::keys_from_phrase(PHRASE).unwrap();
        assert_eq!(id.peer_id, master.peer_id());
        assert_eq!(id.device_peer_id, NativeKeypair::from_secret_bytes(&[0x6d; 32]).peer_id());
    }

    /// Rule 2: an existing identity turns it on only with its own phrase typed in
    /// full; a wrong one leaves everything as it was.
    #[test]
    fn turning_it_on_needs_this_identitys_phrase() {
        let fx = plaintext_identity();
        let before = fx.files();
        for wrong in [OTHER, "", "abandon abandon abandon"] {
            assert!(enable_os_keychain_protection_with_phrase(wrong.into()).is_err(), "{wrong:?}");
        }
        assert_eq!(fx.files(), before);
        assert_eq!(profile_value(fx.root()), None, "a refused phrase stored a key");

        enable_os_keychain_protection_with_phrase(PHRASE.into()).expect("its own phrase");
        assert_eq!(flags_of(fx.root().join("identity.key")), 0x02);
    }

    /// The second layer of rule 2: the phrase must also match the recovery key the
    /// held roster pinned, not only derive this master.
    #[test]
    fn the_phrase_must_match_the_rosters_pinned_recovery_key() {
        let fx = plaintext_identity();
        let (master, _) = crate::identity::recovery::keys_from_phrase(PHRASE).unwrap();
        let (_, foreign_recovery) = crate::identity::recovery::keys_from_phrase(OTHER).unwrap();
        let device = NativeKeypair::from_secret_bytes(&[0x6d; 32]);
        let db = fx.root().join("messages.db").to_str().unwrap().to_string();
        let pass = crate::api::storage::derive_db_key_public().unwrap();
        crate::storage::MessageStore::migrate_auto_vacuum_once(&db, &pass).unwrap();
        let store = crate::storage::MessageStore::open(&db, &pass).unwrap();
        let pinned = crate::identity::roster::Roster::genesis(&master, &foreign_recovery, &device, 1_000);
        crate::node::roster_book::merge_for_test(&store, &pinned, &master.peer_id(), &device.peer_id());
        drop(store);

        let before = fx.files();
        let err = enable_os_keychain_protection_with_phrase(PHRASE.into())
            .expect_err("the roster pins another recovery key");
        assert!(err.contains("different identity"), "{err}");
        assert_eq!(fx.files(), before);
    }

    /// Identities already using a password are left alone, by the default and by
    /// the offer.
    #[test]
    fn a_password_identity_is_left_alone() {
        let fx = plaintext_identity();
        // SAFETY: serialized by the fixture's lock.
        unsafe { std::env::set_var("HOLLOW_TEST_KEYCHAIN_DEFAULTS", "1") };
        enable_password_protection("correct horse".into(), true).expect("password");
        let before = fx.files();
        assert_eq!(protect_new_identity_by_default(PHRASE.into()), Ok(false));
        assert!(enable_os_keychain_protection_with_phrase(PHRASE.into()).is_err());
        assert!(disable_os_keychain_protection().is_err());
        assert_eq!(fx.files(), before);
    }

    /// Rule 3: the key is stored, read back through a new read, and must open the
    /// sealed files before either is replaced. Each failure point leaves both files
    /// and this profile's slot exactly as they were, and says so.
    #[test]
    fn every_failed_step_of_the_switch_leaves_the_identity_as_it_was() {
        type Break = fn();
        let breaks: [(&str, Break); 6] = [
            ("the keystore refuses the write", || inject(Fault::StoreFails)),
            ("the key does not read back", || inject(Fault::ReadBackMissing)),
            ("a different key reads back", || inject(Fault::ReadBackWrong)),
            ("the DPAPI copy opens to another key", || inject(Fault::BlobWrong)),
            ("identity.key cannot be replaced", || test_faults::fail_rename_of("identity.key")),
            ("identity.device cannot be replaced", || test_faults::fail_rename_of("identity.device")),
        ];
        for (label, apply) in breaks {
            let fx = plaintext_identity();
            set_profile(fx.root(), &[0x77; 32]);
            let before = fx.files();
            apply();
            let err = enable_os_keychain_protection_with_phrase(PHRASE.into())
                .expect_err(label);
            assert!(err.contains("nothing changed"), "{label}: {err}");
            clear_faults();
            test_faults::clear();
            assert_eq!(fx.files(), before, "{label}: the files changed");
            assert_eq!(profile_value(fx.root()), Some(vec![0x77; 32]), "{label}: the slot changed");
            assert!(!fx.root().join("identity.key.tmp").exists(), "{label}: a staging file stayed");
            assert!(!fx.root().join("identity.device.tmp").exists(), "{label}: a staging file stayed");
            assert!(encryption::get_session_key().is_none(), "{label}: a session key was set");
            unlock_identity(None).expect("the untouched identity still opens");
        }
    }

    /// Rule 5: a keychain-protected identity whose key is gone answers a marked
    /// error and touches nothing; once the key is back it opens again.
    #[test]
    fn a_missing_key_never_costs_a_file_and_opens_once_it_is_back() {
        let fx = plaintext_identity();
        let key = switch_to_keychain(fx.root()).expect("switch");
        let locked = fx.files();
        encryption::clear_session_key();
        delete_profile(fx.root());
        let _ = std::fs::remove_file(fx.root().join("identity.dpapi"));

        for _ in 0..3 {
            let Err(err) = unlock_identity(None) else { panic!("no key, no unlock") };
            assert!(err.starts_with("keychain_key_missing"), "{err}");
            assert!(!err.to_lowercase().contains("password"), "Dart reads 'password' as a password prompt");
        }
        assert_eq!(fx.files(), locked, "a missing key cost a file");
        assert!(encryption::get_session_key().is_none());

        set_profile(fx.root(), &key);
        unlock_identity(None).expect("the key is back, so it opens");
        assert_eq!(fx.files(), locked);
    }

    /// A key already in this profile's own slot is never re-written at unlock; one
    /// found only in the legacy slot is copied into the profile's slot, and the legacy
    /// slot stays for whichever profile it belongs to.
    #[test]
    fn unlock_heals_from_the_legacy_slot_without_rewriting_a_good_slot() {
        let fx = plaintext_identity();
        let key = switch_to_keychain(fx.root()).expect("switch");
        encryption::clear_session_key();
        let _ = take_writes();
        let _ = legacy_was_read();
        unlock_identity(None).expect("unlock");
        assert_eq!(take_writes(), 0, "unlock rewrote a slot that already held the key");
        assert!(!legacy_was_read(), "unlock read the shared legacy slot though its own slot opened it");

        delete_profile(fx.root());
        let _ = std::fs::remove_file(fx.root().join("identity.dpapi"));
        set_legacy(&key);
        encryption::clear_session_key();
        unlock_identity(None).expect("the legacy slot opens it");
        assert_eq!(profile_value(fx.root()), Some(key.to_vec()), "the profile slot was not healed");
        assert_eq!(legacy_value(), Some(key.to_vec()));
    }

    /// Rule 6: turning it off goes back to plaintext files and forgets this profile's
    /// keys, and the legacy slot only when it was this identity's.
    #[test]
    fn turning_it_off_restores_plaintext_and_forgets_only_this_profiles_keys() {
        let fx = plaintext_identity();
        let (plain_master, plain_device) = fx.files();
        switch_to_keychain(fx.root()).expect("switch");
        set_legacy(&[0x99; 32]);

        disable_os_keychain_protection().expect("off");
        assert_eq!(fx.files(), (plain_master, plain_device));
        assert_eq!(profile_value(fx.root()), None);
        assert!(!fx.root().join("identity.dpapi").exists());
        assert_eq!(legacy_value(), Some(vec![0x99; 32]), "another profile's legacy key went");
        unlock_identity(None).expect("plaintext opens");

        let key = switch_to_keychain(fx.root()).expect("on again");
        set_legacy(&key);
        disable_os_keychain_protection().expect("off again");
        assert_eq!(legacy_value(), None, "the identity's own legacy key stayed");
    }

    /// Turning the protection off fails part-way: the files stay as they were.
    #[test]
    fn a_failed_turn_off_leaves_the_files_as_they_were() {
        let fx = plaintext_identity();
        switch_to_keychain(fx.root()).expect("switch");
        let locked = fx.files();
        test_faults::fail_rename_of("identity.key");
        assert!(disable_os_keychain_protection().unwrap_err().contains("nothing changed"));
        test_faults::clear();
        assert_eq!(fx.files(), locked);
        encryption::clear_session_key();
        unlock_identity(None).expect("still opens from the keychain");
    }

    /// Per profile: two profiles' keys live in two slots, and switching one never
    /// touches the other's.
    #[test]
    fn each_profile_keeps_its_own_key() {
        let fx = plaintext_identity();
        let other = fx.root().join("other");
        std::fs::create_dir_all(&other).unwrap();
        for f in ["identity.key", "identity.device"] {
            std::fs::copy(fx.root().join(f), other.join(f)).unwrap();
        }
        let key_a = switch_to_keychain(fx.root()).expect("a");
        let key_b = switch_to_keychain(&other).expect("b");
        assert_ne!(key_a, key_b);
        assert_eq!(profile_value(fx.root()), Some(key_a.to_vec()));
        assert_eq!(profile_value(&other), Some(key_b.to_vec()));
        switch_to_plaintext(&other).expect("b off");
        assert_eq!(profile_value(fx.root()), Some(key_a.to_vec()), "b's change reached a");
    }

    /// The profile-erase gate asks ANOTHER profile's own slot about that profile,
    /// and never writes a key anywhere while it does.
    #[test]
    fn the_erase_gate_asks_the_other_profiles_own_slot_and_writes_nothing() {
        let fx = plaintext_identity();
        let other = fx.root().join("other");
        std::fs::create_dir_all(&other).unwrap();
        for f in ["identity.key", "identity.device"] {
            std::fs::copy(fx.root().join(f), other.join(f)).unwrap();
        }
        let key = switch_to_keychain(&other).expect("lock the other profile");
        encryption::clear_session_key();
        let _ = take_writes();
        let dir = other.to_string_lossy().to_string();
        assert_eq!(verify_identity_password_at(dir.clone(), None), Ok(true));
        assert_eq!(take_writes(), 0, "asking about another profile wrote a key");
        assert_eq!(profile_value(fx.root()), None, "the running profile's slot was written");
        delete_profile(&other);
        let _ = std::fs::remove_file(other.join("identity.dpapi"));
        assert_eq!(verify_identity_password_at(dir, None), Ok(false));
        let _ = key;
    }

    /// A profile folder that moved on this account (or the same folder under a path
    /// written differently) keeps its key in the slot named after its old path. The
    /// scan finds it, only a key that really opens the file counts, and the new
    /// path's slot is healed, so the next launch finds it at once.
    #[test]
    fn a_moved_profile_still_opens_from_its_old_slot() {
        let run = |fx: &Fixture| {
            let old_key = switch_to_keychain(fx.root()).expect("lock at the old path");
            encryption::clear_session_key();
            let moved = fx.root().join("moved");
            std::fs::create_dir_all(&moved).unwrap();
            for f in ["identity.key", "identity.device"] {
                std::fs::copy(fx.root().join(f), moved.join(f)).unwrap();
            }
            set_profile(&fx.root().join("someone-else"), &[0x13; 32]);
            // SAFETY: serialized by the fixture's lock.
            unsafe { std::env::set_var("HOLLOW_DATA_DIR", &moved) };
            unlock_identity(None).expect("the moved profile opens from its old slot");
            assert_eq!(profile_value(&moved), Some(old_key.to_vec()), "the new path's slot was not healed");
            assert_eq!(profile_value(fx.root()), Some(old_key.to_vec()), "the old slot was touched");
            encryption::clear_session_key();
            // SAFETY: as above.
            unsafe { std::env::set_var("HOLLOW_DATA_DIR", fx.root()) };
        };
        let fx = plaintext_identity();
        run(&fx);
        drop(fx);
        let fx = plaintext_identity();
        if let Some(_real) = RealKeystore::enter() {
            run(&fx);
        }
    }

    /// The scan never trusts a slot that does not open the file: with only other
    /// identities' keys around, a missing key stays missing.
    #[test]
    fn the_scan_never_trusts_a_key_that_does_not_open_the_file() {
        let fx = plaintext_identity();
        switch_to_keychain(fx.root()).expect("switch");
        encryption::clear_session_key();
        delete_profile(fx.root());
        let _ = std::fs::remove_file(fx.root().join("identity.dpapi"));
        for (i, dir) in ["a", "b", "c"].iter().enumerate() {
            set_profile(&fx.root().join(dir), &[0x20 + i as u8; 32]);
        }
        let Err(err) = unlock_identity(None) else { panic!("a foreign key opened the identity") };
        assert!(err.starts_with("keychain_key_missing"), "{err}");
    }

    /// The key-missing screen's phrase restore first asks whether the phrase opens
    /// this profile's messages, so another identity's phrase cannot replace it.
    #[test]
    fn a_phrase_fits_a_profile_only_when_it_opens_its_messages() {
        let fx = plaintext_identity();
        assert_eq!(recovery_phrase_fits_this_profile(OTHER.into()), Ok(true), "no database yet");
        let db = fx.root().join("messages.db").to_str().unwrap().to_string();
        let pass = crate::api::storage::derive_db_key_public().unwrap();
        crate::storage::MessageStore::migrate_auto_vacuum_once(&db, &pass).unwrap();
        drop(crate::storage::MessageStore::open(&db, &pass).unwrap());

        let (master, _) = crate::identity::recovery::keys_from_phrase(PHRASE).unwrap();
        assert_eq!(db_key_of(&master).unwrap(), pass, "the key drifted from derive_db_key");
        assert_eq!(recovery_phrase_fits_this_profile(PHRASE.into()), Ok(true));
        assert_eq!(recovery_phrase_fits_this_profile(OTHER.into()), Ok(false));
        assert!(recovery_phrase_fits_this_profile("nonsense words".into()).is_err());
    }

    /// The missing-key path on this machine's real keystore (test namespace): with
    /// the slot gone nothing opens and nothing changes; with it back, it opens.
    #[test]
    fn a_missing_key_on_the_real_keystore_opens_once_it_is_back() {
        let fx = plaintext_identity();
        let Some(_real) = RealKeystore::enter() else { return };
        let key = switch_to_keychain(fx.root()).expect("switch");
        encryption::clear_session_key();
        let locked = fx.files();
        delete_profile(fx.root());
        let _ = std::fs::remove_file(fx.root().join("identity.dpapi"));
        let Err(err) = unlock_identity(None) else { panic!("opened with no key") };
        assert!(err.starts_with("keychain_key_missing"), "{err}");
        assert_eq!(fx.files(), locked, "a missing key cost a file");
        set_profile(fx.root(), &key);
        unlock_identity(None).expect("opens once the key is back");
        switch_to_plaintext(fx.root()).expect("back to plaintext");
    }

    /// The same switch against this machine's real keystore, test namespace: the
    /// key reads back through a new keystore call and the identity reopens.
    #[test]
    fn the_switch_round_trips_on_the_real_keystore() {
        let fx = plaintext_identity();
        let Some(_real) = RealKeystore::enter() else { return };
        let before = fx.files();
        switch_to_keychain(fx.root()).expect("switch");
        encryption::clear_session_key();
        unlock_identity(None).expect("reopens from the real keystore");
        switch_to_plaintext(fx.root()).expect("off");
        assert_eq!(fx.files(), before);
        assert_eq!(platform_keystore::read_profile_key_at(fx.root()), Ok(None));
    }
}
