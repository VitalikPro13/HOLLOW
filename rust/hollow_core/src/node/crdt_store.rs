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
    DeleteServer(String),
    /// Insert-or-replace one parked-join row (pending joins, rung 1). Goes
    /// through the actor for the same reason every other CRDT write does: the
    /// join handler runs ON the event loop, and `MessageStore::open` there is
    /// a fresh SQLCipher handle + full schema re-parse under a file lock.
    UpsertPendingJoin(Box<crate::storage::messages::PendingJoinRow>),
    DeletePendingJoin(String),
    PruneOps(usize),
    /// READ-ONLY: newest stored message timestamp (ms) per channel, for the
    /// relay catch-up window. Answered on the actor's long-lived connection so
    /// the caller never opens a transient SQLCipher handle — see
    /// `channel_watermarks`.
    ChannelWatermarks {
        server_id: String,
        channel_ids: Vec<String>,
        reply: tokio::sync::oneshot::Sender<HashMap<String, i64>>,
    },
    /// READ-ONLY: one parked-join row, for the "Request again" action. Answered
    /// on the actor's connection for the same reason the watermark read is: the
    /// caller is the swarm event loop and must not open a SQLCipher handle.
    LoadPendingJoin {
        server_id: String,
        reply: tokio::sync::oneshot::Sender<Option<crate::storage::messages::PendingJoinRow>>,
    },
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
/// task.  The swarm task sends save commands via an mpsc channel.
/// Uses batch-drain: `blocking_recv()` waits for the first command, then
/// `try_recv()` drains remaining queued commands.  After draining, only the
/// LATEST `SaveState` per `server_id` is flushed — naturally batching many
/// CRDT ops into one DB write per server.
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

                // Collect the whole drain FIRST, then split reads from writes.
                // Read-only commands are answered OUTSIDE the transaction:
                // `begin_transaction` is `BEGIN IMMEDIATE`, i.e. a RESERVED
                // write lock, and on iOS the DB lives in the App Group
                // container where being suspended while holding a lock is
                // exactly what RunningBoard kills the process for
                // (EXC_CRASH 0xdead10cc). A batch that is all reads never
                // opens a transaction at all.
                let mut writes = Vec::new();
                let mut queued = Some(cmd);
                loop {
                    let Some(cmd) = queued.take().or_else(|| cmd_rx.try_recv().ok()) else {
                        break;
                    };
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
                        CrdtStoreCmd::LoadPendingJoin { server_id, reply } => {
                            let row = store
                                .load_pending_joins()
                                .unwrap_or_default()
                                .into_iter()
                                .find(|r| r.server_id == server_id);
                            let _ = reply.send(row);
                        }
                        other => writes.push(other),
                    }
                }
                if writes.is_empty() {
                    continue;
                }

                let _ = store.begin_transaction();

                for cmd in writes {
                    Self::process_cmd(&store, cmd, &mut pending_states, &mut pending_blobs);
                }

                // Flush batched state saves (one write per server; snapshots
                // serialize HERE — once per drain, on this blocking thread)
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
        });

        Ok(CrdtStore { cmd_tx })
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
                // Keep only the latest state per server (batch)
                pending_states.insert(server_id, PendingState::Json(state_json));
            }
            CrdtStoreCmd::SaveStateSnapshot { server_id, state } => {
                pending_states.insert(server_id, PendingState::Snapshot(state));
            }
            CrdtStoreCmd::SaveBlob { server_id, key, value } => {
                pending_blobs.insert((server_id, key), value);
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
                if let Err(e) = store.delete_server_state(&server_id) {
                    hollow_log!("CrdtStore: failed to delete server {server_id}: {e}");
                }
            }
            // Read-only: split out in the drain loop before the transaction
            // opens, so it never reaches here.
            CrdtStoreCmd::ChannelWatermarks { .. } | CrdtStoreCmd::LoadPendingJoin { .. } => {}
            CrdtStoreCmd::PruneOps(keep) => {
                match store.prune_crdt_ops(keep) {
                    Ok(n) if n > 0 => hollow_log!("[HOLLOW-CRDT] Pruned {n} old crdt_ops rows"),
                    Err(e) => hollow_log!("[HOLLOW-CRDT] Failed to prune crdt_ops: {e}"),
                    _ => {}
                }
            }
        }
    }

    /// Fire-and-forget: persist the latest server state JSON.
    pub fn save_state(&self, server_id: String, state_json: String) {
        let _ = self.cmd_tx.send(CrdtStoreCmd::SaveState { server_id, state_json });
    }

    /// Fire-and-forget: persist the latest server state from a lean snapshot,
    /// serializing on the actor thread at drain time. Prefer this on per-op
    /// paths — the event loop pays a cheap clone instead of a full JSON
    /// serialize (which embeds the server avatar) per op.
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

    /// Fire-and-forget: prune old CRDT ops, keeping `keep_count` per server.
    pub fn prune_ops(&self, keep_count: usize) {
        let _ = self.cmd_tx.send(CrdtStoreCmd::PruneOps(keep_count));
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
    /// `channel_ids` that has one. Channels with no messages are simply absent
    /// from the map.
    ///
    /// The ONE read on this actor, and it exists for a reason: the caller used
    /// to run `MessageStore::open()` per channel on the swarm event loop, and a
    /// fresh handle re-reads and re-parses the whole schema while holding a
    /// file lock. On iOS that lock is on the App Group container, so a
    /// suspension landing inside the window got the process killed
    /// (`EXC_CRASH 0xdead10cc`). Here it is one round trip on a warm
    /// connection, off the event loop, outside any transaction.
    ///
    /// Returns an empty map if the actor is gone (caller falls back to the
    /// full retention window, which is what a missing watermark means anyway).
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
    /// connection, batched, and WITHOUT the caller opening a DB handle — that
    /// per-channel transient open on the event loop is what got the iOS app
    /// killed for holding an App Group file lock across a suspend
    /// (`EXC_CRASH 0xdead10cc`, TestFlight 0.9.5(50)).
    ///
    /// A file-backed DB on purpose: `:memory:` gives every connection its own
    /// empty database, so it could not tell whether the actor sees our writes.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn channel_watermarks_answers_from_the_actor_connection() {
        let dir = tempfile::tempdir().expect("tmp");
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
}
