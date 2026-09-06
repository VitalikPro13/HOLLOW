//! Device-linking orchestration: an EMPTY device pulls a full DB snapshot from a
//! POPULATED sibling.
//!
//! Two entry paths converge on one snapshot push: a 6-char relay code with both
//! devices in `link:{code}`, or the mnemonic path where they already share a
//! master and meet in `inbox:{master}`. The snapshot is the existing
//! `export_backup` zip (`identity.key` included), streamed as
//! `StreamKind::LinkSnapshot` and imported on the receiver's next launch.

use std::collections::{HashMap, HashSet};

use std::sync::Mutex;

use tokio::sync::mpsc;

use crate::hollow_log;
use super::crypto_handler::send_message_to_peer;
use super::file_handler::LinkSnapshotState;
use super::types::{HavenMessage, NetworkEvent};
use super::ws_client::WsCommand;
use super::ws_stream_transfer::{ws_stream_send_bytes, StreamKind};

/// (Receiver) The link CODE this device typed, the passphrase the inbound
/// `.hollow` blob is encrypted with. Process-global because the `LinkSnapshotKey`
/// handler threads no link state. Cleared after use.
static MY_TYPED_LINK_CODE: Mutex<Option<String>> = Mutex::new(None);

pub(crate) fn set_my_link_code(code: &str) {
    if let Ok(mut g) = MY_TYPED_LINK_CODE.lock() {
        *g = Some(code.to_string());
    }
}

pub(crate) fn my_link_code() -> String {
    MY_TYPED_LINK_CODE.lock().ok().and_then(|g| g.clone()).unwrap_or_default()
}

/// Deterministic rendezvous room for a link code — both devices join it so they
/// share a room without needing to know each other's master identity.
pub(crate) fn link_room(code: &str) -> String {
    format!("link:{}", code.to_uppercase())
}

/// (Populated device) Claim a link code on the relay and join its rendezvous room
/// so an empty sibling can reach us by code.
pub(crate) fn handle_claim_link_code(
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    code: &str,
) {
    let _ = ws_cmd_tx.send(WsCommand::ClaimLinkCode { code: code.to_string() });
    let _ = ws_cmd_tx.send(WsCommand::JoinRoom { room_code: link_room(code) });
    // PRIVACY: the code is the passphrase to the identity snapshot — log only
    // its length, never the value (hollow_debug.log gets shared for diagnostics).
    hollow_log!("[HOLLOW-LINK] Claimed link code ({} chars), joined link room", code.len());
}

/// (Populated device) Release the link code + leave its room (cancel / expired).
pub(crate) fn handle_release_link_code(
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    code: &str,
) {
    let _ = ws_cmd_tx.send(WsCommand::ReleaseLinkCode);
    let _ = ws_cmd_tx.send(WsCommand::LeaveRoom { room_code: link_room(code) });
}

/// (Empty device) Join the rendezvous room and ask the relay to resolve the code;
/// the `LinkCodeResolved` event then carries the populated peer_id.
pub(crate) fn handle_resolve_link_code(
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    code: &str,
) {
    let _ = ws_cmd_tx.send(WsCommand::JoinRoom { room_code: link_room(code) });
    let _ = ws_cmd_tx.send(WsCommand::ResolveLinkCode { code: code.to_string() });
    // PRIVACY: see handle_claim_link_code — never log the code value.
    hollow_log!("[HOLLOW-LINK] Resolving link code ({} chars), joined link room", code.len());
}

/// (Empty device) The relay resolved the code to the populated peer. Send a snapshot
/// request to it in the shared `link:{code}` room.
pub(crate) fn handle_link_code_resolved(
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    peer_id: &str,
    include_vault: bool,
    include_files: bool,
) {
    let (msg_count, friend_count, _server_count, has_profile) =
        crate::api::storage::snapshot_state_summary();
    send_message_to_peer(
        ws_cmd_tx, ws_room_peers, peer_id,
        HavenMessage::LinkSnapshotRequest {
            include_vault, include_files, msg_count, friend_count, has_profile,
        },
    );
    hollow_log!("[HOLLOW-LINK] Sent snapshot request to populated peer {peer_id}");
}

/// (Empty device, mnemonic path) Request a snapshot from an already-known sibling.
pub(crate) fn handle_request_link_snapshot(
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    target_peer: &str,
    include_vault: bool,
    include_files: bool,
) {
    let (msg_count, friend_count, _server_count, has_profile) =
        crate::api::storage::snapshot_state_summary();
    send_message_to_peer(
        ws_cmd_tx, ws_room_peers, target_peer,
        HavenMessage::LinkSnapshotRequest {
            include_vault, include_files, msg_count, friend_count, has_profile,
        },
    );
    hollow_log!("[HOLLOW-LINK] Sent snapshot request to sibling {target_peer}");
}

/// (Populated device) An empty device asked for our snapshot: surface a confirm
/// prompt carrying its state summary. The push happens on `AcceptLinkPush`.
pub(crate) async fn handle_inbound_link_request(
    event_tx: &mpsc::Sender<NetworkEvent>,
    sender_peer: &str,
    msg_count: u32,
    friend_count: u32,
    has_profile: bool,
) {
    hollow_log!("[HOLLOW-LINK] Inbound snapshot request from {sender_peer} (their {msg_count} DMs, {friend_count} friends)");
    let _ = event_tx.send(NetworkEvent::SiblingLinkAvailable {
        peer_id: sender_peer.to_string(),
        their_msg_count: msg_count,
        their_friend_count: friend_count,
        their_has_profile: has_profile,
    }).await;
}

/// (Populated device) Build the `.hollow` snapshot encrypted with the link code,
/// tell the target its link_id, then stream the ciphertext as a `LinkSnapshot`.
#[allow(clippy::too_many_arguments)]
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_accept_link_push(
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    target_peer: &str,
    include_vault: bool,
    include_files: bool,
    device_peer_id: &str,
    link_code: &str,
) {
    // Byte-for-byte the same pipeline as a manual export, so the receiver imports
    // it through `import_backup` on next launch, the proven path.
    let blob = match crate::api::storage::export_backup_bytes(link_code, include_vault, include_files) {
        Ok(b) => b,
        Err(e) => {
            hollow_log!("[HOLLOW-LINK] Backup build failed: {e}");
            let _ = event_tx.send(NetworkEvent::LinkFailed {
                link_id: String::new(),
                error: format!("build failed: {e}"),
            }).await;
            return;
        }
    };
    let ciphertext = blob;

    // Stream id carries a "link_" prefix so the progress poll routes LinkProgress.
    // Derive a short session id from the device id + target so it's stable per pair.
    let session = format!("{}_{}", &device_peer_id[device_peer_id.len().saturating_sub(8)..], &target_peer[target_peer.len().saturating_sub(8)..]);
    let link_id = format!("link_{session}");

    // Tell the target the link_id (so it can register the pending stash) — the
    // CODE it already typed is the decryption passphrase, so no key travels here.
    send_message_to_peer(
        ws_cmd_tx, ws_room_peers, target_peer,
        HavenMessage::LinkSnapshotKey {
            link_id: link_id.clone(),
            aes_key: String::new(),
            aes_nonce: String::new(),
        },
    );

    let Some(room) = super::crypto_handler::ws_room_for_peer(ws_room_peers, target_peer) else {
        hollow_log!("[HOLLOW-LINK] No shared room with {target_peer} — cannot stream snapshot");
        let _ = event_tx.send(NetworkEvent::LinkFailed {
            link_id, error: "no shared room with target".to_string(),
        }).await;
        return;
    };

    hollow_log!("[HOLLOW-LINK] Pushing snapshot {link_id} ({} bytes) to {target_peer} in {room}", ciphertext.len());
    let total = ciphertext.len() as u64;
    ws_stream_send_bytes(
        ws_cmd_tx, &room, target_peer,
        &StreamKind::LinkSnapshot, &link_id, &ciphertext,
    ).await;
    // ws_stream_send_bytes only QUEUES chunks into the local WS channel, so it is
    // NOT proof of receipt: completion waits for the receiver's `LinkSnapshotAck`.
    // The sender does not restart; only the receiver replaced its DB.
    hollow_log!("[HOLLOW-LINK] Snapshot {link_id} fully queued to {target_peer} ({total} bytes) — awaiting receiver ack");
}

/// (Empty device) Register the pending snapshot under the announced link_id,
/// carrying the CODE we typed so the completion handler can stash blob and code.
pub(crate) fn handle_inbound_link_key(
    pending_link_snapshots: &mut HashMap<String, LinkSnapshotState>,
    link_id: &str,
    code: String,
) {
    hollow_log!("[HOLLOW-LINK] Registered pending link snapshot {link_id}");
    pending_link_snapshots.insert(link_id.to_string(), LinkSnapshotState { code });
}
