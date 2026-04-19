// Hollow Share — FFI surface (Phase 7A).
//
// Each function pushes a NodeCommand into the swarm event loop and returns
// immediately. Results stream back via watch_network_events as Share* events.

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
    let state = guard.as_ref().ok_or("Node is not running")?;
    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::ShareCreate { source_path }))
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
    let state = guard.as_ref().ok_or("Node is not running")?;
    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::ShareOpenLink { link }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Begin downloading after ShareManifestReady.
#[frb]
pub fn share_start_download(root_hash: String, save_dir: String, link: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;
    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::ShareStart { root_hash, save_dir, link }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Stop an in-flight download. Keeps the partial file + bitmap so the next
/// share_start_download resumes from where we left off.
#[frb]
pub fn share_cancel(root_hash: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;
    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::ShareCancel { root_hash }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Toggle seeding for a completed share.
#[frb]
pub fn share_set_seeding(root_hash: String, seeding: bool) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;
    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::ShareSetSeeding { root_hash, seeding }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Drop a share entry. If `delete_file = true`, also unlinks the on-disk file
/// (and any partial download).
#[frb]
pub fn share_remove(root_hash: String, delete_file: bool) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;
    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::ShareRemove { root_hash, delete_file }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

/// Enumerate persisted shares. Result returned via NetworkEvent::ShareList.
#[frb]
pub fn share_list() -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let state = guard.as_ref().ok_or("Node is not running")?;
    let rt = get_runtime();
    rt.block_on(state.cmd_tx.send(node::NodeCommand::ShareList))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}
