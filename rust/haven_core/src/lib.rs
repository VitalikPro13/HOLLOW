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
mod crypto;
mod frb_generated;
mod identity;
mod node;
mod storage;
