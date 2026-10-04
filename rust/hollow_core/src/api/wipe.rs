//! Destruction: one routine that erases this install, and the scopes that tell the
//! rest of the identity first. Keys die FIRST, nothing waits on the network, and the
//! marker plus `perform_pending_wipe` is the guarantee (wiki `security_write_gates`).
//! Nothing here logs: a line saying a wipe ran is the one thing duress cannot afford.

use std::path::{Path, PathBuf};

use flutter_rust_bridge::frb;

use crate::identity::duress;
use crate::node::NodeCommand;

/// The wipe runs regardless when this elapses: an offline device still erases.
const SIGNAL_BOUND: std::time::Duration = std::time::Duration::from_secs(3);

const MARKER: &str = "pending_wipe.marker";

/// What a destroy writes in the marker, so the boot wipe that finishes it can tell
/// an ended identity (the profile list forgets it) from a cancelled link's throwaway.
pub(crate) const DESTROY_MARK: &[u8] = b"destroy";

/// The recordings this profile made, one absolute path a line. They sit in a folder
/// every profile shares, and the list must still be readable once the keys are gone.
const RECORDINGS: &str = "recordings.list";
const RECORDINGS_FOLDER: &str = "Hollow Recordings";

const KEY_FILES: &[&str] = &[
    "identity.key",
    "identity.device",
    "identity.duress",
    "identity.dpapi",
    "pending_link.code",
    "pending_link.device",
];

/// Plaintext the root holds beside the encrypted store: zeroed before unlinking.
const PLAINTEXT_FILES: &[&str] = &[
    "hollow_debug.log",
    "hollow_crash.log",
    "hollow_crash.log.old",
    "push_debug.log",
    "push_lines.json",
    RECORDINGS,
];

/// What a wipe leaves in the root: the profile registry (app-level config, names
/// only), instance locks, and the marker until the wipe has finished.
fn kept_by_wipe(name: &str) -> bool {
    name == "profiles.json" || name.ends_with(".lock") || name == MARKER
}

/// Hollow's own names in the shared OS temp dir: vault recovery shards, opened
/// archives' attachments, video posters, toast avatars and older pasted images.
fn is_hollow_temp(name: &str) -> bool {
    ["hollow_recovery", "hollow-archive-", "hollow_vthumb_", "hollow_notif_"]
        .iter()
        .any(|p| name.starts_with(p))
        || is_pasted_image(name)
}

/// `clipboard_<ms>.<ext>`, how older versions staged a pasted image.
fn is_pasted_image(name: &str) -> bool {
    let Some((stamp, ext)) = name.strip_prefix("clipboard_").and_then(|r| r.split_once('.'))
    else {
        return false;
    };
    (10..=14).contains(&stamp.len())
        && stamp.bytes().all(|b| b.is_ascii_digit())
        && ["png", "jpg", "gif", "bmp", "webp"].contains(&ext)
}

/// `Hollow_YYYY-MM-DD_HH-MM-SS.mp4`, the name `recording_service.dart` gives one.
fn is_recording_name(name: &str) -> bool {
    let Some(stamp) = name.strip_prefix("Hollow_").and_then(|r| r.strip_suffix(".mp4")) else {
        return false;
    };
    stamp.len() == 19
        && stamp.bytes().enumerate().all(|(i, b)| match i {
            4 | 7 | 13 | 16 => b == b'-',
            10 => b == b'_',
            _ => b.is_ascii_digit(),
        })
}

/// Where Hollow puts a recording: absolute, its own name, directly in a folder
/// named `Hollow Recordings`.
fn is_recording_path(path: &Path) -> bool {
    path.is_absolute()
        && path.file_name().and_then(|n| n.to_str()).is_some_and(is_recording_name)
        && path.parent().and_then(Path::file_name).is_some_and(|n| n == RECORDINGS_FOLDER)
}

/// The recorder's ffmpeg log beside a recording (Linux).
fn recorder_log(recording: &Path) -> PathBuf {
    let mut name = recording.as_os_str().to_owned();
    name.push(".stderr.log");
    PathBuf::from(name)
}

fn read_recordings(root: &Path) -> Vec<PathBuf> {
    std::fs::read_to_string(root.join(RECORDINGS))
        .map(|list| list.lines().filter(|l| !l.is_empty()).map(PathBuf::from).collect())
        .unwrap_or_default()
}

fn write_recordings(root: &Path, recordings: &[PathBuf]) -> std::io::Result<()> {
    let lines: Vec<String> =
        recordings.iter().map(|p| p.to_string_lossy().into_owned()).collect();
    let staged = root.join("recordings.list.tmp");
    std::fs::write(&staged, lines.join("\n"))?;
    std::fs::rename(&staged, root.join(RECORDINGS))
}

/// Unlinks the recordings this profile listed, then each folder they leave empty.
/// Only regular files under Hollow's own names in a real `Hollow Recordings` folder,
/// and never zeroed: gigabytes would hold up a wipe nothing waits on. Returns the
/// ones still held open, such as a recording being written right now.
fn erase_recordings(root: &Path) -> Vec<PathBuf> {
    let mut held = Vec::new();
    let mut folders: Vec<PathBuf> = Vec::new();
    for recording in read_recordings(root) {
        let Some(folder) = recording.parent().filter(|_| is_recording_path(&recording)) else {
            continue;
        };
        if !std::fs::symlink_metadata(folder).is_ok_and(|m| m.is_dir()) {
            continue;
        }
        for path in [recorder_log(&recording), recording.clone()] {
            let regular = std::fs::symlink_metadata(&path).is_ok_and(|m| m.is_file());
            if regular && std::fs::remove_file(&path).is_err() && !held.contains(&recording) {
                held.push(recording.clone());
            }
        }
        if !folders.iter().any(|f| f == folder) {
            folders.push(folder.to_path_buf());
        }
    }
    for folder in folders {
        let _ = std::fs::remove_dir(folder);
    }
    held
}

/// Where Hollow writes beside the data root rather than under it.
#[flutter_rust_bridge::frb(ignore)]
#[derive(Default)]
struct Outside {
    /// Windows keeps the debug log next to the executable.
    exe_dir: Option<PathBuf>,
    /// iOS: the App Group container around the root, home of the extension's
    /// push hints and its own log.
    app_group: Option<PathBuf>,
    /// Shared with other apps, so only Hollow's own names go, and only unlinked:
    /// zeroing through a planted link would write over someone else's file.
    os_temp: Option<PathBuf>,
}

impl Outside {
    fn of_this_process(root: &Path) -> Self {
        // Harness nodes share the machine's temp dir and the test binary's folder.
        if cfg!(test) {
            return Self::default();
        }
        let exe_dir = cfg!(windows)
            .then(|| std::env::current_exe().ok()?.parent().map(Path::to_path_buf))
            .flatten();
        let in_app_group = cfg!(target_os = "ios")
            && root.file_name().is_some_and(|n| n == "hollow_data");
        Self {
            exe_dir,
            app_group: in_app_group.then(|| root.parent().map(Path::to_path_buf)).flatten(),
            os_temp: Some(std::env::temp_dir()),
        }
    }

    fn clear(&self) {
        if let Some(dir) = &self.exe_dir {
            scrub(&dir.join("hollow_debug.log"));
        }
        if let Some(group) = &self.app_group {
            scrub(&group.join("push_hints"));
            scrub(&group.join("push_diag"));
        }
        let Some(Ok(entries)) = self.os_temp.as_ref().map(std::fs::read_dir) else { return };
        for entry in entries.flatten() {
            if !is_hollow_temp(&entry.file_name().to_string_lossy()) {
                continue;
            }
            let path = entry.path();
            let _ = match entry.file_type() {
                Ok(t) if t.is_dir() => std::fs::remove_dir_all(&path),
                _ => std::fs::remove_file(&path),
            };
        }
    }
}

/// Zeroes a regular file before unlinking it. Anything else (a link, a device) is
/// only unlinked, so a write never follows a path out of the folder.
fn zero_and_remove(path: &Path) {
    let Ok(meta) = std::fs::symlink_metadata(path) else { return };
    if meta.is_file() {
        let _ = std::fs::write(path, vec![0u8; meta.len() as usize]);
    }
    let _ = std::fs::remove_file(path);
}

/// [`zero_and_remove`] for every file under `path`, then the folder itself.
fn scrub(path: &Path) {
    match std::fs::symlink_metadata(path) {
        Ok(meta) if meta.is_dir() => {
            if let Ok(entries) = std::fs::read_dir(path) {
                for entry in entries.flatten() {
                    scrub(&entry.path());
                }
            }
            let _ = std::fs::remove_dir_all(path);
        }
        Ok(_) => zero_and_remove(path),
        Err(_) => {}
    }
}

/// Removes everything in `root` but what a wipe keeps, and the recordings it listed.
/// True when nothing else is left; false when something survived, such as a
/// database Windows holds open.
#[frb(ignore)]
pub(crate) fn sweep_root(root: &Path) -> bool {
    let held = erase_recordings(root);
    for name in PLAINTEXT_FILES {
        zero_and_remove(&root.join(name));
    }
    let Ok(entries) = std::fs::read_dir(root) else { return false };
    let mut clean = true;
    for entry in entries.flatten() {
        if kept_by_wipe(&entry.file_name().to_string_lossy()) {
            continue;
        }
        let path = entry.path();
        let gone = match entry.file_type() {
            Ok(t) if t.is_dir() => std::fs::remove_dir_all(&path),
            _ => std::fs::remove_file(&path),
        };
        clean &= gone.is_ok();
    }
    // A recording still being written goes at the next launch, once its writer died.
    if !held.is_empty() {
        let _ = write_recordings(root, &held);
        clean = false;
    }
    clean
}

/// The boot wipe's half of the routine: what Hollow wrote beside the root.
#[frb(ignore)]
pub(crate) fn clear_beside(root: &Path) {
    Outside::of_this_process(root).clear();
}

/// Takes the root explicitly so the harness runs the REAL routine per node.
#[frb(ignore)]
pub(crate) fn destroy_data_root(root: &Path) -> Result<(), String> {
    destroy_with(root, &Outside::of_this_process(root))
}

/// The marker goes first, so a kill halfway through resumes at the next launch.
fn mark_destroy(root: &Path) -> Result<(), String> {
    std::fs::write(root.join(MARKER), DESTROY_MARK)
        .map_err(|e| format!("Failed to stash the wipe marker: {e}"))
}

/// Everything else under a root is only as readable as these are.
fn zero_keys(root: &Path) {
    for name in KEY_FILES {
        zero_and_remove(&root.join(name));
    }
}

fn destroy_with(root: &Path, outside: &Outside) -> Result<(), String> {
    // 1. The marker.
    mark_destroy(root)?;

    // 2. Keys.
    zero_keys(root);
    // TRAP: the keystore is process-wide, not rooted at `root`, and `delete_key`
    // clears the legacy slot too, so a harness run would erase a real credential.
    #[cfg(not(test))]
    let _ = crate::identity::platform_keystore::delete_key();
    crate::identity::encryption::clear_session_key();
    crate::node::at_rest::forget_stores();
    // The log goes with the identity, before anything else can add a line to it.
    crate::log::erase();

    // 3. The per-file keys. Only the singleton closes; the marker covers the rest.
    close_store_singleton();
    for name in ["messages.db", "messages.db-wal", "messages.db-shm"] {
        let _ = std::fs::remove_file(root.join(name));
    }

    // 4. The rest of what Hollow wrote, under the root and beside it.
    let clean = sweep_root(root);
    outside.clear();

    // 5. A finished wipe leaves no marker saying it ran; an unfinished one keeps
    // it, so the next launch completes the job before anything else.
    if clean {
        let _ = std::fs::remove_file(root.join(MARKER));
    }
    Ok(())
}

fn close_store_singleton() {
    if let Ok(mut guard) = super::storage::get_store().lock() {
        *guard = None;
    }
}

/// Scope (a), and the tail of every other. Leaves the node RUNNING for Dart's step 5.
#[frb]
pub fn destroy_local() -> Result<(), String> {
    let root = crate::identity::data_dir()?;
    let out = destroy_data_root(&root);
    // Only once the wipe has actually run: an unacked entry is re-delivered.
    let _ = super::network::send_node_command(NodeCommand::KillAck);
    // The relay stops waking this phone for an identity that is gone.
    let _ = super::network::send_node_command(NodeCommand::UnregisterPushToken);
    out
}

/// Erases a profile this process is not running (Settings, desktop): the same
/// routine against its root, marker and keys first. What belongs to the running
/// process (keystore slots, its log, the shared temp folder) is not touched.
#[frb]
pub fn erase_profile_at(data_dir: String) -> Result<(), String> {
    let root = PathBuf::from(&data_dir);
    if !root.is_absolute() {
        return Err("That folder doesn't look like Hollow data, so it stays.".into());
    }
    if !root.exists() {
        return Ok(());
    }
    if same_folder(&root, &crate::identity::data_dir()?) {
        return Err("Hollow is using that profile right now.".into());
    }
    if !looks_like_a_profile(&root) {
        return Err("That folder doesn't look like Hollow data, so it stays.".into());
    }
    mark_destroy(&root)?;
    zero_keys(&root);
    if sweep_root(&root) {
        let _ = std::fs::remove_file(root.join(MARKER));
    }
    Ok(())
}

fn same_folder(a: &Path, b: &Path) -> bool {
    matches!((a.canonicalize(), b.canonicalize()), (Ok(x), Ok(y)) if x == y)
}

/// An empty folder or one holding an identity, never a folder of somebody else's.
/// A debug log alone proves nothing: on Windows one sits beside the executable.
fn looks_like_a_profile(root: &Path) -> bool {
    let Ok(mut entries) = std::fs::read_dir(root) else { return false };
    entries.next().is_none()
        || ["identity.key", "identity.device", "messages.db", MARKER]
            .iter()
            .any(|name| root.join(name).exists())
}

/// Lists a recording this profile is about to make, so the profile's wipe takes it.
/// Only Hollow's own names in a `Hollow Recordings` folder are accepted; entries no
/// longer on disk drop off.
#[frb]
pub fn remember_recording(path: String) -> Result<(), String> {
    let recording = PathBuf::from(&path);
    if path.contains(['\n', '\r']) || !is_recording_path(&recording) {
        return Err("Not a Hollow recording".into());
    }
    let root = crate::identity::data_dir()?;
    let mut listed: Vec<PathBuf> = read_recordings(&root)
        .into_iter()
        .filter(|p| *p != recording && std::fs::symlink_metadata(p).is_ok())
        .collect();
    listed.push(recording);
    write_recordings(&root, &listed).map_err(|e| format!("Couldn't note the recording: {e}"))
}

/// `scope` is `device` | `device_revoke` | `identity`; its signal never blocks the wipe.
/// `identity` needs the recovery phrase once the identity has one (design ID-1): it is
/// checked BEFORE anything is erased, so a wrong phrase costs nothing.
#[frb]
pub fn destroy_with_scope(
    scope: String,
    notify_friends: bool,
    phrase: Option<String>,
) -> Result<(), String> {
    duress::scope_byte(&scope)?;
    let order = if scope == duress::SCOPE_IDENTITY {
        Some(super::roster::destroy_order(phrase.as_deref(), notify_friends)?)
    } else {
        None
    };
    publish_scope(&scope, order.map(Signal::Order));
    destroy_local()
}

/// What an `identity` scope publishes: an order the phrase signed, or the duress
/// code's permission for this device.
enum Signal {
    Order(crate::node::DestroyIdentity),
    Delegated(crate::node::DestroyDelegation, bool),
}

fn publish_scope(scope: &str, signal: Option<Signal>) {
    match scope {
        duress::SCOPE_DEVICE_REVOKE => {
            let (tx, rx) = tokio::sync::oneshot::channel();
            if super::network::send_node_command(
                NodeCommand::PublishSelfRevocation { reply: tx },
            )
            .is_ok()
            {
                wait_for(rx);
            }
        }
        duress::SCOPE_IDENTITY => {
            let (tx, rx) = tokio::sync::oneshot::channel();
            let cmd = match signal {
                Some(Signal::Order(order)) => Some(NodeCommand::PublishDestroyIdentity {
                    order: Box::new(order),
                    reply: tx,
                }),
                Some(Signal::Delegated(delegation, notify_friends)) => {
                    Some(NodeCommand::PublishDelegatedDestroy { delegation, notify_friends, reply: tx })
                }
                None => None,
            };
            if let Some(cmd) = cmd
                && super::network::send_node_command(cmd).is_ok()
            {
                wait_for(rx);
            }
            let _ = super::network::send_node_command(NodeCommand::UnregisterPushToken);
        }
        _ => {}
    }
}

fn wait_for<T>(rx: tokio::sync::oneshot::Receiver<T>) {
    let rt = super::network::get_runtime();
    let _ = rt.block_on(async { tokio::time::timeout(SIGNAL_BOUND, rx).await });
}

/// Called with the WRONG password by definition, so nothing can be signed and a cold
/// launch destroys locally only. A running node still holds this device's key, which
/// signs under the phrase's permission the slot carries; a legacy identity's master
/// signs alone.
#[frb(ignore)]
pub(crate) fn run_duress(cfg: &duress::DuressConfig) {
    let signal = if cfg.scope == duress::SCOPE_IDENTITY {
        match cfg.permission.as_ref().and_then(super::roster::delegation_from) {
            Some(d) => Some(Signal::Delegated(d, cfg.notify_friends)),
            None => super::roster::destroy_order(None, cfg.notify_friends).ok().map(Signal::Order),
        }
    } else {
        None
    };
    publish_scope(&cfg.scope, signal);
    let _ = destroy_local();
}

/// Drives the conversation banner. `None` = we were never told.
#[frb]
pub fn identity_destroyed_at(master_peer_id: String) -> Option<i64> {
    let store = super::storage::get_store();
    let guard = store.lock().ok()?;
    let ms = guard.as_ref()?;
    let master = super::network::identity_for_persisted(master_peer_id);
    crate::node::destroy::identity_destroyed_at(ms, &master).filter(|v| *v > 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seed_root(root: &Path) {
        for name in KEY_FILES {
            std::fs::write(root.join(name), b"key material").unwrap();
        }
        std::fs::write(root.join("messages.db"), b"ciphertext").unwrap();
        std::fs::write(root.join("profiles.json"), b"{}").unwrap();
        std::fs::write(root.join("hollow.lock"), b"").unwrap();
        std::fs::create_dir_all(root.join("files")).unwrap();
        std::fs::write(root.join("files").join("a.bin"), b"HFE1 ciphertext").unwrap();
    }

    /// Twice must converge, and a kill after the key step still ends clean.
    #[test]
    fn wipe_routine_is_idempotent_and_marker_resumes() {
        let _g = crate::node::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path();
        seed_root(root);

        destroy_data_root(root).expect("first wipe");
        destroy_data_root(root).expect("second wipe is a no-op, not an error");

        for name in KEY_FILES {
            assert!(!root.join(name).exists(), "{name} must be gone");
        }
        assert!(!root.join("files").exists());
        assert!(root.join("profiles.json").exists(), "the profile registry is app config");

        // A kill after the key step: the marker and a file that outlived it.
        std::fs::write(root.join("pending_wipe.marker"), b"1").unwrap();
        std::fs::write(root.join("messages.db"), b"an open file we could not unlink").unwrap();
        // SAFETY: serialized by the crate test lock.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", root) };
        super::super::storage::perform_pending_wipe().expect("boot wipe");

        assert!(!root.join("messages.db").exists(), "the boot wipe finishes the job");
        assert!(!root.join("pending_wipe.marker").exists(), "the marker is cleared last");
        assert!(root.join("profiles.json").exists());
        assert!(root.join("hollow.lock").exists(), "an instance lock survives");
    }

    /// Names under `root` a wipe must not leave, minus what it keeps on purpose.
    fn survivors(root: &Path) -> Vec<String> {
        std::fs::read_dir(root)
            .map(|rd| {
                rd.flatten()
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .filter(|n| n != "profiles.json" && !n.ends_with(".lock"))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// The root holds more than the names the code knows today: push logs, the
    /// notification line cache, a rotated crash log, a backup staging copy. None
    /// may outlive the wipe, and a finished wipe leaves no marker saying it ran.
    #[test]
    fn a_wipe_leaves_nothing_hollow_wrote_under_the_root() {
        let _g = crate::node::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = &tmp.path().join("root");
        std::fs::create_dir_all(root).unwrap();
        seed_root(root);
        for name in [
            "push_debug.log",
            "push_lines.json",
            "hollow_crash.log.old",
            "custom_background.img",
            "hollow-backup-export.hollow",
        ] {
            std::fs::write(root.join(name), b"names and previews").unwrap();
        }

        // A second name for the push log's bytes, outside the root: what the wipe
        // writes over is what a disk image would still hold after an unlink.
        let copy = tmp.path().join("push_debug.link");
        std::fs::hard_link(root.join("push_debug.log"), &copy).unwrap();

        destroy_data_root(root).expect("wipe");

        assert_eq!(survivors(root), Vec::<String>::new(), "the wipe left these behind");
        let left = std::fs::read(&copy).unwrap();
        assert!(left.iter().all(|b| *b == 0), "the push log's bytes outlived the wipe");
    }

    /// Hollow also writes beside the root: the Windows debug log next to the
    /// executable, the iOS extension's hints and log in the App Group, and staged
    /// files in the OS temp dir. The wipe takes all of them, and nothing of
    /// anybody else's in the same folders.
    #[test]
    fn a_wipe_leaves_nothing_hollow_wrote_beside_the_root() {
        let _g = crate::node::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let group = tmp.path().join("group");
        let root = group.join("hollow_data");
        let exe_dir = tmp.path().join("app");
        let os_temp = tmp.path().join("ostemp");
        for dir in [&root, &exe_dir, &os_temp] {
            std::fs::create_dir_all(dir).unwrap();
        }
        seed_root(&root);
        let write = |path: PathBuf| {
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, b"names, ids and previews").unwrap();
        };
        let gone = [
            exe_dir.join("hollow_debug.log"),
            group.join("push_hints").join("hints.json"),
            group.join("push_hints").join("12D3KooWFriend.img"),
            group.join("push_diag").join("nse_metrics.log"),
            os_temp.join("hollow_recovery").join("cid.shard"),
            os_temp.join("hollow-archive-20261004").join("photo.png"),
            os_temp.join("hollow_vthumb_ab12").join("mid.webp"),
            os_temp.join("hollow_notif_77.png"),
            os_temp.join("clipboard_1759600000000.png"),
        ];
        let kept = [
            exe_dir.join("hollow.exe"),
            os_temp.join("other_app.log"),
            os_temp.join("clipboard_notes.png"),
            group.join("someone_elses.txt"),
        ];
        for path in gone.iter().chain(kept.iter()) {
            write(path.clone());
        }
        // The log this process holds open, and the one beside the executable from
        // earlier launches (a duress code at a cold start never opened it).
        crate::log::erase();
        crate::log::open_for_test(root.join("hollow_debug.log"), &root);
        crate::log::write("a line of the identity that is about to go");

        let outside = Outside {
            exe_dir: Some(exe_dir.clone()),
            app_group: Some(group.clone()),
            os_temp: Some(os_temp.clone()),
        };
        destroy_with(&root, &outside).expect("wipe");

        for path in &gone {
            assert!(!path.exists(), "survived the wipe: {}", path.display());
        }
        assert!(!group.join("push_hints").exists() && !group.join("push_diag").exists());
        assert!(!os_temp.join("hollow_recovery").exists());
        assert!(!crate::log::is_open(), "a line written after the wipe would land");
        for path in &kept {
            assert!(path.exists(), "the wipe took what is not Hollow's: {}", path.display());
        }
    }

    fn list_recordings(root: &Path, paths: &[&PathBuf]) {
        let lines: Vec<String> = paths.iter().map(|p| p.display().to_string()).collect();
        std::fs::write(root.join("recordings.list"), lines.join("\n")).unwrap();
    }

    fn touch(path: &Path) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, b"a recording").unwrap();
    }

    /// Recordings live in a folder every profile shares. The wipe takes exactly the
    /// ones this profile listed (with a recorder's log beside one), then a folder
    /// they leave empty; another profile's recordings, anything else in the folder
    /// and a listed path that is not Hollow's own stay.
    #[test]
    fn a_wipe_takes_this_profiles_recordings_and_nothing_else() {
        let _g = crate::node::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("root");
        std::fs::create_dir_all(&root).unwrap();
        seed_root(&root);
        let shared = tmp.path().join("Videos").join("Hollow Recordings");
        let only_ours = tmp.path().join("Movies").join("Hollow Recordings");
        let mine = [
            shared.join("Hollow_2026-10-01_10-00-00.mp4"),
            shared.join("Hollow_2026-10-01_10-00-00.mp4.stderr.log"),
            only_ours.join("Hollow_2026-10-02_11-30-05.mp4"),
        ];
        let theirs = shared.join("Hollow_2026-10-03_09-15-00.mp4");
        let not_hollows = [
            shared.join("holiday.mp4"),
            shared.join("Hollow_2026-10-01.mp4"),
            tmp.path().join("Other").join("Hollow_2026-10-01_10-00-00.mp4"),
        ];
        for path in mine.iter().chain(not_hollows.iter()).chain([&theirs]) {
            touch(path);
        }
        list_recordings(&root, &[&mine[0], &mine[2], &not_hollows[0], &not_hollows[1], &not_hollows[2]]);

        destroy_with(&root, &Outside::default()).expect("wipe");

        for path in &mine {
            assert!(!path.exists(), "this profile's recording survived: {}", path.display());
        }
        assert!(!only_ours.exists(), "a folder only this profile used stays behind");
        for path in not_hollows.iter().chain([&theirs]) {
            assert!(path.exists(), "the wipe took what is not this profile's: {}", path.display());
        }
        assert_eq!(survivors(&root), Vec::<String>::new(), "the list outlived the wipe");
    }

    /// A wipe killed after its key step finishes at the next launch, recordings
    /// included: their list needs no key to read.
    #[test]
    fn the_boot_wipe_takes_the_recordings_after_the_keys_are_gone() {
        let _g = crate::node::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("root");
        std::fs::create_dir_all(&root).unwrap();
        let folder = tmp.path().join("Videos").join("Hollow Recordings");
        let recording = folder.join("Hollow_2026-10-04_08-00-00.mp4");
        touch(&recording);
        list_recordings(&root, &[&recording]);
        std::fs::write(root.join("messages.db"), b"ciphertext nobody can open").unwrap();
        std::fs::write(root.join(MARKER), b"destroy").unwrap();

        // SAFETY: serialized by the crate test lock.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", &root) };
        super::super::storage::perform_pending_wipe().expect("boot wipe");

        assert!(!recording.exists(), "the boot wipe left a recording");
        assert!(!folder.exists(), "the emptied folder stays behind");
        assert_eq!(survivors(&root), Vec::<String>::new());
    }

    /// A recording being written while the wipe runs (a destroy order arriving
    /// mid-call) cannot be unlinked yet: it stays listed and the marker stays, so
    /// the next launch takes it once the recorder is gone.
    #[test]
    fn a_recording_still_being_written_goes_at_the_next_launch() {
        let _g = crate::node::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("root");
        std::fs::create_dir_all(&root).unwrap();
        seed_root(&root);
        let recording =
            tmp.path().join("Videos").join("Hollow Recordings").join("Hollow_2026-10-04_09-00-00.mp4");
        touch(&recording);
        list_recordings(&root, &[&recording]);

        let pin = Pin::hold(&recording);
        destroy_with(&root, &Outside::default()).expect("wipe");
        assert!(root.join(MARKER).exists(), "a held recording must resume at the next launch");
        drop(pin);

        // SAFETY: serialized by the crate test lock.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", &root) };
        assert!(super::super::storage::perform_pending_wipe().expect("boot wipe"));
        assert!(!recording.exists(), "the recording outlived both wipes");
        assert_eq!(survivors(&root), Vec::<String>::new());
    }

    /// The boot wipe says whether it ended an identity: only a destroy makes the
    /// profile list forget the profile, never a cancelled link's throwaway.
    #[test]
    fn the_boot_wipe_tells_a_destroy_from_a_cancelled_link() {
        let _g = crate::node::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("root");
        std::fs::create_dir_all(&root).unwrap();
        seed_root(&root);
        // SAFETY: serialized by the crate test lock.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", &root) };

        let pin = Pin::hold(&root.join("files").join("a.bin"));
        destroy_data_root(&root).expect("wipe");
        drop(pin);
        assert!(super::super::storage::perform_pending_wipe().expect("boot wipe"));

        super::super::storage::stash_pending_wipe().expect("link cancelled");
        assert!(!super::super::storage::perform_pending_wipe().expect("boot wipe"));
    }

    /// Only Hollow's own recording names in a `Hollow Recordings` folder go on the
    /// list, and what is no longer on disk drops off it.
    #[test]
    fn only_hollows_own_recordings_go_on_the_list() {
        let _g = crate::node::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("root");
        std::fs::create_dir_all(&root).unwrap();
        // SAFETY: serialized by the crate test lock.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", &root) };
        let folder = tmp.path().join("Videos").join("Hollow Recordings");
        let first = folder.join("Hollow_2026-10-04_10-00-00.mp4");
        let second = folder.join("Hollow_2026-10-04_11-00-00.mp4");

        for refused in [
            folder.join("notes.txt"),
            folder.join("Hollow_2026-10-04.mp4"),
            tmp.path().join("Documents").join("Hollow_2026-10-04_10-00-00.mp4"),
            PathBuf::from("Hollow Recordings").join("Hollow_2026-10-04_10-00-00.mp4"),
        ] {
            let path = refused.display().to_string();
            assert!(remember_recording(path.clone()).is_err(), "listed {path}");
        }
        let smuggled = format!("{}\n{}", tmp.path().join("victim").display(), first.display());
        assert!(remember_recording(smuggled).is_err(), "a second line rode in");
        assert!(!root.join(RECORDINGS).exists());

        remember_recording(first.display().to_string()).expect("first");
        remember_recording(second.display().to_string()).expect("second");
        assert_eq!(read_recordings(&root), vec![second.clone()], "a recording never written stays listed");

        touch(&second);
        remember_recording(first.display().to_string()).expect("first again");
        assert_eq!(read_recordings(&root), vec![second, first]);
    }

    /// Erasing a profile this process is not running takes that profile's keys, data
    /// and recordings, keeps the registry, and refuses the running profile and a
    /// folder of somebody else's files.
    #[test]
    fn erasing_another_profile_takes_its_recordings_and_refuses_the_running_one() {
        let _g = crate::node::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let running = tmp.path().join("running");
        let other = tmp.path().join("other");
        let stranger = tmp.path().join("stranger");
        for dir in [&running, &other, &stranger] {
            std::fs::create_dir_all(dir).unwrap();
        }
        seed_root(&running);
        seed_root(&other);
        std::fs::write(stranger.join("thesis.docx"), b"somebody's work").unwrap();
        let recording =
            tmp.path().join("Videos").join("Hollow Recordings").join("Hollow_2026-10-04_12-00-00.mp4");
        touch(&recording);
        list_recordings(&other, &[&recording]);
        // SAFETY: serialized by the crate test lock.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", &running) };

        assert!(erase_profile_at(running.display().to_string()).is_err());
        assert!(running.join("identity.key").exists(), "the running profile was touched");
        assert!(erase_profile_at(stranger.display().to_string()).is_err());
        assert!(stranger.join("thesis.docx").exists());
        // The Windows install folder: the debug log sits beside the executable.
        let install = tmp.path().join("install");
        std::fs::create_dir_all(&install).unwrap();
        std::fs::write(install.join("hollow_debug.log"), b"log").unwrap();
        std::fs::write(install.join("hollow.exe"), b"MZ").unwrap();
        assert!(erase_profile_at(install.display().to_string()).is_err());
        assert!(install.join("hollow.exe").exists(), "the install folder was swept");

        erase_profile_at(other.display().to_string()).expect("erase");
        assert_eq!(survivors(&other), Vec::<String>::new());
        assert!(other.join("profiles.json").exists(), "the registry is every profile's");
        assert!(!other.join(MARKER).exists(), "a finished erase leaves no marker");
        assert!(!recording.exists(), "the erased profile's recording survived");
    }

    /// Something the wipe could not remove (Windows keeps an open database) keeps
    /// the marker, so the next launch finishes the job before anything else.
    #[test]
    fn an_unfinished_wipe_keeps_its_marker() {
        let _g = crate::node::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path();
        seed_root(root);
        let held = root.join("files").join("a.bin");
        let pin = Pin::hold(&held);

        destroy_data_root(root).expect("wipe");
        assert!(root.join(MARKER).exists(), "an unfinished wipe must resume at the next launch");
        drop(pin);
    }

    /// Makes `path` impossible to unlink while held.
    struct Pin {
        #[cfg(windows)]
        _file: std::fs::File,
        #[cfg(unix)]
        dir: PathBuf,
    }

    impl Pin {
        fn hold(path: &Path) -> Self {
            #[cfg(windows)]
            {
                use std::os::windows::fs::OpenOptionsExt;
                let _file = std::fs::OpenOptions::new().read(true).share_mode(0).open(path).unwrap();
                Self { _file }
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let dir = path.parent().unwrap().to_path_buf();
                std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o500)).unwrap();
                Self { dir }
            }
        }
    }

    #[cfg(unix)]
    impl Drop for Pin {
        fn drop(&mut self) {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&self.dir, std::fs::Permissions::from_mode(0o700));
        }
    }

    /// The logs must never say a wipe ran or a duress code was typed: the wipe
    /// routine and the boot wipe log nothing, and no log line anywhere names duress.
    #[test]
    fn no_log_line_tells_of_a_wipe_or_a_duress_code() {
        let log_macro = concat!("hollow_", "log!");
        let wipe = include_str!("wipe.rs").replace("\r\n", "\n");
        let routine = wipe.split("#[cfg(test)]").next().expect("the routine");
        assert!(!routine.contains(log_macro), "api/wipe.rs writes a log line");

        let storage = include_str!("storage.rs").replace("\r\n", "\n");
        let boot = storage.split("pub fn perform_pending_wipe(").nth(1).expect("boot wipe");
        let boot = &boot[..boot.find("\n}\n").expect("end of perform_pending_wipe")];
        assert!(!boot.contains(log_macro), "perform_pending_wipe writes a log line");

        let mut named = Vec::new();
        let src = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        for (path, text) in rust_sources(&src) {
            for (n, line) in text.lines().enumerate() {
                if line.contains(log_macro) && line.to_lowercase().contains("duress") {
                    named.push(format!("{}:{}", path.display(), n + 1));
                }
            }
        }
        assert!(named.is_empty(), "log lines that name duress: {named:?}");
    }

    /// The debug log is the file people send for support: it names no person,
    /// server, channel or file, and never a device-link code or its secret half.
    #[test]
    fn log_lines_name_no_person_place_file_or_link_code() {
        const FORBIDDEN: &[&str] = &[
            "{display_name", "{nickname", "{server_name", "{channel_name", "{original_name",
            "{file_name", "{new_name", "{code}", "code={", "'{name}'", "({name},", ": {name} (",
        ];
        let log_macro = concat!("hollow_", "log!(");
        let src = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut found = Vec::new();
        for (path, text) in rust_sources(&src) {
            let mut rest = text.as_str();
            while let Some(at) = rest.find(log_macro) {
                let call = &rest[at..];
                let call = &call[..call.find(");").unwrap_or(call.len())];
                for bad in FORBIDDEN {
                    if call.contains(bad) {
                        found.push(format!("{}: {bad}", path.display()));
                    }
                }
                rest = &rest[at + log_macro.len()..];
            }
        }
        assert!(found.is_empty(), "log lines that name people, places, files or codes: {found:#?}");
    }

    fn rust_sources(dir: &Path) -> Vec<(std::path::PathBuf, String)> {
        let mut out = Vec::new();
        for entry in std::fs::read_dir(dir).expect("src dir").flatten() {
            let path = entry.path();
            if path.is_dir() {
                out.extend(rust_sources(&path));
            } else if path.extension().is_some_and(|e| e == "rs") {
                out.push((path.clone(), std::fs::read_to_string(&path).unwrap_or_default()));
            }
        }
        out
    }
}
