/// Debug log file for release builds. On Windows it lives next to the executable
/// (the layout the installer expects), elsewhere in the per-user data directory
/// next to the Dart side's `hollow_crash.log`.
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

        // Mobile sets the data dir via set_data_dir(), not the env var; honor it or
        // Rust logs vanish into an inaccessible location on Android.
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
mod vault;
