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
    PruneOps(usize),
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

            while let Some(cmd) = cmd_rx.blocking_recv() {
                let _ = store.begin_transaction();

                // Process first command
                Self::process_cmd(&store, cmd, &mut pending_states, &mut pending_blobs);

                // Drain all queued commands without blocking
                while let Ok(cmd) = cmd_rx.try_recv() {
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
            CrdtStoreCmd::DeleteServer(server_id) => {
                pending_states.remove(&server_id);
                if let Err(e) = store.delete_server_state(&server_id) {
                    hollow_log!("CrdtStore: failed to delete server {server_id}: {e}");
                }
            }
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

    /// Fire-and-forget: prune old CRDT ops, keeping `keep_count` per server.
    pub fn prune_ops(&self, keep_count: usize) {
        let _ = self.cmd_tx.send(CrdtStoreCmd::PruneOps(keep_count));
    }
}
