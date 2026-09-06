use tokio::sync::mpsc;

use crate::storage::MessageStore;

/// Commands the swarm task can send to persist crypto state.
pub(crate) enum CryptoStoreCmd {
    SaveAccount(String),
    SaveSession { peer_id: String, pickle: String },
    DeleteSession { peer_id: String },
    SaveMlsIdentity { signer: Vec<u8>, credential: Vec<u8>, storage: Vec<u8> },
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

            let mut backlog = crate::sentinel::BacklogLatch::new("crypto_store", 256);
            while let Some(cmd) = cmd_rx.blocking_recv() {
                backlog.observe(cmd_rx.len());
                match cmd {
                    CryptoStoreCmd::SaveAccount(pickle) => {
                        if let Err(e) = store.save_olm_account(&pickle) {
                            hollow_log!("CryptoStore: failed to save account: {e}");
                        }
                    }
                    CryptoStoreCmd::SaveSession { peer_id, pickle } => {
                        if let Err(e) = store.save_olm_session(&peer_id, &pickle) {
                            hollow_log!("CryptoStore: failed to save session for {peer_id}: {e}");
                        }
                    }
                    CryptoStoreCmd::DeleteSession { peer_id } => {
                        if let Err(e) = store.delete_olm_session(&peer_id) {
                            hollow_log!("CryptoStore: failed to delete session for {peer_id}: {e}");
                        }
                    }
                    CryptoStoreCmd::SaveMlsIdentity { signer, credential, storage } => {
                        if let Err(e) = store.save_mls_identity(&signer, &credential, &storage) {
                            hollow_log!("CryptoStore: failed to save MLS identity: {e}");
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

    /// Fire-and-forget: delete a persisted Olm session.
    pub fn delete_session(&self, peer_id: String) {
        let _ = self.cmd_tx.send(CryptoStoreCmd::DeleteSession { peer_id });
    }

    /// Fire-and-forget: persist MLS identity (signer, credential, storage).
    pub fn save_mls_identity(&self, signer: Vec<u8>, credential: Vec<u8>, storage: Vec<u8>) {
        let _ = self.cmd_tx.send(CryptoStoreCmd::SaveMlsIdentity {
            signer, credential, storage,
        });
    }
}
