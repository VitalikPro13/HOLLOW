use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::{mpsc, oneshot, watch};

use super::mls_storage::MlsSave;
use crate::node::frame_auth::{LIVE_SKEW_MS, NONCE_LEN};
use super::olm_manager::{SessionVersion, StoredSession};
use crate::storage::MessageStore;

/// Commands the swarm task can send to persist crypto state.
pub(crate) enum CryptoStoreCmd {
    SaveAccount(String),
    /// `saved` hears what became of the save, for a frame that waits on it.
    SaveSession { peer_id: String, pickle: String, version: SessionVersion, saved: Option<watch::Sender<Saved>> },
    DeleteSession { peer_id: String },
    SaveReadMark { peer_id: String, sealed_ms: i64 },
    /// A live frame the replay guard saw first, kept until it turns stale; `placed` is
    /// the master of a sender we know (see [`LiveNonceSink::note`]).
    NoteLiveNonce { sender: String, nonce: [u8; NONCE_LEN], expires_ms: i64, placed: Option<String> },
    PruneLiveNonces { now_ms: i64 },
    /// The live-frame nonces still fresh at `now_ms`; the reply closes unanswered when
    /// they cannot be read.
    ReadLiveNonces { now_ms: i64, reply: oneshot::Sender<Vec<(String, Vec<u8>, i64)>> },
    /// The MLS rows changed since the last save; `saved` as for a session save.
    SaveMls { save: MlsSave, saved: Option<watch::Sender<Saved>> },
    /// The stored sessions that came further than `held`, and every read mark.
    ReadNewer { held: HashMap<String, SessionVersion>, reply: oneshot::Sender<Newer> },
    /// Answered once everything queued before it was written.
    Flush(oneshot::Sender<()>),
}

/// What the store holds past this process: sessions another process saved while this
/// one sat suspended, and every read mark.
#[derive(Debug, Default)]
pub(crate) struct Newer {
    pub sessions: Vec<StoredSession>,
    pub read_marks: Vec<(String, i64)>,
}

/// What became of one session save.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Saved {
    Pending,
    /// On disk.
    Stored,
    /// The store already held a copy that came as far or further.
    Refused,
    Failed,
}

/// One state save a frame waits for before it may leave the process (AR-30): a frame
/// on the wire whose Olm session or MLS group state a crash can lose would let the
/// next encrypt after a restart reuse its message key.
#[derive(Clone, Debug)]
pub(crate) struct SessionSaved(watch::Receiver<Saved>);

impl SessionSaved {
    /// What became of the save, `Pending` when it did not settle `within`.
    pub(crate) async fn settled(mut self, within: Duration) -> Saved {
        match tokio::time::timeout(within, self.0.wait_for(|s| *s != Saved::Pending)).await {
            Ok(Ok(outcome)) => *outcome,
            Ok(Err(_)) => Saved::Failed,
            Err(_) => Saved::Pending,
        }
    }

    /// A save that can never settle as stored: nothing could be queued.
    pub(crate) fn failed() -> Self {
        Self(watch::channel(Saved::Failed).1)
    }

    /// TEST-ONLY: a save already on disk.
    #[cfg(test)]
    pub(crate) fn stored_for_test() -> Self {
        Self(watch::channel(Saved::Stored).1)
    }
}

/// One MLS save a frame waits for, numbered by its take: once it landed, the group
/// state of every frame encrypted before it was taken is on disk.
#[derive(Clone, Debug)]
pub(crate) struct MlsSaved {
    saved: SessionSaved,
    take: u64,
}

impl MlsSaved {
    /// [`super::MlsManager::taken`] when this save was taken.
    pub(crate) fn take(&self) -> u64 {
        self.take
    }

    /// What became of the save, `Pending` when it did not settle `within`.
    pub(crate) async fn settled(&self, within: Duration) -> Saved {
        self.saved.clone().settled(within).await
    }

    /// Save number `take`, which could not be built or queued.
    pub(crate) fn failed(take: u64) -> Self {
        Self { saved: SessionSaved::failed(), take }
    }

    fn now(&self) -> Saved {
        *self.saved.0.borrow()
    }

    /// TEST-ONLY: save number `take`, already on disk.
    #[cfg(test)]
    pub(crate) fn stored_for_test(take: u64) -> Self {
        Self { saved: SessionSaved::stored_for_test(), take }
    }

    /// TEST-ONLY: save number `take`, settled through the returned sender.
    #[cfg(test)]
    pub(crate) fn pending_for_test(take: u64) -> (watch::Sender<Saved>, Self) {
        let (tx, rx) = watch::channel(Saved::Pending);
        (tx, Self { saved: SessionSaved(rx), take })
    }
}

/// What the node and the actor share of the MLS saves.
#[derive(Default)]
struct MlsShared {
    /// A save did not land, so the next one must be whole.
    resync: AtomicBool,
    /// The take of the newest whole save queued.
    whole_queued: AtomicU64,
}

impl MlsShared {
    /// Save number `take` did not land. A whole save queued after it covers it, or
    /// raises this itself when it fails, so only without one is another due.
    fn lost(&self, take: u64) {
        if self.whole_queued.load(Ordering::Relaxed) <= take {
            self.resync.store(true, Ordering::Relaxed);
        }
    }
}

/// Commands the actor takes off its queue at once before writing.
const WRITE_BATCH: usize = 64;

/// What the actor knows of the MLS rows on disk: once a save failed, every later save
/// taken as a change on top of it is refused until a whole one lands.
#[derive(Default)]
struct MlsDisk {
    broken: bool,
}

/// Most stored nonces one share holds: an honest sender sends a few hundred live frames
/// in a replay window, so only a flooder loses its own oldest rows.
pub(crate) const NONCES_PER_SHARE: usize = 1_024;
/// Rows the senders we know may fill, which no stranger can touch.
pub(crate) const PLACED_NONCES: usize = 32_768;
/// Rows every other sender shares; a stranger's flood evicts only the heaviest of them.
pub(crate) const STRANGER_NONCES: usize = 32_768;
/// Notes waiting for the actor past which a stranger's note is not queued: every Olm
/// frame waits on a session save in the same queue (AR-30). The guard in RAM still
/// refuses the repeat for as long as this process runs.
pub(crate) const STRANGER_NOTE_BACKLOG: usize = 1_024;
/// The same for a sender we know, out of a stranger flood's reach.
pub(crate) const PLACED_NOTE_BACKLOG: usize = 4_096;

/// The stored guard's rows per share, counted here so a note costs no table scan.
struct NonceBook {
    /// Indexed by `placed as usize`.
    pools: [NoncePool; 2],
    /// Notes the sink queued that the actor has not handled yet.
    queued: Arc<AtomicUsize>,
}

#[derive(Default)]
struct NoncePool {
    rows: usize,
    shares: HashMap<String, usize>,
    by_weight: std::collections::BTreeSet<(usize, String)>,
}

impl NoncePool {
    fn held(&self, share: &str) -> usize {
        self.shares.get(share).copied().unwrap_or(0)
    }

    fn set(&mut self, share: &str, count: usize) {
        let was = self.held(share);
        self.by_weight.remove(&(was, share.to_string()));
        self.rows = self.rows - was + count;
        if count == 0 {
            self.shares.remove(share);
        } else {
            self.shares.insert(share.to_string(), count);
            self.by_weight.insert((count, share.to_string()));
        }
    }

    fn heaviest(&self) -> Option<String> {
        self.by_weight.last().map(|(_, share)| share.clone())
    }
}

impl NonceBook {
    fn new(queued: Arc<AtomicUsize>) -> Self {
        Self { pools: Default::default(), queued }
    }

    /// Count the rows on disk again: at start, after a prune, after a lost commit.
    fn recount(&mut self, store: &MessageStore) {
        self.pools = Default::default();
        match store.live_frame_nonce_shares() {
            Ok(shares) => {
                for (placed, share, count) in shares {
                    self.pools[placed as usize].set(&share, count);
                }
            }
            Err(e) => hollow_log!("CryptoStore: failed to count live frame nonces: {e}"),
        }
    }

    /// Keep one nonce. Never refused: a full share gives up its own oldest row, a full
    /// pool the oldest row of its heaviest share, so a flood from free identities only
    /// ever displaces itself and the senders we know keep their own pool.
    fn note(&mut self, store: &MessageStore, sender: &str, nonce: &[u8], expires_ms: i64, placed: Option<&str>) -> Result<(), String> {
        let (share, cap) = match placed {
            Some(master) => (master, PLACED_NONCES),
            None => (sender, STRANGER_NONCES),
        };
        let pool = &mut self.pools[placed.is_some() as usize];
        let victim = if pool.held(share) >= NONCES_PER_SHARE {
            Some(share.to_string())
        } else if pool.rows >= cap {
            pool.heaviest()
        } else {
            None
        };
        if let Some(victim) = victim
            && store.evict_live_frame_nonce(&victim, placed.is_some())?
        {
            pool.set(&victim, pool.held(&victim) - 1);
        }
        if store.insert_live_frame_nonce(sender, nonce, expires_ms, share, placed.is_some())? {
            pool.set(share, pool.held(share) + 1);
        }
        Ok(())
    }
}

/// The window a stored nonce is worth keeping in at `now_ms`: from frames turning stale
/// now to the newest stamp a frame can carry ([`crate::node::frame_auth::open`] refuses
/// one past `now + LIVE_SKEW_MS`, and its row expires `LIVE_SKEW_MS` after that).
fn nonce_window(now_ms: i64) -> (i64, i64) {
    (now_ms, now_ms.saturating_add(2 * LIVE_SKEW_MS))
}

/// Write one command; a waited-on save returns its outcome and who waits for it. A
/// failed MLS save asks for a whole one: its rows are no longer marked changed, so only
/// a whole save brings the store back.
fn write(
    store: &MessageStore,
    cmd: CryptoStoreCmd,
    shared: &MlsShared,
    mls: &mut MlsDisk,
    book: &mut NonceBook,
) -> Option<(watch::Sender<Saved>, Saved)> {
    match cmd {
        CryptoStoreCmd::SaveAccount(pickle) => {
            if let Err(e) = store.save_olm_account(&pickle) {
                hollow_log!("CryptoStore: failed to save account: {e}");
            }
        }
        CryptoStoreCmd::SaveSession { peer_id, pickle, version, saved } => {
            let (sends, reads) = version.stored();
            let outcome = match store.save_olm_session(&peer_id, &pickle, sends, reads) {
                Ok(true) => Saved::Stored,
                Ok(false) => {
                    hollow_log!("[HOLLOW-CRYPTO] Kept the stored Olm session for {peer_id}: it came as far as {version:?} or further");
                    Saved::Refused
                }
                Err(e) => {
                    hollow_log!("CryptoStore: failed to save session for {peer_id}: {e}");
                    Saved::Failed
                }
            };
            return saved.map(|tx| (tx, outcome));
        }
        CryptoStoreCmd::DeleteSession { peer_id } => {
            if let Err(e) = store.delete_olm_session(&peer_id) {
                hollow_log!("CryptoStore: failed to delete session for {peer_id}: {e}");
            }
        }
        CryptoStoreCmd::SaveReadMark { peer_id, sealed_ms } => {
            if let Err(e) = store.save_olm_read_mark(&peer_id, sealed_ms) {
                hollow_log!("CryptoStore: failed to save read mark for {peer_id}: {e}");
            }
        }
        CryptoStoreCmd::NoteLiveNonce { sender, nonce, expires_ms, placed } => {
            book.queued.fetch_sub(1, Ordering::Relaxed);
            if let Err(e) = book.note(store, &sender, &nonce, expires_ms, placed.as_deref()) {
                hollow_log!("CryptoStore: failed to note a live frame from {sender}: {e}");
            }
        }
        CryptoStoreCmd::PruneLiveNonces { now_ms } => {
            let (oldest, latest) = nonce_window(now_ms);
            if let Err(e) = store.prune_live_frame_nonces(oldest, latest) {
                hollow_log!("CryptoStore: failed to prune live frame nonces: {e}");
            }
            book.recount(store);
        }
        CryptoStoreCmd::SaveMls { save, saved } => {
            let whole = save.retain_only.is_some();
            let outcome = if mls.broken && !whole {
                shared.lost(save.take);
                Saved::Failed
            } else {
                match store.save_mls_state(&save) {
                    Ok(()) => {
                        mls.broken = false;
                        Saved::Stored
                    }
                    Err(e) => {
                        hollow_log!("CryptoStore: failed to save MLS state: {e}");
                        mls.broken = true;
                        shared.lost(save.take);
                        Saved::Failed
                    }
                }
            };
            return saved.map(|tx| (tx, outcome));
        }
        // The actor answers these apart from the writes.
        CryptoStoreCmd::ReadNewer { .. } | CryptoStoreCmd::ReadLiveNonces { .. } | CryptoStoreCmd::Flush(_) => {}
    }
    None
}

/// The stored sessions past `held`, and every read mark.
fn read_newer(store: &MessageStore, held: &HashMap<String, SessionVersion>) -> Newer {
    let past_ours = |peer: &str, version: SessionVersion| held.get(peer).is_none_or(|ours| version > *ours);
    let sessions = store
        .load_olm_session_versions()
        .unwrap_or_else(|e| {
            hollow_log!("CryptoStore: failed to read session versions: {e}");
            Vec::new()
        })
        .into_iter()
        .filter(|(peer, sends, reads)| past_ours(peer, SessionVersion::from_stored(*sends, *reads)))
        .filter_map(|(peer_id, _, _)| {
            // Pickle and version again in one read: another process may have written since.
            let (pickle, sends, reads) = store.load_olm_session(&peer_id).ok().flatten()?;
            let version = SessionVersion::from_stored(sends, reads);
            past_ours(&peer_id, version).then_some(StoredSession { peer_id, pickle, version })
        })
        .collect();
    Newer { sessions, read_marks: store.load_olm_read_marks().unwrap_or_default() }
}

/// Write a batch inside one transaction, so one commit covers it, and tell each
/// waiting frame what became of its save only once the commit returned.
fn write_batch(store: &MessageStore, batch: Vec<CryptoStoreCmd>, shared: &MlsShared, mls: &mut MlsDisk, book: &mut NonceBook) {
    let in_transaction = store.begin_transaction().is_ok();
    let newest_mls = batch.iter().filter_map(|cmd| match cmd {
        CryptoStoreCmd::SaveMls { save, .. } => Some(save.take),
        _ => None,
    }).max();
    let mut outcomes = Vec::new();
    for cmd in batch {
        outcomes.extend(write(store, cmd, shared, mls, book));
    }
    if in_transaction && let Err(e) = store.commit_transaction() {
        hollow_log!("CryptoStore: batch not committed: {e}");
        let _ = store.rollback_transaction();
        book.recount(store);
        if let Some(take) = newest_mls {
            mls.broken = true;
            shared.lost(take);
        }
        for (_, outcome) in outcomes.iter_mut() {
            *outcome = Saved::Failed;
        }
    }
    for (tx, outcome) in outcomes {
        let _ = tx.send(outcome);
    }
}

/// The replay guard's line to the store: fire-and-forget, like every write here.
pub(crate) struct LiveNonceSink {
    tx: mpsc::UnboundedSender<CryptoStoreCmd>,
    queued: Arc<AtomicUsize>,
}

impl LiveNonceSink {
    /// Keep a first sight; `placed` is the master when the sender is one of ours, a
    /// friend's or a co-member's device. False when the backlog left it unqueued.
    pub(crate) fn note(&self, sender: &str, nonce: [u8; NONCE_LEN], expires_ms: i64, placed: Option<&str>) -> bool {
        let backlog = if placed.is_some() { PLACED_NOTE_BACKLOG } else { STRANGER_NOTE_BACKLOG };
        if self.queued.load(Ordering::Relaxed) >= backlog {
            return false;
        }
        self.queued.fetch_add(1, Ordering::Relaxed);
        let placed = placed.map(str::to_string);
        if self.tx.send(CryptoStoreCmd::NoteLiveNonce { sender: sender.to_string(), nonce, expires_ms, placed }).is_err() {
            self.queued.fetch_sub(1, Ordering::Relaxed);
            return false;
        }
        true
    }

    pub(crate) fn prune(&self, now_ms: i64) {
        let _ = self.tx.send(CryptoStoreCmd::PruneLiveNonces { now_ms });
    }

    /// TEST-ONLY: a sink nobody drains, and its queue.
    #[cfg(test)]
    pub(crate) fn detached_for_test() -> (Self, mpsc::UnboundedReceiver<CryptoStoreCmd>) {
        let (tx, rx) = mpsc::unbounded_channel();
        (Self { tx, queued: Arc::default() }, rx)
    }
}

/// A fire-and-forget persistence actor for Olm state.
///
/// Owns a `!Send` rusqlite connection inside a `spawn_blocking` task. The
/// in-memory `OlmManager` is authoritative; the DB only survives restarts.
pub(crate) struct CryptoStore {
    cmd_tx: mpsc::UnboundedSender<CryptoStoreCmd>,
    notes_queued: Arc<AtomicUsize>,
    mls: Arc<MlsShared>,
    last_whole: std::sync::Mutex<Option<MlsSaved>>,
    #[cfg(test)]
    wholes: std::sync::atomic::AtomicUsize,
}

impl CryptoStore {
    /// Spawn the persistence actor. Opens its own DB connection.
    pub fn open(db_path: String, passphrase: String) -> Result<Self, String> {
        let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel::<CryptoStoreCmd>();
        let mls = Arc::new(MlsShared::default());
        let shared = mls.clone();
        let notes_queued = Arc::new(AtomicUsize::new(0));
        let mut book = NonceBook::new(notes_queued.clone());

        tokio::task::spawn_blocking(move || {
            let store = match MessageStore::open(&db_path, &passphrase) {
                Ok(s) => s,
                Err(e) => {
                    hollow_log!("CryptoStore: failed to open DB: {e}");
                    shared.resync.store(true, Ordering::Relaxed);
                    return;
                }
            };
            // Commits keep the NORMAL sync: a committed save outlives the process being
            // killed, which is what a waiting frame needs; a full sync per commit held
            // every Olm frame, and the pacing behind it, on the disk.
            #[cfg(test)]
            let _held = held_saves::Guard(db_path.clone());

            let mut backlog = crate::sentinel::BacklogLatch::new("crypto_store", 256);
            let mut mls_disk = MlsDisk::default();
            book.recount(&store);
            while let Some(first) = cmd_rx.blocking_recv() {
                backlog.observe(cmd_rx.len());
                let mut batch = vec![first];
                while batch.len() < WRITE_BATCH
                    && let Ok(next) = cmd_rx.try_recv()
                {
                    batch.push(next);
                }
                // Reads are answered first and outside the transaction: on iOS the
                // write lock is what a suspended process gets killed for holding.
                let mut writes = Vec::new();
                let mut flushes = Vec::new();
                for cmd in batch {
                    match cmd {
                        CryptoStoreCmd::ReadNewer { held, reply } => {
                            let _ = reply.send(read_newer(&store, &held));
                        }
                        CryptoStoreCmd::ReadLiveNonces { now_ms, reply } => {
                            let (oldest, latest) = nonce_window(now_ms);
                            match store.load_live_frame_nonces(oldest, latest) {
                                Ok(rows) => {
                                    let _ = reply.send(rows);
                                }
                                // Dropping the reply keeps the guard refusing what it cannot judge.
                                Err(e) => hollow_log!("[HOLLOW-SECURITY] CryptoStore: failed to read live frame nonces: {e}"),
                            }
                        }
                        CryptoStoreCmd::Flush(done) => flushes.push(done),
                        write => writes.push(write),
                    }
                }
                #[cfg(test)]
                let writes = held_saves::intercept(&db_path, writes);
                if !writes.is_empty() {
                    write_batch(&store, writes, &shared, &mut mls_disk, &mut book);
                }
                for done in flushes {
                    let _ = done.send(());
                }
            }
        });

        Ok(CryptoStore {
            cmd_tx,
            notes_queued,
            mls,
            last_whole: std::sync::Mutex::new(None),
            #[cfg(test)]
            wholes: Default::default(),
        })
    }

    /// Fire-and-forget: persist the account pickle.
    pub fn save_account(&self, pickle_json: String) {
        let _ = self.cmd_tx.send(CryptoStoreCmd::SaveAccount(pickle_json));
    }

    /// Fire-and-forget: persist a session pickle at `version`, past any older copy.
    pub fn save_session(&self, peer_id: String, pickle_json: String, version: SessionVersion) {
        let _ = self.cmd_tx.send(CryptoStoreCmd::SaveSession { peer_id, pickle: pickle_json, version, saved: None });
    }

    /// Persist a session pickle at `version` and hear what became of it.
    pub fn save_session_awaited(&self, peer_id: String, pickle_json: String, version: SessionVersion) -> SessionSaved {
        let (tx, rx) = watch::channel(Saved::Pending);
        let cmd = CryptoStoreCmd::SaveSession { peer_id, pickle: pickle_json, version, saved: Some(tx) };
        // A closed actor drops the sender with the command, which settles as failed.
        let _ = self.cmd_tx.send(cmd);
        SessionSaved(rx)
    }

    /// Fire-and-forget: delete a persisted Olm session.
    pub fn delete_session(&self, peer_id: String) {
        let _ = self.cmd_tx.send(CryptoStoreCmd::DeleteSession { peer_id });
    }

    /// Fire-and-forget: raise a sending device's read mark.
    pub fn save_read_mark(&self, peer_id: String, sealed_ms: i64) {
        let _ = self.cmd_tx.send(CryptoStoreCmd::SaveReadMark { peer_id, sealed_ms });
    }

    /// Where the replay guard writes the live frames it saw.
    pub fn live_nonce_sink(&self) -> LiveNonceSink {
        LiveNonceSink { tx: self.cmd_tx.clone(), queued: self.notes_queued.clone() }
    }

    /// Ask for the live-frame nonces still fresh at `now_ms`; the answer closes
    /// unanswered when the actor is gone.
    pub fn ask_live_nonces(&self, now_ms: i64) -> oneshot::Receiver<Vec<(String, Vec<u8>, i64)>> {
        let (reply, answer) = oneshot::channel();
        let _ = self.cmd_tx.send(CryptoStoreCmd::ReadLiveNonces { now_ms, reply });
        answer
    }

    /// Persist an MLS save and hear what became of it.
    pub fn save_mls(&self, save: MlsSave) -> MlsSaved {
        let (tx, rx) = watch::channel(Saved::Pending);
        let saved = MlsSaved { saved: SessionSaved(rx), take: save.take };
        if save.retain_only.is_some() {
            self.mls.whole_queued.fetch_max(save.take, Ordering::Relaxed);
            *self.last_whole.lock().unwrap_or_else(|e| e.into_inner()) = Some(saved.clone());
            #[cfg(test)]
            self.wholes.fetch_add(1, Ordering::Relaxed);
        }
        if self.cmd_tx.send(CryptoStoreCmd::SaveMls { save, saved: Some(tx) }).is_err() {
            self.mls.resync.store(true, Ordering::Relaxed);
        }
        saved
    }

    /// The newest whole MLS save, when it was taken after save number `take` and has
    /// not failed: it covers every frame `take` covers.
    pub fn whole_save_after(&self, take: u64) -> Option<MlsSaved> {
        let last = self.last_whole.lock().unwrap_or_else(|e| e.into_inner());
        last.as_ref().filter(|whole| whole.take > take && matches!(whole.now(), Saved::Pending | Saved::Stored)).cloned()
    }

    /// TEST-ONLY: how many whole MLS saves were queued.
    #[cfg(test)]
    pub fn whole_saves_for_test(&self) -> usize {
        self.wholes.load(Ordering::Relaxed)
    }

    /// Whether an MLS save failed since the last ask, so the next must be a whole one.
    pub fn take_mls_resync(&self) -> bool {
        self.mls.resync.swap(false, Ordering::Relaxed)
    }

    /// Ask for the next MLS save to be a whole one.
    pub fn want_mls_resync(&self) {
        self.mls.resync.store(true, Ordering::Relaxed);
    }

    /// Whether everything queued so far was written within `within`, so the Olm frames
    /// waiting on those saves are free to go.
    pub async fn flushed(&self, within: Duration) -> bool {
        let (done, wait) = oneshot::channel();
        self.cmd_tx.send(CryptoStoreCmd::Flush(done)).is_ok()
            && matches!(tokio::time::timeout(within, wait).await, Ok(Ok(())))
    }

    /// Ask for the stored sessions that came further than `held`, and every read mark;
    /// the answer closes unanswered when the actor is gone.
    pub fn ask_newer(&self, held: HashMap<String, SessionVersion>) -> oneshot::Receiver<Newer> {
        let (reply, answer) = oneshot::channel();
        let _ = self.cmd_tx.send(CryptoStoreCmd::ReadNewer { held, reply });
        answer
    }
}

/// TEST-ONLY: keep a store's session saves off its disk, as a process killed before
/// they landed would, and decide later whether they land.
#[cfg(test)]
pub(crate) mod held_saves {
    use super::*;
    use std::sync::Mutex;

    #[derive(Default)]
    struct Held {
        holding: bool,
        holding_mls: bool,
        saves: Vec<CryptoStoreCmd>,
    }

    static HELD: Mutex<Option<HashMap<String, Held>>> = Mutex::new(None);

    fn with<T>(f: impl FnOnce(&mut HashMap<String, Held>) -> T) -> T {
        let mut guard = HELD.lock().unwrap_or_else(|e| e.into_inner());
        f(guard.get_or_insert_with(HashMap::new))
    }

    /// Hold every session save to `db_path` from now on.
    pub(crate) fn hold(db_path: &str) {
        with(|held| held.entry(db_path.to_string()).or_default().holding = true);
    }

    /// Hold every MLS save to `db_path` from now on.
    pub(crate) fn hold_mls(db_path: &str) {
        with(|held| held.entry(db_path.to_string()).or_default().holding_mls = true);
    }

    /// Stop holding and write what was held, in order, through a connection of our own.
    pub(crate) fn release(db_path: &str, passphrase: &str) {
        let saves = with(|held| match held.get_mut(db_path) {
            Some(h) => {
                h.holding = false;
                h.holding_mls = false;
                std::mem::take(&mut h.saves)
            }
            None => Vec::new(),
        });
        if !saves.is_empty() {
            let store = MessageStore::open(db_path, passphrase).expect("open the held store");
            write_batch(&store, saves, &MlsShared::default(), &mut MlsDisk::default(), &mut NonceBook::new(Arc::default()));
        }
    }

    /// How many session saves to `db_path` are held.
    pub(crate) fn count(db_path: &str) -> usize {
        with(|held| held.get(db_path).map_or(0, |h| h.saves.len()))
    }

    pub(super) fn intercept(db_path: &str, writes: Vec<CryptoStoreCmd>) -> Vec<CryptoStoreCmd> {
        with(|held| match held.get_mut(db_path) {
            Some(h) if h.holding || h.holding_mls => {
                let (session, mls) = (h.holding, h.holding_mls);
                let (saves, rest): (Vec<_>, Vec<_>) = writes.into_iter().partition(|cmd| match cmd {
                    CryptoStoreCmd::SaveSession { .. } => session,
                    CryptoStoreCmd::SaveMls { .. } => mls,
                    _ => false,
                });
                h.saves.extend(saves);
                rest
            }
            _ => writes,
        })
    }

    /// Ends with the actor: saves still held then are lost, as in a crash.
    pub(super) struct Guard(pub String);

    impl Drop for Guard {
        fn drop(&mut self) {
            with(|held| held.remove(&self.0));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(sends: u64, reads: u64) -> SessionVersion {
        SessionVersion { sends, reads }
    }

    fn temp_db() -> (crate::test_tmp::TestDir, String, String) {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("crypto.db").to_string_lossy().into_owned();
        let pass = "5e".repeat(32);
        MessageStore::open(&path, &pass).unwrap();
        (tmp, path, pass)
    }

    const SOON: Duration = Duration::from_secs(10);

    fn nonce_n(i: u32, tag: u8) -> [u8; NONCE_LEN] {
        let mut n = [tag; NONCE_LEN];
        n[..4].copy_from_slice(&i.to_be_bytes());
        n
    }

    /// A book over the rows `db` holds.
    fn book_over(db: &MessageStore) -> NonceBook {
        let mut book = NonceBook::new(Arc::default());
        book.recount(db);
        book
    }

    /// AR-35: a live frame the guard saw before a restart is still seen after it, until
    /// it turns stale.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn the_replay_guard_outlives_a_restart_until_its_frames_turn_stale() {
        use crate::node::frame_auth::ReplayGuard;
        const NOW: i64 = 1_790_000_000_000;
        let (_tmp, path, pass) = temp_db();
        let store = CryptoStore::open(path.clone(), pass.clone()).unwrap();
        let mut guard = ReplayGuard::persisted(store.live_nonce_sink(), Vec::new(), NOW);
        assert!(guard.first_sight("alice", [1; NONCE_LEN], NOW, NOW, None));
        assert!(guard.first_sight("bob", [2; NONCE_LEN], NOW - 200_000, NOW, None));
        assert!(store.flushed(SOON).await);

        let reopened = CryptoStore::open(path.clone(), pass.clone()).unwrap();
        let later = NOW + 150_000;
        let rows = reopened.ask_live_nonces(later).await.unwrap();
        assert_eq!(rows.len(), 1, "bob's frame turned stale and stays forgotten");
        let mut guard = ReplayGuard::persisted(reopened.live_nonce_sink(), rows, later);
        assert!(!guard.first_sight("alice", [1; NONCE_LEN], NOW, later, None), "a frame seen before the restart was taken again");
        assert!(guard.first_sight("alice", [3; NONCE_LEN], later, later, None));

        guard.prune(NOW + LIVE_SKEW_MS + 1);
        assert!(reopened.flushed(SOON).await);
        let rows = reopened.ask_live_nonces(NOW).await.unwrap();
        assert_eq!(rows.iter().map(|(s, n, _)| (s.as_str(), n[0])).collect::<Vec<_>>(), vec![("alice", 3)], "prune kept a stale row");

        let stale = vec![("eve".to_string(), vec![5; NONCE_LEN], NOW - 1), ("eve".to_string(), vec![6; 3], NOW + 1)];
        let mut fresh = ReplayGuard::persisted(reopened.live_nonce_sink(), stale, NOW);
        assert!(fresh.first_sight("eve", [5; NONCE_LEN], NOW, NOW, None), "a stale stored row still refused a frame");
    }

    /// AR-35 review MED 1: free identities flooding the stored guard never switch it off
    /// for the senders we know.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_stranger_flood_never_switches_off_persistence_for_honest_senders() {
        use crate::node::frame_auth::ReplayGuard;
        const NOW: i64 = 1_790_000_000_000;
        let (_tmp, path, pass) = temp_db();
        let store = CryptoStore::open(path.clone(), pass.clone()).unwrap();
        let mut guard = ReplayGuard::persisted(store.live_nonce_sink(), Vec::new(), NOW);
        for s in 0..4u8 {
            let sender = format!("stranger{s}");
            for i in 0..16_384u32 {
                assert!(guard.first_sight(&sender, nonce_n(i, s), NOW, NOW, None));
            }
        }
        assert!(guard.first_sight("alice-dev", [0xAA; NONCE_LEN], NOW, NOW, Some("alice")));
        assert!(store.flushed(Duration::from_secs(60)).await);
        let reopened = CryptoStore::open(path.clone(), pass.clone()).unwrap();
        let rows = reopened.ask_live_nonces(NOW + 1_000).await.unwrap();
        let mut after = ReplayGuard::persisted(reopened.live_nonce_sink(), rows, NOW + 1_000);
        assert!(
            !after.first_sight("alice-dev", [0xAA; NONCE_LEN], NOW, NOW + 1_000, Some("alice")),
            "alice's frame seen before the restart was taken again after it"
        );
    }

    /// AR-35 review MED 1: a full stored guard refuses nothing; it gives up the oldest row
    /// of the heaviest stranger, and a stranger never touches a known sender's pool.
    #[test]
    fn a_full_stored_guard_evicts_from_the_heaviest_stranger_never_from_a_known_sender() {
        const NOW: i64 = 1_790_000_000_000;
        let (_tmp, path, pass) = temp_db();
        let db = MessageStore::open(&path, &pass).unwrap();
        let mut book = book_over(&db);
        let mut note = |sender: &str, i: u32, placed: Option<&str>| {
            book.note(&db, sender, &nonce_n(i, 0), NOW + i as i64, placed).unwrap();
        };
        let per_share = NONCES_PER_SHARE as u32;
        db.begin_transaction().unwrap();
        for i in 0..per_share {
            note("bob-dev", i, Some("bob"));
        }
        note("carol", 0, None);
        for i in 0..per_share + 10 {
            note("loud", i, None);
        }
        let loud: Vec<_> = db.load_live_frame_nonces(NOW, i64::MAX).unwrap().into_iter().filter(|(s, ..)| s == "loud").collect();
        assert_eq!(loud.len(), NONCES_PER_SHARE, "a share outgrew its cap before any pool was full");
        assert!(loud.iter().all(|(_, _, expires)| *expires >= NOW + 10), "a full share must give up its own oldest rows");
        let senders = (STRANGER_NONCES / NONCES_PER_SHARE + 8) as u32;
        for s in 0..senders {
            for i in 0..per_share {
                note(&format!("free{s}"), i, None);
            }
        }
        db.commit_transaction().unwrap();

        let rows = db.load_live_frame_nonces(NOW, i64::MAX).unwrap();
        let held = |sender: &str, i: u32| rows.iter().any(|(s, n, _)| s == sender && n[..] == nonce_n(i, 0)[..]);
        assert_eq!(rows.iter().filter(|(s, ..)| s == "bob-dev").count(), NONCES_PER_SHARE, "a stranger flood displaced a known sender's rows");
        assert!(held("carol", 0), "the flood evicted a light stranger before the heaviest");
        assert!(!held("loud", 0) && held("loud", per_share + 9), "a full share must give up its own oldest row");
        assert!(rows.iter().filter(|(s, ..)| s != "bob-dev").count() <= STRANGER_NONCES, "strangers outgrew their pool");
        assert!(held(&format!("free{}", senders - 1), per_share - 1), "a note past a full pool was refused");
        let recounted = book_over(&db);
        for pool in 0..2 {
            assert_eq!(book.pools[pool].rows, recounted.pools[pool].rows, "the running count left the disk");
            assert_eq!(book.pools[pool].shares, recounted.pools[pool].shares, "the running count left the disk");
        }
    }

    /// AR-35 review LOW 2: a stranger flood queues at most its backlog of notes; a known
    /// sender's note still gets through, up to a backlog of its own.
    #[test]
    fn a_stranger_flood_queues_no_more_than_its_backlog() {
        let (sink, queue) = LiveNonceSink::detached_for_test();
        let queued = (0..5_000u32).filter(|&i| sink.note(&format!("free{i}"), nonce_n(i, 0), 1, None)).count();
        assert_eq!((queued, queue.len()), (STRANGER_NOTE_BACKLOG, STRANGER_NOTE_BACKLOG), "a stranger flood queued past its backlog");
        assert!(sink.note("bob-dev", nonce_n(0, 1), 1, Some("bob")), "a stranger flood kept a known sender's note out");
        for i in 1..10_000u32 {
            sink.note("bob-dev", nonce_n(i, 1), 1, Some("bob"));
        }
        assert_eq!(queue.len(), PLACED_NOTE_BACKLOG, "a known sender's notes queued past their backlog");
    }

    /// AR-35 review LOW 2: every Olm frame waits on a session save (AR-30), so a flood of
    /// stranger notes at a full table must never queue in front of one.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_session_save_behind_a_nonce_flood_settles_fast() {
        const NOW: i64 = 1_790_000_000_000;
        let (_tmp, path, pass) = temp_db();
        {
            let db = MessageStore::open(&path, &pass).unwrap();
            let mut book = book_over(&db);
            db.begin_transaction().unwrap();
            for i in 0..(PLACED_NONCES + STRANGER_NONCES) as u32 {
                let (sender, placed) = (format!("fill{}", i / 1_024), (i % 2 == 0).then_some("friend"));
                book.note(&db, &sender, &nonce_n(i, 1), NOW + 300_000, placed).unwrap();
            }
            db.commit_transaction().unwrap();
        }
        let store = CryptoStore::open(path.clone(), pass.clone()).unwrap();
        assert!(store.flushed(SOON).await);
        let sink = store.live_nonce_sink();
        let started = std::time::Instant::now();
        for i in 0..50_000u32 {
            sink.note(&format!("flood{i}"), nonce_n(i, 2), NOW + 300_000, None);
        }
        let saved = store.save_session_awaited("bob".into(), "p1".into(), v(1, 0));
        assert_eq!(saved.settled(Duration::from_secs(120)).await, Saved::Stored);
        let waited = started.elapsed();
        assert!(waited < Duration::from_millis(500), "a session save waited {waited:?} behind stranger notes");
        assert!(store.flushed(SOON).await);
        assert!(sink.note("late", nonce_n(0, 3), NOW + 300_000, None), "the backlog never counted down once the actor caught up");
    }

    /// AR-35 review LOW 6: a stored nonce lives while its frame is not stale (through the
    /// millisecond it expires), and one stamped while our clock ran far ahead is dropped.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_stored_nonce_lives_while_its_frame_is_fresh_and_one_from_far_ahead_goes() {
        use crate::node::frame_auth::{is_stale, ReplayGuard};
        const NOW: i64 = 1_790_000_000_000;
        let (_tmp, path, pass) = temp_db();
        let db = MessageStore::open(&path, &pass).unwrap();
        let ahead = NOW + 2 * LIVE_SKEW_MS;
        for (sender, expires) in [("gone", NOW - 1), ("edge", NOW), ("limit", ahead), ("ahead", ahead + 1)] {
            db.insert_live_frame_nonce(sender, &[1; NONCE_LEN], expires, sender, false).unwrap();
        }
        let senders = |rows: Vec<(String, Vec<u8>, i64)>| {
            let mut s: Vec<String> = rows.into_iter().map(|(s, ..)| s).collect();
            s.sort();
            s
        };
        assert!(!is_stale(NOW - LIVE_SKEW_MS, NOW), "precondition: the edge row's frame is still fresh");
        let store = CryptoStore::open(path.clone(), pass.clone()).unwrap();
        let rows = store.ask_live_nonces(NOW).await.unwrap();
        assert_eq!(senders(rows.clone()), ["edge", "limit"], "the guard loaded a stale or far-ahead row, or lost a fresh one");
        let mut guard = ReplayGuard::persisted(store.live_nonce_sink(), rows, NOW);
        assert!(!guard.first_sight("edge", [1; NONCE_LEN], NOW - LIVE_SKEW_MS, NOW, None), "a fresh frame replayed at its last millisecond");

        store.live_nonce_sink().prune(NOW);
        assert!(store.flushed(SOON).await);
        assert_eq!(senders(db.load_live_frame_nonces(i64::MIN, i64::MAX).unwrap()), ["edge", "limit"], "prune kept a stale or far-ahead row, or dropped a fresh one");
        let rows = vec![("ahead".to_string(), vec![1; NONCE_LEN], ahead + 1)];
        let mut guard = ReplayGuard::persisted(store.live_nonce_sink(), rows, NOW);
        assert!(guard.first_sight("ahead", [1; NONCE_LEN], NOW, NOW, None), "the guard took a far-ahead row");
    }

    /// AR-35 review LOW 3: a stored guard that cannot be read refuses every live frame
    /// stamped before the node started, and only those.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_stored_guard_that_cannot_be_read_fails_closed() {
        use crate::node::frame_auth::{now_ms, ReplayGuard};
        let (_tmp, path, pass) = temp_db();
        let store = CryptoStore::open(path.clone(), pass.clone()).unwrap();
        assert!(store.flushed(SOON).await);
        MessageStore::open(&path, &pass).unwrap().conn_execute_for_test("DROP TABLE live_frame_nonces");
        let gone = CryptoStore::open(path.clone(), "00".repeat(32)).unwrap();
        for store in [&store, &gone] {
            let mut guard = ReplayGuard::load(store, SOON).await;
            let now = now_ms();
            assert!(!guard.first_sight("alice", [1; NONCE_LEN], now - 1_000, now, None), "an unread guard took a frame stamped before the start");
            let now = now_ms();
            assert!(guard.first_sight("alice", [2; NONCE_LEN], now, now, None));
        }
    }

    /// AR-30: a frame waits on this; it may say stored only once the row is on disk.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_session_save_says_stored_only_once_it_is_on_disk() {
        let (_tmp, path, pass) = temp_db();
        let store = CryptoStore::open(path.clone(), pass.clone()).unwrap();
        held_saves::hold(&path);
        let saved = store.save_session_awaited("bob".into(), "p1".into(), v(1, 0));
        assert_eq!(saved.clone().settled(Duration::from_millis(400)).await, Saved::Pending, "settled before it was written");
        assert_eq!(MessageStore::open(&path, &pass).unwrap().load_olm_session("bob").unwrap(), None);
        held_saves::release(&path, &pass);
        assert_eq!(saved.settled(SOON).await, Saved::Stored);
        assert_eq!(MessageStore::open(&path, &pass).unwrap().load_olm_session("bob").unwrap(), Some(("p1".into(), 1, 0)));

        let older = store.save_session_awaited("bob".into(), "older".into(), v(0, 5));
        assert_eq!(older.settled(SOON).await, Saved::Refused, "an older copy must not count as saved");
        let again = store.save_session_awaited("bob".into(), "p1".into(), v(1, 0));
        assert_eq!(again.settled(SOON).await, Saved::Stored, "the same state saved again is on disk");
    }

    fn mls_save(value: &[u8]) -> MlsSave {
        MlsSave {
            signer: b"signer".to_vec(),
            credential: b"credential".to_vec(),
            rows: vec![(String::new(), b"row".to_vec(), Some(value.to_vec()))],
            ..Default::default()
        }
    }

    /// An MLS frame waits on this: stored only once its rows are on disk, and saves
    /// land in the order they were taken.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_mls_save_says_stored_only_once_its_rows_are_on_disk() {
        let (_tmp, path, pass) = temp_db();
        let store = CryptoStore::open(path.clone(), pass.clone()).unwrap();
        held_saves::hold_mls(&path);
        let first = store.save_mls(mls_save(b"one"));
        let second = store.save_mls(mls_save(b"two"));
        assert_eq!(second.clone().settled(Duration::from_millis(400)).await, Saved::Pending, "settled before it was written");
        assert!(MessageStore::open(&path, &pass).unwrap().load_mls_rows().unwrap().is_empty());
        held_saves::release(&path, &pass);
        assert_eq!(first.settled(SOON).await, Saved::Stored);
        assert_eq!(second.settled(SOON).await, Saved::Stored);
        let rows = MessageStore::open(&path, &pass).unwrap().load_mls_rows().unwrap();
        assert_eq!(rows, vec![(String::new(), b"row".to_vec(), b"two".to_vec())]);
        assert!(!store.take_mls_resync());
    }

    /// A save that did not land took its rows off the changed list, so the next save
    /// must be a whole one.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_failed_mls_save_asks_for_a_whole_one() {
        let (_tmp, path, _pass) = temp_db();
        let wrong_key = CryptoStore::open(path, "00".repeat(32)).unwrap();
        assert_eq!(wrong_key.save_mls(mls_save(b"lost")).settled(SOON).await, Saved::Failed);
        assert!(wrong_key.take_mls_resync(), "a lost save went unnoticed");
        assert!(!wrong_key.take_mls_resync(), "asked once");
    }

    /// After a failed save, a change taken on top of it is refused until a whole save
    /// lands, and a failed save leaves none of its rows behind.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn after_a_failed_mls_save_only_a_whole_one_lands() {
        let (_tmp, path, pass) = temp_db();
        let store = CryptoStore::open(path.clone(), pass.clone()).unwrap();
        let disk = || MessageStore::open(&path, &pass).unwrap();
        assert!(store.flushed(SOON).await);
        // Rows past the first fail: the identity and the first row must not land either.
        disk().conn_execute_for_test("CREATE TRIGGER no_bad BEFORE INSERT ON mls_storage WHEN NEW.k = X'626164' BEGIN SELECT RAISE(ABORT, 'refused'); END;");
        let mut half = mls_save(b"one");
        half.rows.push((String::new(), b"bad".to_vec(), Some(b"x".to_vec())));
        assert_eq!(store.save_mls(half).settled(SOON).await, Saved::Failed);
        assert!(disk().load_mls_rows().unwrap().is_empty(), "a failed save left rows behind");
        assert!(disk().load_mls_identity().unwrap().is_none(), "a failed save left its identity behind");
        assert_eq!(store.save_mls(mls_save(b"two")).settled(SOON).await, Saved::Failed, "a change on top of a failed save landed");
        assert!(disk().load_mls_rows().unwrap().is_empty());
        let mut whole = mls_save(b"three");
        whole.retain_only = Some(vec![String::new()]);
        assert_eq!(store.save_mls(whole).settled(SOON).await, Saved::Stored);
        assert_eq!(store.save_mls(mls_save(b"four")).settled(SOON).await, Saved::Stored, "the whole save did not clear the failure");
        assert_eq!(disk().load_mls_rows().unwrap(), vec![(String::new(), b"row".to_vec(), b"four".to_vec())]);
    }

    fn mls_cmd(take: u64, value: &[u8], whole: bool, bad: bool) -> CryptoStoreCmd {
        let mut save = mls_save(value);
        save.take = take;
        if whole {
            save.retain_only = Some(vec![String::new()]);
        }
        if bad {
            save.rows.push((String::new(), b"bad".to_vec(), Some(b"x".to_vec())));
        }
        CryptoStoreCmd::SaveMls { save, saved: None }
    }

    /// A save that did not land asks for a whole one only when no whole save taken
    /// after it is queued: that one covers it, or asks in turn when it fails.
    #[test]
    fn a_lost_mls_save_behind_a_queued_whole_one_asks_for_no_other() {
        let (_tmp, path, pass) = temp_db();
        let store = MessageStore::open(&path, &pass).unwrap();
        store.conn_execute_for_test("CREATE TRIGGER no_bad BEFORE INSERT ON mls_storage WHEN NEW.k = X'626164' BEGIN SELECT RAISE(ABORT, 'refused'); END;");
        let queued = |take| {
            let shared = MlsShared::default();
            shared.whole_queued.store(take, Ordering::Relaxed);
            shared
        };

        let shared = queued(3);
        let batch = vec![mls_cmd(1, b"one", false, true), mls_cmd(2, b"two", false, false), mls_cmd(3, b"three", true, false)];
        write_batch(&store, batch, &shared, &mut MlsDisk::default(), &mut NonceBook::new(Arc::default()));
        assert!(!shared.resync.load(Ordering::Relaxed), "a whole save queued behind the lost ones was not trusted to cover them");
        assert_eq!(store.load_mls_rows().unwrap(), vec![(String::new(), b"row".to_vec(), b"three".to_vec())]);

        let shared = queued(3);
        write_batch(&store, vec![mls_cmd(4, b"four", false, true)], &shared, &mut MlsDisk::default(), &mut NonceBook::new(Arc::default()));
        assert!(shared.resync.load(Ordering::Relaxed), "a lost save with no whole one after it asked for none");

        let shared = queued(5);
        write_batch(&store, vec![mls_cmd(5, b"five", true, true)], &shared, &mut MlsDisk::default(), &mut NonceBook::new(Arc::default()));
        assert!(shared.resync.load(Ordering::Relaxed), "a failed whole save asked for no other");
    }

    /// The actor hears of every whole save queued, so a save lost before it asks for no other.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn the_actor_knows_the_newest_whole_save_queued() {
        let (_tmp, path, pass) = temp_db();
        let store = CryptoStore::open(path, pass).unwrap();
        let mut whole = mls_save(b"whole");
        whole.take = 7;
        whole.retain_only = Some(vec![String::new()]);
        let mut change = mls_save(b"change");
        change.take = 8;
        let whole = store.save_mls(whole);
        let _ = store.save_mls(change);
        assert_eq!(store.mls.whole_queued.load(Ordering::Relaxed), 7);
        assert_eq!(store.whole_save_after(6).map(|w| w.take()), Some(7));
        assert!(store.whole_save_after(7).is_none(), "a whole save covers only frames taken before it");
        assert_eq!(whole.settled(SOON).await, Saved::Stored);
    }

    /// A store that opens but cannot write the rows says so, and asks for a whole save.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_mls_write_that_fails_asks_for_a_whole_save() {
        let (_tmp, path, pass) = temp_db();
        let store = CryptoStore::open(path.clone(), pass.clone()).unwrap();
        assert!(store.flushed(SOON).await);
        MessageStore::open(&path, &pass).unwrap().drop_mls_rows_table_for_test();
        assert_eq!(store.save_mls(mls_save(b"lost")).settled(SOON).await, Saved::Failed);
        assert!(store.take_mls_resync(), "a lost save went unnoticed");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_save_to_a_store_that_cannot_write_says_failed() {
        let (_tmp, path, _pass) = temp_db();
        let wrong_key = CryptoStore::open(path, "00".repeat(32)).unwrap();
        let saved = wrong_key.save_session_awaited("bob".into(), "p".into(), v(1, 0));
        assert_eq!(saved.settled(SOON).await, Saved::Failed);
        assert_eq!(SessionSaved::failed().settled(SOON).await, Saved::Failed);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn the_store_hands_back_only_sessions_past_ours() {
        let (_tmp, path, pass) = temp_db();
        let disk = MessageStore::open(&path, &pass).unwrap();
        disk.save_olm_session("behind", "b", 2, 0).unwrap();
        disk.save_olm_session("ahead", "a", 1, 4).unwrap();
        disk.save_olm_session("new", "n", 0, 1).unwrap();
        disk.save_olm_read_mark("ahead", 77).unwrap();
        let store = CryptoStore::open(path, pass).unwrap();
        let held = HashMap::from([("behind".to_string(), v(2, 0)), ("ahead".to_string(), v(1, 3))]);
        let newer = tokio::time::timeout(SOON, store.ask_newer(held)).await.unwrap().unwrap();
        let mut got: Vec<(String, String, SessionVersion)> =
            newer.sessions.into_iter().map(|s| (s.peer_id, s.pickle, s.version)).collect();
        got.sort();
        assert_eq!(got, vec![("ahead".into(), "a".into(), v(1, 4)), ("new".into(), "n".into(), v(0, 1))]);
        assert_eq!(newer.read_marks, vec![("ahead".to_string(), 77)]);
    }
}
