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
        os_data_root()?
    };
    fs::create_dir_all(&dir).map_err(|e| format!("Failed to create data dir: {e}"))?;
    Ok(dir)
}

/// The OS's own data folder for Hollow.
#[cfg(not(test))]
fn os_data_root() -> Result<PathBuf, String> {
    let base = dirs::data_dir().ok_or("Could not find app data directory")?;
    Ok(base.join("hollow"))
}

/// Test builds never reach the OS's own folder: a suite run on a person's machine
/// wrote a database and vault files into their real profile. A test that names no
/// root gets one of its own, per process, under the test temp root.
#[cfg(test)]
fn os_data_root() -> Result<PathBuf, String> {
    Ok(crate::test_tmp::process_dir("os-root").join("hollow"))
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
) -> Result<Landing, String> {
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

/// What a key landing moved, so a restore that fails after it puts the folder back
/// ([`Landing::undo`]).
pub(crate) struct Landing {
    locked: Vec<(&'static str, &'static str)>,
    /// The database the new identity cannot open, kept aside under this name.
    kept: Option<String>,
    /// The new identity's own kept database, put back from this name.
    reclaimed: Option<String>,
    /// The plaintext key file the new one replaced.
    replaced: Option<zeroize::Zeroizing<Vec<u8>>>,
    /// No database was in place once the key landed.
    no_database: bool,
}

impl Landing {
    /// Puts back what the landing changed: the key file as it was, the locked keys
    /// under their names, the databases where they were. A database made after the
    /// landing holds only what the failed restore wrote, and goes, so typing the phrase
    /// again signs for one device, never beside one nobody holds a key for.
    fn undo(self, root: &std::path::Path) {
        crate::log::init();
        let path = root.join("identity.key");
        match &self.replaced {
            Some(bytes) => {
                if let Err(e) = super::encryption::write_key_file(&path, bytes) {
                    hollow_log!("[HOLLOW-ID] The key file a failed restore replaced could not be put back: {e}");
                }
            }
            None => {
                let _landing = super::encryption::key_file_lock();
                crate::api::wipe::zero_and_remove(&path);
                if path.exists() {
                    hollow_log!("[HOLLOW-ID] The key a failed restore landed could not be taken back out");
                }
            }
        }
        {
            let _landing = super::encryption::key_file_lock();
            for (name, aside) in &self.locked {
                if !root.join(name).exists()
                    && let Err(e) = fs::rename(root.join(aside), root.join(name))
                {
                    hollow_log!("[HOLLOW-ID] A locked key file could not go back after a failed restore: {e}");
                }
            }
        }
        let databases = (|| {
            if self.no_database {
                crate::api::storage::remove_database(root)?;
            }
            if let Some(stem) = &self.reclaimed {
                crate::api::storage::move_database_to(root, stem)?;
            }
            if let Some(stem) = &self.kept {
                crate::api::storage::put_database_back(root, stem)?;
            }
            Ok::<(), String>(())
        })();
        if let Err(e) = databases {
            hollow_log!("[HOLLOW-STORE] A database stays where a failed restore left it: {e}");
        }
    }
}

fn land_staged_key(
    root: &std::path::Path,
    keypair: &NativeKeypair,
    mirror: Option<&[u8]>,
    set_aside_locked: bool,
) -> Result<Landing, String> {
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
    let replaced = fs::read(&path).ok().map(zeroize::Zeroizing::new);
    let Err(e) = place_staged_key(&staged, &path) else {
        let no_database = !root.join("messages.db").exists();
        return Ok(Landing { locked, kept, reclaimed, replaced, no_database });
    };
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

/// Why typed words are not a recovery phrase (positions from 1).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PhraseError {
    Words(usize),
    Word(usize),
    Checksum,
}

impl PhraseError {
    /// The code Welcome maps to its copy.
    pub(crate) fn code(self) -> String {
        match self {
            PhraseError::Words(n) => format!("phrase_words:{n}"),
            PhraseError::Word(i) => format!("phrase_word:{i}"),
            PhraseError::Checksum => "phrase_checksum".into(),
        }
    }

    /// What the in-app phrase dialogs show.
    pub(crate) fn text(self) -> String {
        match self {
            PhraseError::Words(n) => format!("A recovery phrase is 24 words. This one has {n}."),
            PhraseError::Word(i) => format!("Word {i} isn't a recovery phrase word. Check how it's spelled."),
            PhraseError::Checksum => "These words aren't a recovery phrase. Check each word and the order.".into(),
        }
    }
}

/// Every phrase Hollow made is 24 English words; a 12-word wallet phrase is never one.
const PHRASE_WORDS: usize = 24;

/// `typed` as a recovery phrase: lowercased, single-spaced, exactly 24 words of the
/// English list with a valid checksum.
pub(crate) fn parse_phrase(typed: &str) -> Result<Mnemonic, PhraseError> {
    let lower = zeroize::Zeroizing::new(typed.to_lowercase());
    let words: Vec<&str> = lower.split_whitespace().collect();
    if words.len() != PHRASE_WORDS {
        return Err(PhraseError::Words(words.len()));
    }
    let normalized = zeroize::Zeroizing::new(words.join(" "));
    Mnemonic::parse_in_normalized(bip39::Language::English, &normalized).map_err(|e| match e {
        bip39::Error::UnknownWord(i) => PhraseError::Word(i + 1),
        _ => PhraseError::Checksum,
    })
}

/// How a typed phrase restores (PHRASE_RESTORE_DESIGN 1.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PhraseRestore {
    /// The in-app restores and Welcome's No: the device already here is kept when it
    /// may be, else the phrase admits a new one.
    Admit,
    /// Welcome's Yes: a recovery keeping only a newly minted device.
    Recover { lost_since_ms: i64 },
}

/// What a phrase restore did.
pub(crate) struct Restored {
    pub data: IdentityData,
    /// The device already here was kept; nothing was signed.
    pub kept_device: bool,
    /// No roster was held here (a fresh install).
    pub empty: bool,
}

/// Restore an identity from an existing mnemonic phrase (the in-app restores).
pub(crate) fn restore_identity_from_mnemonic(phrase: &str) -> Result<IdentityData, String> {
    let mnemonic = parse_phrase(phrase).map_err(PhraseError::text)?;
    restore_with_phrase(&mnemonic, PhraseRestore::Admit, false).map(|r| r.data)
}

/// Lands the phrase's master key, then keeps the device this folder holds or mints one
/// (HOL-SEC-217), signing into the database with the phrase (HOL-SEC-218). `welcome`
/// drops a gone identity's duress slot first and leaves the mark the Home card reads.
pub(crate) fn restore_with_phrase(mnemonic: &Mnemonic, how: PhraseRestore, welcome: bool) -> Result<Restored, String> {
    let keypair = NativeKeypair::from_mnemonic(mnemonic)?;
    crate::api::storage::refuse_while_not_ready()?;
    let root = data_dir()?;
    if welcome && !root.join("identity.key").exists() {
        // A code made for an identity that is gone must never fire beside this one.
        crate::api::wipe::zero_and_remove(&root.join("identity.duress"));
    }
    // An encrypted key it replaces is kept aside under its locked name, so the new one
    // mirrors no protection.
    let landing = land_identity_key(&root, &keypair, None, true)?;
    // A restore that fails past here leaves the folder as it was, so no launch runs
    // the new master key beside the old device.
    restore_landed(&root, mnemonic, keypair, how, welcome).inspect_err(|_| landing.undo(&root))
}

/// [`restore_with_phrase`] once the master key landed.
fn restore_landed(root: &std::path::Path, mnemonic: &Mnemonic, keypair: NativeKeypair, how: PhraseRestore, welcome: bool) -> Result<Restored, String> {
    let peer_id = keypair.peer_id();
    let seed = zeroize::Zeroizing::new(mnemonic.to_seed(""));
    let recovery = super::recovery::recovery_keypair_from_seed(&seed);
    let db_path = root.join("messages.db").to_str().ok_or("Invalid path encoding")?.to_string();
    let db_passphrase = crate::api::storage::db_key_of(&keypair)?;
    let store = crate::storage::MessageStore::open(&db_path, &db_passphrase)?;
    let held = crate::node::roster_book::held_for_restore(&store, &peer_id, &db_path);
    let empty = held.is_none();

    if how == PhraseRestore::Admit
        && let Some(old) = device_kept_here(root, &store, held.as_ref(), &keypair)
    {
        let device_peer_id = old.peer_id();
        return Ok(Restored {
            data: IdentityData { keypair, peer_id, device_keypair: old, device_peer_id, mnemonic: None },
            kept_device: true,
            empty,
        });
    }

    // Restoring a mnemonic onto a device IS the multi-device case, so this device MUST
    // mint a FRESH random device key (seeding from master recreates the same-peer_id
    // collision). The old device's secrets go before anything is signed for the new
    // one, and its key file is replaced last.
    let mut device_secret = zeroize::Zeroizing::new([0u8; 32]);
    getrandom::fill(&mut device_secret[..]).map_err(|e| format!("RNG failed: {e}"))?;
    let device_keypair = NativeKeypair::from_secret_bytes(&device_secret);
    let device_peer_id = device_keypair.peer_id();
    store.forget_device_secrets()?;
    if let Some(held) = &held {
        crate::node::roster_book::keep_held_for_restore(&store, held, &device_peer_id, &db_path)?;
    }
    let sign = match how {
        PhraseRestore::Admit => crate::api::roster::RestoreSign::Admit,
        PhraseRestore::Recover { lost_since_ms } => crate::api::roster::RestoreSign::Recover {
            lost_since_ms,
            // A held roster keeps its own choice; with none, someone else may hold a
            // device, so a restored backup joins only when approved (decision Nov 21).
            no_wait: held.as_ref().is_none_or(|h| crate::node::roster_book::fold(&store, h).no_wait),
        },
    };
    crate::api::roster::sign_restore(&keypair, &device_keypair, &recovery, sign, &db_path, &db_passphrase)?;
    if welcome {
        let branch = match how {
            PhraseRestore::Admit => crate::node::phrase_restore::Branch::Admit,
            PhraseRestore::Recover { .. } => crate::node::phrase_restore::Branch::Recover,
        };
        let mark = crate::node::phrase_restore::Mark { at_ms: now_ms(), branch, empty, device: device_peer_id.clone() };
        crate::node::phrase_restore::write(&store, &mark)?;
    }
    drop(store);
    place_key_file(&device_keypair_path()?, &device_keypair)?;

    Ok(Restored {
        data: IdentityData { keypair, peer_id, device_keypair, device_peer_id, mnemonic: None },
        kept_device: false,
        empty,
    })
}

/// The device `root` already holds, when a phrase restore may keep it whole (HOL-SEC-217,
/// D4): its key file decodes, it is not the master (G1), the held
/// roster counts it, and the database's MLS identity, when there is one, is certified
/// for it. Anything else mints a device.
fn device_kept_here(
    root: &std::path::Path,
    store: &crate::storage::MessageStore,
    held: Option<&super::roster::Roster>,
    master: &NativeKeypair,
) -> Option<NativeKeypair> {
    // An encrypted one was set aside as `.locked` by the landing, so this is plaintext.
    let bytes = zeroize::Zeroizing::new(fs::read(root.join("identity.device")).ok()?);
    let device = NativeKeypair::from_protobuf_encoding(&bytes).ok()?;
    let id = device.peer_id();
    let own = master.peer_id();
    if id == own || !crate::node::roster_book::fold(store, held?).is_member(&id) {
        return None;
    }
    let mls_names_it = match crate::crypto::MlsManager::load_from(store, &[]) {
        Ok(None) => true,
        Ok(Some(mls)) => mls.bound_leaf().is_some_and(|leaf| leaf.device == id && leaf.master == own),
        Err(_) => false,
    };
    mls_names_it.then_some(device)
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

/// [`save_keypair_to`] through a staged write, so a write that fails or dies leaves
/// the file there before it whole.
fn place_key_file(path: &std::path::Path, keypair: &NativeKeypair) -> Result<(), String> {
    let existing = zeroize::Zeroizing::new(fs::read(path).ok());
    let bytes = zeroize::Zeroizing::new(encode_key_file(existing.as_deref(), keypair)?);
    super::encryption::write_key_file(path, &bytes)
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

    /// #155 review: a suite run on a person's machine wrote into their real profile.
    #[test]
    fn tests_never_touch_the_real_data_root() {
        let fallback = super::os_data_root().unwrap();
        if let Some(real) = dirs::data_dir() {
            assert!(!fallback.starts_with(real.join("hollow")), "a test build falls back to the OS folder: {fallback:?}");
        }
        assert!(fallback.starts_with(crate::test_tmp::process_dir("os-root")), "{fallback:?}");
        assert_eq!(fallback, super::os_data_root().unwrap(), "one root per process");
        if std::env::var_os("HOLLOW_DATA_DIR").is_none() && super::DATA_DIR_OVERRIDE.get().is_none() {
            assert_eq!(super::data_dir().unwrap(), fallback);
        }
    }

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

#[cfg(test)]
mod phrase_restore_tests {
    use super::*;
    use crate::identity::roster::{self, Roster};
    use crate::storage::MessageStore;

    struct Root {
        _g: std::sync::MutexGuard<'static, ()>,
        _s: std::sync::MutexGuard<'static, ()>,
        tmp: crate::test_tmp::TestDir,
    }

    impl Root {
        fn path(&self) -> std::path::PathBuf {
            self.tmp.path().join("data")
        }
        fn db(&self) -> String {
            self.path().join("messages.db").to_string_lossy().into_owned()
        }
        fn store(&self, master: &NativeKeypair) -> MessageStore {
            MessageStore::open(&self.db(), &crate::api::storage::db_key_of(master).unwrap()).unwrap()
        }
    }

    impl Drop for Root {
        fn drop(&mut self) {
            // SAFETY: still serialized by the guards, which drop after this.
            unsafe { std::env::remove_var("HOLLOW_DATA_DIR") };
        }
    }

    fn root() -> Root {
        let g = crate::node::resolver::test_lock();
        let s = crate::api::storage::store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        fs::create_dir_all(tmp.path().join("data")).unwrap();
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", tmp.path().join("data")) };
        super::super::encryption::clear_session_key();
        Root { _g: g, _s: s, tmp }
    }

    /// An identity on disk whose database holds its roster (the old device counted),
    /// as one that has run once has it. Returns the phrase, master and device.
    fn ran_once(r: &Root) -> (zeroize::Zeroizing<String>, NativeKeypair, NativeKeypair) {
        let id = generate_new_identity().unwrap();
        let phrase = zeroize::Zeroizing::new(id.mnemonic.clone().unwrap());
        let store = r.store(&id.keypair);
        let (_, state) = crate::node::roster_book::ensure_own(&store, &id.keypair, &id.device_keypair, &r.db());
        assert!(state.is_member(&id.device_peer_id), "precondition: the old device counts");
        (phrase, id.keypair, id.device_keypair)
    }

    fn mls_for(store: &MessageStore, device: &NativeKeypair, master: &NativeKeypair) {
        let m = crate::crypto::MlsManager::new(device, master).unwrap();
        store.save_mls_identity(&m.signer_bytes().unwrap(), &m.credential_bytes().unwrap(), &m.serialize_storage().unwrap()).unwrap();
    }

    fn own_state(r: &Root, master: &NativeKeypair) -> (Roster, roster::RosterState) {
        let store = r.store(master);
        let held = crate::node::roster_book::load(&store, &master.peer_id()).expect("a roster in the database");
        let state = crate::node::roster_book::fold(&store, &held);
        (held, state)
    }

    fn restore(phrase: &str, how: PhraseRestore) -> Restored {
        restore_with_phrase(&parse_phrase(phrase).unwrap(), how, true).unwrap()
    }

    /// HOL-SEC-217 (reviewer probe, ported): a restore that mints a device beside this
    /// identity's own database (the key pair gone, or bound to the device elsewhere)
    /// never speaks with the old device's Olm or MLS state.
    #[test]
    fn a_restore_that_mints_a_device_beside_its_own_database_starts_a_fresh_olm_account() {
        let r = root();
        let (phrase, master, old) = ran_once(&r);
        let account = crate::crypto::OlmManager::new().account_pickle_json().unwrap().to_string();
        {
            let store = r.store(&master);
            store.save_olm_account(&account).unwrap();
            store.save_olm_read_mark("peer", 5).unwrap();
            assert!(store.insert_live_frame_nonce("peer", &[1; 16], i64::MAX, "peer", false).unwrap());
            mls_for(&store, &old, &master);
            store.save_setting("theme", "dark").unwrap();
        }
        crate::api::wipe::zero_and_remove(&r.path().join("identity.key"));
        crate::api::wipe::zero_and_remove(&r.path().join("identity.device"));

        let new = restore_identity_from_mnemonic(&phrase).unwrap();

        assert_ne!(new.device_peer_id, old.peer_id(), "a restore mints a new device");
        let store = r.store(&master);
        let held = store.load_olm_account().unwrap().map(|a| a.to_string());
        assert_ne!(held.as_deref(), Some(account.as_str()), "the new device runs on the old device's Olm account");
        assert!(store.load_mls_identity().unwrap().is_none(), "the old device's MLS identity stayed");
        assert!(store.load_olm_read_marks().unwrap().is_empty(), "the old device's read marks stayed");
        assert!(store.load_live_frame_nonces(0, i64::MAX).unwrap().is_empty(), "the old device's nonces stayed");
        assert_eq!(store.load_setting("theme").unwrap().as_deref(), Some("dark"), "the database's own rows went");
        assert!(own_state(&r, &master).1.is_member(&new.device_peer_id), "the phrase admitted the new device");
    }

    /// D4: only the key file was lost. The device this folder holds, counted and named
    /// by its MLS credential, is kept whole: nothing minted, signed or marked.
    #[test]
    fn a_restore_over_a_lost_key_file_keeps_its_counted_device() {
        let r = root();
        let (phrase, master, old) = ran_once(&r);
        let account = crate::crypto::OlmManager::new().account_pickle_json().unwrap().to_string();
        {
            let store = r.store(&master);
            store.save_olm_account(&account).unwrap();
            mls_for(&store, &old, &master);
        }
        let roster_before = own_state(&r, &master).0;
        crate::api::wipe::zero_and_remove(&r.path().join("identity.key"));

        let done = restore(&phrase, PhraseRestore::Admit);

        assert!(done.kept_device);
        assert_eq!(done.data.device_peer_id, old.peer_id(), "the counted device was replaced");
        assert_eq!(fs::read(r.path().join("identity.device")).unwrap(), old.to_protobuf_encoding().unwrap());
        let store = r.store(&master);
        assert_eq!(store.load_olm_account().unwrap().map(|a| a.to_string()).as_deref(), Some(account.as_str()));
        assert!(store.load_mls_identity().unwrap().is_some());
        assert_eq!(store.load_setting(crate::node::phrase_restore::KEY).unwrap(), None, "a kept device wrote the mark");
        assert_eq!(own_state(&r, &master).0, roster_before, "a kept device signed something");
    }

    #[test]
    fn a_restore_never_keeps_a_device_its_roster_does_not_count() {
        let r = root();
        let (phrase, _, old) = ran_once(&r);
        let stranger = NativeKeypair::from_secret_bytes(&[0x71; 32]);
        fs::write(r.path().join("identity.device"), stranger.to_protobuf_encoding().unwrap()).unwrap();
        crate::api::wipe::zero_and_remove(&r.path().join("identity.key"));

        let done = restore(&phrase, PhraseRestore::Admit);

        assert!(!done.kept_device);
        assert_ne!(done.data.device_peer_id, stranger.peer_id(), "kept a device the roster does not count");
        assert_ne!(done.data.device_peer_id, old.peer_id());
    }

    /// G1: a legacy roster can count the master id (a 0.11 keystone), and anyone with
    /// the master key can log in as it, so it is never kept as this device.
    #[test]
    fn a_restore_never_keeps_the_master_as_its_device() {
        let r = root();
        let id = generate_new_identity().unwrap();
        let phrase = id.mnemonic.clone().unwrap();
        let master = id.keypair;
        let own = master.peer_id();
        let _ = fs::remove_file(r.path().join(crate::node::roster_book::BOOTSTRAP_FILE));
        let mut legacy = Roster::new(&own);
        legacy.add_legacy(roster::sign_legacy(&master, &own));
        legacy.add_consent(roster::sign_consent(&master, &own));
        {
            let store = r.store(&master);
            crate::node::roster_book::merge_for_test(&store, &legacy, &own, &own);
            assert!(crate::node::roster_book::fold(&store, &legacy).is_member(&own), "precondition: the legacy roster counts the master id");
        }
        fs::write(r.path().join("identity.device"), master.to_protobuf_encoding().unwrap()).unwrap();
        crate::api::wipe::zero_and_remove(&r.path().join("identity.key"));

        let done = restore(&phrase, PhraseRestore::Admit);

        assert!(!done.kept_device);
        assert_ne!(done.data.device_peer_id, own, "kept the master as this device");
    }

    #[test]
    fn a_restore_never_keeps_a_device_the_databases_mls_credential_does_not_name() {
        let r = root();
        let (phrase, master, old) = ran_once(&r);
        mls_for(&r.store(&master), &NativeKeypair::from_secret_bytes(&[0x72; 32]), &master);
        crate::api::wipe::zero_and_remove(&r.path().join("identity.key"));

        let done = restore(&phrase, PhraseRestore::Admit);

        assert!(!done.kept_device);
        assert_ne!(done.data.device_peer_id, old.peer_id(), "kept a device beside another device's MLS identity");
        assert!(r.store(&master).load_mls_identity().unwrap().is_none());
    }

    /// Yes: "someone else may have it" covers a copy of this folder, so a recovery never
    /// keeps the device here, and its base keeps only the new one.
    #[test]
    fn a_recovery_restore_always_mints_a_device() {
        let r = root();
        let (phrase, master, old) = ran_once(&r);
        mls_for(&r.store(&master), &old, &master);
        crate::api::wipe::zero_and_remove(&r.path().join("identity.key"));

        let done = restore(&phrase, PhraseRestore::Recover { lost_since_ms: 1_000 });

        assert!(!done.kept_device);
        assert_ne!(done.data.device_peer_id, old.peer_id());
        let (_, state) = own_state(&r, &master);
        assert_eq!(state.members, std::collections::BTreeSet::from([done.data.device_peer_id.clone()]));
    }

    /// HOL-SEC-218: a restore beside a held roster whose base is dated ahead of this
    /// clock (a recovery signed by a device a few minutes fast) still counts.
    #[test]
    fn a_restore_beside_a_held_roster_dates_its_admission_after_its_newest_statement() {
        let r = root();
        let (phrase, master, old) = ran_once(&r);
        let (_, recovery) = crate::identity::recovery::keys_from_phrase(&phrase).unwrap();
        let (mut held, _) = own_state(&r, &master);
        let ahead = now_ms() + 5 * 60 * 1000;
        let rec = roster::sign_recovery(&master, &recovery, ahead, &[old.peer_id()], false);
        held.add_phrase_statement(&roster::r_pub_of(&recovery), Some(rec), None).unwrap();
        crate::node::roster_book::merge_for_test(&r.store(&master), &held, &master.peer_id(), &old.peer_id());
        crate::api::wipe::zero_and_remove(&r.path().join("identity.key"));
        crate::api::wipe::zero_and_remove(&r.path().join("identity.device"));

        let done = restore(&phrase, PhraseRestore::Admit);

        let (roster, state) = own_state(&r, &master);
        assert!(roster.base_at() == Some(ahead), "precondition: the base is the one dated ahead");
        assert!(state.is_member(&done.data.device_peer_id), "the admission was dated before the base it joins");
        assert!(state.is_member(&old.peer_id()), "an admission drops nobody");
    }

    #[test]
    fn welcome_recovery_into_an_empty_store_signs_a_base_keeping_only_this_device() {
        let r = root();
        let phrase = Mnemonic::from_entropy(&[0x33; 32]).unwrap().to_string();
        let t = now_ms() - 3_600_000;

        let done = restore(&phrase, PhraseRestore::Recover { lost_since_ms: t });

        assert!(done.empty);
        let master = done.data.keypair.clone();
        let (roster, state) = own_state(&r, &master);
        assert_eq!(roster.recoveries.len(), 1);
        assert_eq!(state.members, std::collections::BTreeSet::from([done.data.device_peer_id.clone()]));
        assert!(state.no_wait, "an empty install's recovery lets a restored backup wait in");
        let store = r.store(&master);
        assert_eq!(crate::node::roster_book::recovery_lost_since(&store, &roster.base()), Some(t));
        let mark = crate::node::phrase_restore::current(&store, &done.data.device_peer_id, now_ms()).expect("the mark");
        assert_eq!((mark.branch, mark.empty), (crate::node::phrase_restore::Branch::Recover, true));
        assert!(!r.path().join(crate::node::roster_book::BOOTSTRAP_FILE).exists(), "the restore left a bootstrap");
    }

    /// The in-app restores share the 24-word rule: a 12-word wallet phrase lands nothing.
    #[test]
    fn every_phrase_restore_refuses_a_12_word_phrase() {
        let r = root();
        let twelve = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let err = restore_identity_from_mnemonic(twelve).err().expect("a 12-word phrase restored");
        assert_eq!(err, "A recovery phrase is 24 words. This one has 12.");
        assert!(!r.path().join("identity.key").exists(), "a key landed");
    }

    #[test]
    fn a_welcome_restore_drops_a_gone_identitys_duress_slot() {
        let r = root();
        let slot = r.path().join("identity.duress");
        fs::write(&slot, [0xa5u8; 96]).unwrap();
        let peek = r.tmp.path().join("peek");
        fs::hard_link(&slot, &peek).unwrap();
        let phrase = Mnemonic::from_entropy(&[0x34; 32]).unwrap().to_string();

        restore(&phrase, PhraseRestore::Admit);

        assert!(!slot.exists(), "a gone identity's duress slot stayed beside the restored one");
        assert!(fs::read(&peek).unwrap().iter().all(|b| *b == 0), "the slot was unlinked unzeroed");
    }

    /// Review finding 2: a Yes restore that fails once the master key has landed takes
    /// the key back out, so the next launch never runs as the old device the person
    /// said someone else may hold.
    #[test]
    fn a_recovery_that_fails_after_the_key_lands_never_runs_as_the_old_device() {
        let r = root();
        let (phrase, master, old) = ran_once(&r);
        crate::api::wipe::zero_and_remove(&r.path().join("identity.key"));
        let db = r.path().join("messages.db");
        let mut perms = fs::metadata(&db).unwrap().permissions();
        perms.set_readonly(true);
        fs::set_permissions(&db, perms.clone()).unwrap();
        assert!(fs::OpenOptions::new().write(true).open(&db).is_err(), "precondition: the database cannot be written");
        let out = restore_with_phrase(&parse_phrase(&phrase).unwrap(), PhraseRestore::Recover { lost_since_ms: 1_000 }, true);
        #[allow(clippy::permissions_set_readonly_false)]
        perms.set_readonly(false);
        fs::set_permissions(&db, perms).unwrap();
        assert!(out.is_err(), "precondition: the restore failed");
        let landed = r.path().join("identity.key").exists();
        let device = fs::read(r.path().join("identity.device")).ok().and_then(|b| NativeKeypair::from_protobuf_encoding(&b).ok()).map(|k| k.peer_id());
        let counted = own_state(&r, &master).1.is_member(&old.peer_id());
        assert!(
            !(landed && device.as_deref() == Some(old.peer_id().as_str()) && counted),
            "the failed recovery left the master key beside the old device, which still counts: the next launch runs as it",
        );
        assert!(!landed, "the landed key stayed after the restore failed");
    }

    /// Review finding 2: a restore on a fresh install that fails at its last step
    /// leaves the folder as it found it, so typing the phrase again admits one device,
    /// never a second beside a first nobody holds a key for.
    #[test]
    fn a_failed_restore_on_a_fresh_install_leaves_nothing_behind() {
        let r = root();
        let phrase = Mnemonic::from_entropy(&[0x35; 32]).unwrap().to_string();
        super::super::encryption::test_faults::fail_rename_of("identity.device");
        let out = restore_with_phrase(&parse_phrase(&phrase).unwrap(), PhraseRestore::Recover { lost_since_ms: 1_000 }, true);
        super::super::encryption::test_faults::clear();
        assert!(out.is_err(), "precondition: the restore failed");
        for name in ["identity.key", "identity.device", "messages.db", "messages.db-wal"] {
            assert!(!r.path().join(name).exists(), "{name} stayed after the restore failed");
        }

        let done = restore(&phrase, PhraseRestore::Recover { lost_since_ms: 1_000 });

        let master = NativeKeypair::from_mnemonic(&parse_phrase(&phrase).unwrap()).unwrap();
        let members = own_state(&r, &master).1.members;
        assert_eq!(members.into_iter().collect::<Vec<_>>(), vec![done.data.device_peer_id], "the failed restore's device still counts");
    }

    /// Review finding 2: a locked identity's key file, set aside for a restore that then
    /// fails, comes back under its own name.
    #[test]
    fn a_failed_restore_puts_a_locked_key_back() {
        let r = root();
        let mut locked = b"HKEYV1".to_vec();
        locked.push(0x02);
        locked.resize(119, 7);
        fs::write(r.path().join("identity.key"), &locked).unwrap();
        let phrase = Mnemonic::from_entropy(&[0x36; 32]).unwrap().to_string();
        super::super::encryption::test_faults::fail_rename_of("identity.device");
        let out = restore_with_phrase(&parse_phrase(&phrase).unwrap(), PhraseRestore::Admit, true);
        super::super::encryption::test_faults::clear();
        assert!(out.is_err(), "precondition: the restore failed");
        assert_eq!(fs::read(r.path().join("identity.key")).unwrap(), locked, "the locked key is not back");
        assert!(!r.path().join("identity.key.locked").exists());
    }
}
