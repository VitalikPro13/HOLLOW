use tokio::sync::mpsc;

use crate::storage::messages::MessageStore;

use super::operations::CrdtOp;

/// Commands for fire-and-forget CRDT persistence.
pub enum CrdtStoreCmd {
    SaveServerState {
        server_id: String,
        state_json: String,
    },
    InsertOp {
        op: CrdtOp,
    },
    SaveHlcState {
        physical_ms: u64,
        counter: u32,
        actor: String,
    },
}

/// Async persistence actor for CRDT state.
///
/// Follows the same pattern as `CryptoStore`: owns a database connection
/// on a blocking thread, receives commands via an unbounded channel.
pub struct CrdtStore {
    cmd_tx: mpsc::UnboundedSender<CrdtStoreCmd>,
}

impl CrdtStore {
    /// Open the store. Spawns a blocking background task that owns the DB connection.
    pub fn open(db_path: String, passphrase: String) -> Result<Self, String> {
        let store =
            MessageStore::open(&db_path, &passphrase).map_err(|e| format!("CrdtStore open: {e}"))?;

        let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel::<CrdtStoreCmd>();

        tokio::task::spawn_blocking(move || {
            while let Some(cmd) = cmd_rx.blocking_recv() {
                match cmd {
                    CrdtStoreCmd::SaveServerState {
                        server_id,
                        state_json,
                    } => {
                        if let Err(e) = store.save_server_state(&server_id, &state_json) {
                            eprintln!("[CrdtStore] save_server_state error: {e}");
                        }
                    }
                    CrdtStoreCmd::InsertOp { op } => {
                        if let Err(e) = store.insert_crdt_op(&op) {
                            eprintln!("[CrdtStore] insert_crdt_op error: {e}");
                        }
                    }
                    CrdtStoreCmd::SaveHlcState {
                        physical_ms,
                        counter,
                        actor,
                    } => {
                        if let Err(e) = store.save_hlc_state(physical_ms, counter, &actor) {
                            eprintln!("[CrdtStore] save_hlc_state error: {e}");
                        }
                    }
                }
            }
        });

        Ok(Self { cmd_tx })
    }

    /// Persist a server's full CRDT state (fire-and-forget).
    pub fn save_server_state(&self, server_id: String, state_json: String) {
        let _ = self
            .cmd_tx
            .send(CrdtStoreCmd::SaveServerState {
                server_id,
                state_json,
            });
    }

    /// Persist a single CRDT operation (fire-and-forget).
    pub fn insert_op(&self, op: CrdtOp) {
        let _ = self.cmd_tx.send(CrdtStoreCmd::InsertOp { op });
    }

    /// Persist HLC state (fire-and-forget).
    pub fn save_hlc_state(&self, physical_ms: u64, counter: u32, actor: String) {
        let _ = self.cmd_tx.send(CrdtStoreCmd::SaveHlcState {
            physical_ms,
            counter,
            actor,
        });
    }
}
