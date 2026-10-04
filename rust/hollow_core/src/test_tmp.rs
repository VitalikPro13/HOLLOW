//! Test temp dirs, all under ONE root (`HOLLOW_TEST_TMP`, else `{temp}/hollow-tests`)
//! whose stale leftovers the first use in a process sweeps.

use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::{Duration, Instant, SystemTime};

/// The sweep removes only this prefix, so a root on a shared folder loses nothing else.
const PREFIX: &str = "hollow-test-";

/// Longer than any run: nextest kills a hung test after 10 minutes.
const STALE_AFTER: Duration = Duration::from_secs(3 * 60 * 60);

/// How long a removal waits for the last handle inside to close.
const RELEASE_WAIT: Duration = Duration::from_secs(10);

/// A task finishing its last poll at shutdown can recreate a data root (`files_dir()`).
const SHUTDOWN_SETTLE: Duration = Duration::from_millis(100);

/// A temp dir that outlives every handle inside it. Windows cannot delete an open file
/// (`TempDir` then gives up silently), and tasks a test spawned hold files until their
/// runtime shuts down, so a dir dropped inside a multi-thread runtime goes then.
pub(crate) struct TestDir {
    path: PathBuf,
}

impl TestDir {
    pub(crate) fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TestDir {
    fn drop(&mut self) {
        let path = std::mem::take(&mut self.path);
        // A current-thread runtime drops its tasks on this thread: parking could stall the holder.
        if let Ok(rt) = tokio::runtime::Handle::try_current()
            && rt.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread
        {
            let doomed = RemoveAtShutdown(path);
            rt.spawn(async move {
                let _doomed = doomed;
                std::future::pending::<()>().await
            });
            return;
        }
        remove_when_released(&path, Duration::ZERO);
    }
}

/// Parked in a never-ending task; the runtime's drop waits for it, so it ends before the test.
struct RemoveAtShutdown(PathBuf);

impl Drop for RemoveAtShutdown {
    fn drop(&mut self) {
        remove_when_released(&self.0, SHUTDOWN_SETTLE);
    }
}

/// `tempfile::tempdir()` under the test root.
pub(crate) fn tempdir() -> std::io::Result<TestDir> {
    let dir = tempfile::Builder::new().prefix(PREFIX).tempdir_in(root())?;
    Ok(TestDir { path: dir.keep() })
}

/// Removes `path` once its last handle closes, until it has stayed gone for `settle`.
fn remove_when_released(path: &Path, settle: Duration) {
    let deadline = Instant::now() + RELEASE_WAIT;
    let mut gone_since: Option<Instant> = None;
    while Instant::now() < deadline {
        match std::fs::remove_dir_all(path) {
            Ok(()) if settle.is_zero() => return,
            Ok(()) => gone_since = Some(Instant::now()),
            Err(e) if e.kind() == ErrorKind::NotFound => {
                if gone_since.get_or_insert_with(Instant::now).elapsed() >= settle {
                    return;
                }
            }
            Err(_) => gone_since = None,
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn root() -> &'static Path {
    static ROOT: OnceLock<PathBuf> = OnceLock::new();
    ROOT.get_or_init(|| {
        let root = std::env::var_os("HOLLOW_TEST_TMP")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| std::env::temp_dir().join("hollow-tests"));
        std::fs::create_dir_all(&root).expect("test temp root");
        sweep_stale(&root, SystemTime::now());
        root
    })
}

/// Never leaves `root`: a link's own metadata is not a dir, and `remove_dir_all` removes
/// links, not their targets.
fn sweep_stale(root: &Path, now: SystemTime) {
    let Ok(entries) = std::fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        if !entry.file_name().to_string_lossy().starts_with(PREFIX) {
            continue;
        }
        let path = entry.path();
        let Ok(meta) = path.symlink_metadata() else {
            continue;
        };
        if !meta.is_dir() {
            continue;
        }
        let stale = meta
            .modified()
            .ok()
            .and_then(|at| now.duration_since(at).ok())
            .is_some_and(|age| age > STALE_AFTER);
        if stale {
            let _ = std::fs::remove_dir_all(&path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn later(hours: u64) -> SystemTime {
        SystemTime::now() + Duration::from_secs(hours * 60 * 60)
    }

    /// SQLite opens without delete sharing, as a node's store actors do.
    fn open_db(dir: &Path) -> rusqlite::Connection {
        let db = rusqlite::Connection::open(dir.join("messages.db")).unwrap();
        db.execute_batch("PRAGMA journal_mode = WAL; CREATE TABLE t (x INTEGER)")
            .unwrap();
        db
    }

    #[test]
    fn sweep_removes_only_our_stale_dirs() {
        let parent = tempdir().unwrap();
        let root = parent.path();
        let ours = root.join(format!("{PREFIX}old"));
        let foreign = root.join(".tmpForeign");
        std::fs::create_dir_all(ours.join("files")).unwrap();
        std::fs::write(ours.join("files").join("messages.db"), b"x").unwrap();
        std::fs::create_dir_all(&foreign).unwrap();

        sweep_stale(root, SystemTime::now());
        assert!(ours.exists(), "a fresh dir belongs to a running test");

        sweep_stale(root, later(4));
        assert!(!ours.exists(), "a dir older than the cutoff must be swept");
        assert!(
            foreign.exists(),
            "the sweep must never touch what it did not make"
        );
    }

    #[test]
    fn sweep_never_follows_a_link_out_of_the_root() {
        let parent = tempdir().unwrap();
        let outside = tempdir().unwrap();
        std::fs::write(outside.path().join("keep.txt"), b"x").unwrap();
        let link = parent.path().join(format!("{PREFIX}link"));
        #[cfg(unix)]
        std::os::unix::fs::symlink(outside.path(), &link).unwrap();
        // A junction, the link kind any Windows account may create; mklink refuses '/'
        // separators, which a HOLLOW_TEST_TMP written with them brings in.
        #[cfg(windows)]
        assert!(
            std::process::Command::new("cmd")
                .args(["/C", "mklink", "/J"])
                .arg(link.to_string_lossy().replace('/', "\\"))
                .arg(outside.path().to_string_lossy().replace('/', "\\"))
                .output()
                .unwrap()
                .status
                .success()
        );

        sweep_stale(parent.path(), later(4));
        assert!(
            outside.path().join("keep.txt").exists(),
            "the sweep followed a link"
        );
    }

    #[test]
    fn a_dir_goes_once_a_handle_closed_late_lets_go() {
        let dir = tempdir().unwrap();
        let path = dir.path().to_path_buf();
        let db = open_db(&path);
        let closer = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(200));
            drop(db);
        });

        drop(dir);
        closer.join().unwrap();
        assert!(
            !path.exists(),
            "the dir must go once its last handle closes"
        );
    }

    #[test]
    fn a_dir_dropped_in_a_runtime_goes_after_the_tasks_holding_it() {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .build()
            .unwrap();
        let path = rt.block_on(async {
            let dir = tempdir().unwrap();
            let db = open_db(dir.path());
            tokio::spawn(async move {
                let _db = db;
                std::future::pending::<()>().await
            });
            dir.path().to_path_buf()
        });
        drop(rt);
        assert!(
            !path.exists(),
            "the dir must go when its runtime shuts down"
        );
    }

    /// A test making its own `tempfile` dir leaks it again on Windows, silently.
    #[test]
    fn every_test_temp_dir_comes_from_here() {
        let needles = ["tempfile::", "TempDir::new("];
        let mut dirs = vec![Path::new(env!("CARGO_MANIFEST_DIR")).join("src")];
        let (mut files, mut hits) = (0usize, Vec::new());
        while let Some(dir) = dirs.pop() {
            for path in std::fs::read_dir(&dir).unwrap().map(|e| e.unwrap().path()) {
                if path.is_dir() {
                    dirs.push(path);
                } else if path.extension().is_some_and(|e| e == "rs")
                    && !path.ends_with("test_tmp.rs")
                {
                    files += 1;
                    let src = std::fs::read_to_string(&path).unwrap();
                    for (n, line) in src.lines().enumerate() {
                        if needles.iter().any(|needle| line.contains(needle)) {
                            hits.push(format!("{}:{}", path.display(), n + 1));
                        }
                    }
                }
            }
        }
        assert!(
            files > 100,
            "the scan must see the crate, saw {files} files"
        );
        assert!(
            hits.is_empty(),
            "make test temp dirs with crate::test_tmp::tempdir(): {hits:#?}"
        );
    }
}
