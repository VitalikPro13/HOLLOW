//! Destruction: one routine that erases this install, and the scopes that tell the
//! rest of the identity first. Keys die FIRST, nothing waits on the network, and the
//! marker plus `perform_pending_wipe` is the guarantee (wiki `security_write_gates`).

use std::path::Path;

use flutter_rust_bridge::frb;

use crate::identity::duress;
use crate::node::NodeCommand;

/// The wipe runs regardless when this elapses: an offline device still erases.
const SIGNAL_BOUND: std::time::Duration = std::time::Duration::from_secs(3);

/// `profiles.json` is deliberately absent: app-level registry, names only.
const WIPE_ENTRIES: &[&str] = &[
    "files",
    "audio_cache",
    "vault_cache",
    "shares",
    "temp",
    "vault",
    "hollow_debug.log",
    "hollow_crash.log",
    "pending_link.hollow",
];

const KEY_FILES: &[&str] = &[
    "identity.key",
    "identity.device",
    "identity.duress",
    "identity.dpapi",
];

fn zero_and_remove(path: &Path) {
    if !path.exists() {
        return;
    }
    if let Ok(len) = std::fs::metadata(path).map(|m| m.len()) {
        let _ = std::fs::write(path, vec![0u8; len as usize]);
    }
    let _ = std::fs::remove_file(path);
}

/// Takes the root explicitly so the harness runs the REAL routine per node.
#[frb(ignore)]
pub(crate) fn destroy_data_root(root: &Path) -> Result<(), String> {
    // 1. The marker first, so a kill halfway through resumes at the next launch.
    std::fs::write(root.join("pending_wipe.marker"), b"1")
        .map_err(|e| format!("Failed to stash the wipe marker: {e}"))?;

    // 2. Keys. Everything else is only as readable as these are.
    for name in KEY_FILES {
        zero_and_remove(&root.join(name));
    }
    // TRAP: the keystore is process-wide, not rooted at `root`, and `delete_key`
    // clears the legacy slot too, so a harness run would erase a real credential.
    #[cfg(not(test))]
    let _ = crate::identity::platform_keystore::delete_key();
    crate::identity::encryption::clear_session_key();
    crate::node::at_rest::forget_stores();

    // 3. The per-file keys. Only the singleton closes; the marker covers the rest.
    close_store_singleton();
    for name in ["messages.db", "messages.db-wal", "messages.db-shm"] {
        let _ = std::fs::remove_file(root.join(name));
    }

    // 4. Content. Unlink only: step 2 already made these bytes meaningless.
    for name in WIPE_ENTRIES {
        let path = root.join(name);
        let _ = if path.is_dir() {
            std::fs::remove_dir_all(&path)
        } else {
            std::fs::remove_file(&path)
        };
    }
    hollow_log!("[HOLLOW-DESTROY] Local data destroyed");
    Ok(())
}

fn close_store_singleton() {
    if let Ok(mut guard) = super::storage::get_store().lock() {
        *guard = None;
    }
}

/// Scope (a), and the tail of every other. Leaves the node RUNNING for Dart's step 5.
#[frb]
pub fn destroy_local() -> Result<(), String> {
    let root = crate::identity::data_dir()?;
    let out = destroy_data_root(&root);
    // Only once the wipe has actually run: an unacked entry is re-delivered.
    let _ = super::network::send_node_command(NodeCommand::KillAck);
    out
}

/// `scope` is `device` | `device_revoke` | `identity`; its signal never blocks the wipe.
#[frb]
pub fn destroy_with_scope(scope: String, notify_friends: bool) -> Result<(), String> {
    duress::scope_byte(&scope)?;
    publish_scope(&scope, notify_friends);
    destroy_local()
}

fn publish_scope(scope: &str, notify_friends: bool) {
    match scope {
        duress::SCOPE_DEVICE_REVOKE => {
            let (tx, rx) = tokio::sync::oneshot::channel();
            if super::network::send_node_command(
                NodeCommand::PublishSelfRevocation { reply: tx },
            )
            .is_ok()
            {
                wait_for(rx);
            }
        }
        duress::SCOPE_IDENTITY => {
            let (tx, rx) = tokio::sync::oneshot::channel();
            if super::network::send_node_command(NodeCommand::PublishDestroyIdentity {
                targets: Vec::new(),
                notify_friends,
                reply: tx,
            })
            .is_ok()
            {
                wait_for(rx);
            }
            let _ = super::network::send_node_command(NodeCommand::UnregisterPushToken);
        }
        _ => {}
    }
}

fn wait_for<T>(rx: tokio::sync::oneshot::Receiver<T>) {
    let rt = super::network::get_runtime();
    let _ = rt.block_on(async { tokio::time::timeout(SIGNAL_BOUND, rx).await });
}

/// Called with the WRONG password by definition, so nothing can be signed and a cold
/// launch destroys locally only. A running node still holds the master key.
#[frb(ignore)]
pub(crate) fn run_duress(cfg: &duress::DuressConfig) {
    hollow_log!("[HOLLOW-DESTROY] Duress code entered");
    publish_scope(&cfg.scope, cfg.notify_friends);
    let _ = destroy_local();
}

/// Drives the conversation banner. `None` = we were never told.
#[frb]
pub fn identity_destroyed_at(master_peer_id: String) -> Option<i64> {
    let store = super::storage::get_store();
    let guard = store.lock().ok()?;
    let ms = guard.as_ref()?;
    let master = super::network::identity_for_persisted(master_peer_id);
    crate::node::destroy::identity_destroyed_at(ms, &master).filter(|v| *v > 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seed_root(root: &Path) {
        for name in KEY_FILES {
            std::fs::write(root.join(name), b"key material").unwrap();
        }
        std::fs::write(root.join("messages.db"), b"ciphertext").unwrap();
        std::fs::write(root.join("profiles.json"), b"{}").unwrap();
        std::fs::write(root.join("hollow.lock"), b"").unwrap();
        std::fs::create_dir_all(root.join("files")).unwrap();
        std::fs::write(root.join("files").join("a.bin"), b"HFE1 ciphertext").unwrap();
    }

    /// Twice must converge, and a kill after the key step still ends clean.
    #[test]
    fn wipe_routine_is_idempotent_and_marker_resumes() {
        let _g = crate::node::resolver::test_lock();
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        seed_root(root);

        destroy_data_root(root).expect("first wipe");
        destroy_data_root(root).expect("second wipe is a no-op, not an error");

        for name in KEY_FILES {
            assert!(!root.join(name).exists(), "{name} must be gone");
        }
        assert!(!root.join("files").exists());
        assert!(root.join("pending_wipe.marker").exists(), "the marker resumes the wipe");
        assert!(root.join("profiles.json").exists(), "the profile registry is app config");

        std::fs::write(root.join("messages.db"), b"an open file we could not unlink").unwrap();
        // SAFETY: serialized by the crate test lock.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", root) };
        super::super::storage::perform_pending_wipe().expect("boot wipe");

        assert!(!root.join("messages.db").exists(), "the boot wipe finishes the job");
        assert!(!root.join("pending_wipe.marker").exists(), "the marker is cleared last");
        assert!(root.join("profiles.json").exists());
        assert!(root.join("hollow.lock").exists(), "an instance lock survives");
    }
}
