/// Debug log file for release builds.
///
/// On Windows the log lives next to the executable (legacy layout that the
/// Hollow installer expects). On macOS/Linux it sits in the per-user data
/// directory (`dirs::data_dir()/hollow/`) — keeping the log out of the .app
/// bundle and next to `hollow_crash.log` from the Dart side.
pub(crate) mod log {
    use std::fs::{File, OpenOptions};
    use std::io::Write;
    use std::sync::Mutex;
    use std::sync::OnceLock;

    static LOG_FILE: OnceLock<Mutex<File>> = OnceLock::new();

    fn log_path() -> std::path::PathBuf {
        if cfg!(target_os = "windows") {
            return std::env::current_exe()
                .ok()
                .and_then(|p| p.parent().map(|d| d.join("hollow_debug.log")))
                .unwrap_or_else(|| std::path::PathBuf::from("hollow_debug.log"));
        }

        // Mobile sets the data dir via set_data_dir() (DATA_DIR_OVERRIDE), not the
        // env var. Honor it so the log lands in the same app dir as messages.db
        // (otherwise Rust logs vanish into an inaccessible location on Android).
        if let Ok(dir) = crate::identity::data_dir() {
            return dir.join("hollow_debug.log");
        }

        if let Ok(custom) = std::env::var("HOLLOW_DATA_DIR") {
            let dir = std::path::PathBuf::from(custom);
            let _ = std::fs::create_dir_all(&dir);
            return dir.join("hollow_debug.log");
        }

        if let Some(base) = dirs::data_dir() {
            let dir = base.join("hollow");
            let _ = std::fs::create_dir_all(&dir);
            return dir.join("hollow_debug.log");
        }

        std::path::PathBuf::from("hollow_debug.log")
    }

    pub fn init() {
        let path = log_path();

        // Log rotation: if file exceeds 10MB, keep only the last 2MB.
        const MAX_LOG_SIZE: u64 = 10 * 1024 * 1024;
        const KEEP_SIZE: usize = 2 * 1024 * 1024;
        if let Ok(meta) = std::fs::metadata(&path) {
            if meta.len() > MAX_LOG_SIZE {
                if let Ok(data) = std::fs::read(&path) {
                    let start = data.len().saturating_sub(KEEP_SIZE);
                    // Find the next newline after the cut point to avoid partial lines.
                    let start = data[start..].iter().position(|&b| b == b'\n')
                        .map(|p| start + p + 1)
                        .unwrap_or(start);
                    let _ = std::fs::write(&path, &data[start..]);
                }
            }
        }

        if let Ok(file) = OpenOptions::new().create(true).append(true).open(&path) {
            let _ = LOG_FILE.set(Mutex::new(file));
        }
    }

    pub fn write(msg: &str) {
        eprintln!("{msg}");
        if let Some(file) = LOG_FILE.get() {
            if let Ok(mut f) = file.lock() {
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs();
                let _ = writeln!(f, "[{now}] {msg}");
                let _ = f.flush();
            }
        }
    }
}

/// Log a message to both stderr and the debug log file.
#[macro_export]
macro_rules! hollow_log {
    ($($arg:tt)*) => {
        $crate::log::write(&format!($($arg)*))
    };
}

pub mod api;
mod archive;
mod chat_clock;
/// C-ABI entry point for the iOS Notification Service Extension (disposable-NSE
/// Tier B). Raw `extern "C"`, intentionally OUTSIDE `api` so flutter_rust_bridge
/// codegen never scans it.
pub mod push_enrich;
/// C-ABI + Android JNI surface for DeepFilterNet3 noise suppression, bound at
/// runtime by the forked flutter_webrtc capture-processor ports. Raw
/// `extern "C"`, intentionally OUTSIDE `api` (same rule as `push_enrich`).
pub mod dfn_ffi;
mod crdt;
mod crypto;
mod frb_generated;
/// Headless media forwarder (media forwarding step 3): blind str0m packet
/// relay for SFrame screen-share RTP, deployed as the `hollow-forwarder` bin
/// on the VPS (phase 2 embeds it in-app for peer forwarders). Feature-gated +
/// intentionally OUTSIDE `api` so flutter_rust_bridge codegen never scans it
/// (same rule as `push_enrich`). Public surface = `ForwarderConfig` + `run`
/// only — the bin target can't see the crate's pub(crate) internals.
#[cfg(feature = "forwarder")]
pub mod forwarder;
mod identity;
mod node;
mod sentinel;
mod storage;
mod vault;
