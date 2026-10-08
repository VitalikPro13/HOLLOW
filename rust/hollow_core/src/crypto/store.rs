use std::collections::HashMap;
use std::time::Duration;

use tokio::sync::{mpsc, oneshot, watch};

use super::olm_manager::{SessionVersion, StoredSession};
use crate::storage::MessageStore;

/// Commands the swarm task can send to persist crypto state.
pub(crate) enum CryptoStoreCmd {
    SaveAccount(String),
    /// `saved` hears what became of the save, for a frame that waits on it.
    SaveSession { peer_id: String, pickle: String, version: SessionVersion, saved: Option<watch::Sender<Saved>> },
    DeleteSession { peer_id: String },
    SaveReadMark { peer_id: String, sealed_ms: i64 },
    SaveMlsIdentity { signer: Vec<u8>, credential: Vec<u8>, storage: Vec<u8> },
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

/// One session save an Olm frame waits for before it may leave the process (AR-30):
/// a frame on the wire whose session state a crash can lose would let the next
/// encrypt after a restart reuse its message key.
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

/// Commands the actor takes off its queue at once before writing.
const WRITE_BATCH: usize = 64;

/// A batch as the actor writes it: in order, except that only its newest MLS snapshot
/// is written, last. Each snapshot is the whole state, so the older ones are moot.
fn coalesce(batch: Vec<CryptoStoreCmd>) -> Vec<CryptoStoreCmd> {
    let mut newest_mls = None;
    let mut out: Vec<CryptoStoreCmd> = batch
        .into_iter()
        .filter_map(|cmd| match cmd {
            CryptoStoreCmd::SaveMlsIdentity { .. } => {
                newest_mls = Some(cmd);
                None
            }
            other => Some(other),
        })
        .collect();
    out.extend(newest_mls);
    out
}

/// Write one command; a session save returns its outcome and who waits for it.
fn write(store: &MessageStore, cmd: CryptoStoreCmd) -> Option<(watch::Sender<Saved>, Saved)> {
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
        CryptoStoreCmd::SaveMlsIdentity { signer, credential, storage } => {
            if let Err(e) = store.save_mls_identity(&signer, &credential, &storage) {
                hollow_log!("CryptoStore: failed to save MLS identity: {e}");
            }
        }
        // The actor answers these apart from the writes.
        CryptoStoreCmd::ReadNewer { .. } | CryptoStoreCmd::Flush(_) => {}
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
fn write_batch(store: &MessageStore, batch: Vec<CryptoStoreCmd>) {
    let in_transaction = store.begin_transaction().is_ok();
    let mut outcomes = Vec::new();
    for cmd in coalesce(batch) {
        outcomes.extend(write(store, cmd));
    }
    if in_transaction && let Err(e) = store.commit_transaction() {
        hollow_log!("CryptoStore: batch not committed: {e}");
        let _ = store.rollback_transaction();
        for (_, outcome) in outcomes.iter_mut() {
            *outcome = Saved::Failed;
        }
    }
    for (tx, outcome) in outcomes {
        let _ = tx.send(outcome);
    }
}

/// A fire-and-forget persistence actor for Olm state.
///
/// Owns a `!Send` rusqlite connection inside a `spawn_blocking` task. The
/// in-memory `OlmManager` is authoritative; the DB only survives restarts.
pub(crate) struct CryptoStore {
    cmd_tx: mpsc::UnboundedSender<CryptoStoreCmd>,
}

impl CryptoStore {
    /// Spawn the persistence actor. Opens its own DB connection.
    pub fn open(db_path: String, passphrase: String) -> Result<Self, String> {
        let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel::<CryptoStoreCmd>();

        tokio::task::spawn_blocking(move || {
            let store = match MessageStore::open(&db_path, &passphrase) {
                Ok(s) => s,
                Err(e) => {
                    hollow_log!("CryptoStore: failed to open DB: {e}");
                    return;
                }
            };
            // Commits keep the NORMAL sync: a committed save outlives the process being
            // killed, which is what a waiting frame needs; a full sync per commit held
            // every Olm frame, and the pacing behind it, on the disk.
            #[cfg(test)]
            let _held = held_saves::Guard(db_path.clone());

            let mut backlog = crate::sentinel::BacklogLatch::new("crypto_store", 256);
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
                        CryptoStoreCmd::Flush(done) => flushes.push(done),
                        write => writes.push(write),
                    }
                }
                #[cfg(test)]
                let writes = held_saves::intercept(&db_path, writes);
                if !writes.is_empty() {
                    write_batch(&store, writes);
                }
                for done in flushes {
                    let _ = done.send(());
                }
            }
        });

        Ok(CryptoStore { cmd_tx })
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

    /// Fire-and-forget: persist MLS identity (signer, credential, storage).
    pub fn save_mls_identity(&self, signer: Vec<u8>, credential: Vec<u8>, storage: Vec<u8>) {
        let _ = self.cmd_tx.send(CryptoStoreCmd::SaveMlsIdentity {
            signer, credential, storage,
        });
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

    /// Stop holding and write what was held, in order, through a connection of our own.
    pub(crate) fn release(db_path: &str, passphrase: &str) {
        let saves = with(|held| match held.get_mut(db_path) {
            Some(h) => {
                h.holding = false;
                std::mem::take(&mut h.saves)
            }
            None => Vec::new(),
        });
        if !saves.is_empty() {
            let store = MessageStore::open(db_path, passphrase).expect("open the held store");
            write_batch(&store, saves);
        }
    }

    /// How many session saves to `db_path` are held.
    pub(crate) fn count(db_path: &str) -> usize {
        with(|held| held.get(db_path).map_or(0, |h| h.saves.len()))
    }

    pub(super) fn intercept(db_path: &str, writes: Vec<CryptoStoreCmd>) -> Vec<CryptoStoreCmd> {
        with(|held| match held.get_mut(db_path) {
            Some(h) if h.holding => {
                let (saves, rest): (Vec<_>, Vec<_>) =
                    writes.into_iter().partition(|cmd| matches!(cmd, CryptoStoreCmd::SaveSession { .. }));
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

    /// C-MLS-08: every send queues a full MLS snapshot, and only the newest of a batch
    /// is worth writing; everything else keeps its order.
    #[test]
    fn queued_mls_snapshots_coalesce_to_the_newest() {
        let mls = |tag: u8| CryptoStoreCmd::SaveMlsIdentity { signer: vec![tag], credential: vec![], storage: vec![] };
        let written = coalesce(vec![
            mls(1),
            CryptoStoreCmd::SaveSession { peer_id: "a".into(), pickle: "p".into(), version: SessionVersion::default(), saved: None },
            mls(2),
            CryptoStoreCmd::SaveAccount("acct".into()),
        ]);
        let shape: Vec<String> = written
            .iter()
            .map(|cmd| match cmd {
                CryptoStoreCmd::SaveMlsIdentity { signer, .. } => format!("mls{}", signer[0]),
                CryptoStoreCmd::SaveSession { peer_id, .. } => format!("session {peer_id}"),
                CryptoStoreCmd::SaveAccount(_) => "account".to_string(),
                _ => "other".to_string(),
            })
            .collect();
        assert_eq!(shape, vec!["session a", "account", "mls2"]);
    }

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
