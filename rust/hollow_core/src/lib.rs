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
mod crdt;
mod crypto;
mod frb_generated;
mod identity;
mod node;
mod storage;
mod vault;
