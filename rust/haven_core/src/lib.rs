/// Debug log file for release builds. Writes to `haven_debug.log` next to the executable.
pub(crate) mod log {
    use std::fs::{File, OpenOptions};
    use std::io::Write;
    use std::sync::Mutex;
    use std::sync::OnceLock;

    static LOG_FILE: OnceLock<Mutex<File>> = OnceLock::new();

    pub fn init() {
        let path = std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|d| d.join("haven_debug.log")))
            .unwrap_or_else(|| std::path::PathBuf::from("haven_debug.log"));

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
macro_rules! haven_log {
    ($($arg:tt)*) => {
        $crate::log::write(&format!($($arg)*))
    };
}

pub mod api;
mod crdt;
mod crypto;
mod frb_generated;
mod identity;
mod node;
mod storage;
