//! Warm connections to the message store while a node's event loop runs. A fresh
//! SQLCipher open re-parses the whole schema under a shared lock (about 0.6 ms on an
//! M4, several on a phone) while a read on a warm connection costs microseconds, so
//! node code leases instead (`node/store_open_floor.rs` holds it there) and the loop
//! opens the store only to fill its pool.

use std::collections::HashMap;
use std::ops::Deref;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

use subtle::ConstantTimeEq;
use zeroize::Zeroizing;

use super::MessageStore;

/// Connections kept per path between calls: nesting on the loop goes about two deep. A
/// phone keeps one fewer.
const MAX_IDLE: usize = if cfg!(any(target_os = "android", target_os = "ios")) { 2 } else { 3 };

/// The page cache an idle connection may keep (each may grow to 8 MB). Reads on a warm
/// connection stay cheap with less, because what a fresh open costs is the schema.
const IDLE_CACHE_BYTES: i64 = 2 << 20;

/// The file a connection opened, so a pooled one never outlives a deleted or replaced
/// database. Windows cannot unlink an open database, so the path alone is enough there.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
struct FileId(u64, u64);

fn file_id(path: &str) -> Option<FileId> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        std::fs::metadata(path).ok().map(|m| FileId(m.dev(), m.ino()))
    }
    #[cfg(not(unix))]
    {
        std::fs::metadata(path).ok().map(|_| FileId(0, 0))
    }
}

struct Pool {
    generation: u64,
    passphrase: Zeroizing<String>,
    idle: Vec<(MessageStore, FileId)>,
}

impl Pool {
    fn takes(&self, passphrase: &str) -> bool {
        self.passphrase.len() == passphrase.len()
            && bool::from(self.passphrase.as_bytes().ct_eq(passphrase.as_bytes()))
    }
}

static POOLS: Mutex<Option<HashMap<String, Pool>>> = Mutex::new(None);
static GENERATION: AtomicU64 = AtomicU64::new(1);

fn with_pools<T>(f: impl FnOnce(&mut HashMap<String, Pool>) -> T) -> T {
    let mut pools = POOLS.lock().unwrap_or_else(|e| e.into_inner());
    f(pools.get_or_insert_with(HashMap::new))
}

/// Pooling for one path, for as long as the event loop on it holds this.
pub(crate) struct PoolOpen {
    path: String,
    generation: u64,
}

/// Starts pooling `path`. A newer call replaces an older pool on the same path, and an
/// older holder's drop never closes the newer one.
pub(crate) fn enable(path: &str, passphrase: &str) -> PoolOpen {
    let generation = GENERATION.fetch_add(1, Ordering::Relaxed);
    let replaced = with_pools(|pools| {
        pools.insert(
            path.to_string(),
            Pool { generation, passphrase: Zeroizing::new(passphrase.to_string()), idle: Vec::new() },
        )
    });
    drop(replaced);
    PoolOpen { path: path.to_string(), generation }
}

impl Drop for PoolOpen {
    fn drop(&mut self) {
        let closed = with_pools(|pools| match pools.get(&self.path) {
            Some(pool) if pool.generation == self.generation => pools.remove(&self.path),
            _ => None,
        });
        drop(closed);
    }
}

/// Closes every pooled connection, for a wipe that must unlink the database.
pub(crate) fn close_all() {
    let closed = with_pools(std::mem::take);
    drop(closed);
}

/// A connection for one call: warm from the pool while a loop runs on the path, else
/// a fresh open closed on drop, exactly as `MessageStore::open`.
pub(crate) struct StoreLease {
    store: Option<MessageStore>,
    home: Option<(String, u64, FileId)>,
}

impl Deref for StoreLease {
    type Target = MessageStore;
    fn deref(&self) -> &MessageStore {
        self.store.as_ref().expect("a lease holds its store until dropped")
    }
}

impl Drop for StoreLease {
    /// Back to the pool only unchanged: same pool, same file, no open transaction or read.
    fn drop(&mut self) {
        let (Some(store), Some((path, generation, file))) = (self.store.take(), self.home.take()) else {
            return;
        };
        if store.in_transaction() || file_id(&path) != Some(file) {
            return;
        }
        if store.cache_used() > IDLE_CACHE_BYTES {
            store.release_cache();
        }
        let rejected = with_pools(|pools| match pools.get_mut(&path) {
            Some(pool) if pool.generation == generation && pool.idle.len() < MAX_IDLE => {
                pool.idle.push((store, file));
                None
            }
            _ => Some(store),
        });
        drop(rejected);
    }
}

impl MessageStore {
    /// [`MessageStore::open`] for one call; see [`StoreLease`].
    pub(crate) fn lease(path: &str, passphrase: &str) -> Result<StoreLease, String> {
        #[cfg(test)]
        let _leasing = meter::ForPool::enter();
        #[cfg(test)]
        if meter::pool_off() {
            return MessageStore::open(path, passphrase).map(|store| StoreLease { store: Some(store), home: None });
        }
        let current = file_id(path);
        let found = with_pools(|pools| {
            let pool = pools.get_mut(path).filter(|p| p.takes(passphrase))?;
            let (fit, stale): (Vec<_>, Vec<_>) =
                std::mem::take(&mut pool.idle).into_iter().partition(|(_, f)| Some(*f) == current);
            pool.idle = fit;
            Some((pool.generation, pool.idle.pop(), stale))
        });
        let Some((generation, warm, stale)) = found else {
            return MessageStore::open(path, passphrase).map(|store| StoreLease { store: Some(store), home: None });
        };
        drop(stale);
        if let Some((store, file)) = warm {
            #[cfg(test)]
            meter::note_warm();
            return Ok(StoreLease { store: Some(store), home: Some((path.to_string(), generation, file)) });
        }
        let store = MessageStore::open(path, passphrase)?;
        #[cfg(test)]
        tests::after_open(path);
        // Pooled only when the path named one file before and after the open, so the id
        // is the opened file's: a file swapped in meanwhile would vouch for an old one.
        let home = file_id(path).filter(|after| Some(*after) == current).map(|file| (path.to_string(), generation, file));
        Ok(StoreLease { store: Some(store), home })
    }
}

/// Test-only: which opens ran on an event loop, and how long its polls held the thread.
#[cfg(test)]
pub(crate) mod meter {
    use std::cell::{Cell, RefCell};
    use std::collections::HashMap;
    use std::future::Future;
    use std::pin::Pin;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::{Arc, Mutex};
    use std::task::{Context, Poll};
    use std::time::Instant;

    #[derive(Default, Debug)]
    pub(crate) struct LoopMeter {
        pub polls: AtomicU64,
        pub busy_ns: AtomicU64,
        pub max_poll_ns: AtomicU64,
        pub polls_over_1ms: AtomicU64,
        pub polls_over_5ms: AtomicU64,
        /// Opens on the loop not made for the pool: the floor this track keeps at zero.
        pub direct_opens: AtomicU64,
        /// Opens on the loop a lease made: no warm connection waited, or no pool for the
        /// path (the harness's share handler reads the global data dir, not the node's).
        pub pool_opens: AtomicU64,
        pub open_ns: AtomicU64,
        pub warm_leases: AtomicU64,
        /// Where the first direct open came from, for the failure message.
        pub first_direct: Mutex<Option<String>>,
    }

    impl LoopMeter {
        pub(crate) fn summary(&self) -> String {
            let get = |a: &AtomicU64| a.load(Ordering::Relaxed);
            format!(
                "polls={} busy_ms={:.1} max_poll_ms={:.2} polls>1ms={} polls>5ms={} direct_opens={} pool_opens={} open_ms={:.1} warm_leases={}{}",
                get(&self.polls),
                get(&self.busy_ns) as f64 / 1e6,
                get(&self.max_poll_ns) as f64 / 1e6,
                get(&self.polls_over_1ms),
                get(&self.polls_over_5ms),
                get(&self.direct_opens),
                get(&self.pool_opens),
                get(&self.open_ns) as f64 / 1e6,
                get(&self.warm_leases),
                self.first_direct.lock().unwrap_or_else(|e| e.into_inner()).as_deref().map(|b| format!("\nfirst direct open at:\n{b}")).unwrap_or_default(),
            )
        }

        pub(crate) fn add(&self, other: &LoopMeter) {
            let pairs = [
                (&self.polls, &other.polls),
                (&self.busy_ns, &other.busy_ns),
                (&self.polls_over_1ms, &other.polls_over_1ms),
                (&self.polls_over_5ms, &other.polls_over_5ms),
                (&self.direct_opens, &other.direct_opens),
                (&self.pool_opens, &other.pool_opens),
                (&self.open_ns, &other.open_ns),
                (&self.warm_leases, &other.warm_leases),
            ];
            for (mine, theirs) in pairs {
                mine.fetch_add(theirs.load(Ordering::Relaxed), Ordering::Relaxed);
            }
            self.max_poll_ns.fetch_max(other.max_poll_ns.load(Ordering::Relaxed), Ordering::Relaxed);
        }
    }

    thread_local! {
        static CURRENT: RefCell<Option<Arc<LoopMeter>>> = const { RefCell::new(None) };
        static FOR_POOL: Cell<bool> = const { Cell::new(false) };
    }

    static METERS: Mutex<Option<HashMap<String, Arc<LoopMeter>>>> = Mutex::new(None);

    /// The meter of the loop on `db_path` (harness nodes), created on first ask.
    pub(crate) fn for_path(db_path: &str) -> Arc<LoopMeter> {
        let mut meters = METERS.lock().unwrap_or_else(|e| e.into_inner());
        meters.get_or_insert_with(HashMap::new).entry(db_path.to_string()).or_default().clone()
    }

    /// Starts every meter again from zero.
    pub(crate) fn reset_all() {
        let mut meters = METERS.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(map) = meters.as_mut() {
            for m in map.values_mut() {
                *m = Arc::new(LoopMeter::default());
            }
        }
    }

    pub(crate) fn pool_off() -> bool {
        std::env::var("HOLLOW_STORE_POOL_OFF").is_ok_and(|v| v == "1")
    }

    pub(crate) struct ForPool;
    impl ForPool {
        pub(crate) fn enter() -> ForPool {
            FOR_POOL.with(|f| f.set(true));
            ForPool
        }
    }
    impl Drop for ForPool {
        fn drop(&mut self) {
            FOR_POOL.with(|f| f.set(false));
        }
    }

    pub(crate) fn note_warm() {
        CURRENT.with(|c| {
            if let Some(m) = c.borrow().as_ref() {
                m.warm_leases.fetch_add(1, Ordering::Relaxed);
            }
        });
    }

    /// Called by `MessageStore::open` with how long the open took.
    pub(crate) fn note_open(took_ns: u64) {
        let for_pool = FOR_POOL.with(|f| f.get());
        CURRENT.with(|c| {
            if let Some(m) = c.borrow().as_ref() {
                if for_pool {
                    m.pool_opens.fetch_add(1, Ordering::Relaxed);
                } else if m.direct_opens.fetch_add(1, Ordering::Relaxed) == 0 {
                    let trace = std::backtrace::Backtrace::force_capture().to_string();
                    let ours: Vec<&str> = trace
                        .lines()
                        .filter(|l| l.contains("hollow_core::node::") && !l.contains('<'))
                        .take(8)
                        .collect();
                    *m.first_direct.lock().unwrap_or_else(|e| e.into_inner()) = Some(ours.join("\n"));
                }
                m.open_ns.fetch_add(took_ns, Ordering::Relaxed);
            }
        });
    }

    /// Wraps an event loop so each poll is timed and opens inside it are counted.
    pub(crate) struct OnLoop<F> {
        inner: F,
        db_path: String,
    }

    impl<F> OnLoop<F> {
        pub(crate) fn new(inner: F, db_path: &str) -> Self {
            OnLoop { inner, db_path: db_path.to_string() }
        }
    }

    impl<F: Future + Unpin> Future for OnLoop<F> {
        type Output = F::Output;
        fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<F::Output> {
            let meter = for_path(&self.db_path);
            let outer = CURRENT.with(|c| c.replace(Some(meter.clone())));
            let start = Instant::now();
            let out = Pin::new(&mut self.inner).poll(cx);
            let took = start.elapsed().as_nanos() as u64;
            CURRENT.with(|c| *c.borrow_mut() = outer);
            meter.polls.fetch_add(1, Ordering::Relaxed);
            meter.busy_ns.fetch_add(took, Ordering::Relaxed);
            meter.max_poll_ns.fetch_max(took, Ordering::Relaxed);
            if took > 1_000_000 {
                meter.polls_over_1ms.fetch_add(1, Ordering::Relaxed);
            }
            if took > 5_000_000 {
                meter.polls_over_5ms.fetch_add(1, Ordering::Relaxed);
            }
            out
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PASS: &str = "7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a";

    type AfterOpen = Option<Box<dyn Fn(&str)>>;
    thread_local! {
        static AFTER_OPEN: std::cell::RefCell<AfterOpen> = const { std::cell::RefCell::new(None) };
    }

    /// Runs the hook a test set, between a pool miss's open and its file check.
    pub(super) fn after_open(path: &str) {
        AFTER_OPEN.with(|hook| {
            if let Some(hook) = hook.borrow().as_ref() {
                hook(path);
            }
        });
    }

    #[cfg(unix)]
    fn replace_file(path: &str) {
        for suffix in ["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{path}{suffix}"));
        }
        drop(MessageStore::open(path, PASS).unwrap());
    }

    /// `close_all` reaches every pool in the process, harness nodes' included, so these
    /// tests take the harness's turn.
    fn db() -> (std::sync::MutexGuard<'static, ()>, crate::test_tmp::TestDir, String) {
        let turn = crate::node::resolver::test_lock();
        let dir = crate::test_tmp::tempdir().expect("tmp");
        let path = dir.path().join("pool.db").to_string_lossy().to_string();
        drop(MessageStore::open(&path, PASS).expect("create"));
        (turn, dir, path)
    }

    fn idle(path: &str) -> usize {
        with_pools(|pools| pools.get(path).map_or(0, |p| p.idle.len()))
    }

    fn same_connection(a: &MessageStore, b: &MessageStore) -> bool {
        std::ptr::eq(a.raw_handle(), b.raw_handle())
    }

    #[test]
    fn a_running_loop_reuses_one_connection() {
        let (_turn, _dir, path) = db();
        let _pool = enable(&path, PASS);
        let first = MessageStore::lease(&path, PASS).unwrap();
        let handle = first.raw_handle();
        drop(first);
        let again = MessageStore::lease(&path, PASS).unwrap();
        assert!(std::ptr::eq(again.raw_handle(), handle), "the second call opened a new connection");
    }

    #[test]
    fn without_a_loop_every_lease_is_a_fresh_connection() {
        let (_turn, _dir, path) = db();
        drop(MessageStore::lease(&path, PASS).unwrap());
        assert_eq!(idle(&path), 0, "a path with no loop kept a connection open");
        let pool = enable(&path, PASS);
        drop(MessageStore::lease(&path, PASS).unwrap());
        assert_eq!(idle(&path), 1);
        drop(pool);
        assert_eq!(idle(&path), 0, "the loop's end left a connection open");
        drop(MessageStore::lease(&path, PASS).unwrap());
        assert_eq!(idle(&path), 0, "a lease after the loop ended kept its connection");
    }

    #[test]
    fn nested_leases_get_their_own_connections() {
        let (_turn, _dir, path) = db();
        let _pool = enable(&path, PASS);
        let outer = MessageStore::lease(&path, PASS).unwrap();
        let inner = MessageStore::lease(&path, PASS).unwrap();
        assert!(!same_connection(&outer, &inner));
        drop(inner);
        drop(outer);
        assert_eq!(idle(&path), 2);
    }

    #[test]
    fn a_connection_left_in_a_transaction_is_closed_not_reused() {
        let (_turn, _dir, path) = db();
        let _pool = enable(&path, PASS);
        let lease = MessageStore::lease(&path, PASS).unwrap();
        lease.begin_transaction().unwrap();
        lease.save_setting("pool_probe", "uncommitted").unwrap();
        drop(lease);
        assert_eq!(idle(&path), 0, "a connection inside a transaction went back to the pool");
        let next = MessageStore::lease(&path, PASS).unwrap();
        assert_eq!(next.load_setting("pool_probe").unwrap(), None, "the next call saw an uncommitted write");
    }

    #[test]
    fn a_connection_holding_a_read_open_is_closed_not_reused() {
        let (_turn, _dir, path) = db();
        let _pool = enable(&path, PASS);
        let lease = MessageStore::lease(&path, PASS).unwrap();
        lease.hold_a_read_open_for_test();
        drop(lease);
        assert_eq!(idle(&path), 0, "a connection pinned to an old snapshot went back to the pool");
    }

    // Windows cannot unlink a database a connection holds open.
    #[cfg(unix)]
    #[test]
    fn a_replaced_database_file_is_never_served_from_the_pool() {
        let (_turn, dir, path) = db();
        let _pool = enable(&path, PASS);
        let lease = MessageStore::lease(&path, PASS).unwrap();
        lease.save_setting("pool_probe", "old file").unwrap();
        drop(lease);
        assert_eq!(idle(&path), 1);
        for suffix in ["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{path}{suffix}"));
        }
        drop(MessageStore::open(&path, PASS).unwrap());
        let next = MessageStore::lease(&path, PASS).unwrap();
        assert_eq!(next.load_setting("pool_probe").unwrap(), None, "a connection to the deleted file answered");
        drop(next);
        drop(dir);
    }

    // Windows cannot unlink a database a connection holds open.
    #[cfg(unix)]
    #[test]
    fn a_lease_whose_file_was_replaced_meanwhile_never_comes_back() {
        let (_turn, _dir, path) = db();
        let _pool = enable(&path, PASS);
        let lease = MessageStore::lease(&path, PASS).unwrap();
        for suffix in ["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{path}{suffix}"));
        }
        drop(MessageStore::open(&path, PASS).unwrap());
        drop(lease);
        assert_eq!(idle(&path), 0, "a connection to the deleted file went back to the pool");
    }

    // Windows cannot unlink a database a connection holds open.
    #[cfg(unix)]
    #[test]
    fn a_file_swapped_in_during_the_open_never_vouches_for_the_old_one() {
        let (_turn, _dir, path) = db();
        MessageStore::open(&path, PASS).unwrap().save_setting("pool_probe", "old file").unwrap();
        let _pool = enable(&path, PASS);
        AFTER_OPEN.with(|hook| *hook.borrow_mut() = Some(Box::new(|p: &str| replace_file(p))));
        let lease = MessageStore::lease(&path, PASS);
        AFTER_OPEN.with(|hook| *hook.borrow_mut() = None);
        drop(lease.unwrap());
        assert_eq!(idle(&path), 0, "a connection to the replaced file joined the pool");
        let next = MessageStore::lease(&path, PASS).unwrap();
        assert_eq!(next.load_setting("pool_probe").unwrap(), None, "a connection to the replaced file answered");
    }

    #[test]
    fn an_idle_connection_keeps_at_most_its_cache_budget() {
        let (_turn, _dir, path) = db();
        let _pool = enable(&path, PASS);
        let lease = MessageStore::lease(&path, PASS).unwrap();
        for i in 0..3000 {
            lease.save_setting(&format!("k{i}"), &"x".repeat(1000)).unwrap();
        }
        for i in 0..3000 {
            lease.load_setting(&format!("k{i}")).unwrap();
        }
        assert!(lease.cache_used() > IDLE_CACHE_BYTES, "precondition: the cache outgrew the budget");
        drop(lease);
        let back = MessageStore::lease(&path, PASS).unwrap();
        assert!(back.cache_used() <= IDLE_CACHE_BYTES, "an idle connection kept {} bytes of cache", back.cache_used());
    }

    #[test]
    fn another_passphrase_never_gets_a_pooled_connection() {
        let (_turn, _dir, path) = db();
        let _pool = enable(&path, PASS);
        drop(MessageStore::lease(&path, PASS).unwrap());
        assert_eq!(idle(&path), 1);
        let wrong = "ab".repeat(32);
        let other = MessageStore::lease(&path, &wrong);
        assert!(other.is_err() || other.unwrap().load_setting("x").is_err(), "a wrong key read the store");
        assert_eq!(idle(&path), 1);
    }

    #[test]
    fn an_older_loops_end_never_closes_a_newer_loops_pool() {
        let (_turn, _dir, path) = db();
        let old = enable(&path, PASS);
        let stale = MessageStore::lease(&path, PASS).unwrap();
        let _new = enable(&path, PASS);
        drop(old);
        drop(MessageStore::lease(&path, PASS).unwrap());
        assert_eq!(idle(&path), 1, "the old loop's end closed the new pool");
        drop(stale);
        assert_eq!(idle(&path), 1, "a connection from the old pool joined the new one");
    }

    #[test]
    fn the_pool_keeps_at_most_max_idle_connections() {
        let (_turn, _dir, path) = db();
        let _pool = enable(&path, PASS);
        let held: Vec<_> = (0..MAX_IDLE + 2).map(|_| MessageStore::lease(&path, PASS).unwrap()).collect();
        drop(held);
        assert_eq!(idle(&path), MAX_IDLE);
    }

    #[test]
    fn a_destroy_closes_the_running_nodes_connections() {
        let (_turn, dir, _) = db();
        let path = dir.path().join("messages.db").to_string_lossy().to_string();
        drop(MessageStore::open(&path, PASS).unwrap());
        let _pool = enable(&path, PASS);
        drop(MessageStore::lease(&path, PASS).unwrap());
        assert_eq!(idle(&path), 1);
        crate::api::wipe::destroy_data_root(dir.path()).unwrap();
        assert_eq!(idle(&path), 0, "a destroy left the node's connections open on the database");
    }

    #[test]
    fn close_all_drops_every_pooled_connection() {
        let (_turn, _dir, path) = db();
        let _pool = enable(&path, PASS);
        let held = MessageStore::lease(&path, PASS).unwrap();
        drop(MessageStore::lease(&path, PASS).unwrap());
        close_all();
        assert_eq!(idle(&path), 0);
        drop(held);
        assert_eq!(idle(&path), 0, "a lease out during the wipe came back to a closed pool");
    }
}
