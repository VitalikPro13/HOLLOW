// Hollow Share FFI: each function pushes a NodeCommand into the swarm loop and returns
// immediately, with results streaming back as Share* network events.

use flutter_rust_bridge::frb;

use crate::node;
use super::network::{get_node, get_runtime};

/// Pure helper: parse a hollow://share/... link into its root_hash + key.
/// No I/O, no network — safe to call from any thread.
#[frb]
pub fn share_decode_link(link: String) -> Result<ShareLinkInfo, String> {
    let info = node::share_handler::decode_link(&link)?;
    Ok(ShareLinkInfo {
        root_hash: info.root_hash_hex(),
        room_id: info.room_id(),
    })
}

pub struct ShareLinkInfo {
    pub root_hash: String,
    pub room_id: String,
}

/// Build a manifest from a local file, encrypt every chunk with a fresh
/// random key, persist the share row, write the encrypted stream to
/// `~/.hollow/shares/{root_hash}.{ext}`, join the swarm room, start seeding.
/// Emits NetworkEvent::ShareCreated on success or ShareFailed on error.
#[frb]
pub fn share_create_from_file(source_path: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    // Drop the mutex before the send: holding it across block_on(send) serializes
    // every other FFI call.
    drop(guard);
    let rt = get_runtime();
    rt.block_on(cmd_tx.send(node::NodeCommand::ShareCreate { source_path }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Decode a share link, persist a placeholder row, join the swarm room, and
/// queue a manifest request. Emits NetworkEvent::ShareManifestReady when the
/// manifest arrives (or ShareFailed on error).
#[frb]
pub fn share_open_link(link: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);
    let rt = get_runtime();
    rt.block_on(cmd_tx.send(node::NodeCommand::ShareOpenLink { link, server_id: None, context_type: None }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Begin downloading after ShareManifestReady. `sequential` fetches chunks in order
/// instead of rarest-first, for progressive video streaming.
#[frb]
pub fn share_start_download(root_hash: String, save_dir: String, link: String, sequential: bool) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);
    let rt = get_runtime();
    rt.block_on(cmd_tx.send(node::NodeCommand::ShareStart { root_hash, save_dir, link, sequential }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Stop an in-flight download. Keeps the partial file + bitmap so the next
/// share_start_download resumes from where we left off.
#[frb]
pub fn share_cancel(root_hash: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);
    let rt = get_runtime();
    rt.block_on(cmd_tx.send(node::NodeCommand::ShareCancel { root_hash }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Toggle seeding for a completed share.
#[frb]
pub fn share_set_seeding(root_hash: String, seeding: bool) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);
    let rt = get_runtime();
    rt.block_on(cmd_tx.send(node::NodeCommand::ShareSetSeeding { root_hash, seeding }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Drop a share entry. If `delete_file = true`, also unlinks the on-disk file
/// (and any partial download).
#[frb]
pub fn share_remove(root_hash: String, delete_file: bool) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);
    let rt = get_runtime();
    rt.block_on(cmd_tx.send(node::NodeCommand::ShareRemove { root_hash, delete_file }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Start a hidden Share download from a raw root_hash and key, which is what a receiver
/// does when a FileHeader carries a ShareRef.
#[frb]
pub fn share_start_from_ref(root_hash: String, key_hex: String, save_dir: String, sequential: bool, server_id: Option<String>, context_type: Option<String>) -> Result<(), String> {
    let key_bytes = hex::decode(&key_hex)
        .map_err(|e| format!("Invalid key hex: {e}"))?;
    if key_bytes.len() != 32 {
        return Err(format!("Key must be 32 bytes, got {}", key_bytes.len()));
    }
    let mut root = [0u8; 32];
    let root_bytes = hex::decode(&root_hash)
        .map_err(|e| format!("Invalid root_hash hex: {e}"))?;
    if root_bytes.len() != 32 {
        return Err(format!("Root hash must be 32 bytes, got {}", root_bytes.len()));
    }
    root.copy_from_slice(&root_bytes);
    let mut key = [0u8; 32];
    key.copy_from_slice(&key_bytes);

    let link = node::share_handler::encode_link(&root, &key);
    let node_lock = get_node();
    let guard = node_lock.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);
    let rt = get_runtime();
    rt.block_on(cmd_tx.send(node::NodeCommand::ShareOpenLink { link: link.clone(), server_id, context_type }))
        .map_err(|e| format!("Failed to send open command: {e}"))?;
    Ok(())
}

/// Enumerate persisted shares. Result returned via NetworkEvent::ShareList.
#[frb]
pub fn share_list() -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);
    let rt = get_runtime();
    rt.block_on(cmd_tx.send(node::NodeCommand::ShareList))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Evict vault cache files that exceed the 1 GB cap.
/// `exempt_paths` lists files that should NOT be evicted (e.g. currently playing video).
/// Returns bytes freed.
#[frb]
pub fn evict_vault_cache(exempt_paths: Vec<String>) -> Result<u64, String> {
    let exempt: std::collections::HashSet<std::path::PathBuf> =
        exempt_paths.iter().map(std::path::PathBuf::from).collect();
    crate::vault::pipeline::evict_cache_if_needed(
        crate::vault::pipeline::VAULT_CACHE_CAP,
        &exempt,
    )
}

/// Move a completed share-backed file out of the vault cache into the files directory
/// and enable seeding, behind the "Keep & Seed" action. Returns the new path.
#[frb]
pub fn share_keep_and_seed(root_hash: String) -> Result<String, String> {
    use crate::identity::data_dir;

    let new_path_str = {
        let store_lock = super::storage::get_store();
        let store_guard = store_lock.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        let store = store_guard.as_ref().ok_or("Message store not open")?;

        let share = store.load_share(&root_hash)?
            .ok_or("Share not found")?;
        let old_path = share.disk_path
            .ok_or("Share has no disk_path. Is it still transferring?")?;

        let old = std::path::PathBuf::from(&old_path);
        if !old.exists() {
            return Err(format!("Source file does not exist: {old_path}"));
        }

        let files_dir = data_dir()
            .map_err(|e| format!("data_dir: {e}"))?
            .join("files");
        std::fs::create_dir_all(&files_dir)
            .map_err(|e| format!("create files dir: {e}"))?;

        let file_name = old.file_name()
            .ok_or("Invalid file path")?;
        let new_path = files_dir.join(file_name);

        std::fs::copy(&old, &new_path)
            .map_err(|e| format!("Failed to copy file: {e}"))?;
        let _ = std::fs::remove_file(&old);

        let result = new_path.to_string_lossy().to_string();
        store.update_share_disk_path(&root_hash, &result)?;
        store.set_share_seeding(&root_hash, true)?;
        result
    };

    let node_lock = get_node();
    let guard = node_lock.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    if let Some(state) = guard.as_ref() {
        let rt = get_runtime();
        let _ = rt.block_on(state.cmd_tx.send(node::NodeCommand::ShareSetSeeding {
            root_hash,
            seeding: true,
        }));
    }

    Ok(new_path_str)
}
