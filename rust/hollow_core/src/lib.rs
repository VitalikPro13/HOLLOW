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
        // Tests log into their own data dir: beside the test binary, parallel test
        // processes would share and erase one file.
        if cfg!(target_os = "windows") && !cfg!(test) {
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

    /// Where this process's log file is, or would be.
    pub(crate) fn path() -> PathBuf {
        log_path()
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
        // Every line, Rust's and Dart's alike, names no account folder.
        let msg = redact_line(msg);
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

    /// A person's file as the log names it: its kind, never its folder or its name.
    pub(crate) fn redact_file(path: impl AsRef<std::ffi::OsStr>) -> String {
        let ext = Path::new(path.as_ref())
            .extension()
            .and_then(|e| e.to_str())
            .filter(|e| e.len() <= 8 && e.bytes().all(|b| b.is_ascii_alphanumeric()));
        match ext {
            Some(ext) => format!("<file .{}>", ext.to_ascii_lowercase()),
            None => "<file>".to_string(),
        }
    }

    fn redact_line(msg: &str) -> std::borrow::Cow<'_, str> {
        if msg.contains(['/', '\\']) {
            std::borrow::Cow::Owned(redact_path(msg))
        } else {
            std::borrow::Cow::Borrowed(msg)
        }
    }

    /// One of the app's own paths as the log names it, the account folder hidden the
    /// way the diagnostics export hides it.
    pub(crate) fn redact_path(path: impl AsRef<std::ffi::OsStr>) -> String {
        let text = Path::new(path.as_ref()).to_string_lossy().into_owned();
        let lower = text.to_ascii_lowercase();
        let mut out = String::with_capacity(text.len());
        let mut at = 0;
        while at < text.len() {
            let next = ["/users/", "/home/", ":\\users\\"]
                .iter()
                .filter_map(|m| lower[at..].find(m).map(|i| (at + i + m.len(), *m)))
                .min();
            let Some((start, marker)) = next else { break };
            // A Windows account name may hold spaces; a Unix one ends where the line's words do.
            let windows = marker.starts_with(':');
            let end = text[start..]
                .find(|c: char| {
                    matches!(c, '/' | '\\' | '"' | '\'')
                        || (!windows && (c.is_whitespace() || matches!(c, ',' | ')' | ']' | ':' | ';')))
                })
                .map_or(text.len(), |i| start + i);
            out.push_str(&text[at..start]);
            out.push('~');
            at = end;
        }
        out.push_str(&text[at..]);
        out
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
    pub(crate) fn open_path() -> Option<PathBuf> {
        slot().as_ref().map(|open| open.path.clone())
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        /// A person's file leaves only its kind in the log, an app path only its shape.
        #[test]
        fn a_logged_path_names_no_person_and_no_file() {
            assert_eq!(redact_file("/Users/jabun/Documents/secret plan.PDF"), "<file .pdf>");
            assert_eq!(redact_file("C:\\Users\\Jabun\\notes"), "<file>");
            assert_eq!(redact_file("a.<script>"), "<file>");
            assert_eq!(redact_path("C:\\Users\\Jabun\\AppData\\Hollow"), "C:\\Users\\~\\AppData\\Hollow");
            assert_eq!(redact_path("/home/alice/.var/app/x and /Users/bob"), "/home/~/.var/app/x and /Users/~");
            assert_eq!(redact_path("/opt/hollow/bundle"), "/opt/hollow/bundle");
        }

        /// Every line the log writes hides the account folders it names, whoever
        /// formatted it: Rust's own lines and the ones Dart hands over alike.
        #[test]
        fn every_written_line_hides_the_account_folder() {
            let _g = crate::node::resolver::test_lock();
            erase();
            let tmp = crate::test_tmp::tempdir().unwrap();
            std::fs::write(tmp.path().join("identity.key"), b"key").unwrap();
            let log = tmp.path().join("hollow_debug.log");
            open_for_test(log.clone(), tmp.path());
            write("[PORTABLE] data root: /Users/alice/Hollow, backup C:\\Users\\Bob Smith\\AppData\\x");
            crate::api::network::log_from_dart("[DART] home /home/carol and done".into());
            let text = std::fs::read_to_string(&log).unwrap();
            erase();
            for name in ["alice", "Bob Smith", "carol"] {
                assert!(!text.contains(name), "the log named the account {name}: {text}");
            }
            assert!(text.contains("/Users/~/Hollow,") && text.contains("/home/~ and done"), "{text}");
        }

        /// The words a log argument names a path or a file by.
        fn names_a_path(ident: &str) -> bool {
            let last = ident.rsplit('.').next().unwrap_or(ident).trim_start_matches(['&', '*']);
            let word = last.rsplit('_').next().unwrap_or(last);
            matches!(word, "path" | "dir" | "dest" | "name" | "file" | "filename")
        }

        /// The body of each `hollow_log!` call in `text`, parentheses balanced outside
        /// string literals.
        fn log_calls(text: &str) -> Vec<&str> {
            let opener = concat!("hollow_log", "!(");
            let mut out = Vec::new();
            let mut rest = text;
            while let Some(i) = rest.find(opener) {
                let body = &rest[i + opener.len()..];
                let (mut depth, mut in_str, mut esc, mut end) = (1usize, false, false, body.len());
                for (j, c) in body.char_indices() {
                    match (in_str, c) {
                        (true, _) if esc => esc = false,
                        (true, '\\') => esc = true,
                        (true, '"') => in_str = false,
                        (true, _) => {}
                        (false, '"') => in_str = true,
                        (false, '(') => depth += 1,
                        (false, ')') => {
                            depth -= 1;
                            if depth == 0 {
                                end = j;
                                break;
                            }
                        }
                        _ => {}
                    }
                }
                out.push(&body[..end]);
                rest = &body[end..];
            }
            out
        }

        /// `call` with every `redact_path(..)` and `redact_file(..)` cut out, then split
        /// into its string literals and the code between them.
        fn split_call(call: &str) -> (Vec<String>, String) {
            let mut code = call.to_string();
            for wrap in ["redact_path(", "redact_file("] {
                while let Some(i) = code.find(wrap) {
                    let mut depth = 0usize;
                    let mut end = code.len();
                    for (j, c) in code[i + wrap.len() - 1..].char_indices() {
                        match c {
                            '(' => depth += 1,
                            ')' => {
                                depth -= 1;
                                if depth == 0 {
                                    end = i + wrap.len() - 1 + j + 1;
                                    break;
                                }
                            }
                            _ => {}
                        }
                    }
                    code.replace_range(i..end, "R");
                }
            }
            let (mut lits, mut outside, mut cur, mut in_str, mut esc) = (Vec::new(), String::new(), String::new(), false, false);
            for c in code.chars() {
                if in_str {
                    if esc {
                        esc = false;
                    } else if c == '\\' {
                        esc = true;
                    } else if c == '"' {
                        in_str = false;
                        lits.push(std::mem::take(&mut cur));
                        continue;
                    }
                    cur.push(c);
                } else if c == '"' {
                    in_str = true;
                } else {
                    outside.push(c);
                }
            }
            (lits, outside)
        }

        /// No log line formats a path or a person's file name raw: a format argument
        /// named for a path, a folder, a file or a name, or a path rendered with
        /// `display()` or `to_string_lossy`, goes through `redact_file` or `redact_path`.
        #[test]
        fn no_log_line_writes_a_raw_path() {
            // App-owned names, never a person's: data-root entries and a flag.
            let allowed = [("recovery.rs", "name"), ("file_handler.rs", "store_full_file")];
            let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
            let mut stack = vec![src];
            let mut found = Vec::new();
            while let Some(dir) = stack.pop() {
                for entry in std::fs::read_dir(&dir).unwrap().flatten() {
                    let p = entry.path();
                    if p.is_dir() {
                        stack.push(p);
                        continue;
                    }
                    let name = p.file_name().unwrap().to_string_lossy().into_owned();
                    if !name.ends_with(".rs") || name == "test_harness.rs" || name == "frb_generated.rs" {
                        continue;
                    }
                    let text = std::fs::read_to_string(&p).unwrap().replace("\r\n", "\n");
                    for call in log_calls(&text) {
                        let (lits, outside) = split_call(call);
                        let mut idents: Vec<String> = Vec::new();
                        for lit in &lits {
                            for piece in lit.split('{').skip(1) {
                                let id: String = piece.chars().take_while(|c| c.is_alphanumeric() || *c == '_' || *c == '.').collect();
                                if !id.is_empty() && piece[id.len()..].starts_with(['}', ':']) {
                                    idents.push(id);
                                }
                            }
                        }
                        for arg in outside.split(',').skip(1) {
                            let arg = arg.trim();
                            if !arg.is_empty() && arg.chars().all(|c| c.is_alphanumeric() || matches!(c, '_' | '.' | '&' | '*')) {
                                idents.push(arg.to_string());
                            }
                        }
                        for id in idents.iter().filter(|id| names_a_path(id)) {
                            if !allowed.iter().any(|(f, a)| *f == name && a == id) {
                                found.push(format!("{name}: {{{id}}}"));
                            }
                        }
                        if outside.contains("to_string_lossy") || outside.contains("display()") {
                            found.push(format!("{name}: a path rendered raw"));
                        }
                    }
                }
            }
            assert!(found.is_empty(), "log lines that write a raw path or file name: {found:?}");
        }

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
