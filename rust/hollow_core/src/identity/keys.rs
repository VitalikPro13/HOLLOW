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
    if let Err(path) = DATA_DIR_OVERRIDE.set(path)
        && DATA_DIR_OVERRIDE.get() != Some(&path)
    {
        crate::log::init();
        hollow_log!("[HOLLOW-ID] The data folder was set already, so {} was not used", crate::log::redact_path(&path));
    }
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

    // A key written beside a database it never opens, or into a root a wipe is about
    // to clear, fails every launch after this one.
    crate::api::storage::refuse_while_not_ready()?;
    let root = data_dir()?;
    let mirror = fs::read(root.join("identity.key")).ok();
    land_identity_key(&root, &keypair, mirror.as_deref(), false)?;

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
/// Returns the pairs it moved.
pub(crate) fn set_aside_locked_keys(root: &std::path::Path) -> Vec<(&'static str, &'static str)> {
    let mut moved = Vec::new();
    for (name, aside) in LOCKED_KEY_FILES {
        let path = root.join(name);
        let Ok(bytes) = fs::read(&path) else { continue };
        if matches!(
            super::encryption::detect_format(&bytes),
            Ok(super::encryption::IdentityFormat::Encrypted { .. })
        ) && fs::rename(&path, root.join(aside)).is_ok()
        {
            moved.push((name, aside));
        }
    }
    moved
}

/// Present from before a key landing stages its key until the key is in place (or the
/// landing undone), naming the encrypted key files it moves to their locked names. A
/// launch that finds it with the staged key still there undoes the landing.
const KEY_LANDING_MARK: &str = ".key_landing";

/// What the mark says once a launch undid the key files: the unlock that follows, with
/// the identity's key at hand, takes back a database the landing set aside.
const KEY_LANDING_RECLAIM: &str = "reclaim";

/// Staging names of key files; the rename is each one's commit point, so one found at
/// launch belongs to a write that died.
const STAGED_KEY_FILES: [&str; 3] = ["identity.key.tmp", "identity.device.tmp", "identity.dpapi.tmp"];

/// Writes `keypair` as `root`'s identity key, never beside a database it cannot open
/// and never stranding the database of the identity still there: the key is staged
/// first, the database set aside only then, the key renamed in last, and a key that
/// does not land puts everything back (in process here, after a kill at the next
/// launch, `recover_interrupted_key_landing`). `mirror` is the key file whose
/// protection the new one takes.
fn land_identity_key(
    root: &std::path::Path,
    keypair: &NativeKeypair,
    mirror: Option<&[u8]>,
    set_aside_locked: bool,
) -> Result<(), String> {
    let _landing = super::encryption::key_file_lock();
    let planned: Vec<&str> = if set_aside_locked {
        LOCKED_KEY_FILES.iter().map(|(name, _)| *name).filter(|name| is_encrypted_key(&root.join(name))).collect()
    } else {
        Vec::new()
    };
    write_synced(&root.join(KEY_LANDING_MARK), planned.join("\n").as_bytes())
        .map_err(|e| format!("Failed to write identity file: {e}"))?;
    let landed = land_staged_key(root, keypair, mirror, set_aside_locked);
    let _ = fs::remove_file(root.join(KEY_LANDING_MARK));
    landed
}

fn land_staged_key(
    root: &std::path::Path,
    keypair: &NativeKeypair,
    mirror: Option<&[u8]>,
    set_aside_locked: bool,
) -> Result<(), String> {
    let path = root.join("identity.key");
    let staged = super::encryption::staging_path(&path);
    let discard = || crate::api::wipe::zero_and_remove(&staged);
    discard();
    let bytes = encode_key_file(mirror, keypair)?;
    if let Err(e) = stage_key_file(&staged, &bytes) {
        discard();
        return Err(e);
    }
    let kept = match crate::api::storage::keep_aside_a_database_this_identity_cannot_open(root, keypair) {
        Ok(kept) => kept,
        Err(e) => {
            discard();
            return Err(e);
        }
    };
    let put_kept_back = |kept: Option<String>| {
        if let Some(stem) = kept
            && let Err(back) = crate::api::storage::put_database_back(root, &stem)
        {
            crate::log::init();
            hollow_log!("[HOLLOW-STORE] A database set aside for a key that did not land stays aside: {back}");
        }
    };
    // The identity's own database, kept aside by an earlier phrase for another
    // identity, comes back with its key.
    let reclaimed = match crate::api::storage::put_back_a_kept_database_this_identity_opens(root, keypair) {
        Ok(reclaimed) => reclaimed,
        Err(e) => {
            discard();
            put_kept_back(kept);
            crate::log::init();
            hollow_log!("[HOLLOW-STORE] A kept database could not be read before a new key was written: {e}");
            return Err(crate::api::storage::IDENTITY_NOT_READY.into());
        }
    };
    let locked = if set_aside_locked { set_aside_locked_keys(root) } else { Vec::new() };
    let Err(e) = place_staged_key(&staged, &path) else { return Ok(()) };
    discard();
    for (name, aside) in locked {
        if !root.join(name).exists() {
            let _ = fs::rename(root.join(aside), root.join(name));
        }
    }
    if let Some(stem) = reclaimed
        && let Err(back) = crate::api::storage::move_database_to(root, &stem)
    {
        crate::log::init();
        hollow_log!("[HOLLOW-STORE] A database put back for a key that did not land stays in place: {back}");
    }
    put_kept_back(kept);
    Err(e)
}

fn is_encrypted_key(path: &std::path::Path) -> bool {
    fs::read(path).is_ok_and(|bytes| {
        matches!(
            super::encryption::detect_format(&bytes),
            Ok(super::encryption::IdentityFormat::Encrypted { .. })
        )
    })
}

fn write_synced(path: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let mut file = fs::File::create(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

/// At launch, before any unlock: a key write that died before its rename leaves a
/// staged key (plaintext when the identity had none on disk sealed yet), and a key
/// landing that died also left the old identity's locked keys and database aside. The
/// locked keys go back now; the database waits for the unlock (`reclaim_after_unlock`),
/// since only the identity's own key can tell which kept database is its. Every staged
/// key is zeroed and removed.
pub(crate) fn recover_interrupted_key_landing(root: &std::path::Path) {
    let _landing = super::encryption::key_file_lock();
    let mark = root.join(KEY_LANDING_MARK);
    if root.join("identity.key.tmp").exists() {
        let planned = fs::read_to_string(&mark).unwrap_or_default();
        for (name, aside) in LOCKED_KEY_FILES {
            if planned.lines().any(|line| line == name) && !root.join(name).exists() && root.join(aside).exists() {
                let _ = fs::rename(root.join(aside), root.join(name));
            }
        }
        let _ = write_synced(&mark, KEY_LANDING_RECLAIM.as_bytes());
    } else if fs::read_to_string(&mark).is_ok_and(|text| text != KEY_LANDING_RECLAIM) {
        // The key is in place, or the landing died before it staged anything.
        let _ = fs::remove_file(&mark);
    }
    for name in STAGED_KEY_FILES {
        crate::api::wipe::zero_and_remove(&root.join(name));
    }
}

/// Whether a key landing a kill cut short still waits for its database to come back:
/// until then no database may be made in `root`, or it would take the kept one's place.
pub(crate) fn reclaim_pending(root: &std::path::Path) -> bool {
    fs::read_to_string(root.join(KEY_LANDING_MARK)).ok().as_deref() == Some(KEY_LANDING_RECLAIM)
}

/// The unlock after a launch that undid a key landing: the identity left in the root
/// takes back the database the landing had set aside, if one opens with its key. One
/// in its place it cannot open (the new identity's, put back before the kill) goes
/// aside first.
pub(crate) fn reclaim_after_unlock() {
    let Ok(root) = data_dir() else { return };
    let _landing = super::encryption::key_file_lock();
    let mark = root.join(KEY_LANDING_MARK);
    if !reclaim_pending(&root) || crate::api::storage::has_pending_wipe().unwrap_or(true) {
        return;
    }
    if let Ok(Some(id)) = load_existing_identity() {
        let reclaimed = crate::api::storage::keep_aside_a_database_this_identity_cannot_open(&root, &id.keypair)
            .and_then(|_| crate::api::storage::put_back_a_kept_database_this_identity_opens(&root, &id.keypair));
        match reclaimed {
            Ok(Some(stem)) => {
                crate::log::init();
                hollow_log!("[HOLLOW-STORE] A key landing that did not finish had set this identity's database aside; {stem} is back");
            }
            Ok(None) => {}
            Err(e) => {
                crate::log::init();
                hollow_log!("[HOLLOW-STORE] A database a key landing set aside could not be put back yet: {e}");
                return;
            }
        }
    }
    let _ = fs::remove_file(&mark);
}

/// The staged key, flushed and read back.
fn stage_key_file(staged: &std::path::Path, bytes: &[u8]) -> Result<(), String> {
    use std::io::Write;
    let mut file = fs::File::create(staged).map_err(|e| format!("Failed to write identity file: {e}"))?;
    file.write_all(bytes)
        .and_then(|()| file.sync_all())
        .map_err(|e| format!("Failed to write identity file: {e}"))?;
    if fs::read(staged).ok().as_deref() != Some(bytes) {
        return Err("The identity file did not read back as written".to_string());
    }
    Ok(())
}

fn place_staged_key(staged: &std::path::Path, path: &std::path::Path) -> Result<(), String> {
    #[cfg(test)]
    if super::encryption::test_faults::rename_fails(path) {
        return Err(format!("injected: could not replace {}", path.display()));
    }
    fs::rename(staged, path).map_err(|e| format!("Failed to write identity file: {e}"))?;
    #[cfg(unix)]
    if let Some(dir) = path.parent()
        && let Ok(d) = fs::File::open(dir)
    {
        let _ = d.sync_all();
    }
    Ok(())
}

/// Restore an identity from an existing mnemonic phrase.
pub(crate) fn restore_identity_from_mnemonic(phrase: &str) -> Result<IdentityData, String> {
    let mnemonic: Mnemonic = phrase
        .parse()
        .map_err(|e| format!("Invalid mnemonic: {e}"))?;

    let keypair = NativeKeypair::from_mnemonic(&mnemonic)?;
    let peer_id = keypair.peer_id();

    crate::api::storage::refuse_while_not_ready()?;
    // An encrypted key it replaces is kept aside under its locked name, so the new one
    // mirrors no protection.
    land_identity_key(&data_dir()?, &keypair, None, true)?;

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

/// Save a keypair to an arbitrary path, mirroring the protection mode of whatever is
/// already there, so the device file matches the master file's password or keychain
/// state independently.
pub(crate) fn save_keypair_to(path: &PathBuf, keypair: &NativeKeypair) -> Result<(), String> {
    let existing = path.exists().then(|| fs::read(path).unwrap_or_default());
    let bytes_to_write = encode_key_file(existing.as_deref(), keypair)?;
    fs::write(path, bytes_to_write).map_err(|e| format!("Failed to write identity file: {e}"))?;
    Ok(())
}

/// A key file's bytes: an HKEYV1 envelope with `existing`'s protection when a session
/// key is set, otherwise plaintext protobuf.
fn encode_key_file(existing: Option<&[u8]>, keypair: &NativeKeypair) -> Result<Vec<u8>, String> {
    let plaintext = keypair.to_protobuf_encoding()
        .map_err(|e| format!("Failed to encode keypair: {e}"))?;

    let bytes_to_write = if let Some(key) = super::encryption::get_session_key() {
        let (password_used, os_keychain_used) = match existing.map(super::encryption::detect_format) {
            Some(Ok(super::encryption::IdentityFormat::Encrypted { flags, .. })) => {
                (super::encryption::flags_has_password(flags),
                 super::encryption::flags_has_os_keychain(flags))
            }
            _ => (false, true), // Default: OS keychain only
        };
        let mut salt = [0u8; 16];
        if password_used {
            getrandom::fill(&mut salt).map_err(|e| format!("RNG error: {e}"))?;
        }
        super::encryption::encrypt_identity(&plaintext, &key, &salt, password_used, os_keychain_used)?
    } else {
        plaintext
    };
    Ok(bytes_to_write)
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
