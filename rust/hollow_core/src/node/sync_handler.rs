use std::collections::HashMap;
use std::time::Duration;

use base64::Engine;
use tokio::sync::mpsc;

use crate::crdt::operations::{CrdtPayload, Permission};
use crate::crdt::server_state::ServerState;
use crate::crypto::{CryptoStore, MlsManager, OlmManager};
use super::crdt_store::CrdtStore;
use super::crypto_handler::{
    send_mls_broadcast,
    persist_mls_state, send_encrypted_message, online_devices_for,
    BackfillSig, PkCache,
};
use super::types::*;

/// Multi-device: fan pre-serialized bytes to EVERY online device of EVERY server
/// member except our own identity. Members are master-keyed and a master has no
/// socket, so a direct `send_message_to_peer(master)` is dropped: every
/// member-broadcast loop must go through this.
fn carry_to_members(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    state: &ServerState,
    local_peer_str: &str,
    msg: &HavenMessage,
) {
    let Some(json) = super::olm_lane::carried_json(msg) else { return };
    super::olm_lane::carry_to_identities(
        ws_cmd_tx, ws_room_peers, state.members.keys(), local_peer_str, &json, super::olm_lane::NoSession::Queue,
    );
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

/// Carry a `CrdtOpBroadcast` to every member device inside Olm: the path that does
/// not depend on anyone's MLS epoch.
///
/// Tier 2 (`reports/shipped/relay-and-sync/LARGE_SERVER_SCALING_2026.md`): when the server's gossip
/// overlay has live data channels the op floods over the P2P mesh instead, so the
/// sender stops paying O(members x devices) relay uploads. Falls back to the relay
/// fan-out whenever the mesh cannot carry it.
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
    carry_to_members(
        ws_cmd_tx, ws_room_peers, state, local_peer_str,
        &HavenMessage::CrdtOpBroadcast { server_id: server_id.to_string(), op_json: op_json.to_string() },
    );
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

/// Author one CRDT op: create, judge by the SAME rule every receiver runs
/// (`op_allowed`), apply locally, persist (op log + snapshot). `None` = our own
/// rules refuse it, and nothing was applied or stored.
fn author_op(
    state: &mut ServerState,
    crdt_store: &CrdtStore,
    server_id: &str,
    payload: CrdtPayload,
) -> Option<crate::crdt::operations::CrdtOp> {
    let op = state.author_checked(payload)?;
    crdt_store.insert_op(op.clone());
    crdt_store.save_state_snapshot(server_id.to_string(), state);
    Some(op)
}

/// Broadcast an authored op MLS-first, then ALWAYS also as the Olm-carried
/// `CrdtOpBroadcast` twin (idempotent: op_log dedups and receivers re-validate). A
/// receiver at a skewed epoch drops the MLS copy silently with no recovery.
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
            hollow_log!("[HOLLOW-MLS] CrdtOp broadcast failed, the Olm twin still goes: {e}");
        }
    }
    broadcast_crdt_op_to_members(
        ws_cmd_tx, ws_room_peers, gossip_overlays, event_tx, state, local_peer_str, server_id, &op_json,
    );
}

/// Carry an op with no MLS copy to all members AND to our OWN online sibling
/// devices (the master-keyed member broadcast skips our identity, so without the
/// fan our other devices only converge on restart / next sync).
#[allow(clippy::too_many_arguments)]
fn broadcast_op_with_fan(
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
    super::olm_lane::carry_to_own_siblings(
        ws_cmd_tx, ws_room_peers, local_peer_str, local_device_id,
        &HavenMessage::CrdtOpBroadcast { server_id: server_id.to_string(), op_json },
        super::olm_lane::NoSession::Queue,
    );
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
    /// `state.setting_change_allowed(local, key, value)`, the ingest rule.
    Setting(&'a str, &'a str),
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
        OpGate::Setting(key, value) => state.setting_change_allowed(local_peer, key, value),
        OpGate::Always => true,
    }
}

/// How [`author_broadcast_op`] pushes the authored op out, carrying exactly
/// the state that route needs.
enum OpBroadcast<'a> {
    /// MLS broadcast when the server group exists, plus the Olm twin.
    MlsFirst { mls: &'a mut Option<MlsManager>, crypto_store: &'a CryptoStore },
    /// Olm only (no MLS copy) + own-sibling fan.
    WithFan { local_device_id: &'a str },
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
    let Some(op) = author_op(state, crdt_store, server_id, payload) else {
        return match denied_msg {
            Some(msg) => deny(event_tx, msg).await,
            None => true,
        };
    };
    let _ = event_tx.send(event).await;
    match broadcast {
        OpBroadcast::MlsFirst { mls, crypto_store } => broadcast_op_mls_first(
            mls, ws_cmd_tx, ws_room_peers, gossip_overlays, event_tx, state, local_peer_str, server_id, &op, crypto_store,
        ),
        OpBroadcast::WithFan { local_device_id } => broadcast_op_with_fan(
            ws_cmd_tx, ws_room_peers, gossip_overlays, event_tx, state, local_peer_str, local_device_id, server_id, &op,
        ),
    }
    false
}

// ── Owner checkpoints (design E) ─────────────────────────────────────

/// Author every checkpoint we owe as an owner: once per existing server to move it
/// onto the fold, and a compaction one when an anchored log grows long. Broadcast
/// like any op; members rebase on it and drop the rows it overwrote.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn author_due_checkpoints(
    server_states: &mut ServerStates,
    mls: &mut Option<MlsManager>,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    event_tx: &EventTx,
    local_peer_str: &str,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) {
    let now = crate::crdt::hlc::wall_clock_ms();
    let due: Vec<String> = server_states
        .iter()
        .filter(|(_, s)| s.checkpoint_due(local_peer_str, now))
        .map(|(id, _)| id.clone())
        .collect();
    for server_id in due {
        let legacy = server_states.get(&server_id)
            .is_some_and(|s| s.anchor() == crate::crdt::server_state::Anchor::Legacy);
        let past_authors: Vec<String> = if legacy {
            let mut authors: Vec<String> = crdt_store.channel_authors(server_id.clone()).await
                .iter()
                .map(|a| super::resolver::resolve(a))
                .collect();
            authors.sort();
            authors.dedup();
            authors
        } else {
            Vec::new()
        };
        let Some(state) = server_states.get_mut(&server_id) else { continue };
        let covers = state.horizon();
        let Some(json) = state.checkpoint_json(local_peer_str, &past_authors, now) else { continue };
        let Some(op) = state.author_checked(CrdtPayload::ServerCheckpoint { state: json, covers }) else { continue };
        hollow_log!("[HOLLOW-CRDT] Checkpointed {server_id} ({} ops kept)", state.op_log.len());
        crdt_store.persist_admitted(vec![op.clone()], state.checkpoint_hlc.clone());
        crdt_store.save_state_snapshot(server_id.clone(), state);
        broadcast_op_mls_first(
            mls, ws_cmd_tx, ws_room_peers, gossip_overlays, event_tx, state, local_peer_str, &server_id, &op, crypto_store,
        );
    }
}

/// Set a join key on every live server we own that has none: one founded before
/// 0.12, or one whose key never reached this device. Without it no invite can be
/// made and no one can ask to join.
#[allow(clippy::too_many_arguments)]
pub(crate) fn author_missing_join_keys(
    server_states: &mut ServerStates,
    mls: &mut Option<MlsManager>,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    event_tx: &EventTx,
    local_peer_str: &str,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) {
    let missing: Vec<String> = server_states
        .iter()
        .filter(|(_, s)| !s.is_deleted() && s.join_secret().is_none() && s.current_owner().as_deref() == Some(local_peer_str))
        .map(|(id, _)| id.clone())
        .collect();
    for server_id in missing {
        let Some(state) = server_states.get_mut(&server_id) else { continue };
        let Some(secret) = super::sealed_box::new_secret() else { continue };
        let secret = crate::crdt::operations::JoinSecret(hex::encode(secret.as_slice()));
        let Some(op) = author_op(state, crdt_store, &server_id, CrdtPayload::JoinKeySet { secret }) else {
            continue;
        };
        hollow_log!("[HOLLOW-CRDT] Set the join key of {server_id}");
        broadcast_op_mls_first(
            mls, ws_cmd_tx, ws_room_peers, gossip_overlays, event_tx, state, local_peer_str, &server_id, &op, crypto_store,
        );
    }
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
    let msg = HavenMessage::CrdtOpBroadcast { server_id: server_id.to_string(), op_json };
    let Some(json) = super::olm_lane::carried_json(&msg) else { return };
    super::olm_lane::carry_to_identities(
        ws_cmd_tx, ws_room_peers, targets.iter().filter(|m| skip != Some(m.as_str())),
        local_peer_str, &json, super::olm_lane::NoSession::Queue,
    );
    super::olm_lane::carry_to_own_siblings(
        ws_cmd_tx, ws_room_peers, local_peer_str, local_device_id, &msg, super::olm_lane::NoSession::Queue,
    );
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
            file_meta_map.get(fid.as_str()).map(|f| SyncFileMetaItem::from_stored(f, f.sender_id.clone()))
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
            album: m.album_id.clone(),
            lp: m.link_preview.clone().map(Box::new),
            reactions,
        });
    }
    SyncPage { items, truncated }
}

/// Build one page (at most 200 messages) of a channel-sync response: per-sender
/// watermarks when the requester sent them, a legacy single timestamp otherwise,
/// then pack and stamp `total`/`has_more`. Returns the envelope and item count.
/// The ChannelSyncRequest for everything we may be missing in one channel:
/// per-sender watermarks plus the digest of what we hold behind them. A
/// pagination follow-up passes `with_gap = false`, since the first page already
/// carried the rows behind the watermarks.
pub(crate) fn channel_sync_request(
    store: &crate::storage::MessageStore,
    server_id: &str,
    channel_id: &str,
    with_gap: bool,
) -> HavenMessage {
    HavenMessage::ChannelSyncRequest {
        server_id: server_id.to_string(),
        channel_id: channel_id.to_string(),
        since_timestamp: store
            .get_latest_channel_timestamp(server_id, channel_id)
            .unwrap_or(None)
            .unwrap_or(0),
        sender_timestamps: store.get_per_sender_timestamps(server_id, channel_id).unwrap_or_default(),
        gap: if with_gap { store.channel_gap_anchor(server_id, channel_id) } else { None },
    }
}

pub(crate) fn build_channel_sync_batch(
    store: &crate::storage::MessageStore,
    sid: &str,
    cid: &str,
    since_timestamp: i64,
    sender_timestamps: &HashMap<String, i64>,
    // What the requester holds behind its watermarks. The rows it is missing
    // there join this page and are never paginated: whatever does not fit is
    // still missing at the next sync and is served then.
    gap: Option<&GapDigest>,
) -> Result<(MessageEnvelope, usize), String> {
    let mut messages = if !sender_timestamps.is_empty() {
        store.get_channel_messages_since_per_sender(sid, cid, sender_timestamps, 200)
    } else {
        store.get_channel_messages_since(sid, cid, since_timestamp, 200)
    }?;
    let tail_len = messages.len();
    if let Some(gap) = gap {
        let paged: std::collections::HashSet<String> =
            messages.iter().filter_map(|m| m.message_id.clone()).collect();
        let missed = store.get_channel_gap_messages(sid, cid, gap, 200).unwrap_or_default();
        messages.extend(
            missed
                .into_iter()
                .filter(|m| m.message_id.as_ref().is_some_and(|id| !paged.contains(id))),
        );
        messages.sort_by_key(|m| m.timestamp);
    }
    let gap_len = (messages.len() - tail_len) as u32;
    let SyncPage { items, truncated } = channel_sync_items(store, &messages);
    let tail_total = if !sender_timestamps.is_empty() {
        store.count_channel_messages_since_per_sender(sid, cid, sender_timestamps)
            .unwrap_or(tail_len as u32)
    } else {
        store.count_channel_messages_since(sid, cid, since_timestamp)
            .unwrap_or(tail_len as u32)
    };
    let total = tail_total + gap_len;
    // `truncated` = the preview budget ended the page before the query did, so
    // there is definitely more to serve even though the page is short.
    let has_more = if truncated || (tail_len >= 200 && tail_total > 200) {
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
    // A self-certifying id: our master key and the founding op's nonce hash to it,
    // so any joiner can prove who owns the server without trusting who answers.
    let pk_b64 = base64::engine::general_purpose::STANDARD.encode(bundle_keypair.public_key_protobuf());
    let (state, founding) = ServerState::found(
        name.clone(), local_peer_str.to_string(), bundle_keypair.clone(), pk_b64,
    );
    let server_id = state.server_id.clone();
    hollow_log!("[HOLLOW-CRDT] Creating server '{name}' id={server_id}");
    crdt_store.insert_op(founding);
    crdt_store.save_state_snapshot(server_id.clone(), &state);

    server_states.insert(server_id.clone(), state);

    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
        room_code: server_id.clone(),
    });

    // Register the room's catch-up rings straight away: the JOIN ring is registered
    // by MEMBERS on behalf of people who are not members yet, so until it exists a
    // stranger's parked request is dropped rather than buffered. Doing it here makes
    // a server joinable-while-empty from the instant it is created.
    if let Some(state) = server_states.get(&server_id) {
        register_relay_catchup(ws_cmd_tx, state, &server_id, bundle_keypair);
    }

    // Auto-pledge default storage (512 MB) for the owner
    if let Some(state) = server_states.get_mut(&server_id) {
        let default_pledge = 512u64 * 1024 * 1024;
        let _ = author_op(state, crdt_store, &server_id, CrdtPayload::StoragePledgeChanged {
            peer_id: local_peer_str.to_string(),
            pledge_bytes: default_pledge,
        });
        // Before any invite can be made: every invite carries the join key.
        if let Some(secret) = super::sealed_box::new_secret() {
            let secret = crate::crdt::operations::JoinSecret(hex::encode(secret.as_slice()));
            let _ = author_op(state, crdt_store, &server_id, CrdtPayload::JoinKeySet { secret });
        }
    }
    let join_key = server_states.get(&server_id).and_then(|s| s.join_public_text());

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

    // Our online siblings are not in the brand-new room and have no other way to
    // learn it exists; offline ones hear it on reconnect, via re-announce.
    let sent = super::olm_lane::carry_to_own_siblings(
        ws_cmd_tx, ws_room_peers, local_peer_str, local_device_id,
        &HavenMessage::SiblingServerAnnounce { server_id: server_id.clone(), owner: Some(local_peer_str.to_string()), join_key },
        super::olm_lane::NoSession::Queue,
    );
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
    master: &crate::identity::native_identity::NativeKeypair,
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
    let channels: Vec<String> = channels.iter().map(|c| super::ring_auth::topic(state, c)).collect();
    hollow_log!("[HOLLOW-TOPIC] Registering relay catch-up rings for {server_id}: {} channel(s) + the join ring, retention {secs}s", channels.len() - 1);
    // Signed when we hold the lock's change key; unsigned it only keeps the rings
    // the owner, an admin or a mod made from idling out.
    let auth = super::lock_keeper::sign_ring_control(server_id, state, master, secs, false, &channels);
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SetTopicBuffer {
        room_code: server_id.to_string(),
        channels,
        retention_secs: secs,
        clear: false,
        auth,
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
#[allow(clippy::too_many_arguments)]
pub(crate) async fn request_channel_catchups(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    crdt_store: &CrdtStore,
    state: Option<&ServerState>,
    room: &str,
    local_peer: &str,
    master: &crate::identity::native_identity::NativeKeypair,
    relay_catchup_done: &mut std::collections::HashSet<(String, String)>,
    tag: &str,
) {
    // Gather the channel list and DROP the borrow before crossing the await:
    // the watermark lookup is answered on the CrdtStore actor's long-lived
    // connection, never by opening a SQLCipher handle per channel here.
    let owner = state.and_then(|s| s.anchor_owner());
    let fresh_channels: Vec<String> = match state {
        Some(state) if state.relay_catchup_secs() > 0 => {
            register_relay_catchup(ws_cmd_tx, state, room, master);
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
            channel_id: super::ring_auth::ring_topic(room, owner.as_deref(), &cid),
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

        let Some(op) = author_op(state, crdt_store, &server_id, CrdtPayload::ChannelAdded {
            channel_id: channel_id.clone(),
            name: name.clone(),
            category: category.clone(),
            channel_type: channel_type.clone(),
        }) else {
            return deny(event_tx, "Permission denied: cannot manage channels").await;
        };

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
        register_relay_catchup(ws_cmd_tx, state, &server_id, bundle_keypair);
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
    // The same rule every RECEIVER enforces. Without it an unauthorized FFI call
    // applies the op locally, the network rejects it, and our state diverges.
    let denied = if key.starts_with("retention_") {
        "Only the server owner can change how long things are kept"
    } else {
        "Permission denied: changing server settings needs the Manage Server permission"
    };
    if author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        OpGate::Setting(&key, &value),
        Some(denied),
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
                register_relay_catchup(ws_cmd_tx, state, &server_id, bundle_keypair);
            } else {
                let auth = super::lock_keeper::sign_ring_control(&server_id, state, bundle_keypair, 0, true, &[]);
                let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SetTopicBuffer {
                    room_code: server_id.clone(),
                    channels: Vec::new(),
                    retention_secs: 0,
                    clear: true,
                    auth,
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
    // The Olm twin goes out UNCONDITIONALLY, alongside the MLS copy. Sending
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
        let msg = HavenMessage::CrdtOpBroadcast { server_id: server_id.clone(), op_json };
        if let Some(json) = super::olm_lane::carried_json(&msg) {
            super::olm_lane::carry_to_identities(
                ws_cmd_tx, ws_room_peers, member_targets.iter(), local_peer_str, &json,
                super::olm_lane::NoSession::Queue,
            );
        }
        // Siblings get the op directly too: it covers the no-other-member-online case.
        super::olm_lane::carry_to_own_siblings(
            ws_cmd_tx, ws_room_peers, local_peer_str, local_device_id, &msg, super::olm_lane::NoSession::Queue,
        );
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
        owner_pin: pending.owner_pin.clone(),
        join_key: pending.join_key.clone(),
        reply_secret: pending.reply_secret.as_ref().map(|r| r.to_stored()),
    }
}

/// Write the parked copy of a request into the server room's `~join` ring, sealed
/// to the server's join key like every copy.
///
/// Rung 2: the ring copy carries the LEAF as well as the membership, so the member
/// that admits it can add us to the MLS group in the same batch.
pub(crate) fn deposit_parked_join(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    server_id: &str,
    our_device: &str,
    pending: &PendingJoin,
) -> bool {
    let Some(data) = super::join_lane::request_frame(server_id, our_device, pending, true) else {
        hollow_log!("[HOLLOW-CRDT] No verified join lock for {server_id} yet: nothing deposited in the join ring");
        return false;
    };
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoomTopic {
        room_code: server_id.to_string(),
        topic: super::ring_auth::ring_topic(server_id, pending.owner_pin.as_deref(), super::types::JOIN_TOPIC),
        data,
    });
    hollow_log!(
        "[HOLLOW-CRDT] Deposited parked join for {server_id} (nonce {}) into the join ring",
        pending.requested_at
    );
    true
}

/// Publish a member's answer to a join into the room's `~join` ring.
///
/// Two copies: one sealed to our newest door and the invite key tells the OTHER
/// members the join is resolved (with the admitting op), so a member returning later
/// does not re-serve it; a refusal also goes sealed to the joiner, who may not be here.
pub(crate) fn publish_join_resolution(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    answer: &super::join_lane::Answer<'_>,
    admitted: bool,
    reason: &str,
    op_json: Option<String>,
) {
    let resolved = |op_json| HavenMessage::ServerJoinResolved {
        server_id: answer.server_id.to_string(),
        joiner_master: answer.joiner_master.to_string(),
        requested_at: answer.requested_at,
        admitted,
        reason: reason.to_string(),
        op_json,
    };
    let for_members = answer.sealed_to_members(&resolved(op_json));
    let for_joiner = (!admitted).then(|| answer.sealed_to_joiner(&resolved(None))).flatten();
    for data in [for_members, for_joiner].into_iter().flatten() {
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoomTopic {
            room_code: answer.server_id.to_string(),
            topic: answer.join_ring.clone(),
            data,
        });
    }
    hollow_log!("[HOLLOW-CRDT] Published join resolution for {} on {} (admitted {admitted})", answer.joiner_master, answer.server_id);
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

/// The refusal a join gets when it has no join key to seal to: an invite from
/// before the join lane, or a pasted bare server id.
pub(crate) const INVITE_OUTDATED: &str = "invite_outdated";

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
/// A refusal never ends the join: a member removed a moment ago, or one whose client
/// was changed, can send one, so the ask stays open (row, room, ring copy) and a real
/// admission still completes it. The tile shows the reason until the user discards it.
/// A question (NSFW consent, a Twitch proof) goes to the user once; their answer asks
/// again with it, their cancel discards the ask, and meanwhile it stays open but does
/// not park.
pub(crate) async fn handle_join_refused(
    pending_server_joins: &mut HashMap<String, PendingJoin>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    crdt_store: &CrdtStore,
    server_id: String,
    reason: String,
) {
    let Some(pending) = pending_server_joins.get_mut(&server_id) else { return };
    if is_interactive_reason(&reason) {
        // Once per ask: every member that reads it asks the same question.
        if !pending.asked {
            hollow_log!("[HOLLOW-CRDT] Join for {server_id} needs an answer from the user: {reason}");
            pending.asked = true;
            let _ = event_tx.send(NetworkEvent::TwitchJoinRejected { server_id, reason }).await;
        }
        return;
    }
    if pending.refused.as_deref() == Some(reason.as_str()) {
        return;
    }
    hollow_log!("[HOLLOW-CRDT] Join for {server_id} refused: {reason}; the ask stays open for a real admission");
    pending.refused = Some(reason.clone());
    let (state, _) = tile_state(pending);
    crdt_store.upsert_pending_join(pending_join_row(&server_id, pending, state, &reason));
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
        server_id,
        state: "rejected".to_string(),
        reason,
    }).await;
}

/// Refuse a join, by both legs.
///
/// The targeted leg goes to the DETERMINISTIC server room rather than through a
/// presence lookup, so the relay buffers it for an absent joiner and replays it.
///
/// INTERACTIVE reasons are deliberately NOT written into the ring: they are
/// questions, and one parked in a TTL ring re-opens the same dialog for days.
pub(crate) fn send_join_rejection(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    answer: &super::join_lane::Answer<'_>,
    reason: &str,
    catchup_secs: i64,
) {
    answer.reply(ws_cmd_tx, &HavenMessage::ServerJoinRejected {
        server_id: answer.server_id.to_string(),
        reason: reason.to_string(),
        requested_at: answer.requested_at,
    });
    let interactive = is_interactive_reason(reason);
    if answer.requested_at != 0 && !interactive && catchup_secs > 0 {
        publish_join_resolution(ws_cmd_tx, answer, false, reason, None);
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
    owner_pin: Option<String>,
    // The invite's join key: every copy of the request is sealed to it.
    join_key: String,
    crdt_store: &CrdtStore,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    mls: &Option<MlsManager>,
    crypto_store: &CryptoStore,
    // The KeyPackage and reply key a persisted row already holds ("request again").
    // Reused rather than re-minted, so a re-ask does not orphan what the ring copy
    // already names.
    stored_key_package: Option<String>,
    stored_reply_secret: Option<String>,
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
    let device_list = super::roster_book::own_roster(&master_keypair.peer_id(), db_path, db_passphrase);
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
    // A self-certifying id pins its own owner; a pin on one would only be noise.
    let owner_pin = owner_pin
        .filter(|_| !crate::crdt::anchor::is_genesis_id(&server_id))
        .or_else(|| pending_server_joins.get(&server_id).and_then(|p| p.owner_pin.clone()));
    let reply_secret = stored_reply_secret
        .as_deref()
        .and_then(super::join_lane::ReplySecret::from_stored)
        .or_else(|| pending_server_joins.get(&server_id).and_then(|p| p.reply_secret.clone()))
        .or_else(super::join_lane::ReplySecret::new);
    // Who is asking rides inside the sealed request, so no member needs an Olm
    // session with a stranger to learn a name.
    let card = super::profile_card::own_card(master_keypair, db_path, db_passphrase);
    let avatar_b64 = card
        .as_ref()
        .and_then(|c| super::profile_card::own_avatar(&c.master, db_path, db_passphrase))
        .filter(|b| b.len() <= JOIN_AVATAR_MAX_BYTES)
        .map(|b| base64::engine::general_purpose::STANDARD.encode(b))
        .unwrap_or_default();
    let mut pending = PendingJoin {
        twitch_proof_json: twitch_proof_json.clone(),
        nsfw_confirmed,
        requested_at,
        parked: false,
        last_deposited_at: 0,
        device_list,
        key_package,
        owner_pin,
        join_key: Some(join_key),
        reply_secret,
        // A lock read a moment ago for this same join still holds.
        lock: pending_server_joins.get(&server_id).and_then(|p| p.lock.clone()).filter(|l| l.fresh()),
        card,
        avatar_b64,
        ..Default::default()
    };
    // Persist BEFORE anything can go wrong: a crash inside the 15s live window
    // still leaves a row the boot path picks up, and a join that completes
    // deletes it.
    crdt_store.upsert_pending_join(pending_join_row(&server_id, &pending, "pending", ""));

    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
        room_code: server_id.clone(),
    });

    // Every copy is sealed to the door the relay's lock names: with none read yet,
    // the answer to the ask sends them.
    if pending.lock.is_some() {
        if let Some(room_peers) = ws_room_peers.get(&server_id) {
            for peer in room_peers.iter() {
                if super::join_lane::send_request(ws_cmd_tx, &server_id, device_peer_id, &pending, peer) {
                    hollow_log!("[HOLLOW-CRDT] Sent join request to {peer} for {server_id}");
                }
            }
        }
    } else {
        request_join_lock(ws_cmd_tx, &server_id, &mut pending);
    }
    pending_server_joins.insert(server_id.clone(), pending);
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

/// Largest avatar a live join request carries; a bigger one arrives once we are in.
const JOIN_AVATAR_MAX_BYTES: usize = 256 * 1024;

/// Between two asks for the lock of a server we are joining, unless an answer waits.
const JOIN_LOCK_ASK_GAP: Duration = Duration::from_secs(1);
/// Unanswered asks we keep track of.
const MAX_LOCK_ASKS: usize = 32;

/// The row state a pending join's tile shows: a refusal keeps its reason.
pub(crate) fn tile_state(pending: &PendingJoin) -> (&'static str, String) {
    match &pending.refused {
        Some(reason) => ("rejected", reason.clone()),
        None => ("pending", String::new()),
    }
}

/// Ask the relay for the join lock of a server we are joining.
pub(crate) fn request_join_lock(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    server_id: &str,
    pending: &mut PendingJoin,
) {
    if pending.lock_asked_at.is_some_and(|t| t.elapsed() < JOIN_LOCK_ASK_GAP) {
        return;
    }
    ask_join_lock(ws_cmd_tx, server_id, pending);
}

fn ask_join_lock(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    server_id: &str,
    pending: &mut PendingJoin,
) {
    let now = std::time::Instant::now();
    pending.lock_asked_at = Some(now);
    if pending.lock_asks.len() >= MAX_LOCK_ASKS {
        pending.lock_asks.pop_front();
    }
    pending.lock_asks.push_back(now);
    let owner = pending.owner_pin.clone().unwrap_or_default();
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LockGet { locks: vec![(server_id.to_string(), owner)] });
}

/// An answer to our join counts only against a read of the lock asked after it
/// arrived: that read reflects every removal before it, so an answer from the door
/// of someone removed by then is never taken. Returns false when too many wait.
pub(crate) fn hold_join_answer(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    server_id: &str,
    pending: &mut PendingJoin,
    held: HeldAnswer,
) -> bool {
    if pending.held.len() >= MAX_HELD_ANSWERS {
        return false;
    }
    pending.held.push(held);
    ask_join_lock(ws_cmd_tx, server_id, pending);
    true
}

/// The relay's lock for a server we are joining: verified back to the owner the id
/// or the invite names, it is what every copy is sealed to and the oldest door an
/// answer may come from. The first one we read sends the copies that waited for it.
/// Returns the answers that waited for it, to be judged again.
pub(crate) fn handle_join_lock_chain(
    pending_server_joins: &mut HashMap<String, PendingJoin>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    crdt_store: &CrdtStore,
    our_device: &str,
    server_id: &str,
    links: Vec<super::join_lock::LockLink>,
    hidden: bool,
) -> Vec<HeldAnswer> {
    let Some(pending) = pending_server_joins.get_mut(server_id) else { return Vec::new() };
    let asked = pending.lock_asks.pop_front();
    if super::join_lock::verify_chain(server_id, &links, pending.owner_pin.as_deref()).is_none() {
        hollow_log!("[HOLLOW-CRDT] No join lock for {server_id} we can verify yet ({} link(s) on the relay); waiting for a member to put it back", links.len());
        return Vec::new();
    }
    let first = pending.lock.is_none();
    pending.lock = Some(super::join_lock::VerifiedLock { links, checked_at: std::time::Instant::now() });
    if first && !pending.asked {
        // A locked room hides its members from a joiner: ask the whole room.
        if hidden && super::join_lane::send_request_to_room(ws_cmd_tx, server_id, our_device, pending) {
            hollow_log!("[HOLLOW-CRDT] Sent our join request for {server_id} to the whole room");
        }
        for peer in ws_room_peers.get(server_id).into_iter().flatten() {
            if super::join_lane::send_request(ws_cmd_tx, server_id, our_device, pending, peer) {
                hollow_log!("[HOLLOW-CRDT] Sent join request to {peer} for {server_id}");
            }
        }
    }
    if pending.parked && pending.last_deposited_at == 0 && deposit_parked_join(ws_cmd_tx, server_id, our_device, pending) {
        pending.last_deposited_at = super::types::now_ms();
        let (state, reason) = tile_state(pending);
        crdt_store.upsert_pending_join(pending_join_row(server_id, pending, state, &reason));
    }
    let Some(asked) = asked else { return Vec::new() };
    let (ready, waiting) = std::mem::take(&mut pending.held).into_iter().partition(|h| h.arrived_at <= asked);
    pending.held = waiting;
    ready
}

/// How often a join with no lock yet, or with answers waiting on one, asks again.
const JOIN_LOCK_REASK: Duration = Duration::from_secs(15);

/// Joins still missing a lock, or holding answers for one, ask the relay again: a
/// member coming back puts the chain back, and a held answer waits on the reply.
pub(crate) fn reask_join_locks(
    pending_server_joins: &mut HashMap<String, PendingJoin>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
) {
    for (server_id, pending) in pending_server_joins.iter_mut() {
        let waiting = pending.lock.is_none() || !pending.held.is_empty();
        if waiting && pending.lock_asked_at.is_none_or(|t| t.elapsed() >= JOIN_LOCK_REASK) {
            request_join_lock(ws_cmd_tx, server_id, pending);
        }
    }
}

/// An answer to our join came from a door older than the relay's newest: from a
/// member who answered just before the lock moved, or from someone it moved to shut
/// out. Ask again, once per lock, sealed to the newest door under a new nonce, so a
/// member answers from that door (one that already admitted us sends our state).
pub(crate) fn reask_join(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    crdt_store: &CrdtStore,
    server_id: &str,
    our_device: &str,
    pending: &mut PendingJoin,
    hidden: bool,
) {
    let Some(tip) = pending.lock.as_ref().and_then(|l| l.newest()).map(|l| l.n) else { return };
    if pending.asked || pending.reasked_for == Some(tip) {
        return;
    }
    hollow_log!("[HOLLOW-CRDT] Asking again to join {server_id} from join lock {tip}");
    pending.reasked_for = Some(tip);
    pending.requested_at = super::types::now_ms();
    if hidden {
        super::join_lane::send_request_to_room(ws_cmd_tx, server_id, our_device, pending);
    }
    for peer in ws_room_peers.get(server_id).into_iter().flatten() {
        super::join_lane::send_request(ws_cmd_tx, server_id, our_device, pending, peer);
    }
    if pending.parked && deposit_parked_join(ws_cmd_tx, server_id, our_device, pending) {
        pending.last_deposited_at = super::types::now_ms();
    }
    let (state, reason) = tile_state(pending);
    crdt_store.upsert_pending_join(pending_join_row(server_id, pending, state, &reason));
}

/// A device came into the room of a server we are joining: ask it, or first read the
/// lock, which a member coming back may just have put back on the relay.
pub(crate) fn send_pending_request(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    server_id: &str,
    our_device: &str,
    pending: &mut PendingJoin,
    target: &str,
) {
    if pending.asked {
        return;
    }
    if super::join_lane::send_request(ws_cmd_tx, server_id, our_device, pending, target) {
        hollow_log!("[HOLLOW-CRDT] Sent pending join request to {target} for {server_id}");
    } else {
        request_join_lock(ws_cmd_tx, server_id, pending);
    }
}

/// What becomes of a sealed answer to our join.
pub(crate) enum JoinAnswer {
    Open(Box<HavenMessage>),
    /// From a door older than the relay's newest: see `reask_join`.
    Stale,
    Dropped,
}

/// An answer held until a read of the lock asked after it arrived: it counts only
/// from the newest door that read shows. One from an older door is from someone
/// that door no longer admits, or from a member who answered just before the lock
/// moved; it is never read, only a reason to ask again.
pub(crate) fn judge_join_answer(pending: &PendingJoin, server_id: &str, our_device: &str, held: &HeldAnswer) -> JoinAnswer {
    let (Some(reply), Some(tip)) = (pending.reply_secret.as_ref(), pending.lock.as_ref().and_then(|l| l.newest())) else {
        return JoinAnswer::Dropped;
    };
    let open_with = |door: [u8; 32]| {
        super::join_lane::open_for_joiner(reply, &door, server_id, &held.from, our_device, held.n, &held.eph, &held.ct)
    };
    if held.n == tip.n {
        return tip.door_key().and_then(open_with).map_or(JoinAnswer::Dropped, |msg| JoinAnswer::Open(Box::new(msg)));
    }
    let from_its_door = held.n < tip.n && super::sealed_box::key_from_text(&held.door).and_then(open_with).is_some();
    if !from_its_door {
        return JoinAnswer::Dropped;
    }
    hollow_log!("[HOLLOW-SECURITY] Dropped an answer to our join of {server_id} from {} sealed from door {}, the relay's newest is {}", held.from, held.n, tip.n);
    JoinAnswer::Stale
}

/// What a join about to complete leaves behind for `recent_join_answer`.
pub(crate) fn recent_join_of(pending: &PendingJoin) -> Option<RecentJoin> {
    Some(RecentJoin {
        reply: pending.reply_secret.clone()?,
        door: pending.lock.as_ref()?.newest()?.clone(),
        until: std::time::Instant::now() + RECENT_JOIN_WINDOW,
    })
}

/// After an answer to our join was dispatched: when it completed the join, keep
/// taking that join's answers for a while.
pub(crate) fn note_completed_join(
    recent: &mut HashMap<String, RecentJoin>,
    pending_server_joins: &HashMap<String, PendingJoin>,
    server_states: &HashMap<String, ServerState>,
    local_peer_str: &str,
    server_id: &str,
    joining: Option<RecentJoin>,
) {
    let Some(joining) = joining else { return };
    if !pending_server_joins.contains_key(server_id) && server_states.get(server_id).is_some_and(|s| s.is_member(local_peer_str)) {
        recent.insert(server_id.to_string(), joining);
    }
}

/// Write a join lock op and send it to every member and our own other devices.
#[allow(clippy::too_many_arguments)]
pub(crate) fn author_join_lock_op(
    server_states: &mut ServerStates,
    mls: &mut Option<MlsManager>,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    event_tx: &EventTx,
    local_peer_str: &str,
    local_device_id: &str,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
    server_id: &str,
    payload: CrdtPayload,
) {
    let Some(state) = server_states.get_mut(server_id) else { return };
    let Some(op) = author_op(state, crdt_store, server_id, payload) else {
        hollow_log!("[HOLLOW-CRDT] A join lock op for {server_id} did not pass our own rules");
        return;
    };
    broadcast_op_mls_first(mls, ws_cmd_tx, ws_room_peers, gossip_overlays, event_tx, state, local_peer_str, server_id, &op, crypto_store);
    if let Ok(op_json) = serde_json::to_string(&op) {
        super::olm_lane::carry_to_own_siblings(
            ws_cmd_tx, ws_room_peers, local_peer_str, local_device_id,
            &HavenMessage::CrdtOpBroadcast { server_id: server_id.to_string(), op_json },
            super::olm_lane::NoSession::Queue,
        );
    }
}

/// A sync answer to a join that completed a moment ago, from the door we verified:
/// a real admission arriving after a stale one merges into it.
pub(crate) fn recent_join_answer(
    recent: &mut HashMap<String, RecentJoin>,
    server_id: &str,
    our_device: &str,
    held: &HeldAnswer,
) -> Option<HavenMessage> {
    let now = std::time::Instant::now();
    recent.retain(|_, r| r.until > now);
    let join = recent.get(server_id).filter(|r| r.door.n == held.n)?;
    let msg = super::join_lane::open_for_joiner(
        &join.reply, &join.door.door_key()?, server_id, &held.from, our_device, held.n, &held.eph, &held.ct,
    )?;
    matches!(msg, HavenMessage::SyncResponse { .. }).then_some(msg)
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
    our_device: &str,
    server_id: String,
) {
    let Some(pending) = pending_server_joins.get(&server_id) else { return };
    if pending.asked {
        return;
    }
    let Some(room_peers) = ws_room_peers.get(&server_id) else { return };
    hollow_log!(
        "[HOLLOW-CRDT] Join for {server_id} still pending after the coordinator window — re-asking {} peer(s)",
        room_peers.len()
    );
    for peer in room_peers.iter() {
        super::join_lane::send_request(ws_cmd_tx, &server_id, our_device, pending, peer);
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
        let Some(op) = author_op(state, crdt_store, &server_id, CrdtPayload::RoleChanged {
            peer_id: peer_id.clone(),
            role: new_member_role,
            priority: author_role.priority(),
        }) else {
            return deny(event_tx, &format!("Permission denied: cannot change role to {new_role}")).await;
        };

        let _ = event_tx.send(NetworkEvent::RoleChanged {
            server_id: server_id.clone(),
            peer_id: peer_id.clone(),
            new_role: new_role.clone(),
        }).await;

        // Role-change has no MLS copy, and the member broadcast skips our
        // identity, so the helper also fans to our OWN siblings.
        broadcast_op_with_fan(
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
        let Some(op) = author_op(state, crdt_store, &server_id, CrdtPayload::MemberRemoved {
            peer_id: peer_id.clone(),
        }) else {
            return deny(event_tx, "Permission denied: cannot kick this member").await;
        };

        let _ = event_tx.send(NetworkEvent::MemberLeft {
            server_id: server_id.clone(),
            peer_id: peer_id.clone(),
        }).await;

        // Kicked peer is skipped — it gets MemberKickBroadcast instead.
        broadcast_removal_op(
            ws_cmd_tx, ws_room_peers, &targets, Some(&peer_id),
            local_peer_str, local_device_id, &server_id, &op,
        );

        // Tell EVERY online device of the kicked identity.
        if let Some(json) = super::olm_lane::carried_json(&HavenMessage::MemberKickBroadcast { server_id: server_id.clone() }) {
            super::olm_lane::carry_to_identity(ws_cmd_tx, ws_room_peers, &peer_id, &json, super::olm_lane::NoSession::Queue);
        }

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
/// Our roster changed: hand it first to each device in `first` on the relay lane (a
/// removed device has no session left, and an approved one may have none yet), then
/// announce it to every peer we share a room with.
#[allow(clippy::too_many_arguments)]
pub(crate) fn announce_roster_change(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server_states: &HashMap<String, ServerState>,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    device_peer_id: &str,
    is_invisible: bool,
    first: &[String],
    db_path: &str,
    db_passphrase: &str,
) {
    if let Some(roster) = super::roster_book::own_roster(local_peer_str, db_path, db_passphrase) {
        for target in first {
            super::crypto_handler::send_message_to_peer(
                ws_cmd_tx, ws_room_peers, target,
                HavenMessage::RosterNotice { roster: roster.clone() },
            );
        }
    }
    // The relay hears it too, so a device this change removed loses our inbox now.
    super::roster_book::show_relay(ws_cmd_tx, local_peer_str, db_path, db_passphrase);
    let peers: Vec<String> = ws_room_peers.values().flat_map(|p| p.iter().cloned()).collect();
    let mut told: std::collections::HashSet<String> = std::collections::HashSet::new();
    for pid in peers {
        if pid == local_peer_str || pid == device_peer_id || first.contains(&pid) || !told.insert(pid.clone()) {
            continue;
        }
        super::social::send_own_profile_to_peer(
            ws_cmd_tx, ws_room_peers, server_states,
            local_peer_str, master_keypair, &pid,
            is_invisible, db_path, db_passphrase,
        );
    }
}

/// This device removes `target_device` from our roster, or refuses its pending join.
/// The removed device learns it first, while the relay still routes to it.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_revoke_device(
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server_states: &HashMap<String, ServerState>,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    master_peer_str: &str,
    local_peer_str: &str,
    device_peer_id: &str,
    is_invisible: bool,
    target_device: String,
    db_path: &str,
    db_passphrase: &str,
) -> Option<String> {
    if let Err(e) = super::roster_book::remove(
        master_keypair, device_keypair, &target_device, db_path, db_passphrase,
    ) {
        let _ = event_tx.send(NetworkEvent::Error { message: e }).await;
        return None;
    }
    announce_roster_change(
        ws_cmd_tx, ws_room_peers, server_states, master_keypair, local_peer_str,
        device_peer_id, is_invisible, std::slice::from_ref(&target_device), db_path, db_passphrase,
    );
    let _ = event_tx.send(NetworkEvent::DeviceListUpdated {
        master_peer_id: master_peer_str.to_string(),
    }).await;
    Some(target_device)
}

// ── 10a2. ResetDeviceLists (full sibling teardown) ───────────────────

/// This device removes every other device and pending join, and each learns it
/// first. Returns the removed ids, or `None` when we were already the only one.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_reset_device_lists(
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server_states: &HashMap<String, ServerState>,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    master_peer_str: &str,
    local_peer_str: &str,
    device_peer_id: &str,
    is_invisible: bool,
    db_path: &str,
    db_passphrase: &str,
) -> Option<Vec<String>> {
    let removed = match super::roster_book::remove_all_others(
        master_keypair, device_keypair, db_path, db_passphrase,
    ) {
        Ok((_, _, removed)) => removed,
        Err(_) => {
            // Nothing to remove: still refresh the UI so it reflects the clean state.
            let _ = event_tx.send(NetworkEvent::DeviceListUpdated {
                master_peer_id: master_peer_str.to_string(),
            }).await;
            return None;
        }
    };
    announce_roster_change(
        ws_cmd_tx, ws_room_peers, server_states, master_keypair, local_peer_str,
        device_peer_id, is_invisible, &removed, db_path, db_passphrase,
    );
    let _ = event_tx.send(NetworkEvent::DeviceListUpdated {
        master_peer_id: master_peer_str.to_string(),
    }).await;
    Some(removed)
}

/// This device vouches for a device asking to join (a restored backup), which learns
/// it first.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_approve_device(
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server_states: &HashMap<String, ServerState>,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    device_peer_id: &str,
    is_invisible: bool,
    target_device: String,
    db_path: &str,
    db_passphrase: &str,
) {
    if let Err(e) = super::roster_book::vouch(
        master_keypair, device_keypair, &target_device, db_path, db_passphrase,
    ) {
        let _ = event_tx.send(NetworkEvent::Error { message: e }).await;
        return;
    }
    announce_roster_change(
        ws_cmd_tx, ws_room_peers, server_states, master_keypair, local_peer_str,
        device_peer_id, is_invisible, std::slice::from_ref(&target_device), db_path, db_passphrase,
    );
    let _ = event_tx.send(NetworkEvent::DeviceListUpdated {
        master_peer_id: local_peer_str.to_string(),
    }).await;
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
        // The owner is fixed for the server's life, so the only way out is a delete.
        if state.get_role(local_peer_str) == crate::crdt::operations::MemberRole::Owner {
            hollow_log!("[HOLLOW-CRDT] Owner cannot leave server {server_id}");
            return deny(event_tx, "You own this server, so you can't leave it, only delete it.").await;
        }

        hollow_log!("[HOLLOW-CRDT] Leaving server {server_id}");
        // Collect broadcast targets BEFORE apply_op removes us.
        let targets = other_member_targets(state, local_peer_str);
        let Some(op) = author_op(state, crdt_store, &server_id, CrdtPayload::MemberRemoved {
            peer_id: local_peer_str.to_string(),
        }) else {
            return deny(event_tx, "You can't leave this server right now").await;
        };

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
        let Some(op) = author_op(state, crdt_store, &server_id, CrdtPayload::MemberBanned {
            peer_id: peer_id.clone(),
        }) else {
            return deny(event_tx, "Permission denied: cannot ban this member").await;
        };

        let _ = event_tx.send(NetworkEvent::MemberLeft {
            server_id: server_id.clone(),
            peer_id: peer_id.clone(),
        }).await;

        // Banned peer is skipped — it gets MemberKickBroadcast instead.
        broadcast_removal_op(
            ws_cmd_tx, ws_room_peers, &targets, Some(&peer_id),
            local_peer_str, local_device_id, &server_id, &op,
        );

        // Tell every online device of the banned identity.
        if let Some(json) = super::olm_lane::carried_json(&HavenMessage::MemberKickBroadcast { server_id: server_id.clone() }) {
            super::olm_lane::carry_to_identity(ws_cmd_tx, ws_room_peers, &peer_id, &json, super::olm_lane::NoSession::Queue);
        }

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

        let Some(op) = author_op(state, crdt_store, &server_id, payload) else {
            return deny(event_tx, "Permission denied: cannot manage emotes").await;
        };

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
        // Tell the room's guests, who hold no server state. Only the author does, and a
        // channel going private keeps its name and category out of the clear: a guest
        // needs only its id to drop it.
        if let Some(ch) = state.channels.get(&channel_id) {
            let notify = HavenMessage::PublicChannelConfigChanged {
                server_id: server_id.clone(),
                channel_id: channel_id.clone(),
                is_public,
                channel_name: if is_public { ch.name.clone() } else { String::new() },
                category: if is_public { ch.category.clone() } else { None },
            };
            if let Ok(data) = serde_json::to_vec(&notify) {
                let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendPublic {
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
        OpBroadcast::WithFan { local_device_id },
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
        OpBroadcast::WithFan { local_device_id },
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
            carry_to_members(
                ws_cmd_tx, ws_room_peers, state, local_peer_str,
                &channel_sync_request(&store, &server_id, &channel_id, true),
            );
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
        OpBroadcast::WithFan { local_device_id },
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
        OpBroadcast::WithFan { local_device_id },
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
        OpBroadcast::WithFan { local_device_id },
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
        OpBroadcast::WithFan { local_device_id },
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
    // A member is asking the user something: it is here, and the answer asks again.
    if pending.parked || pending.asked {
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
    // With no verified lock yet the copy goes when one arrives (`handle_join_lock_chain`).
    if deposit_parked_join(ws_cmd_tx, &server_id, local_device_id, pending) {
        pending.last_deposited_at = super::types::now_ms();
    }
    // A refused join parks too, for a real admission, but its tile keeps the reason.
    let (state, reason) = tile_state(pending);
    crdt_store.upsert_pending_join(pending_join_row(&server_id, pending, state, &reason));
    if pending.refused.is_none() {
        let _ = event_tx.send(NetworkEvent::ServerJoinParked {
            server_id,
        }).await;
    }
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
        match build_channel_sync_batch(&store, &server_id, &channel_id, since_timestamp, &sender_ts, None) {
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
    // The ONE ingest (ServerState::ingest_remote): the author's
    // signature, the clock bound, then the shared permission matrix. It
    // validates op.author (the creator), never the transport sender.
    let ingested = state.ingest_remote(std::slice::from_ref(&op));
    if ingested.admitted.is_empty() && !ingested.rebuilt {
        return;
    }
    let op_is_new = ingested.admitted.iter().any(|o| o.author == op.author && o.hlc == op.hlc);
    crdt_store.persist_admitted(ingested.admitted, state.checkpoint_hlc.clone());
    crdt_store.save_state_snapshot(sid.clone(), state);
    if ingested.rebuilt {
        let _ = event_tx.send(NetworkEvent::ServerUpdated { server_id: sid.clone() }).await;
    }
    if op_is_new {
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
            | CrdtPayload::JoinKeySet { .. }
            | CrdtPayload::JoinLock { .. }
            | CrdtPayload::ServerCheckpoint { .. }
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

/// Whether a kick sealed at `frame_ts_ms` predates our current membership: a relay
/// holding back or replaying a kick from before we rejoined.
pub(crate) fn kick_predates_membership(state: &ServerState, local_master: &str, frame_ts_ms: i64) -> bool {
    let sealed = frame_ts_ms.saturating_add(super::frame_auth::LIVE_SKEW_MS).max(0) as u64;
    state.member_since(local_master).is_some_and(|since| sealed < since)
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
        let (inserted, events) = ingest_synced_channel_item(&store, &sid, &cid, msg, local_peer, &mut pk_cache);
        new_count += inserted;
        for ev in events {
            let _ = event_tx.send(ev).await;
        }
    }
    let _ = store.commit_transaction();
    if has_more == Some(true) {
        // No digest: the first page already carried the rows behind the watermarks.
        super::olm_lane::carry(
            ws_cmd_tx, sender_peer_id, None,
            &channel_sync_request(&store, &sid, &cid, false),
            super::olm_lane::NoSession::Queue,
        );
    }
    if has_more != Some(true) {
        let _ = event_tx.send(NetworkEvent::MessageSyncCompleted {
            server_id: sid,
            new_message_count: new_count,
        }).await;
    }
}

/// One `ChannelSyncBatch` item, for both transports: verify, guard the row it
/// names, then insert or update it with everything riding it. Returns (1 when a
/// NEW row was inserted, else 0; the events to emit). Synchronous because holding
/// a `&MessageStore` across an await would un-Send the caller's future.
pub(crate) fn ingest_synced_channel_item(
    store: &crate::storage::MessageStore,
    sid: &str,
    cid: &str,
    msg: &SyncMessageItem,
    local_peer: &str,
    pk_cache: &mut PkCache,
) -> (u32, Vec<NetworkEvent>) {
    let sig_check = verify_sync_item_sig(msg, sid, cid, pk_cache);
    // SECURITY: only a VERIFYING signature gets stored, and the whole item is
    // dropped (text, edit, file metadata, reactions and the hidden flag all ride
    // it). Unsigned is refused too as of 0.8.5: the item names its own sender,
    // so omitting the signature was an impersonation primitive.
    if !sig_check.is_acceptable() {
        hollow_log!(
            "[HOLLOW-SECURITY] REJECTED synced channel message in {sid}/{cid} claiming sender {} — {} (mid={:?}, ts={})",
            msg.s, sig_check.reject_reason(), msg.mid, msg.ts
        );
        return (0, Vec::new());
    }
    let scope = super::message_ops::RowScope::Channel { sid, cid, signer: &msg.s };
    if !super::message_ops::change_may_touch_row(store, &scope, msg.mid.as_deref()) {
        return (0, Vec::new());
    }
    let sig_verified = sig_check == BackfillSig::Valid;
    // Multi-device: a message authored by ANY of our own devices is ours.
    let is_mine = super::resolver::same_identity(&msg.s, local_peer);
    let (inserted, mut events) = upsert_synced_channel_message(store, sid, cid, msg, is_mine, sig_verified);
    events.extend(apply_sync_item_extras(store, sid, cid, msg, is_mine, pk_cache));
    (inserted, events)
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
        album: msg.album.as_deref(),
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
            msg.album.as_deref(),
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
    if let Some(fm) = super::file_handler::synced_file_meta(
        store, msg.file_meta.as_ref(), msg.file_id.as_deref(), msg.mid.as_deref(), &msg.s,
    ) {
        let ctx_id = format!("{sid}:{cid}");
        let thumb = super::file_handler::accept_header_thumb(fm.thumb.clone(), fm.img, &fm.mime);
        let _ = store.insert_file_metadata(
            &fm.fid, &fm.name, &fm.ext, &fm.mime,
            fm.size, 0, fm.img, fm.w, fm.h,
            msg.mid.as_deref(), "channel", &ctx_id,
            &msg.s, is_mine, fm.ts,
            fm.vthumb.as_ref(), thumb.as_deref(), fm.sha256.as_deref(),
        );
        events.push(NetworkEvent::FileHeaderReceived {
            file_id: fm.fid.clone(), file_name: fm.name.clone(),
            size_bytes: fm.size, is_image: fm.img,
            width: fm.w, height: fm.h,
            message_id: msg.mid.clone().unwrap_or_default(),
            sender_id: msg.s.clone(),
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
