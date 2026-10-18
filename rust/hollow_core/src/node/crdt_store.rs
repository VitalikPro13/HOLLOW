use std::collections::HashMap;
use tokio::sync::mpsc;

use crate::crdt::operations::CrdtOp;
use crate::storage::MessageStore;

pub(crate) enum CrdtStoreCmd {
    InsertOp(CrdtOp),
    SaveState { server_id: String, state_json: String },
    /// Like SaveState, but carries a lean state clone and defers the JSON
    /// serialization to the actor thread at drain time — a burst of N CRDT
    /// ops costs N cheap clones and exactly ONE serialize per server.
    SaveStateSnapshot { server_id: String, state: Box<crate::crdt::server_state::ServerState> },
    SaveBlob { server_id: String, key: String, value: String },
    DeleteBlob { server_id: String, key: String },
    DeleteServer(String),
    /// Insert-or-replace one parked-join row (pending joins, rung 1). Through
    /// the actor for the same reason every other CRDT write is: the join handler
    /// runs ON the event loop, and `MessageStore::open` there is a fresh handle.
    UpsertPendingJoin(Box<crate::storage::messages::PendingJoinRow>),
    DeletePendingJoin(String),
    /// Keep only the newest N ops of each named LEGACY-anchored server.
    PruneLegacyOps { server_ids: Vec<String>, keep: usize },
    /// Ops the fold admitted, plus the checkpoint they may have rebased on.
    PersistAdmitted { ops: Vec<CrdtOp>, checkpoint: Option<crate::crdt::hlc::HlcTimestamp> },
    /// READ-ONLY: newest stored message timestamp (ms) per channel, for the relay
    /// catch-up window. Answered on the actor's long-lived connection so the
    /// caller never opens a transient SQLCipher handle.
    ChannelWatermarks {
        server_id: String,
        channel_ids: Vec<String>,
        reply: tokio::sync::oneshot::Sender<HashMap<String, i64>>,
    },
    /// READ-ONLY: every author of a channel post we hold, for the owner's first
    /// checkpoint of an existing server (it seeds the membership record).
    ChannelAuthors {
        server_id: String,
        reply: tokio::sync::oneshot::Sender<Vec<String>>,
    },
    /// READ-ONLY: one parked-join row, for the "Request again" action. Answered
    /// on the actor's connection: the caller is the swarm event loop.
    LoadPendingJoin {
        server_id: String,
        reply: tokio::sync::oneshot::Sender<Option<crate::storage::messages::PendingJoinRow>>,
    },
    /// Answered once every write queued before it is committed.
    Barrier(tokio::sync::oneshot::Sender<()>),
}

/// A batched pending state save: either pre-serialized JSON (legacy path) or
/// a snapshot serialized once at flush.
enum PendingState {
    Json(String),
    Snapshot(Box<crate::crdt::server_state::ServerState>),
}

/// A fire-and-forget persistence actor for CRDT state.
///
/// Owns a `rusqlite::Connection` (which is `!Send`) inside a `spawn_blocking`
/// task. After each batch drain only the LATEST `SaveState` per `server_id` is
/// flushed, which batches many CRDT ops into one DB write per server.
#[derive(Clone)]
pub(crate) struct CrdtStore {
    cmd_tx: mpsc::UnboundedSender<CrdtStoreCmd>,
}

impl CrdtStore {
    /// Spawn the persistence actor.  Opens its own DB connection.
    pub fn open(db_path: String, passphrase: String) -> Result<Self, String> {
        let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel::<CrdtStoreCmd>();

        tokio::task::spawn_blocking(move || {
            let store = match MessageStore::open(&db_path, &passphrase) {
                Ok(s) => s,
                Err(e) => {
                    hollow_log!("CrdtStore: failed to open DB: {e}");
                    return;
                }
            };

            let mut pending_states: HashMap<String, PendingState> = HashMap::new();
            let mut pending_blobs: HashMap<(String, String), String> = HashMap::new();
            let mut backlog = crate::sentinel::BacklogLatch::new("crdt_store", 256);

            while let Some(cmd) = cmd_rx.blocking_recv() {
                backlog.observe(cmd_rx.len());

                // Collect the whole drain FIRST, then split reads from writes:
                // `begin_transaction` is BEGIN IMMEDIATE, a RESERVED write lock,
                // and on iOS the DB is in the App Group container where being
                // suspended holding a lock is what RunningBoard kills the process
                // for (EXC_CRASH 0xdead10cc). An all-read batch opens none. A read
                // commits the writes queued before it first, so it sees them.
                let mut writes = Vec::new();
                let mut barriers = Vec::new();
                let mut queued = Some(cmd);
                loop {
                    let Some(cmd) = queued.take().or_else(|| cmd_rx.try_recv().ok()) else {
                        break;
                    };
                    let is_read = matches!(
                        cmd,
                        CrdtStoreCmd::ChannelWatermarks { .. }
                            | CrdtStoreCmd::ChannelAuthors { .. }
                            | CrdtStoreCmd::LoadPendingJoin { .. }
                    );
                    if is_read && !writes.is_empty() {
                        Self::flush(&store, std::mem::take(&mut writes), &mut pending_states, &mut pending_blobs);
                    }
                    match cmd {
                        CrdtStoreCmd::ChannelWatermarks { server_id, channel_ids, reply } => {
                            let mut out: HashMap<String, i64> = HashMap::new();
                            for cid in &channel_ids {
                                if let Ok(Some(ts)) =
                                    store.get_latest_channel_timestamp(&server_id, cid)
                                {
                                    if ts > 0 {
                                        out.insert(cid.clone(), ts);
                                    }
                                }
                            }
                            let _ = reply.send(out);
                        }
                        CrdtStoreCmd::ChannelAuthors { server_id, reply } => {
                            let _ = reply.send(store.channel_authors(&server_id));
                        }
                        CrdtStoreCmd::LoadPendingJoin { server_id, reply } => {
                            let row = store
                                .load_pending_joins()
                                .unwrap_or_default()
                                .into_iter()
                                .find(|r| r.server_id == server_id);
                            let _ = reply.send(row);
                        }
                        CrdtStoreCmd::Barrier(done) => barriers.push(done),
                        other => writes.push(other),
                    }
                }
                if !writes.is_empty() {
                    Self::flush(&store, writes, &mut pending_states, &mut pending_blobs);
                }
                for done in barriers {
                    let _ = done.send(());
                }
            }
        });

        Ok(CrdtStore { cmd_tx })
    }

    /// Apply `writes` in one transaction, one state and blob write per server.
    fn flush(
        store: &MessageStore,
        writes: Vec<CrdtStoreCmd>,
        pending_states: &mut HashMap<String, PendingState>,
        pending_blobs: &mut HashMap<(String, String), String>,
    ) {
        let _ = store.begin_transaction();

        for cmd in writes {
            Self::process_cmd(store, cmd, pending_states, pending_blobs);
        }

        // One write per server; snapshots serialize HERE, on this thread.
        for (sid, pending) in pending_states.drain() {
            let json = match pending {
                PendingState::Json(j) => j,
                PendingState::Snapshot(s) => match serde_json::to_string(&*s) {
                    Ok(j) => j,
                    Err(e) => {
                        hollow_log!("CrdtStore: failed to serialize state for {sid}: {e}");
                        continue;
                    }
                },
            };
            if let Err(e) = store.save_server_state(&sid, &json) {
                hollow_log!("CrdtStore: failed to save state for {sid}: {e}");
            }
        }
        for ((sid, key), value) in pending_blobs.drain() {
            if let Err(e) = store.save_server_blob(&sid, &key, &value) {
                hollow_log!("CrdtStore: failed to save blob {key} for {sid}: {e}");
            }
        }
        let _ = store.commit_transaction();
    }

    fn process_cmd(
        store: &MessageStore,
        cmd: CrdtStoreCmd,
        pending_states: &mut HashMap<String, PendingState>,
        pending_blobs: &mut HashMap<(String, String), String>,
    ) {
        match cmd {
            CrdtStoreCmd::InsertOp(op) => {
                if let Err(e) = store.insert_crdt_op(&op) {
                    hollow_log!("CrdtStore: failed to insert op: {e}");
                }
            }
            CrdtStoreCmd::SaveState { server_id, state_json } => {
                pending_states.insert(server_id, PendingState::Json(state_json));
            }
            CrdtStoreCmd::SaveStateSnapshot { server_id, state } => {
                pending_states.insert(server_id, PendingState::Snapshot(state));
            }
            CrdtStoreCmd::SaveBlob { server_id, key, value } => {
                pending_blobs.insert((server_id, key), value);
            }
            CrdtStoreCmd::DeleteBlob { server_id, key } => {
                pending_blobs.remove(&(server_id.clone(), key.clone()));
                if let Err(e) = store.delete_server_blob(&server_id, &key) {
                    hollow_log!("CrdtStore: failed to delete blob {key} for {server_id}: {e}");
                }
            }
            CrdtStoreCmd::UpsertPendingJoin(row) => {
                if let Err(e) = store.upsert_pending_join(&row) {
                    hollow_log!("CrdtStore: failed to upsert pending join {}: {e}", row.server_id);
                }
            }
            CrdtStoreCmd::DeletePendingJoin(server_id) => {
                if let Err(e) = store.delete_pending_join(&server_id) {
                    hollow_log!("CrdtStore: failed to delete pending join {server_id}: {e}");
                }
            }
            CrdtStoreCmd::DeleteServer(server_id) => {
                pending_states.remove(&server_id);
                pending_blobs.retain(|(sid, _), _| sid != &server_id);
                if let Err(e) = store.delete_server_state(&server_id) {
                    hollow_log!("CrdtStore: failed to delete server {server_id}: {e}");
                }
            }
            // Read-only: split out in the drain loop before the transaction
            // opens, so it never reaches here.
            CrdtStoreCmd::ChannelWatermarks { .. }
            | CrdtStoreCmd::LoadPendingJoin { .. }
            | CrdtStoreCmd::ChannelAuthors { .. }
            | CrdtStoreCmd::Barrier(_) => {}
            CrdtStoreCmd::PruneLegacyOps { server_ids, keep } => {
                for sid in server_ids {
                    match store.prune_crdt_ops(&sid, keep) {
                        Ok(n) if n > 0 => hollow_log!("[HOLLOW-CRDT] Pruned {n} old crdt_ops rows of {sid}"),
                        Err(e) => hollow_log!("[HOLLOW-CRDT] Failed to prune crdt_ops: {e}"),
                        _ => {}
                    }
                }
            }
            CrdtStoreCmd::PersistAdmitted { ops, checkpoint } => {
                store.persist_admitted_ops(&ops, checkpoint.as_ref());
            }
        }
    }

    /// Fire-and-forget: persist the latest server state JSON.
    pub fn save_state(&self, server_id: String, state_json: String) {
        let _ = self.cmd_tx.send(CrdtStoreCmd::SaveState { server_id, state_json });
    }

    /// Fire-and-forget: persist the latest server state from a lean snapshot,
    /// serializing on the actor thread at drain time. Prefer this on per-op
    /// paths: the event loop pays a clone instead of a full JSON serialize.
    pub fn save_state_snapshot(&self, server_id: String, state: &crate::crdt::server_state::ServerState) {
        let _ = self.cmd_tx.send(CrdtStoreCmd::SaveStateSnapshot {
            server_id,
            state: Box::new(state.lean_snapshot()),
        });
    }

    /// Fire-and-forget: persist a key-value blob for a server.
    pub fn save_blob(&self, server_id: String, key: String, value: String) {
        let _ = self.cmd_tx.send(CrdtStoreCmd::SaveBlob { server_id, key, value });
    }

    /// Fire-and-forget: forget one key-value blob of a server.
    pub fn delete_blob(&self, server_id: String, key: String) {
        let _ = self.cmd_tx.send(CrdtStoreCmd::DeleteBlob { server_id, key });
    }

    /// Fire-and-forget: insert a CRDT op.
    pub fn insert_op(&self, op: CrdtOp) {
        let _ = self.cmd_tx.send(CrdtStoreCmd::InsertOp(op));
    }

    /// Fire-and-forget: delete all state for a server.
    pub fn delete_server(&self, server_id: String) {
        let _ = self.cmd_tx.send(CrdtStoreCmd::DeleteServer(server_id));
    }

    /// Fire-and-forget: persist one parked-join row.
    pub fn upsert_pending_join(&self, row: crate::storage::messages::PendingJoinRow) {
        let _ = self.cmd_tx.send(CrdtStoreCmd::UpsertPendingJoin(Box::new(row)));
    }

    /// Fire-and-forget: forget a parked-join row (completed or discarded).
    pub fn delete_pending_join(&self, server_id: String) {
        let _ = self.cmd_tx.send(CrdtStoreCmd::DeletePendingJoin(server_id));
    }

    /// Fire-and-forget: prune each named legacy-anchored server to its newest ops.
    pub fn prune_legacy_ops(&self, server_ids: Vec<String>, keep: usize) {
        let _ = self.cmd_tx.send(CrdtStoreCmd::PruneLegacyOps { server_ids, keep });
    }

    /// Waits until every write queued before this call is committed, so another
    /// connection reads it. Returns at once when the actor is gone.
    pub async fn committed(&self) {
        let (done, rx) = tokio::sync::oneshot::channel();
        if self.cmd_tx.send(CrdtStoreCmd::Barrier(done)).is_ok() {
            let _ = rx.await;
        }
    }

    /// Every author of a channel post we hold in `server_id` (empty if the actor is gone).
    pub async fn channel_authors(&self, server_id: String) -> Vec<String> {
        let (reply, rx) = tokio::sync::oneshot::channel();
        if self.cmd_tx.send(CrdtStoreCmd::ChannelAuthors { server_id, reply }).is_err() {
            return Vec::new();
        }
        rx.await.unwrap_or_default()
    }

    /// Fire-and-forget: persist what an ingest admitted, pruning below a new checkpoint.
    pub fn persist_admitted(&self, ops: Vec<CrdtOp>, checkpoint: Option<crate::crdt::hlc::HlcTimestamp>) {
        if !ops.is_empty() {
            let _ = self.cmd_tx.send(CrdtStoreCmd::PersistAdmitted { ops, checkpoint });
        }
    }

    /// One parked-join row by server id, or `None` when there is no such row
    /// (or the actor is gone). Read on the actor's long-lived connection, so
    /// the swarm event loop never opens a SQLCipher handle for it.
    pub async fn load_pending_join(
        &self,
        server_id: String,
    ) -> Option<crate::storage::messages::PendingJoinRow> {
        let (reply, rx) = tokio::sync::oneshot::channel();
        if self.cmd_tx.send(CrdtStoreCmd::LoadPendingJoin { server_id, reply }).is_err() {
            return None;
        }
        rx.await.ok().flatten()
    }

    /// Newest stored message timestamp (ms) per channel, for every channel in
    /// `channel_ids` that has one; channels with no messages are absent.
    ///
    /// The ONE read on this actor, and it exists for a reason: a per-channel
    /// `MessageStore::open()` on the event loop re-parses the whole schema under
    /// a file lock, and on iOS a suspension inside that window kills the process
    /// (`EXC_CRASH 0xdead10cc`). An empty map means the actor is gone.
    pub async fn channel_watermarks(
        &self,
        server_id: String,
        channel_ids: Vec<String>,
    ) -> HashMap<String, i64> {
        let (reply, rx) = tokio::sync::oneshot::channel();
        if self
            .cmd_tx
            .send(CrdtStoreCmd::ChannelWatermarks { server_id, channel_ids, reply })
            .is_err()
        {
            return HashMap::new();
        }
        rx.await.unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::MessageStore;

    /// The relay catch-up watermark must come back off the actor's long-lived
    /// connection, batched, WITHOUT the caller opening a DB handle: that
    /// transient open on the event loop is what got the iOS app killed for
    /// holding an App Group file lock across a suspend (`EXC_CRASH 0xdead10cc`).
    /// File-backed on purpose: `:memory:` gives each connection its own database.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn channel_watermarks_answers_from_the_actor_connection() {
        let dir = crate::test_tmp::tempdir().expect("tmp");
        let path = dir.path().join("watermarks.db");
        let path_str = path.to_string_lossy().to_string();
        let passphrase = "ab".repeat(32);

        {
            let store = MessageStore::open(&path_str, &passphrase).expect("seed store");
            for (chan, ts) in [("general", 1_000i64), ("general", 5_000), ("random", 2_000)] {
                store
                    .insert_channel_message(
                        "srv", chan, "sender", "hi", false, ts,
                        None, None, Some(&format!("{chan}-{ts}")), None, None, None,
                        None,
                    )
                    .expect("insert");
            }
        }

        let actor = CrdtStore::open(path_str, passphrase).expect("actor");
        let out = actor
            .channel_watermarks(
                "srv".to_string(),
                vec!["general".into(), "random".into(), "empty".into()],
            )
            .await;

        assert_eq!(out.get("general"), Some(&5_000), "newest row wins per channel");
        assert_eq!(out.get("random"), Some(&2_000));
        assert!(!out.contains_key("empty"), "a channel with no rows has no watermark");

        // Answering a read must not leave the actor wedged: a second query, and
        // a write behind it, still land.
        let again = actor
            .channel_watermarks("srv".to_string(), vec!["general".into()])
            .await;
        assert_eq!(again.get("general"), Some(&5_000));
        actor.save_blob("srv".into(), "k".into(), "v".into());
        let mixed = actor
            .channel_watermarks("srv".to_string(), vec!["random".into()])
            .await;
        assert_eq!(mixed.get("random"), Some(&2_000));
    }

    /// Dart answers a server event by reading the state on ITS connection, so the
    /// barrier must hold until the write queued before it is committed, or a rename
    /// shows one change late. A big state keeps the write slow enough to lose a race.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn committed_waits_for_the_queued_state_write() {
        let dir = crate::test_tmp::tempdir().expect("tmp");
        let path = dir.path().join("barrier.db");
        let path_str = path.to_string_lossy().to_string();
        let passphrase = "cd".repeat(32);
        let actor = CrdtStore::open(path_str.clone(), passphrase.clone()).expect("actor");
        // Two opens at once race for the schema lock; the round trip waits out the actor's.
        actor.committed().await;
        let reader = MessageStore::open(&path_str, &passphrase).expect("reader");
        let padding = "x".repeat(4 * 1024 * 1024);

        for name in ["first", "second", "third"] {
            actor.save_state("srv".into(), format!(r#"{{"name":"{name}","pad":"{padding}"}}"#));
            actor.committed().await;
            let stored = reader.load_all_servers().expect("read");
            let json = &stored.iter().find(|(sid, _)| sid == "srv").expect("row").1;
            assert!(json.starts_with(&format!(r#"{{"name":"{name}""#)), "the reader saw a stale state after {name}");
        }
    }

    /// A store busy answering a catch-up read for a server of `n` channels, as at every
    /// reconnect, so writes queued now land together in one later drain.
    async fn busy_actor(n: usize) -> (crate::test_tmp::TestDir, CrdtStore, MessageStore, tokio::task::JoinHandle<HashMap<String, i64>>) {
        let dir = crate::test_tmp::tempdir().expect("tmp");
        let path_str = dir.path().join("busy.db").to_string_lossy().to_string();
        let passphrase = "ab".repeat(32);
        {
            let store = MessageStore::open(&path_str, &passphrase).expect("seed store");
            let _ = store.begin_transaction();
            for i in 0..n {
                store
                    .insert_channel_message(
                        "srv", &format!("c{i}"), "sender", "hi", false, 1_000 + i as i64,
                        None, None, Some(&format!("m{i}")), None, None, None, None,
                    )
                    .expect("insert");
            }
            let _ = store.commit_transaction();
        }
        let actor = CrdtStore::open(path_str.clone(), passphrase.clone()).expect("actor");
        actor.committed().await;
        let direct = MessageStore::open(&path_str, &passphrase).expect("direct");
        let ids: Vec<String> = (0..n).map(|i| format!("c{i}")).collect();
        let reader = actor.clone();
        let read = tokio::spawn(async move { reader.channel_watermarks("srv".into(), ids).await });
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        (dir, actor, direct, read)
    }

    /// Program order holds on disk: of two saves queued while the actor is busy, the
    /// later one is what a restart reads.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_later_state_save_wins_over_one_queued_before_it() {
        let (_dir, actor, direct, read) = busy_actor(20_000).await;
        actor.save_state("srv".into(), r#"{"name":"older"}"#.into());
        actor.save_state("srv".into(), r#"{"name":"newer"}"#.into());
        let _ = read.await;
        actor.committed().await;
        let stored = direct.load_all_servers().expect("read");
        let json = &stored.iter().find(|(sid, _)| sid == "srv").expect("row").1;
        assert!(json.contains("newer"), "the state queued first overwrote the newer one saved after it: {json}");
    }

    /// A delete queued after a snapshot of the same server leaves no row behind.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_delete_after_a_queued_snapshot_stays_deleted() {
        let (_dir, actor, direct, read) = busy_actor(20_000).await;
        direct.save_server_state("gone", r#"{"name":"member"}"#).expect("seed");
        actor.save_state("gone".into(), r#"{"name":"still a member"}"#.into());
        actor.insert_op(crate::crdt::operations::CrdtOp {
            server_id: "gone".into(),
            hlc: crate::crdt::hlc::HlcTimestamp { physical_ms: 1, counter: 0, actor: "a".into() },
            author: "a".into(),
            payload: crate::crdt::operations::CrdtPayload::ServerRenamed { new_name: "x".into() },
            auth: None,
        });
        actor.delete_server("gone".into());
        let _ = read.await;
        actor.committed().await;
        let stored = direct.load_all_servers().expect("read");
        assert!(stored.iter().all(|(sid, _)| sid != "gone"), "the deleted server came back: {stored:?}");
        assert!(direct.load_ops_for_server("gone", None).unwrap().is_empty(), "the deleted server kept an op");
    }

    /// A blob queued before its server's delete, in the same drain, does not outlive it.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_blob_queued_before_a_server_delete_does_not_outlive_it() {
        let (_dir, actor, direct, read) = busy_actor(20_000).await;
        actor.save_blob("gone".into(), "crdt_resync".into(), "{}".into());
        actor.save_blob("kept".into(), "crdt_resync".into(), "{}".into());
        actor.delete_server("gone".into());
        let _ = read.await;
        actor.committed().await;
        assert_eq!(direct.load_server_blob("gone", "crdt_resync").unwrap(), None, "a blob outlived its server's delete");
        assert!(direct.load_server_blob("kept", "crdt_resync").unwrap().is_some(), "another server's blob went with it");
    }


    /// A read queued after a write sees that write: "Request again" right after the
    /// row changed must not re-ask with the row as it was.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_pending_join_read_sees_the_upsert_queued_before_it() {
        let (_dir, actor, _direct, read) = busy_actor(20_000).await;
        actor.upsert_pending_join(crate::storage::messages::PendingJoinRow {
            server_id: "srv".into(),
            requested_at: 1,
            nsfw_confirmed: false,
            twitch_proof_json: None,
            state: "pending".into(),
            reason: String::new(),
            last_deposited_at: 0,
            created_at: 1,
            key_package: None,
            owner_pin: None,
            join_key: Some("k".into()),
            reply_secret: None,
        });
        let row = actor.load_pending_join("srv".into()).await;
        let _ = read.await;
        assert!(row.is_some(), "the read was answered before the upsert queued ahead of it");
    }

    /// Server rows have ONE writer, this actor: a direct write on another connection
    /// races a write still queued here, and the older state or a deleted server lands
    /// last. The startup fold in `CrdtResync::load` runs before the event loop queues
    /// anything, and needs to know its writes landed.
    #[test]
    fn server_rows_are_written_only_through_the_actor() {
        let writes = [
            ".save_server_state(", ".delete_server_state(", ".insert_crdt_op(", ".persist_admitted_ops(",
            ".save_server_blob(", ".delete_server_blob(", ".delete_server_blobs(", ".prune_crdt_ops(",
        ];
        let allowed: &[(&str, usize)] = &[("crdt_resync.rs", 4)];
        let src = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut found = Vec::new();
        for sub in ["node", "api"] {
            for entry in std::fs::read_dir(src.join(sub)).unwrap().flatten() {
                let p = entry.path();
                let name = p.file_name().unwrap().to_string_lossy().into_owned();
                if !name.ends_with(".rs") || name == "crdt_store.rs" || name == "test_harness.rs" {
                    continue;
                }
                let text = std::fs::read_to_string(&p).unwrap().replace("\r\n", "\n");
                let live = text.split("\n#[cfg(test)]\nmod tests").next().unwrap_or_default();
                let n: usize = writes.iter().map(|w| live.matches(w).count()).sum();
                let ok = allowed.iter().find(|(f, _)| *f == name).map_or(0, |(_, k)| *k);
                if n != ok {
                    found.push(format!("{sub}/{name}: {n} direct server-row write(s), {ok} allowed"));
                }
            }
        }
        assert!(found.is_empty(), "server rows written outside the CrdtStore actor: {found:?}");
    }
}
