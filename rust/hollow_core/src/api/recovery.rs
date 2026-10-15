//! A device whose database will not open with its identity: repair it in place, or set
//! its whole data set aside as a kept profile and link it again. Nothing here deletes
//! user data; what is set aside goes only with a destroy of the profile it came from.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use flutter_rust_bridge::frb;

use super::storage::IDENTITY_NOT_READY;

/// Why the database did not open, as far as a read-only probe can tell.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StoreTrouble {
    /// A wipe, a landing, a link import or a relink is unfinished. ONE class for all of
    /// them: a held boot wipe must read exactly like a held landing.
    NotReady,
    /// Another program holds the file.
    Held,
    /// The file is there and does not open with this identity.
    Unreadable,
    /// Anything else, a database that opens included.
    Other,
}

/// What a repair did.
pub struct RepairOutcome {
    /// The folder under the data root that holds what was set aside.
    pub folder: String,
    /// A kept copy opened with this identity and was put back in place of a new one.
    pub restored: bool,
}

pub(crate) const HELD: &str = "Another program is using Hollow's files. Close it and try again.";
pub(crate) const KEY_NOT_KEPT: &str = "Hollow couldn't save the key for your old data, so nothing moved. Try again.";

/// The database and what SQLite keeps beside it, as `storage::set_database_aside` moves it.
const DB_SET: [&str; 4] = ["messages.db", "messages.db-wal", "messages.db-shm", "messages.db-journal"];
const ASIDE_PREFIX: &str = "unreadable-";
/// A start-up sets a database the identity cannot open aside in the root under this
/// name, `-<time>` added.
const SET_ASIDE_FILE: &str = "messages.db.unreadable-";
const RELINK_JOURNAL: &str = "relink.json";
const RELINK_ORIGIN: &str = "relink_origin.json";
const RELINK_WELCOME: &str = "relink_welcome";
const WIPE_MARKER: &str = "pending_wipe.marker";
/// Device-level files: the logs say what happened to this device, whatever it holds.
const LOGS: [&str; 4] = ["hollow_debug.log", "hollow_crash.log", "hollow_crash.log.old", "push_debug.log"];

fn present(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok()
}

fn is_key_file(name: &str) -> bool {
    name.starts_with("identity.")
}

/// Root entries a relink leaves behind: the registry, instance locks, the logs, what a
/// destroy of this root must still find (`recordings.list`, push hints), and its own marks.
/// A root that is itself old data keeps the mark naming its origin: moved, the next
/// folder would name the wrong root and neither would go with a destroy.
fn stays_on_relink(name: &str) -> bool {
    name == "profiles.json"
        || name.ends_with(".lock")
        || LOGS.contains(&name)
        || name == "recordings.list"
        || name == "push_lines.json"
        || name == RELINK_JOURNAL
        || name == RELINK_WELCOME
        || name == RELINK_ORIGIN
        || name == WIPE_MARKER
}

/// Root entries a repair leaves in place: everything a relink leaves, the identity and
/// what belongs to it rather than to the database, and earlier repairs' folders.
fn stays_on_repair(name: &str) -> bool {
    stays_on_relink(name)
        || is_key_file(name)
        || name.starts_with("pending_link.")
        || name == crate::node::roster_book::BOOTSTRAP_FILE
        || name.starts_with(ASIDE_PREFIX)
        || name.starts_with(SET_ASIDE_FILE)
        || [".landing", ".replaced", ".landed", ".key_landing", crate::node::destroy::REPAIR_LINK_HINT].contains(&name)
}

/// An unfinished step another part of start-up owns, during which nothing here runs.
fn not_ready(root: &Path) -> bool {
    [WIPE_MARKER, ".landing", ".landed", ".key_landing", "pending_link.hollow", RELINK_JOURNAL]
        .iter()
        .any(|name| present(&root.join(name)))
        || !root.join("identity.key").exists()
        || super::storage::landing_in_progress()
}

/// While a relink is moving the identity out, a missing `identity.key` is no reason to
/// mint one: it would sit beside what has not moved yet.
pub(crate) fn relink_in_progress() -> bool {
    crate::identity::data_dir().is_ok_and(|root| present(&root.join(RELINK_JOURNAL)))
}

// -- Probing --

#[derive(Debug, PartialEq, Eq)]
enum Probe {
    Opens,
    Unreadable,
    Held,
}

/// Opens `db` without creating or changing it and reads its schema with `passphrase`.
fn probe(db: &Path, passphrase: &str, read_only: bool) -> Probe {
    use rusqlite::{ErrorCode, OpenFlags};
    if let Err(e) = std::fs::File::open(db) {
        return if e.kind() == std::io::ErrorKind::NotFound { Probe::Unreadable } else { Probe::Held };
    }
    let classify = |e: rusqlite::Error| match e.sqlite_error_code() {
        Some(ErrorCode::NotADatabase | ErrorCode::DatabaseCorrupt) => Probe::Unreadable,
        Some(_) => Probe::Held,
        None => Probe::Unreadable,
    };
    let opened = if read_only {
        open_kept(db)
    } else {
        rusqlite::Connection::open_with_flags(db, OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX)
    };
    let conn = match opened {
        Ok(c) => c,
        Err(e) => return classify(e),
    };
    if let Err(e) = conn.execute_batch(&format!("PRAGMA key = \"x'{passphrase}'\";")) {
        return classify(e);
    }
    match conn.query_row("SELECT count(*) FROM sqlite_master", [], |r| r.get::<_, i64>(0)) {
        Ok(_) => Probe::Opens,
        Err(e) => classify(e),
    }
}

/// A read-only URI for a kept copy. Without a WAL beside it the copy is opened as
/// immutable, since a read-only connection to a WAL database cannot make its
/// shared-memory file. Never with a rollback journal beside it: an immutable read
/// skips a hot journal and reads a half-written copy, where a read-only one refuses it
/// and the copy is passed over.
fn kept_uri(db: &Path) -> String {
    let beside = |suffix: &str| {
        let mut name = db.as_os_str().to_owned();
        name.push(suffix);
        present(Path::new(&name))
    };
    let mode = if beside("-wal") || beside("-journal") { "mode=ro" } else { "mode=ro&immutable=1" };
    let mut path = db.to_string_lossy().replace('\\', "/");
    if !path.starts_with('/') {
        path.insert(0, '/');
    }
    let path: String = path
        .chars()
        .map(|c| match c {
            '%' => "%25".to_string(),
            '?' => "%3f".to_string(),
            '#' => "%23".to_string(),
            ' ' => "%20".to_string(),
            '\'' => "%27".to_string(),
            c => c.to_string(),
        })
        .collect();
    format!("file://{path}?{mode}")
}

fn open_kept(db: &Path) -> rusqlite::Result<rusqlite::Connection> {
    use rusqlite::OpenFlags;
    rusqlite::Connection::open_with_flags(
        kept_uri(db),
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX | OpenFlags::SQLITE_OPEN_URI,
    )
}

/// The identity on disk, never a new one, and its database passphrase.
fn loaded_identity() -> Result<(String, String), String> {
    let id = crate::identity::load_existing_identity()?.ok_or_else(|| IDENTITY_NOT_READY.to_string())?;
    let proto = id
        .keypair
        .to_protobuf_encoding()
        .map_err(|e| format!("Failed to encode keypair: {e}"))?;
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);
    Ok((id.device_peer_id, passphrase))
}

/// What is wrong with this profile's database. Read-only: nothing on disk changes.
#[frb]
pub fn store_trouble() -> Result<StoreTrouble, String> {
    let root = crate::identity::data_dir()?;
    if not_ready(&root) {
        return Ok(StoreTrouble::NotReady);
    }
    let db = root.join("messages.db");
    if !present(&db) {
        return Ok(StoreTrouble::Other);
    }
    let Ok((_, passphrase)) = loaded_identity() else { return Ok(StoreTrouble::Other) };
    Ok(trouble_of(&db, &passphrase))
}

fn trouble_of(db: &Path, passphrase: &str) -> StoreTrouble {
    match probe(db, passphrase, false) {
        Probe::Opens => StoreTrouble::Other,
        Probe::Unreadable => StoreTrouble::Unreadable,
        Probe::Held => StoreTrouble::Held,
    }
}

// -- Dates and names --

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

/// `YYYY-MM-DD` (UTC) of a unix time in milliseconds.
pub(crate) fn day_of(ms: i64) -> String {
    let days = ms.div_euclid(86_400_000);
    // Civil date from a day count (H. Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}")
}

/// `{base}`, or `{base}-2`, `{base}-3`... whichever `dir` does not hold yet.
fn unique_in(dir: &Path, base: &str) -> PathBuf {
    let first = dir.join(base);
    if !present(&first) {
        return first;
    }
    (2..)
        .map(|n| dir.join(format!("{base}-{n}")))
        .find(|p| !present(p))
        .unwrap_or(first)
}

// -- Moving --

#[cfg(test)]
thread_local! {
    /// Forward moves fail from this index on; with `true` every move back fails too.
    static MOVE_FAULT: std::cell::Cell<(usize, bool)> = const { std::cell::Cell::new((usize::MAX, false)) };
    /// A repair stops dead right after its move, as a killed process would.
    static REPAIR_CRASH: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

fn write_synced(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let mut file = std::fs::File::create(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

/// One rename: the `index`th of a move, or a move back (`None`).
#[cfg_attr(not(test), allow(unused_variables))]
fn move_one(from: &Path, to: &Path, index: Option<usize>) -> std::io::Result<()> {
    #[cfg(test)]
    {
        let (from_index, back) = MOVE_FAULT.with(std::cell::Cell::get);
        if index.map_or(back, |i| i >= from_index) {
            return Err(std::io::Error::other("injected"));
        }
    }
    std::fs::rename(from, to)
}

/// A move that stopped partway; `stranded` when some of what had moved would not go back.
struct MoveFailed {
    stranded: bool,
}

/// Renames each of `names` from `from` into `to`, in order. On the first failure what
/// already moved goes back, newest first.
fn move_all(from: &Path, to: &Path, names: &[String]) -> Result<(), MoveFailed> {
    let mut moved: Vec<&String> = Vec::new();
    for (i, name) in names.iter().enumerate() {
        if let Err(e) = move_one(&from.join(name), &to.join(name), Some(i)) {
            hollow_log!("[HOLLOW-REPAIR] {name} would not move: {e}");
            let stranded = moved
                .iter()
                .rev()
                .fold(false, |stranded, back| move_one(&to.join(back), &from.join(back), None).is_err() || stranded);
            return Err(MoveFailed { stranded });
        }
        moved.push(name);
    }
    Ok(())
}

/// The database set first: it is the file another program may hold, and nothing else
/// has moved when it refuses. Then the rest by name, then whatever `last` picks.
fn ordered(root: &Path, moves: impl Fn(&str) -> bool, last: impl Fn(&str) -> bool) -> Result<Vec<String>, String> {
    let mut rest: Vec<String> = std::fs::read_dir(root)
        .map_err(|e| format!("Failed to read the data folder: {e}"))?
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| !DB_SET.contains(&n.as_str()) && moves(n))
        .collect();
    rest.sort();
    let (tail, mid): (Vec<String>, Vec<String>) = rest.into_iter().partition(|n| last(n));
    let mut tail = tail;
    // identity.key last of all: while it is in the root the identity is.
    tail.sort_by_key(|n| (n == "identity.key", n.clone()));
    Ok(DB_SET
        .iter()
        .filter(|n| present(&root.join(n)))
        .map(|n| n.to_string())
        .chain(mid)
        .chain(tail)
        .collect())
}

// -- Repair --

/// The earliest time the identity files show: never later than the device's link, so
/// an order to destroy it from before a repair still counts.
fn link_time_estimate(root: &Path) -> i64 {
    ["identity.device", "identity.key"]
        .iter()
        .filter_map(|name| std::fs::metadata(root.join(name)).ok())
        .flat_map(|m| [m.created().ok(), m.modified().ok()])
        .flatten()
        .filter_map(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as i64)
        .min()
        .unwrap_or_else(now_ms)
}

/// Copies of a database this identity might open: one a landing could not clean up,
/// then what earlier repairs and start-ups set aside, newest first. Read, never changed.
fn candidates(root: &Path, skip: &Path) -> Vec<PathBuf> {
    let mut kept: Vec<(std::time::SystemTime, PathBuf)> = std::fs::read_dir(root)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            let db = if name.starts_with(ASIDE_PREFIX) && e.path() != skip {
                e.path().join("messages.db")
            } else if name.starts_with(SET_ASIDE_FILE) && !["-wal", "-shm", "-journal"].iter().any(|part| name.ends_with(part)) {
                e.path()
            } else {
                return None;
            };
            let changed = std::fs::metadata(&db).and_then(|m| m.modified()).ok()?;
            db.is_file().then_some((changed, db))
        })
        .collect();
    kept.sort_by(|a, b| b.0.cmp(&a.0));
    std::iter::once(root.join(".replaced").join("messages.db"))
        .filter(|db| db.is_file())
        .chain(kept.into_iter().map(|(_, db)| db))
        .collect()
}

/// Writes the readable copy at `from` into a new database at `to`, leaving `from` as it is.
fn export_copy(from: &Path, to: &Path, passphrase: &str) -> Result<(), String> {
    let conn = rusqlite::Connection::open(to).map_err(|e| format!("copy open: {e}"))?;
    let source = kept_uri(from);
    conn.execute_batch(&format!(
        "PRAGMA key = \"x'{passphrase}'\"; ATTACH DATABASE '{source}' AS kept KEY \"x'{passphrase}'\"; \
         SELECT sqlcipher_export('main', 'kept'); DETACH DATABASE kept;"
    ))
    .map_err(|e| format!("copy export: {e}"))
}

/// Sets the unreadable database aside in a new `unreadable-<day>` folder and puts a
/// database this identity opens in its place: a kept copy when one opens, else a new one.
/// Refuses, moving nothing, while another start-up step is unfinished or a file is held.
pub(crate) fn repair_at(root: &Path, passphrase: &str, device: &str, now: i64) -> Result<RepairOutcome, String> {
    if not_ready(root) {
        return Err(IDENTITY_NOT_READY.to_string());
    }
    let db = root.join("messages.db");
    match probe(&db, passphrase, false) {
        Probe::Unreadable if present(&db) => {}
        Probe::Held => return Err(HELD.to_string()),
        _ => return Err("There is nothing to repair. Restart Hollow.".to_string()),
    }
    let folder = unique_in(root, &format!("{ASIDE_PREFIX}{}", day_of(now)));
    let copy = candidates(root, &folder).into_iter().find(|c| probe(c, passphrase, true) == Probe::Opens);
    // With a copy back in place, the at-rest folders stay: their keys may be in it.
    let names = if copy.is_some() {
        DB_SET.iter().filter(|n| present(&root.join(n))).map(|n| n.to_string()).collect()
    } else {
        ordered(root, |n| !stays_on_repair(n), |_| false)?
    };
    std::fs::create_dir(&folder).map_err(|e| format!("Failed to make the repair folder: {e}"))?;
    // A crash between the move and the stamp leaves a new database the next start
    // would stamp with its own time, refusing a destroy order issued since the link.
    let hint = root.join(crate::node::destroy::REPAIR_LINK_HINT);
    let link_time = link_time_estimate(root);
    write_synced(&hint, link_time.to_string().as_bytes()).map_err(|e| format!("Failed to start the repair: {e}"))?;
    if let Err(failed) = move_all(root, &folder, &names) {
        let _ = std::fs::remove_file(&hint);
        if failed.stranded {
            hollow_log!("[HOLLOW-REPAIR] Some entries stayed in the repair folder");
        } else {
            let _ = std::fs::remove_dir(&folder);
        }
        return Err(HELD.to_string());
    }
    #[cfg(test)]
    if REPAIR_CRASH.with(std::cell::Cell::get) {
        return Err("injected: the process died".into());
    }
    let restored = copy.as_ref().is_some_and(|c| match export_copy(c, &db, passphrase) {
        Ok(()) => true,
        Err(e) => {
            hollow_log!("[HOLLOW-REPAIR] A kept copy opened but did not copy: {e}");
            let _ = std::fs::remove_file(&db);
            false
        }
    });
    let store = crate::storage::MessageStore::open(db.to_str().ok_or("Invalid path encoding")?, passphrase)?;
    if !restored {
        let key = crate::node::destroy::link_key(device);
        store.save_setting(&key, &link_time.to_string())?;
    }
    drop(store);
    let _ = std::fs::remove_file(&hint);
    let name = folder.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    hollow_log!(
        "[HOLLOW-REPAIR] Set {} entr(ies) aside in {name}; {}",
        names.len(),
        if restored { "a kept copy opened and is back in place" } else { "a new database is in place" }
    );
    Ok(RepairOutcome { folder: name, restored })
}

/// Repair this device: keep the identity, set the database that will not open aside,
/// and open one that does. Before the node starts, after `unlock_identity()`.
#[frb]
pub fn repair_this_device() -> Result<RepairOutcome, String> {
    let root = crate::identity::data_dir()?;
    crate::log::init();
    if super::storage::get_store().lock().map_err(|e| format!("Lock poisoned: {e}"))?.is_some() {
        return Err("There is nothing to repair. Restart Hollow.".to_string());
    }
    let (device, passphrase) = loaded_identity()?;
    repair_at(&root, &passphrase, &device, now_ms())
}

// -- Link again --

#[derive(serde::Serialize, serde::Deserialize)]
struct Journal {
    target: String,
}

#[derive(serde::Serialize, serde::Deserialize)]
struct Origin {
    root: String,
}

/// Paths compared the way the profile registry compares them.
fn same_path(a: &str, b: &str) -> bool {
    let norm = |p: &str| {
        let mut s = p.replace('\\', "/");
        while s.len() > 1 && s.ends_with('/') {
            s.pop();
        }
        if cfg!(windows) { s.to_lowercase() } else { s }
    };
    norm(a) == norm(b)
}

fn keychain_locked(identity: &[u8]) -> bool {
    use crate::identity::encryption::{detect_format, flags_has_os_keychain, IdentityFormat};
    matches!(detect_format(identity), Ok(IdentityFormat::Encrypted { flags, .. }) if flags_has_os_keychain(flags))
}

/// The key a keychain-locked identity file at `root` opens with, read BEFORE it moves:
/// the per-profile slot is named after the folder. Refuses when no stored key opens it.
fn keychain_key(root: &Path) -> Result<Option<[u8; 32]>, String> {
    let Ok(bytes) = std::fs::read(root.join("identity.key")) else { return Ok(None) };
    if !keychain_locked(&bytes) {
        return Ok(None);
    }
    crate::identity::platform_keystore::key_that_opens(root, &bytes)
        .map(|(_, key)| Some(key))
        .ok_or_else(|| KEY_NOT_KEPT.to_string())
}

#[cfg(test)]
thread_local! {
    /// Whether the folder carried its origin mark when its slot was last written.
    static MARK_SEEN_BEFORE_KEY: std::cell::Cell<Option<bool>> = const { std::cell::Cell::new(None) };
}

/// Stores `key` in `dir`'s own slot and reads it back.
fn keep_key_at(dir: &Path, key: &[u8; 32]) -> Result<(), String> {
    use crate::identity::platform_keystore::{read_profile_key_at, store_key_at};
    #[cfg(test)]
    MARK_SEEN_BEFORE_KEY.with(|seen| seen.set(Some(present(&dir.join(RELINK_ORIGIN)))));
    store_key_at(dir, key)?;
    match read_profile_key_at(dir)? {
        Some(read) if read == key[..] => Ok(()),
        _ => Err("the keystore did not keep the key".into()),
    }
}

/// The kept identity at `target` opens with its own slot, the key copied there from
/// any slot that opens it. False only when such a key would not store.
fn kept_key_in_place(root: &Path, target: &Path) -> bool {
    use crate::identity::platform_keystore::{key_that_opens, read_profile_key_at};
    let Ok(bytes) = std::fs::read(target.join("identity.key")) else { return true };
    if !keychain_locked(&bytes) {
        return true;
    }
    let opens = |key: &[u8]| {
        <[u8; 32]>::try_from(key).is_ok_and(|k| crate::identity::encryption::decrypt_identity(&bytes, &k).is_ok())
    };
    if read_profile_key_at(target).ok().flatten().is_some_and(|k| opens(&k)) {
        return true;
    }
    match key_that_opens(root, &bytes).or_else(|| key_that_opens(target, &bytes)) {
        Some((_, key)) => keep_key_at(target, &key).is_ok(),
        // No stored key opens it: holding the relink open would save nothing.
        None => true,
    }
}

/// Moves everything this root holds for its identity into a new sibling folder
/// `<root>-old-<day>`, marked with where it came from, the database first and the
/// identity last. Returns that folder. A failure moves everything back.
pub(crate) fn relink_at(root: &Path, now: i64) -> Result<PathBuf, String> {
    if not_ready(root) {
        return Err(IDENTITY_NOT_READY.to_string());
    }
    let parent = root.parent().ok_or("The data folder has no parent folder")?;
    let base = root.file_name().ok_or("The data folder has no name")?.to_string_lossy().into_owned();
    let target = unique_in(parent, &format!("{base}-old-{}", day_of(now)));
    let key = keychain_key(root)?;
    let names = ordered(root, |n| !stays_on_relink(n), is_key_file)?;

    std::fs::create_dir(&target).map_err(|e| format!("Failed to make the folder for the old data: {e}"))?;
    let origin = serde_json::to_vec(&Origin { root: root.to_string_lossy().into_owned() }).map_err(|e| e.to_string())?;
    let journal = serde_json::to_vec(&Journal { target: target.to_string_lossy().into_owned() }).map_err(|e| e.to_string())?;
    let undo = |target: &Path| {
        crate::identity::platform_keystore::forget_key_proven(target, false);
        let _ = std::fs::remove_file(target.join(RELINK_ORIGIN));
        let _ = std::fs::remove_dir(target);
        let _ = std::fs::remove_file(root.join(RELINK_JOURNAL));
    };
    // The mark and the journal come first: a crash after them is settled at the next
    // start, the kept slot with it, and a destroy finds the folder by its mark.
    if let Err(e) = std::fs::write(target.join(RELINK_ORIGIN), origin)
        .and_then(|_| std::fs::write(root.join(RELINK_JOURNAL), journal))
    {
        undo(&target);
        return Err(format!("Failed to start moving the old data: {e}"));
    }
    // The kept identity's key goes to the kept folder's own slot before anything moves:
    // the root's slot belongs to whatever identity this profile gets next.
    if let Some(key) = key
        && let Err(e) = keep_key_at(&target, &key)
    {
        hollow_log!("[HOLLOW-REPAIR] The old data's keychain key did not keep: {e}");
        undo(&target);
        return Err(KEY_NOT_KEPT.to_string());
    }
    if let Err(failed) = move_all(root, &target, &names) {
        // What would not go back stays under the journal and the origin mark, so a
        // settle (now, and at every start until it finishes) puts it back.
        if failed.stranded {
            settle_relink_at(root);
        } else {
            undo(&target);
        }
        return Err(HELD.to_string());
    }
    let _ = std::fs::write(root.join(RELINK_WELCOME), target.to_string_lossy().as_bytes());
    // The commit point: from here a start-up sees a finished relink.
    let _ = std::fs::remove_file(root.join(RELINK_JOURNAL));
    hollow_log!("[HOLLOW-REPAIR] Moved {} entr(ies) aside to link this device again", names.len());
    Ok(target)
}

/// Link this device again: the whole data set moves to a kept folder beside this one,
/// and this profile starts at Welcome. Returns the kept folder's path.
#[frb]
pub fn relink_this_device() -> Result<String, String> {
    let root = crate::identity::data_dir()?;
    crate::log::init();
    if super::storage::get_store().lock().map_err(|e| format!("Lock poisoned: {e}"))?.is_some() {
        return Err(IDENTITY_NOT_READY.to_string());
    }
    relink_at(&root, now_ms()).map(|p| p.to_string_lossy().into_owned())
}

/// A relink a crash or a held file cut short: finished once the identity had moved,
/// else undone. The journal, and with it the refusal to mint or open anything here,
/// stays while a step is left for a later start.
pub(crate) fn settle_relink_at(root: &Path) {
    let Ok(bytes) = std::fs::read(root.join(RELINK_JOURNAL)) else { return };
    let Ok(journal) = serde_json::from_slice::<Journal>(&bytes) else {
        let _ = std::fs::remove_file(root.join(RELINK_JOURNAL));
        return;
    };
    let target = PathBuf::from(&journal.target);
    if !root.join("identity.key").exists() && target.join("identity.key").exists() {
        if !kept_key_in_place(root, &target) {
            hollow_log!("[HOLLOW-REPAIR] The old data's keychain key did not keep; the relink finishes at a later start");
            return;
        }
        if !present(&root.join(RELINK_WELCOME)) {
            let _ = std::fs::write(root.join(RELINK_WELCOME), journal.target.as_bytes());
        }
        hollow_log!("[HOLLOW-REPAIR] Finished a relink a restart cut short");
    } else {
        let mut stranded = false;
        let mut doubled = false;
        for entry in std::fs::read_dir(&target).into_iter().flatten().flatten() {
            let name = entry.file_name();
            if name == RELINK_ORIGIN {
                continue;
            }
            if present(&root.join(&name)) {
                // The blob copy of a key the identity still in the root opens with.
                if name == "identity.dpapi" {
                    super::wipe::zero_and_remove(&entry.path());
                } else {
                    doubled = true;
                }
                continue;
            }
            stranded |= move_one(&entry.path(), &root.join(&name), None).is_err();
        }
        if stranded {
            hollow_log!("[HOLLOW-REPAIR] A relink could not be undone yet; a later start tries again");
            return;
        }
        if doubled {
            // The root holds these names again: what is left stays marked as this
            // root's old data, which a destroy of the root erases.
            hollow_log!("[HOLLOW-REPAIR] Undid a relink; entries the root holds again stay aside");
        } else {
            crate::identity::platform_keystore::forget_key_proven(&target, false);
            let _ = std::fs::remove_file(target.join(RELINK_ORIGIN));
            let _ = std::fs::remove_dir(&target);
            hollow_log!("[HOLLOW-REPAIR] Undid a relink a restart cut short");
        }
    }
    let _ = std::fs::remove_file(root.join(RELINK_JOURNAL));
}

/// At launch, before anything reads the identity.
#[frb]
pub fn settle_relink() -> Result<(), String> {
    settle_relink_at(&crate::identity::data_dir()?);
    Ok(())
}

/// The kept folder of a relink this profile has not shown Welcome for yet.
#[frb]
pub fn relink_welcome() -> Result<Option<String>, String> {
    let root = crate::identity::data_dir()?;
    Ok(std::fs::read_to_string(root.join(RELINK_WELCOME)).ok().filter(|p| !p.is_empty()))
}

/// Welcome has been shown for the relink.
#[frb]
pub fn clear_relink_welcome() -> Result<(), String> {
    let root = crate::identity::data_dir()?;
    let _ = std::fs::remove_file(root.join(RELINK_WELCOME));
    Ok(())
}

/// Whether `name` is `{base}-old-YYYY-MM-DD` or that with `-<n>`.
fn is_kept_name(name: &str, base: &str) -> bool {
    let Some(rest) = name.strip_prefix(base).and_then(|r| r.strip_prefix("-old-")) else { return false };
    let (day, tail) = rest.split_at(rest.len().min(10));
    let digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    let day_ok = day.len() == 10
        && day.bytes().enumerate().all(|(i, b)| if i == 4 || i == 7 { b == b'-' } else { b.is_ascii_digit() });
    day_ok && (tail.is_empty() || tail.strip_prefix('-').is_some_and(digits))
}

fn same_folder(a: &Path, b: &Path) -> bool {
    match (a.canonicalize(), b.canonicalize()) {
        (Ok(x), Ok(y)) => x == y,
        _ => same_path(&a.to_string_lossy(), &b.to_string_lossy()),
    }
}

/// The byte a running Hollow locks in its `hollow.lock` (`SingleInstanceLock`).
#[cfg(unix)]
const INSTANCE_LOCK_BYTE: i64 = 1 << 30;

/// Another process holds the instance lock in `dir`. Never asked of this process's own
/// root: on POSIX closing any handle to a file drops the process's lock on it.
#[cfg(windows)]
fn instance_lock_held(dir: &Path) -> bool {
    const ERROR_SHARING_VIOLATION: i32 = 32;
    let file = match std::fs::OpenOptions::new().read(true).write(true).open(dir.join("hollow.lock")) {
        Ok(f) => f,
        Err(e) => return e.raw_os_error() == Some(ERROR_SHARING_VIOLATION),
    };
    match file.try_lock() {
        Ok(()) => {
            let _ = file.unlock();
            false
        }
        Err(std::fs::TryLockError::WouldBlock) => true,
        Err(_) => false,
    }
}

#[cfg(unix)]
fn instance_lock_held(dir: &Path) -> bool {
    use std::os::fd::AsRawFd;
    let Ok(file) = std::fs::File::open(dir.join("hollow.lock")) else { return false };
    // SAFETY: a plain C struct, for which all zeros is a valid value.
    let mut probe: libc::flock = unsafe { std::mem::zeroed() };
    probe.l_type = libc::F_WRLCK as _;
    probe.l_whence = libc::SEEK_SET as _;
    probe.l_start = INSTANCE_LOCK_BYTE as _;
    probe.l_len = 1;
    // SAFETY: a valid descriptor and a struct the call only reads and writes.
    let asked = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETLK, &mut probe) };
    asked == 0 && probe.l_type != libc::F_UNLCK as libc::c_short
}

#[cfg(not(any(windows, unix)))]
fn instance_lock_held(_dir: &Path) -> bool {
    false
}

/// A profile runs in `dir`: this process's or another's.
fn in_use(dir: &Path) -> bool {
    crate::identity::data_dir().is_ok_and(|root| same_folder(&root, dir)) || instance_lock_held(dir)
}

/// Every folder a relink kept aside from `root`, at any depth: a `<root>-old-<day>`
/// sibling whose origin mark names `root`, then what was kept aside from that. A
/// folder some profile runs in is a live profile now, so it and what it kept stay.
fn kept_aside_of(root: &Path, out: &mut Vec<PathBuf>) {
    let (Some(parent), Some(base)) = (root.parent(), root.file_name()) else { return };
    let base = base.to_string_lossy().into_owned();
    let root_text = root.to_string_lossy().into_owned();
    for entry in std::fs::read_dir(parent).into_iter().flatten().flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().into_owned();
        if !entry.file_type().is_ok_and(|t| t.is_dir()) || !is_kept_name(&name, &base) {
            continue;
        }
        let origin = std::fs::read(path.join(RELINK_ORIGIN))
            .ok()
            .and_then(|b| serde_json::from_slice::<Origin>(&b).ok());
        if !origin.is_some_and(|o| same_path(&o.root, &root_text)) || in_use(&path) {
            continue;
        }
        kept_aside_of(&path, out);
        out.push(path);
    }
}

/// A relink cut short between making its folder and marking it leaves an unmarked
/// `<root>-old-<day>` folder with no identity in it, perhaps with that folder's
/// keychain slot and blob. They open the identity a destroy is taking, so they go.
fn forget_unmarked_slots(root: &Path) {
    let (Some(parent), Some(base)) = (root.parent(), root.file_name()) else { return };
    let base = base.to_string_lossy().into_owned();
    for entry in std::fs::read_dir(parent).into_iter().flatten().flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().into_owned();
        if !entry.file_type().is_ok_and(|t| t.is_dir())
            || !is_kept_name(&name, &base)
            || present(&path.join(RELINK_ORIGIN))
            || present(&path.join("identity.key"))
        {
            continue;
        }
        super::wipe::zero_and_remove(&path.join("identity.dpapi"));
        crate::identity::platform_keystore::forget_key_proven(&path, false);
        let _ = std::fs::remove_dir(&path);
    }
}

/// The first half of erasing what a relink kept aside from `root`: each folder's keys
/// are zeroed as a root's destroy zeroes them, its keychain slots go (the shared legacy
/// slot only when its key provably opens that folder's identity), and its database,
/// which holds the per-file keys, goes as the root's does. Returns the folders for
/// [`remove_kept_aside`]. Part of a destroy only, never of a cancelled link's wipe.
pub(crate) fn zero_kept_aside(root: &Path) -> Vec<PathBuf> {
    let mut kept = Vec::new();
    kept_aside_of(root, &mut kept);
    forget_unmarked_slots(root);
    for dir in &kept {
        let identity_before = std::fs::read(dir.join("identity.key")).ok();
        super::wipe::zero_keys(dir);
        crate::identity::platform_keystore::forget_key_at(dir, identity_before.as_deref());
        for name in DB_SET {
            let _ = std::fs::remove_file(dir.join(name));
        }
        forget_unmarked_slots(dir);
    }
    kept
}

/// Removes one entry of a kept folder. A link (a symlink, a junction) goes as a link,
/// never followed: what it points at is not Hollow's.
fn remove_kept_entry(entry: &std::fs::DirEntry) -> bool {
    let path = entry.path();
    let name = entry.file_name().to_string_lossy().into_owned();
    match entry.file_type() {
        Ok(t) if t.is_symlink() => std::fs::remove_file(&path).or_else(|_| std::fs::remove_dir(&path)).is_ok(),
        Ok(t) if t.is_dir() => super::wipe::remove_dir_zeroing_keys(&path).is_ok(),
        _ if is_key_file(&name) || name.starts_with("pending_link.") => {
            super::wipe::zero_and_remove(&path);
            !present(&path)
        }
        _ => std::fs::remove_file(&path).is_ok(),
    }
}

/// `dir` is old data kept aside from `of`, at any depth: its name extends `of`'s.
fn kept_from(dir: &Path, of: &Path) -> bool {
    let (Some(name), Some(base)) = (dir.file_name(), of.file_name()) else { return false };
    dir.parent() == of.parent() && name.to_string_lossy().starts_with(&format!("{}-old-", base.to_string_lossy()))
}

/// The second half: the folders themselves, each one's origin mark last, so a folder
/// a held file keeps is still found by the next start's wipe. A folder whose own kept
/// data is left keeps its mark too: that mark is the only way back to it. True when
/// all are gone.
pub(crate) fn remove_kept_aside(kept: &[PathBuf]) -> bool {
    let mut left: Vec<&PathBuf> = Vec::new();
    for dir in kept {
        let gone = std::fs::read_dir(dir)
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.file_name() != RELINK_ORIGIN)
            .fold(true, |gone, entry| remove_kept_entry(&entry) && gone);
        let removed = gone
            && !left.iter().any(|d| kept_from(d, dir))
            && std::fs::remove_file(dir.join(RELINK_ORIGIN)).is_ok()
            && std::fs::remove_dir(dir).is_ok();
        if !removed {
            left.push(dir);
        }
    }
    left.is_empty()
}

/// No kept folder holds a key or a database any more, its landing copies included:
/// what a boot wipe waits for, as it waits for the root's. Any other leftover stays
/// under its origin mark for the next destroy, and never keeps the profile from
/// getting an identity again.
pub(crate) fn kept_keys_gone(kept: &[PathBuf]) -> bool {
    let holds_keys = |dir: &Path| {
        std::fs::read_dir(dir).into_iter().flatten().flatten().any(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            is_key_file(&name) || name.starts_with("pending_link.") || DB_SET.contains(&name.as_str())
        })
    };
    let landing_holds_keys = |dir: &Path| {
        [".landing", ".replaced"].iter().map(|sub| dir.join(sub)).any(|sub| {
            std::fs::symlink_metadata(&sub).is_ok_and(|m| m.is_dir()) && holds_keys(&sub)
        })
    };
    !kept.iter().any(|dir| holds_keys(dir) || landing_holds_keys(dir))
}

/// Both halves at once. Returns the folders it erased.
#[cfg(test)]
pub(crate) fn erase_kept_aside(root: &Path) -> Vec<PathBuf> {
    let kept = zero_kept_aside(root);
    remove_kept_aside(&kept);
    kept
}

// -- Diagnostics --

/// Names the file list may show. Anything else is only counted.
const LISTED: [&str; 24] = [
    "identity.key", "identity.device", "identity.dpapi", "identity.key.locked", "identity.device.locked",
    "messages.db", "messages.db-wal", "messages.db-shm", "files", "audio_cache", "vault_cache", "vault",
    "shares", "temp", "custom_background.img", "profiles.json", "hollow.lock", "hollow_debug.log",
    "hollow_crash.log", "hollow_crash.log.old", "roster_bootstrap.json", "pending_link.hollow", ".landing",
    ".replaced",
];

fn listed(name: &str) -> bool {
    LISTED.contains(&name) || name == ".landed" || name.starts_with(ASIDE_PREFIX) || name.starts_with(SET_ASIDE_FILE)
}

fn tree_size(path: &Path) -> (u64, u64) {
    let mut count = 0;
    let mut bytes = 0;
    for entry in std::fs::read_dir(path).into_iter().flatten().flatten() {
        match entry.metadata() {
            Ok(m) if m.is_dir() => {
                let (c, b) = tree_size(&entry.path());
                count += c;
                bytes += b;
            }
            Ok(m) => {
                count += 1;
                bytes += m.len();
            }
            Err(_) => {}
        }
    }
    (count, bytes)
}

fn file_list(root: &Path) -> String {
    let mut lines = Vec::new();
    let mut other = (0u64, 0u64);
    let mut entries: Vec<_> = std::fs::read_dir(root).into_iter().flatten().flatten().collect();
    entries.sort_by_key(|e| e.file_name());
    for entry in entries {
        let name = entry.file_name().to_string_lossy().into_owned();
        let Ok(meta) = entry.metadata() else { continue };
        let (count, bytes) = if meta.is_dir() { tree_size(&entry.path()) } else { (1, meta.len()) };
        if !listed(&name) {
            other = (other.0 + 1, other.1 + bytes);
            continue;
        }
        let when = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| day_of(d.as_millis() as i64))
            .unwrap_or_default();
        lines.push(if meta.is_dir() {
            format!("  {name}/ {count} files, {bytes} bytes, changed {when}")
        } else {
            format!("  {name} {bytes} bytes, changed {when}")
        });
    }
    if other.0 > 0 {
        lines.push(format!("  {} other entr(ies), {} bytes", other.0, other.1));
    }
    lines.join("\n")
}

/// The last `n` lines of a text file, or nothing.
fn tail(path: &Path, n: usize) -> String {
    let Ok(bytes) = std::fs::read(path) else { return String::new() };
    let text = String::from_utf8_lossy(&bytes);
    let lines: Vec<&str> = text.lines().collect();
    lines[lines.len().saturating_sub(n)..].join("\n")
}

fn is_hex(s: &str) -> bool {
    s.bytes().all(|b| b.is_ascii_hexdigit())
}

/// A token that names something: a peer id, a key, a signature, a hash, a uuid.
/// A peer id needs no rule of its own: `12D3Koo` gives it digits and both cases.
fn names_something(t: &str) -> bool {
    let len = t.len();
    let stripped: String = t.chars().filter(|c| *c != '-').collect();
    if len == 36 && t.matches('-').count() == 4 && is_hex(&stripped) {
        return true;
    }
    if is_hex(t) && len >= 16 && (len >= 32 || t.bytes().any(|b| b.is_ascii_alphabetic())) {
        return true;
    }
    len >= 24
        && t.bytes().all(|b| b.is_ascii_alphanumeric() || b"+/=_-".contains(&b))
        && t.bytes().any(|b| b.is_ascii_digit())
        && t.bytes().any(|b| b.is_ascii_uppercase())
        && t.bytes().any(|b| b.is_ascii_lowercase())
}

/// The relay every install starts on: naming it says nothing about the person.
const DEFAULT_RELAY: &str = "relay.anonlisten.com";

/// Dotted names Hollow's own logs use: its files, its relay, and source files a crash
/// line points at. Any other `a.b` is a file someone named or a host someone chose.
fn hollow_dotted(name: &str) -> bool {
    const SOURCE: [&str; 13] = ["rs", "dart", "cpp", "cc", "c", "h", "hpp", "kt", "java", "swift", "mm", "dll", "so"];
    LISTED.contains(&name)
        || LOGS.contains(&name)
        || name == DEFAULT_RELAY
        || [RELINK_JOURNAL, RELINK_ORIGIN, "push_lines.json", "recordings.list"].contains(&name)
        || name.starts_with("messages.db")
        || name.rsplit_once('.').is_some_and(|(_, ext)| SOURCE.contains(&ext.to_ascii_lowercase().as_str()) || ext == "dylib")
}

/// `a.b` (or longer) ending in letters, as a file name or a host name does.
fn dotted_name(t: &str) -> bool {
    let parts: Vec<&str> = t.split('.').collect();
    let last = parts[parts.len() - 1];
    parts.len() >= 2
        && parts.iter().all(|p| !p.is_empty())
        && (2..=24).contains(&last.len())
        && last.bytes().all(|b| b.is_ascii_alphabetic())
        && !hollow_dotted(t)
}

fn ipv4_at(chars: &[char], start: usize) -> Option<usize> {
    let mut i = start;
    for part in 0..4 {
        let digits = chars[i..].iter().take_while(|c| c.is_ascii_digit()).count();
        if !(1..=3).contains(&digits) {
            return None;
        }
        i += digits;
        if part < 3 {
            if chars.get(i) != Some(&'.') {
                return None;
            }
            i += 1;
        }
    }
    let joined = |c: Option<&char>| c.is_some_and(|c| c.is_ascii_alphanumeric() || *c == '.');
    (!joined(chars.get(i)) && (start == 0 || !joined(chars.get(start - 1)))).then_some(i)
}

/// Hex groups and colons, with a letter or "::" to tell it from a clock.
fn is_v6(t: &str) -> bool {
    t.matches(':').count() >= 2
        && t.chars().all(|c| c.is_ascii_hexdigit() || c == ':')
        && (t.contains("::") || t.chars().any(|c| c.is_ascii_alphabetic()))
}

/// One pass over `text`: wherever `find` matches at a position, its replacement goes
/// out in place of the characters up to the end it gives.
fn replace_at(text: &str, find: impl Fn(&[char], usize) -> Option<(usize, String)>) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < chars.len() {
        match find(&chars, i) {
            Some((end, with)) if end > i => {
                out.push_str(&with);
                i = end;
            }
            _ => {
                out.push(chars[i]);
                i += 1;
            }
        }
    }
    out
}

/// Nothing word-like right before `i`: a name or a path may start here.
fn starts_free(chars: &[char], i: usize) -> bool {
    i == 0 || chars[i - 1].is_whitespace() || "\"'([=,".contains(chars[i - 1])
}

fn email_at(chars: &[char], i: usize) -> Option<(usize, String)> {
    let local = |c: char| c.is_ascii_alphanumeric() || "._%+-".contains(c);
    if !local(chars[i]) || (i > 0 && local(chars[i - 1])) {
        return None;
    }
    let at = i + chars[i..].iter().take_while(|c| local(**c)).count();
    if chars.get(at) != Some(&'@') {
        return None;
    }
    let domain_len = chars[at + 1..].iter().take_while(|c| c.is_ascii_alphanumeric() || **c == '.' || **c == '-').count();
    let domain: String = chars[at + 1..at + 1 + domain_len].iter().collect();
    let domain = domain.trim_end_matches('.');
    let last = domain.rsplit('.').next().unwrap_or("");
    (domain.contains('.') && last.len() >= 2 && last.bytes().all(|b| b.is_ascii_alphabetic()))
        .then(|| (at + 1 + domain.chars().count(), "email".to_string()))
}

/// `scheme://host[:port][/rest]`: the host goes unless it is the default relay, and the
/// rest goes with it.
fn url_at(chars: &[char], i: usize) -> Option<(usize, String)> {
    if !chars[i].is_ascii_alphabetic() || (i > 0 && chars[i - 1].is_ascii_alphanumeric()) {
        return None;
    }
    let scheme_len = chars[i..].iter().take_while(|c| c.is_ascii_alphanumeric() || "+.-".contains(**c)).count();
    let sep = i + scheme_len;
    if chars.get(sep..sep + 3)? != [':', '/', '/'] {
        return None;
    }
    let host_start = sep + 3;
    let host_len = if chars.get(host_start) == Some(&'[') {
        chars[host_start..].iter().position(|c| *c == ']').map_or(chars.len() - host_start, |p| p + 1)
    } else {
        chars[host_start..].iter().take_while(|c| c.is_ascii_alphanumeric() || ".-_@".contains(**c)).count()
    };
    let host: String = chars[host_start..host_start + host_len].iter().collect();
    let mut end = host_start + host_len;
    let port_len = if chars.get(end) == Some(&':') {
        chars[end + 1..].iter().take_while(|c| c.is_ascii_digit()).count()
    } else {
        0
    };
    let port: String = if port_len > 0 { chars[end..end + 1 + port_len].iter().collect() } else { String::new() };
    if port_len > 0 {
        end += 1 + port_len;
    }
    let rest_len = chars[end..]
        .iter()
        .take_while(|c| !c.is_whitespace() && !"\"'<>)]".contains(**c))
        .count();
    let scheme: String = chars[i..sep].iter().collect();
    if host.eq_ignore_ascii_case(DEFAULT_RELAY) {
        let whole: String = chars[i..end + rest_len].iter().collect();
        return Some((end + rest_len, whole));
    }
    let rest = if rest_len > 0 { "/<path>" } else { "" };
    Some((end + rest_len, format!("{scheme}://host{port}{rest}")))
}

/// Characters that close a word of a path, trimmed before judging it.
const PATH_TRAIL: &str = ":,;)]\"'";

/// The word ends in a file extension: `.` then up to ten letters or digits, one a letter.
fn ends_with_extension(word: &str) -> bool {
    let word = word.trim_end_matches(|c| PATH_TRAIL.contains(c));
    let name = word.rsplit(['/', '\\']).next().unwrap_or(word);
    name.rsplit_once('.').is_some_and(|(stem, ext)| {
        !stem.is_empty()
            && (1..=10).contains(&ext.len())
            && ext.bytes().all(|b| b.is_ascii_alphanumeric())
            && ext.bytes().any(|b| b.is_ascii_alphabetic())
    })
}

/// A path: under `<data>` or `~`, from a drive, from `/`, or a share. A quoted path runs
/// to its quote. Otherwise, since names hold spaces, it runs to the first word on the
/// line that ends in a file extension, before any `key=value`; with none, one word.
fn path_at(chars: &[char], i: usize) -> Option<(usize, String)> {
    let sep = |c: Option<&char>| matches!(c, Some('/') | Some('\\'));
    let data: Vec<char> = "<data>".chars().collect();
    let (body, prefix) = if chars[i..].starts_with(&data) && sep(chars.get(i + data.len())) {
        (i + data.len(), "<data>/")
    } else if chars[i] == '~' && starts_free(chars, i) && sep(chars.get(i + 1)) {
        (i + 1, "~/")
    } else if starts_free(chars, i)
        && ((chars[i].is_ascii_alphabetic() && chars.get(i + 1) == Some(&':') && sep(chars.get(i + 2)))
            || (chars[i] == '/' && chars.get(i + 1).is_some_and(|c| c.is_alphanumeric() || "._~".contains(*c)))
            || (chars[i] == '\\' && chars.get(i + 1) == Some(&'\\')))
    {
        (i, "")
    } else {
        return None;
    };
    let line_end = chars[body..].iter().position(|c| *c == '\n').map_or(chars.len(), |p| body + p);
    let quote = (i > 0 && (chars[i - 1] == '"' || chars[i - 1] == '\'')).then(|| chars[i - 1]);
    let end = if let Some(q) = quote {
        chars[body..line_end].iter().position(|c| *c == q).map_or(line_end, |p| body + p)
    } else {
        let mut words = Vec::new();
        let mut w = body;
        while w < line_end {
            let len = chars[w..line_end].iter().take_while(|c| !c.is_whitespace()).count();
            words.push((w, w + len));
            w += len;
            w += chars[w..line_end].iter().take_while(|c| c.is_whitespace()).count();
        }
        let trimmed_end = |(s, e): (usize, usize)| {
            let word: String = chars[s..e].iter().collect();
            s + word.trim_end_matches(|c| PATH_TRAIL.contains(c)).chars().count()
        };
        let mut end = words.first().copied().map_or(body, trimmed_end);
        for &(s, e) in &words {
            let word: String = chars[s..e].iter().collect();
            if s != body && word.contains('=') {
                break;
            }
            if ends_with_extension(&word) {
                end = trimmed_end((s, e));
                break;
            }
            if word.ends_with(':') {
                break;
            }
        }
        end
    };
    Some((end.max(body + 1), format!("{prefix}<path>")))
}

/// `+` and 8 to 15 digits, or `(555) 123-4567` / `555-123-4567` / `555.123.4567`.
fn phone_at(chars: &[char], i: usize) -> Option<(usize, String)> {
    let free = i == 0 || !(chars[i - 1].is_ascii_alphanumeric() || ".-+_".contains(chars[i - 1]));
    if !free {
        return None;
    }
    let digit = |j: usize| chars.get(j).is_some_and(|c| c.is_ascii_digit());
    if chars[i] == '+' && digit(i + 1) {
        let mut j = i + 1;
        let mut end = j;
        let mut count = 0;
        while j < chars.len() && (chars[j].is_ascii_digit() || " -.()".contains(chars[j])) {
            if chars[j].is_ascii_digit() {
                count += 1;
                end = j + 1;
            }
            j += 1;
        }
        return ((8..=15).contains(&count) && !chars.get(end).is_some_and(|c| c.is_ascii_alphanumeric()))
            .then(|| (end, "phone".to_string()));
    }
    let run = |j: usize, n: usize| (j..j + n).all(digit);
    let (mut j, paren) = if chars[i] == '(' { (i + 1, true) } else { (i, false) };
    if !run(j, 3) {
        return None;
    }
    j += 3;
    if paren {
        if chars.get(j) != Some(&')') {
            return None;
        }
        j += 1;
    }
    let sep = chars.get(j).copied()?;
    if !(sep == '-' || sep == '.' || (paren && sep == ' ')) || !run(j + 1, 3) {
        return None;
    }
    j += 4;
    if !chars.get(j).is_some_and(|c| *c == '-' || *c == '.' || *c == sep) || !run(j + 1, 4) {
        return None;
    }
    j += 5;
    (!chars.get(j).is_some_and(|c| c.is_ascii_alphanumeric())).then(|| (j, "phone".to_string()))
}

/// The word at `start` follows a stack frame's number (`#5      State.setState`): it is
/// a class and method, which a crash report needs, never a name someone chose.
fn frame_method_at(chars: &[char], start: usize) -> bool {
    let line_start = chars[..start].iter().rposition(|c| *c == '\n').map_or(0, |p| p + 1);
    let lead: String = chars[line_start..start].iter().collect();
    let lead = lead.trim_start();
    lead.strip_prefix('#').is_some_and(|rest| {
        let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
        digits > 0 && rest.len() > digits && rest[digits..].bytes().all(|b| b == b' ' || b == b'\t')
    })
}

/// `text` with every id replaced by a stable alias (`id1`, `id2`... in order of first
/// sight, so lines still match up), the given folders by a name, and what tells who the
/// person is or what they shared by a plain word: paths, file and host names (but the
/// default relay's), links, addresses, emails, phone numbers.
pub(crate) fn redact(text: &str, folders: &[(&str, &str)]) -> String {
    let mut text = text.to_string();
    for (path, name) in folders.iter().filter(|(p, _)| p.len() > 2) {
        text = text.replace(path, name).replace(&path.replace('\\', "/"), name);
    }
    let text = replace_at(&text, email_at);
    let text = replace_at(&text, url_at);
    let text = replace_at(&text, path_at);
    let chars: Vec<char> = text.chars().collect();
    let mut aliases: HashMap<String, String> = HashMap::new();
    let mut alias = |part: &str, out: &mut String| {
        let next = aliases.len() + 1;
        out.push_str(aliases.entry(part.to_string()).or_insert_with(|| format!("id{next}")));
    };
    let mut out = String::with_capacity(text.len());
    let token_char = |c: char| c.is_ascii_alphanumeric() || "+/=_-.:".contains(c);
    let mut i = 0;
    while i < chars.len() {
        if chars[i].is_ascii_digit()
            && let Some(end) = ipv4_at(&chars, i)
        {
            out.push_str("ip");
            i = end;
            continue;
        }
        if !token_char(chars[i]) {
            out.push(chars[i]);
            i += 1;
            continue;
        }
        let start = i;
        while i < chars.len() && token_char(chars[i]) {
            i += 1;
        }
        // A sentence's full stop is not part of the word.
        while i > start + 1 && chars[i - 1] == '.' {
            i -= 1;
        }
        let word: String = chars[start..i].iter().collect();
        if is_v6(&word) {
            out.push_str("ip");
            continue;
        }
        // An IPv4-mapped IPv6 address, `::ffff:a.b.c.d`, a port after it or not.
        let wchars: Vec<char> = word.chars().collect();
        let mapped = wchars.iter().enumerate().filter(|(_, c)| **c == ':').find_map(|(k, _)| {
            let prefix: String = wchars[..k].iter().collect();
            let end = ipv4_at(&wchars, k + 1)?;
            (is_v6(&format!("{prefix}:")) || prefix.contains("::")).then_some(end)
        });
        if let Some(end) = mapped {
            out.push_str("ip");
            out.extend(&wchars[end..]);
            continue;
        }
        let frame = frame_method_at(&chars, start);
        for (n, part) in word.split(':').enumerate() {
            if n > 0 {
                out.push(':');
            }
            if names_something(part) {
                alias(part, &mut out);
            } else if !frame && dotted_name(part) {
                out.push_str("name");
            } else {
                for (m, piece) in part.split('.').enumerate() {
                    if m > 0 {
                        out.push('.');
                    }
                    if names_something(piece) {
                        alias(piece, &mut out);
                    } else {
                        out.push_str(piece);
                    }
                }
            }
        }
    }
    replace_at(&out, phone_at)
}

const MAX_REPORT: usize = 64 * 1024;

/// The file list and the ends of both logs, ids replaced. Never key material: file
/// contents are never read, the logs never hold a key, a phrase or a password.
/// `starting` (a start-up step unfinished) gives nothing at all, so a held wipe and a
/// held landing read the same.
#[frb]
pub fn diagnostics_report(starting: bool) -> Result<String, String> {
    if starting {
        return Ok(String::new());
    }
    let root = crate::identity::data_dir()?;
    Ok(report_for(&root, &crate::log::path()))
}

pub(crate) fn report_for(root: &Path, debug_log: &Path) -> String {
    let home = std::env::var("USERPROFILE").or_else(|_| std::env::var("HOME")).unwrap_or_default();
    let root_text = root.to_string_lossy().into_owned();
    let folders = [(root_text.as_str(), "<data>"), (home.as_str(), "~")];
    let mut debug = tail(debug_log, 300);
    let crash = tail(&root.join("hollow_crash.log"), 80);
    let budget = MAX_REPORT.saturating_sub(crash.len() + 8 * 1024);
    if debug.len() > budget {
        let mut cut = debug.len() - budget;
        while !debug.is_char_boundary(cut) {
            cut += 1;
        }
        debug = debug[cut..].to_string();
    }
    // The file list names only what `LISTED` allows; the logs say anything.
    let logs = redact(&format!("Debug log, last lines\n{debug}\n\nCrash log, last lines\n{crash}\n"), &folders);
    format!("Data folder\n{}\n\n{logs}", file_list(root))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::native_identity::NativeKeypair;
    use crate::storage::MessageStore;

    const DAY: i64 = 1_760_054_400_000; // 2025-10-10 00:00 UTC

    fn pass_of(seed: u8) -> String {
        let proto = NativeKeypair::from_secret_bytes(&[seed; 32]).to_protobuf_encoding().unwrap();
        hex::encode(&proto[..32])
    }

    /// A data root holding the identity `seed` (plaintext key and a device key) and a
    /// database made under `db_seed` that says `who`.
    fn root_with(root: &Path, seed: u8, db_seed: u8, who: &str) {
        std::fs::create_dir_all(root).unwrap();
        let master = NativeKeypair::from_secret_bytes(&[seed; 32]);
        std::fs::write(root.join("identity.key"), master.to_protobuf_encoding().unwrap()).unwrap();
        let device = NativeKeypair::from_secret_bytes(&[seed.wrapping_add(1); 32]);
        std::fs::write(root.join("identity.device"), device.to_protobuf_encoding().unwrap()).unwrap();
        db_in(root, db_seed, who);
    }

    fn db_in(dir: &Path, seed: u8, who: &str) {
        std::fs::create_dir_all(dir).unwrap();
        let db = dir.join("messages.db");
        let store = MessageStore::open(db.to_str().unwrap(), &pass_of(seed)).unwrap();
        store.save_setting("who", who).unwrap();
    }

    fn who(dir: &Path, seed: u8) -> Result<String, String> {
        let store = MessageStore::open(dir.join("messages.db").to_str().unwrap(), &pass_of(seed))?;
        Ok(store.load_setting("who")?.unwrap_or_default())
    }

    fn put(path: &Path, bytes: &[u8]) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, bytes).unwrap();
    }

    fn names(dir: &Path) -> Vec<String> {
        let mut v: Vec<String> = std::fs::read_dir(dir)
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        v.sort();
        v
    }

    #[test]
    fn day_of_names_the_utc_day() {
        assert_eq!(day_of(0), "1970-01-01");
        assert_eq!(day_of(DAY), "2025-10-10");
        assert_eq!(day_of(DAY + 86_399_999), "2025-10-10");
        assert_eq!(day_of(951_782_400_000), "2000-02-29");
    }

    #[test]
    fn a_move_that_fails_partway_puts_back_what_already_moved() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let (from, to) = (tmp.path().join("from"), tmp.path().join("to"));
        put(&from.join("a"), b"a");
        put(&from.join("b").join("inner"), b"b");
        std::fs::create_dir_all(&to).unwrap();
        let list = ["a", "b", "missing"].map(String::from);
        assert!(move_all(&from, &to, &list).err().is_some_and(|f| !f.stranded));
        assert_eq!(names(&from), ["a", "b"]);
        assert!(names(&to).is_empty());
    }

    #[test]
    fn the_database_moves_first_and_the_identity_key_last() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        for name in ["messages.db", "messages.db-wal", "aaa", "identity.key", "identity.key.locked", "identity.device", "zzz"] {
            put(&root.join(name), b"x");
        }
        let order = ordered(&root, |_| true, is_key_file).unwrap();
        assert_eq!(
            order,
            ["messages.db", "messages.db-wal", "aaa", "zzz", "identity.device", "identity.key.locked", "identity.key"]
        );
    }

    #[test]
    fn a_repair_stamps_the_link_time_the_identity_files_show() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x4a, 0x4b, "other");
        let then = std::time::UNIX_EPOCH + std::time::Duration::from_millis(DAY as u64);
        for name in ["identity.key", "identity.device"] {
            std::fs::File::options().write(true).open(root.join(name)).unwrap().set_modified(then).unwrap();
        }
        repair_at(&root, &pass_of(0x4a), "dev", now_ms()).unwrap();
        let store = MessageStore::open(root.join("messages.db").to_str().unwrap(), &pass_of(0x4a)).unwrap();
        let stamp: i64 = store.load_setting(&crate::node::destroy::link_key("dev")).unwrap().unwrap().parse().unwrap();
        assert!(stamp <= DAY, "never later than the files show: {stamp}");
    }

    #[test]
    fn store_trouble_tells_a_database_of_another_identity_from_one_that_opens() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x31, 0x32, "other");
        assert_eq!(trouble_of(&root.join("messages.db"), &pass_of(0x31)), StoreTrouble::Unreadable);
        assert_eq!(trouble_of(&root.join("messages.db"), &pass_of(0x32)), StoreTrouble::Other);
        std::fs::write(root.join("messages.db"), b"not sqlite at all, just bytes that are long enough").unwrap();
        assert_eq!(trouble_of(&root.join("messages.db"), &pass_of(0x31)), StoreTrouble::Unreadable);
    }

    #[test]
    fn a_repair_keeps_the_unreadable_database_and_opens_a_new_one_under_the_same_identity() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x33, 0x34, "the old one");
        put(&root.join("files").join("f1.webp"), b"HFE1 sealed bytes");
        put(&root.join("hollow_debug.log"), b"log line\n");
        put(&root.join("profiles.json"), b"{}");
        let old_db = std::fs::read(root.join("messages.db")).unwrap();
        let key = std::fs::read(root.join("identity.key")).unwrap();

        let out = repair_at(&root, &pass_of(0x33), "dev", DAY).unwrap();

        assert_eq!(out.folder, "unreadable-2025-10-10");
        assert!(!out.restored);
        let aside = root.join(&out.folder);
        assert_eq!(std::fs::read(aside.join("messages.db")).unwrap(), old_db, "the unreadable database is kept byte for byte");
        assert_eq!(who(&aside, 0x34).unwrap(), "the old one");
        assert!(aside.join("files").join("f1.webp").exists(), "the at-rest files go with the keys that open them");
        assert!(!root.join("files").exists());
        assert_eq!(std::fs::read(root.join("identity.key")).unwrap(), key, "the identity stays");
        assert!(root.join("identity.device").exists());
        assert!(root.join("hollow_debug.log").exists() && root.join("profiles.json").exists());
        assert_eq!(who(&root, 0x33).unwrap(), "", "a new database opens under the same identity");
        let store = MessageStore::open(root.join("messages.db").to_str().unwrap(), &pass_of(0x33)).unwrap();
        let stamp: i64 = store.load_setting(&crate::node::destroy::link_key("dev")).unwrap().unwrap().parse().unwrap();
        assert!(stamp > 0 && stamp <= now_ms(), "the link time is carried from the identity files, got {stamp}");
    }

    #[test]
    fn a_second_repair_on_one_day_gets_its_own_folder() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x35, 0x36, "first");
        repair_at(&root, &pass_of(0x35), "dev", DAY).unwrap();
        for name in DB_SET {
            let _ = std::fs::remove_file(root.join(name));
        }
        db_in(&root, 0x37, "second");
        let out = repair_at(&root, &pass_of(0x35), "dev", DAY).unwrap();
        assert_eq!(out.folder, "unreadable-2025-10-10-2");
        assert_eq!(who(&root.join("unreadable-2025-10-10"), 0x36).unwrap(), "first");
        assert_eq!(who(&root.join("unreadable-2025-10-10-2"), 0x37).unwrap(), "second");
    }

    #[test]
    fn a_repair_puts_back_a_kept_copy_this_identity_opens() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x38, 0x39, "a stranger's");
        db_in(&root.join(".replaced"), 0x38, "ours, kept");
        put(&root.join("files").join("f2.webp"), b"HFE1");

        let out = repair_at(&root, &pass_of(0x38), "dev", DAY).unwrap();

        assert!(out.restored);
        assert_eq!(who(&root, 0x38).unwrap(), "ours, kept");
        assert_eq!(who(&root.join(&out.folder), 0x39).unwrap(), "a stranger's");
        assert!(root.join("files").join("f2.webp").exists(), "the restored copy may hold these files' keys");
        assert_eq!(who(&root.join(".replaced"), 0x38).unwrap(), "ours, kept", "the kept copy itself is never changed");
    }

    #[test]
    fn a_repair_puts_back_a_copy_a_start_up_set_aside_in_the_root() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x4d, 0x4e, "a stranger's");
        let ours = root.join("messages.db.unreadable-20261009-080000");
        let theirs = root.join("messages.db.unreadable-20261010-090000");
        std::fs::rename(root.join("messages.db"), &theirs).unwrap();
        db_in(&tmp.path().join("ours"), 0x4d, "ours, set aside");
        std::fs::rename(tmp.path().join("ours").join("messages.db"), &ours).unwrap();
        db_in(&root, 0x4e, "a stranger's");
        let (ours_bytes, theirs_bytes) = (std::fs::read(&ours).unwrap(), std::fs::read(&theirs).unwrap());

        let out = repair_at(&root, &pass_of(0x4d), "dev", DAY).unwrap();

        assert!(out.restored, "the copy this identity opens comes back");
        assert_eq!(who(&root, 0x4d).unwrap(), "ours, set aside");
        assert_eq!(std::fs::read(&ours).unwrap(), ours_bytes, "the copy itself is never changed");
        assert_eq!(std::fs::read(&theirs).unwrap(), theirs_bytes);
    }

    #[test]
    fn a_repair_refuses_while_another_start_up_step_is_unfinished_and_moves_nothing() {
        for blocker in ["pending_wipe.marker", ".landing", ".landed", "pending_link.hollow", RELINK_JOURNAL] {
            let tmp = crate::test_tmp::tempdir().unwrap();
            let root = tmp.path().join("data");
            root_with(&root, 0x3a, 0x3b, "kept");
            put(&root.join(blocker), b"1");
            let before = names(&root);
            assert_eq!(repair_at(&root, &pass_of(0x3a), "dev", DAY).err().as_deref(), Some(IDENTITY_NOT_READY), "{blocker}");
            assert_eq!(names(&root), before, "{blocker}: nothing moved");
            assert_eq!(relink_at(&root, DAY).err().as_deref(), Some(IDENTITY_NOT_READY), "{blocker}");
            assert_eq!(names(&root), before, "{blocker}: nothing moved by a relink");
        }
    }

    #[test]
    fn a_repair_of_a_database_that_opens_does_nothing() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x3c, 0x3c, "fine");
        let before = names(&root);
        assert!(repair_at(&root, &pass_of(0x3c), "dev", DAY).is_err());
        assert_eq!(names(&root), before);
        assert_eq!(who(&root, 0x3c).unwrap(), "fine");
    }

    /// Windows refuses to rename a database SQLite holds; elsewhere a rename never fails on it.
    #[cfg(windows)]
    #[test]
    fn a_repair_or_relink_that_meets_a_held_database_moves_everything_back() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x3d, 0x3e, "held");
        put(&root.join("files").join("f.webp"), b"x");
        let holder = MessageStore::open(root.join("messages.db").to_str().unwrap(), &pass_of(0x3e)).unwrap();
        holder.save_setting("late", "write").unwrap();
        let before = names(&root);
        assert_eq!(repair_at(&root, &pass_of(0x3d), "dev", DAY).err().as_deref(), Some(HELD));
        assert_eq!(names(&root), before);
        assert_eq!(relink_at(&root, DAY).err().as_deref(), Some(HELD));
        assert_eq!(names(&root), before);
        assert!(!tmp.path().join("data-old-2025-10-10").exists(), "an undone relink leaves no folder");
        drop(holder);
        assert_eq!(who(&root, 0x3e).unwrap(), "held");
    }

    #[test]
    fn a_relink_moves_everything_beside_the_root_marked_with_where_it_came_from() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x40, 0x40, "ours");
        for name in ["profiles.json", "hollow.lock", "hollow_debug.log", "hollow_crash.log", "recordings.list"] {
            put(&root.join(name), b"stays");
        }
        put(&root.join("files").join("f.webp"), b"x");
        put(&root.join("unreadable-2025-01-01").join("messages.db"), b"older repair");

        let target = relink_at(&root, DAY).unwrap();

        assert_eq!(target, tmp.path().join("data-old-2025-10-10"));
        assert_eq!(
            names(&root),
            ["hollow.lock", "hollow_crash.log", "hollow_debug.log", "profiles.json", "recordings.list", RELINK_WELCOME]
        );
        assert_eq!(who(&target, 0x40).unwrap(), "ours");
        assert!(target.join("identity.key").exists() && target.join("identity.device").exists());
        assert!(target.join("files").join("f.webp").exists() && target.join("unreadable-2025-01-01").exists());
        let origin: Origin = serde_json::from_slice(&std::fs::read(target.join(RELINK_ORIGIN)).unwrap()).unwrap();
        assert!(same_path(&origin.root, &root.to_string_lossy()));
        assert_eq!(std::fs::read_to_string(root.join(RELINK_WELCOME)).unwrap(), target.to_string_lossy());
        assert!(!root.join(RELINK_JOURNAL).exists(), "a finished relink leaves no journal");
        assert_eq!(relink_at(&root, DAY).err().as_deref(), Some(IDENTITY_NOT_READY), "nothing left to move");
    }

    #[test]
    fn a_relink_cut_short_is_undone_before_the_identity_moved_and_finished_after() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        // Cut before the identity moved: the database already went.
        let root = tmp.path().join("a");
        root_with(&root, 0x41, 0x41, "ours");
        let target = tmp.path().join("a-old-2025-10-10");
        std::fs::create_dir(&target).unwrap();
        put(&target.join(RELINK_ORIGIN), br#"{"root":"x"}"#);
        put(&root.join(RELINK_JOURNAL), serde_json::to_string(&Journal { target: target.to_string_lossy().into() }).unwrap().as_bytes());
        std::fs::rename(root.join("messages.db"), target.join("messages.db")).unwrap();
        settle_relink_at(&root);
        assert_eq!(who(&root, 0x41).unwrap(), "ours", "the database is back");
        assert!(!target.exists() && !root.join(RELINK_JOURNAL).exists() && !root.join(RELINK_WELCOME).exists());

        // Cut after the identity moved: only the journal was left.
        let root = tmp.path().join("b");
        root_with(&root, 0x42, 0x42, "ours");
        let target = relink_at(&root, DAY).unwrap();
        std::fs::remove_file(root.join(RELINK_WELCOME)).unwrap();
        put(&root.join(RELINK_JOURNAL), serde_json::to_string(&Journal { target: target.to_string_lossy().into() }).unwrap().as_bytes());
        settle_relink_at(&root);
        assert_eq!(who(&target, 0x42).unwrap(), "ours");
        assert!(!root.join(RELINK_JOURNAL).exists());
        assert!(root.join(RELINK_WELCOME).exists(), "Welcome still tells of the old data");
    }

    #[test]
    fn a_relink_copies_the_keychain_key_to_the_kept_folders_slot() {
        use crate::identity::platform_keystore::test_support as ks;
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x43, 0x43, "ours");
        let key = [0x5a; 32];
        let plain = NativeKeypair::from_secret_bytes(&[0x43; 32]).to_protobuf_encoding().unwrap();
        let sealed = crate::identity::encryption::encrypt_identity(&plain, &key, &[0; 16], false, true).unwrap();
        std::fs::write(root.join("identity.key"), &sealed).unwrap();
        ks::set_profile(&root, &key);

        let target = relink_at(&root, DAY).unwrap();

        assert_eq!(ks::profile_value(&target).as_deref(), Some(&key[..]), "the kept profile still opens");
        assert_eq!(ks::profile_value(&root).as_deref(), Some(&key[..]), "the old slot is not touched");
    }

    fn kept(parent: &Path, name: &str, origin: &Path) -> PathBuf {
        let dir = parent.join(name);
        put(&dir.join("identity.key"), b"a key");
        put(&dir.join("messages.db"), b"db");
        let origin = serde_json::to_vec(&Origin { root: origin.to_string_lossy().into() }).unwrap();
        put(&dir.join(RELINK_ORIGIN), &origin);
        dir
    }

    #[test]
    fn erasing_kept_aside_takes_only_folders_marked_with_this_root() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x44, 0x44, "ours");
        let mine = kept(tmp.path(), "data-old-2025-10-10", &root);
        let mine2 = kept(tmp.path(), "data-old-2025-10-10-2", &root);
        let other_root = kept(tmp.path(), "data-old-2025-10-11", &tmp.path().join("elsewhere"));
        let odd_name = kept(tmp.path(), "data-old-yesterday", &root);
        let other_base = kept(tmp.path(), "database-old-2025-10-10", &root);
        let unmarked = tmp.path().join("data-old-2025-10-12");
        put(&unmarked.join("identity.key"), b"a key");
        crate::identity::platform_keystore::test_support::set_profile(&unmarked, &[0x45; 32]);

        let erased = erase_kept_aside(&root);

        assert_eq!(erased.len(), 2);
        assert!(!mine.exists() && !mine2.exists());
        for kept in [&other_root, &odd_name, &other_base, &unmarked] {
            assert!(kept.join("identity.key").exists(), "{} stays", kept.display());
        }
        assert!(root.join("identity.key").exists(), "the root itself is the wipe's");
        assert!(
            crate::identity::platform_keystore::test_support::profile_value(&unmarked).is_some(),
            "an unmarked folder holding an identity keeps its slot"
        );
    }

    #[test]
    fn erasing_kept_aside_forgets_its_keychain_slot_and_never_the_shared_one() {
        use crate::identity::platform_keystore::test_support as ks;
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x4c, 0x4c, "ours");
        let old = kept(tmp.path(), "data-old-2025-10-10", &root);
        ks::set_profile(&old, &[0x6b; 32]);
        ks::set_profile(&root, &[0x6c; 32]);
        ks::set_legacy(&[0x6d; 32]);

        erase_kept_aside(&root);

        assert_eq!(ks::profile_value(&old), None, "the kept data's key goes with it");
        assert_eq!(ks::profile_value(&root).as_deref(), Some(&[0x6c; 32][..]));
        assert_eq!(ks::legacy_value().as_deref(), Some(&[0x6d; 32][..]), "the shared slot belongs to no one folder");
    }

    /// Erasing this device erases what it kept aside, and a cancelled link's wipe never does.
    #[test]
    fn a_destroy_erases_the_old_data_kept_aside_and_a_cancelled_links_wipe_keeps_it() {
        let _g = crate::node::resolver::test_lock();
        let _s = super::super::storage::store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();

        let root = tmp.path().join("one");
        root_with(&root, 0x45, 0x45, "ours");
        let old = kept(tmp.path(), "one-old-2025-10-10", &root);
        super::super::wipe::destroy_data_root(&root).unwrap();
        assert!(!old.exists(), "a destroy takes the old data too");

        let root = tmp.path().join("two");
        root_with(&root, 0x46, 0x46, "ours");
        let old = kept(tmp.path(), "two-old-2025-10-10", &root);
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", &root) };
        super::super::storage::stash_pending_wipe().unwrap();
        super::super::storage::perform_pending_wipe().unwrap();
        assert!(old.join("identity.key").exists(), "a cancelled link's wipe keeps the old data");

        root_with(&root, 0x46, 0x46, "ours");
        std::fs::write(root.join(WIPE_MARKER), super::super::wipe::DESTROY_MARK).unwrap();
        assert!(super::super::storage::perform_pending_wipe().unwrap());
        assert!(!old.exists(), "the boot half of a destroy takes the old data too");
    }

    #[test]
    fn erasing_another_profile_takes_its_kept_old_data_too() {
        let _g = crate::node::resolver::test_lock();
        let _s = super::super::storage::store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let running = tmp.path().join("running");
        std::fs::create_dir_all(&running).unwrap();
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", &running) };
        let other = tmp.path().join("other");
        root_with(&other, 0x49, 0x49, "theirs");
        let old = kept(tmp.path(), "other-old-2025-10-10", &other);
        super::super::wipe::erase_profile_at(other.to_string_lossy().into_owned()).unwrap();
        assert!(!old.exists());
    }

    #[test]
    fn minting_waits_while_a_relink_moves_the_identity() {
        let _g = crate::node::resolver::test_lock();
        let _s = super::super::storage::store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        std::fs::create_dir_all(&root).unwrap();
        put(&root.join(RELINK_JOURNAL), b"{}");
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", &root) };
        let minted = crate::identity::load_or_create_identity();
        assert_eq!(minted.err().as_deref(), Some(IDENTITY_NOT_READY));
        assert!(!root.join("identity.key").exists());
    }

    #[test]
    fn no_database_is_made_while_a_relink_moves_the_old_one_out() {
        let _g = crate::node::resolver::test_lock();
        let _s = super::super::storage::store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x48, 0x48, "ours");
        for name in DB_SET {
            let _ = std::fs::remove_file(root.join(name));
        }
        put(&root.join(RELINK_JOURNAL), b"{}");
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", &root) };
        let opened = super::super::storage::open_message_store();
        assert_eq!(opened.err().as_deref(), Some(IDENTITY_NOT_READY));
        assert!(!root.join("messages.db").exists());
    }

    #[test]
    fn diagnostics_carry_no_id_key_address_or_wipe_marker() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x47, 0x47, "ours");
        put(&root.join(WIPE_MARKER), b"destroy");
        put(&root.join("identity.duress"), b"slot");
        put(&root.join("Holiday photos.zip"), b"x");
        let peer = NativeKeypair::from_secret_bytes(&[0x47; 32]).peer_id();
        let log = tmp.path().join("hollow_debug.log");
        let line = format!(
            "[1760054400] [HOLLOW-SYNC] from {peer} in inbox:{peer} mid 3f2b8c1e-9a4d-4f6b-8e2a-1c5d7f9b0a3e \
             room ab12cd34ef56ab12cd34ef56ab12cd34 key qZ8vT3mK9pL2xR7wN4bY6cF1hJ5dG0sA= \
             via 203.0.113.7:443 and [2001:db8::1] path {} at 12:00:01 order 1760054400123456\n",
            root.join("files").display()
        );
        std::fs::write(&log, line.repeat(3)).unwrap();

        let report = report_for(&root, &log);

        for secret in [peer.as_str(), "3f2b8c1e-9a4d", "ab12cd34ef56", "qZ8vT3mK9pL2", "203.0.113.7", "2001:db8"] {
            assert!(!report.contains(secret), "{secret} leaked:\n{report}");
        }
        assert!(!report.contains(WIPE_MARKER) && !report.contains("duress"), "{report}");
        assert!(!report.contains("Holiday"), "unknown names are only counted: {report}");
        assert!(report.contains("3 other entr(ies)"), "{report}");
        assert!(report.contains("from id1 in inbox:id1"), "one id keeps one alias: {report}");
        assert!(report.contains("12:00:01") && report.contains("[1760054400]"), "times stay: {report}");
        assert!(report.contains("<data>"), "the data folder is named, not shown: {report}");
        assert!(report.contains("messages.db") && report.contains("identity.key"), "{report}");
        assert_eq!(diagnostics_report(true).unwrap(), "", "nothing at all while start-up is unfinished");
    }

    // md-review

    /// The kept folder is a listed profile a desktop can switch to; erasing the profile
    /// it came from must never erase it out from under the process running it.
    #[test]
    fn md_review_erasing_a_profile_never_erases_the_running_profile_kept_from_it() {
        let _g = crate::node::resolver::test_lock();
        let _s = super::super::storage::store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let origin = tmp.path().join("other");
        root_with(&origin, 0x51, 0x51, "the new identity");
        let running = kept(tmp.path(), "other-old-2025-10-10", &origin);
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", &running) };
        super::super::wipe::erase_profile_at(origin.to_string_lossy().into_owned()).unwrap();
        assert!(running.join("identity.key").exists(), "the running profile's identity was erased by another profile's erase");
    }

    /// Old data a relink kept aside from old data is still this root's: a destroy (a
    /// duress code included) must not leave its keys behind.
    #[test]
    fn md_review_a_destroy_erases_old_data_kept_aside_from_old_data() {
        let _g = crate::node::resolver::test_lock();
        let _s = super::super::storage::store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("one");
        root_with(&root, 0x52, 0x52, "ours");
        let old = kept(tmp.path(), "one-old-2025-10-10", &root);
        let older = kept(tmp.path(), "one-old-2025-10-10-old-2025-10-11", &old);
        super::super::wipe::destroy_data_root(&root).unwrap();
        assert!(!old.exists());
        assert!(!older.join("identity.key").exists(), "a destroy left the identity of old data relinked from old data");
    }

    /// A relink that could not copy the keychain key commits anyway, so the kept data
    /// opens only from the root's slot until the next identity there overwrites it.
    #[test]
    fn md_review_a_relink_never_commits_without_the_kept_identitys_keychain_key() {
        use crate::identity::platform_keystore::test_support as ks;
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x53, 0x53, "ours");
        let key = [0x7a; 32];
        let plain = NativeKeypair::from_secret_bytes(&[0x53; 32]).to_protobuf_encoding().unwrap();
        let sealed = crate::identity::encryption::encrypt_identity(&plain, &key, &[0; 16], false, true).unwrap();
        std::fs::write(root.join("identity.key"), &sealed).unwrap();
        ks::set_profile(&root, &key);

        ks::inject(ks::Fault::StoreFails);
        let relinked = relink_at(&root, DAY);
        ks::clear_faults();
        if relinked.is_err() {
            assert!(root.join("identity.key").exists(), "a refused relink moves everything back");
            return;
        }
        let target = relinked.unwrap();
        // Welcome, then a new identity locked to the keychain in the same root.
        ks::set_profile(&root, &[0x7b; 32]);
        assert!(
            crate::identity::platform_keystore::key_that_opens(&target, &sealed).is_some(),
            "the kept identity no longer opens: its key lived only in the root's slot",
        );
    }

    /// Every key file a destroy zeroes in a root is zeroed in a kept folder too.
    #[test]
    fn md_review_erasing_kept_aside_zeroes_the_pending_link_device_key() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x54, 0x54, "ours");
        let old = kept(tmp.path(), "data-old-2025-10-10", &root);
        put(&old.join("pending_link.device"), b"a device secret");
        let watch_key = tmp.path().join("watch_key");
        let watch_dev = tmp.path().join("watch_dev");
        std::fs::hard_link(old.join("identity.key"), &watch_key).unwrap();
        std::fs::hard_link(old.join("pending_link.device"), &watch_dev).unwrap();
        erase_kept_aside(&root);
        assert!(std::fs::read(&watch_key).unwrap().iter().all(|b| *b == 0), "control: identity.key is zeroed");
        assert!(
            std::fs::read(&watch_dev).unwrap().iter().all(|b| *b == 0),
            "pending_link.device was unlinked with its secret still on disk",
        );
    }

    /// A self-hoster's relay and an IPv4-mapped address are as identifying as an IP.
    #[test]
    fn md_review_diagnostics_hide_a_self_hosted_relay_and_a_mapped_address() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x55, 0x55, "ours");
        let log = tmp.path().join("hollow_debug.log");
        std::fs::write(
            &log,
            "[HOLLOW-WS] Connecting to wss://hollow.smithfamily.example/ws...\n\
             [HOLLOW-ICE] local candidate ::ffff:198.51.100.23 port 3478\n",
        )
        .unwrap();
        let report = report_for(&root, &log);
        for secret in ["smithfamily", "51.100.23"] {
            assert!(!report.contains(secret), "{secret} leaked:\n{report}");
        }
    }

    /// The log names the files a person sent and received; the copy says only ids,
    /// keys and messages are left out, and a file name is often all three.
    #[test]
    fn md_review_diagnostics_leave_out_sent_and_received_file_names() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x59, 0x59, "ours");
        let log = tmp.path().join("hollow_debug.log");
        std::fs::write(
            &log,
            format!(
                "[HOLLOW-FILE] SendFile: /home/someone/Documents/Divorce papers draft.pdf mid=m1\n\
                 [HOLLOW-STREAM] File f1 complete: {}\n",
                root.join("files").join("clinic_results_march.png").display()
            ),
        )
        .unwrap();
        let report = report_for(&root, &log);
        for secret in ["Divorce papers", "clinic_results"] {
            assert!(!report.contains(secret), "{secret} leaked:\n{report}");
        }
    }

    /// A copy a start-up set aside in the root stays where a later repair looks: a
    /// repair under the wrong identity must not bury it inside its own folder.
    #[test]
    fn md_review_a_repair_under_the_wrong_identity_never_buries_a_set_aside_copy() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x56, 0x57, "a stranger's");
        let ours = root.join("messages.db.unreadable-20261009-080000");
        db_in(&tmp.path().join("ours"), 0x58, "ours, set aside");
        std::fs::rename(tmp.path().join("ours").join("messages.db"), &ours).unwrap();

        let first = repair_at(&root, &pass_of(0x56), "dev", DAY).unwrap();
        assert!(!first.restored, "precondition: nothing opens with the wrong identity");

        // The right identity comes back (its phrase), and its fresh database will not open.
        let second = repair_at(&root, &pass_of(0x58), "dev", DAY).unwrap();
        assert!(second.restored, "the copy set aside at start-up was buried in {} and never found again", first.folder);
    }

    // md-recovery-4

    /// A kept folder another process runs (its instance lock held) is a live profile.
    #[cfg(windows)]
    #[test]
    fn a_kept_folder_whose_instance_lock_is_held_is_never_erased() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x60, 0x60, "ours");
        let running = kept(tmp.path(), "data-old-2025-10-10", &root);
        let idle = kept(tmp.path(), "data-old-2025-10-10-2", &root);
        put(&idle.join("hollow.lock"), b"4242");
        put(&running.join("hollow.lock"), b"4243");
        let holder = std::fs::OpenOptions::new().read(true).write(true).open(running.join("hollow.lock")).unwrap();
        holder.lock().unwrap();

        let erased = erase_kept_aside(&root);

        assert_eq!(erased, std::slice::from_ref(&idle), "only the idle folder goes");
        assert!(running.join("identity.key").exists(), "a held instance lock keeps the folder");
        assert!(!idle.exists(), "control: a lock nobody holds keeps nothing");
        drop(holder);
    }

    /// What a running kept folder kept aside itself is that live profile's, not the root's.
    #[test]
    fn a_running_kept_folder_keeps_what_it_kept_aside() {
        let _g = crate::node::resolver::test_lock();
        let _s = super::super::storage::store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("one");
        root_with(&root, 0x61, 0x61, "ours");
        let running = kept(tmp.path(), "one-old-2025-10-10", &root);
        let its_own = kept(tmp.path(), "one-old-2025-10-10-old-2025-10-11", &running);
        let sibling = kept(tmp.path(), "one-old-2025-10-12", &root);
        let sibling_own = kept(tmp.path(), "one-old-2025-10-12-old-2025-10-13", &sibling);
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", &running) };
        erase_kept_aside(&root);
        assert!(running.join("identity.key").exists() && its_own.join("identity.key").exists());
        assert!(!sibling.exists() && !sibling_own.exists(), "control: idle old data goes at every depth");
    }

    /// A destroy over a kept folder it cannot remove yet keeps its marker, so the next
    /// start finishes the erase.
    #[cfg(windows)]
    #[test]
    fn a_destroy_keeps_its_marker_while_old_data_is_left_and_the_boot_wipe_waits_only_for_its_keys() {
        use std::os::windows::fs::OpenOptionsExt;
        let _g = crate::node::resolver::test_lock();
        let _s = super::super::storage::store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("one");
        root_with(&root, 0x62, 0x62, "ours");
        let old = kept(tmp.path(), "one-old-2025-10-10", &root);
        put(&old.join("files").join("f.webp"), b"x");
        let holder = std::fs::OpenOptions::new().read(true).share_mode(0).open(old.join("files").join("f.webp")).unwrap();

        super::super::wipe::destroy_data_root(&root).unwrap();

        assert!(root.join(WIPE_MARKER).exists(), "the marker stays while old data is left");
        assert_eq!(std::fs::read(old.join("identity.key")).ok().filter(|k| k.iter().any(|b| *b != 0)), None, "its keys are gone at once");
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", &root) };
        assert!(
            super::super::storage::perform_pending_wipe().unwrap(),
            "a key-less leftover never keeps the profile from getting an identity again"
        );
        assert!(!root.join(WIPE_MARKER).exists());
        assert!(old.join(RELINK_ORIGIN).exists(), "the leftover stays marked for the next destroy");
        drop(holder);
        assert_eq!(erase_kept_aside(&root), std::slice::from_ref(&old));
        assert!(!old.exists());
    }

    /// The boot wipe waits for old data's database as it waits for the root's: it holds
    /// the per-file keys.
    #[cfg(windows)]
    #[test]
    fn a_boot_wipe_keeps_its_marker_while_old_datas_database_is_held() {
        use std::os::windows::fs::OpenOptionsExt;
        let _g = crate::node::resolver::test_lock();
        let _s = super::super::storage::store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("one");
        root_with(&root, 0x85, 0x85, "ours");
        let old = kept(tmp.path(), "one-old-2025-10-10", &root);
        std::fs::write(root.join(WIPE_MARKER), super::super::wipe::DESTROY_MARK).unwrap();
        let holder = std::fs::OpenOptions::new().read(true).share_mode(0).open(old.join("messages.db")).unwrap();
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", &root) };

        assert!(!super::super::storage::perform_pending_wipe().unwrap());
        assert!(root.join(WIPE_MARKER).exists(), "the marker stays while old data's database is left");
        drop(holder);
        assert!(super::super::storage::perform_pending_wipe().unwrap());
        assert!(!old.exists() && !root.join(WIPE_MARKER).exists());
    }

    /// A relink is marked before anything holds a key for it: the mark and the journal
    /// are in place by the time the kept folder's slot is written.
    #[test]
    fn a_relink_marks_its_folder_before_it_keeps_the_key() {
        use crate::identity::platform_keystore::test_support as ks;
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        keychain_root(&root, 0x86, &[0x87; 32]);
        let target = tmp.path().join("data-old-2025-10-10");
        ks::inject(ks::Fault::StoreFails);
        let relinked = relink_at(&root, DAY);
        ks::clear_faults();
        assert_eq!(relinked.err().as_deref(), Some(KEY_NOT_KEPT));
        assert!(!target.exists() && !root.join(RELINK_JOURNAL).exists(), "a refused relink leaves nothing");
        // The mark is written first: a store that fails only once it sees one proves the order.
        MARK_SEEN_BEFORE_KEY.with(|seen| assert_eq!(seen.get(), Some(true)));
    }

    /// Erasing another profile over a kept folder it cannot remove yet keeps that
    /// profile's marker, so its own next start finishes the erase.
    #[cfg(windows)]
    #[test]
    fn erasing_another_profile_keeps_its_marker_until_its_old_data_is_gone() {
        use std::os::windows::fs::OpenOptionsExt;
        let _g = crate::node::resolver::test_lock();
        let _s = super::super::storage::store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let running = tmp.path().join("running");
        std::fs::create_dir_all(&running).unwrap();
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", &running) };
        let other = tmp.path().join("other");
        root_with(&other, 0x6f, 0x6f, "theirs");
        let old = kept(tmp.path(), "other-old-2025-10-10", &other);
        put(&old.join("shares").join("s"), b"x");
        let holder = std::fs::OpenOptions::new().read(true).share_mode(0).open(old.join("shares").join("s")).unwrap();
        super::super::wipe::erase_profile_at(other.to_string_lossy().into_owned()).unwrap();
        assert!(other.join(WIPE_MARKER).exists());
        drop(holder);
    }

    /// The first half alone takes every key a destroy takes and leaves the bulk for later.
    #[test]
    fn zeroing_kept_aside_takes_every_key_before_any_bulk_goes() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x70, 0x70, "ours");
        let old = kept(tmp.path(), "data-old-2025-10-10", &root);
        put(&old.join("pending_link.device"), b"a device secret");
        put(&old.join("identity.duress"), b"a slot");
        put(&old.join("files").join("f.webp"), b"x");
        let watch = tmp.path().join("watch");
        std::fs::hard_link(old.join("pending_link.device"), &watch).unwrap();

        let found = zero_kept_aside(&root);

        assert_eq!(found, std::slice::from_ref(&old));
        assert!(std::fs::read(&watch).unwrap().iter().all(|b| *b == 0));
        for key in ["identity.key", "identity.duress", "pending_link.device"] {
            assert!(!old.join(key).exists(), "{key} is gone");
        }
        assert!(!old.join("messages.db").exists(), "the database goes with the keys, as the root's does");
        assert!(old.join(RELINK_ORIGIN).exists() && old.join("files").join("f.webp").exists(), "the bulk waits");
    }

    /// The second half alone zeroes a key before it unlinks it: one left behind by a
    /// held file in the first half is never unlinked with its secret on disk.
    #[test]
    fn removing_kept_aside_zeroes_a_key_the_first_half_missed() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x71, 0x71, "ours");
        let old = kept(tmp.path(), "data-old-2025-10-10", &root);
        let watch = tmp.path().join("watch");
        std::fs::hard_link(old.join("identity.key"), &watch).unwrap();
        assert!(remove_kept_aside(std::slice::from_ref(&old)));
        assert!(std::fs::read(&watch).unwrap().iter().all(|b| *b == 0));
        assert!(!old.exists());
    }

    /// An undone relink whose blob copy of the key the root still has goes with the
    /// undo; it is no reason to keep the folder.
    #[test]
    fn an_undone_relink_drops_its_copy_of_a_key_the_root_still_has() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x72, 0x72, "ours");
        put(&root.join("identity.dpapi"), b"the root's blob");
        let target = tmp.path().join("data-old-2025-10-10");
        std::fs::create_dir(&target).unwrap();
        put(&target.join(RELINK_ORIGIN), &serde_json::to_vec(&Origin { root: root.to_string_lossy().into() }).unwrap());
        put(&target.join("identity.dpapi"), b"the kept slot's blob");
        put(&root.join(RELINK_JOURNAL), serde_json::to_string(&Journal { target: target.to_string_lossy().into() }).unwrap().as_bytes());

        settle_relink_at(&root);

        assert!(!target.exists(), "nothing is left aside");
        assert_eq!(std::fs::read(root.join("identity.dpapi")).unwrap(), b"the root's blob");
    }

    /// A kept identity whose key the shared legacy slot holds: its erase forgets that
    /// slot, which no other identity opens with.
    #[test]
    fn erasing_kept_aside_forgets_a_legacy_slot_its_identity_proves() {
        use crate::identity::platform_keystore::test_support as ks;
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x63, 0x63, "ours");
        let old = kept(tmp.path(), "data-old-2025-10-10", &root);
        let key = [0x64; 32];
        let plain = NativeKeypair::from_secret_bytes(&[0x63; 32]).to_protobuf_encoding().unwrap();
        let sealed = crate::identity::encryption::encrypt_identity(&plain, &key, &[0; 16], false, true).unwrap();
        std::fs::write(old.join("identity.key"), &sealed).unwrap();
        ks::set_legacy(&key);

        erase_kept_aside(&root);

        assert_eq!(ks::legacy_value(), None, "the legacy slot held only this identity's key");
    }

    fn keychain_root(root: &Path, seed: u8, key: &[u8; 32]) -> Vec<u8> {
        use crate::identity::platform_keystore::test_support as ks;
        root_with(root, seed, seed, "ours");
        let plain = NativeKeypair::from_secret_bytes(&[seed; 32]).to_protobuf_encoding().unwrap();
        let sealed = crate::identity::encryption::encrypt_identity(&plain, key, &[0; 16], false, true).unwrap();
        std::fs::write(root.join("identity.key"), &sealed).unwrap();
        ks::set_profile(root, key);
        sealed
    }

    /// A slot that takes the key but gives back nothing is no slot: nothing moves.
    #[test]
    fn a_relink_whose_keychain_slot_does_not_read_back_moves_nothing() {
        use crate::identity::platform_keystore::test_support as ks;
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        keychain_root(&root, 0x65, &[0x66; 32]);
        let before = names(&root);
        ks::inject(ks::Fault::ReadBackMissing);
        let relinked = relink_at(&root, DAY);
        ks::clear_faults();
        assert_eq!(relinked.err().as_deref(), Some(KEY_NOT_KEPT));
        assert_eq!(names(&root), before);
        assert!(!tmp.path().join("data-old-2025-10-10").exists());
    }

    /// A keychain identity no stored key opens would be stranded in the kept folder.
    #[test]
    fn a_relink_refuses_a_keychain_identity_no_stored_key_opens() {
        use crate::identity::platform_keystore::test_support as ks;
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        keychain_root(&root, 0x67, &[0x68; 32]);
        ks::delete_profile(&root);
        let before = names(&root);
        assert_eq!(relink_at(&root, DAY).err().as_deref(), Some(KEY_NOT_KEPT));
        assert_eq!(names(&root), before);
    }

    /// A relink a restart finishes copies the kept identity's key to its own slot.
    #[test]
    fn finishing_a_relink_copies_the_key_when_the_kept_slot_is_empty() {
        use crate::identity::platform_keystore::test_support as ks;
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        let key = [0x69; 32];
        let sealed = keychain_root(&root, 0x6a, &key);
        let target = relink_at(&root, DAY).unwrap();
        ks::delete_profile(&target);
        let _ = std::fs::remove_file(target.join("identity.dpapi"));
        put(&root.join(RELINK_JOURNAL), serde_json::to_string(&Journal { target: target.to_string_lossy().into() }).unwrap().as_bytes());

        settle_relink_at(&root);

        assert_eq!(ks::profile_value(&target).as_deref(), Some(&key[..]));
        assert!(crate::identity::platform_keystore::key_that_opens(&target, &sealed).is_some());
        assert!(!root.join(RELINK_JOURNAL).exists());
    }

    /// The copy at a finish does not store: the journal stays and nothing finishes, so
    /// the root's slot, the only one that opens the kept identity, is never given away.
    #[test]
    fn a_relink_finish_whose_key_would_not_store_waits_for_a_later_start() {
        use crate::identity::platform_keystore::test_support as ks;
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        keychain_root(&root, 0x6b, &[0x6c; 32]);
        let target = relink_at(&root, DAY).unwrap();
        ks::delete_profile(&target);
        let _ = std::fs::remove_file(target.join("identity.dpapi"));
        std::fs::remove_file(root.join(RELINK_WELCOME)).unwrap();
        put(&root.join(RELINK_JOURNAL), serde_json::to_string(&Journal { target: target.to_string_lossy().into() }).unwrap().as_bytes());

        ks::inject(ks::Fault::StoreFails);
        settle_relink_at(&root);
        ks::clear_faults();

        assert!(root.join(RELINK_JOURNAL).exists(), "the relink is not over");
        assert!(!root.join(RELINK_WELCOME).exists());
        settle_relink_at(&root);
        assert!(!root.join(RELINK_JOURNAL).exists() && root.join(RELINK_WELCOME).exists());
    }

    /// A relink whose rollback could not finish keeps its journal and origin mark, so
    /// the leftovers are never an unmarked folder a destroy misses.
    #[test]
    fn a_relink_whose_rollback_is_stranded_keeps_its_journal_until_a_settle_finishes() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x6d, 0x6d, "ours");
        put(&root.join("files").join("f.webp"), b"x");
        let target = tmp.path().join("data-old-2025-10-10");

        MOVE_FAULT.with(|f| f.set((2, true)));
        let relinked = relink_at(&root, DAY);
        MOVE_FAULT.with(|f| f.set((usize::MAX, false)));

        assert_eq!(relinked.err().as_deref(), Some(HELD));
        assert!(root.join(RELINK_JOURNAL).exists(), "the journal stays while anything is left over there");
        assert!(target.join(RELINK_ORIGIN).exists() && target.join("messages.db").exists());
        assert_eq!(super::super::storage::IDENTITY_NOT_READY, relink_at(&root, DAY).err().unwrap(), "nothing else starts meanwhile");

        settle_relink_at(&root);

        assert_eq!(who(&root, 0x6d).unwrap(), "ours");
        assert!(!target.exists() && !root.join(RELINK_JOURNAL).exists());
    }

    /// An undo that meets a name the root holds again leaves that entry marked as this
    /// root's old data, which a destroy then erases.
    #[test]
    fn an_undone_relink_keeps_what_the_root_holds_again_marked_for_a_destroy() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x6e, 0x6e, "ours");
        let target = tmp.path().join("data-old-2025-10-10");
        std::fs::create_dir(&target).unwrap();
        put(&target.join(RELINK_ORIGIN), &serde_json::to_vec(&Origin { root: root.to_string_lossy().into() }).unwrap());
        put(&root.join(RELINK_JOURNAL), serde_json::to_string(&Journal { target: target.to_string_lossy().into() }).unwrap().as_bytes());
        put(&target.join("custom_background.img"), b"the old one");
        put(&root.join("custom_background.img"), b"a new one");
        put(&target.join("shares").join("s"), b"x");

        settle_relink_at(&root);

        assert!(!root.join(RELINK_JOURNAL).exists());
        assert!(root.join("shares").join("s").exists(), "what can go back does");
        assert!(target.join(RELINK_ORIGIN).exists(), "what cannot stays marked");
        assert_eq!(erase_kept_aside(&root), std::slice::from_ref(&target));
        assert!(!target.exists());
    }

    /// The log says ids, sizes and times, never what a person named or where they keep it.
    #[test]
    fn diagnostics_hide_names_hosts_links_emails_and_phone_numbers() {
        let lines = [
            ("[HOLLOW-STREAM] Received clinic_results_march.png from x", "clinic_results"),
            ("[HOLLOW-FILE] metadata strip refused \"C:\\Users\\sam\\Pictures\\Beach day 2.jpg\": denied", "Beach day"),
            ("[HOLLOW-WS-STREAM] Failed to open source D:\\Taxes 2026\\return final.pdf: os error 32", "Taxes"),
            ("[updater] Extracting /home/sam/Downloads/hollow-0.12.1.zip into /tmp/x", "sam"),
            ("[HOLLOW-LP] Social adapter for news.example.org failed (timeout)", "example"),
            ("[HOLLOW-FWD] STUN server stun.familyhost.net:3478 did not resolve", "familyhost"),
            ("[friendlyError] Bad: write to sam.smith@mail.example.com failed", "smith"),
            ("[friendlyError] Bad: invite for sammy@mail.example.com failed", "sammy"),
            ("[HOLLOW] note +1 (555) 010-4477 then 555-010-4477 and +447700900123", "4477"),
            ("[HOLLOW] note +447700900123", "900123"),
            ("[HOLLOW-ICE] candidate [::ffff:192.0.2.44]:3478 and ::ffff:192.0.2.45:9", "192.0.2"),
            ("[HOLLOW-FETCH] Connecting to https://hollow.example.net:8443/ws?room=1 now", "hollow.example"),
            ("[HOLLOW-FILE] open \"/home/sam/Secret Plans\" failed", "Plans"),
            ("[HOLLOW] #general got clinic_notes.pdf", "clinic_notes"),
        ];
        for (line, secret) in lines {
            let out = redact(line, &[]);
            assert!(!out.contains(secret), "{secret} leaked from {line:?}: {out}");
        }
        let kept = redact(
            "[1760054400] [HOLLOW-WS] Connecting to wss://relay.anonlisten.com/ws... at 12:00:01 order 1760054400123456 \
             v0.12.1 messages.db hollow_debug.log; panicked at src/node/swarm.rs:123:5 in hollow_core.dll",
            &[],
        );
        for stays in ["wss://relay.anonlisten.com/ws", "12:00:01", "1760054400123456", "[1760054400]", "v0.12.1",
            "messages.db", "hollow_debug.log", "src/node/swarm.rs:123:5", "hollow_core.dll"] {
            assert!(kept.contains(stays), "{stays} is Hollow's own and stays: {kept}");
        }
        let path = redact("[HOLLOW-FILE] SendFile: /home/s/My Docs/a b.pdf mid=m1 size 3", &[]);
        assert_eq!(path, "[HOLLOW-FILE] SendFile: <path> mid=m1 size 3", "a path ends at its file's extension");
        let data = redact("[HOLLOW-STREAM] File f1 complete: C:\\D\\files\\x y.png", &[("C:\\D", "<data>")]);
        assert_eq!(data, "[HOLLOW-STREAM] File f1 complete: <data>/<path>");
    }

    /// A name with no dot in it (a display name, a channel category) slips past the
    /// redaction, so no log line carries one.
    #[test]
    fn no_log_line_carries_a_display_name_or_a_channel_layout() {
        fn sources(dir: &Path, out: &mut Vec<(PathBuf, String)>) {
            for entry in std::fs::read_dir(dir).unwrap().flatten() {
                let path = entry.path();
                if path.is_dir() {
                    sources(&path, out);
                } else if path.extension().is_some_and(|e| e == "rs") {
                    out.push((path.clone(), std::fs::read_to_string(&path).unwrap()));
                }
            }
        }
        const FORBIDDEN: &[&str] = &["display_name", "layout_json"];
        let log_macro = concat!("hollow_", "log!(");
        let mut files = Vec::new();
        sources(&Path::new(env!("CARGO_MANIFEST_DIR")).join("src"), &mut files);
        let mut found = Vec::new();
        for (path, text) in files {
            for (at, _) in text.match_indices(log_macro) {
                let call = &text[at..];
                let call = &call[..call.find(");").unwrap_or(call.len())];
                found.extend(FORBIDDEN.iter().filter(|bad| call.contains(**bad)).map(|bad| format!("{}: {bad}", path.display())));
            }
        }
        assert!(found.is_empty(), "log lines that carry a name: {found:#?}");
    }

    /// Old data that is repaired or linked again keeps saying whose it is: a destroy of
    /// the root finds it, and what it kept aside in turn, at every depth.
    #[test]
    fn old_data_repaired_and_linked_again_is_still_erased_with_its_root() {
        let _g = crate::node::resolver::test_lock();
        let _s = super::super::storage::store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("one");
        root_with(&root, 0x73, 0x74, "a stranger's");
        let old = relink_at(&root, DAY).unwrap();

        let repaired = repair_at(&old, &pass_of(0x73), "dev", DAY).unwrap();
        assert!(old.join(RELINK_ORIGIN).exists(), "a repair left the mark in {}", repaired.folder);
        let older = relink_at(&old, DAY + 86_400_000).unwrap();
        let mark: Origin = serde_json::from_slice(&std::fs::read(older.join(RELINK_ORIGIN)).unwrap()).unwrap();
        assert!(same_path(&mark.root, &old.to_string_lossy()), "the newer folder names the one it came from");
        assert!(old.join(RELINK_ORIGIN).exists(), "a relink left the mark where it was");

        super::super::wipe::destroy_data_root(&root).unwrap();

        assert!(!old.exists() && !older.exists(), "a destroy takes every old data kept aside from the root");
    }

    // md-review-2

    /// A kept folder holding a leftover the erase can never unlink, and no key: the
    /// root's own sweep leftovers never hold the wipe marker, but this one does at
    /// every start, so the profile can never mint or link an identity again.
    #[cfg(windows)]
    #[test]
    fn md_review_2_a_keyless_leftover_in_old_data_never_strands_the_profile() {
        let _g = crate::node::resolver::test_lock();
        let _s = super::super::storage::store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("one");
        root_with(&root, 0x80, 0x80, "ours");
        let old = kept(tmp.path(), "one-old-2025-10-10", &root);
        // A folder the person moved to another drive and linked back (a junction).
        let elsewhere = tmp.path().join("elsewhere");
        put(&elsewhere.join("photo.jpg"), b"a picture");
        let made = std::process::Command::new("cmd")
            .args(["/c", "mklink", "/J"])
            .arg(old.join("files"))
            .arg(&elsewhere)
            .output()
            .unwrap();
        assert!(made.status.success(), "precondition: a junction");
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", &root) };

        super::super::wipe::destroy_data_root(&root).unwrap();
        let first = super::super::storage::perform_pending_wipe();
        let second = super::super::storage::perform_pending_wipe();
        let stranded = root.join(WIPE_MARKER).exists();
        let keys_left = old.join("identity.key").exists();
        let _ = std::fs::remove_dir(old.join("files"));

        assert!(!keys_left, "precondition: the old data's keys are gone");
        assert!(
            !stranded,
            "a key-less leftover in old data keeps the wipe marker at every start ({first:?}, {second:?}): \
             the profile can never get an identity again"
        );
    }

    /// A relink cut short right after the kept folder's keychain slot was written, before
    /// its origin mark: the folder is unmarked, so a destroy (a duress code included)
    /// never finds it, and its slot and blob keep a key that opens the destroyed identity.
    #[test]
    fn md_review_2_a_relink_cut_short_before_its_mark_leaves_no_key_a_destroy_misses() {
        use crate::identity::platform_keystore::test_support as ks;
        let _g = crate::node::resolver::test_lock();
        let _s = super::super::storage::store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        let key = [0x81; 32];
        keychain_root(&root, 0x82, &key);
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", &root) };
        // relink_at's state when the process dies between keep_key_at and the origin mark.
        let target = tmp.path().join("data-old-2025-10-10");
        std::fs::create_dir(&target).unwrap();
        keep_key_at(&target, &key).unwrap();

        settle_relink_at(&root);
        super::super::wipe::destroy_data_root(&root).unwrap();

        assert_eq!(ks::profile_value(&target), None, "the kept folder's slot outlived the destroy of the identity it opens");
        assert!(!target.join("identity.dpapi").exists(), "the kept folder's key blob outlived the destroy");
    }

    /// The root's destroy takes its database (the per-file keys) before the bulk; the
    /// first half over old data leaves the kept database until after the root's sweep.
    #[test]
    fn md_review_2_zeroing_kept_aside_takes_the_database_that_holds_the_file_keys() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x83, 0x83, "ours");
        let old = kept(tmp.path(), "data-old-2025-10-10", &root);
        put(&old.join("messages.db-wal"), b"wal");
        zero_kept_aside(&root);
        assert!(
            !old.join("messages.db").exists() && !old.join("messages.db-wal").exists(),
            "the kept database, which holds the at-rest file keys, waits for the second half"
        );
    }

    /// Old data kept aside from old data, held for a moment while its parent goes: the
    /// parent's origin mark was the only path to it, so the next start's wipe never
    /// finds it again and clears the marker over it.
    #[cfg(windows)]
    #[test]
    fn md_review_2_a_held_file_in_nested_old_data_never_orphans_it() {
        use std::os::windows::fs::OpenOptionsExt;
        let _g = crate::node::resolver::test_lock();
        let _s = super::super::storage::store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("one");
        root_with(&root, 0x84, 0x84, "ours");
        let old = kept(tmp.path(), "one-old-2025-10-10", &root);
        let older = kept(tmp.path(), "one-old-2025-10-10-old-2025-10-11", &old);
        put(&older.join("files").join("f.webp"), b"x");
        let holder = std::fs::OpenOptions::new().read(true).share_mode(0).open(older.join("files").join("f.webp")).unwrap();
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", &root) };

        super::super::wipe::destroy_data_root(&root).unwrap();
        drop(holder);
        let _ = super::super::storage::perform_pending_wipe();

        assert!(
            !older.exists() || root.join(WIPE_MARKER).exists(),
            "nested old data outlived the destroy with the marker gone: {:?}",
            names(&older)
        );
    }

    /// A Dart stack frame's class and method are what a crash report needs most.
    #[test]
    fn md_review_2_diagnostics_keep_a_dart_stack_frames_method() {
        let line = "#5      State.setState (package:flutter/src/widgets/framework.dart:1199:9)\n\
                    #6      Future.wait.<anonymous closure> (dart:async/future.dart:520:12)";
        let out = redact(line, &[]);
        assert!(out.contains("State.setState") && out.contains("Future.wait"), "frames lost their method: {out}");
    }

    /// The POSIX probe sees a lock another process holds, taken the way
    /// `SingleInstanceLock` takes it (fcntl, one byte at 1 << 30). A process never sees
    /// its own fcntl lock, so the test binary runs again as the holder.
    #[cfg(unix)]
    #[test]
    fn the_unix_probe_sees_an_instance_lock_another_process_holds() {
        const HOLD: &str = "HOLLOW_TEST_HOLD_INSTANCE_LOCK";
        if let Ok(dir) = std::env::var(HOLD) {
            hold_instance_lock(Path::new(&dir));
            return;
        }
        let tmp = crate::test_tmp::tempdir().unwrap();
        let dir = tmp.path().join("profile");
        put(&dir.join("hollow.lock"), b"4242");
        assert!(!instance_lock_held(&dir), "control: nobody holds it");
        let mut child = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "api::recovery::tests::the_unix_probe_sees_an_instance_lock_another_process_holds"])
            .args(["--nocapture", "--test-threads=1"])
            .env(HOLD, &dir)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        while !dir.join("ready").exists() && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        let held = instance_lock_held(&dir);
        put(&dir.join("release"), b"1");
        let _ = child.wait();
        assert!(dir.join("ready").exists(), "precondition: the holder took the lock");
        assert!(held, "a lock another process holds reads as held");
        assert!(!instance_lock_held(&dir), "a lock let go reads as free");
    }

    /// The holder half of the test above: takes the lock and keeps it until released.
    #[cfg(unix)]
    fn hold_instance_lock(dir: &Path) {
        use std::os::fd::AsRawFd;
        let file = std::fs::OpenOptions::new().read(true).write(true).open(dir.join("hollow.lock")).unwrap();
        // SAFETY: a plain C struct, for which all zeros is a valid value.
        let mut lock: libc::flock = unsafe { std::mem::zeroed() };
        lock.l_type = libc::F_WRLCK as _;
        lock.l_whence = libc::SEEK_SET as _;
        lock.l_start = INSTANCE_LOCK_BYTE as _;
        lock.l_len = 1;
        // SAFETY: a valid descriptor and a struct the call only reads.
        assert_eq!(unsafe { libc::fcntl(file.as_raw_fd(), libc::F_SETLK, &lock) }, 0, "the holder took the lock");
        put(&dir.join("ready"), b"1");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        while !dir.join("release").exists() && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        drop(file);
    }

    /// A link in old data (a folder moved to another drive and linked back) goes as a
    /// link: the folder is erased, and what the link points at is never touched.
    #[test]
    fn a_link_in_old_data_goes_as_a_link() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x88, 0x88, "ours");
        let old = kept(tmp.path(), "data-old-2025-10-10", &root);
        let elsewhere = tmp.path().join("elsewhere");
        put(&elsewhere.join("photo.jpg"), b"a picture");
        #[cfg(windows)]
        let made = std::process::Command::new("cmd")
            .args(["/c", "mklink", "/J"])
            .arg(old.join("files"))
            .arg(&elsewhere)
            .output()
            .is_ok_and(|o| o.status.success());
        #[cfg(unix)]
        let made = std::os::unix::fs::symlink(&elsewhere, old.join("files")).is_ok();
        assert!(made, "precondition: a link");

        let kept = zero_kept_aside(&root);

        assert!(remove_kept_aside(&kept), "the link goes and the folder with it");
        assert!(!old.exists());
        assert_eq!(std::fs::read(elsewhere.join("photo.jpg")).unwrap(), b"a picture", "what it pointed at stays");
    }

    // md-merge

    /// A key another program holds in old data's landing copy (`.replaced/`) through the
    /// destroy: the boot wipe keeps its marker until a later pass has zeroed it, as it
    /// does for the root's own landing folders.
    #[cfg(windows)]
    #[test]
    fn md_merge_a_held_key_in_old_datas_landing_folder_keeps_the_wipe_marker() {
        use std::os::windows::fs::OpenOptionsExt;
        const FILE_SHARE_READ_DELETE: u32 = 1 | 4;
        let _g = crate::node::resolver::test_lock();
        let _s = super::super::storage::store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("one");
        root_with(&root, 0x89, 0x89, "ours");
        let old = kept(tmp.path(), "one-old-2025-10-10", &root);
        let landed_key = old.join(".replaced").join("identity.key");
        put(&landed_key, b"key material");
        let holder = std::fs::OpenOptions::new().read(true).share_mode(FILE_SHARE_READ_DELETE).open(&landed_key).unwrap();
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", &root) };

        super::super::wipe::destroy_data_root(&root).unwrap();
        let first = super::super::storage::perform_pending_wipe();
        let marker_kept = root.join(WIPE_MARKER).exists();
        drop(holder);
        let second = super::super::storage::perform_pending_wipe();

        assert!(marker_kept, "the marker went while old data's landing copy still held a key ({first:?})");
        assert!(!landed_key.exists(), "the later pass did not take the key ({second:?})");
        assert!(!root.join(WIPE_MARKER).exists(), "the later pass did not finish the wipe");
    }

    /// A kept copy with a rollback journal beside it is read read-only, never as
    /// immutable: an immutable read skips a hot journal and reads a half-written copy.
    #[test]
    fn md_merge_a_kept_copy_with_a_journal_is_never_read_as_immutable() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join("messages.db.unreadable-20251010-000000");
        put(&db, b"db");
        assert!(kept_uri(&db).ends_with("?mode=ro&immutable=1"), "precondition: no journal, immutable");
        put(&tmp.path().join("messages.db.unreadable-20251010-000000-journal"), b"journal");
        let uri = kept_uri(&db);
        assert!(uri.ends_with("?mode=ro"), "a copy with a journal read as immutable: {uri}");
    }

    /// A repair killed after it moved the database and before it stamped the new one:
    /// the next start stamps the link time the repair had read off the identity files,
    /// not its own, so a destroy order issued since the link still counts.
    #[test]
    fn md_merge_a_repair_cut_short_keeps_the_link_time_it_read() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("data");
        root_with(&root, 0x8a, 0x8b, "a stranger's");
        let then = std::time::UNIX_EPOCH + std::time::Duration::from_millis(DAY as u64);
        for name in ["identity.key", "identity.device"] {
            std::fs::File::options().write(true).open(root.join(name)).unwrap().set_modified(then).unwrap();
        }
        REPAIR_CRASH.with(|c| c.set(true));
        let crashed = repair_at(&root, &pass_of(0x8a), "dev", now_ms());
        REPAIR_CRASH.with(|c| c.set(false));
        assert!(crashed.is_err(), "precondition: the repair died");
        assert!(!root.join("messages.db").exists(), "precondition: no database in place");

        // The next start: a new database, stamped as the node's start stamps it.
        let db = root.join("messages.db");
        drop(MessageStore::open(db.to_str().unwrap(), &pass_of(0x8a)).unwrap());
        crate::node::destroy::stamp_device_link(db.to_str().unwrap(), &pass_of(0x8a), "dev");

        let store = MessageStore::open(db.to_str().unwrap(), &pass_of(0x8a)).unwrap();
        let stamp: i64 = store.load_setting(&crate::node::destroy::link_key("dev")).unwrap().unwrap().parse().unwrap();
        assert!(stamp <= DAY, "the start after a cut-short repair stamped its own time: {stamp}");
        assert!(!root.join(crate::node::destroy::REPAIR_LINK_HINT).exists(), "the hint stayed after the stamp");
    }
}
