use tokio::sync::mpsc;

use crate::storage::MessageStore;

/// Commands the swarm task can send to persist crypto state.
pub(crate) enum CryptoStoreCmd {
    SaveAccount(String),
    SaveSession { peer_id: String, pickle: String },
}

/// A fire-and-forget persistence actor for Olm state.
///
/// Owns a `rusqlite::Connection` (which is `!Send`) inside a `spawn_blocking`
/// task. The swarm task sends save commands via an mpsc channel.
/// The in-memory `OlmManager` is authoritative; the DB is for restart persistence.
pub(crate) struct CryptoStore {
    cmd_tx: mpsc::UnboundedSender<CryptoStoreCmd>,
}

impl CryptoStore {
    /// Spawn the persistence actor. Opens its own DB connection.
    pub fn open(db_path: String, passphrase: String) -> Result<Self, String> {
        let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel::<CryptoStoreCmd>();

        // Spawn a blocking task that owns the Connection.
        tokio::task::spawn_blocking(move || {
            let store = match MessageStore::open(&db_path, &passphrase) {
                Ok(s) => s,
                Err(e) => {
                    haven_log!("CryptoStore: failed to open DB: {e}");
                    return;
                }
            };

            // Block this OS thread, receiving commands from the async world.
            // We use `blocking_recv` since we're already on a blocking thread.
            while let Some(cmd) = cmd_rx.blocking_recv() {
                match cmd {
                    CryptoStoreCmd::SaveAccount(pickle) => {
                        if let Err(e) = store.save_olm_account(&pickle) {
                            haven_log!("CryptoStore: failed to save account: {e}");
                        }
                    }
                    CryptoStoreCmd::SaveSession { peer_id, pickle } => {
                        if let Err(e) = store.save_olm_session(&peer_id, &pickle) {
                            haven_log!("CryptoStore: failed to save session for {peer_id}: {e}");
                        }
                    }
                }
            }
        });

        Ok(CryptoStore { cmd_tx })
    }

    /// Fire-and-forget: persist the account pickle.
    pub fn save_account(&self, pickle_json: String) {
        let _ = self.cmd_tx.send(CryptoStoreCmd::SaveAccount(pickle_json));
    }

    /// Fire-and-forget: persist a session pickle.
    pub fn save_session(&self, peer_id: String, pickle_json: String) {
        let _ = self.cmd_tx.send(CryptoStoreCmd::SaveSession {
            peer_id,
            pickle: pickle_json,
        });
    }
}
