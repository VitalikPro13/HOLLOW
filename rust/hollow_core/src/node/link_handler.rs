//! Multi-device device-linking orchestration (Step 4).
//!
//! Lets an EMPTY device pull a full DB snapshot from a POPULATED sibling. Two
//! entry paths converge on the same snapshot push:
//!   - **Code path:** populated device claims a 6-char relay code + joins `link:{code}`;
//!     empty device resolves the code + joins `link:{code}`, then requests the snapshot.
//!   - **Mnemonic path:** the empty device already shares the master, meets the populated
//!     device in `inbox:{master}` (sibling inbox-proof), and requests the snapshot there.
//!
//! The snapshot itself is the existing `export_backup` zip (incl. `identity.key`),
//! AES-256-GCM encrypted with a one-time random key, streamed via
//! `ws_stream_transfer::ws_stream_send_bytes` as `StreamKind::LinkSnapshot`. The
//! receiver registers the key in `pending_link_snapshots`; `file_handler` decrypts
//! and imports on completion.

use std::collections::{HashMap, HashSet};

use std::sync::Mutex;

use tokio::sync::mpsc;

use crate::hollow_log;
use super::crypto_handler::send_message_to_peer;
use super::file_handler::LinkSnapshotState;
use super::types::{HavenMessage, NetworkEvent};
use super::ws_client::WsCommand;
use super::ws_stream_transfer::{ws_stream_send_bytes, StreamKind};

/// (Receiver) The link CODE this device typed — the passphrase the inbound `.hollow`
/// blob is encrypted with. Process-global so the `LinkSnapshotKey` handler (deep in
/// `handle_incoming_request`, which doesn't thread link state) can read it. Set when
/// the user enters a code; cleared after use.
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
    hollow_log!("[HOLLOW-LINK] Claimed link code {code}, joined {}", link_room(code));
}

/// (Populated device) Release the link code + leave its room (cancel / expired).
pub(crate) fn handle_release_link_code(
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    code: &str,
) {
    let _ = ws_cmd_tx.send(WsCommand::ReleaseLinkCode);
    let _ = ws_cmd_tx.send(WsCommand::LeaveRoom { room_code: link_room(code) });
}

/// (Empty device) Begin resolving a link code: join its rendezvous room and ask the
/// relay to resolve the code to the populated peer. The `LinkCodeResolved` WsEvent
/// then carries the populated peer_id, at which point we send the snapshot request.
pub(crate) fn handle_resolve_link_code(
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    code: &str,
) {
    let _ = ws_cmd_tx.send(WsCommand::JoinRoom { room_code: link_room(code) });
    let _ = ws_cmd_tx.send(WsCommand::ResolveLinkCode { code: code.to_string() });
    hollow_log!("[HOLLOW-LINK] Resolving link code {code}, joined {}", link_room(code));
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

/// (Populated device) An empty device asked for our snapshot. Surface a confirm
/// prompt to the UI (carrying the requester's state summary for direction detect).
/// The actual push happens on `AcceptLinkPush`.
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

/// (Populated device) Build the snapshot, encrypt with a one-time random key, send
/// the key to the target, then stream the ciphertext as a `LinkSnapshot`.
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
    // Build the FULL `.hollow` backup blob, encrypted with the link CODE as the
    // passphrase — byte-for-byte the same pipeline as a manual export. The receiver
    // stashes it and imports via `import_backup` on next launch (the proven path).
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

    // Stream the encrypted .hollow blob in the room shared with the target.
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
    // ws_stream_send_bytes only QUEUES every chunk into the local WS command channel —
    // it returns long before those bytes reach the relay, let alone the target. So this
    // is NOT proof of receipt: emitting LinkPushComplete here made the sender flash
    // "Data sent" while the receiver was only just starting its progress bar. Instead
    // we stay on the "sending" spinner and wait for the receiver to send back a
    // `LinkSnapshotAck` (it does so right after it stashes the full blob); the dispatch
    // arm for that ack emits LinkPushComplete. The sender does NOT restart; only the
    // receiver replaced its DB.
    hollow_log!("[HOLLOW-LINK] Snapshot {link_id} fully queued to {target_peer} ({total} bytes) — awaiting receiver ack");
}

/// (Empty device) The populated device announced the link_id. Register the pending
/// snapshot keyed by it, carrying the CODE we typed (the `.hollow` blob's passphrase)
/// so the completion handler can stash blob+code for a next-launch `import_backup`.
pub(crate) fn handle_inbound_link_key(
    pending_link_snapshots: &mut HashMap<String, LinkSnapshotState>,
    link_id: &str,
    code: String,
) {
    hollow_log!("[HOLLOW-LINK] Registered pending link snapshot {link_id}");
    pending_link_snapshots.insert(link_id.to_string(), LinkSnapshotState { code });
}
