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

/// Removes everything in `root` but what a wipe keeps. True when nothing else is
/// left; false when something survived, such as a database Windows holds open.
#[frb(ignore)]
pub(crate) fn sweep_root(root: &Path) -> bool {
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

fn destroy_with(root: &Path, outside: &Outside) -> Result<(), String> {
    // 1. The marker first, so a kill halfway through resumes at the next launch.
    std::fs::write(root.join(MARKER), b"1")
        .map_err(|e| format!("Failed to stash the wipe marker: {e}"))?;

    // 2. Keys. Everything else is only as readable as these are.
    for name in KEY_FILES {
        zero_and_remove(&root.join(name));
    }
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
