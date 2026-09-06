use std::collections::HashMap;
use std::time::Duration;

use base64::Engine;
use tokio::sync::mpsc;

use crate::crdt::operations::{CrdtPayload, Permission};
use crate::crdt::server_state::ServerState;
use crate::crypto::{CryptoStore, MlsManager, OlmManager};
use super::crdt_store::CrdtStore;
use super::crypto_handler::{
    peer_is_reachable, send_message_to_peer, send_message_to_peer_in_room, send_mls_broadcast,
    persist_mls_state, send_encrypted_message, send_raw_to_identity, online_devices_for,
    BackfillSig, PkCache,
};
use super::types::*;

/// Multi-device: fan pre-serialized bytes to EVERY online device of EVERY server
/// member except our own identity. Members are master-keyed and a master has no
/// socket, so a direct `send_message_to_peer(master)` is dropped: every
/// member-broadcast loop must go through this.
fn broadcast_raw_to_members(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    state: &ServerState,
    local_peer_str: &str,
    data: Vec<u8>,
) {
    for member_peer_str in state.members.keys() {
        if super::resolver::same_identity(member_peer_str, local_peer_str) { continue; }
        send_raw_to_identity(ws_cmd_tx, ws_room_peers, member_peer_str, data.clone());
    }
}

/// Multi-device: fan pre-serialized bytes to our OWN online sibling devices,
/// EXCLUDING the acting device (`local_device_id`).
///
/// The remaining-member broadcast skips the actor's own identity, so a moderation
/// or leave op, and the MLS leaf-removal commit behind it, never reaches a
/// person's OTHER devices. The acting device is excluded because it already
/// applied the change and because re-feeding a node its OWN MLS commit fails
/// `process_commit` and self-drops the group. Returns the sibling count reached.
pub(crate) fn fan_to_own_siblings(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    local_peer_str: &str,
    local_device_id: &str,
    data: Vec<u8>,
) -> usize {
    let mut sent = 0;
    for dev in online_devices_for(ws_room_peers, local_peer_str) {
        if dev == local_device_id { continue; } // never re-feed the acting device
        if let Some(room) = super::crypto_handler::ws_room_for_peer(ws_room_peers, &dev) {
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
                room_code: room,
                target_peer: dev.clone(),
                data: data.clone(),
            });
            sent += 1;
        }
    }
    sent
}

/// Convenience: broadcast a `CrdtOpBroadcast` (plaintext fallback) to all members'
/// devices. Used by every sync-handler CRDT op whose MLS broadcast failed or was
/// absent.
///
/// Tier 2 (`reports/LARGE_SERVER_SCALING_2026.md`): when the server's gossip
/// overlay has live data channels the op floods over the P2P mesh instead, so the
/// sender stops paying O(members x devices) relay uploads and the relay stops
/// seeing plaintext op JSON. Falls back to the relay fan-out whenever the mesh
/// cannot carry it.
fn broadcast_crdt_op_to_members(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    gossip_overlays: &mut HashMap<String, super::gossip::GossipOverlay>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    state: &ServerState,
    local_peer_str: &str,
    server_id: &str,
    op_json: &str,
) {
    if super::gossip_relay::flood_crdt_op(gossip_overlays, event_tx, server_id, op_json, None) > 0 {
        return;
    }
    let data = serde_json::to_vec(&HavenMessage::CrdtOpBroadcast {
        server_id: server_id.to_string(),
        op_json: op_json.to_string(),
    }).unwrap_or_default();
    broadcast_raw_to_members(ws_cmd_tx, ws_room_peers, state, local_peer_str, data);
}

/// Multi-device: all MLS-credential ids belonging to one identity, the master plus
/// every known device id. Used to remove EVERY leaf of a kicked or banned human in
/// one commit, since a leaf may be an offline device.
fn identity_credential_ids(master: &str) -> Vec<String> {
    let m = super::resolver::resolve(master); // normalize if a device id slipped in
    let mut ids = super::resolver::devices_for(&m);
    ids.push(m);
    ids
}

// ── Shared authoring / broadcast plumbing ─────────────────────────────
//
// Nearly every handler in this file authors one CRDT op and pushes it out the
// same way; the helpers below hold that shape ONCE.

/// Emit the standard permission-denied `Error` event. Returns `true` so
/// handlers can `return deny(...).await` straight out.
async fn deny(event_tx: &EventTx, message: &str) -> bool {
    let _ = event_tx.send(NetworkEvent::Error {
        message: message.to_string(),
    }).await;
    true
}

/// Author one CRDT op: create → apply locally → persist (op log + snapshot).
fn author_op(
    state: &mut ServerState,
    crdt_store: &CrdtStore,
    server_id: &str,
    payload: CrdtPayload,
) -> crate::crdt::operations::CrdtOp {
    let op = state.create_op(payload);
    let _ = state.apply_op(&op);
    crdt_store.insert_op(op.clone());
    crdt_store.save_state_snapshot(server_id.to_string(), state);
    op
}

/// Broadcast an authored op MLS-first, then ALWAYS also as the plaintext
/// `CrdtOpBroadcast` twin (idempotent: op_log dedups and receivers re-validate).
/// An MLS broadcast is confidential, but a receiver at a skewed epoch drops it
/// silently with no recovery, permanently losing the op.
#[allow(clippy::too_many_arguments)]
fn broadcast_op_mls_first(
    mls: &mut Option<MlsManager>,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    event_tx: &EventTx,
    state: &ServerState,
    local_peer_str: &str,
    server_id: &str,
    op: &crate::crdt::operations::CrdtOp,
    crypto_store: &CryptoStore,
) {
    let Ok(op_json) = serde_json::to_string(op) else { return };
    if mls.as_ref().is_some_and(|m| m.has_group(server_id)) {
        let envelope = MessageEnvelope::CrdtOp { sid: server_id.to_string(), op_json: op_json.clone() };
        if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, server_id, &envelope, crypto_store) {
            hollow_log!("[HOLLOW-MLS] CrdtOp broadcast failed, falling back to plaintext: {e}");
        }
    }
    broadcast_crdt_op_to_members(
        ws_cmd_tx, ws_room_peers, gossip_overlays, event_tx, state, local_peer_str, server_id, &op_json,
    );
}

/// Broadcast a plaintext-only op to all members AND fan it to our OWN online
/// sibling devices (the master-keyed member broadcast skips our identity, so
/// without the fan our other devices only converge on restart / next sync).
#[allow(clippy::too_many_arguments)]
fn broadcast_op_plaintext_with_fan(
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    event_tx: &EventTx,
    state: &ServerState,
    local_peer_str: &str,
    local_device_id: &str,
    server_id: &str,
    op: &crate::crdt::operations::CrdtOp,
) {
    let Ok(op_json) = serde_json::to_string(op) else { return };
    broadcast_crdt_op_to_members(
        ws_cmd_tx, ws_room_peers, gossip_overlays, event_tx, state, local_peer_str, server_id, &op_json,
    );
    let data = serde_json::to_vec(&HavenMessage::CrdtOpBroadcast {
        server_id: server_id.to_string(),
        op_json,
    }).unwrap_or_default();
    fan_to_own_siblings(ws_cmd_tx, ws_room_peers, local_peer_str, local_device_id, data);
}

/// Permission gate for [`author_broadcast_op`], evaluated against the acting
/// (local) peer inside the server-state borrow.
enum OpGate<'a> {
    /// `state.has_permission(local, bits)`.
    Perm(u32),
    /// `state.can_mute(local, target)`.
    CanMute(&'a str),
    /// MANAGE_ROLES and the actor outranks the named target role.
    ManageRolesOutranking(&'a str),
    /// The target is the local peer itself, or fall back to `Perm(bits)`.
    SelfOrPerm(&'a str, u32),
    /// No gate (e.g. changing our own storage pledge).
    Always,
}

fn gate_allows(state: &ServerState, local_peer: &str, gate: &OpGate<'_>) -> bool {
    use crate::crdt::operations::MemberRole;
    match gate {
        OpGate::Perm(bits) => state.has_permission(local_peer, *bits),
        OpGate::CanMute(target) => state.can_mute(local_peer, target),
        OpGate::ManageRolesOutranking(role_name) => {
            let target = MemberRole::from_str(role_name);
            state.has_permission(local_peer, Permission::MANAGE_ROLES)
                && state.get_role(local_peer).outranks(&target)
        }
        OpGate::SelfOrPerm(target, bits) => {
            *target == local_peer || state.has_permission(local_peer, *bits)
        }
        OpGate::Always => true,
    }
}

/// How [`author_broadcast_op`] pushes the authored op out, carrying exactly
/// the state that route needs.
enum OpBroadcast<'a> {
    /// MLS broadcast when the server group exists, plus the plaintext twin.
    MlsFirst { mls: &'a mut Option<MlsManager>, crypto_store: &'a CryptoStore },
    /// Plaintext-only op (no MLS path) + own-sibling fan.
    PlaintextWithFan { local_device_id: &'a str },
}

/// Shared driver for locally-authored server CRDT ops: permission gate, author
/// (create, apply, persist), emit the prebuilt UI event, broadcast.
///
/// `denied_msg` = the user-facing `Error` on a failed gate (`None` = silent deny).
/// Returns `true` when the gate denied, so callers `continue`.
#[allow(clippy::too_many_arguments)]
async fn author_broadcast_op(
    server_states: &mut ServerStates,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    local_peer_str: &str,
    server_id: &str,
    gate: OpGate<'_>,
    denied_msg: Option<&str>,
    payload: CrdtPayload,
    log_label: &str,
    event: NetworkEvent,
    broadcast: OpBroadcast<'_>,
    crdt_store: &CrdtStore,
) -> bool {
    let Some(state) = server_states.get_mut(server_id) else { return false };
    if !gate_allows(state, local_peer_str, &gate) {
        hollow_log!("[HOLLOW-CRDT] Permission denied: {log_label} in {server_id}");
        if let Some(msg) = denied_msg {
            return deny(event_tx, msg).await;
        }
        return true;
    }
    hollow_log!("[HOLLOW-CRDT] {log_label} in {server_id}");
    let op = author_op(state, crdt_store, server_id, payload);
    let _ = event_tx.send(event).await;
    match broadcast {
        OpBroadcast::MlsFirst { mls, crypto_store } => broadcast_op_mls_first(
            mls, ws_cmd_tx, ws_room_peers, gossip_overlays, event_tx, state, local_peer_str, server_id, &op, crypto_store,
        ),
        OpBroadcast::PlaintextWithFan { local_device_id } => broadcast_op_plaintext_with_fan(
            ws_cmd_tx, ws_room_peers, gossip_overlays, event_tx, state, local_peer_str, local_device_id, server_id, &op,
        ),
    }
    false
}

// ── Shared member-removal plumbing (kick / ban / leave) ───────────────

/// Every OTHER member (master-keyed), collected BEFORE `apply_op` removes the
/// target from `state.members`.
fn other_member_targets(state: &ServerState, local_peer: &str) -> Vec<String> {
    state.members.keys().filter(|m| m.as_str() != local_peer).cloned().collect()
}

/// Fan a member-removal CRDT op to the remaining members (collected before the
/// removal applied) and to our OWN online siblings, which the master-keyed member
/// list excludes. `skip` = the removed identity, which gets a
/// `MemberKickBroadcast` instead; `None` for a voluntary leave.
#[allow(clippy::too_many_arguments)]
fn broadcast_removal_op(
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    targets: &[String],
    skip: Option<&str>,
    local_peer_str: &str,
    local_device_id: &str,
    server_id: &str,
    op: &crate::crdt::operations::CrdtOp,
) {
    let Ok(op_json) = serde_json::to_string(op) else { return };
    let data = serde_json::to_vec(&HavenMessage::CrdtOpBroadcast {
        server_id: server_id.to_string(),
        op_json,
    }).unwrap_or_default();
    for member in targets {
        if skip.is_some_and(|s| member == s) { continue; }
        send_raw_to_identity(ws_cmd_tx, ws_room_peers, member, data.clone());
    }
    fan_to_own_siblings(ws_cmd_tx, ws_room_peers, local_peer_str, local_device_id, data);
}

/// Remove EVERY MLS leaf of `identity` from the server group (epoch rotation for
/// forward secrecy) and broadcast the commit: ONE room broadcast replaces the
/// per-identity fan-out and the sibling fan. A kicked identity's devices receive
/// it but cannot rejoin, because the MlsKeyPackage non-member check rejects their
/// re-bootstrap. Kick and ban pass `emit_epoch_event` for SFrame rotation;
/// self-removal on leave passes `drop_group_on_err`.
#[allow(clippy::too_many_arguments)]
async fn mls_remove_identity_and_broadcast(
    mls_mgr: &mut MlsManager,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    crypto_store: &CryptoStore,
    server_id: &str,
    identity: &str,
    emit_epoch_event: bool,
    drop_group_on_err: bool,
    log_ok: &str,
) {
    if !mls_mgr.has_group(server_id) { return; }
    let id_set = identity_credential_ids(identity);
    let owned: Vec<&str> = id_set.iter().map(|s| s.as_str()).collect();
    match mls_mgr.remove_identity_leaves(server_id, &owned) {
        Ok(commit_bytes) => match mls_mgr.merge_pending_commit(server_id) {
            Ok(()) => {
                persist_mls_state(mls_mgr, crypto_store);
                if emit_epoch_event {
                    if let Ok(sframe_key) = mls_mgr.export_secret(server_id, "sframe", b"", 32) {
                        let epoch = mls_mgr.epoch(server_id).unwrap_or(0);
                        let _ = event_tx.send(NetworkEvent::MlsEpochChanged {
                            server_id: server_id.to_string(), epoch, sframe_key,
                            channel_id: None,
                        }).await;
                    }
                }
                let commit_b64 = base64::engine::general_purpose::STANDARD.encode(&commit_bytes);
                let commit_epoch = mls_mgr.epoch(server_id).ok();
                crate::node::crypto_handler::broadcast_mls_commit(
                    mls_mgr, ws_cmd_tx, server_id, None, commit_b64,
                    commit_epoch,
                );
                hollow_log!("[HOLLOW-MLS] {log_ok}");
            }
            Err(e) => hollow_log!("[HOLLOW-MLS] Failed to merge remove commit: {e}"),
        },
        Err(e) => {
            hollow_log!("[HOLLOW-MLS] Failed to remove identity from MLS group: {e}");
            if drop_group_on_err {
                mls_mgr.remove_group(server_id);
                persist_mls_state(mls_mgr, crypto_store);
            }
        }
    }
}

// ── Shared channel-sync response plumbing ─────────────────────────────

// ── Link previews in backfill (issue #45 follow-up) ──────────────────
//
// A card's thumbnail is tens of kilobytes and a sync page holds up to 200
// messages, so a link-heavy channel could mint a multi-megabyte batch.
//
// The answer is NOT to strip cards past some limit: a stripped card never comes
// back, which is exactly the bug that made previews vanish for anyone offline.
// The PAGE is cut short instead, because pages are already the wire's unit of
// flow control, so a short page costs one round trip and still delivers the card.

/// Link-preview bytes one sync batch may carry before its page is cut short.
pub(crate) const SYNC_PREVIEW_BUDGET_BYTES: usize = 2 * 1_024 * 1_024;

/// Messages a page always carries before the byte budget may end it.
///
/// This floor is what keeps pagination LIVE, and it is not a tuning knob. A
/// requester re-asks from its own watermark and two of the three watermark
/// queries are INCLUSIVE, so the first rows of every later page are rows it
/// already has. Cut a page short enough and it contains nothing but that overlap:
/// the watermark never moves and the identical page comes back forever. This many
/// messages means a stall needs ~50 sitting exactly on their sender's watermark.
const MIN_ITEMS_BEFORE_TRUNCATION: usize = 50;

/// A packed sync page: the items, plus whether the preview budget ended it
/// early. `truncated` MUST reach the responder's `has_more`, or the messages
/// left behind wait for whatever triggers the next sync.
pub(crate) struct SyncPage<T> {
    pub items: Vec<T>,
    pub truncated: bool,
}

/// Spends [`SYNC_PREVIEW_BUDGET_BYTES`] across one batch.
pub(crate) struct PreviewBudget {
    remaining: usize,
}

impl PreviewBudget {
    pub(crate) fn new() -> Self {
        Self { remaining: SYNC_PREVIEW_BUDGET_BYTES }
    }

    /// Charge one preview to the budget. `false` = it does not fit, and the caller
    /// must END the page there rather than pack the message card-less. Below
    /// [`MIN_ITEMS_BEFORE_TRUNCATION`] the answer is always yes, which is what
    /// guarantees the page outruns the requester's inclusive watermark.
    pub(crate) fn fits(&mut self, lp: &LinkPreviewRef, packed: usize) -> bool {
        let cost = preview_wire_cost(lp);
        if packed < MIN_ITEMS_BEFORE_TRUNCATION {
            self.remaining = self.remaining.saturating_sub(cost);
            return true;
        }
        match self.remaining.checked_sub(cost) {
            Some(left) => {
                self.remaining = left;
                true
            }
            None => false,
        }
    }
}

/// Rough serialized size of a preview. The thumbnail dominates by orders of
/// magnitude; the text fields are capped at 200/400 chars by the fetcher.
fn preview_wire_cost(lp: &LinkPreviewRef) -> usize {
    lp.thumb_webp_b64.as_ref().map_or(0, String::len)
        + lp.url.len()
        + lp.title.len()
        + lp.description.len()
        + lp.domain.len()
        + lp.site_name.len()
}

/// Pack stored channel messages into wire `SyncMessageItem`s, joining in each
/// message's reactions and file metadata via two batch queries. The channel twin
/// of `build_dm_sync_items`, shared by every channel-sync responder.
pub(crate) fn channel_sync_items(
    store: &crate::storage::MessageStore,
    messages: &[crate::storage::messages::StoredChannelMessage],
) -> SyncPage<SyncMessageItem> {
    let msg_ids: Vec<String> = messages.iter().filter_map(|m| m.message_id.clone()).collect();
    let reactions_map = store.load_reactions_for_sync(&msg_ids).unwrap_or_default();
    let file_ids: Vec<&str> = messages.iter().filter_map(|m| m.file_id.as_deref()).collect();
    let file_meta_map = store.get_file_metadata_batch(&file_ids).unwrap_or_default();

    let mut budget = PreviewBudget::new();
    let mut items: Vec<SyncMessageItem> = Vec::with_capacity(messages.len());
    let mut truncated = false;

    for m in messages {
        // Cut the page here when this message's card no longer fits — never
        // pack the message and drop its card (see the budget note above).
        if let Some(lp) = &m.link_preview {
            if !budget.fits(lp, items.len()) {
                hollow_log!(
                    "[HOLLOW-SYNC] Preview budget spent after {} item(s) — cutting the page short (has_more)",
                    items.len()
                );
                truncated = true;
                break;
            }
        }
        let reactions = m.message_id.as_ref()
            .and_then(|mid| reactions_map.get(mid))
            .map(|rs| rs.iter().map(|(e, p, ts, sig, pk)| SyncReactionItem {
                e: e.clone(), p: p.clone(), ts: *ts, sig: sig.clone(), pk: pk.clone(),
            }).collect())
            .unwrap_or_default();
        let file_meta = m.file_id.as_ref().and_then(|fid| {
            file_meta_map.get(fid.as_str()).map(|f| SyncFileMetaItem {
                fid: f.file_id.clone(),
                name: f.file_name.clone(),
                ext: f.file_ext.clone(),
                mime: f.mime_type.clone(),
                size: f.size_bytes,
                img: f.is_image,
                w: f.width,
                h: f.height,
                mid: f.message_id.clone(),
                ts: f.created_at,
                sender: f.sender_id.clone(),
                vthumb: f.video_thumb.clone(),
                thumb: f.thumb_b64.clone(),
            })
        });
        // Deletion proof rides with the hidden flag (REJECT-ABSENT on apply).
        let (hidden_at, hidden_sig, hidden_pk) = super::message_ops::deletion_proof_fields(
            store, m.hidden_at, m.message_id.as_deref(),
        );
        items.push(SyncMessageItem {
            s: m.sender_id.clone(),
            t: m.text.clone(),
            ts: m.timestamp,
            sig: m.signature.clone(),
            pk: m.public_key.clone(),
            mid: m.message_id.clone(),
            edited_at: m.edited_at,
            reply_to: m.reply_to_mid.clone(),
            file_id: m.file_id.clone(),
            file_meta,
            hidden_at,
            hidden_sig,
            hidden_pk,
            order_us: m.order_us,
            lp_digest: m.link_preview.as_ref()
                .map(super::crypto_handler::link_preview_digest),
            lp: m.link_preview.clone().map(Box::new),
            reactions,
        });
    }
    SyncPage { items, truncated }
}

/// Build one page (at most 200 messages) of a channel-sync response: per-sender
/// watermarks when the requester sent them, a legacy single timestamp otherwise,
/// then pack and stamp `total`/`has_more`. Returns the envelope and item count.
pub(crate) fn build_channel_sync_batch(
    store: &crate::storage::MessageStore,
    sid: &str,
    cid: &str,
    since_timestamp: i64,
    sender_timestamps: &HashMap<String, i64>,
) -> Result<(MessageEnvelope, usize), String> {
    let messages = if !sender_timestamps.is_empty() {
        store.get_channel_messages_since_per_sender(sid, cid, sender_timestamps, 200)
    } else {
        store.get_channel_messages_since(sid, cid, since_timestamp, 200)
    }?;
    let SyncPage { items, truncated } = channel_sync_items(store, &messages);
    let total = if !sender_timestamps.is_empty() {
        store.count_channel_messages_since_per_sender(sid, cid, sender_timestamps)
            .unwrap_or(items.len() as u32)
    } else {
        store.count_channel_messages_since(sid, cid, since_timestamp)
            .unwrap_or(items.len() as u32)
    };
    // `truncated` = the preview budget ended the page before the query did, so
    // there is definitely more to serve even though the page is short.
    let has_more = if truncated || (items.len() >= 200 && total > 200) {
        Some(true)
    } else {
        None
    };
    let count = items.len();
    Ok((MessageEnvelope::ChannelSyncBatch {
        sid: sid.to_string(),
        cid: cid.to_string(),
        messages: items,
        total,
        has_more,
        target: None,
    }, count))
}

// ── 1. CreateServer ───────────────────────────────────────────────────

pub(crate) async fn handle_create_server(
    server_states: &mut HashMap<String, ServerState>,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    local_device_id: &str,
    name: String,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) {
    let local_peer = local_peer_str.to_string();
    let server_id = hex::encode(&{
        let mut buf = [0u8; 16];
        getrandom::fill(&mut buf).expect("system RNG unavailable — cannot generate secure random bytes");
        buf
    });
    hollow_log!("[HOLLOW-CRDT] Creating server '{name}' id={server_id}");

    let mut state = ServerState::new(
        server_id.clone(),
        name.clone(),
        local_peer.clone(),
    );
    // Every op this state authors is signed with our MASTER key (goes with
    // the HLC `ServerState::new` seeded).
    super::swarm::install_op_signer(&mut state, bundle_keypair);

    author_op(&mut state, crdt_store, &server_id, CrdtPayload::ServerCreated {
        name: name.clone(),
        owner_peer_id: local_peer,
    });

    server_states.insert(server_id.clone(), state);

    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
        room_code: server_id.clone(),
    });

    // Register the room's catch-up rings straight away: the JOIN ring is registered
    // by MEMBERS on behalf of people who are not members yet, so until it exists a
    // stranger's parked request is dropped rather than buffered. Doing it here makes
    // a server joinable-while-empty from the instant it is created.
    if let Some(state) = server_states.get(&server_id) {
        register_relay_catchup(ws_cmd_tx, state, &server_id);
    }

    // Auto-pledge default storage (512 MB) for the owner
    if let Some(state) = server_states.get_mut(&server_id) {
        let default_pledge = 512u64 * 1024 * 1024;
        author_op(state, crdt_store, &server_id, CrdtPayload::StoragePledgeChanged {
            peer_id: local_peer_str.to_string(),
            pledge_bytes: default_pledge,
        });
    }

    if let Some(mls_mgr) = mls {
        match mls_mgr.create_group(&server_id) {
            Ok(()) => persist_mls_state(mls_mgr, crypto_store),
            Err(e) => hollow_log!("[HOLLOW-MLS] Failed to create MLS group: {e}"),
        }
    }

    let _ = event_tx.send(NetworkEvent::ServerCreated {
        server_id: server_id.clone(),
        name,
    }).await;

    // Announce the new server to our OWN online siblings so they auto-onboard: the
    // room is brand-new, so they are not in it and have no other way to learn it
    // exists. Offline siblings onboard on their next connect, via re-announce.
    let announce = serde_json::to_vec(&HavenMessage::SiblingServerAnnounce {
        server_id: server_id.clone(),
    }).unwrap_or_default();
    let sent = fan_to_own_siblings(ws_cmd_tx, ws_room_peers, local_peer_str, local_device_id, announce);
    if sent > 0 {
        hollow_log!("[HOLLOW-CRDT] Announced new server {server_id} to {sent} online sibling device(s)");
    }
}

// ── Relay offline catch-up registration ──────────────────────────────

/// Register this server's text channels with the relay's per-channel offline ring
/// when the CRDT `relay_catchup_secs` setting is on. Additive and refresh-only: it
/// NEVER clears here, because a member holding a stale CRDT must not wipe a buffer
/// everyone else relies on. Clearing happens only at the Owner/Admin toggle site.
pub(crate) fn register_relay_catchup(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    state: &ServerState,
    server_id: &str,
) {
    let secs = state.relay_catchup_secs();
    if secs <= 0 {
        return;
    }
    let mut channels: Vec<String> = state
        .channels
        .values()
        .filter(|c| matches!(c.channel_type, crate::crdt::server_state::ChannelType::Text))
        .map(|c| c.channel_id.clone())
        .collect();
    // The join ring. ALWAYS registered alongside the text channels, because a parked
    // join is deposited by somebody who is not a member yet and can therefore never
    // register the ring itself. That also keeps the list non-empty, so a server with
    // only voice channels still gets its join ring.
    //
    // `relay_catchup_secs == 0` (the owner turned catch-up off) means no ring at
    // all, so a parked join degrades to "pending until co-presence".
    channels.push(super::types::JOIN_TOPIC.to_string());
    hollow_log!("[HOLLOW-TOPIC] Registering relay catch-up rings for {server_id}: {} channel(s) + the join ring, retention {secs}s", channels.len() - 1);
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SetTopicBuffer {
        room_code: server_id.to_string(),
        channels,
        retention_secs: secs,
        clear: false,
    });
}

/// Age window (seconds) for a relay topic catch-up request: how far back the relay
/// replays ring frames per channel. Derived from the local watermark plus a
/// 30-minute overlap, because frames older than what we hold are undecryptable
/// (MLS consumed those generations) and were pure SecretReuse noise. 0 = no
/// watermark, so replay the whole retention window.
///
/// Batched over the server and answered on the `CrdtStore` actor's long-lived
/// connection: the per-channel form opened a TRANSIENT `MessageStore` on the event
/// loop, which on iOS is what got the process killed for holding an App Group lock
/// across a suspend (`EXC_CRASH 0xdead10cc`). Pairs come back in `channel_ids` order.
pub(crate) async fn catchup_watermark_ages(
    crdt_store: &CrdtStore,
    server_id: &str,
    channel_ids: Vec<String>,
) -> Vec<(String, i64)> {
    const LOOKBACK_SECS: i64 = 1800;
    if channel_ids.is_empty() {
        return Vec::new();
    }
    let watermarks = crdt_store
        .channel_watermarks(server_id.to_string(), channel_ids.clone())
        .await;
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    channel_ids
        .into_iter()
        .map(|cid| {
            let age = match watermarks.get(&cid) {
                Some(&ts_ms) if ts_ms > 0 => {
                    ((now_ms - ts_ms) / 1000 + LOOKBACK_SECS).max(LOOKBACK_SECS)
                }
                _ => 0,
            };
            (cid, age)
        })
        .collect()
}

/// Ask the relay to replay every Text channel ring in `room` this connection has
/// not pulled yet, for the channels we can actually see.
///
/// ONE definition, called from two places that need identical behaviour: the
/// connect-time sweep in the `RoomMembers` arm, and again after the Welcome that
/// ends a parked join. The second call exists because a returning parked joiner
/// can process `RoomMembers` BEFORE its buffered `SyncResponse` lands, and because
/// any channel frame that replayed before the leaf formed failed to decrypt. Dedup
/// is by message_id. `relay_catchup_done` is the per-connection "already pulled"
/// set, and the caller must clear the room's entries before a re-issue.
pub(crate) async fn request_channel_catchups(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    crdt_store: &CrdtStore,
    state: Option<&ServerState>,
    room: &str,
    local_peer: &str,
    relay_catchup_done: &mut std::collections::HashSet<(String, String)>,
    tag: &str,
) {
    // Gather the channel list and DROP the borrow before crossing the await:
    // the watermark lookup is answered on the CrdtStore actor's long-lived
    // connection, never by opening a SQLCipher handle per channel here.
    let fresh_channels: Vec<String> = match state {
        Some(state) if state.relay_catchup_secs() > 0 => {
            register_relay_catchup(ws_cmd_tx, state, room);
            state
                .channels
                .values()
                .filter(|ch| {
                    matches!(ch.channel_type, crate::crdt::server_state::ChannelType::Text)
                        && state.can_see_channel(local_peer, &ch.channel_id)
                })
                .map(|ch| ch.channel_id.clone())
                .filter(|cid| relay_catchup_done.insert((room.to_string(), cid.clone())))
                .collect()
        }
        _ => Vec::new(),
    };
    if fresh_channels.is_empty() {
        return;
    }
    let ages = catchup_watermark_ages(crdt_store, room, fresh_channels).await;
    for (cid, max_age_secs) in ages {
        hollow_log!("[HOLLOW-TOPIC] Catch-up request ({tag}) {room}/{cid} max_age={max_age_secs}s");
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::TopicCatchup {
            room_code: room.to_string(),
            channel_id: cid,
            max_age_secs,
        });
    }
}

// ── 2. CreateChannel ──────────────────────────────────────────────────

pub(crate) async fn handle_create_channel(
    server_states: &mut HashMap<String, ServerState>,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    gossip_overlays: &mut HashMap<String, super::gossip::GossipOverlay>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    name: String,
    category: Option<String>,
    channel_type: String,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) -> bool {
    // Returns true if the caller should `continue` (skip to next iteration).
    if let Some(state) = server_states.get_mut(&server_id) {
        let local_peer = local_peer_str.to_string();
        if !state.has_permission(&local_peer, Permission::MANAGE_CHANNELS) {
            hollow_log!("[HOLLOW-CRDT] Permission denied: cannot create channel in {server_id}");
            let _ = event_tx.send(NetworkEvent::Error {
                message: "Permission denied: cannot manage channels".to_string(),
            }).await;
            return true;
        }
        // The id came in with the command: the caller already handed it to the
        // UI (see `api::crdt::create_channel`), so minting another one here
        // would leave the layout pointing at a channel that never exists.
        hollow_log!("[HOLLOW-CRDT] Creating channel '{name}' id={channel_id} in server {server_id}");

        let op = author_op(state, crdt_store, &server_id, CrdtPayload::ChannelAdded {
            channel_id: channel_id.clone(),
            name: name.clone(),
            category: category.clone(),
            channel_type: channel_type.clone(),
        });

        let _ = event_tx.send(NetworkEvent::ChannelAdded {
            server_id: server_id.clone(),
            channel_id,
            name,
            channel_type,
        }).await;

        broadcast_op_mls_first(
            mls, ws_cmd_tx, ws_room_peers, gossip_overlays, event_tx, state, local_peer_str, &server_id, &op, crypto_store,
        );

        // Relay offline catch-up: a new channel must be in the relay's
        // registration or its messages never buffer. The creator is online
        // right now, so their refresh covers everyone.
        register_relay_catchup(ws_cmd_tx, state, &server_id);
    } else {
        let _ = event_tx.send(NetworkEvent::Error {
            message: format!("[CRDT] Server {server_id} not found"),
        }).await;
    }
    false
}

// ── 3. RemoveChannel ──────────────────────────────────────────────────

pub(crate) async fn handle_remove_channel(
    server_states: &mut ServerStates,
    mls: &mut Option<MlsManager>,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) -> bool {
    if author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        OpGate::Perm(Permission::MANAGE_CHANNELS),
        Some("Permission denied: cannot manage channels"),
        CrdtPayload::ChannelRemoved { channel_id: channel_id.clone() },
        &format!("Removing channel {channel_id}"),
        NetworkEvent::ChannelRemoved { server_id: server_id.clone(), channel_id: channel_id.clone() },
        OpBroadcast::MlsFirst { mls, crypto_store },
        crdt_store,
    ).await {
        return true;
    }

    // Option B: tear down the channel's MLS subgroup locally if it had one.
    if server_states.contains_key(&server_id)
        && let Some(mls_mgr) = mls.as_mut()
    {
        let group_key = crate::crypto::subgroup_id(&server_id, &channel_id);
        if mls_mgr.has_group(&group_key) {
            hollow_log!("[HOLLOW-MLS] Channel removed — dropping subgroup {group_key}");
            mls_mgr.remove_group(&group_key);
            crate::node::crypto_handler::persist_mls_state(mls_mgr, crypto_store);
        }
    }
    false
}

// ── 4. RenameServer ───────────────────────────────────────────────────

pub(crate) async fn handle_rename_server(
    server_states: &mut ServerStates,
    mls: &mut Option<MlsManager>,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    new_name: String,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) -> bool {
    author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        OpGate::Perm(Permission::MANAGE_SERVER),
        Some("Permission denied: cannot manage server"),
        CrdtPayload::ServerRenamed { new_name: new_name.clone() },
        &format!("Renaming server to '{new_name}'"),
        NetworkEvent::ServerUpdated { server_id: server_id.clone() },
        OpBroadcast::MlsFirst { mls, crypto_store },
        crdt_store,
    ).await
}

// ── 5. RenameChannel ──────────────────────────────────────────────────

pub(crate) async fn handle_rename_channel(
    server_states: &mut ServerStates,
    mls: &mut Option<MlsManager>,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    new_name: String,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) -> bool {
    author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        OpGate::Perm(Permission::MANAGE_CHANNELS),
        Some("Permission denied: cannot manage channels"),
        CrdtPayload::ChannelRenamed { channel_id: channel_id.clone(), new_name: new_name.clone() },
        &format!("Renaming channel {channel_id} to '{new_name}'"),
        NetworkEvent::ChannelRenamed { server_id: server_id.clone(), channel_id, new_name },
        OpBroadcast::MlsFirst { mls, crypto_store },
        crdt_store,
    ).await
}

// ── 6. UpdateServerSetting ────────────────────────────────────────────

pub(crate) async fn handle_update_server_setting(
    server_states: &mut ServerStates,
    mls: &mut Option<MlsManager>,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    key: String,
    value: String,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) {
    // Local permission gate (MANAGE_SERVER, override-aware), mirroring what every
    // RECEIVER enforces. Without it an unauthorized FFI call applies the op
    // locally, the network rejects it, and our state diverges from everyone else's.
    if author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        OpGate::Perm(Permission::MANAGE_SERVER),
        Some("Permission denied: changing server settings needs the Manage Server permission"),
        CrdtPayload::ServerSettingChanged { key: key.clone(), value: value.clone() },
        &format!("Updating setting '{key}'='{value}'"),
        NetworkEvent::ServerUpdated { server_id: server_id.clone() },
        OpBroadcast::MlsFirst { mls, crypto_store },
        crdt_store,
    ).await {
        return;
    }

    // Relay offline catch-up toggle: (de)register the relay-side ring
    // buffers immediately. Other members refresh on their own next
    // connect; only THIS authoritative toggle site may clear.
    if key == "relay_catchup_secs" {
        if let Some(state) = server_states.get(&server_id) {
            if state.relay_catchup_secs() > 0 {
                register_relay_catchup(ws_cmd_tx, state, &server_id);
            } else {
                let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SetTopicBuffer {
                    room_code: server_id.clone(),
                    channels: Vec::new(),
                    retention_secs: 0,
                    clear: true,
                });
            }
        }
    }
}

// ── 7. DeleteServer ───────────────────────────────────────────────────

pub(crate) async fn handle_delete_server(
    server_states: &mut HashMap<String, ServerState>,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    local_device_id: &str,
    server_id: String,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) -> bool {
    // Only owner can delete a server.
    if let Some(state) = server_states.get(&server_id) {
        let local_peer = local_peer_str.to_string();
        if !state.has_permission(&local_peer, Permission::MANAGE_SERVER) {
            hollow_log!("[HOLLOW-CRDT] Permission denied: cannot delete server {server_id}");
            let _ = event_tx.send(NetworkEvent::Error {
                message: "Permission denied: only the owner can delete the server".to_string(),
            }).await;
            return true;
        }
    }

    hollow_log!("[HOLLOW-CRDT] Deleting server {server_id} (tombstone)");

    // A replicable `ServerDeleted` tombstone op rather than the old missable
    // one-shot broadcast: online members get it via normal gossip, and an OFFLINE
    // member reconciles it on reconnect through SyncRequest/SyncResponse, because
    // the owner RETAINS the tombstone shell and op_log to serve it.
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    let Some(state) = server_states.get_mut(&server_id) else { return false; };
    // Capture the membership BEFORE the tombstone is applied: `ServerDeleted`
    // DRAINS `members` as part of apply, so anything that reads `state.members`
    // afterwards to decide who to tell is iterating an empty map.
    let member_targets: Vec<String> = state
        .members
        .keys()
        .filter(|m| !super::resolver::same_identity(m, local_peer_str))
        .cloned()
        .collect();
    let op = state.create_op(CrdtPayload::ServerDeleted { deleted_at: now_ms });
    let _ = state.apply_op(&op); // marks shell `deleted`, drains membership, keeps op_log

    // Persist the tombstone shell + the op (op_log is skip_serializing → the op MUST be
    // persisted via insert_op or the owner stops serving it after restart).
    crdt_store.insert_op(op.clone());
    crdt_store.save_state_snapshot(server_id.clone(), state);

    // Fan the tombstone op to remaining members AND to our OWN siblings, which the
    // master-keyed member broadcast excludes.
    //
    // The plaintext twin goes out UNCONDITIONALLY, alongside the MLS copy. Sending
    // it only `if !mls_sent` measures the WRONG end of the wire: a member can be
    // perfectly reachable and still unable to read an MLS frame, holding no leaf
    // yet or sitting at a skewed epoch, and neither is visible from here
    // (`feedback_owner_coordinator_mls_recovery`). Duplication is free, because
    // `ServerDeleted` ingest is owner-author validated and `apply_op` is idempotent.
    if let Ok(op_json) = serde_json::to_string(&op) {
        if mls.as_ref().is_some_and(|m| m.has_group(&server_id)) {
            let envelope = MessageEnvelope::CrdtOp { sid: server_id.clone(), op_json: op_json.clone() };
            if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &envelope, crypto_store) {
                hollow_log!("[HOLLOW-MLS] ServerDeleted MLS broadcast failed: {e}");
            }
        }
        let data = serde_json::to_vec(&HavenMessage::CrdtOpBroadcast {
            server_id: server_id.clone(), op_json,
        }).unwrap_or_default();
        for member in &member_targets {
            send_raw_to_identity(ws_cmd_tx, ws_room_peers, member, data.clone());
        }
        // Siblings always get the plaintext op directly (SendToRoom reaches them too,
        // but a direct fan also covers the no-other-member-online case).
        fan_to_own_siblings(ws_cmd_tx, ws_room_peers, local_peer_str, local_device_id, data);
    }

    // Tear down our LOCAL MLS group (we're leaving the server) but KEEP the CRDT
    // tombstone shell + signaling registration so we keep serving the tombstone to
    // reconnecting peers. (We no longer hard-delete the server_states entry / DB row.)
    if let Some(mls_mgr) = mls {
        mls_mgr.remove_group(&server_id);
        persist_mls_state(mls_mgr, crypto_store);
    }

    let _ = event_tx.send(NetworkEvent::ServerDeleted {
        server_id,
    }).await;
    false
}

// ── 8. JoinServer ─────────────────────────────────────────────────────

/// The persisted twin of a live [`PendingJoin`], for the CrdtStore actor.
pub(crate) fn pending_join_row(
    server_id: &str,
    pending: &PendingJoin,
    state: &str,
    reason: &str,
) -> crate::storage::messages::PendingJoinRow {
    crate::storage::messages::PendingJoinRow {
        server_id: server_id.to_string(),
        requested_at: pending.requested_at,
        nsfw_confirmed: pending.nsfw_confirmed,
        twitch_proof_json: pending.twitch_proof_json.clone(),
        state: state.to_string(),
        reason: reason.to_string(),
        last_deposited_at: pending.last_deposited_at,
        // Only used on INSERT: the upsert preserves the original on conflict,
        // so a repeat request keeps saying when the user first asked.
        created_at: pending.requested_at,
        // The private half lives in the MLS store, which survives a restart on its
        // own; this is the public half the ring copy carries, and it has to survive
        // with it or a restarted joiner deposits a DIFFERENT package.
        key_package: pending.key_package.clone(),
    }
}

/// Write the parked copy of a request into the server room's `~join` ring.
///
/// The copy CARRIES `twitch_proof_json`. A ring frame can be pulled by any socket
/// in the room for the ring's whole retention, so what rides it has to be readable
/// by strangers without cost: a follow CREDENTIAL names a channel id, an age
/// bucket and a subscription tier, all facts about the server's own channel, bound
/// to the joiner's master by a blind signature that reveals nothing else.
pub(crate) fn deposit_parked_join(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    server_id: &str,
    pending: &PendingJoin,
) {
    let data = serde_json::to_vec(&HavenMessage::ServerJoinRequest {
        server_id: server_id.to_string(),
        twitch_proof_json: pending.twitch_proof_json.clone(),
        nsfw_confirmed: pending.nsfw_confirmed,
        requested_at: pending.requested_at,
        device_list: pending.device_list.clone(),
        parked: true,
        // Rung 2: the ring copy carries the LEAF as well as the membership, so the
        // member that admits it can add us to the MLS group in the same batch. Only
        // the parked copy; a live join bootstraps on its SyncResponse.
        key_package: pending.key_package.clone(),
    })
    .unwrap_or_default();
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoomTopic {
        room_code: server_id.to_string(),
        topic: super::types::JOIN_TOPIC.to_string(),
        data,
    });
    hollow_log!(
        "[HOLLOW-CRDT] Deposited parked join for {server_id} (nonce {}) into the join ring",
        pending.requested_at
    );
}

/// Publish a member's answer to a join into the room's `~join` ring.
///
/// Two jobs at once: it reaches a joiner that is not here, and it tells the OTHER
/// members the join is resolved, so a member returning later does not re-serve it.
#[allow(clippy::too_many_arguments)]
pub(crate) fn publish_join_resolution(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    server_id: &str,
    joiner_master: &str,
    requested_at: i64,
    admitted: bool,
    reason: &str,
    op_json: Option<String>,
) {
    let data = serde_json::to_vec(&HavenMessage::ServerJoinResolved {
        server_id: server_id.to_string(),
        joiner_master: joiner_master.to_string(),
        requested_at,
        admitted,
        reason: reason.to_string(),
        op_json,
    })
    .unwrap_or_default();
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoomTopic {
        room_code: server_id.to_string(),
        topic: super::types::JOIN_TOPIC.to_string(),
        data,
    });
    hollow_log!("[HOLLOW-CRDT] Published join resolution for {joiner_master} on {server_id} (admitted {admitted})");
}

/// Drop the MLS KeyPackage a join will now never use.
///
/// The package's private half sits in the MLS store from the moment it is minted
/// until a Welcome consumes it, so a join ending in a refusal or a discard would
/// leave that material in the persisted storage blob for the life of the install.
/// Best effort: a package we cannot parse is one we did not write.
///
/// Called LAST, after the row and the events: it writes the whole MLS storage blob
/// through the crypto store, on the same SQLCipher file the pending-join row uses.
fn discard_join_key_package(
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    server_id: &str,
    key_package_b64: Option<&str>,
) {
    let Some(kp_b64) = key_package_b64 else { return };
    let Some(mls_mgr) = mls.as_mut() else { return };
    let Ok(kp) = base64::engine::general_purpose::STANDARD.decode(kp_b64) else {
        hollow_log!("[HOLLOW-MLS] Join KeyPackage for {server_id} is not valid base64, nothing to discard");
        return;
    };
    match mls_mgr.discard_key_package(&kp) {
        Ok(()) => {
            super::crypto_handler::persist_mls_state(mls_mgr, crypto_store);
            hollow_log!("[HOLLOW-MLS] Discarded the unused join KeyPackage for {server_id}");
        }
        Err(e) => hollow_log!("[HOLLOW-MLS] Could not discard the join KeyPackage for {server_id}: {e}"),
    }
}

/// A refusal that is really a QUESTION: the member is asking the joiner for
/// something (NSFW consent, a Twitch proof) and the next request will carry it.
///
/// Handled differently at both ends. The member never writes one into the `~join`
/// ring (a question parked in a TTL buffer is re-served for days), and the joiner
/// never keeps a row for one (a persisted tile pops the same dialog every boot).
pub(crate) fn is_interactive_reason(reason: &str) -> bool {
    reason.starts_with("nsfw_confirm:") || reason.starts_with("twitch_required:")
}

/// ONE place where a refusal lands on the joiner, whichever leg carried it.
///
/// Always leaves the room: "no row means we are not in that room" is the invariant
/// that stops the relay replaying a late admission's buffered snapshot at us.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_join_refused(
    pending_server_joins: &mut HashMap<String, PendingJoin>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    crdt_store: &CrdtStore,
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    server_id: String,
    reason: String,
) {
    let Some(mut pending) = pending_server_joins.remove(&server_id) else { return };
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom {
        room_code: server_id.clone(),
    });
    // Whichever branch runs, this ask is over. The package is taken off the entry
    // HERE, so neither branch writes a row naming a package that no longer exists,
    // and it is reclaimed at the end of the branch.
    let spent = pending.key_package.take();

    if is_interactive_reason(&reason) {
        // The row goes: the user's answer re-requests through `handle_join_server`
        // with a FRESH row carrying the consent or the proof. Keeping the old row
        // would restore a tile, re-serve the question, and pop the dialog at launch.
        hollow_log!("[HOLLOW-CRDT] Join for {server_id} needs an answer from the user: {reason}");
        crdt_store.delete_pending_join(server_id.clone());
        // Tile first, then the question: the tile is about to be answered by a
        // dialog and must not still sit behind it, and a UI that sees only one of
        // the two events gets the safer one.
        let _ = event_tx.send(NetworkEvent::PendingJoinUpdated {
            server_id: server_id.clone(),
            state: "discarded".to_string(),
            reason: String::new(),
        }).await;
        let _ = event_tx.send(NetworkEvent::TwitchJoinRejected {
            server_id: server_id.clone(),
            reason,
        }).await;
        discard_join_key_package(mls, crypto_store, &server_id, spent.as_deref());
        return;
    }

    hollow_log!("[HOLLOW-CRDT] Join for {server_id} refused: {reason}");
    crdt_store.upsert_pending_join(pending_join_row(&server_id, &pending, "rejected", &reason));
    // A join inside its LIVE window keeps today's surfaces: the user is standing in
    // front of the dialog they triggered. A PARKED one is answered hours later with
    // nobody watching, so the tile is the only surface and a toast would be noise.
    if !pending.parked {
        let _ = event_tx.send(NetworkEvent::TwitchJoinRejected {
            server_id: server_id.clone(),
            reason: reason.clone(),
        }).await;
    }
    let _ = event_tx.send(NetworkEvent::PendingJoinUpdated {
        server_id: server_id.clone(),
        state: "rejected".to_string(),
        reason,
    }).await;
    discard_join_key_package(mls, crypto_store, &server_id, spent.as_deref());
}

/// Refuse a join, by both legs.
///
/// The targeted leg goes to the DETERMINISTIC server room rather than through a
/// presence lookup, so the relay buffers it for an absent joiner and replays it.
///
/// INTERACTIVE reasons are deliberately NOT written into the ring: they are
/// questions, and one parked in a TTL ring re-opens the same dialog for days.
#[allow(clippy::too_many_arguments)]
pub(crate) fn send_join_rejection(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    server_id: &str,
    joiner_device: &str,
    joiner_master: &str,
    requested_at: i64,
    reason: &str,
    catchup_secs: i64,
) {
    send_message_to_peer_in_room(
        ws_cmd_tx, server_id, joiner_device,
        HavenMessage::ServerJoinRejected {
            server_id: server_id.to_string(),
            reason: reason.to_string(),
            requested_at,
        },
    );
    let interactive = is_interactive_reason(reason);
    if requested_at != 0 && !interactive && catchup_secs > 0 {
        publish_join_resolution(
            ws_cmd_tx, server_id, joiner_master, requested_at, false, reason, None,
        );
    }
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_join_server(
    pending_server_joins: &mut HashMap<String, PendingJoin>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    cmd_tx: &mpsc::Sender<NodeCommand>,
    server_id: String,
    twitch_proof_json: Option<String>,
    nsfw_confirmed: bool,
    crdt_store: &CrdtStore,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    mls: &Option<MlsManager>,
    crypto_store: &CryptoStore,
    // The KeyPackage a persisted row already holds ("request again"). Reused
    // rather than re-minted, so a re-ask does not orphan the package the ring
    // copy already names.
    stored_key_package: Option<String>,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-CRDT] Joining server {server_id}");
    // The request NONCE. Every answer names it, so an answer replayed out of a
    // three-day ring can never resolve the join the user made afterwards.
    let requested_at = super::types::now_ms();
    // Our own signed device list, built ONCE and cached for the re-sends. A member
    // serving this from the ring has never been online with us, so it is the only
    // thing that attributes the request to our MASTER rather than to this device.
    let device_list = super::crypto_handler::build_local_device_list(
        master_keypair, device_peer_id, db_path, db_passphrase,
    );
    // The KeyPackage this join will be added with. Minted ONCE per row: a re-ask
    // refreshes the nonce and keeps the package, because the ring may already hold
    // a copy naming it. `mint_key_package` persists the private half immediately,
    // which is what keeps it usable days and one restart later.
    let key_package = stored_key_package.or_else(|| {
        pending_server_joins
            .get(&server_id)
            .and_then(|p| p.key_package.clone())
    }).or_else(|| {
        let mls = mls.as_ref()?;
        match super::crypto_handler::mint_key_package(mls, crypto_store) {
            Ok(kp) => Some(base64::engine::general_purpose::STANDARD.encode(kp)),
            Err(e) => {
                hollow_log!("[HOLLOW-MLS] Join KeyPackage mint failed for {server_id}: {e}");
                None
            }
        }
    });
    let pending = PendingJoin {
        twitch_proof_json: twitch_proof_json.clone(),
        nsfw_confirmed,
        requested_at,
        parked: false,
        last_deposited_at: 0,
        device_list,
        key_package,
    };
    // Persist BEFORE anything can go wrong: a crash inside the 15s live window
    // still leaves a row the boot path picks up, and a join that completes
    // deletes it.
    crdt_store.upsert_pending_join(pending_join_row(&server_id, &pending, "pending", ""));
    pending_server_joins.insert(server_id.clone(), pending.clone());

    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
        room_code: server_id.clone(),
    });

    if let Some(room_peers) = ws_room_peers.get(&server_id) {
        for peer in room_peers.iter() {
            send_message_to_peer(
                ws_cmd_tx, ws_room_peers,
                peer, HavenMessage::ServerJoinRequest {
                    server_id: server_id.clone(),
                    twitch_proof_json: twitch_proof_json.clone(),
                    nsfw_confirmed,
                    requested_at,
                    device_list: pending.device_list.clone(),
                    parked: false,
                    // A live request is answered by somebody who is right here;
                    // the leaf rides the SyncResponse bootstrap, not the wire.
                    key_package: None,
                },
            );
            hollow_log!("[HOLLOW-CRDT] Sent join request to {peer} for {server_id}");
        }
    }
    // If no peers found yet, the PeerJoined/RoomMembers handler
    // will pick up pending_server_joins and send the request then.

    // Members serve a join through their elected coordinator, and that election
    // reads each member's OWN presence view, so a coordinator whose socket has just
    // died can be elected by everyone and answer for nobody. The 4s re-send is
    // served by every member, degrading to the old fan-out instead of a failure.
    let retry_cmd_tx = cmd_tx.clone();
    let retry_sid = server_id.clone();
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_secs(4)).await;
        let _ = retry_cmd_tx.send(NodeCommand::RetryPendingJoin {
            server_id: retry_sid,
        }).await;
    });

    // Both windows. The short one parks only when the relay has told us the room is
    // empty; the long one is the authority for everything else. Either is a no-op
    // once the join has completed or been discarded.
    for (window, only_if_empty) in [
        (JOIN_EMPTY_ROOM_WINDOW, true),
        (JOIN_LIVE_WINDOW, false),
    ] {
        let timeout_cmd_tx = cmd_tx.clone();
        let timeout_sid = server_id.clone();
        tokio::spawn(async move {
            tokio::time::sleep(window).await;
            let _ = timeout_cmd_tx.send(NodeCommand::CheckPendingJoinTimeout {
                server_id: timeout_sid,
                only_if_empty,
            }).await;
        });
    }
}

// ── 8b. RetryPendingJoin ──────────────────────────────────────────────

/// Re-send a still-pending `ServerJoinRequest` to every peer in the server room.
/// Members gate the FIRST request to their elected coordinator; a repeat inside
/// their retry window is served by all of them, so this is what rescues a join
/// whose elected coordinator turned out to be gone.
pub(crate) fn handle_retry_pending_join(
    pending_server_joins: &HashMap<String, PendingJoin>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server_id: String,
) {
    let Some(pending) = pending_server_joins.get(&server_id) else { return };
    let Some(room_peers) = ws_room_peers.get(&server_id) else { return };
    hollow_log!(
        "[HOLLOW-CRDT] Join for {server_id} still pending after the coordinator window — re-asking {} peer(s)",
        room_peers.len()
    );
    for peer in room_peers.iter() {
        send_message_to_peer(
            ws_cmd_tx, ws_room_peers,
            peer, HavenMessage::ServerJoinRequest {
                server_id: server_id.clone(),
                twitch_proof_json: pending.twitch_proof_json.clone(),
                nsfw_confirmed: pending.nsfw_confirmed,
                requested_at: pending.requested_at,
                device_list: pending.device_list.clone(),
                parked: false,
                key_package: None,
            },
        );
    }
}

// ── 9. ChangeRole ─────────────────────────────────────────────────────

pub(crate) async fn handle_change_role(
    server_states: &mut HashMap<String, ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    gossip_overlays: &mut HashMap<String, super::gossip::GossipOverlay>,
    _bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    local_device_id: &str,
    server_id: String,
    peer_id: String,
    new_role: String,
    crdt_store: &CrdtStore,
) -> bool {
    if let Some(state) = server_states.get_mut(&server_id) {
        let local_peer = local_peer_str.to_string();
        let new_member_role = crate::crdt::operations::MemberRole::from_str(&new_role);

        if !state.can_change_role(&local_peer, &peer_id, &new_member_role) {
            hollow_log!("[HOLLOW-CRDT] Permission denied: cannot change {peer_id} to {new_role} in {server_id}");
            return deny(event_tx, &format!("Permission denied: cannot change role to {new_role}")).await;
        }

        hollow_log!("[HOLLOW-CRDT] Changing role of {peer_id} to {new_role} in {server_id}");
        // The payload priority is wire-compat metadata for old clients that merge
        // priority-first; current merge is pure HLC LWW, so demotions land because
        // the op is later, and `can_change_role` carries the authority.
        let author_role = state.get_role(&local_peer);
        let op = author_op(state, crdt_store, &server_id, CrdtPayload::RoleChanged {
            peer_id: peer_id.clone(),
            role: new_member_role,
            priority: author_role.priority(),
        });

        let _ = event_tx.send(NetworkEvent::RoleChanged {
            server_id: server_id.clone(),
            peer_id: peer_id.clone(),
            new_role: new_role.clone(),
        }).await;

        // Role-change is plaintext-only (no MLS path), so the member broadcast
        // skips our identity — the helper also fans to our OWN siblings.
        broadcast_op_plaintext_with_fan(
            ws_cmd_tx, ws_room_peers, gossip_overlays, event_tx, state, local_peer_str, local_device_id, &server_id, &op,
        );
    }
    false
}

// ── 10. KickMember ────────────────────────────────────────────────────

pub(crate) async fn handle_kick_member(
    server_states: &mut HashMap<String, ServerState>,
    mls: &mut Option<MlsManager>,
    olm: &mut OlmManager,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    local_device_id: &str,
    server_id: String,
    peer_id: String,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) -> bool {
    if let Some(state) = server_states.get_mut(&server_id) {
        if !state.can_kick(local_peer_str, &peer_id) {
            hollow_log!("[HOLLOW-CRDT] Permission denied: cannot kick {peer_id} from {server_id}");
            return deny(event_tx, "Permission denied: cannot kick this member").await;
        }

        hollow_log!("[HOLLOW-CRDT] Kicking member {peer_id} from {server_id}");
        // Collect broadcast targets BEFORE apply_op removes the member.
        let targets = other_member_targets(state, local_peer_str);
        let op = author_op(state, crdt_store, &server_id, CrdtPayload::MemberRemoved {
            peer_id: peer_id.clone(),
        });

        let _ = event_tx.send(NetworkEvent::MemberLeft {
            server_id: server_id.clone(),
            peer_id: peer_id.clone(),
        }).await;

        // Kicked peer is skipped — it gets MemberKickBroadcast instead.
        broadcast_removal_op(
            ws_cmd_tx, ws_room_peers, &targets, Some(&peer_id),
            local_peer_str, local_device_id, &server_id, &op,
        );

        // Send kick notification to EVERY online device of the kicked identity
        // via Olm (targeted) + plaintext broadcast.
        let kicked_devices = online_devices_for(ws_room_peers, &peer_id);
        let envelope = MessageEnvelope::MemberKick { sid: server_id.clone() };
        let kick_json = serde_json::to_string(&envelope).unwrap_or_default();
        let kick_bcast = serde_json::to_vec(&HavenMessage::MemberKickBroadcast {
            server_id: server_id.clone(),
        }).unwrap_or_default();
        for dev in &kicked_devices {
            send_encrypted_message(olm, crypto_store, dev, &kick_json, event_tx, ws_cmd_tx, ws_room_peers).await;
        }
        send_raw_to_identity(ws_cmd_tx, ws_room_peers, &peer_id, kick_bcast);

        if let Some(mls_mgr) = mls {
            mls_remove_identity_and_broadcast(
                mls_mgr, event_tx, ws_cmd_tx, crypto_store, &server_id, &peer_id,
                true, false,
                &format!("Removed all leaves of {peer_id} from MLS group, epoch rotated"),
            ).await;

            // Option B: also drop the kicked identity from every restricted-channel
            // subgroup so it loses access there too (not just the server group).
            let target_master = super::resolver::resolve(&peer_id);
            crate::node::crypto_handler::remove_identity_from_subgroups(
                mls_mgr, event_tx, ws_cmd_tx, crypto_store,
                state, &server_id, &target_master,
            ).await;
        }
    }
    false
}

// ── 10a. RevokeDevice (Step 7) ────────────────────────────────────────

/// Revoke one of OUR OWN devices (manual, lost or stolen). Bumps our master-signed
/// device list with the target tombstoned, re-broadcasts it so friends stop
/// encrypting to the revoked device, and returns the revoked device id so the
/// caller drops the Olm session and removes the MLS leaf. `None` when rejected.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_revoke_device(
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    master_peer_str: &str,
    local_peer_str: &str,
    device_peer_id: &str,
    is_invisible: bool,
    target_device: String,
    db_path: &str,
    db_passphrase: &str,
) -> Option<String> {
    let signed = super::crypto_handler::revoke_own_device(
        master_keypair, device_peer_id, &target_device, db_path, db_passphrase,
    );
    if signed.is_none() {
        let _ = event_tx.send(NetworkEvent::Error {
            message: "Cannot remove that device".to_string(),
        }).await;
        return None;
    }

    // CRITICAL: send the tombstone TO THE REVOKED DEVICE FIRST. It is the one peer
    // that most needs the v+1 list naming itself revoked, because its ingest fires
    // `SelfRevoked` and it wipes itself. Sent before the relay drops it from our
    // shared rooms as a side effect of the MLS leaf removal, so the message still
    // routes; skipping it left a revoked device running as the master forever.
    super::social::send_own_profile_to_peer(
        ws_cmd_tx, ws_room_peers,
        local_peer_str, master_keypair, device_peer_id, &target_device,
        is_invisible, db_path, db_passphrase,
    );

    // Then re-announce to every other peer we share a room with — friends converge
    // immediately and drop the revoked device. Skip ourselves and the target (just
    // sent above); siblings get it via their own ingest.
    let peers: Vec<String> = ws_room_peers.values().flat_map(|p| p.iter().cloned()).collect();
    for pid in peers {
        if pid == local_peer_str || pid == device_peer_id || pid == target_device {
            continue;
        }
        super::social::send_own_profile_to_peer(
            ws_cmd_tx, ws_room_peers,
            local_peer_str, master_keypair, device_peer_id, &pid,
            is_invisible, db_path, db_passphrase,
        );
    }

    let _ = event_tx.send(NetworkEvent::DeviceListUpdated {
        master_peer_id: master_peer_str.to_string(),
    }).await;
    Some(target_device)
}

// ── 10a2. ResetDeviceLists (full sibling teardown) ───────────────────

/// Tombstone EVERY sibling device in one version bump and propagate it: friends
/// converge and drop them, and each revoked sibling self-nukes on ingest. Returns
/// the revoked device ids, or `None` when we were already the sole device.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_reset_device_lists(
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    master_peer_str: &str,
    local_peer_str: &str,
    device_peer_id: &str,
    is_invisible: bool,
    db_path: &str,
    db_passphrase: &str,
) -> Option<Vec<String>> {
    let (_signed, revoked) = match super::crypto_handler::revoke_all_other_devices(
        master_keypair, device_peer_id, db_path, db_passphrase,
    ) {
        Some(r) => r,
        None => {
            // Nothing to revoke — still refresh the UI so it reflects the clean state.
            let _ = event_tx.send(NetworkEvent::DeviceListUpdated {
                master_peer_id: master_peer_str.to_string(),
            }).await;
            return None;
        }
    };

    // Push the v+1 tombstoned list to EACH revoked sibling FIRST (same ordering as
    // single revoke) so its ingest fires SelfRevoked → wipe + relaunch, before the
    // MLS-leaf removal drops it from our shared rooms.
    for target in &revoked {
        super::social::send_own_profile_to_peer(
            ws_cmd_tx, ws_room_peers,
            local_peer_str, master_keypair, device_peer_id, target,
            is_invisible, db_path, db_passphrase,
        );
    }
    // Then re-announce to every other peer we share a room with so friends converge
    // and drop the revoked devices. Skip ourselves and the revoked targets.
    let peers: Vec<String> = ws_room_peers.values().flat_map(|p| p.iter().cloned()).collect();
    for pid in peers {
        if pid == local_peer_str || pid == device_peer_id || revoked.contains(&pid) {
            continue;
        }
        super::social::send_own_profile_to_peer(
            ws_cmd_tx, ws_room_peers,
            local_peer_str, master_keypair, device_peer_id, &pid,
            is_invisible, db_path, db_passphrase,
        );
    }

    let _ = event_tx.send(NetworkEvent::DeviceListUpdated {
        master_peer_id: master_peer_str.to_string(),
    }).await;
    Some(revoked)
}

// ── 10b. LeaveServer ─────────────────────────────────────────────────

pub(crate) async fn handle_leave_server(
    server_states: &mut HashMap<String, ServerState>,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    local_device_id: &str,
    server_id: String,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) -> bool {
    if let Some(state) = server_states.get_mut(&server_id) {
        // Owner cannot leave — must delete or transfer ownership first.
        if state.get_role(local_peer_str) == crate::crdt::operations::MemberRole::Owner {
            hollow_log!("[HOLLOW-CRDT] Owner cannot leave server {server_id}");
            return deny(event_tx, "Owner cannot leave the server. Delete it or transfer ownership first.").await;
        }

        hollow_log!("[HOLLOW-CRDT] Leaving server {server_id}");
        // Collect broadcast targets BEFORE apply_op removes us.
        let targets = other_member_targets(state, local_peer_str);
        let op = author_op(state, crdt_store, &server_id, CrdtPayload::MemberRemoved {
            peer_id: local_peer_str.to_string(),
        });

        // Leaving is an identity-level action: `skip: None`, so the fan also sends
        // the self-removal op to our OWN siblings, each applying it because
        // peer_id == op.author. The acting device already left.
        broadcast_removal_op(
            ws_cmd_tx, ws_room_peers, &targets, None,
            local_peer_str, local_device_id, &server_id, &op,
        );

        // MLS: remove ALL of OUR leaves from the group (this device + any sibling
        // device's leaf — leaving the server means none of our devices stay).
        if let Some(mls_mgr) = mls {
            mls_remove_identity_and_broadcast(
                mls_mgr, event_tx, ws_cmd_tx, crypto_store, &server_id, local_peer_str,
                false, true,
                &format!("Left MLS group for {server_id}"),
            ).await;

            // Option B: drop every restricted-channel subgroup locally too. We're
            // leaving the whole server, so we discard the keys; remaining members
            // sweep our now-stale leaves on their next reconcile/KeyPackage.
            for cid in state.subgroup_channel_ids() {
                let gk = crate::crypto::subgroup_id(&server_id, &cid);
                if mls_mgr.has_group(&gk) {
                    mls_mgr.remove_group(&gk);
                }
            }
            persist_mls_state(mls_mgr, crypto_store);
        }
    }

    server_states.remove(&server_id);


    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom {
        room_code: server_id.clone(),
    });

    crdt_store.delete_server(server_id.clone());

    let _ = event_tx.send(NetworkEvent::ServerDeleted {
        server_id,
    }).await;
    false
}

// ── 10c. BanMember ──────────────────────────────────────────────────

pub(crate) async fn handle_ban_member(
    server_states: &mut HashMap<String, ServerState>,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    local_device_id: &str,
    server_id: String,
    peer_id: String,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) -> bool {
    if let Some(state) = server_states.get_mut(&server_id) {
        if !state.can_ban(local_peer_str, &peer_id) {
            hollow_log!("[HOLLOW-CRDT] Permission denied: cannot ban {peer_id} from {server_id}");
            return deny(event_tx, "Permission denied: cannot ban this member").await;
        }

        hollow_log!("[HOLLOW-CRDT] Banning member {peer_id} from {server_id}");
        // Collect broadcast targets BEFORE apply_op removes the member.
        let targets = other_member_targets(state, local_peer_str);
        let op = author_op(state, crdt_store, &server_id, CrdtPayload::MemberBanned {
            peer_id: peer_id.clone(),
        });

        let _ = event_tx.send(NetworkEvent::MemberLeft {
            server_id: server_id.clone(),
            peer_id: peer_id.clone(),
        }).await;

        // Banned peer is skipped — it gets MemberKickBroadcast instead.
        broadcast_removal_op(
            ws_cmd_tx, ws_room_peers, &targets, Some(&peer_id),
            local_peer_str, local_device_id, &server_id, &op,
        );

        // Send kick notification to every device of the banned identity.
        let ban_bcast = serde_json::to_vec(&HavenMessage::MemberKickBroadcast {
            server_id: server_id.clone(),
        }).unwrap_or_default();
        send_raw_to_identity(ws_cmd_tx, ws_room_peers, &peer_id, ban_bcast);

        if let Some(mls_mgr) = mls {
            mls_remove_identity_and_broadcast(
                mls_mgr, event_tx, ws_cmd_tx, crypto_store, &server_id, &peer_id,
                true, false,
                &format!("Removed all leaves of banned {peer_id} from MLS group"),
            ).await;

            // Option B: also drop the banned identity from every restricted-channel subgroup.
            let target_master = super::resolver::resolve(&peer_id);
            crate::node::crypto_handler::remove_identity_from_subgroups(
                mls_mgr, event_tx, ws_cmd_tx, crypto_store,
                state, &server_id, &target_master,
            ).await;
        }
    }
    false
}

// ── 10d. UnbanMember ────────────────────────────────────────────────

pub(crate) async fn handle_unban_member(
    server_states: &mut ServerStates,
    mls: &mut Option<MlsManager>,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    peer_id: String,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) -> bool {
    author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        OpGate::Perm(Permission::KICK_MEMBERS),
        Some("Permission denied: cannot unban members"),
        CrdtPayload::MemberUnbanned { peer_id: peer_id.clone() },
        &format!("Unbanning member {peer_id}"),
        NetworkEvent::ServerUpdated { server_id: server_id.clone() },
        OpBroadcast::MlsFirst { mls, crypto_store },
        crdt_store,
    ).await
}

// ── 10d-bis. Moderation trio: mute / slow mode / media-only ──────────

/// Server-wide mute (read-only member). `expires_at` = epoch ms, u64::MAX = permanent.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_mute_member(
    server_states: &mut ServerStates,
    mls: &mut Option<MlsManager>,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    local_peer_str: &str,
    server_id: String,
    peer_id: String,
    expires_at: u64,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) -> bool {
    // Mutes are master-keyed (multi-device): normalize if a device id slipped in.
    let target_master = super::resolver::resolve(&peer_id);
    author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        OpGate::CanMute(&target_master),
        Some("Permission denied: cannot mute this member"),
        CrdtPayload::MemberMuted { peer_id: target_master.clone(), expires_at },
        &format!("Muting member {target_master} until {expires_at}"),
        NetworkEvent::ServerUpdated { server_id: server_id.clone() },
        OpBroadcast::MlsFirst { mls, crypto_store },
        crdt_store,
    ).await
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_unmute_member(
    server_states: &mut ServerStates,
    mls: &mut Option<MlsManager>,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    local_peer_str: &str,
    server_id: String,
    peer_id: String,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) -> bool {
    let target_master = super::resolver::resolve(&peer_id);
    author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        OpGate::Perm(Permission::KICK_MEMBERS),
        Some("Permission denied: cannot unmute members"),
        CrdtPayload::MemberUnmuted { peer_id: target_master.clone() },
        &format!("Unmuting member {target_master}"),
        NetworkEvent::ServerUpdated { server_id: server_id.clone() },
        OpBroadcast::MlsFirst { mls, crypto_store },
        crdt_store,
    ).await
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_set_channel_slow_mode(
    server_states: &mut ServerStates,
    mls: &mut Option<MlsManager>,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    seconds: u32,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) -> bool {
    author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        OpGate::Perm(Permission::MANAGE_CHANNELS),
        Some("Permission denied: cannot manage channels"),
        CrdtPayload::ChannelSlowModeChanged { channel_id: channel_id.clone(), seconds },
        &format!("Setting slow_mode={seconds}s on {channel_id}"),
        NetworkEvent::ServerUpdated { server_id: server_id.clone() },
        OpBroadcast::MlsFirst { mls, crypto_store },
        crdt_store,
    ).await
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_set_channel_media_only(
    server_states: &mut ServerStates,
    mls: &mut Option<MlsManager>,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    media_only: bool,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) -> bool {
    author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        OpGate::Perm(Permission::MANAGE_CHANNELS),
        Some("Permission denied: cannot manage channels"),
        CrdtPayload::ChannelMediaOnlyChanged { channel_id: channel_id.clone(), media_only },
        &format!("Setting media_only={media_only} on {channel_id}"),
        NetworkEvent::ServerUpdated { server_id: server_id.clone() },
        OpBroadcast::MlsFirst { mls, crypto_store },
        crdt_store,
    ).await
}

// ── 10e. Label operations ────────────────────────────────────────────

pub(crate) async fn handle_label_op(
    server_states: &mut ServerStates,
    mls: &mut Option<MlsManager>,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    payload: CrdtPayload,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) -> bool {
    // Self-assign/unassign: any member can toggle their own COSMETIC labels. Access
    // labels (and unknown label ids) require MANAGE_ROLES even on yourself, because
    // they gate channels and self-assignment would be privilege escalation. Shared
    // rule with op_allowed via `can_self_toggle_label`, so the gates cannot drift.
    let is_self_toggle = match &payload {
        CrdtPayload::LabelAssigned { label_id, peer_id }
        | CrdtPayload::LabelUnassigned { label_id, peer_id } => server_states
            .get(&server_id)
            .is_some_and(|s| s.can_self_toggle_label(local_peer_str, peer_id, label_id)),
        _ => false,
    };
    let gate = if is_self_toggle { OpGate::Always } else { OpGate::Perm(Permission::MANAGE_ROLES) };
    author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        gate,
        Some("Permission denied: cannot manage labels"),
        payload,
        "Applying label op",
        NetworkEvent::ServerUpdated { server_id: server_id.clone() },
        OpBroadcast::MlsFirst { mls, crypto_store },
        crdt_store,
    ).await
}

// ── 10e2. Custom emote + sticker operations ─────────────────────────

/// Author an EmojiAdded/EmojiRemoved or StickerAdded/StickerRemoved op. Mirrors
/// [handle_label_op]. The BYTES never ride the CRDT: the caller stored them in the
/// local asset blob cache and members pull them on demand via EmoteRequest.
///
/// Both families share `Permission::MANAGE_EMOTES`, which is why one handler serves them.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_emote_op(
    server_states: &mut ServerStates,
    mls: &mut Option<MlsManager>,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    _bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    payload: CrdtPayload,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) -> bool {
    if let Some(state) = server_states.get_mut(&server_id) {
        if !state.has_permission(local_peer_str, Permission::MANAGE_EMOTES) {
            hollow_log!("[HOLLOW-CRDT] Permission denied: cannot manage emotes in {server_id}");
            return deny(event_tx, "Permission denied: cannot manage emotes").await;
        }

        if let CrdtPayload::EmojiAdded { name, hash, .. } = &payload {
            if !crate::crdt::valid_emote_name(name) || !crate::crdt::valid_emote_hash(hash) {
                return deny(event_tx, "Invalid emote name").await;
            }
            if !state.emotes.contains_key(name)
                && state.emotes.len() >= crate::crdt::server_state::MAX_SERVER_EMOTES
            {
                return deny(event_tx, &format!(
                    "Emote limit reached ({} per server)",
                    crate::crdt::server_state::MAX_SERVER_EMOTES
                )).await;
            }
        }

        if let CrdtPayload::StickerAdded { hash, name, pack, w, h, .. } = &payload {
            if !crate::crdt::valid_emote_hash(hash)
                || !crate::crdt::server_state::valid_sticker_label(name)
                || !crate::crdt::server_state::valid_sticker_label(pack)
                || !(1..=4096).contains(w)
                || !(1..=4096).contains(h)
            {
                return deny(event_tx, "Invalid sticker").await;
            }
            if !state.stickers.contains_key(hash)
                && state.stickers.len() >= crate::crdt::server_state::MAX_SERVER_STICKERS
            {
                return deny(event_tx, &format!(
                    "Sticker limit reached ({} per server)",
                    crate::crdt::server_state::MAX_SERVER_STICKERS
                )).await;
            }
        }

        let op = author_op(state, crdt_store, &server_id, payload);

        let _ = event_tx.send(NetworkEvent::ServerUpdated {
            server_id: server_id.clone(),
        }).await;

        broadcast_op_mls_first(
            mls, ws_cmd_tx, ws_room_peers, gossip_overlays, event_tx, state, local_peer_str, &server_id, &op, crypto_store,
        );
    }
    false
}

// ── 10f. SetChannelVisibility ───────────────────────────────────────

pub(crate) async fn handle_set_channel_visibility(
    server_states: &mut ServerStates,
    mls: &mut Option<MlsManager>,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    visibility: String,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) -> bool {
    if author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        OpGate::Perm(Permission::MANAGE_CHANNELS),
        Some("Permission denied: cannot manage channels"),
        CrdtPayload::ChannelVisibilityChanged { channel_id: channel_id.clone(), visibility: visibility.clone() },
        &format!("Setting channel {channel_id} visibility to {visibility}"),
        NetworkEvent::ServerUpdated { server_id: server_id.clone() },
        OpBroadcast::MlsFirst { mls, crypto_store },
        crdt_store,
    ).await {
        return true;
    }

    // Picking a plain tier on a label-gated channel also clears the label gate (the
    // UI presents them as ONE selector, and a stale label list would keep gating on
    // new clients). Authored second, so HLC-later wins everywhere.
    let had_labels = server_states
        .get(&server_id)
        .and_then(|s| s.channels.get(&channel_id))
        .is_some_and(|ch| !ch.visibility_labels.is_empty());
    if had_labels {
        if author_broadcast_op(
            server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
            &server_id,
            OpGate::Perm(Permission::MANAGE_CHANNELS),
            Some("Permission denied: cannot manage channels"),
            CrdtPayload::ChannelVisibilityLabelsChanged { channel_id: channel_id.clone(), labels: Vec::new() },
            &format!("Clearing channel {channel_id} visibility label gate"),
            NetworkEvent::ServerUpdated { server_id: server_id.clone() },
            OpBroadcast::MlsFirst { mls, crypto_store },
            crdt_store,
        ).await {
            return true;
        }
    }

    // Per-channel MLS subgroup: if the channel is no longer restricted, tear its
    // subgroup down locally and messages revert to the server-wide group. Becoming
    // restricted is handled by the swarm reconciler, which owns the batch queues.
    if let Some(state) = server_states.get(&server_id)
        && !state.channel_uses_subgroup(&channel_id)
        && let Some(mls_mgr) = mls.as_mut()
    {
        let group_key = crate::crypto::subgroup_id(&server_id, &channel_id);
        if mls_mgr.has_group(&group_key) {
            hollow_log!("[HOLLOW-MLS] Channel {channel_id} no longer restricted — removing subgroup {group_key}");
            mls_mgr.remove_group(&group_key);
            crate::node::crypto_handler::persist_mls_state(mls_mgr, crypto_store);
        }
    }
    false
}

// ── 10f. SetChannelPosting ──────────────────────────────────────────

pub(crate) async fn handle_set_channel_posting(
    server_states: &mut ServerStates,
    mls: &mut Option<MlsManager>,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    posting: String,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) -> bool {
    if author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        OpGate::Perm(Permission::MANAGE_CHANNELS),
        Some("Permission denied: cannot manage channels"),
        CrdtPayload::ChannelPostingChanged { channel_id: channel_id.clone(), posting: posting.clone() },
        &format!("Setting channel {channel_id} posting to {posting}"),
        NetworkEvent::ServerUpdated { server_id: server_id.clone() },
        OpBroadcast::MlsFirst { mls, crypto_store },
        crdt_store,
    ).await {
        return true;
    }

    // Same one-selector rule as visibility: a plain posting tier clears any
    // posting label gate.
    let had_labels = server_states
        .get(&server_id)
        .and_then(|s| s.channels.get(&channel_id))
        .is_some_and(|ch| !ch.posting_labels.is_empty());
    if had_labels {
        return author_broadcast_op(
            server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
            &server_id,
            OpGate::Perm(Permission::MANAGE_CHANNELS),
            Some("Permission denied: cannot manage channels"),
            CrdtPayload::ChannelPostingLabelsChanged { channel_id: channel_id.clone(), labels: Vec::new() },
            &format!("Clearing channel {channel_id} posting label gate"),
            NetworkEvent::ServerUpdated { server_id: server_id.clone() },
            OpBroadcast::MlsFirst { mls, crypto_store },
            crdt_store,
        ).await;
    }
    false
}

// ── 10f-1b. Label-gated access + temporary grants (issue #32) ────────

/// Set (or clear, empty vec) the visibility label gate. When the gate turns ON a
/// plain `ChannelVisibilityChanged{"admin"}` stamp is authored FIRST: clients that
/// predate the labels op drop it but honor the stamp, so the channel fails closed
/// rather than open. Both ops come from our HLC in sequence, so replicas converge.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_set_channel_visibility_labels(
    server_states: &mut ServerStates,
    mls: &mut Option<MlsManager>,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    labels: Vec<String>,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) -> bool {
    let needs_admin_stamp = !labels.is_empty()
        && server_states
            .get(&server_id)
            .and_then(|s| s.channels.get(&channel_id))
            .is_some_and(|ch| ch.visibility != crate::crdt::server_state::ChannelVisibility::AdminPlus);
    if needs_admin_stamp {
        if author_broadcast_op(
            server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
            &server_id,
            OpGate::Perm(Permission::MANAGE_CHANNELS),
            Some("Permission denied: cannot manage channels"),
            CrdtPayload::ChannelVisibilityChanged { channel_id: channel_id.clone(), visibility: "admin".to_string() },
            &format!("Stamping channel {channel_id} visibility to admin (label-gate fallback)"),
            NetworkEvent::ServerUpdated { server_id: server_id.clone() },
            OpBroadcast::MlsFirst { mls, crypto_store },
            crdt_store,
        ).await {
            return true; // gate denied — abort before the labels op
        }
    }

    if author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        OpGate::Perm(Permission::MANAGE_CHANNELS),
        Some("Permission denied: cannot manage channels"),
        CrdtPayload::ChannelVisibilityLabelsChanged { channel_id: channel_id.clone(), labels: labels.clone() },
        &format!("Setting channel {channel_id} visibility labels ({} entries)", labels.len()),
        NetworkEvent::ServerUpdated { server_id: server_id.clone() },
        OpBroadcast::MlsFirst { mls, crypto_store },
        crdt_store,
    ).await {
        return true;
    }

    // Defensive teardown mirror of handle_set_channel_visibility: if the
    // channel ended up fully unrestricted (labels cleared while the tier is
    // Everyone), drop its subgroup locally.
    if let Some(state) = server_states.get(&server_id)
        && !state.channel_uses_subgroup(&channel_id)
        && let Some(mls_mgr) = mls.as_mut()
    {
        let group_key = crate::crypto::subgroup_id(&server_id, &channel_id);
        if mls_mgr.has_group(&group_key) {
            hollow_log!("[HOLLOW-MLS] Channel {channel_id} no longer restricted — removing subgroup {group_key}");
            mls_mgr.remove_group(&group_key);
            crate::node::crypto_handler::persist_mls_state(mls_mgr, crypto_store);
        }
    }
    false
}

/// Set (or clear) the posting label gate. Same old-client stamp pairing as the
/// visibility twin, because old clients enforce posting send-side and would
/// otherwise let anyone post into a label-gated channel. Posting never subgroups.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_set_channel_posting_labels(
    server_states: &mut ServerStates,
    mls: &mut Option<MlsManager>,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    labels: Vec<String>,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) -> bool {
    let needs_admin_stamp = !labels.is_empty()
        && server_states
            .get(&server_id)
            .and_then(|s| s.channels.get(&channel_id))
            .is_some_and(|ch| ch.posting != crate::crdt::server_state::ChannelPosting::AdminPlus);
    if needs_admin_stamp {
        if author_broadcast_op(
            server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
            &server_id,
            OpGate::Perm(Permission::MANAGE_CHANNELS),
            Some("Permission denied: cannot manage channels"),
            CrdtPayload::ChannelPostingChanged { channel_id: channel_id.clone(), posting: "admin".to_string() },
            &format!("Stamping channel {channel_id} posting to admin (label-gate fallback)"),
            NetworkEvent::ServerUpdated { server_id: server_id.clone() },
            OpBroadcast::MlsFirst { mls, crypto_store },
            crdt_store,
        ).await {
            return true;
        }
    }

    author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        OpGate::Perm(Permission::MANAGE_CHANNELS),
        Some("Permission denied: cannot manage channels"),
        CrdtPayload::ChannelPostingLabelsChanged { channel_id: channel_id.clone(), labels: labels.clone() },
        &format!("Setting channel {channel_id} posting labels ({} entries)", labels.len()),
        NetworkEvent::ServerUpdated { server_id: server_id.clone() },
        OpBroadcast::MlsFirst { mls, crypto_store },
        crdt_store,
    ).await
}

/// Grant a member time-boxed access to one channel. Authoring-side friendly
/// validation (channel exists, target is a member) is STRICTER than ingest —
/// the safe asymmetry (looser-than-ingest would fork).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_grant_channel_access(
    server_states: &mut ServerStates,
    mls: &mut Option<MlsManager>,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    peer_id: String,
    expires_at: u64,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) -> bool {
    if let Some(state) = server_states.get(&server_id) {
        if !state.channels.contains_key(&channel_id) {
            return deny(event_tx, "Channel not found").await;
        }
        if !state.is_member(&peer_id) {
            return deny(event_tx, "Not a member of this server").await;
        }
    }
    author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        OpGate::Perm(Permission::MANAGE_CHANNELS),
        Some("Permission denied: cannot manage channels"),
        CrdtPayload::ChannelGrantSet { channel_id: channel_id.clone(), peer_id, expires_at },
        &format!("Granting temporary access to channel {channel_id}"),
        NetworkEvent::ServerUpdated { server_id: server_id.clone() },
        OpBroadcast::MlsFirst { mls, crypto_store },
        crdt_store,
    ).await
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_revoke_channel_access(
    server_states: &mut ServerStates,
    mls: &mut Option<MlsManager>,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    peer_id: String,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) -> bool {
    author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        OpGate::Perm(Permission::MANAGE_CHANNELS),
        Some("Permission denied: cannot manage channels"),
        CrdtPayload::ChannelGrantRevoked { channel_id: channel_id.clone(), peer_id },
        &format!("Revoking temporary access to channel {channel_id}"),
        NetworkEvent::ServerUpdated { server_id: server_id.clone() },
        OpBroadcast::MlsFirst { mls, crypto_store },
        crdt_store,
    ).await
}

// ── 10f-2. SetChannelPublic ──────────────────────────────────────

pub(crate) async fn handle_set_channel_public(
    server_states: &mut ServerStates,
    mls: &mut Option<MlsManager>,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    is_public: bool,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) -> bool {
    // Voice channels can never be public (#44): the browser's list responders filter
    // them out and a public voice channel flips its SFrame key domain. The UIs hide
    // the toggle; this covers stale UIs and any other caller.
    if server_states
        .get(&server_id)
        .and_then(|s| s.channels.get(&channel_id))
        .is_some_and(|ch| ch.channel_type != crate::crdt::server_state::ChannelType::Text)
    {
        hollow_log!("[HOLLOW-CRDT] REFUSED set_channel_public on non-text channel {channel_id}");
        let _ = event_tx.send(NetworkEvent::Error {
            message: "Voice channels cannot be made public".to_string(),
        }).await;
        return true;
    }
    if author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        OpGate::Perm(Permission::MANAGE_CHANNELS),
        Some("Permission denied: cannot manage channels"),
        CrdtPayload::ChannelPublicChanged { channel_id: channel_id.clone(), is_public },
        &format!("Setting channel {channel_id} is_public={is_public}"),
        NetworkEvent::ServerUpdated { server_id: server_id.clone() },
        OpBroadcast::MlsFirst { mls, crypto_store },
        crdt_store,
    ).await {
        return true;
    }

    if let Some(state) = server_states.get(&server_id) {
        // Broadcast to room (including guests) so public channel browsers see the change
        if let Some(ch) = state.channels.get(&channel_id) {
            let notify = HavenMessage::PublicChannelConfigChanged {
                server_id: server_id.clone(),
                channel_id: channel_id.clone(),
                is_public,
                channel_name: ch.name.clone(),
                category: ch.category.clone(),
            };
            if let Ok(data) = serde_json::to_vec(&notify) {
                let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom {
                    room_code: server_id.clone(),
                    data,
                });
            }
            // Also emit locally so in-app guest browser updates for own servers
            let _ = event_tx.send(NetworkEvent::PublicChannelConfigChanged {
                server_id: server_id.clone(),
                channel_id: channel_id.clone(),
                is_public,
                channel_name: ch.name.clone(),
                category: ch.category.clone(),
            }).await;
        }
    }
    false
}

// ── 10g. ChangeRolePermissions ──────────────────────────────────────

pub(crate) async fn handle_change_role_permissions(
    server_states: &mut ServerStates,
    mls: &mut Option<MlsManager>,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    role: String,
    permissions: u32,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) -> bool {
    // Must have MANAGE_ROLES and can only edit roles below own rank.
    author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        OpGate::ManageRolesOutranking(&role),
        Some(&format!("Permission denied: cannot change {role} permissions")),
        CrdtPayload::RolePermissionsChanged { role: role.clone(), permissions },
        &format!("Changing {role} permissions to {permissions}"),
        NetworkEvent::ServerUpdated { server_id: server_id.clone() },
        OpBroadcast::MlsFirst { mls, crypto_store },
        crdt_store,
    ).await
}

// ── 11. SetNickname ───────────────────────────────────────────────────

pub(crate) async fn handle_set_nickname(
    server_states: &mut ServerStates,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    _bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    local_device_id: &str,
    server_id: String,
    peer_id: String,
    nickname: String,
    crdt_store: &CrdtStore,
) -> bool {
    // Members can set their own nickname. Admins+ can set others'.
    // Event = MemberJoined so Dart refreshes the member list.
    author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        OpGate::SelfOrPerm(&peer_id, Permission::MANAGE_ROLES),
        None,
        CrdtPayload::NicknameChanged { peer_id: peer_id.clone(), nickname: nickname.clone() },
        &format!("Setting nickname for {peer_id} to '{nickname}'"),
        NetworkEvent::MemberJoined { server_id: server_id.clone(), peer_id: peer_id.clone() },
        OpBroadcast::PlaintextWithFan { local_device_id },
        crdt_store,
    ).await
}

// ── 11b. SetTwitchUsername ─────────────────────────────────────────────

pub(crate) async fn handle_set_twitch_username(
    server_states: &mut ServerStates,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    _bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    local_device_id: &str,
    server_id: String,
    peer_id: String,
    twitch_username: String,
    crdt_store: &CrdtStore,
) -> bool {
    author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        OpGate::SelfOrPerm(&peer_id, Permission::MANAGE_ROLES),
        None,
        CrdtPayload::TwitchUsernameChanged { peer_id: peer_id.clone(), twitch_username: twitch_username.clone() },
        &format!("Setting twitch username for {peer_id}"),
        NetworkEvent::MemberJoined { server_id: server_id.clone(), peer_id: peer_id.clone() },
        OpBroadcast::PlaintextWithFan { local_device_id },
        crdt_store,
    ).await
}

// ── 12. RequestChannelSync ────────────────────────────────────────────

pub(crate) async fn handle_request_channel_sync(
    server_states: &HashMap<String, ServerState>,
    _event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    channel_sync_sent: &mut HashMap<String, std::time::Instant>,
    server_id: String,
    channel_id: String,
    _crdt_store: &CrdtStore,
    db_path: &str,
    db_passphrase: &str,
) -> bool {
    // On-demand sync when user opens a channel.
    // Dedup: skip if already synced this channel recently.
    let dedup_key = format!("{server_id}:{channel_id}");
    if channel_sync_sent.get(&dedup_key).is_some_and(|t| t.elapsed() < Duration::from_secs(5)) {
        return true;
    }
    channel_sync_sent.insert(dedup_key, std::time::Instant::now());
    if let Some(state) = server_states.get(&server_id) {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let since = store
                .get_latest_channel_timestamp(&server_id, &channel_id)
                .unwrap_or(None)
                .unwrap_or(0);
            let sender_ts = store
                .get_per_sender_timestamps(&server_id, &channel_id)
                .unwrap_or_default();
            let local_peer = local_peer_str.to_string();
            let sync_data = serde_json::to_vec(&HavenMessage::ChannelSyncRequest {
                server_id: server_id.clone(),
                channel_id: channel_id.clone(),
                since_timestamp: since,
                sender_timestamps: sender_ts.clone(),
            }).unwrap_or_default();
            let _ = local_peer;
            broadcast_raw_to_members(ws_cmd_tx, ws_room_peers, state, local_peer_str, sync_data);
        }
    }
    false
}

// ── 13. UpdateChannelLayout ───────────────────────────────────────────

pub(crate) async fn handle_update_channel_layout(
    server_states: &mut ServerStates,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    _bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    local_device_id: &str,
    server_id: String,
    layout_json: String,
    crdt_store: &CrdtStore,
) -> bool {
    author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        OpGate::Perm(Permission::MANAGE_CHANNELS),
        None,
        CrdtPayload::ChannelLayoutUpdated { layout_json: layout_json.clone() },
        &format!("Updating channel layout, layout_json={layout_json}"),
        NetworkEvent::ServerUpdated { server_id: server_id.clone() },
        OpBroadcast::PlaintextWithFan { local_device_id },
        crdt_store,
    ).await
}

// ── 14. PinMessage ────────────────────────────────────────────────────

pub(crate) async fn handle_pin_message(
    server_states: &mut ServerStates,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    _bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    local_device_id: &str,
    server_id: String,
    channel_id: String,
    message_id: String,
    crdt_store: &CrdtStore,
) -> bool {
    author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        OpGate::Perm(Permission::MANAGE_CHANNELS),
        None,
        CrdtPayload::MessagePinned { channel_id: channel_id.clone(), message_id: message_id.clone() },
        &format!("Pinning message {message_id} in channel {channel_id}"),
        NetworkEvent::MessagePinned { server_id: server_id.clone(), channel_id, message_id },
        OpBroadcast::PlaintextWithFan { local_device_id },
        crdt_store,
    ).await
}

// ── 15. UnpinMessage ──────────────────────────────────────────────────

pub(crate) async fn handle_unpin_message(
    server_states: &mut ServerStates,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    _bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    local_device_id: &str,
    server_id: String,
    channel_id: String,
    message_id: String,
    crdt_store: &CrdtStore,
) -> bool {
    // Payload hoisted (unlike the pin twin) so the two functions don't form
    // one long identical token run for Sonar's copy-paste detector.
    let unpin_payload = CrdtPayload::MessageUnpinned {
        channel_id: channel_id.clone(),
        message_id: message_id.clone(),
    };
    author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        OpGate::Perm(Permission::MANAGE_CHANNELS),
        None,
        unpin_payload,
        &format!("Unpinning message {message_id} in channel {channel_id}"),
        NetworkEvent::MessageUnpinned { server_id: server_id.clone(), channel_id, message_id },
        OpBroadcast::PlaintextWithFan { local_device_id },
        crdt_store,
    ).await
}

// ── 16. SetStoragePledge ──────────────────────────────────────────────

pub(crate) async fn handle_set_storage_pledge(
    server_states: &mut ServerStates,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    _bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    local_device_id: &str,
    server_id: String,
    pledge_bytes: u64,
    crdt_store: &CrdtStore,
) {
    let _ = author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        OpGate::Always,
        None,
        CrdtPayload::StoragePledgeChanged { peer_id: local_peer_str.to_string(), pledge_bytes },
        &format!("Setting storage pledge to {pledge_bytes} bytes"),
        NetworkEvent::ServerUpdated { server_id: server_id.clone() },
        OpBroadcast::PlaintextWithFan { local_device_id },
        crdt_store,
    ).await;
}

// ── 17. CheckPendingJoinTimeout: a window elapsed, so PARK ───────────

/// How long a join waits for a member who is THERE.
///
/// The coordinator election, its 4s retry, a full state snapshot and the whole op
/// log all have to cross the wire inside this, and a member one round trip from
/// answering is the normal case, so parking under it would front a live join.
pub(crate) const JOIN_LIVE_WINDOW: Duration = Duration::from_secs(15);

/// How long a join waits when the relay has already answered the question.
///
/// Two windows exist because "nobody answered" has two very different causes. A
/// room with somebody in it needs [`JOIN_LIVE_WINDOW`]; a room the relay described
/// as EMPTY needs nothing. Saying so early costs nothing, because parking is not a
/// failure: the request goes into the `~join` ring and a member still completes it.
pub(crate) const JOIN_EMPTY_ROOM_WINDOW: Duration = Duration::from_secs(3);

/// Nobody answered inside the window, which is not a failure any more.
///
/// The request is marked parked and deposited into the server room's `~join` ring.
/// We STAY IN THE ROOM, because that is how both legs of the answer reach us
/// later: buffered targeted frames replay on a room join, and the ring catch-up is
/// gated on room membership.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_check_pending_join_timeout(
    pending_server_joins: &mut HashMap<String, PendingJoin>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    local_peer_str: &str,
    local_device_id: &str,
    server_id: String,
    only_if_empty: bool,
    crdt_store: &CrdtStore,
) {
    // Already gone = the join completed or was discarded; already parked = a
    // stale timer from an earlier attempt. Both are no-ops.
    let Some(pending) = pending_server_joins.get_mut(&server_id) else { return };
    if pending.parked {
        return;
    }
    if only_if_empty {
        // The short window speaks only for a room the relay has actually described
        // to us. An entry appears the moment `RoomMembers` answers our join (an
        // empty room included) and is dropped on disconnect, so NO entry means we
        // have not looked yet rather than that nobody is there.
        //
        // OUR OWN ids are filtered here rather than trusted to be absent: the
        // `PeerJoined` site inserts whatever id the relay named, and a room the
        // socket joins twice makes the relay announce US to ourselves, so the room
        // reads as occupied by nobody but us.
        let known_empty = ws_room_peers.get(&server_id).is_some_and(|peers| {
            peers.iter().all(|p| p == local_peer_str || p == local_device_id)
        });
        if !known_empty {
            return;
        }
        hollow_log!("[HOLLOW-CRDT] Nobody is in the room for {server_id}; parking the join after the short window");
    } else {
        hollow_log!("[HOLLOW-CRDT] No answer within the live window for {server_id} — parking the join");
    }
    pending.parked = true;
    pending.last_deposited_at = super::types::now_ms();
    deposit_parked_join(ws_cmd_tx, &server_id, pending);
    crdt_store.upsert_pending_join(pending_join_row(&server_id, pending, "pending", ""));
    let _ = event_tx.send(NetworkEvent::ServerJoinParked {
        server_id,
    }).await;
}

// ── 17b. DiscardPendingJoin (user action) ─────────────────────────────

/// The user gave up on a pending or rejected tile.
///
/// Nothing reaches the relay: the ring copy cannot be recalled and just ages
/// out. What makes the discard STICK is local — no row, so no boot rejoin of
/// that room, so a late admission's buffered snapshot is never collected.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_discard_pending_join(
    pending_server_joins: &mut HashMap<String, PendingJoin>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    server_id: String,
    crdt_store: &CrdtStore,
) {
    hollow_log!("[HOLLOW-CRDT] Discarding pending join for {server_id}");
    let spent = pending_server_joins.remove(&server_id).and_then(|p| p.key_package);
    crdt_store.delete_pending_join(server_id.clone());
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom {
        room_code: server_id.clone(),
    });
    let _ = event_tx.send(NetworkEvent::PendingJoinUpdated {
        server_id: server_id.clone(),
        state: "discarded".to_string(),
        reason: String::new(),
    }).await;
    discard_join_key_package(mls, crypto_store, &server_id, spent.as_deref());
}

// ── 18. flush_pending_sync_requests ───────────────────────────────────

pub(crate) async fn flush_pending_sync_requests(
    pending_sync_requests: &mut HashMap<String, Vec<(String, String, i64)>>,
    peer_str: &str,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    _crdt_store: &CrdtStore,
    db_path: &str,
    db_passphrase: &str,
) {
    let Some(entries) = pending_sync_requests.remove(peer_str) else {
        return;
    };
    if entries.is_empty() {
        return;
    }

    hollow_log!("[HOLLOW-SYNC] Flushing {} pending sync requests for {peer_str}", entries.len());

    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else { return };

    for (server_id, channel_id, since_timestamp) in entries {
        let _ = event_tx.send(NetworkEvent::MessageSyncStarted {
            server_id: server_id.clone(),
            peer_id: peer_str.to_string(),
        }).await;

        // Re-query per-sender timestamps at flush time (DB may have changed since original request).
        let sender_ts = store.get_per_sender_timestamps(&server_id, &channel_id).unwrap_or_default();
        match build_channel_sync_batch(&store, &server_id, &channel_id, since_timestamp, &sender_ts) {
            Ok((envelope, count)) => {
                hollow_log!("[HOLLOW-SYNC] Retry: sending {count} messages for {channel_id} to {peer_str}");
                let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();
                let ok = send_encrypted_message(
                    olm, crypto_store,
                    peer_str, &envelope_json, event_tx,
                    ws_cmd_tx, ws_room_peers,
                ).await;

                if !ok {
                    hollow_log!("[HOLLOW-SYNC] Retry also failed for {server_id} — giving up");
                    let _ = event_tx.send(NetworkEvent::MessageSyncFailed {
                        server_id,
                        error: "Retry after re-key also failed".to_string(),
                    }).await;
                }
            }
            Err(e) => {
                hollow_log!("[HOLLOW-SYNC] DB query failed during retry for {server_id}: {e}");
            }
        }
    }
}

/// Handle `MessageEnvelope::CrdtOp` (MLS path) — permission-checked CRDT op application.
pub(crate) async fn handle_envelope_crdt_op(
    server_states: &mut ServerStates,
    _bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &EventTx,
    sid: String,
    op_json: String,
    crdt_store: &CrdtStore,
    ws_cmd_tx: &WsCmdTx,
) {
    let Some(state) = server_states.get_mut(&sid) else { return };
    let Ok(op) = serde_json::from_str::<crate::crdt::operations::CrdtOp>(&op_json) else { return };
    // The ONE admission gate (ServerState::admit_remote_op): the author's
    // signature, the clock bound, then the shared permission matrix. It
    // validates op.author (the creator), never the transport sender.
    if let Err(reason) = state.admit_remote_op(&op) {
        hollow_log!(
            "[HOLLOW-SECURITY] REJECTED MLS CrdtOp {} for {sid} from {}: {reason}",
            crate::crdt::sync::payload_name(&op.payload),
            op.author,
        );
        return;
    }
    let was_len = state.op_log.len();
    let _ = state.apply_op(&op);
    if state.op_log.len() > was_len {
        crdt_store.insert_op(op.clone());
        crdt_store.save_state_snapshot(sid.clone(), state);
        emit_crdt_apply_event(event_tx, ws_cmd_tx, state, &sid, &op).await;
    }
}

/// Emit the UI event matching a freshly-applied remote CRDT op (MLS ingest
/// path — the plaintext twin in swarm.rs has extra self-eviction/MLS teardown
/// duties, so it keeps its own richer match).
async fn emit_crdt_apply_event(
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    state: &ServerState,
    sid: &str,
    op: &crate::crdt::operations::CrdtOp,
) {
    let sid = sid.to_string();
    {
        match &op.payload {
            CrdtPayload::ChannelAdded { channel_id, name, channel_type, .. } => {
                let _ = event_tx.send(NetworkEvent::ChannelAdded {
                    server_id: sid.clone(), channel_id: channel_id.clone(), name: name.clone(), channel_type: channel_type.clone(),
                }).await;
            }
            CrdtPayload::ChannelRemoved { channel_id } => {
                let _ = event_tx.send(NetworkEvent::ChannelRemoved {
                    server_id: sid.clone(), channel_id: channel_id.clone(),
                }).await;
            }
            CrdtPayload::MemberAdded { peer_id, .. } => {
                let _ = event_tx.send(NetworkEvent::MemberJoined {
                    server_id: sid.clone(), peer_id: peer_id.clone(),
                }).await;
            }
            CrdtPayload::MemberRemoved { peer_id } => {
                let _ = event_tx.send(NetworkEvent::MemberLeft {
                    server_id: sid.clone(), peer_id: peer_id.clone(),
                }).await;
            }
            CrdtPayload::ServerDeleted { .. } => {
                // Owner tombstoned the server. The shell is retained to serve our
                // offline peers; the UI drops the server. MLS group teardown is the
                // plaintext path's job, since this handler has no mls handle.
                let _ = event_tx.send(NetworkEvent::ServerDeleted {
                    server_id: sid.clone(),
                }).await;
            }
            CrdtPayload::RoleChanged { peer_id, role, .. } => {
                let _ = event_tx.send(NetworkEvent::RoleChanged {
                    server_id: sid.clone(), peer_id: peer_id.clone(), new_role: role.as_str().to_string(),
                }).await;
            }
            CrdtPayload::ChannelPublicChanged { channel_id, is_public } => {
                let _ = event_tx.send(NetworkEvent::ServerUpdated {
                    server_id: sid.clone(),
                }).await;
                // Text only (#44) — announcing a voice channel put a ghost
                // entry in browsers that the next list refresh dropped.
                if let Some(ch) = state.channels.get(channel_id)
                    .filter(|c| c.channel_type == crate::crdt::server_state::ChannelType::Text)
                {
                    let notify = HavenMessage::PublicChannelConfigChanged {
                        server_id: sid.clone(),
                        channel_id: channel_id.clone(),
                        is_public: *is_public,
                        channel_name: ch.name.clone(),
                        category: ch.category.clone(),
                    };
                    if let Ok(data) = serde_json::to_vec(&notify) {
                        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom {
                            room_code: sid.clone(),
                            data,
                        });
                    }
                    let _ = event_tx.send(NetworkEvent::PublicChannelConfigChanged {
                        server_id: sid.clone(),
                        channel_id: channel_id.clone(),
                        is_public: *is_public,
                        channel_name: ch.name.clone(),
                        category: ch.category.clone(),
                    }).await;
                }
            }
            CrdtPayload::ServerSettingChanged { .. }
            | CrdtPayload::ServerRenamed { .. }
            | CrdtPayload::RolePermissionsChanged { .. }
            | CrdtPayload::MemberBanned { .. }
            | CrdtPayload::MemberUnbanned { .. }
            | CrdtPayload::MemberMuted { .. }
            | CrdtPayload::MemberUnmuted { .. }
            | CrdtPayload::ChannelVisibilityChanged { .. }
            | CrdtPayload::ChannelPostingChanged { .. }
            | CrdtPayload::ChannelSlowModeChanged { .. }
            | CrdtPayload::ChannelMediaOnlyChanged { .. }
            | CrdtPayload::ChannelVisibilityLabelsChanged { .. }
            | CrdtPayload::ChannelPostingLabelsChanged { .. }
            | CrdtPayload::ChannelGrantSet { .. }
            | CrdtPayload::ChannelGrantRevoked { .. }
            | CrdtPayload::LabelCreated { .. }
            | CrdtPayload::LabelDeleted { .. }
            | CrdtPayload::LabelUpdated { .. }
            | CrdtPayload::LabelAssigned { .. }
            | CrdtPayload::LabelUnassigned { .. }
            | CrdtPayload::EmojiAdded { .. }
            | CrdtPayload::EmojiRemoved { .. }
            | CrdtPayload::StickerAdded { .. }
            | CrdtPayload::StickerRemoved { .. } => {
                let _ = event_tx.send(NetworkEvent::ServerUpdated {
                    server_id: sid.clone(),
                }).await;
            }
            _ => {
                let _ = event_tx.send(NetworkEvent::SyncCompleted {
                    server_id: sid.clone(), ops_applied: 1,
                }).await;
            }
        }
    }
}

/// Handle `MessageEnvelope::ServerDelete` (MLS path) — owner-only.
pub(crate) async fn handle_envelope_server_delete(
    server_states: &mut HashMap<String, ServerState>,
    mls: &mut Option<MlsManager>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sender_peer_id: &str,
    sid: String,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) {
    let sender_role = server_states.get(&sid)
        .map(|s| s.get_role(sender_peer_id))
        .unwrap_or(crate::crdt::operations::MemberRole::Member);
    if sender_role != crate::crdt::operations::MemberRole::Owner {
        hollow_log!("[HOLLOW-SECURITY] REJECTED MLS ServerDelete from {sender_peer_id} — not owner");
        return;
    }
    // Legacy one-shot MLS path (a pre-tombstone peer may still send this). Convert to
    // a TOMBSTONE: synthesize + apply the owner's ServerDeleted op, persist, keep the
    // shell to relay onward. (New senders route deletion through the CRDT op instead.)
    if let Some(state) = server_states.get_mut(&sid) {
        if !state.is_deleted() {
            let now_ms = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis() as i64;
            let op = state.create_op(CrdtPayload::ServerDeleted { deleted_at: now_ms });
            let _ = state.apply_op(&op);
            crdt_store.insert_op(op.clone());
            crdt_store.save_state_snapshot(sid.clone(), state);
            if let Some(mls_mgr_ref) = mls {
                mls_mgr_ref.remove_group(&sid);
                persist_mls_state(mls_mgr_ref, crypto_store);
            }
            let _ = event_tx.send(NetworkEvent::ServerDeleted {
                server_id: sid,
            }).await;
        }
    }
}

/// Handle `MessageEnvelope::MemberKick` (MLS path) — kicker must outrank kickee.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_member_kick(
    server_states: &mut HashMap<String, ServerState>,
    mls: &mut Option<MlsManager>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    local_peer: &str,
    sender_peer_id: &str,
    sid: String,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) {
    let can_kick = if let Some(state) = server_states.get(&sid) {
        let sender_role = state.get_role(sender_peer_id);
        let our_role = state.get_role(local_peer);
        // Override-aware — must match the kicker's own has_permission gate.
        let sender_perms = state.get_permissions(sender_peer_id);
        (sender_perms & crate::crdt::operations::Permission::KICK_MEMBERS) != 0
            && sender_role.outranks(&our_role)
    } else { false };
    if !can_kick {
        hollow_log!("[HOLLOW-SECURITY] REJECTED MLS MemberKick from {sender_peer_id} — insufficient permissions");
        return;
    }
    if server_states.remove(&sid).is_some() {
        crdt_store.delete_server(sid.clone());
        if let Some(mls_mgr_ref) = mls {
            mls_mgr_ref.remove_group(&sid);
            persist_mls_state(mls_mgr_ref, crypto_store);
        }
        let _ = event_tx.send(NetworkEvent::ServerDeleted {
            server_id: sid,
        }).await;
    }
}

/// Handle `MessageEnvelope::SyncReq` (MLS path).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_sync_req(
    server_states: &HashMap<String, ServerState>,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    mls_mgr: &mut MlsManager,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    sender_peer_id: String,
    sid: String,
    state_vector_json: String,
    _crdt_store: &CrdtStore,
) {
    hollow_log!("[HOLLOW-CRDT] MLS SyncReq from {sender_peer_id} for {sid}, our op_log has {} ops", server_states.get(&sid).map(|s| s.op_log.len()).unwrap_or(0));
    if let Some(state) = server_states.get(&sid) {
        if let Ok(their_vector) = serde_json::from_str::<crate::crdt::sync::StateVector>(&state_vector_json) {
            let delta = crate::crdt::sync::compute_delta(&state.op_log, &their_vector);
            hollow_log!("[HOLLOW-CRDT] Delta for {sid}: {} ops to send (their vector has {} entries)", delta.len(), their_vector.entries.len());
            if !delta.is_empty() {
                let ops_json = serde_json::to_string(&delta).unwrap_or_default();
                let resp = MessageEnvelope::SyncResp {
                    sid: sid.clone(), ops_json, target: None,
                };
                let resp_json = serde_json::to_string(&resp).unwrap_or_default();
                send_encrypted_message(
                    olm, crypto_store,
                    &sender_peer_id, &resp_json, event_tx,
                    ws_cmd_tx, ws_room_peers,
                ).await;
            }
        }
    }
}

/// Handle `MessageEnvelope::SyncResp` (MLS path).
pub(crate) async fn handle_envelope_sync_resp(
    server_states: &mut ServerStates,
    _bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &EventTx,
    sid: String,
    ops_json: String,
    crdt_store: &CrdtStore,
) {
    let Some(state) = server_states.get_mut(&sid) else { return };
    // Tolerant parse: an op variant from a NEWER client skips just that
    // op, never the whole batch.
    let incoming_ops = crate::crdt::operations::parse_ops_tolerant(&ops_json);
    if incoming_ops.is_empty() { return; }
    // SECURITY: every op passes `admit_remote_op` inside `merge_ops`: the author's
    // signature, the clock bound, then the permission matrix against OUR role map,
    // never the relayer's word. That covers the destructive `ServerDeleted`
    // tombstone along with every other payload.
    //
    // Persist ADMITTED ops as they merge: op_log is not serialized in the state
    // JSON, so ops merged in RAM are lost on restart without this.
    let Ok(report) = crate::crdt::sync::merge_ops_with(state, &incoming_ops, |op| {
        if op.server_id == sid {
            crdt_store.insert_op(op.clone());
        }
    }) else { return };
    if report.rejected > 0 {
        hollow_log!("[HOLLOW-SECURITY] Dropped {} unadmitted op(s) from an MLS SyncResp for {sid}", report.rejected);
    }
    let applied = report.applied;
    if applied == 0 { return; }
    crdt_store.save_state_snapshot(sid.clone(), state);
    // Reconcile a deletion that happened while offline (UI hides the
    // tombstoned server; the shell is retained to relay onward).
    if state.is_deleted() {
        let _ = event_tx.send(NetworkEvent::ServerDeleted {
            server_id: sid.clone(),
        }).await;
    } else {
        let _ = event_tx.send(NetworkEvent::SyncCompleted {
            server_id: sid.clone(),
            ops_applied: applied as u32,
        }).await;
    }
}

/// Handle `MessageEnvelope::ChannelSyncReq` (MLS path).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_channel_sync_req(
    server_states: &HashMap<String, ServerState>,
    olm: &mut OlmManager,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    sender_peer_id: &str,
    sid: String,
    cid: String,
    since_timestamp: i64,
    sender_timestamps: HashMap<String, i64>,
    crypto_store: &CryptoStore,
    _crdt_store: &CrdtStore,
    db_path: &str,
    db_passphrase: &str,
) {
    // Visibility gate, identical to the plaintext responder in swarm.rs: this is the
    // MLS/Olm twin of the same request and shares `build_channel_sync_batch`, so
    // gating one leg and not the other leaves the hole open on the leg groups use.
    let visible = match server_states.get(&sid) {
        Some(state) => super::crypto_handler::channel_readable_by(state, sender_peer_id, &cid),
        None => return,
    };
    if !visible {
        hollow_log!("[HOLLOW-SECURITY] REJECTED ChannelSyncRequest from {sender_peer_id} for {cid}: not visible to that member");
        return;
    }
    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else { return };
    let Ok((batch, count)) = build_channel_sync_batch(&store, &sid, &cid, since_timestamp, &sender_timestamps) else { return };
    if count == 0 { return; }
    let batch_json = serde_json::to_string(&batch).unwrap_or_default();
    send_encrypted_message(
        olm, crypto_store, sender_peer_id, &batch_json, event_tx,
        ws_cmd_tx, ws_room_peers,
    ).await;
}

/// Handle `MessageEnvelope::ChannelProbe` (MLS path).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_channel_probe(
    server_states: &HashMap<String, ServerState>,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    sender_peer_id: String,
    sid: String,
    cid: String,
    _crdt_store: &CrdtStore,
    db_path: &str,
    db_passphrase: &str,
) {
    // Visibility gate, identical to the plaintext probe responder in swarm.rs.
    let visible = match server_states.get(&sid) {
        Some(state) => super::crypto_handler::channel_readable_by(state, &sender_peer_id, &cid),
        None => return,
    };
    if !visible {
        hollow_log!("[HOLLOW-SECURITY] REJECTED ChannelSyncProbe from {sender_peer_id} for {cid}: not visible to that member");
        return;
    }
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let our_latest = store.get_latest_channel_timestamp(&sid, &cid)
            .unwrap_or(None).unwrap_or(0);
        let our_count = store.count_channel_messages(&sid, &cid);
        let resp = MessageEnvelope::ChannelProbeResp {
            sid: sid.clone(), cid,
            their_latest: our_latest,
            msg_count: our_count,
            target: None,
        };
        let resp_json = serde_json::to_string(&resp).unwrap_or_default();
        send_encrypted_message(
            olm, crypto_store,
            &sender_peer_id, &resp_json, event_tx,
            ws_cmd_tx, ws_room_peers,
        ).await;
    }
}

/// Handle `MessageEnvelope::ChannelProbeResp` (MLS path).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_channel_probe_resp(
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    channel_sync_sent: &mut HashMap<String, std::time::Instant>,
    sender_peer_id: String,
    sid: String,
    cid: String,
    their_latest: i64,
    _msg_count: u32,
    _crdt_store: &CrdtStore,
    db_path: &str,
    db_passphrase: &str,
) {
    let dedup_key = format!("{sid}:{cid}");
    if channel_sync_sent.get(&dedup_key).is_some_and(|t| t.elapsed() < Duration::from_secs(5)) {
        return;
    }
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let our_latest = store.get_latest_channel_timestamp(&sid, &cid)
            .unwrap_or(None).unwrap_or(0);
        let _our_count = store.count_channel_messages(&sid, &cid);
        if their_latest > our_latest {
            channel_sync_sent.insert(dedup_key, std::time::Instant::now());
            let per_sender = store.get_per_sender_timestamps(&sid, &cid)
                .unwrap_or_default();
            send_message_to_peer(
                ws_cmd_tx, ws_room_peers,
                &sender_peer_id, HavenMessage::ChannelSyncRequest {
                    server_id: sid.clone(),
                    channel_id: cid.clone(),
                    since_timestamp: our_latest,
                    sender_timestamps: per_sender,
                },
            );
        }
    }
}

/// Handle `MessageEnvelope::ChannelSyncBatch` (MLS path).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_channel_sync_batch(
    olm: &mut OlmManager,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    local_peer: &str,
    sender_peer_id: &str,
    sid: String,
    cid: String,
    messages: Vec<SyncMessageItem>,
    _total: u32,
    has_more: Option<bool>,
    crypto_store: &CryptoStore,
    _crdt_store: &CrdtStore,
    db_path: &str,
    db_passphrase: &str,
) {
    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else { return };
    // One transaction for the whole batch (up to 200 items) — the per-item
    // auto-commit made this handler fsync hundreds of times per sync page.
    // Same pattern as its plaintext twin in swarm.rs (ChannelSyncBatch).
    let _ = store.begin_transaction();
    let mut pk_cache = PkCache::new();
    let mut new_count = 0u32;
    for msg in &messages {
        let sig_check = verify_sync_item_sig(msg, &sid, &cid, &mut pk_cache);
        // SECURITY: only a VERIFYING signature gets stored, and the whole item is
        // dropped (text, edit, file metadata, reactions and the hidden flag all ride
        // it). Unsigned is refused too as of 0.8.5: the item names its own sender,
        // so omitting the signature was an impersonation primitive.
        if !sig_check.is_acceptable() {
            hollow_log!(
                "[HOLLOW-SECURITY] REJECTED synced channel message in {sid}/{cid} claiming sender {} — {} (mid={:?}, ts={})",
                msg.s, sig_check.reject_reason(), msg.mid, msg.ts
            );
            continue;
        }
        let sig_verified = sig_check == BackfillSig::Valid;
        // Multi-device: a message authored by ANY of our own devices is ours.
        let is_mine = super::resolver::same_identity(&msg.s, local_peer);
        // The helpers stay synchronous and hand back the events to emit:
        // holding a `&MessageStore` across an await would un-Send the future
        // (rusqlite's Connection is !Sync).
        let (inserted, events) = upsert_synced_channel_message(&store, &sid, &cid, msg, is_mine, sig_verified);
        new_count += inserted;
        for ev in events.into_iter().chain(apply_sync_item_extras(&store, &sid, &cid, msg, is_mine, &mut pk_cache)) {
            let _ = event_tx.send(ev).await;
        }
    }
    let _ = store.commit_transaction();
    if has_more == Some(true) {
        let sender_ts = store.get_per_sender_timestamps(&sid, &cid)
            .unwrap_or_default();
        let since = store.get_latest_channel_timestamp(&sid, &cid)
            .unwrap_or(None).unwrap_or(0);
        let req = MessageEnvelope::ChannelSyncReq {
            sid: sid.clone(), cid: cid.clone(),
            since_timestamp: since, sender_timestamps: sender_ts,
            target: None,
        };
        let req_json = serde_json::to_string(&req).unwrap_or_default();
        send_encrypted_message(
            olm, crypto_store, sender_peer_id, &req_json, event_tx,
            ws_cmd_tx, ws_room_peers,
        ).await;
    }
    if has_more != Some(true) {
        let _ = event_tx.send(NetworkEvent::MessageSyncCompleted {
            server_id: sid,
            new_message_count: new_count,
        }).await;
    }
}

/// Verify one synced item's signature (cached pubkey parse) under the backfill
/// rule: `Valid` or the item is dropped. An edited row is verified against its EDIT
/// signature rather than skipped.
fn verify_sync_item_sig(
    msg: &SyncMessageItem,
    sid: &str,
    cid: &str,
    pk_cache: &mut PkCache,
) -> BackfillSig {
    // Recomputed from the shipped card when there is one — that is what makes
    // the preview signature-covered. See `crypto_handler::backfill_lp_digest`.
    let lp_digest = super::crypto_handler::backfill_lp_digest(
        msg.lp.as_deref(), msg.lp_digest.as_deref(),
    );
    let extras = super::crypto_handler::SignedExtras {
        mid: msg.mid.as_deref(),
        reply_to: msg.reply_to.as_deref(),
        file_id: msg.file_id.as_deref(),
        order_us: msg.order_us,
        lp_digest: lp_digest.as_deref(),
    };
    super::crypto_handler::check_backfill_signature(
        &msg.s, "ch", &format!("{sid}:{cid}"),
        msg.ts, msg.edited_at, &extras, &msg.t,
        msg.sig.as_deref(), msg.pk.as_deref(), pk_cache,
    )
}

/// Insert / edit / repair one synced channel message row, and land the link
/// preview riding it. Returns (1 when a NEW row was inserted — feeds the sync
/// counter, else 0; the events to emit).
fn upsert_synced_channel_message(
    store: &crate::storage::MessageStore,
    sid: &str,
    cid: &str,
    msg: &SyncMessageItem,
    is_mine: bool,
    sig_verified: bool,
) -> (u32, Vec<NetworkEvent>) {
    let already_exists = msg.mid.as_ref()
        .map(|mid| store.channel_message_exists(mid))
        .unwrap_or(false);

    let mut inserted = 0u32;
    let mut events = Vec::new();

    if !already_exists {
        if let Ok(1) = store.insert_channel_message(
            sid, cid, &msg.s, &msg.t, is_mine, msg.ts,
            msg.sig.as_deref(), msg.pk.as_deref(), msg.mid.as_deref(),
            msg.reply_to.as_deref(), msg.file_id.as_deref(), msg.order_us,
        ) {
            // If the synced message was already edited, stamp edited_at directly.
            // edit_channel_message would skip it (old_text == new_text).
            if let (Some(edit_ts), Some(mid)) = (msg.edited_at, &msg.mid) {
                let _ = store.set_channel_message_edited_at(mid, edit_ts);
            }
            inserted = 1;
        }
    } else if let (Some(edit_ts), Some(mid)) = (msg.edited_at, &msg.mid) {
        if store.edit_channel_message(
            mid, &msg.t, edit_ts,
            msg.sig.as_deref(),
            msg.pk.as_deref(),
        ).unwrap_or(false) {
            events.push(NetworkEvent::ChannelMessageEdited {
                server_id: sid.to_string(),
                channel_id: cid.to_string(),
                message_id: mid.clone(),
                new_text: msg.t.clone(),
                edited_at: edit_ts,
                signature: msg.sig.clone(),
                public_key: msg.pk.clone(),
            });
        }
    } else if sig_verified {
        repair_wedged_sender(store, msg, is_mine);
    }

    // The card the item's signature covers. Deliberately runs on EVERY branch: a
    // fresh insert, a row that reached us card-less by another path, and an edited
    // row alike should end up holding it. `sig_verified` because a card is content.
    if sig_verified
        && let (Some(lp), Some(mid)) = (msg.lp.as_deref(), &msg.mid)
        && super::message_ops::apply_synced_link_preview(
            store, true, mid, &msg.t, lp, msg.sig.as_deref(), msg.pk.as_deref(),
        )
    {
        events.push(NetworkEvent::ChannelLinkPreviewUpdated {
            server_id: sid.to_string(),
            channel_id: cid.to_string(),
            message_id: mid.clone(),
            preview: Some(lp.clone()),
        });
    }

    (inserted, events)
}

/// Multi-device self-heal: the row already exists but may have been stored under a
/// sender DEVICE id with signature material that no longer verifies here. THIS
/// synced copy's signature verified, proving sender and text, so a row attributed
/// to a different sender is repaired to the verified one. INSERT OR IGNORE blocked
/// re-inserting the good copy, so this UPDATE is the only path to converge, and it
/// is safe because the verify also binds the PeerId to the pubkey.
///
/// Not announced with a fake edit event, which would mark the row "(edited)"; the
/// corrected sender renders on the next channel open.
fn repair_wedged_sender(
    store: &crate::storage::MessageStore,
    msg: &SyncMessageItem,
    is_mine: bool,
) {
    let Some(mid) = &msg.mid else { return };
    let stored_sender = store.get_channel_message_sender(mid);
    if stored_sender.as_deref() != Some(msg.s.as_str()) {
        if let Ok(true) = store.repair_channel_message_sender(
            mid, &msg.s, is_mine,
            msg.sig.as_deref(), msg.pk.as_deref(),
        ) {
            hollow_log!(
                "[HOLLOW-SYNC] Repaired channel msg {mid} sender {stored_sender:?} → {} (verified)", msg.s
            );
        }
    }
}

/// Hidden-flag, file metadata, and reactions riding one synced channel item.
/// Returns the events to emit (kept synchronous — see the caller's !Sync note).
fn apply_sync_item_extras(
    store: &crate::storage::MessageStore,
    sid: &str,
    cid: &str,
    msg: &SyncMessageItem,
    is_mine: bool,
    pk_cache: &mut PkCache,
) -> Vec<NetworkEvent> {
    let mut events = Vec::new();
    // Hidden flag: honored ONLY with the author's own deletion proof
    // (REJECT-ABSENT, 0.8.4) — see `message_ops::apply_verified_channel_deletion`.
    if let (Some(hidden_ts), Some(mid)) = (msg.hidden_at, &msg.mid) {
        if super::message_ops::apply_verified_channel_deletion(
            store, sid, cid, mid, hidden_ts,
            msg.hidden_sig.as_deref(), msg.hidden_pk.as_deref(), pk_cache,
        ) {
            events.push(NetworkEvent::ChannelMessageDeleted {
                server_id: sid.to_string(),
                channel_id: cid.to_string(),
                message_id: mid.clone(),
                deleted_at: hidden_ts,
            });
        }
    }
    // Owner guard (0.8.5): the item's v2 signature binds `file_id`, not this
    // file_meta blob — see `file_handler::file_meta_write_allowed`.
    if let Some(ref fm) = msg.file_meta
        .as_ref()
        .filter(|fm| super::file_handler::file_meta_write_allowed(store, &fm.fid, &fm.sender))
    {
        let ctx_id = format!("{sid}:{cid}");
        let thumb = super::file_handler::accept_header_thumb(fm.thumb.clone(), fm.img, &fm.mime);
        let _ = store.insert_file_metadata(
            &fm.fid, &fm.name, &fm.ext, &fm.mime,
            fm.size, 0, fm.img, fm.w, fm.h,
            fm.mid.as_deref(), "channel", &ctx_id,
            &fm.sender, is_mine, fm.ts,
            fm.vthumb.as_ref(), thumb.as_deref(),
        );
        events.push(NetworkEvent::FileHeaderReceived {
            file_id: fm.fid.clone(), file_name: fm.name.clone(),
            size_bytes: fm.size, is_image: fm.img,
            width: fm.w, height: fm.h,
            message_id: fm.mid.clone().unwrap_or_default(),
            sender_id: fm.sender.clone(),
            server_id: sid.to_string(), channel_id: cid.to_string(),
            video_thumb: fm.vthumb.clone(),
            share_ref: None,
            thumb_b64: thumb,
        });
    }
    if let Some(mid) = &msg.mid {
        for r in &msg.reactions {
            // Each reaction names its own reactor, so it needs its own signature
            // check: the item-level backfill verdict covers only the message.
            if !super::message_ops::sync_reaction_accepted(mid, r) {
                continue;
            }
            let _ = store.add_reaction(
                mid, &r.e, &r.p, r.ts,
                r.sig.as_deref(), r.pk.as_deref(),
            );
        }
    }
    events
}
