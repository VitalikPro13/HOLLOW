/// Debug log file for release builds. On Windows it lives next to the executable
/// (the layout the installer expects), elsewhere in the per-user data directory
/// next to the Dart side's `hollow_crash.log`. It exists only while an identity
/// does: a wiped or never-used install keeps no line saying it was used.
pub(crate) mod log {
    use std::fs::{File, OpenOptions};
    use std::io::Write;
    use std::path::{Path, PathBuf};
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicBool, Ordering};

    struct Open {
        path: PathBuf,
        file: File,
    }

    static LOG_FILE: Mutex<Option<Open>> = Mutex::new(None);
    /// Set while a file is open, so a line with nowhere to go takes no lock.
    static OPEN: AtomicBool = AtomicBool::new(false);

    /// Release builds keep stderr quiet: a desktop session's journal keeps what
    /// an app prints, outside anything a wipe can reach.
    static STDERR: AtomicBool = AtomicBool::new(cfg!(debug_assertions));

    fn log_path() -> PathBuf {
        if cfg!(target_os = "windows") {
            return std::env::current_exe()
                .ok()
                .and_then(|p| p.parent().map(|d| d.join("hollow_debug.log")))
                .unwrap_or_else(|| PathBuf::from("hollow_debug.log"));
        }

        // Mobile sets the data dir via set_data_dir(), not the env var; honor it or
        // Rust logs vanish into an inaccessible location on Android.
        if let Ok(dir) = crate::identity::data_dir() {
            return dir.join("hollow_debug.log");
        }

        if let Ok(custom) = std::env::var("HOLLOW_DATA_DIR") {
            let dir = PathBuf::from(custom);
            let _ = std::fs::create_dir_all(&dir);
            return dir.join("hollow_debug.log");
        }

        if let Some(base) = dirs::data_dir() {
            let dir = base.join("hollow");
            let _ = std::fs::create_dir_all(&dir);
            return dir.join("hollow_debug.log");
        }

        PathBuf::from("hollow_debug.log")
    }

    /// An identity lives in `root` and no wipe is waiting on it.
    pub(crate) fn holds_identity(root: &Path) -> bool {
        root.join("identity.key").exists() && !root.join("pending_wipe.marker").exists()
    }

    fn slot() -> std::sync::MutexGuard<'static, Option<Open>> {
        LOG_FILE.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn init() {
        let Ok(root) = crate::identity::data_dir() else { return };
        open_at(log_path(), &root);
    }

    fn open_at(path: PathBuf, root: &Path) {
        let mut slot = slot();
        if slot.is_some() || !holds_identity(root) {
            return;
        }

        const MAX_LOG_SIZE: u64 = 10 * 1024 * 1024;
        const KEEP_SIZE: usize = 2 * 1024 * 1024;
        if let Ok(meta) = std::fs::metadata(&path) {
            if meta.len() > MAX_LOG_SIZE {
                if let Ok(data) = std::fs::read(&path) {
                    let start = data.len().saturating_sub(KEEP_SIZE);
                    // Cut at a newline so the file never starts mid-line.
                    let start = data[start..].iter().position(|&b| b == b'\n')
                        .map(|p| start + p + 1)
                        .unwrap_or(start);
                    let _ = std::fs::write(&path, &data[start..]);
                }
            }
        }

        if let Ok(file) = OpenOptions::new().create(true).append(true).open(&path) {
            *slot = Some(Open { path, file });
            OPEN.store(true, Ordering::Release);
        }
    }

    /// The headless forwarder's only log is stderr, which the relay box keeps in a
    /// RAM-only journal.
    #[cfg(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios"))))]
    pub fn mirror_to_stderr() {
        STDERR.store(true, Ordering::Relaxed);
    }

    pub fn write(msg: &str) {
        // Never eprintln!: it panics when stderr cannot be written, and on
        // Linux a closed terminal leaves the app alive (SIGHUP is ignored)
        // with a dead pty, so every log line would panic the task that logs.
        if STDERR.load(Ordering::Relaxed) {
            let _ = writeln!(std::io::stderr().lock(), "{msg}");
        }
        if !OPEN.load(Ordering::Acquire) {
            return;
        }
        if let Some(open) = slot().as_mut() {
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs();
            let _ = writeln!(open.file, "[{now}] {msg}");
            let _ = open.file.flush();
        }
    }

    /// The wipe's step: what the log holds is gone, and no later line lands until
    /// an identity exists again.
    pub(crate) fn erase() {
        let mut slot = slot();
        OPEN.store(false, Ordering::Release);
        let Some(Open { path, file }) = slot.take() else { return };
        drop(slot);
        let _ = file.set_len(0);
        drop(file);
        let _ = std::fs::remove_file(&path);
    }

    #[cfg(test)]
    pub(crate) fn open_for_test(path: PathBuf, root: &Path) {
        open_at(path, root);
    }

    #[cfg(test)]
    pub(crate) fn is_open() -> bool {
        slot().is_some()
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        /// A root with no identity keeps no log, so a wiped install shows no use.
        #[test]
        fn the_log_exists_only_while_an_identity_does() {
            let _g = crate::node::resolver::test_lock();
            erase();
            let tmp = crate::test_tmp::tempdir().unwrap();
            let log = tmp.path().join("hollow_debug.log");

            open_for_test(log.clone(), tmp.path());
            write("a line before any identity");
            assert!(!is_open() && !log.exists(), "no identity, no log");

            std::fs::write(tmp.path().join("identity.key"), b"key").unwrap();
            std::fs::write(tmp.path().join("pending_wipe.marker"), b"1").unwrap();
            open_for_test(log.clone(), tmp.path());
            assert!(!is_open() && !log.exists(), "a wipe pending is no identity");

            std::fs::remove_file(tmp.path().join("pending_wipe.marker")).unwrap();
            open_for_test(log.clone(), tmp.path());
            write("a line with an identity");
            assert!(std::fs::read_to_string(&log).unwrap().contains("with an identity"));

            std::fs::remove_file(tmp.path().join("identity.key")).unwrap();
            erase();
            write("a line after the wipe");
            assert!(!log.exists(), "the wipe takes the log with it");
            open_for_test(log.clone(), tmp.path());
            write("a line from a push after the wipe");
            assert!(!is_open() && !log.exists(), "nothing reopens it once the identity is gone");
        }
    }
}

/// Log a message to the debug log file, and to stderr in debug builds.
#[macro_export]
macro_rules! hollow_log {
    ($($arg:tt)*) => {
        $crate::log::write(&format!($($arg)*))
    };
}

pub mod api;
mod archive;
mod audio_peaks;
mod chat_clock;
/// C-ABI entry point for the iOS Notification Service Extension. Raw `extern "C"`,
/// intentionally OUTSIDE `api` so flutter_rust_bridge codegen never scans it.
pub mod push_enrich;
/// C-ABI + Android JNI surface for DeepFilterNet3 noise suppression, bound at
/// runtime by the forked flutter_webrtc capture processors. Outside `api` for the
/// same reason as `push_enrich`.
pub mod dfn_ffi;
mod crdt;
mod crypto;
mod frb_generated;
/// Media forwarder: blind str0m packet relay for SFrame screen-share RTP, run
/// headless on the VPS and embedded in desktop builds. Feature- AND desktop-gated
/// (the flag reaches mobile cargokit builds, its deps do not) and outside `api` so
/// codegen never scans it. Public surface is `ForwarderConfig` + `run`, which is
/// all the bin target can see of the crate.
#[cfg(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios"))))]
pub mod forwarder;
/// `.hollowpack`, the artist shop's art container: the format, the encoders and the
/// ONE verification both the CLI and the importer run. Public so the `hollowpack`
/// bin can link it through the rlib, outside `api` so codegen never scans it.
pub mod hollowpack;
mod identity;
mod node;
mod sentinel;
mod storage;
#[cfg(test)]
mod test_tmp;
mod vault;
