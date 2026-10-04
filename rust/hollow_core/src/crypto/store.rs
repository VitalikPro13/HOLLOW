use tokio::sync::mpsc;

use crate::storage::MessageStore;

/// Commands the swarm task can send to persist crypto state.
pub(crate) enum CryptoStoreCmd {
    SaveAccount(String),
    SaveSession { peer_id: String, pickle: String },
    DeleteSession { peer_id: String },
    SaveReadMark { peer_id: String, sealed_ms: i64 },
    SaveMlsIdentity { signer: Vec<u8>, credential: Vec<u8>, storage: Vec<u8> },
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

fn write(store: &MessageStore, cmd: CryptoStoreCmd) {
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

            let mut backlog = crate::sentinel::BacklogLatch::new("crypto_store", 256);
            while let Some(first) = cmd_rx.blocking_recv() {
                backlog.observe(cmd_rx.len());
                let mut batch = vec![first];
                while batch.len() < WRITE_BATCH
                    && let Ok(next) = cmd_rx.try_recv()
                {
                    batch.push(next);
                }
                for cmd in coalesce(batch) {
                    write(&store, cmd);
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
            CryptoStoreCmd::SaveSession { peer_id: "a".into(), pickle: "p".into() },
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
}
