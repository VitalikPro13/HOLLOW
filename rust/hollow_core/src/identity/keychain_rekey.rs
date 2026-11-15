//! macOS (HOL-SEC-187): macOS lets only the app that made a login keychain item
//! delete it, so the item a build before 0.14 wrote may outlive the move, and every
//! old build could still read it. An identity whose files a key in such an item opens
//! moves onto a fresh key kept only in the protected keychain; the old item then
//! opens nothing. A keychain-only identity (`0x02`) moves at start onto a random key.
//! A password identity whose key the keychain caches (`0x03`) holds a key derived
//! from the password, so it moves only with the password in hand: a typed unlock
//! derives a new key under a fresh salt (the duress slot keeps its own salt).
//!
//! The files are the live pair and the pair a phrase restore set aside (the same
//! master secret). Every step leaves a stored key that opens every file on disk: the
//! new key is staged under `<slot>.rekey` (which unlock tries right after the profile
//! slot) and read back before any file changes, each file is replaced whole and
//! checked, the profile slot takes the new key only once every file opens with it,
//! and the old key goes last. A start that finds the work half done finishes it from
//! what it reads; the unlock re-wraps a device file a cut left on the other key.

use std::path::Path;

use zeroize::Zeroizing;

use super::{encryption, platform_keystore};

const KEY_FILE: &str = "identity.key";
const DEVICE_FILE: &str = "identity.device";
/// The pair a phrase restore set aside (`keys::set_aside_locked_keys`).
const LOCKED: [&str; 2] = [super::keys::LOCKED_KEY_FILES[0].1, super::keys::LOCKED_KEY_FILES[1].1];
/// Every file one identity's key opens, in the order a re-key rewrites them.
const FILES: [&str; 4] = [KEY_FILE, DEVICE_FILE, LOCKED[0], LOCKED[1]];

const KEYCHAIN_ONLY: u8 = encryption::FLAG_OS_KEYCHAIN;
const PASSWORD_CACHED: u8 = encryption::FLAG_PASSWORD | encryption::FLAG_OS_KEYCHAIN;

type Key = Zeroizing<[u8; 32]>;

/// What one folder's re-key did.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Rekey {
    /// No login item opens these files, and no re-key was waiting.
    Nothing,
    /// The files moved onto a new key; `stay` login items keep the old one.
    Rekeyed { stay: usize },
    /// An earlier start's re-key, finished now.
    Finished,
    /// A login item holds the key of a password identity, which only the password
    /// can change.
    PasswordKey,
    /// Stopped before it could finish; nothing is lost and the next start tries again.
    Failed(String),
    /// The test hook ended the "process" here.
    Died,
}

fn header(bytes: &[u8]) -> Option<(u8, [u8; 16])> {
    match encryption::detect_format(bytes) {
        Ok(encryption::IdentityFormat::Encrypted { flags, salt, .. }) => Some((flags, salt)),
        _ => None,
    }
}

fn flags_of(bytes: &[u8]) -> Option<u8> {
    header(bytes).map(|(flags, _)| flags)
}

fn has_password(bytes: &[u8]) -> bool {
    flags_of(bytes).is_some_and(encryption::flags_has_password)
}

fn opens(file: &[u8], key: &[u8]) -> bool {
    <[u8; 32]>::try_from(key).is_ok_and(|k| encryption::decrypt_identity(file, &k).is_ok())
}

fn same(a: &[u8], b: &[u8]) -> bool {
    use subtle::ConstantTimeEq;
    a.len() == b.len() && bool::from(a.ct_eq(b))
}

/// One folder's encrypted key files, as read now.
struct Set {
    files: Vec<(&'static str, Vec<u8>)>,
}

impl Set {
    fn read(dir: &Path) -> Self {
        let files = FILES
            .iter()
            .filter_map(|name| std::fs::read(dir.join(name)).ok().map(|bytes| (*name, bytes)))
            .filter(|(_, bytes)| header(bytes).is_some())
            .collect();
        Self { files }
    }

    fn get(&self, name: &str) -> Option<&[u8]> {
        self.files.iter().find(|(n, _)| *n == name).map(|(_, b)| b.as_slice())
    }

    fn opened_by(&self, key: &[u8]) -> bool {
        self.files.iter().any(|(_, b)| opens(b, key))
    }
}

/// The encrypted key files of some folders, to judge a login key by.
pub(crate) struct Ours {
    sets: Vec<Set>,
}

impl Ours {
    pub(crate) fn of(dirs: &[std::path::PathBuf]) -> Self {
        Self { sets: dirs.iter().map(|d| Set::read(d)).collect() }
    }

    /// Whether `key` opens any of them.
    pub(crate) fn opened_by(&self, key: &[u8]) -> bool {
        self.sets.iter().any(|s| s.opened_by(key))
    }
}

/// The stored key that opens `file`, checked by decrypting it.
fn key_of(dir: &Path, file: &[u8]) -> Option<Key> {
    platform_keystore::key_that_opens(dir, file).map(|(_, k)| k)
}

/// The key `secret` derives for a password file under its own salt, if it opens it.
fn password_key(secret: &str, file: &[u8]) -> Option<Key> {
    let (_, salt) = header(file)?;
    let key = Zeroizing::new(encryption::derive_wrapping_key_from_password(secret, &salt).ok()?);
    opens(file, &key[..]).then_some(key)
}

/// The files a re-key may move onto a key it chose: the live pair always; the
/// set-aside pair unless its master is a password file, whose key only its password
/// gives: that one moves only when a login key opens it and `secret` is its password
/// (its new salt is then the live master's, so the same password still opens it).
/// Also answers the key `secret` derived for it.
fn movable(set: &Set, logins: &[Key], secret: Option<&str>) -> (Vec<&'static str>, Option<Key>) {
    let mut locked_key = None;
    let locked_moves = match set.get(LOCKED[0]) {
        Some(m) if has_password(m) => {
            let exposed = logins.iter().any(|k| opens(m, &k[..]));
            locked_key = secret.filter(|_| exposed).and_then(|s| password_key(s, m));
            locked_key.is_some()
        }
        Some(_) => true,
        None => set.get(LOCKED[1]).is_some_and(|d| !has_password(d)),
    };
    let names = FILES.iter().copied().filter(|n| set.get(n).is_some() && (locked_moves || !LOCKED.contains(n))).collect();
    (names, locked_key)
}

/// Whether a login key opens a file a re-key could move.
fn exposed(set: &Set, logins: &[Key], names: &[&str]) -> bool {
    logins.iter().any(|k| names.iter().any(|n| set.get(n).is_some_and(|b| opens(b, &k[..]))))
}

/// One file a run moves: what it holds and how it is sealed now.
struct Move {
    name: &'static str,
    before: Vec<u8>,
    plain: Zeroizing<Vec<u8>>,
    flags: u8,
    salt: [u8; 16],
}

/// What a run moves (every movable file `on` does not open yet, each opened with the
/// stored, login or password key that opens it now) and the keys it replaces. An
/// error when a file of the live pair opens with no key we hold.
struct Plan {
    moves: Vec<Move>,
    retired: Vec<Key>,
}

fn plan(dir: &Path, set: &Set, logins: &[Key], secret: Option<&str>, on: Option<&[u8; 32]>) -> Result<Plan, String> {
    let (names, locked_key) = movable(set, logins, secret);
    let mut out = Plan { moves: Vec::new(), retired: Vec::new() };
    for name in names {
        let Some(bytes) = set.get(name) else { continue };
        if on.is_some_and(|k| opens(bytes, k)) {
            continue;
        }
        let key = key_of(dir, bytes)
            .or_else(|| logins.iter().find(|k| opens(bytes, &k[..])).cloned())
            .or_else(|| locked_key.clone().filter(|k| opens(bytes, &k[..])));
        let Some(key) = key else {
            if name == KEY_FILE || name == DEVICE_FILE {
                return Err(format!("{name} opens with no stored key"));
            }
            // A set-aside file no key of ours opens: no login item exposes it.
            continue;
        };
        let Some((flags, salt)) = header(bytes) else { continue };
        let plain = Zeroizing::new(encryption::decrypt_identity(bytes, &key)?);
        if !out.retired.iter().any(|r| same(&r[..], &key[..])) {
            out.retired.push(key);
        }
        out.moves.push(Move { name, before: bytes.to_vec(), plain, flags, salt });
    }
    Ok(out)
}

fn lands_as(path: &Path, key: &[u8; 32], plain: &[u8]) -> bool {
    std::fs::read(path)
        .ok()
        .and_then(|b| encryption::decrypt_identity(&b, key).ok())
        .is_some_and(|p| same(&p, plain))
}

/// `plain` sealed under `key` with `flags` and `salt`, proven to open.
fn seal(plain: &[u8], key: &[u8; 32], flags: u8, salt: &[u8; 16]) -> Result<Vec<u8>, String> {
    let sealed = encryption::encrypt_with_flags(plain, key, salt, flags)?;
    if !encryption::decrypt_identity(&sealed, key).is_ok_and(|p| same(&p, plain)) {
        return Err("a sealed file did not open to what was sealed".into());
    }
    Ok(sealed)
}

/// Re-keys the identity in `dir` off every key a login item holds, or finishes a
/// re-key or re-salt a start or an unlock before began. macOS only. Reads nothing
/// that can ask the person: it runs before any window.
pub(crate) fn settle(dir: &Path) -> Rekey {
    if !platform_keystore::has_login_keychain() {
        return Rekey::Nothing;
    }
    platform_keystore::without_prompts(|| settle_quietly(dir))
}

fn settle_quietly(dir: &Path) -> Rekey {
    let set = Set::read(dir);
    let Some(master) = set.get(KEY_FILE) else { return Rekey::Nothing };
    let password = match flags_of(master) {
        Some(KEYCHAIN_ONLY) => false,
        Some(PASSWORD_CACHED) => true,
        _ => return Rekey::Nothing,
    };
    let logins = platform_keystore::login_keys(dir);
    let (names, _) = movable(&set, &logins, None);
    let exposed = exposed(&set, &logins, &names);
    let staged = platform_keystore::staged_key(dir, &|k| set.opened_by(k));
    if let Some(new_key) = staged.as_ref().filter(|s| set.opened_by(&s[..])) {
        // A password key opens only under the salt it was derived with, which only
        // `identity.key` carries: a re-salt cut before that file took it waits for
        // the password again.
        if password && !opens(master, &new_key[..]) {
            return Rekey::Failed("a re-salt stopped before identity.key took its key".into());
        }
        let plan = match plan(dir, &set, &logins, None, Some(new_key)) {
            Ok(plan) => plan,
            Err(e) => return Rekey::Failed(e),
        };
        return run(dir, plan, new_key.clone(), None, exposed);
    }
    if staged.is_some() {
        platform_keystore::unstage(dir, &|v| set.opened_by(v));
    }
    if !exposed {
        return Rekey::Nothing;
    }
    if password {
        return Rekey::PasswordKey;
    }
    let plan = match plan(dir, &set, &logins, None, None) {
        Ok(plan) => plan,
        Err(e) => return Rekey::Failed(e),
    };
    let mut fresh = Zeroizing::new([0u8; 32]);
    if let Err(e) = getrandom::fill(&mut fresh[..]) {
        return Rekey::Failed(format!("RNG error: {e}"));
    }
    match platform_keystore::stage_key(dir, &fresh) {
        Ok(back) => run(dir, plan, back, None, exposed),
        Err(e) => Rekey::Failed(e),
    }
}

/// A typed unlock of a password identity whose key the keychain caches (`0x03`):
/// moves it off every key a login item holds onto one `secret` derives under a fresh
/// salt, or finishes such a move. `secret` must be the one that just opened
/// `identity.key`. Answers what happened and, when `identity.key` now opens with a
/// new key, that key for the session.
pub(crate) fn resalt(dir: &Path, secret: &str) -> (Rekey, Option<Key>) {
    if !platform_keystore::has_login_keychain() {
        return (Rekey::Nothing, None);
    }
    platform_keystore::without_prompts(|| {
        let set = Set::read(dir);
        let Some(master) = set.get(KEY_FILE).filter(|m| flags_of(m) == Some(PASSWORD_CACHED)) else {
            return (Rekey::Nothing, None);
        };
        let logins = platform_keystore::login_keys(dir);
        let (names, _) = movable(&set, &logins, Some(secret));
        let exposed = exposed(&set, &logins, &names);
        let staged = platform_keystore::staged_key(dir, &|k| set.opened_by(k));
        let (new_key, salt, plan) = match staged.as_ref().filter(|s| opens(master, &s[..])).cloned() {
            Some(staged) => match plan(dir, &set, &logins, Some(secret), Some(&staged)) {
                Ok(plan) => {
                    let salt = header(master).map(|(_, s)| s);
                    (staged, salt, plan)
                }
                Err(e) => return (Rekey::Failed(e), None),
            },
            None => {
                if staged.is_some() {
                    platform_keystore::unstage(dir, &|v| set.opened_by(v));
                }
                if !exposed {
                    return (Rekey::Nothing, None);
                }
                let plan = match plan(dir, &set, &logins, Some(secret), None) {
                    Ok(plan) => plan,
                    Err(e) => return (Rekey::Failed(e), None),
                };
                let mut salt = [0u8; 16];
                if let Err(e) = getrandom::fill(&mut salt) {
                    return (Rekey::Failed(format!("RNG error: {e}")), None);
                }
                let fresh = match encryption::derive_wrapping_key_from_password(secret, &salt) {
                    Ok(k) => Zeroizing::new(k),
                    Err(e) => return (Rekey::Failed(e), None),
                };
                match platform_keystore::stage_key(dir, &fresh) {
                    Ok(back) if same(&back[..], &fresh[..]) => (fresh, Some(salt), plan),
                    Ok(_) => return (Rekey::Failed("another key is staged".into()), None),
                    Err(e) => return (Rekey::Failed(e), None),
                }
            }
        };
        let outcome = run(dir, plan, new_key.clone(), salt, exposed);
        let now = std::fs::read(dir.join(KEY_FILE)).ok().filter(|b| opens(b, &new_key[..])).map(|_| new_key);
        (outcome, now)
    })
}

/// Whether a password identity's cached key still sits in a login item that only
/// the password can make inert (what `settle` answers with `PasswordKey`). Reads
/// nothing that can ask.
pub(crate) fn wants_password(dir: &Path) -> bool {
    if !platform_keystore::has_login_keychain() {
        return false;
    }
    platform_keystore::without_prompts(|| {
        let set = Set::read(dir);
        if set.get(KEY_FILE).and_then(flags_of) != Some(PASSWORD_CACHED) {
            return false;
        }
        let logins = platform_keystore::login_keys(dir);
        let (names, _) = movable(&set, &logins, None);
        exposed(&set, &logins, &names)
    })
}

/// Moves every file in `plan` onto `new_key` (staged and read back already), then
/// promotes it, unstages it and retires the keys it replaced. `master_salt` is the
/// fresh salt a password `new_key` was derived under: a password master file takes
/// it, so the password opens the file under the new key.
fn run(dir: &Path, plan: Plan, new_key: Key, master_salt: Option<[u8; 16]>, exposed: bool) -> Rekey {
    use platform_keystore::Step;
    let slot = "rekey";
    if !platform_keystore::step(Step::RekeyStaged, slot) {
        return Rekey::Died;
    }
    // Drops the staged key while no file needs it, so an abort leaves none behind.
    let abandon = |why: String| {
        let now = Set::read(dir);
        platform_keystore::unstage(dir, &|v| now.opened_by(v));
        Rekey::Failed(why)
    };

    // Each file in order; a failure puts back every file this run wrote.
    let mut written: Vec<&Move> = Vec::new();
    for at in [Step::RekeyKeyFile, Step::RekeyDeviceFile, Step::RekeyLockedFiles] {
        let these = |m: &&Move| match at {
            Step::RekeyKeyFile => m.name == KEY_FILE,
            Step::RekeyDeviceFile => m.name == DEVICE_FILE,
            _ => LOCKED.contains(&m.name),
        };
        for m in plan.moves.iter().filter(these) {
            let path = dir.join(m.name);
            let salt = match master_salt {
                Some(fresh) if encryption::flags_has_password(m.flags) && (m.name == KEY_FILE || m.name == LOCKED[0]) => fresh,
                _ => m.salt,
            };
            let landed = seal(&m.plain, &new_key, m.flags, &salt)
                .and_then(|sealed| encryption::write_key_file(&path, &sealed))
                .and_then(|()| {
                    if lands_as(&path, &new_key, &m.plain) { Ok(()) } else { Err(format!("{} did not read back", m.name)) }
                });
            if let Err(e) = landed {
                for back in written.iter().rev() {
                    let _ = encryption::write_key_file(&dir.join(back.name), &back.before);
                }
                return abandon(e);
            }
            written.push(m);
        }
        if !platform_keystore::step(at, slot) {
            return Rekey::Died;
        }
    }

    let promoted = platform_keystore::store_key_at(dir, &new_key[..]).and_then(|()| {
        match platform_keystore::read_profile_key_at(dir)?.map(Zeroizing::new) {
            Some(back) if same(&back, &new_key[..]) => Ok(()),
            _ => Err("the profile slot did not read back".into()),
        }
    });
    if let Err(e) = promoted {
        // The files open with the staged key: the unlock reads it, the next start promotes it.
        return Rekey::Failed(e);
    }
    if !platform_keystore::step(Step::RekeyPromoted, slot) {
        return Rekey::Died;
    }
    let after = Set::read(dir);
    platform_keystore::unstage(dir, &|v| !same(v, &new_key[..]) && after.opened_by(v));
    if !platform_keystore::step(Step::RekeyUnstaged, slot) {
        return Rekey::Died;
    }
    let stay = platform_keystore::retire(dir, &plan.retired, &|v| after.opened_by(v));
    if exposed { Rekey::Rekeyed { stay } } else { Rekey::Finished }
}

/// Unlock: a device file a cut re-key left on another stored key is re-wrapped under
/// `key` (the one that opened `identity.key`), so the pair opens together again. Runs
/// for every keychain-flagged identity, with or without a password, on every platform
/// (only the macOS re-key splits a pair, so elsewhere it finds the pair whole and
/// stops). `may_ask`: the unlock read no login item, so this one search may.
pub(crate) fn heal_device_file(dir: &Path, key: &[u8; 32], may_ask: bool) {
    let path = dir.join(DEVICE_FILE);
    let Ok(device) = std::fs::read(&path) else { return };
    let Some((flags, salt)) = header(&device) else { return };
    if !encryption::flags_has_os_keychain(flags) || opens(&device, key) {
        return;
    }
    let old = platform_keystore::without_prompts(|| key_of(dir, &device))
        .or_else(|| may_ask.then(|| key_of(dir, &device)).flatten());
    let Some(old) = old else {
        crate::hollow_log!("[HOLLOW-ID] The device key opens with no stored key this unlock could read");
        return;
    };
    let healed = encryption::decrypt_identity(&device, &old).map(Zeroizing::new).and_then(|plain| {
        let sealed = seal(&plain, key, flags, &salt)?;
        encryption::write_key_file(&path, &sealed)?;
        if lands_as(&path, key, &plain) { Ok(()) } else { Err("identity.device did not read back".into()) }
    });
    match healed {
        Ok(()) => crate::hollow_log!("[HOLLOW-ID] The device key joined the identity's keychain key again"),
        Err(e) => crate::hollow_log!("[HOLLOW-ID] The device key stays on its other keychain key for now: {e}"),
    }
}

#[cfg(test)]
mod tests;
