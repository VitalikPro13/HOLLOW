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
    persist_mls_state, online_devices_for,
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

/// Carry a `CrdtOpBroadcast` to every member device and to our own online siblings
/// inside Olm: the path that does not depend on anyone's MLS epoch, and the author's
/// guarantee, since no receiver forwards an op on over the relay.
///
/// The WebRTC mesh gets it too when the server's overlay has live data channels; it is a
/// faster path, never the only one (`reports/shipped/relay-and-sync/LARGE_SERVER_SCALING_2026.md`).
#[allow(clippy::too_many_arguments)]
fn broadcast_crdt_op_to_members(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    gossip_overlays: &mut HashMap<String, super::gossip::GossipOverlay>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    state: &ServerState,
    local_peer_str: &str,
    local_device_id: &str,
    server_id: &str,
    op_json: &str,
) {
    super::gossip_relay::flood_crdt_op(gossip_overlays, event_tx, server_id, op_json, None);
    let msg = HavenMessage::CrdtOpBroadcast { server_id: server_id.to_string(), op_json: op_json.to_string() };
    carry_to_members(ws_cmd_tx, ws_room_peers, state, local_peer_str, &msg);
    super::olm_lane::carry_to_own_siblings(
        ws_cmd_tx, ws_room_peers, local_peer_str, local_device_id, &msg, super::olm_lane::NoSession::Queue,
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
pub(crate) fn broadcast_op_mls_first(
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
        #[cfg(test)]
        super::lock_keeper::note_door_send(server_id, &op.payload, mls.as_ref().map(|m| m.group_members(server_id)).unwrap_or_default());
        let envelope = MessageEnvelope::CrdtOp { sid: server_id.to_string(), op_json: op_json.clone() };
        if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, server_id, &envelope, crypto_store, Some(state)) {
            hollow_log!("[HOLLOW-MLS] CrdtOp broadcast failed, the Olm twin still goes: {e}");
        }
    }
    // The room peer lists never hold this device, so skipping it needs no device id.
    broadcast_crdt_op_to_members(
        ws_cmd_tx, ws_room_peers, gossip_overlays, event_tx, state, local_peer_str, "", server_id, &op_json,
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
        ws_cmd_tx, ws_room_peers, gossip_overlays, event_tx, state, local_peer_str, local_device_id, server_id, &op_json,
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
    /// The local peer is the server's owner.
    Owner,
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
        OpGate::Owner => state.current_owner().as_deref() == Some(local_peer),
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
    crdt_resync: &super::crdt_resync::CrdtResync,
) {
    let now = crate::crdt::hlc::wall_clock_ms();
    for s in server_states.values_mut().filter(|s| !s.refold_answers.is_empty()) {
        if s.settle_refold_answers() {
            keep_refold_answers(crdt_store, s);
        }
    }
    let due: Vec<String> = server_states
        .iter()
        .filter(|(id, s)| {
            s.checkpoint_due(local_peer_str, now)
                && s.checkpoint_witnessed(local_peer_str, &crdt_resync.op_sync.witnesses(id))
        })
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
        let public_before: Vec<String> = state.public_channels().map(|c| c.channel_id.clone()).collect();
        let refolded_before = state.base.as_ref().map(|b| b.state.cp_refolded.clone()).unwrap_or_default();
        let Some((op, ingested)) = state.author_due_checkpoint(local_peer_str, &past_authors, now) else {
            hollow_log!("[HOLLOW-CRDT] Could not checkpoint {server_id}; next try in an hour");
            continue;
        };
        let refolded = state.base.as_ref().is_some_and(|b| b.state.cp_refolded != refolded_before);
        hollow_log!("[HOLLOW-CRDT] Checkpointed {server_id} ({} ops kept)", state.op_log.len());
        crdt_store.persist(ingested.delta(&server_id));
        crdt_store.save_state_snapshot(server_id.clone(), state);
        broadcast_op_mls_first(
            mls, ws_cmd_tx, ws_room_peers, gossip_overlays, event_tx, state, local_peer_str, &server_id, &op, crypto_store,
        );
        // Section 8.3: an Unpublish revert closes channels to guests at once.
        for channel_id in public_before {
            tell_guests_if_closed(server_states, event_tx, ws_cmd_tx, &server_id, &channel_id, true).await;
        }
        if refolded {
            let _ = event_tx.send(NetworkEvent::ServerUpdated { server_id: server_id.clone() }).await;
        }
    }
}

/// Store the owner's re-fold answers a checkpoint does not carry yet (section 8.3,
/// "Confirm"), so a restart before the next checkpoint keeps them.
pub(crate) fn keep_refold_answers(crdt_store: &CrdtStore, state: &ServerState) {
    let key = crate::crdt::refold_write::ANSWERS_BLOB.to_string();
    match state.refold_answers_json() {
        Some(json) => crdt_store.save_blob(state.server_id.clone(), key, json),
        None => crdt_store.delete_blob(state.server_id.clone(), key),
    }
}

/// Writer rule a counts only digest rounds WE asked: where our checkpoint is due and not
/// yet witnessed, ask the online members a round of our own.
#[allow(clippy::too_many_arguments)]
pub(crate) fn ask_checkpoint_witnesses(
    server_states: &ServerStates,
    crdt_resync: &mut super::crdt_resync::CrdtResync,
    frame_budget: &mut super::frame_budget::FrameBudget,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    local_peer_str: &str,
    device_peer_id: &str,
    now: std::time::Instant,
) {
    let now_ms = crate::crdt::hlc::wall_clock_ms();
    for (sid, state) in server_states {
        if !state.checkpoint_due(local_peer_str, now_ms)
            || state.checkpoint_witnessed(local_peer_str, &crdt_resync.op_sync.witnesses(sid))
        {
            continue;
        }
        for device in crdt_resync.op_sync.witness_round(state, ws_room_peers.get(sid), local_peer_str, now) {
            let ask = crdt_resync.sync_ask(state, &device, None, None);
            super::frame_budget::pace_carried(frame_budget, ws_cmd_tx, device_peer_id, &device, &ask);
        }
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
    device_peer_id: &str,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
    caught_up: &super::join_hold::JoinHold,
    pending_server_joins: &HashMap<String, PendingJoin>,
    crdt_resync: &super::crdt_resync::CrdtResync,
) {
    let missing: Vec<String> = server_states
        .iter()
        .filter(|(_, s)| !s.is_deleted() && s.join_secret().is_none() && s.current_owner().as_deref() == Some(local_peer_str))
        .map(|(id, _)| id.clone())
        .filter(|id| {
            sets_missing_join_key(id, caught_up, pending_server_joins, crdt_resync, server_states, ws_room_peers, local_peer_str, device_peer_id)
        })
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

/// Whether this device sets a server's missing join key now. A second key is an invite
/// reset, so only a device that knows none exists sets one: the lowest of the owner's
/// devices the relay shows us in the room, with no join or whole-log fetch under way,
/// once this connection's catch-up there finished or no other member is there. Never
/// while we are away: the relay hides us from our siblings too, so an on-screen
/// higher one also thinks it is the lowest.
#[allow(clippy::too_many_arguments)]
fn sets_missing_join_key(
    server_id: &str,
    join_hold: &super::join_hold::JoinHold,
    pending_server_joins: &HashMap<String, PendingJoin>,
    crdt_resync: &super::crdt_resync::CrdtResync,
    server_states: &ServerStates,
    ws_room_peers: &WsRoomPeers,
    local_master: &str,
    local_device: &str,
) -> bool {
    if super::ws_client::backgrounded() || pending_server_joins.contains_key(server_id) || crdt_resync.whole_log_due(server_id) {
        return false;
    }
    let lower_sibling = ws_room_peers.get(server_id).is_some_and(|peers| {
        peers.iter().any(|d| {
            d.as_str() < local_device && super::resolver::is_device_of(d, local_master) && !super::resolver::is_revoked(d)
        })
    });
    if lower_sibling {
        return false;
    }
    let others: Vec<String> = super::join_hold::visible_members(server_id, server_states, ws_room_peers)
        .into_iter()
        .filter(|d| d != local_device)
        .collect();
    join_hold.caught_up(server_id, &others)
}

// ── Shared member-removal plumbing (kick / ban / leave) ───────────────

/// Every OTHER member (master-keyed), collected BEFORE `apply_op` removes the
/// target from `state.members`.
fn other_member_targets(state: &ServerState, local_peer: &str) -> Vec<String> {
    state.members.keys().filter(|m| m.as_str() != local_peer).cloned().collect()
}

/// Fan a member-removal CRDT op to the remaining members (collected before the
/// removal applied) and to our OWN online siblings, which the master-keyed member
/// list excludes. `skip` = the removed identity, which gets the op inside a
/// `MemberKickBroadcast` instead ([`carry_kick_notice`]).
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
    // A removal drops the server on our own devices at once, the hidden ones included.
    super::olm_lane::carry_to_every_own_device(ws_cmd_tx, ws_room_peers, local_peer_str, local_device_id, &msg);
}

/// Tell every online device of the removed `identity` with the removal op itself:
/// a device leaves only once its own fold drops it, never on a bare notice.
fn carry_kick_notice(
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    server_id: &str,
    identity: &str,
    op: &crate::crdt::operations::CrdtOp,
) {
    let Ok(op_json) = serde_json::to_string(op) else { return };
    let msg = HavenMessage::MemberKickBroadcast { server_id: server_id.to_string(), op_json };
    if let Some(json) = super::olm_lane::carried_json(&msg) {
        super::olm_lane::carry_to_identity(ws_cmd_tx, ws_room_peers, identity, &json, super::olm_lane::NoSession::Queue);
    }
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
    rate_exempt: bool,
    log_ok: &str,
) {
    if !mls_mgr.has_group(server_id) { return; }
    let id_set = identity_credential_ids(identity);
    let owned: Vec<&str> = id_set.iter().map(|s| s.as_str()).collect();
    match mls_mgr.remove_identity_leaves_as(server_id, &owned, rate_exempt) {
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
    let mids: Vec<&str> = msg_ids.iter().map(String::as_str).collect();
    let proofs = store.channel_post_proofs(&mids);

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
                e: e.clone(), p: p.clone(), ts: *ts, sig: sig.clone(), pk: pk.clone(), dev: None,
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
            dev: m.message_id.as_ref().and_then(|mid| proofs.get(mid)).cloned().map(Box::new),
            hidden_dev: None,
            lp_dev: None,
        });
    }
    attach_change_proofs(store, &mut items);
    SyncPage { items, truncated }
}

/// Serve each change riding a page with the device proof its row keeps.
pub(crate) fn attach_change_proofs(store: &crate::storage::MessageStore, items: &mut [SyncMessageItem]) {
    let mids: Vec<&str> = items.iter().filter_map(|i| i.mid.as_deref()).collect();
    let fids: Vec<&str> = items.iter().filter_map(|i| i.file_meta.as_ref().map(|f| f.fid.as_str())).collect();
    let mut proofs = store.change_proofs(&mids, &fids);
    for item in items.iter_mut() {
        let Some(mid) = item.mid.clone() else { continue };
        if item.hidden_at.is_some() {
            item.hidden_dev = proofs.deletions.remove(&mid).map(Box::new);
        }
        if item.lp.is_some() {
            item.lp_dev = proofs.cards.remove(&mid).map(Box::new);
        }
        for r in &mut item.reactions {
            r.dev = proofs.reactions.remove(&(mid.clone(), r.e.clone(), r.p.clone())).map(Box::new);
        }
        if let Some(fm) = item.file_meta.as_mut() {
            fm.dev = proofs.files.get(&fm.fid).cloned().map(Box::new);
        }
    }
}

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
        // Every field from the rows we vouch for: a cleared device asks as one whose
        // history begins at its oldest row past the floor, never naming the floor.
        since_timestamp: store.channel_ask_since(server_id, channel_id),
        sender_timestamps: store.get_per_sender_timestamps(server_id, channel_id).unwrap_or_default(),
        gap: if with_gap { store.channel_gap_anchor(server_id, channel_id) } else { None },
        partial_ok: true,
        until: None,
    }
}

/// The ask for what a channel still lacks below its hole, `None` without one: every
/// sender we hold from where the hole starts (one we never met, in full), up to the top.
/// A gap digest would only serve rows of the hole again.
pub(crate) fn channel_hole_request(
    store: &crate::storage::MessageStore,
    server_id: &str,
    channel_id: &str,
) -> Option<HavenMessage> {
    let hole = store.channel_hole(server_id, channel_id)?;
    let from = hole.from.max(0);
    Some(HavenMessage::ChannelSyncRequest {
        server_id: server_id.to_string(),
        channel_id: channel_id.to_string(),
        since_timestamp: from - 1,
        sender_timestamps: store.channel_sender_ids(server_id, channel_id).unwrap_or_default().into_iter().map(|s| (s, from)).collect(),
        gap: None,
        partial_ok: true,
        until: (hole.below != i64::MAX).then_some(hole.below),
    })
}

/// The ask of `kind` for one channel; a hole served meanwhile asks as a catch-up.
pub(crate) fn channel_ask_of(
    store: &crate::storage::MessageStore,
    server_id: &str,
    channel_id: &str,
    kind: super::channel_asks::Kind,
) -> HavenMessage {
    match kind {
        super::channel_asks::Kind::Hole => channel_hole_request(store, server_id, channel_id),
        super::channel_asks::Kind::Catch => None,
    }
    .unwrap_or_else(|| channel_sync_request(store, server_id, channel_id, true))
}

/// Where a channel sync page ended, read before anything in it is filtered out: the
/// next page continues from the page the responder served, not from what we kept.
pub(crate) struct ChannelPageEnd {
    last: i64,
    senders: std::collections::BTreeSet<String>,
}

impl ChannelPageEnd {
    /// The newest timestamp the page served.
    pub(crate) fn last(&self) -> i64 {
        self.last
    }

    /// `None` when a page from this end would serve the whole page again (one
    /// millisecond fills it): paging stops there and the next catch-up takes the rest.
    pub(crate) fn of(items: &[SyncMessageItem]) -> Option<Self> {
        let last = items.iter().map(|m| m.ts).max()?;
        items
            .iter()
            .any(|m| m.ts < last)
            .then(|| Self { last, senders: items.iter().map(|m| m.s.clone()).collect() })
    }
}

/// The next page of a channel sync: every sender from where the page ended. Our own
/// watermarks are no cursor here: a post that arrived while paging moves its sender's
/// past rows not served yet, and their lookback holds a busy page in place. A sender
/// the ask does not name is served in full, which past this page is only rows at or
/// after its end.
pub(crate) fn channel_next_page_request(
    store: &crate::storage::MessageStore,
    server_id: &str,
    channel_id: &str,
    end: ChannelPageEnd,
    // The hole's top, for a page of the ask for a hole.
    until: Option<i64>,
) -> HavenMessage {
    // A catch-up page that served a sender in full from below where our history starts
    // goes on from there: below it is our hole, asked for by itself, or rows we never held
    // before a clear, which the floor refuses.
    let from = match (until, store.channel_page_start(server_id, channel_id)) {
        (None, Some(start)) => end.last.max(start),
        _ => end.last,
    };
    let mut sender_timestamps: HashMap<String, i64> = store
        .get_per_sender_timestamps(server_id, channel_id)
        .unwrap_or_default()
        .into_keys()
        .map(|sender| (sender, from))
        .collect();
    sender_timestamps.extend(end.senders.into_iter().map(|sender| (sender, from)));
    HavenMessage::ChannelSyncRequest {
        server_id: server_id.to_string(),
        channel_id: channel_id.to_string(),
        since_timestamp: from,
        sender_timestamps,
        gap: None,
        partial_ok: true,
        until,
    }
}

/// What tells two channel sync asks apart for the responder's de-dup: a repeat of one
/// ask is answered once, the ask for the next page is answered too.
pub(crate) fn channel_sync_ask_key(
    since_timestamp: i64,
    sender_timestamps: &HashMap<String, i64>,
    gap: Option<&GapDigest>,
    until: Option<i64>,
) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut senders: Vec<(&String, &i64)> = sender_timestamps.iter().collect();
    senders.sort();
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    since_timestamp.hash(&mut hasher);
    senders.hash(&mut hasher);
    serde_json::to_string(&gap).unwrap_or_default().hash(&mut hasher);
    until.hash(&mut hasher);
    hasher.finish()
}

/// Where the next page of a DM sync starts: at the page's own end, never at our newest
/// row, which a DM that arrived while paging moves past rows the responder has not
/// served yet. `strict` = the next ask is `both_directions`, served by the
/// `timestamp >` query, so it starts one millisecond early to keep the rows that share
/// the page's last timestamp. `None` when that ask would serve this whole page again
/// (one millisecond fills it, or edits keep it qualifying): paging stops there and the
/// next catch-up takes the rest.
pub(crate) fn dm_next_page_since(items: &[DmSyncItem], strict: bool) -> Option<i64> {
    let last = items.iter().map(|m| m.ts).max()?;
    let since = if strict { last - 1 } else { last };
    let served_again = |m: &DmSyncItem| {
        (if strict { m.ts > since } else { m.ts >= since })
            || m.edited_at.max(m.hidden_at).is_some_and(|at| at >= since)
    };
    (!items.iter().all(served_again)).then_some(since)
}

/// How long a page we asked for counts as asked: two overlapping asks bring the same
/// page twice, and one conversation must not page twice side by side.
const DM_PAGE_REPEAT_WINDOW: Duration = Duration::from_secs(10);

/// Whether `peer` was asked for this page of `convo` moments ago; records the ask
/// when it was not.
pub(crate) fn dm_page_asked(
    asked: &mut HashMap<String, std::time::Instant>,
    peer: &str,
    convo: &str,
    since: i64,
) -> bool {
    let key = format!("dm_page:{peer}:{convo}:{since}");
    if asked.get(&key).is_some_and(|at| at.elapsed() < DM_PAGE_REPEAT_WINDOW) {
        return true;
    }
    asked.insert(key, std::time::Instant::now());
    false
}

/// What a sibling backfill names a conversation it wants nothing more of: no row is
/// newer than it.
const NOTHING_NEWER: i64 = i64::MAX;

/// The next page of one conversation of a sibling backfill. The responder serves
/// every conversation an ask leaves out from its start, so every other one we hold is
/// named past its end: one page must not fetch every other conversation again.
pub(crate) fn sibling_next_page_request(
    store: &crate::storage::MessageStore,
    convo: &str,
    since: i64,
) -> HavenMessage {
    let mut per_convo_since: Vec<(String, i64)> = store
        .get_dm_peer_ids()
        .into_iter()
        .filter(|held| held != convo)
        .map(|held| (held, NOTHING_NEWER))
        .collect();
    per_convo_since.push((convo.to_string(), since));
    HavenMessage::DmSiblingSyncRequest { per_convo_since, gaps: HashMap::new() }
}

/// A guest page (the newest `limit` rows, oldest first) cut to where we vouch from, as a
/// member's page is, so it tells a guest no clear: whether more follows, `None` = send nothing.
pub(crate) fn guest_page_bounded(
    store: &crate::storage::MessageStore,
    server_id: &str,
    channel_id: &str,
    rows: &mut Vec<crate::storage::messages::StoredChannelMessage>,
    limit: usize,
) -> Option<bool> {
    let held = store.channel_held_from(server_id, channel_id);
    rows.retain(|m| held.is_none_or(|from| m.timestamp >= from));
    // Oldest first, as the query returns them.
    guest_page_more(held.map(|from| from.saturating_sub(1)), rows.len(), limit, rows.first().map(|m| m.timestamp))
}

/// A guest page (newest first, at most `limit` rows, the oldest at `oldest`) from a
/// device holding the channel only past `floor` (a clear, a later start): one reaching it is never the
/// channel's start, so it says more follows, and with no row it is not sent at all
/// (`None`); every other member answers the guest too.
pub(crate) fn guest_page_more(floor: Option<i64>, rows: usize, limit: usize, oldest: Option<i64>) -> Option<bool> {
    let Some(floor) = floor else { return Some(false) };
    let reaches = rows < limit || oldest.is_some_and(|ts| ts <= floor);
    match (reaches, rows) {
        (false, _) => Some(false),
        (true, 0) => None,
        (true, _) => Some(true),
    }
}

/// What one channel sync answer serves, after the holder's own history bounds it.
struct Served<'a> {
    since: i64,
    marks: std::borrow::Cow<'a, HashMap<String, i64>>,
    gap: Option<GapDigest>,
    held_from: Option<i64>,
    /// Bounded to the stretch this holder vouches for: no ask names a row below it.
    bounded: bool,
}

/// Build one page (at most 200 messages) of a channel-sync response: per-sender
/// watermarks when the requester sent them, a legacy single timestamp otherwise,
/// then pack and stamp `total`/`has_more`. Returns the envelope and item count.
#[allow(clippy::too_many_arguments)]
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
    partial_ok: bool,
    until: Option<i64>,
) -> Result<(MessageEnvelope, usize), String> {
    let served = match store.channel_held_from(sid, cid) {
        None => Served { since: since_timestamp, marks: std::borrow::Cow::Borrowed(sender_timestamps), gap: gap.cloned(), held_from: None, bounded: false },
        Some(held) => {
            let reaches = store.channel_ask_reaches_below(sid, cid, held, since_timestamp, sender_timestamps, gap.map(|g| g.from));
            // An older asker would move its watermarks past what we lack: no rows and more
            // to come (`Page::Stuck`), so it asks another holder now.
            if reaches && !partial_ok {
                let below = MessageEnvelope::ChannelSyncBatch {
                    sid: sid.to_string(),
                    cid: cid.to_string(),
                    messages: Vec::new(),
                    total: 0,
                    has_more: Some(true),
                    target: None,
                    held_from: None,
                };
                return Ok((below, 0));
            }
            // Only the stretch we vouch for, whatever we hold below it: every holder lacking
            // part of the channel serves alike, so the page tells no clear from a late join.
            Served {
                since: since_timestamp.max(held.saturating_sub(1)),
                marks: std::borrow::Cow::Owned(store.channel_marks_from(sid, cid, held, since_timestamp, sender_timestamps)?),
                gap: gap.filter(|g| g.until > held).map(|g| GapDigest { from: g.from.max(held), ..g.clone() }),
                held_from: reaches.then_some(held),
                bounded: true,
            }
        }
    };
    let (since_timestamp, sender_timestamps, gap) = (served.since, served.marks.as_ref(), served.gap.as_ref());
    let empty_bound = served.bounded && sender_timestamps.is_empty();
    // One row past the page says whether more follow, without counting what is left:
    // a count on every page made a long first sync quadratic.
    let (mut messages, per_sender_more) = if empty_bound {
        (Vec::new(), false)
    } else if !sender_timestamps.is_empty() {
        let mut rows = store.get_channel_messages_since_per_sender(sid, cid, sender_timestamps, 201)?;
        let more = rows.len() > 200;
        rows.truncate(200);
        (rows, more)
    } else {
        (store.get_channel_messages_since(sid, cid, since_timestamp, 200)?, false)
    };
    // Rows come oldest first: one at or past `until` ends the stretch asked for.
    let past_until = until.is_some_and(|u| messages.iter().any(|m| m.timestamp >= u));
    messages.retain(|m| until.is_none_or(|u| m.timestamp < u));
    let tail_len = messages.len();
    if let Some(gap) = gap {
        let paged: std::collections::HashSet<String> =
            messages.iter().filter_map(|m| m.message_id.clone()).collect();
        // A page cut by its limit takes no gap row past its end: the next pages serve
        // every sender from that end, and a row past it would move the requester's
        // next page over tail rows it has not had.
        let tail_end = if tail_len >= 200 { messages.last().map(|m| m.timestamp) } else { None };
        let missed = store.get_channel_gap_messages(sid, cid, gap, 200).unwrap_or_default();
        messages.extend(missed.into_iter().filter(|m| {
            m.message_id.as_ref().is_some_and(|id| !paged.contains(id))
                && tail_end.is_none_or(|end| m.timestamp <= end)
                && until.is_none_or(|u| m.timestamp < u)
        }));
        messages.sort_by_key(|m| m.timestamp);
    }
    let gap_len = (messages.len() - tail_len) as u32;
    let SyncPage { items, truncated } = channel_sync_items(store, &messages);
    // `total` only drives the asker's progress line, so the ask for a next page (every
    // sender from where the last page ended) counts just this page.
    let next_page = gap.is_none() && sender_timestamps.values().all(|ts| *ts == since_timestamp);
    let tail_total = if empty_bound {
        0
    } else if sender_timestamps.is_empty() {
        store.count_channel_messages_since(sid, cid, since_timestamp)
            .unwrap_or(tail_len as u32)
    } else if next_page {
        tail_len as u32
    } else {
        store.count_channel_messages_since_per_sender(sid, cid, sender_timestamps)
            .unwrap_or(tail_len as u32)
    };
    let total = tail_total + gap_len;
    // `truncated` = the preview budget ended the page before the query did, so
    // there is definitely more to serve even though the page is short.
    let more_rows = !past_until
        && if sender_timestamps.is_empty() { tail_len >= 200 && tail_total > 200 } else { per_sender_more };
    let has_more = if truncated || more_rows {
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
        held_from: served.held_from,
    }, count))
}

// ── 1. CreateServer ───────────────────────────────────────────────────

pub(crate) async fn handle_create_server(
    server_states: &mut HashMap<String, ServerState>,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    r_pub: Option<&str>,
    store_at: (&str, &str),
    local_peer_str: &str,
    device_peer_id: &str,
    name: String,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) {
    // A self-certifying id: our master key and the founding op's nonce hash to it,
    // so any joiner can prove who owns the server without trusting who answers.
    let pk_b64 = base64::engine::general_purpose::STANDARD.encode(bundle_keypair.public_key_protobuf());
    let founder = crate::crdt::server_state::Founder { device_peer_id, device: Some(device_keypair), r_pub };
    let (mut state, founding) = ServerState::found_on(name.clone(), local_peer_str.to_string(), founder, bundle_keypair.clone(), pk_b64);
    super::authority_view::install(&mut state, store_at.0, store_at.1);
    let server_id = state.server_id.clone();
    hollow_log!("[HOLLOW-CRDT] Creating server {server_id}");
    crdt_store.insert_op(founding);
    crdt_store.save_state_snapshot(server_id.clone(), &state);
    // Its founder holds all there is of it.
    super::age_gate::note_settled_at(store_at.0, store_at.1, &server_id);

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
    // Our online siblings hear of it from `author_join_lock_op`, once its first join
    // lock is on the relay: a sibling's join asked before then finds no lock.
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
    // A tombstoned shell is never joined again: its join ring would only replay old answers.
    if secs <= 0 || state.is_deleted() {
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
        // A tombstoned shell has no channel anyone still posts to.
        Some(state) if state.relay_catchup_secs() > 0 && !state.is_deleted() => {
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
            end: false,
        });
    }
}

/// Ask the relay to replay a server room's join ring once per session: a member
/// collects parked asks and the answers to them, a joiner the answer addressed to it.
/// No `max_age`: a join has no watermark, and an old ask is exactly the one wanted.
#[allow(clippy::too_many_arguments)]
pub(crate) fn request_join_ring_catchup(
    ws_cmd_tx: &WsCmdTx,
    server_states: &ServerStates,
    pending_server_joins: &HashMap<String, PendingJoin>,
    join_hold: &mut super::join_hold::JoinHold,
    relay_catchup_done: &mut std::collections::HashSet<(String, String)>,
    room: &str,
    hidden: bool,
    tag: &str,
) {
    let held = server_states.get(room).filter(|s| !s.is_deleted());
    let member = held.is_some();
    if member {
        join_hold.joined(room, hidden);
    }
    let ring_wanted = held.is_some_and(|s| s.relay_catchup_secs() > 0)
        || pending_server_joins.contains_key(room);
    if !ring_wanted || hidden || !relay_catchup_done.insert((room.to_string(), JOIN_TOPIC.to_string())) {
        return;
    }
    hollow_log!("[HOLLOW-TOPIC] Join-ring catch-up request ({tag}) for {room}");
    let owner = server_states
        .get(room)
        .and_then(|s| s.anchor_owner())
        .or_else(|| pending_server_joins.get(room).and_then(|p| p.owner_pin.clone()));
    let topic = super::ring_auth::ring_topic(room, owner.as_deref(), JOIN_TOPIC);
    // A member judges the parked asks of the replay only after its end.
    if member {
        join_hold.ring_asked(room, &topic);
    }
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::TopicCatchup {
        room_code: room.to_string(),
        channel_id: topic,
        max_age_secs: 0,
        end: member,
    });
}

/// A resumed relay session whose ring overflowed while we were away
/// (`Resumed { gap: true }`, RESUMABLE_SESSIONS_PLAN.md 9.8). What fell out comes back
/// through the catch-ups a fresh session runs (topic rings, server sync, DM gap
/// digests), without a single join. A dropped frame may have been a removal, so every
/// server judges join asks again as a member back from away (HOL-SEC-121).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn repair_after_gap(
    ws_cmd_tx: &WsCmdTx,
    crdt_store: &CrdtStore,
    server_states: &ServerStates,
    ws_room_peers: &WsRoomPeers,
    pending_server_joins: &HashMap<String, PendingJoin>,
    relay_catchup_done: &mut std::collections::HashSet<(String, String)>,
    join_hold: &mut super::join_hold::JoinHold,
    crdt_resync: &mut super::crdt_resync::CrdtResync,
    hidden: &(dyn Fn(&str) -> bool + Sync),
    sync_coordinator: &mut SyncCoordinator,
    budget: &mut super::frame_budget::FrameBudget,
    mls: Option<&MlsManager>,
    master: &crate::identity::native_identity::NativeKeypair,
    local_peer: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    relay_catchup_done.clear();
    join_hold.went_away(server_states);
    crdt_resync.op_sync.went_away();
    let rooms: std::collections::BTreeSet<String> =
        server_states.keys().chain(pending_server_joins.keys()).cloned().collect();
    for room in &rooms {
        let hidden = hidden(room);
        if !hidden {
            request_channel_catchups(
                ws_cmd_tx, crdt_store, server_states.get(room), room, local_peer, master, relay_catchup_done, "gap",
            )
            .await;
        }
        request_join_ring_catchup(
            ws_cmd_tx, server_states, pending_server_joins, join_hold, relay_catchup_done, room, hidden, "gap",
        );
    }

    // Whom to ask: the member devices each server room shows us, and the friends' devices
    // in our DM rooms.
    let mut server_peers: Vec<(String, String)> = Vec::new();
    for (sid, state) in server_states {
        if state.is_deleted() || !state.keeps_peer(local_peer) {
            continue;
        }
        for device in ws_room_peers.get(sid).into_iter().flatten() {
            if state.keeps_peer(device) {
                server_peers.push((sid.clone(), device.clone()));
            }
        }
    }
    let mut dm_peers: Vec<String> = ws_room_peers
        .iter()
        .flat_map(|(room, peers)| {
            peers.iter().filter(move |d| *room == dm_room_code(local_peer, &super::resolver::resolve(d)))
        })
        .cloned()
        .collect();
    dm_peers.sort();
    dm_peers.dedup();

    ask_peers_to_fill(
        ws_cmd_tx, server_states, crdt_resync, &server_peers, &dm_peers, join_hold.ask(), sync_coordinator, budget, mls,
        local_peer, db_path, db_passphrase,
    )
    .await;
    hollow_log!(
        "[HOLLOW-SYNC] Gap repair after a resume: {} room(s), {} server peer(s), {} DM peer(s)",
        rooms.len(), server_peers.len(), dm_peers.len(),
    );
}

/// A peer our inbound rate limit dropped frames from, back inside its bucket: ask it
/// again for what those frames may have carried, as [`repair_after_gap`] asks every
/// peer. A stranger shares no DM room or server with us and is asked nothing. Returns
/// (servers asked about, whether its DM history was).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn repair_after_drops(
    peer: &str,
    ws_cmd_tx: &WsCmdTx,
    server_states: &ServerStates,
    ws_room_peers: &WsRoomPeers,
    join_hold: &super::join_hold::JoinHold,
    crdt_resync: &mut super::crdt_resync::CrdtResync,
    sync_coordinator: &mut SyncCoordinator,
    budget: &mut super::frame_budget::FrameBudget,
    mls: Option<&MlsManager>,
    local_peer: &str,
    db_path: &str,
    db_passphrase: &str,
) -> (usize, bool) {
    let in_room = |room: &str| ws_room_peers.get(room).is_some_and(|peers| peers.contains(peer));
    let server_peers: Vec<(String, String)> = server_states
        .iter()
        .filter(|(sid, state)| !state.is_deleted() && state.keeps_peer(local_peer) && state.keeps_peer(peer) && in_room(sid))
        .map(|(sid, _)| (sid.clone(), peer.to_string()))
        .collect();
    let dm_peers: Vec<String> = in_room(&dm_room_code(local_peer, &super::resolver::resolve(peer)))
        .then(|| peer.to_string())
        .into_iter()
        .collect();
    // No server counts a device whose roster we never got, and that roster may be what
    // the bucket dropped: a device sitting in a room of a server we hold is asked for
    // its profile, which carries it. Once placed, the asks below reach it next time.
    let unplaced = super::resolver::resolve(peer) == peer
        && !super::resolver::is_known_master(peer)
        && !super::resolver::is_revoked(peer);
    let held_room = server_states
        .iter()
        .find(|(sid, state)| !state.is_deleted() && state.is_member(local_peer) && in_room(sid))
        .map(|(sid, _)| sid.clone());
    if unplaced && let Some(room) = held_room {
        hollow_log!("[HOLLOW-SECURITY] {peer} sits in a server room we hold and we cannot place it: asked its profile");
        super::olm_lane::carry(ws_cmd_tx, peer, Some(&room), &HavenMessage::ProfileRequest, super::olm_lane::NoSession::Queue);
    }
    ask_peers_to_fill(
        ws_cmd_tx, server_states, crdt_resync, &server_peers, &dm_peers, join_hold.ask(), sync_coordinator, budget, mls,
        local_peer, db_path, db_passphrase,
    )
    .await;
    (server_peers.len(), !dm_peers.is_empty())
}

/// Ask each `(server, member device)` for a server sync and its channels, and each
/// friend device for a DM sync behind a gap digest: what fell out comes back from the
/// peers that hold it. The server asks are paced: one per server we share.
#[allow(clippy::too_many_arguments)]
async fn ask_peers_to_fill(
    ws_cmd_tx: &WsCmdTx,
    server_states: &ServerStates,
    crdt_resync: &mut super::crdt_resync::CrdtResync,
    server_peers: &[(String, String)],
    dm_peers: &[String],
    nonce: u64,
    sync_coordinator: &mut SyncCoordinator,
    budget: &mut super::frame_budget::FrameBudget,
    mls: Option<&MlsManager>,
    local_peer: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    let channels: Vec<(String, Vec<String>)> = server_peers
        .iter()
        .map(|(sid, _)| sid.clone())
        .collect::<std::collections::BTreeSet<_>>()
        .into_iter()
        .filter_map(|sid| server_states.get(&sid).map(|s| (sid, s.channels.keys().cloned().collect())))
        .collect();
    let multi_device = !super::resolver::devices_for(local_peer).is_empty();
    let convos: Vec<String> = dm_peers.iter().map(|d| super::resolver::resolve(d)).collect();
    let (path, pass) = (db_path.to_string(), db_passphrase.to_string());
    let (channel_ts, anchors) = tokio::task::spawn_blocking(move || {
        let Ok(store) = crate::storage::MessageStore::lease(&path, &pass) else {
            return (HashMap::new(), Vec::new());
        };
        let channel_ts: HashMap<String, Vec<(String, i64)>> = channels
            .into_iter()
            .map(|(sid, cids)| {
                let ts = cids
                    .into_iter()
                    .map(|cid| {
                        let at = store.get_latest_channel_timestamp(&sid, &cid).unwrap_or(None).unwrap_or(0);
                        (cid, at)
                    })
                    .collect();
                (sid, ts)
            })
            .collect();
        let anchors: Vec<(i64, Option<GapDigest>)> =
            convos.iter().map(|c| store.dm_sync_anchor(c, multi_device)).collect();
        (channel_ts, anchors)
    })
    .await
    .unwrap_or_default();

    for (sid, device) in server_peers {
        let Some(state) = server_states.get(sid) else { continue };
        let ask = crdt_resync.sync_ask(state, device, Some(nonce), mls.and_then(|m| m.epoch(sid).ok()));
        super::frame_budget::pace_carried(budget, ws_cmd_tx, local_peer, device, &ask);
        sync_coordinator.register_peer(sid, device, channel_ts.get(sid).cloned().unwrap_or_default());
    }
    for (device, (since_timestamp, gap)) in dm_peers.iter().zip(anchors) {
        super::olm_lane::carry(
            ws_cmd_tx, device, None,
            &HavenMessage::DmSyncRequest { since_timestamp, both_directions: multi_device, gap },
            super::olm_lane::NoSession::Drop,
        );
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
        hollow_log!("[HOLLOW-CRDT] Creating channel {channel_id} in server {server_id}");

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

// ── 4b. ResetInviteLink ───────────────────────────────────────────────

/// The owner's invite reset: a new join key, so every invite link made before it stops
/// working; the fold makes the lock due to move at once, as a kick does.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_reset_invite_link(
    server_states: &mut ServerStates,
    mls: &mut Option<MlsManager>,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    local_peer_str: &str,
    server_id: String,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) -> bool {
    let Some(secret) = super::sealed_box::new_secret() else { return false };
    let secret = crate::crdt::operations::JoinSecret(hex::encode(secret.as_slice()));
    author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        OpGate::Owner,
        Some("Only the owner can reset the invite link"),
        CrdtPayload::JoinKeySet { secret },
        "Resetting the invite link",
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
    } else if key == crate::crdt::server_state::VOICE_TEXT_CHAT_KEY {
        "Permission denied: cannot manage channels"
    } else {
        "Permission denied: changing server settings needs the Manage Server permission"
    };
    let adult = key == "is_nsfw" && value == "true";
    let public_before: Vec<String> = server_states
        .get(&server_id)
        .filter(|_| adult)
        .map(|s| s.public_channels().map(|c| c.channel_id.clone()).collect())
        .unwrap_or_default();
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

    // An age-restricted server has no public channels: guests lose them at once, and
    // an actor who may manage channels clears the flags too. The read-time rule keeps
    // them closed whoever flips it; lifting it reopens any flag left on.
    if adult {
        let flagged: Vec<String> = server_states
            .get(&server_id)
            .map(|s| s.channels.values().filter(|c| c.is_public).map(|c| c.channel_id.clone()).collect())
            .unwrap_or_default();
        for channel_id in flagged {
            author_broadcast_op(
                server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
                &server_id,
                OpGate::Perm(Permission::MANAGE_CHANNELS),
                None,
                CrdtPayload::ChannelPublicChanged { channel_id: channel_id.clone(), is_public: false },
                &format!("Closing public channel {channel_id} of an age-restricted server"),
                NetworkEvent::ServerUpdated { server_id: server_id.clone() },
                OpBroadcast::MlsFirst { mls: &mut *mls, crypto_store },
                crdt_store,
            ).await;
        }
        for channel_id in public_before {
            tell_guests_if_closed(server_states, event_tx, ws_cmd_tx, &server_id, &channel_id, true).await;
        }
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
    let op_json = serde_json::to_string(&op).ok();
    // The MLS copy goes out before the tombstone drains the members it may reach.
    if let Some(op_json) = &op_json
        && mls.as_ref().is_some_and(|m| m.has_group(&server_id))
    {
        let envelope = MessageEnvelope::CrdtOp { sid: server_id.clone(), op_json: op_json.clone() };
        if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &envelope, crypto_store, Some(&*state)) {
            hollow_log!("[HOLLOW-MLS] ServerDeleted MLS broadcast failed: {e}");
        }
    }
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
    if let Some(op_json) = op_json {
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

/// Keep the row of a join the user made. One another device of ours announced gets
/// none: a row outlives this run, and boot turns it into a master-signed ask.
pub(crate) fn save_pending_join(crdt_store: &CrdtStore, server_id: &str, pending: &PendingJoin, state: &str, reason: &str) {
    if pending.unasked() {
        return;
    }
    crdt_store.upsert_pending_join(pending_join_row(server_id, pending, state, reason));
}

/// The persisted twin of a live [`PendingJoin`], for the CrdtStore actor.
fn pending_join_row(
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
    // Nobody asked: a dialog, toast or tile would be for a server the user may have left.
    if pending.unasked() {
        hollow_log!("[HOLLOW-CRDT] Join for {server_id} that our other device announced refused: {reason}");
        return;
    }
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
    save_pending_join(crdt_store, &server_id, pending, state, &reason);
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

/// A new join ask's stamp: now, or just past our own last leave of the server while our
/// clock is still behind that leave's stamp (a co-member's clock ahead carries our HLC,
/// and so the leave, past our wall). Members refuse an ask sealed and stamped no later
/// than the leave. Capped at the drift bound the leave itself was held to.
pub(crate) fn ask_stamp(left_at: Option<u64>) -> i64 {
    let now = super::types::now_ms();
    let past_leave = left_at.map_or(now, |left| i64::try_from(left).unwrap_or(i64::MAX).saturating_add(1));
    now.max(past_leave.min(now.saturating_add(crate::crdt::hlc::MAX_DRIFT_MS as i64)))
}

/// Whether a join may start for `server_id`, logging a refusal: it becomes a room, a
/// pending row and an MLS group key, so only a server's own id shape.
pub(crate) fn joinable_server_id(server_id: &str) -> bool {
    let ok = crate::crdt::anchor::valid_server_id(server_id);
    if !ok {
        hollow_log!("[HOLLOW-SECURITY] Not joining {server_id:?}: it is no server id");
    }
    ok
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
    // The leave of ours this ask names and the one it is stamped past (`LeaveBook::ask_floor`).
    ask_floor: super::leave_book::AskFloor,
    db_path: &str,
    db_passphrase: &str,
) {
    if !joinable_server_id(&server_id) {
        return;
    }
    hollow_log!("[HOLLOW-CRDT] Joining server {server_id}");
    // A phone that hides age-restricted servers never consents to one, and knows
    // nothing yet of what this server is.
    let nsfw_confirmed = super::age_gate::join_consent_at(db_path, db_passphrase, nsfw_confirmed);
    super::age_gate::unsettle_at(db_path, db_passphrase, &server_id);
    // The request NONCE. Every answer names it, so an answer replayed out of a
    // three-day ring can never resolve the join the user made afterwards.
    let requested_at = ask_stamp(ask_floor.past_ms);
    let Some(ask) = crate::crdt::operations::JoinAsk::sign_for_invite(&server_id, requested_at, &join_key, master_keypair) else {
        hollow_log!("[HOLLOW-CRDT] Join of {server_id} refused here: its invite's join key is no key");
        return;
    };
    // Our own signed device list, built ONCE and cached for the re-sends. A member
    // serving this from the ring has never been online with us, so it is the only
    // thing that attributes the request to our MASTER rather than to this device.
    let device_list = super::roster_book::join_roster(&master_keypair.peer_id(), device_peer_id, db_path, db_passphrase);
    // The KeyPackage this join will be added with. Minted ONCE per row: a re-ask
    // refreshes the nonce and keeps the package, because the ring may already hold
    // a copy naming it. `mint_key_package` persists the private half immediately,
    // which is what keeps it usable days and one restart later.
    // A self-certifying id pins its own owner; a pin on one would only be noise.
    let owner_pin = owner_pin
        .filter(|_| !crate::crdt::anchor::is_genesis_id(&server_id))
        .or_else(|| pending_server_joins.get(&server_id).and_then(|p| p.owner_pin.clone()));
    // Only a Legacy server seats a joiner from its ring copy, and every door holder reads
    // that copy: a self-certifying id or an owner pin (a checkpoint anchor) carries none.
    let legacy_possible = !crate::crdt::anchor::is_genesis_id(&server_id) && owner_pin.is_none();
    let key_package = stored_key_package.or_else(|| {
        pending_server_joins
            .get(&server_id)
            .and_then(|p| p.key_package.clone())
    }).filter(|_| legacy_possible).or_else(|| {
        if !legacy_possible {
            return None;
        }
        let mls = mls.as_ref()?;
        match super::crypto_handler::mint_group_key_package(mls, crypto_store, &server_id, true) {
            Ok(kp) => Some(base64::engine::general_purpose::STANDARD.encode(kp)),
            Err(e) => {
                hollow_log!("[HOLLOW-MLS] Join KeyPackage mint failed for {server_id}: {e}");
                None
            }
        }
    });
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
        ask: Some(ask),
        join_key: Some(join_key),
        reply_secret,
        // A lock read a moment ago for this same join still holds.
        lock: pending_server_joins.get(&server_id).and_then(|p| p.lock.clone()).filter(|l| l.fresh()),
        card,
        avatar_b64,
        follows_leave: ask_floor.follows,
        opened_at: requested_at,
        ..Default::default()
    };
    // Persist BEFORE anything can go wrong: a crash inside the 15s live window
    // still leaves a row the boot path picks up, and a join that completes
    // deletes it.
    save_pending_join(crdt_store, &server_id, &pending, "pending", "");

    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
        room_code: server_id.clone(),
    });

    // Every copy is sealed to the door the relay's lock names: with none read yet,
    // the answer to the ask sends them.
    if pending.lock.is_some() {
        if let Some(room_peers) = ws_room_peers.get(&server_id) {
            for peer in room_peers.iter() {
                if super::join_lane::send_request(ws_cmd_tx, &server_id, device_peer_id, &mut pending, peer) {
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
    // died can be elected by everyone and answer for nobody. The re-send a window
    // later is served by every member, degrading to the old fan-out instead of a failure.
    arm_join_retry(cmd_tx, &server_id, requested_at, JOIN_RETRY_WINDOW);

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
                opened_at: requested_at,
            }).await;
        });
    }
}

/// Largest avatar a live join request carries; a bigger one arrives once we are in.
const JOIN_AVATAR_MAX_BYTES: usize = 256 * 1024;

/// How long members get to serve an ask before it goes out again, counted from the
/// first copy that went out.
const JOIN_RETRY_WINDOW: Duration = Duration::from_secs(4);

/// Look at the ask opened at `opened_at` again after `after` ([`handle_retry_pending_join`]).
fn arm_join_retry(cmd_tx: &mpsc::Sender<NodeCommand>, server_id: &str, opened_at: i64, after: Duration) {
    let cmd_tx = cmd_tx.clone();
    let server_id = server_id.to_string();
    tokio::spawn(async move {
        tokio::time::sleep(after).await;
        let _ = cmd_tx.send(NodeCommand::RetryPendingJoin { server_id, opened_at }).await;
    });
}

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
        save_pending_join(crdt_store, server_id, pending, state, &reason);
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
#[allow(clippy::too_many_arguments)]
pub(crate) fn reask_join(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    crdt_store: &CrdtStore,
    server_id: &str,
    our_device: &str,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    pending: &mut PendingJoin,
    hidden: bool,
) {
    let Some(tip) = pending.lock.as_ref().and_then(|l| l.newest()).map(|l| l.n) else { return };
    if pending.asked || pending.reasked_for == Some(tip) {
        return;
    }
    hollow_log!("[HOLLOW-CRDT] Asking again to join {server_id} from join lock {tip}");
    pending.reasked_for = Some(tip);
    pending.ask_again(server_id, super::types::now_ms(), master_keypair);
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
    save_pending_join(crdt_store, server_id, pending, state, &reason);
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
    let first_lock = !state.join_lock.has_lock();
    let Some(op) = author_op(state, crdt_store, server_id, payload) else {
        hollow_log!("[HOLLOW-CRDT] A join lock op for {server_id} did not pass our own rules");
        return;
    };
    broadcast_op_mls_first(mls, ws_cmd_tx, ws_room_peers, gossip_overlays, event_tx, state, local_peer_str, server_id, &op, crypto_store);
    // A new server's siblings are in no room of it yet, so this is how they learn it
    // exists.
    if first_lock && state.join_lock.has_lock() {
        announce_server_to_own_devices(ws_cmd_tx, local_peer_str, local_device_id, server_id, state);
    }
}

/// Tell every other device our roster counts about a server we belong to, offline ones
/// included: pinned to our inbox, an absent device gets it from the relay's buffer when
/// it next joins, with neither this device nor any member online by then.
pub(crate) fn announce_server_to_own_devices(
    ws_cmd_tx: &WsCmdTx,
    local_master: &str,
    local_device: &str,
    server_id: &str,
    state: &ServerState,
) -> usize {
    // A shell kept after our leave would have the sibling re-add our identity; the
    // recovery hold (8.8 class 3) keeps announcing.
    if state.is_deleted() || !state.keeps_peer(local_master) {
        return 0;
    }
    let own_inbox = format!("inbox:{local_master}");
    let announce = HavenMessage::SiblingServerAnnounce {
        server_id: server_id.to_string(),
        owner: state.anchor_owner(),
        join_key: state.join_public_text(),
        fresh: true,
    };
    let devices: Vec<String> = super::resolver::devices_for(local_master)
        .into_iter()
        .filter(|d| d != local_device && !super::resolver::is_revoked(d))
        .collect();
    for device in &devices {
        super::olm_lane::carry(ws_cmd_tx, device, Some(&own_inbox), &announce, super::olm_lane::NoSession::Queue);
    }
    if !devices.is_empty() {
        hollow_log!("[HOLLOW-CRDT] Announced server {server_id} to {} sibling device(s), online or not", devices.len());
    }
    devices.len()
}

/// Ask each device our roster counts that the relay did not list in our inbox as we
/// came back for its state. One sitting in its session's grace still lists us when it
/// resumes, so it never sees us arrive: the ask waits in its session and it answers.
/// A late ask is dropped as stale. Returns how many were asked.
pub(crate) fn ask_absent_siblings(
    ws_cmd_tx: &WsCmdTx,
    local_master: &str,
    local_device: &str,
    present: &std::collections::HashSet<String>,
) -> usize {
    let own_inbox = format!("inbox:{local_master}");
    let devices: Vec<String> = super::resolver::devices_for(local_master)
        .into_iter()
        .filter(|d| d != local_device && d != local_master && !present.contains(d) && !super::resolver::is_revoked(d))
        .collect();
    for device in &devices {
        super::olm_lane::carry(
            ws_cmd_tx, device, Some(&own_inbox), &HavenMessage::SiblingStateSyncRequest, super::olm_lane::NoSession::Drop,
        );
    }
    if !devices.is_empty() {
        hollow_log!("[HOLLOW-SYNC] Back in our inbox: asked {} absent sibling device(s) for their state", devices.len());
    }
    devices.len()
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

/// Re-send a still-pending `ServerJoinRequest` to every peer in the server room, a
/// window after its first copy went out. Members gate the FIRST request to their
/// elected coordinator; a repeat inside their retry window is served by all of them,
/// so this is what rescues a join whose elected coordinator turned out to be gone.
#[allow(clippy::too_many_arguments)]
pub(crate) fn handle_retry_pending_join(
    pending_server_joins: &mut HashMap<String, PendingJoin>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    cmd_tx: &mpsc::Sender<NodeCommand>,
    our_device: &str,
    server_id: String,
    opened_at: i64,
    hidden: bool,
) {
    let Some(pending) = pending_server_joins.get_mut(&server_id) else { return };
    if pending.opened_at != opened_at || pending.asked {
        return;
    }
    let waited = pending.first_sent_at.map_or(Duration::ZERO, |t| t.elapsed());
    if waited < JOIN_RETRY_WINDOW {
        // A parked join has no timer: a member coming back serves it.
        if !pending.parked {
            arm_join_retry(cmd_tx, &server_id, opened_at, JOIN_RETRY_WINDOW - waited);
        }
        return;
    }
    let room_peers = ws_room_peers.get(&server_id);
    hollow_log!(
        "[HOLLOW-CRDT] Join for {server_id} still pending after the coordinator window — re-asking {} peer(s){}",
        room_peers.map_or(0, |p| p.len()),
        if hidden { " and the room that hides them" } else { "" },
    );
    // A locked room shows a joiner none of its members, so the room is asked instead.
    if hidden {
        super::join_lane::send_request_to_room(ws_cmd_tx, &server_id, our_device, pending);
    }
    for peer in room_peers.into_iter().flatten() {
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
            seen: None,
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
        carry_kick_notice(ws_cmd_tx, ws_room_peers, &server_id, &peer_id, &op);

        if let Some(mls_mgr) = mls {
            mls_remove_identity_and_broadcast(
                mls_mgr, event_tx, ws_cmd_tx, crypto_store, &server_id, &peer_id,
                true, false, crate::node::crypto_handler::is_anchor_owner(state, local_peer_str),
                &format!("Removed all leaves of {peer_id} from MLS group, epoch rotated"),
            ).await;

            // Option B: also drop the kicked identity from every restricted-channel
            // subgroup so it loses access there too (not just the server group).
            let target_master = super::resolver::resolve(&peer_id);
            crate::node::crypto_handler::remove_identity_from_subgroups(
                mls_mgr, event_tx, ws_cmd_tx, crypto_store,
                state, &server_id, &target_master, local_peer_str,
            ).await;
        }
    }
    false
}

// ── 10a. RevokeDevice (Step 7) ────────────────────────────────────────

/// Revoke one of OUR OWN devices (manual, lost or stolen). Bumps our master-signed
/// device list with the target tombstoned, re-broadcasts it so friends stop
/// encrypting to the revoked device, and returns every removed device id (the target
/// first) so the caller drops their Olm sessions and MLS leaves. `None` when rejected.
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
        // Every co-member hears it in each server room, so a member who is no contact
        // learns the change before folding anything the removed device writes.
        if let Ok(data) = serde_json::to_vec(&HavenMessage::RosterNotice { roster }) {
            super::roster_book::notice_into_server_rooms(ws_cmd_tx, &data, server_states.keys());
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

/// This device removes `target_device` from our roster, or refuses its pending join,
/// signed into our roster here only: the settling and its marks leave before the
/// removal does (section 8.3 steps 3 to 5), through [`publish_revocation`].
#[allow(clippy::too_many_arguments)]
pub(crate) async fn revoke_device_locally(
    event_tx: &mpsc::Sender<NetworkEvent>,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    target_device: &str,
    mode: super::roster_book::RemoveMode,
    with_dependents: bool,
    db_path: &str,
    db_passphrase: &str,
) -> Option<Vec<String>> {
    match super::roster_book::remove(master_keypair, device_keypair, target_device, mode, with_dependents, db_path, db_passphrase) {
        Ok((_, _, gone)) => Some(gone),
        Err(e) => {
            let _ = event_tx.send(NetworkEvent::Error { message: e }).await;
            None
        }
    }
}

/// Publish a removal [`revoke_device_locally`] signed; the removed devices learn it
/// first, while the relay still routes to them.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn publish_revocation(
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server_states: &HashMap<String, ServerState>,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    master_peer_str: &str,
    local_peer_str: &str,
    device_peer_id: &str,
    is_invisible: bool,
    gone: &[String],
    db_path: &str,
    db_passphrase: &str,
) {
    announce_roster_change(
        ws_cmd_tx, ws_room_peers, server_states, master_keypair, local_peer_str,
        device_peer_id, is_invisible, gone, db_path, db_passphrase,
    );
    let _ = event_tx.send(NetworkEvent::DeviceListUpdated {
        master_peer_id: master_peer_str.to_string(),
    }).await;
}

/// Section 8.2 on the remover, before a retire's removal is published: every server we
/// hold (or `only` that one) gets the `DeviceRetired` ops naming what that device wrote
/// there and we folded, so its history keeps counting once the removal reaches a member.
#[allow(clippy::too_many_arguments)]
pub(crate) fn retire_device_ops(
    server_states: &mut ServerStates,
    mls: &mut Option<MlsManager>,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    event_tx: &EventTx,
    local_peer_str: &str,
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device: &str,
    only: Option<&str>,
    posts_of: &dyn Fn(&str) -> Option<i64>,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) {
    for (server_id, state) in server_states.iter_mut() {
        if only.is_some_and(|s| s != server_id)
            || super::conference::is_conference_sid(server_id)
            || state.is_deleted()
            || !state.is_member(local_peer_str)
        {
            continue;
        }
        for payload in state.retire_payloads(local_peer_str, device, posts_of(server_id)) {
            let Some(op) = author_op(state, crdt_store, server_id, payload) else {
                hollow_log!("[HOLLOW-CRDT] Our own rules refuse the retire of {device} in {server_id}");
                break;
            };
            broadcast_op_mls_first(mls, ws_cmd_tx, ws_room_peers, gossip_overlays, event_tx, state, local_peer_str, server_id, &op, crypto_store);
        }
        if state.current_owner().as_deref() == Some(local_peer_str) {
            co_sign_marks(state, mls, ws_cmd_tx, ws_room_peers, gossip_overlays, event_tx, local_peer_str, device_keypair, server_id, device, None, crypto_store, crdt_store);
        }
    }
}

/// Section 8.5: our device co-signs the settle marks a removed device signed, so they
/// keep counting once it does not.
#[allow(clippy::too_many_arguments)]
fn co_sign_marks(
    state: &mut ServerState,
    mls: &mut Option<MlsManager>,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    event_tx: &EventTx,
    local_peer_str: &str,
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    server_id: &str,
    removed: &str,
    before: Option<(u64, &crate::crdt::settle::SeenAt)>,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) {
    for stamp in state.co_sign_stamps(removed, &device_keypair.peer_id(), before) {
        let Some((op, ingested)) = state.author_settle_sign(&stamp, device_keypair) else { continue };
        crdt_store.persist(ingested.delta(server_id));
        crdt_store.save_state_snapshot(server_id.to_string(), state);
        broadcast_op_mls_first(mls, ws_cmd_tx, ws_room_peers, gossip_overlays, event_tx, state, local_peer_str, server_id, &op, crypto_store);
    }
}

/// Section 8.3 after a lost-or-stolen removal of `dropped` (the device and the vouchees
/// removed with it) as of `t_ms`: every server we own past the cut gets a settling from
/// its restore point, every other one our retires naming what those devices did that we
/// stored before T. `before` holds each server's view from before the removal. Returns
/// each settling with the members it brought back (`floor::FloorDesk::note_settled`).
#[allow(clippy::too_many_arguments)]
pub(crate) fn settle_lost_devices(
    server_states: &mut ServerStates,
    before: &HashMap<String, std::sync::Arc<crate::crdt::authority::AuthorityView>>,
    mls: &mut Option<MlsManager>,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    event_tx: &EventTx,
    local_peer_str: &str,
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    dropped: &[String],
    t_ms: u64,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
    db_path: &str,
    db_passphrase: &str,
) -> Vec<(String, std::collections::BTreeSet<String>, Vec<crate::crdt::operations::CrdtOp>)> {
    let mut settled = Vec::new();
    let Ok(store) = crate::storage::MessageStore::lease(db_path, db_passphrase) else { return settled };
    let roster = store.load_roster(local_peer_str).ok().flatten();
    for (server_id, state) in server_states.iter_mut() {
        if !state.cut || super::conference::is_conference_sid(server_id) || state.is_deleted() || !state.is_member(local_peer_str) {
            continue;
        }
        let Some(view) = before.get(server_id) else { continue };
        let t_ms = state.lost_t(t_ms);
        let seen = store.op_seen_ms(server_id).unwrap_or_default();
        let mut ops = Vec::new();
        if state.current_owner().as_deref() == Some(local_peer_str) {
            for device in dropped {
                co_sign_marks(
                    state, mls, ws_cmd_tx, ws_room_peers, gossip_overlays, event_tx, local_peer_str, device_keypair, server_id, device,
                    Some((t_ms, &seen)), crypto_store, crdt_store,
                );
            }
            let Some(roster) = roster.clone() else { continue };
            let settling = crate::crdt::settle::Settling { before: view.clone(), dropped, t_ms, seen: &seen, roster };
            let counted = super::floor::counted_members(state);
            let written = write_settling(state, server_id, &settling, local_peer_str, device_keypair, crdt_store);
            settled.push((server_id.clone(), super::floor::settled_newcomers(&counted, state, local_peer_str), written.clone()));
            ops.extend(written);
        } else {
            for device in dropped {
                for payload in state.lost_retire_payloads(local_peer_str, device, t_ms, &seen) {
                    match author_op(state, crdt_store, server_id, payload) {
                        Some(op) => ops.push(op),
                        None => hollow_log!("[HOLLOW-CRDT] Our own rules refuse the retire of {device} in {server_id}"),
                    }
                }
            }
        }
        for op in &ops {
            broadcast_op_mls_first(mls, ws_cmd_tx, ws_room_peers, gossip_overlays, event_tx, state, local_peer_str, server_id, op, crypto_store);
        }
    }
    settled
}

/// Our settling of `server_id` as our new base, persisted; the ops to publish.
fn write_settling(
    state: &mut ServerState,
    server_id: &str,
    settling: &crate::crdt::settle::Settling<'_>,
    local_peer_str: &str,
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    crdt_store: &CrdtStore,
) -> Vec<crate::crdt::operations::CrdtOp> {
    let Some((settled, ingested)) = state.author_settling(local_peer_str, settling, device_keypair) else {
        hollow_log!("[HOLLOW-CRDT] Could not settle {server_id} after the removal");
        return Vec::new();
    };
    for i in &ingested {
        crdt_store.persist(i.delta(server_id));
    }
    crdt_store.save_state_snapshot(server_id.to_string(), state);
    settled
}

/// Section 8.3, two settlings at once: on a server we own where a counted sibling's
/// settling off our base's line drops a device ours does not, one settling for both, a
/// child of the winner. `tried` keeps each rival set to one attempt.
#[allow(clippy::too_many_arguments)]
pub(crate) fn merge_rival_settlings(
    server_states: &mut ServerStates,
    mls: &mut Option<MlsManager>,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    event_tx: &EventTx,
    local_peer_str: &str,
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
    db_path: &str,
    db_passphrase: &str,
    tried: &mut std::collections::HashSet<String>,
) {
    for (server_id, state) in server_states.iter_mut() {
        if !state.cut || super::conference::is_conference_sid(server_id) || state.is_deleted() || state.current_owner().as_deref() != Some(local_peer_str) {
            continue;
        }
        let Some((dropped, t_ms)) = state.merged_settling() else { continue };
        let ids: Vec<String> = state.rival_settles.iter().map(|st| st.id()).collect();
        if !tried.insert(format!("{server_id}:{}", ids.join(","))) {
            continue;
        }
        if tried.len() > 256 {
            tried.clear();
        }
        let Ok(store) = crate::storage::MessageStore::lease(db_path, db_passphrase) else { return };
        let Some(roster) = store.load_roster(local_peer_str).ok().flatten() else { return };
        let seen = store.op_seen_ms(server_id).unwrap_or_default();
        let before = state.view_counting(local_peer_str, &dropped);
        let settling = crate::crdt::settle::Settling { before, dropped: &dropped, t_ms, seen: &seen, roster };
        for op in write_settling(state, server_id, &settling, local_peer_str, device_keypair, crdt_store) {
            broadcast_op_mls_first(mls, ws_cmd_tx, ws_room_peers, gossip_overlays, event_tx, state, local_peer_str, server_id, &op, crypto_store);
        }
    }
}

/// Section 8.2 step 1 (M4): before a retire, ask member identities of every server we hold
/// past the cut (and the retiring device itself, which holds its own ops); returns per
/// server how many identities other than ours were asked.
#[allow(clippy::too_many_arguments)]
pub(crate) fn ask_retire_round(
    server_states: &ServerStates,
    crdt_resync: &mut super::crdt_resync::CrdtResync,
    frame_budget: &mut super::frame_budget::FrameBudget,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    local_peer_str: &str,
    device_peer_id: &str,
    retiring: &str,
    lost_t_ms: Option<u64>,
) -> Vec<(String, usize)> {
    let mut asked = Vec::new();
    for (server_id, state) in server_states {
        if !state.cut || super::conference::is_conference_sid(server_id) || state.is_deleted() || !state.is_member(local_peer_str) {
            continue;
        }
        let mut room: Vec<&String> = ws_room_peers.get(server_id).into_iter().flatten().filter(|d| state.is_member(d)).collect();
        room.sort();
        let mut identities: Vec<String> = Vec::new();
        let mut devices: Vec<&String> = Vec::new();
        for d in room {
            // A retiring device hands over what only it holds; a lost one is never asked.
            if d == retiring {
                if lost_t_ms.is_none() {
                    devices.push(d);
                }
                continue;
            }
            let identity = super::resolver::resolve(d);
            if super::resolver::same_identity(d, local_peer_str) || identities.contains(&identity) || identities.len() >= super::retire_round::ASKED {
                continue;
            }
            identities.push(identity);
            devices.push(d);
        }
        // Section 8.3 step 1: a lost removal's asks name the restore point R as their base,
        // so answerers send what R does not dominate.
        let restore = lost_t_ms.and_then(|t| state.restore_for(t));
        for device in devices {
            let ask = match &restore {
                Some(r) => crdt_resync.sync_ask_on_base(state, device, None, r, Default::default()),
                None => crdt_resync.sync_ask(state, device, None, None),
            };
            super::frame_budget::pace_carried(frame_budget, ws_cmd_tx, device_peer_id, device, &ask);
        }
        asked.push((server_id.clone(), identities.len()));
    }
    asked
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
    leave_book: &mut super::leave_book::LeaveBook,
    door: Option<(u64, zeroize::Zeroizing<[u8; 32]>)>,
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
        state.witness_own_ask(local_peer_str);
        let Some(op) = author_op(state, crdt_store, &server_id, CrdtPayload::MemberRemoved {
            peer_id: local_peer_str.to_string(),
            seen: None,
        }) else {
            return deny(event_tx, "You can't leave this server right now").await;
        };

        // Leaving is an identity-level action: our own devices drop the server on it
        // at once. The members get it from the leave book, which keeps the op, the room
        // and its door until the owner holds it: until then the server counts us.
        if let Ok(op_json) = serde_json::to_string(&op) {
            let msg = HavenMessage::CrdtOpBroadcast { server_id: server_id.clone(), op_json };
            super::olm_lane::carry_to_every_own_device(ws_cmd_tx, ws_room_peers, local_peer_str, local_device_id, &msg);
        }
        let opened = super::leave_book::opened_by(Some(state), local_peer_str);
        if let Some(dropped) = leave_book.begin(&server_id, &op, state.anchor_owner(), targets, door, local_device_id, opened) {
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom { room_code: dropped });
        }

        // MLS: remove ALL of OUR leaves from the group (this device + any sibling
        // device's leaf — leaving the server means none of our devices stay).
        if let Some(mls_mgr) = mls {
            mls_remove_identity_and_broadcast(
                mls_mgr, event_tx, ws_cmd_tx, crypto_store, &server_id, local_peer_str,
                false, true, crate::node::crypto_handler::is_anchor_owner(state, local_peer_str),
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
    if !leave_book.holds_room(&server_id) {
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom {
            room_code: server_id.clone(),
        });
    }
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
            seen: None,
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
        carry_kick_notice(ws_cmd_tx, ws_room_peers, &server_id, &peer_id, &op);

        if let Some(mls_mgr) = mls {
            mls_remove_identity_and_broadcast(
                mls_mgr, event_tx, ws_cmd_tx, crypto_store, &server_id, &peer_id,
                true, false, crate::node::crypto_handler::is_anchor_owner(state, local_peer_str),
                &format!("Removed all leaves of banned {peer_id} from MLS group"),
            ).await;

            // Option B: also drop the banned identity from every restricted-channel subgroup.
            let target_master = super::resolver::resolve(&peer_id);
            crate::node::crypto_handler::remove_identity_from_subgroups(
                mls_mgr, event_tx, ws_cmd_tx, crypto_store,
                state, &server_id, &target_master, local_peer_str,
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

#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_set_channel_voice_chat(
    server_states: &mut ServerStates,
    mls: &mut Option<MlsManager>,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    gossip_overlays: &mut GossipOverlays,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    mode: crate::crdt::server_state::VoiceChat,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
) -> bool {
    author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        OpGate::Perm(Permission::MANAGE_CHANNELS),
        Some("Permission denied: cannot manage channels"),
        CrdtPayload::ChannelVoiceChatChanged { channel_id: channel_id.clone(), mode },
        &format!("Setting voice_chat={mode:?} on {channel_id}"),
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
    let was_public = server_states.get(&server_id).is_some_and(|s| s.is_channel_public(&channel_id));
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

    tell_guests_if_closed(server_states, event_tx, ws_cmd_tx, &server_id, &channel_id, was_public).await;

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
    let was_public = server_states.get(&server_id).is_some_and(|s| s.is_channel_public(&channel_id));
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

    tell_guests_if_closed(server_states, event_tx, ws_cmd_tx, &server_id, &channel_id, was_public).await;

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

/// Why an age-restricted server's channel cannot be made public.
pub(crate) const PUBLIC_OFF_FOR_ADULT_SERVERS: &str = "Public channels are off for age-restricted servers";

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
    if is_public && server_states.get(&server_id).is_some_and(|s| s.is_nsfw()) {
        hollow_log!("[HOLLOW-CRDT] REFUSED set_channel_public on age-restricted server {server_id}");
        let _ = event_tx.send(NetworkEvent::Error {
            message: PUBLIC_OFF_FOR_ADULT_SERVERS.to_string(),
        }).await;
        return true;
    }
    if is_public
        && server_states
            .get(&server_id)
            .and_then(|s| s.channels.get(&channel_id))
            .is_some_and(crate::crdt::server_state::ChannelInfo::restricted)
    {
        hollow_log!("[HOLLOW-CRDT] REFUSED set_channel_public on restricted channel {channel_id}");
        let _ = event_tx.send(NetworkEvent::Error {
            message: "Only a channel everyone can see can be public".to_string(),
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

    if let Some(ch) = server_states.get(&server_id).and_then(|s| s.channels.get(&channel_id)) {
        tell_guests(event_tx, ws_cmd_tx, &server_id, ch, is_public).await;
    }
    false
}

/// Tell the room's guests, who hold no server state, that a channel opened or closed,
/// and our own guest browser too. Only the author does. A closing channel keeps its
/// name and category out of the clear: a guest needs only its id to drop it.
async fn tell_guests(
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    server_id: &str,
    ch: &crate::crdt::server_state::ChannelInfo,
    is_public: bool,
) {
    let notify = HavenMessage::PublicChannelConfigChanged {
        server_id: server_id.to_string(),
        channel_id: ch.channel_id.clone(),
        is_public,
        channel_name: if is_public { ch.name.clone() } else { String::new() },
        category: if is_public { ch.category.clone() } else { None },
    };
    if let Ok(data) = serde_json::to_vec(&notify) {
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendPublic { room_code: server_id.to_string(), data });
    }
    let _ = event_tx.send(NetworkEvent::PublicChannelConfigChanged {
        server_id: server_id.to_string(),
        channel_id: ch.channel_id.clone(),
        is_public,
        channel_name: ch.name.clone(),
        category: ch.category.clone(),
    }).await;
}

/// After a visibility change: a channel that was public and is now closed leaves the
/// guests' lists.
async fn tell_guests_if_closed(
    server_states: &ServerStates,
    event_tx: &EventTx,
    ws_cmd_tx: &WsCmdTx,
    server_id: &str,
    channel_id: &str,
    was_public: bool,
) {
    let closed = server_states
        .get(server_id)
        .filter(|s| was_public && !s.is_channel_public(channel_id))
        .and_then(|s| s.channels.get(channel_id));
    if let Some(ch) = closed {
        tell_guests(event_tx, ws_cmd_tx, server_id, ch, false).await;
    }
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
    channel_asks: &mut super::channel_asks::ChannelAsks,
    frame_budget: &mut super::frame_budget::FrameBudget,
    device_peer_id: &str,
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
        let holders = super::channel_asks::holders(ws_room_peers, state, local_peer_str, &channel_id);
        if let Some(holder) = channel_asks.start(&server_id, &channel_id, &holders, std::time::Instant::now()) {
            let kind = super::channel_asks::Kind::Catch;
            ask_channel_holders(frame_budget, ws_cmd_tx, device_peer_id, vec![(server_id, channel_id, holder, kind)], db_path, db_passphrase);
        }
    }
    false
}

/// Send each `(server, channel, holder, kind)` the ask for what we miss in that channel,
/// paced to the holder's bucket: a sweep can move several asks to one holder at once.
pub(crate) fn ask_channel_holders(
    frame_budget: &mut super::frame_budget::FrameBudget,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    device_peer_id: &str,
    asks: Vec<(String, String, String, super::channel_asks::Kind)>,
    db_path: &str,
    db_passphrase: &str,
) {
    if asks.is_empty() {
        return;
    }
    let Ok(store) = crate::storage::MessageStore::lease(db_path, db_passphrase) else { return };
    for (server_id, channel_id, holder, kind) in asks {
        hollow_log!("[HOLLOW-SYNC] Asking {holder} for channel {channel_id} in {server_id} ({kind:?})");
        super::frame_budget::pace_carried(
            frame_budget, ws_cmd_tx, device_peer_id, &holder,
            &channel_ask_of(&store, &server_id, &channel_id, kind),
        );
    }
}

/// Whether a server has the channel a page names: an owner passes the read check for
/// any id, a channel that does not exist included.
pub(crate) fn channel_known(state: Option<&ServerState>, cid: &str) -> bool {
    state.is_some_and(|s| s.channels.contains_key(cid))
}

/// One channel sync page once landed: what it stored, whether to follow it (the end to
/// follow from), the hole's top to bound that next page by, and what the ask does next.
pub(crate) struct PageLanded {
    pub(crate) new_count: u32,
    pub(crate) events: Vec<NetworkEvent>,
    pub(crate) page_end: Option<ChannelPageEnd>,
    pub(crate) until: Option<i64>,
    pub(crate) heard: super::channel_asks::Heard,
}

/// Land one channel sync page from `from` in one transaction (one fsync, not one per
/// row). What it vouches for is noted in the same transaction, before its rows can move
/// a watermark, and only from a page of an ask we opened, of a channel the server has
/// (`channel_known`), with the rows ingest accepted. `messages` are filtered already;
/// `page_end` is where the page ended as served.
#[allow(clippy::too_many_arguments)]
pub(crate) fn land_channel_page(
    store: &crate::storage::MessageStore,
    channel_asks: &mut super::channel_asks::ChannelAsks,
    sid: &str,
    cid: &str,
    from: &str,
    channel_known: bool,
    messages: &[SyncMessageItem],
    has_more: Option<bool>,
    held_from: Option<i64>,
    page_end: Option<ChannelPageEnd>,
    local_peer: &str,
) -> PageLanded {
    use super::channel_asks::{Kind, Page};
    let now = std::time::Instant::now();
    let asked = channel_asks.page_held(sid, cid, from, held_from, now);
    let (held, kind) = asked.unwrap_or((None, Kind::Catch));
    let _ = store.begin_transaction();
    let before = store.channel_holds_rows(sid, cid);
    let mut pk_cache = PkCache::new();
    let (mut new_count, mut events, mut landed) = (0u32, Vec::new(), Vec::new());
    for msg in messages {
        let (inserted, item_events, accepted) = ingest_synced_channel_item_judged(store, sid, cid, msg, local_peer, &mut pk_cache);
        new_count += inserted;
        events.extend(item_events);
        if accepted {
            landed.push(msg.ts);
        }
    }
    let noted = match held.filter(|_| asked.is_some() && channel_known) {
        Some(held) => before.and_then(|before| {
            store.note_held_page(sid, cid, held, before, &landed, kind == Kind::Hole, super::types::now_ms())
        }),
        None => Ok(()),
    };
    // Unnoted, its rows would move watermarks past what we lack: the page goes whole.
    let land = match noted.and_then(|()| store.commit_transaction()) {
        Ok(()) => true,
        Err(e) => {
            hollow_log!("[HOLLOW-SYNC] Dropped a page of {cid}: {e}");
            let _ = store.rollback_transaction();
            false
        }
    };
    if !land {
        new_count = 0;
        events.clear();
    }
    let hole = store.channel_hole(sid, cid).map(|h| h.below);
    let page = Page::of(has_more, page_end.as_ref());
    let heard = channel_asks.hear(sid, cid, from, page, held, hole, now);
    // After the rows: a crash between leaves the hole, asked for again.
    if land && heard.filled {
        let _ = store.close_channel_hole(sid, cid);
    } else if let (true, Kind::Hole, None, Page::Next(end), Some(top)) = (land, kind, held, page, landed.iter().max()) {
        // Filled only up to the newest row that landed: a forged row fills nothing.
        let _ = store.raise_channel_hole(sid, cid, end.min(*top));
    }
    let until = (kind == Kind::Hole).then(|| store.channel_hole(sid, cid).map(|h| h.below)).flatten();
    PageLanded { new_count, events, page_end: page_end.filter(|_| heard.follow && land), until, heard }
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
    opened_at: i64,
    crdt_store: &CrdtStore,
) {
    // Already gone = the join completed or was discarded; already parked = a
    // stale timer from an earlier attempt. Both are no-ops.
    let Some(pending) = pending_server_joins.get_mut(&server_id) else { return };
    // A window armed for an earlier ask to this server is not this ask's to end.
    if pending.opened_at != opened_at {
        return;
    }
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
    save_pending_join(crdt_store, &server_id, pending, state, &reason);
    if pending.refused.is_none() {
        let _ = event_tx.send(NetworkEvent::ServerJoinParked {
            server_id,
        }).await;
    }
}

// ── 17a. A join our identity left before it completed ────────────────

/// End a join another device of ours announced, for a server our identity has since
/// left: no join of ours may outlive our own leave. A state the join adopted goes with
/// it; the room stays only while a leave of this device still needs it.
#[allow(clippy::too_many_arguments)]
pub(crate) fn end_join_we_left(
    pending_server_joins: &mut HashMap<String, PendingJoin>,
    server_states: &mut HashMap<String, ServerState>,
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    crdt_store: &CrdtStore,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    keep_room: bool,
    server_id: &str,
) {
    let Some(pending) = pending_server_joins.remove(server_id) else { return };
    hollow_log!("[HOLLOW-CRDT] Our identity left {server_id}: ending the join our other device announced");
    if server_states.remove(server_id).is_some() {
        crdt_store.delete_server(server_id.to_string());
    }
    if !keep_room {
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom { room_code: server_id.to_string() });
    }
    discard_join_key_package(mls, crypto_store, server_id, pending.key_package.as_deref());
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

/// Handle `MessageEnvelope::CrdtOp` (MLS path) — permission-checked CRDT op application.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_crdt_op(
    server_states: &mut ServerStates,
    crdt_resync: &mut super::crdt_resync::CrdtResync,
    _bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &EventTx,
    sid: String,
    op_json: String,
    crdt_store: &CrdtStore,
    ws_cmd_tx: &WsCmdTx,
    carrier: &str,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    us: &str,
) {
    let Some(state) = server_states.get_mut(&sid) else { return };
    let Some(op) = super::crdt_resync::read_live_op(crdt_resync, Some(state), &sid, &op_json) else { return };
    // The ONE ingest (ServerState::ingest_remote): the author's
    // signature, the clock bound, then the shared permission matrix. It
    // validates op.author (the creator), never the transport sender.
    let ingested = state.ingest_remote(std::slice::from_ref(&op));
    // A live op the base decides but its parent did not is kept as a dormant row only.
    crdt_store.persist(ingested.delta(&sid));
    crdt_resync.want_rosters(state, &ingested.wanted, carrier, ws_room_peers.get(&sid), us, std::time::Instant::now());
    if ingested.admitted.is_empty() && !ingested.rebuilt {
        return;
    }
    let op_is_new = ingested.admitted.iter().any(|o| o.author == op.author && o.hlc == op.hlc);
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
            CrdtPayload::MemberRemoved { peer_id, .. } => {
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
            | CrdtPayload::ChannelVoiceChatChanged { .. }
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
            | CrdtPayload::StickerRemoved { .. }
            | CrdtPayload::DeviceRetired { .. }
            | CrdtPayload::SettleSign { .. }
            | CrdtPayload::FloorMark { .. } => {
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

/// Handle `MessageEnvelope::ChannelSyncBatch` (MLS path), once [`land_channel_page`]
/// landed it: emit its events, follow it, and ask what the ask asks next.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_channel_sync_batch(
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    sender_peer_id: &str,
    sid: String,
    cid: String,
    has_more: Option<bool>,
    landed: PageLanded,
    db_path: &str,
    db_passphrase: &str,
) {
    // After the commit: Dart re-reads the rows these name.
    for ev in landed.events {
        let _ = event_tx.send(ev).await;
    }
    let Ok(store) = crate::storage::MessageStore::lease(db_path, db_passphrase) else { return };
    if has_more == Some(true) {
        match landed.page_end {
            Some(end) => super::olm_lane::carry(
                ws_cmd_tx, sender_peer_id, None,
                &channel_next_page_request(&store, &sid, &cid, end, landed.until),
                super::olm_lane::NoSession::Queue,
            ),
            None => hollow_log!("[HOLLOW-SYNC] Not following the channel page for {cid} from {sender_peer_id}; the next catch-up takes the rest"),
        }
    }
    if let Some(kind) = landed.heard.again {
        super::olm_lane::carry(
            ws_cmd_tx, sender_peer_id, None,
            &channel_ask_of(&store, &sid, &cid, kind),
            super::olm_lane::NoSession::Queue,
        );
    }
    if has_more != Some(true) {
        let _ = event_tx.send(NetworkEvent::MessageSyncCompleted {
            server_id: sid,
            new_message_count: landed.new_count,
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
    let (inserted, events, _) = ingest_synced_channel_item_judged(store, sid, cid, msg, local_peer, pk_cache);
    (inserted, events)
}

/// [`ingest_synced_channel_item`], and whether the item passed every gate (a row we
/// already held included): only such a row may say where a page vouches from.
pub(crate) fn ingest_synced_channel_item_judged(
    store: &crate::storage::MessageStore,
    sid: &str,
    cid: &str,
    msg: &SyncMessageItem,
    local_peer: &str,
    pk_cache: &mut PkCache,
) -> (u32, Vec<NetworkEvent>, bool) {
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
        return (0, Vec::new(), false);
    }
    let scope = super::message_ops::RowScope::Channel { sid, cid, signer: &msg.s };
    if !super::message_ops::change_may_touch_row(store, &scope, msg.mid.as_deref()) {
        return (0, Vec::new(), false);
    }
    // History this device cleared: neither the row nor anything riding it (file
    // header, reactions, hidden flag, card) is stored or shown again.
    if store.channel_floor_refuses(sid, cid, msg.ts, msg.mid.as_deref()) {
        return (0, Vec::new(), false);
    }
    // A post's date and slots never change: an item naming a post we hold with others
    // speaks for no version of it, and the gate judged it (and all riding it) at a
    // date the row does not hold (section 13).
    if let Some(row) = msg.mid.as_deref().and_then(|mid| store.get_channel_message_sig_row(mid))
        && !item_matches_row(msg, &row)
    {
        hollow_log!("[HOLLOW-SECURITY] REJECTED synced item for {:?} in {sid}/{cid}: its date or slots differ from the post we hold", msg.mid);
        return (0, Vec::new(), false);
    }
    let sig_verified = sig_check == BackfillSig::Valid;
    // Multi-device: a message authored by ANY of our own devices is ours.
    let is_mine = super::resolver::same_identity(&msg.s, local_peer);
    let (inserted, mut events) = upsert_synced_channel_message(store, sid, cid, msg, is_mine, sig_verified);
    events.extend(apply_sync_item_extras(store, sid, cid, msg, is_mine, pk_cache));
    (inserted, events, true)
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
            if let (Some(dev), Some(mid)) = (super::post_proof::item_proof(sid, cid, msg), &msg.mid) {
                let _ = store.set_channel_post_proof(mid, dev);
            }
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
            super::post_proof::item_proof(sid, cid, msg),
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
    if already_exists {
        adopt_post_proof(store, sid, cid, msg);
    }

    // The card the item's signature covers. Deliberately runs on EVERY branch: a
    // fresh insert, a row that reached us card-less by another path, and an edited
    // row alike should end up holding it. `sig_verified` because a card is content.
    if sig_verified
        && let (Some(lp), Some(mid)) = (msg.lp.as_deref(), &msg.mid)
        && apply_synced_channel_card(store, sid, cid, mid, msg, lp)
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

/// A held row with no proof takes the item's when it proves the version the row holds
/// (its date and slots match: `item_matches_row`).
fn adopt_post_proof(store: &crate::storage::MessageStore, sid: &str, cid: &str, msg: &SyncMessageItem) {
    let (Some(mid), Some(dev)) = (msg.mid.as_deref(), super::post_proof::item_proof(sid, cid, msg)) else { return };
    if store.get_channel_message_sig_row(mid).is_some_and(|r| r.text == msg.t && r.edited_at == msg.edited_at) {
        let _ = store.set_channel_post_proof(mid, dev);
    }
}

/// Whether a synced item names the post `row` holds: the same date and slots.
fn item_matches_row(msg: &SyncMessageItem, row: &crate::storage::messages::MessageSigRow) -> bool {
    row.timestamp == msg.ts
        && row.reply_to_mid == msg.reply_to
        && row.file_id == msg.file_id
        && row.order_us == msg.order_us
        && row.album_id == msg.album
}

/// Land the card a verified item carries on channel row `mid`: within its bounds,
/// for the text the row holds, and only when newer than the row's card or edit (the
/// date its proof signs). A card without a proof never replaces one a proof holds.
fn apply_synced_channel_card(store: &crate::storage::MessageStore, sid: &str, cid: &str, mid: &str, msg: &SyncMessageItem, lp: &crate::node::LinkPreviewRef) -> bool {
    if !super::link_preview::card_within_bounds(lp) {
        hollow_log!("[HOLLOW-SECURITY] REJECTED synced card for {mid} in {sid}/{cid}: over its bounds");
        return false;
    }
    let Some(row) = store.get_channel_message_sig_row(mid) else { return false };
    if row.text != msg.t || row.link_preview.as_ref() == Some(lp) {
        return false;
    }
    let proof = super::post_proof::item_card_proof(sid, cid, msg);
    if proof.is_none() && store.change_proofs(&[mid], &[]).cards.contains_key(mid) {
        return false;
    }
    let Some(lp_json) = serde_json::to_string(lp).ok() else { return false };
    let applied = store.update_channel_link_preview_and_sig(mid, Some(&lp_json), msg.sig.as_deref(), msg.pk.as_deref(), proof.map(|p| p.at));
    if !matches!(applied, Ok(true)) {
        return false;
    }
    let _ = store.set_channel_card_proof(mid, proof);
    true
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
        let newly_hidden = super::message_ops::apply_verified_channel_deletion(
            store, sid, cid, mid, hidden_ts,
            msg.hidden_sig.as_deref(), msg.hidden_pk.as_deref(), pk_cache,
        );
        if let Some(dev) = super::post_proof::item_deletion_proof(sid, cid, msg)
            && store.load_deletion_proof(mid).is_some_and(|(at, _, _)| at == hidden_ts)
        {
            let _ = store.set_deletion_dev(mid, dev);
        }
        if newly_hidden {
            events.push(NetworkEvent::ChannelMessageDeleted {
                server_id: sid.to_string(),
                channel_id: cid.to_string(),
                message_id: mid.clone(),
                deleted_at: hidden_ts,
            });
        }
    }
    let file_proof = super::post_proof::item_file_proof(sid, cid, msg);
    if let Some(fm) = super::file_handler::synced_file_meta(
        store, msg.file_meta.as_ref(), msg.file_id.as_deref(), msg.mid.as_deref(), &msg.s,
    ).filter(|fm| !super::file_handler::meta_swap_refused(store, &fm.fid, file_proof.is_some())) {
        let ctx_id = format!("{sid}:{cid}");
        let thumb = super::file_handler::accept_header_thumb(fm.thumb.clone(), fm.img, &fm.mime);
        let _ = store.insert_file_metadata(
            &fm.fid, &fm.name, &fm.ext, &fm.mime,
            fm.size, 0, fm.img, fm.w, fm.h,
            msg.mid.as_deref(), "channel", &ctx_id,
            &msg.s, is_mine, fm.ts,
            fm.vthumb.as_ref(), thumb.as_deref(), fm.sha256.as_deref(),
        );
        super::file_handler::keep_meta_proof(store, &fm.fid, &super::post_proof::sync_meta_digest(fm), file_proof);
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
            if let Some(dev) = super::post_proof::item_reaction_proof(sid, cid, mid, r) {
                let _ = store.set_reaction_dev(mid, &r.e, &r.p, r.ts, dev);
            }
        }
    }
    events
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> crate::storage::MessageStore {
        crate::storage::MessageStore::open(":memory:", &"ab".repeat(32)).expect("open in-memory store")
    }

    fn dm_item(ts: i64, edited_at: Option<i64>) -> DmSyncItem {
        serde_json::from_value(serde_json::json!({ "t": "x", "ts": ts, "mine": true, "edited_at": edited_at })).unwrap()
    }

    fn channel_item(sender: &str, ts: i64) -> SyncMessageItem {
        serde_json::from_value(serde_json::json!({ "s": sender, "t": "x", "ts": ts })).unwrap()
    }

    fn channel_row(store: &crate::storage::MessageStore, sender: &str, ts: i64, mid: &str) {
        store
            .insert_channel_message("srv", "ch", sender, "x", false, ts, Some("sig"), Some("pk"), Some(mid), None, None, None, None)
            .unwrap();
    }

    /// A rejoin's ask goes just past our own leave while our clock is behind it, never
    /// further than the drift bound the leave itself was held to.
    #[test]
    fn a_rejoin_is_stamped_past_our_own_leave_within_the_drift_bound() {
        let now = super::super::types::now_ms();
        assert!((now..now + 1_000).contains(&super::ask_stamp(None)), "no leave held: now");
        assert!((now..now + 1_000).contains(&super::ask_stamp(Some(5))), "an old leave: now");
        let ahead = now as u64 + 120_000;
        assert_eq!(super::ask_stamp(Some(ahead)), ahead as i64 + 1, "just past a leave stamped ahead");
        let bound = now + crate::crdt::hlc::MAX_DRIFT_MS as i64;
        assert!((bound..bound + 1_000).contains(&super::ask_stamp(Some(u64::MAX))), "never past the drift bound");
    }

    #[test]
    fn a_dm_page_continues_from_its_own_end() {
        let page: Vec<DmSyncItem> = [10, 11, 12, 12].into_iter().map(|ts| dm_item(ts, None)).collect();
        assert_eq!(dm_next_page_since(&page, false), Some(12), "`>=` keeps the rows sharing the last timestamp");
        assert_eq!(dm_next_page_since(&page, true), Some(11), "`>` starts a millisecond early to keep them");
        assert_eq!(dm_next_page_since(&[], true), None);
    }

    #[test]
    fn a_dm_page_its_next_ask_would_serve_again_stops_paging() {
        let one_ms: Vec<DmSyncItem> = (0..200).map(|_| dm_item(50, None)).collect();
        assert_eq!(dm_next_page_since(&one_ms, false), None, "one millisecond fills the page");
        assert_eq!(dm_next_page_since(&one_ms, true), None, "one millisecond fills the page");
        let edited_since: Vec<DmSyncItem> = (1..=5).map(|ts| dm_item(ts, Some(100))).collect();
        assert_eq!(dm_next_page_since(&edited_since, false), None, "rows edited after the page's end qualify again");
        let mut one_left: Vec<DmSyncItem> = (1..=5).map(|ts| dm_item(ts, Some(100))).collect();
        one_left[0] = dm_item(1, Some(2));
        assert_eq!(dm_next_page_since(&one_left, false), Some(5), "a row the next ask leaves out is progress");
    }

    #[test]
    fn a_repeated_dm_page_is_asked_once_per_window() {
        let mut asked = HashMap::new();
        assert!(!dm_page_asked(&mut asked, "dev", "convo", 7));
        assert!(dm_page_asked(&mut asked, "dev", "convo", 7), "the same page again");
        assert!(!dm_page_asked(&mut asked, "dev", "convo", 8), "the next page");
        assert!(!dm_page_asked(&mut asked, "dev", "other", 7), "another conversation");
    }

    #[test]
    fn a_sibling_page_names_every_other_conversation_past_its_end() {
        let store = store();
        for convo in ["a", "b", "c"] {
            store.insert(convo, "x", true, 1, None, None, Some(&format!("m-{convo}")), None, None, None, None).unwrap();
        }
        let HavenMessage::DmSiblingSyncRequest { per_convo_since, gaps } = sibling_next_page_request(&store, "b", 5) else {
            panic!("a sibling ask");
        };
        let mut named = per_convo_since;
        named.sort();
        assert_eq!(named, vec![("a".into(), NOTHING_NEWER), ("b".into(), 5), ("c".into(), NOTHING_NEWER)]);
        assert!(gaps.is_empty());
        assert!(store.get_dm_messages_for_sibling("a", NOTHING_NEWER, 200).unwrap().is_empty(), "nothing is newer");
    }

    #[test]
    fn a_channel_page_end_needs_two_timestamps() {
        assert!(ChannelPageEnd::of(&[]).is_none());
        let one_ms: Vec<SyncMessageItem> = (0..200).map(|_| channel_item("x", 9)).collect();
        assert!(ChannelPageEnd::of(&one_ms).is_none(), "one millisecond fills the page");
        assert!(ChannelPageEnd::of(&[channel_item("x", 8), channel_item("x", 9)]).is_some());
    }

    #[test]
    fn the_next_channel_page_starts_every_sender_at_the_page_end() {
        let store = store();
        channel_row(&store, "known", 3, "m1");
        // A live post far newer than the page: its sender's watermark is no cursor.
        channel_row(&store, "live", 10_000_000, "m2");
        let end = ChannelPageEnd::of(&[channel_item("live", 4), channel_item("paged", 6)]).unwrap();
        let HavenMessage::ChannelSyncRequest { since_timestamp, sender_timestamps, gap, .. } =
            channel_next_page_request(&store, "srv", "ch", end, None)
        else {
            panic!("a channel ask");
        };
        assert_eq!(since_timestamp, 6);
        let mut named: Vec<(String, i64)> = sender_timestamps.into_iter().collect();
        named.sort();
        assert_eq!(named, vec![("known".into(), 6), ("live".into(), 6), ("paged".into(), 6)]);
        assert!(gap.is_none(), "the first page carried the digest");
    }

    #[test]
    fn a_repeated_channel_ask_keys_the_same_and_the_next_page_does_not() {
        let first = HashMap::from([("a".to_string(), 1), ("b".to_string(), 2)]);
        let same = HashMap::from([("b".to_string(), 2), ("a".to_string(), 1)]);
        let next = HashMap::from([("a".to_string(), 5), ("b".to_string(), 5)]);
        let gap = GapDigest { from: 1, until: 2, days: Vec::new() };
        assert_eq!(channel_sync_ask_key(0, &first, None, None), channel_sync_ask_key(0, &same, None, None));
        assert_ne!(channel_sync_ask_key(0, &first, None, None), channel_sync_ask_key(0, &next, None, None));
        assert_ne!(channel_sync_ask_key(0, &first, None, None), channel_sync_ask_key(0, &first, Some(&gap), None));
        assert_ne!(channel_sync_ask_key(0, &first, None, None), channel_sync_ask_key(1, &first, None, None));
    }

    #[test]
    fn a_page_cut_by_its_limit_takes_no_gap_row_past_its_end() {
        const DAY: i64 = 24 * 60 * 60 * 1000;
        let base = 400 * DAY;
        let store = store();
        for i in 0..250 {
            channel_row(&store, "tail", base + i, &format!("t{i}"));
        }
        // Behind their sender's watermark, so only the digest serves them: one before the
        // tail's first page ends, one after it, a day apart from the tail's own day.
        channel_row(&store, "behind", base - 10, "before-end");
        channel_row(&store, "behind", base + DAY + 300, "past-end");
        channel_row(&store, "behind", base + 5 * DAY, "watermark");
        let watermarks = HashMap::from([("tail".to_string(), base), ("behind".to_string(), base + 5 * DAY)]);
        // The requester holds the tail's day and lacks the two days around it.
        let mut theirs = store.channel_gap_anchor("srv", "ch").expect("a digest window");
        theirs.days.retain(|day| day.d == base / DAY);
        assert_eq!(theirs.days.len(), 1);
        let mids = |envelope: MessageEnvelope| -> Vec<String> {
            let MessageEnvelope::ChannelSyncBatch { messages, has_more, .. } = envelope else { panic!("a batch") };
            assert_eq!(has_more, Some(true));
            messages.into_iter().filter_map(|m| m.mid).collect()
        };
        let (page, _) = build_channel_sync_batch(&store, "srv", "ch", 0, &watermarks, Some(&theirs), false, None).unwrap();
        let page = mids(page);
        assert!(page.contains(&"before-end".to_string()), "a gap row inside the page stays");
        assert!(!page.contains(&"past-end".to_string()), "a gap row past the page's end waits for the next page");
        assert_eq!(page.iter().filter(|m| m.starts_with('t')).count(), 200);
    }

    /// A next-page ask (every sender from where the last page ended) is served without
    /// counting the rest of the history; any other ask still gets the full count, and
    /// both say whether more follow exactly as a count would.
    #[test]
    fn a_next_page_is_served_without_counting_what_is_left() {
        let store = store();
        for i in 0..450 {
            channel_row(&store, if i % 3 == 0 { "a" } else { "b" }, 1_000 + i, &format!("r{i}"));
        }
        let batch = |since: i64, wm: &HashMap<String, i64>| {
            let (env, _) = build_channel_sync_batch(&store, "srv", "ch", since, wm, None, false, None).unwrap();
            let MessageEnvelope::ChannelSyncBatch { messages, total, has_more, .. } = env else { panic!("a batch") };
            (messages.len(), total, has_more, messages.iter().map(|m| m.ts).max().unwrap_or(0))
        };
        let (n, total, more, end) = batch(0, &HashMap::new());
        assert_eq!((n, total, more), (200, 450, Some(true)), "a first page counts everything");
        let next = |end: i64| HashMap::from([("a".to_string(), end), ("b".to_string(), end)]);
        let (n, total, more, end) = batch(end, &next(end));
        assert_eq!((n, total, more), (200, 200, Some(true)), "a next page counts itself only");
        let (n, total, more, _) = batch(end, &next(end));
        assert_eq!((n, total, more), (52, 52, None), "the last page says so");
        let catch_up = HashMap::from([("a".to_string(), 1_100), ("b".to_string(), 1_300)]);
        let (n, total, more, _) = batch(1_449, &catch_up);
        assert_eq!((n, more), (200, Some(true)));
        assert_eq!(total, store.count_channel_messages_since_per_sender("srv", "ch", &catch_up).unwrap(), "a catch-up is counted");
        let (n, _, more, _) = batch(1_449, &HashMap::from([("a".to_string(), 2_000), ("b".to_string(), 1_150)]));
        assert_eq!((n, more), (200, None), "exactly 200 rows left is one page");
        let (_, _, more, _) = batch(1_449, &HashMap::from([("a".to_string(), 2_000), ("b".to_string(), 1_149)]));
        assert_eq!(more, Some(true), "201 is two");
    }

    /// A second join key is an invite reset, so the missing-key sweep sets one only on the
    /// lowest of the owner's devices in the room, caught up there, nothing under way.
    #[test]
    fn only_the_lowest_caught_up_owner_device_sets_a_missing_join_key() {
        use crate::identity::native_identity::NativeKeypair;
        let id = |b: u8| NativeKeypair::from_secret_bytes(&[b; 32]).peer_id();
        let (master, member) = (id(211), id(214));
        let (mut lo, mut hi) = (id(212), id(213));
        if hi < lo {
            std::mem::swap(&mut lo, &mut hi);
        }
        crate::crdt::set_identity_resolver(super::super::resolver::resolve);
        super::super::resolver::seed_self(&master, &[lo.clone(), hi.clone()]);
        let mut state = ServerState::new("srv".into(), "S".into(), master.clone());
        state.members.insert(member.clone(), crate::crdt::server_state::MemberInfo { peer_id: member.clone(), display_name: "m".into() });
        let states: ServerStates = HashMap::from([("srv".to_string(), state)]);
        let mut hold = super::super::join_hold::JoinHold::default();
        hold.went_away(&states);
        let mut resync = super::super::crdt_resync::CrdtResync::for_test();
        let mut pending: HashMap<String, PendingJoin> = HashMap::new();
        let room = |peers: &[&String]| -> WsRoomPeers { HashMap::from([("srv".to_string(), peers.iter().map(|p| (*p).clone()).collect())]) };
        let sets = |hold: &super::super::join_hold::JoinHold, resync: &super::super::crdt_resync::CrdtResync, pending: &HashMap<String, PendingJoin>, peers: &WsRoomPeers, device: &str| {
            sets_missing_join_key("srv", hold, pending, resync, &states, peers, &master, device)
        };

        assert!(!sets(&hold, &resync, &pending, &room(&[]), &lo), "the room is not shown yet");
        hold.joined("srv", false);
        assert!(sets(&hold, &resync, &pending, &room(&[]), &lo), "nobody else is there");
        assert!(!sets(&hold, &resync, &pending, &room(&[&member]), &lo), "a member is, and has not answered");
        assert!(!sets(&hold, &resync, &pending, &room(&[&hi]), &lo), "our sibling is, and has not answered");
        assert!(!sets(&hold, &resync, &pending, &room(&[&lo]), &hi), "a lower device of ours sets it");
        hold.synced(Some(("srv".into(), master.clone())));
        assert!(sets(&hold, &resync, &pending, &room(&[&hi, &member]), &lo), "caught up, our lowest device");
        assert!(!sets(&hold, &resync, &pending, &room(&[&lo, &member]), &hi), "never the higher one");
        pending.insert("srv".into(), PendingJoin::default());
        assert!(!sets(&hold, &resync, &pending, &room(&[]), &lo), "a join is under way");
        pending.clear();
        resync.mark_due_for_test("srv");
        assert!(!sets(&hold, &resync, &pending, &room(&[]), &lo), "a whole-log fetch is due");
    }

    /// The relay hides a backgrounded device from every presence list, its siblings'
    /// too, while it still sees them: an away lower owner device and an on-screen higher
    /// one would both think they are the lowest, and two first keys fold as a reset.
    #[test]
    fn an_away_owner_device_sets_no_missing_join_key() {
        use crate::identity::native_identity::NativeKeypair;
        let id = |b: u8| NativeKeypair::from_secret_bytes(&[b; 32]).peer_id();
        let (master, member) = (id(221), id(224));
        let (mut lo, mut hi) = (id(222), id(223));
        if hi < lo {
            std::mem::swap(&mut lo, &mut hi);
        }
        crate::crdt::set_identity_resolver(super::super::resolver::resolve);
        super::super::resolver::seed_self(&master, &[lo.clone(), hi.clone()]);
        let mut state = ServerState::new("srv".into(), "S".into(), master.clone());
        state.members.insert(member.clone(), crate::crdt::server_state::MemberInfo { peer_id: member.clone(), display_name: "m".into() });
        let states: ServerStates = HashMap::from([("srv".to_string(), state)]);
        let resync = super::super::crdt_resync::CrdtResync::for_test();
        let pending: HashMap<String, PendingJoin> = HashMap::new();
        let room = |peers: &[&String]| -> WsRoomPeers { HashMap::from([("srv".to_string(), peers.iter().map(|p| (*p).clone()).collect())]) };
        let mut hold = super::super::join_hold::JoinHold::default();
        hold.went_away(&states);
        hold.joined("srv", false);
        hold.synced(Some(("srv".into(), member.clone())));
        let rt = tokio::runtime::Builder::new_current_thread().build().unwrap();
        let sets_as = |away: bool, peers: &WsRoomPeers, device: &str| {
            let flag = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(away));
            rt.block_on(super::super::ws_client::with_test_away(flag, async {
                sets_missing_join_key("srv", &hold, &pending, &resync, &states, peers, &master, device)
            }))
        };
        assert!(!sets_as(true, &room(&[&hi, &member]), &lo), "the away lower device set a key");
        assert!(sets_as(false, &room(&[&member]), &hi), "the on-screen device the relay shows alone sets it");
        assert!(!sets_as(true, &room(&[]), &lo), "an away owner alone set a key");
        assert!(sets_as(false, &room(&[&hi, &member]), &lo), "back on screen, the lowest device sets it");
    }
}

#[cfg(test)]
mod g13_twin_tests {
    use super::*;
    use crate::crdt::testkeys::keys;

    /// The author's carried twin goes over the relay to every member device even when the
    /// mesh took the op: no receiver hands it on.
    #[test]
    fn broadcast_twin_goes_over_the_relay_even_when_the_mesh_took_it() {
        let (kp, owner, pk) = keys(1);
        let (mut state, _) = ServerState::found("S".into(), owner.clone(), kp, pk);
        let sid = state.server_id.clone();
        let member = keys(2).1;
        let ask = crate::crdt::operations::JoinAsk::sign(&sid, 1, &keys(2).0);
        state
            .author_checked(CrdtPayload::MemberAdded { peer_id: member.clone(), display_name: "m".into(), follow: None, ask: Some(ask) })
            .expect("the owner admits");
        let rooms: WsRoomPeers = HashMap::from([(sid.clone(), std::collections::HashSet::from([member.clone()]))]);
        let mut overlay = super::super::gossip::GossipOverlay::new(sid.clone());
        overlay.add_known_peer("neighbour");
        overlay.peer_scores.get_mut("neighbour").expect("scored").mark_connected();
        let mut overlays: GossipOverlays = HashMap::from([(sid.clone(), overlay)]);
        let (event_tx, mut events) = tokio::sync::mpsc::channel(8);
        let (ws_tx, mut ws_rx) = tokio::sync::mpsc::unbounded_channel();
        broadcast_crdt_op_to_members(&ws_tx, &rooms, &mut overlays, &event_tx, &state, &owner, "our-device", &sid, "{}");
        assert!(matches!(events.try_recv(), Ok(NetworkEvent::GossipRelayOp { .. })), "the mesh took the op");
        let mut carried_to = Vec::new();
        while let Ok(cmd) = ws_rx.try_recv() {
            if let super::super::ws_client::WsCommand::Carry { device, .. } = cmd {
                carried_to.push(device);
            }
        }
        assert_eq!(carried_to, [member], "the member got no carried twin over the relay");
    }
}

// w2-c round 2
#[cfg(test)]
mod w2c_guest_floor {
    use super::guest_page_more;

    /// A guest page from a device that cleared the channel: served as usual while it
    /// stays above the floor, says more follows once it reaches it, not sent when empty.
    #[test]
    fn w2c_guest_pages_from_a_cleared_device() {
        assert_eq!(guest_page_more(None, 3, 50, Some(1)), Some(false), "a device that never cleared");
        assert_eq!(guest_page_more(Some(100), 50, 50, Some(101)), Some(false), "a full page above the floor");
        assert_eq!(guest_page_more(Some(100), 50, 50, Some(100)), Some(true), "a page reaching the floor");
        assert_eq!(guest_page_more(Some(100), 3, 50, Some(500)), Some(true), "rows ran out at the floor");
        assert_eq!(guest_page_more(Some(100), 0, 50, None), None, "an empty page from a cleared device was sent");
    }
}

// w3-gp1
#[cfg(test)]
mod w3_gp1 {
    use super::{build_channel_sync_batch, channel_sync_request};
    use crate::node::crypto_handler::{channel_readable_by, sync_partner};
    use crate::node::types::{HavenMessage, MessageEnvelope};

    /// A public channel's sync page goes only to a member who may see the channel; the
    /// public carve-out of `channel_readable_by` does not reach it (HOL-SEC-194).
    #[test]
    fn a_public_channels_sync_page_goes_only_to_a_member() {
        let _g = crate::node::resolver::test_lock();
        let mut s = crate::crdt::server_state::ServerState::new("srv".into(), "S".into(), "gp1-owner".into());
        let general = s.channels.keys().next().cloned().expect("a founding channel");
        s.channels.get_mut(&general).unwrap().is_public = true;
        assert!(channel_readable_by(&s, "gp1-stranger", &general), "precondition: a stranger may read a public channel");
        assert!(!sync_partner(Some(&s), "gp1-stranger", Some(&general)), "a stranger is served the member page");
        assert!(sync_partner(Some(&s), "gp1-owner", Some(&general)));
        assert!(!sync_partner(None, "gp1-owner", Some(&general)), "a server we do not hold");
    }

    /// A member refused before we could place it holds nothing from us, so its next ask
    /// gets the old deleted row back with its text.
    #[test]
    fn a_member_once_refused_gets_its_old_evidence_on_the_retry() {
        const DAY: i64 = 86_400_000;
        let open = || crate::storage::MessageStore::open(":memory:", &"ab".repeat(32)).unwrap();
        let (holder, asker) = (open(), open());
        for (mid, ts) in [("old-kept", 10 * DAY), ("old-gone", 10 * DAY + 5), ("new-kept", 100 * DAY)] {
            holder.insert_channel_message("srv", "ch", "al", &format!("t-{mid}"), false, ts, Some("sig"), Some("pk"), Some(mid), None, None, None, None).unwrap();
        }
        holder.set_channel_message_hidden("old-gone", 11 * DAY).unwrap();
        let HavenMessage::ChannelSyncRequest { since_timestamp, sender_timestamps, gap, .. } = channel_sync_request(&asker, "srv", "ch", true) else { panic!("an ask") };
        let (env, _) = build_channel_sync_batch(&holder, "srv", "ch", since_timestamp, &sender_timestamps, gap.as_ref(), false, None).unwrap();
        let MessageEnvelope::ChannelSyncBatch { messages, .. } = env else { panic!("a batch") };
        assert!(
            messages.iter().any(|m| m.mid.as_deref() == Some("old-gone") && m.t == "t-old-gone" && m.hidden_at.is_some()),
            "the member's old evidence is missing",
        );
    }
}

// w3-ar39
#[cfg(test)]
mod w3_ar39 {
    use super::*;
    use crate::identity::native_identity::NativeKeypair;
    use crate::node::channel_asks::{ChannelAsks, Holder, Standing};
    use crate::node::crypto_handler::SignedExtras;
    use crate::storage::MessageStore;

    const KEY: &str = "abababababababababababababababababababababababababababababababab";
    const T: i64 = 1_000_000_000_000;

    fn store(tmp: &std::path::Path, name: &str) -> MessageStore {
        MessageStore::open(tmp.join(name).to_str().unwrap(), KEY).unwrap()
    }

    fn kp(seed: u8) -> NativeKeypair {
        NativeKeypair::from_secret_bytes(&[seed; 32])
    }

    /// A row as its author signed it.
    fn signed(k: &NativeKeypair, mid: &str, ts: i64) -> SyncMessageItem {
        let pk = base64::engine::general_purpose::STANDARD.encode(k.public_key_protobuf());
        let extras = SignedExtras { mid: Some(mid), reply_to: None, file_id: None, order_us: Some(ts * 1000), lp_digest: None, album: None };
        let (sig, pk) = super::super::crypto_handler::sign_message_versioned(k, &pk, "ch", "srv:ch", &k.peer_id(), ts, &extras, mid);
        serde_json::from_value(serde_json::json!({
            "s": k.peer_id(), "t": mid, "ts": ts, "mid": mid, "sig": sig, "pk": pk, "order_us": ts * 1000,
        }))
        .unwrap()
    }

    fn put(store: &MessageStore, m: &SyncMessageItem) {
        store
            .insert_channel_message("srv", "ch", &m.s, &m.t, false, m.ts, m.sig.as_deref(), m.pk.as_deref(), m.mid.as_deref(), None, None, m.order_us, None)
            .unwrap();
    }

    fn post(store: &MessageStore, sender: &str, mid: &str, ts: i64) {
        store.insert_channel_message("srv", "ch", sender, mid, false, ts, None, None, Some(mid), None, None, Some(ts * 1000), None).unwrap();
    }

    fn rows_of(env: &MessageEnvelope) -> (usize, Option<bool>, Option<i64>) {
        let MessageEnvelope::ChannelSyncBatch { messages, has_more, held_from, .. } = env else { panic!("a batch") };
        (messages.len(), *has_more, *held_from)
    }

    fn joiner_page(holder: &MessageStore, partial_ok: bool) -> MessageEnvelope {
        build_channel_sync_batch(holder, "srv", "ch", -1, &HashMap::new(), None, partial_ok, None).unwrap().0
    }

    fn holders(device: &str) -> Vec<Holder> {
        vec![Holder { device: device.into(), master: device.into(), standing: Standing::Established }]
    }

    /// `asker` asks `holder` once and lands its first page as the swarm does.
    fn ask_and_land(asker: &MessageStore, asks: &mut ChannelAsks, holder: &MessageStore, device: &str) -> (PageLanded, Option<i64>) {
        let asked = asks.start("srv", "ch", &holders(device), std::time::Instant::now()).expect("an ask");
        assert_eq!(asked, device);
        let HavenMessage::ChannelSyncRequest { since_timestamp, sender_timestamps, gap, partial_ok, until, .. } = channel_sync_request(asker, "srv", "ch", true) else { panic!() };
        let (env, _) = build_channel_sync_batch(holder, "srv", "ch", since_timestamp, &sender_timestamps, gap.as_ref(), partial_ok, until).unwrap();
        let MessageEnvelope::ChannelSyncBatch { messages, has_more, held_from, .. } = env else { panic!() };
        let end = if has_more == Some(true) { ChannelPageEnd::of(&messages) } else { None };
        (land_channel_page(asker, asks, "srv", "ch", device, true, &messages, has_more, held_from, end, "us"), held_from)
    }

    /// A page nobody asked for, carrying `held_from` and a forged row, changes nothing
    /// about what a full holder serves: only a chain we opened is noted.
    #[test]
    fn ar39_an_unasked_forged_page_never_changes_what_a_holder_serves() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let v = store(tmp.path(), "v.db");
        for i in 0..100 {
            post(&v, "alice", &format!("h{i}"), T + i);
        }
        let mut forged = signed(&kp(7), "forged", T + 500);
        forged.t = "not what was signed".into();
        let mut asks = ChannelAsks::with_seed(1);
        let empty = store(tmp.path(), "nothing.db");
        for target in [&v, &empty] {
            land_channel_page(target, &mut asks, "srv", "ch", "mallory", true, std::slice::from_ref(&forged), None, Some(T + 500), None, "us");
            assert!(target.channel_hole("srv", "ch").is_none(), "an unasked page opened a hole");
        }
        assert_eq!(rows_of(&joiner_page(&v, true)), (100, None, None));
        assert_eq!(rows_of(&joiner_page(&v, false)), (100, None, None));
    }

    /// Of a page we asked for, only a row ingest accepted says where our history starts:
    /// a forged row below the first real one never moves the hole down to it.
    #[test]
    fn ar39_only_rows_ingest_accepted_place_a_hole() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let (o, j) = (store(tmp.path(), "o.db"), store(tmp.path(), "j.db"));
        let alice = kp(11);
        let real = signed(&alice, "real", T + 900);
        put(&o, &real);
        let mut forged = signed(&alice, "forged", T + 500);
        forged.t = "tampered".into();
        let mut asks = ChannelAsks::with_seed(2);
        asks.start("srv", "ch", &holders("o"), std::time::Instant::now()).unwrap();
        let page = vec![forged, real];
        let landed = land_channel_page(&j, &mut asks, "srv", "ch", "o", true, &page, None, Some(T + 500), None, "us");
        assert_eq!(landed.new_count, 1);
        assert_eq!(j.channel_hole("srv", "ch").map(|h| h.below), Some(T + 900), "a forged row placed the hole");
        assert_eq!(j.channel_held_from("srv", "ch"), Some(T + 900));
    }

    /// A channel the server does not have (an owner may send one) never gets a hole row.
    #[test]
    fn ar39_a_made_up_channel_gets_no_hole() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let j = store(tmp.path(), "j.db");
        let mut asks = ChannelAsks::with_seed(3);
        asks.start("srv", "ch", &holders("o"), std::time::Instant::now()).unwrap();
        land_channel_page(&j, &mut asks, "srv", "ch", "o", false, &[], None, Some(T), None, "us");
        assert!(j.channel_hole("srv", "ch").is_none(), "a channel the server lacks got a hole");
        let state = ServerState::new("srv".into(), "srv".into(), "owner".into());
        let general = state.channels.keys().next().cloned().expect("a founding channel");
        assert!(!channel_known(Some(&state), "ch") && !channel_known(None, &general));
        assert!(channel_known(Some(&state), &general));
    }

    /// K was online for everything up to the clear and lacks nothing, then catches up the
    /// posts after it from the holder that cleared: it keeps serving its whole history to
    /// every asker, exactly as before, and opens no hole.
    #[test]
    fn ar39_a_full_holder_catching_up_from_a_cleared_one_keeps_serving_its_history() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let (o, k, base) = (store(tmp.path(), "o.db"), store(tmp.path(), "k.db"), store(tmp.path(), "base.db"));
        for i in 0..100 {
            for s in [&o, &k, &base] {
                post(s, "alice", &format!("h{i}"), T + i * 10);
            }
        }
        o.clear_channel_history(T + 2_000).unwrap();
        let (p1, p2) = (signed(&kp(21), "p1", T + 400_000), signed(&kp(22), "p2", T + 400_100));
        put(&o, &p1);
        put(&o, &p2);
        put(&base, &p1);
        put(&base, &p2);
        let mut asks = ChannelAsks::with_seed(4);
        let (landed, held) = ask_and_land(&k, &mut asks, &o, "o");
        assert_eq!((landed.new_count, held), (2, Some(T + 400_000)), "precondition: a partial page");
        assert!(k.channel_hole("srv", "ch").is_none(), "a full holder opened a hole");
        assert_eq!(k.channel_held_from("srv", "ch"), None);
        for partial_ok in [true, false] {
            let (ours, theirs) = (joiner_page(&k, partial_ok), joiner_page(&base, partial_ok));
            assert_eq!(rows_of(&ours).0, 102);
            assert_eq!(serde_json::to_string(&ours).unwrap(), serde_json::to_string(&theirs).unwrap(), "it answers an asker unlike a full holder (partial_ok {partial_ok})");
        }
    }

    /// A device whose history begins later (it held nothing) lands a partial page and opens
    /// a hole there, inside the page's own transaction; a hole page vouching for part keeps it.
    #[test]
    fn ar39_a_late_joiner_lacks_what_lies_below_a_partial_page() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let (o, j) = (store(tmp.path(), "o.db"), store(tmp.path(), "j.db"));
        post(&o, "alice", "old", T);
        o.clear_channel_history(T + 1).unwrap();
        put(&o, &signed(&kp(31), "p1", T + 400_000));
        let mut asks = ChannelAsks::with_seed(5);
        let (landed, held) = ask_and_land(&j, &mut asks, &o, "o");
        assert_eq!((landed.new_count, held), (1, Some(T + 400_000)));
        assert_eq!(j.channel_hole("srv", "ch").map(|h| h.below), Some(T + 400_000));
        assert!(j.channel_history_begins_later("srv", "ch"));
        assert_eq!(rows_of(&joiner_page(&j, false)), (0, Some(true), None), "it answers an older asker as a partial holder");
        // The hole ask goes to a second cleared holder, which vouches for part again.
        let o2 = store(tmp.path(), "o2.db");
        post(&o2, "alice", "old", T);
        o2.clear_channel_history(T + 1).unwrap();
        put(&o2, &signed(&kp(31), "p1", T + 400_000));
        let two = |_: &str, _: &str| [holders("o"), holders("o2")].concat();
        let moved = asks.sweep_asks(std::time::Instant::now() + std::time::Duration::from_secs(2), &|_| true, &two);
        assert_eq!(moved, vec![("srv".into(), "ch".into(), "o2".into(), Kind::Hole)], "the hole goes to the holder not short of it");
        let ask = channel_hole_request(&j, "srv", "ch").unwrap();
        let HavenMessage::ChannelSyncRequest { since_timestamp, sender_timestamps, partial_ok, until, .. } = ask else { panic!() };
        let (env, _) = build_channel_sync_batch(&o2, "srv", "ch", since_timestamp, &sender_timestamps, None, partial_ok, until).unwrap();
        let MessageEnvelope::ChannelSyncBatch { messages, has_more, held_from, .. } = env else { panic!() };
        let landed = land_channel_page(&j, &mut asks, "srv", "ch", "o2", true, &messages, has_more, held_from, None, "us");
        assert!(!landed.heard.filled);
        assert!(j.channel_hole_open("srv", "ch"), "a partial answer filled the hole");
    }

    const DAY: i64 = 86_400_000;

    fn mids_served(env: &MessageEnvelope) -> Vec<String> {
        let MessageEnvelope::ChannelSyncBatch { messages, .. } = env else { panic!("a batch") };
        messages.iter().filter_map(|m| m.mid.clone()).collect()
    }

    fn catch_up_page(asker: &MessageStore, holder: &MessageStore) -> MessageEnvelope {
        let HavenMessage::ChannelSyncRequest { since_timestamp, sender_timestamps, gap, partial_ok, until, .. } = channel_sync_request(asker, "srv", "ch", true) else { panic!() };
        build_channel_sync_batch(holder, "srv", "ch", since_timestamp, &sender_timestamps, gap.as_ref(), partial_ok, until).unwrap().0
    }

    /// A device that cleared a channel and was away takes the posts made after its clear
    /// that it missed, older than the first one it then received, and none of what it
    /// cleared is served again.
    #[test]
    fn ar39_a_cleared_device_back_from_away_takes_the_posts_it_missed() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let (o, a) = (store(tmp.path(), "o.db"), store(tmp.path(), "a.db"));
        for s in [&o, &a] {
            for i in 0..20 {
                post(s, "alice", &format!("h{i}"), T + i * 1_000);
            }
        }
        a.clear_channel_history(T + DAY).unwrap();
        let missed: Vec<String> = (0..5).flat_map(|i| [format!("m{i}"), format!("b{i}")]).collect();
        for i in 0..5 {
            post(&o, "alice", &format!("m{i}"), T + 3 * DAY + i * 1_000);
            post(&o, "bob", &format!("b{i}"), T + 3 * DAY + 500 + i * 1_000);
        }
        for s in [&o, &a] {
            post(s, "alice", "p", T + 5 * DAY);
            post(s, "bob", "pb", T + 5 * DAY + 1);
        }
        let served = mids_served(&catch_up_page(&a, &o));
        assert!(missed.iter().all(|m| served.contains(m)), "the posts it missed after its clear were not served: {served:?}");
        assert!(!served.iter().any(|m| m.starts_with('h')), "what it cleared was served again: {served:?}");
    }

    /// A device that cleared a channel and holds nothing of it since lands a partial page
    /// and opens no hole: its floor is its line, and its asks count what it cleared.
    #[test]
    fn ar39_a_cleared_device_opens_no_hole() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let (o, a) = (store(tmp.path(), "o.db"), store(tmp.path(), "a.db"));
        for s in [&o, &a] {
            post(s, "alice", "old", T);
            s.clear_channel_history(T + 1).unwrap();
        }
        put(&o, &signed(&kp(31), "p1", T + 400_000));
        let mut asks = ChannelAsks::with_seed(6);
        let (landed, held) = ask_and_land(&a, &mut asks, &o, "o");
        assert_eq!((landed.new_count, held), (1, Some(T + 400_000)), "precondition: a partial page landed");
        assert!(a.channel_hole("srv", "ch").is_none() && !a.channel_history_begins_later("srv", "ch"), "a cleared device opened a hole");
    }

    /// A cleared device asks exactly as it would have without the clear: its since, sender
    /// marks and gap digest count what it cleared as held, so no ask shows a clear or where
    /// it lies, whether or not it received anything since.
    #[test]
    fn ar39_a_cleared_device_asks_as_it_would_have_without_the_clear() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let (a, b) = (store(tmp.path(), "a.db"), store(tmp.path(), "b.db"));
        let floor = T + 20 * DAY;
        for s in [&a, &b] {
            // From before the digest window on, as a history the device holds from its start.
            for i in 0..70 {
                post(s, "alice", &format!("old{i}"), floor - 35 * DAY + i * DAY / 2);
            }
            // On the window's first day, before the window's own start.
            post(s, "alice", "first-day", floor - 30 * DAY - 3_600_000);
            post(s, "carol", "c-old", floor - 40 * 60_000);
            // Within the lookback of the newest row, below where a later ask's digest ends.
            post(s, "erin", "e-near", floor - 25 * 60_000);
            // Within the lookback of the newest row, where the digest of a later ask ends.
            for i in 0..5 {
                post(s, "dave", &format!("near{i}"), floor - i * 60_000);
            }
        }
        a.clear_channel_history(floor + 60_000).unwrap();
        assert_eq!((a.channel_floor("srv", "ch"), a.count_all_channel_messages().unwrap()), (Some(floor), 0), "precondition: a cleared all of it");
        let ask = |s: &MessageStore| serde_json::to_value(channel_sync_request(s, "srv", "ch", true)).unwrap();
        assert_eq!(ask(&a), ask(&b), "a cleared device holding nothing since asks unlike the device it was");
        // A slow clock's post after the clear, stamped below the floor, lands and is named.
        for s in [&a, &b] {
            post(s, "gwen", "slow", floor - 60_000);
        }
        assert_eq!(a.count_all_channel_messages().unwrap(), 1, "precondition: the slow post landed");
        for s in [&a, &b] {
            post(s, "alice", "p1", floor + 10 * 60_000);
            post(s, "bob", "p2", floor + 12 * 60_000);
        }
        assert_eq!(ask(&a), ask(&b), "a cleared device asks unlike the device it was");
        let HavenMessage::ChannelSyncRequest { gap, .. } = channel_sync_request(&a, "srv", "ch", true) else { panic!() };
        assert!(gap.is_some_and(|g| g.until < floor && g.from < floor - 29 * DAY), "the digest does not reach below its first new post");
        let end = || ChannelPageEnd::of(&[item("erin", floor - DAY), item("erin", floor - DAY + 5)]).unwrap();
        let next = |s: &MessageStore| serde_json::to_value(channel_next_page_request(s, "srv", "ch", end(), None)).unwrap();
        assert_eq!(next(&a), next(&b), "a cleared device's next page differs from the device it was");
    }

    /// A copy of a cleared device asks for its hole up to its oldest row past the floor,
    /// which is a row it serves, never the floor.
    #[test]
    fn ar39_a_copys_hole_ask_names_a_row_not_the_floor() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let a = store(tmp.path(), "a.db");
        for i in 0..4 {
            post(&a, "alice", &format!("old{i}"), T + 1_000 * (i + 1));
        }
        a.clear_channel_history(T + 900_000).unwrap();
        let floor = a.channel_floor("srv", "ch").unwrap();
        post(&a, "alice", "p1", T + 2_000_000);
        a.scrub_device_secrets().unwrap();
        let Some(HavenMessage::ChannelSyncRequest { until, since_timestamp, sender_timestamps, .. }) = channel_hole_request(&a, "srv", "ch") else { panic!("a hole ask") };
        assert_eq!(until, Some(T + 2_000_000), "the copy's hole ask names until {until:?}, the floor is {floor}");
        assert!(since_timestamp == -1 && sender_timestamps.values().all(|t| *t == 0));
    }

    /// A hole page from a holder lacking part of what we lack keeps the hole open, and
    /// one that served it whole closes it once its rows are in.
    #[test]
    fn ar39_a_hole_closes_only_on_a_whole_answer() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let k = store(tmp.path(), "k.db");
        k.note_held_page("srv", "ch", T + 500_000, false, &[T + 500_000], false, T + 900_000).unwrap();
        post(&k, "alice", "a9", T + 500_000);
        let mut asks = ChannelAsks::with_seed(6);
        let device = asks.start("srv", "ch", &holders("o"), std::time::Instant::now()).unwrap();
        let heard = land_channel_page(&k, &mut asks, "srv", "ch", &device, true, &[], None, None, None, "us").heard;
        assert_eq!(heard.again, Some(Kind::Hole), "the whole catch-up hands the hole to the same holder");
        let landed = land_channel_page(&k, &mut asks, "srv", "ch", &device, true, &[], None, Some(T + 500_000), None, "us");
        assert!(!landed.heard.filled && k.channel_hole_open("srv", "ch"), "a partial answer filled the hole");
        let mut asks = ChannelAsks::with_seed(6);
        let device = asks.start("srv", "ch", &holders("p"), std::time::Instant::now()).unwrap();
        land_channel_page(&k, &mut asks, "srv", "ch", &device, true, &[], None, None, None, "us");
        let landed = land_channel_page(&k, &mut asks, "srv", "ch", &device, true, &[], None, None, None, "us");
        assert!(landed.heard.filled && !k.channel_hole_open("srv", "ch"), "a whole answer left the hole open");
    }

    /// A full page of the hole's own ask raises the hole's bottom once its rows are in; a
    /// partial one never does.
    #[test]
    fn ar39_a_hole_page_keeps_its_progress() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let k = store(tmp.path(), "k.db");
        k.note_held_page("srv", "ch", 50_000 + T, false, &[50_000 + T], false, T + 90_000).unwrap();
        let mut asks = ChannelAsks::with_seed(7);
        let device = asks.start("srv", "ch", &holders("h"), std::time::Instant::now()).unwrap();
        land_channel_page(&k, &mut asks, "srv", "ch", &device, true, &[], None, None, None, "us");
        let carol = kp(41);
        let mut forged = signed(&carol, "c3", T + 300);
        forged.t = "tampered".into();
        let page = vec![signed(&carol, "c1", T + 100), signed(&carol, "c2", T + 200), forged];
        let landed = land_channel_page(&k, &mut asks, "srv", "ch", &device, true, &page, Some(true), None, ChannelPageEnd::of(&page), "us");
        assert_eq!(landed.until, Some(T + 50_000), "a hole page's next page lost its bound");
        assert_eq!(k.channel_hole("srv", "ch").map(|h| h.from), Some(T + 200), "the hole's bottom moved past what the page landed");
        let page = vec![signed(&carol, "c4", T + 400), signed(&carol, "c5", T + 500)];
        land_channel_page(&k, &mut asks, "srv", "ch", &device, true, &page, Some(true), Some(T + 400), ChannelPageEnd::of(&page), "us");
        assert_eq!(k.channel_hole("srv", "ch").map(|h| h.from), Some(T + 200), "a partial page filled the hole below it");
    }

    fn item(sender: &str, ts: i64) -> SyncMessageItem {
        serde_json::from_value(serde_json::json!({ "s": sender, "t": "x", "ts": ts, "mid": format!("m{ts}") })).unwrap()
    }

    use crate::node::channel_asks::Kind;
}

#[cfg(test)]
mod roster_ask_tests {
    use super::*;

    /// Lead decision 1: a refused post's roster is asked of a member device of ANOTHER
    /// identity, never the author's own (its master key could mint the roster), never a
    /// stranger or us, once per pace, and never for a non-member or ourselves.
    #[test]
    fn lead_c_a_refused_posts_roster_is_never_asked_of_its_author() {
        let _g = crate::node::resolver::test_lock();
        let (state, _, member) = crate::crdt::verdict::tests::uncounted_member_op();
        let sid = state.server_id.clone();
        let owner = state.anchor_owner().expect("anchored");
        let us = "0-lead-c-local-master";
        crate::node::resolver::seed_self(&member, &["0-lead-c-author-device".to_string()]);
        let room: std::collections::HashSet<String> =
            ["0-lead-c-author-device".to_string(), owner.clone(), "0-lead-c-stranger".into(), us.into()].into();
        let mut resync = super::super::crdt_resync::CrdtResync::for_test();
        let now = std::time::Instant::now();
        let wanted: std::collections::BTreeSet<(String, String)> =
            [(member.clone(), "c".to_string()), (us.to_string(), "c".to_string()), ("0-lead-c-stranger".to_string(), "c".to_string())].into();
        resync.want_post_rosters(&state, &wanted, Some(&room), us, now);
        resync.want_post_rosters(&state, &wanted, Some(&room), us, now);
        let asks = resync.take_roster_asks();
        crate::node::resolver::forget_for_test("0-lead-c-author-device");
        let to: Vec<&str> = asks.iter().map(|(d, _)| d.as_str()).collect();
        assert_eq!(to, [owner.as_str()], "one member device of another identity, once");
        let HavenMessage::SyncRequest { server_id, x, .. } = &asks[0].1 else { panic!("a sync ask") };
        assert_eq!(server_id, &sid);
        assert_eq!(x.as_ref().map(|x| x.rosters_wanted.clone()), Some(vec![member]));
    }

    /// A live MLS op whose device the view does not count asks its carrier and one other
    /// member device for its author's roster (section 9, "Fetch on Uncounted"), once.
    #[tokio::test]
    async fn an_uncounted_live_op_asks_its_carrier_and_another_member_for_the_roster() {
        let (state, nick, member) = crate::crdt::verdict::tests::uncounted_member_op();
        let sid = state.server_id.clone();
        let owner = state.anchor_owner().expect("anchored");
        let dir = crate::test_tmp::tempdir().expect("tmp");
        let crdt_store = CrdtStore::open(dir.path().join("c.db").to_string_lossy().to_string(), "ab".repeat(32)).expect("store");
        let mut states: ServerStates = HashMap::from([(sid.clone(), state)]);
        let mut resync = super::super::crdt_resync::CrdtResync::for_test();
        let (event_tx, _event_rx) = tokio::sync::mpsc::channel(64);
        let (ws_cmd_tx, _ws_rx) = tokio::sync::mpsc::unbounded_channel();
        let carrier = "uncounted-carrier-device".to_string();
        let room: HashMap<String, std::collections::HashSet<String>> =
            HashMap::from([(sid.clone(), [carrier.clone(), owner.clone(), "0-stranger-device".into(), "0-uncounted-local-master".into()].into())]);
        let json = serde_json::to_string(&nick).unwrap();
        for _ in 0..2 {
            handle_envelope_crdt_op(
                &mut states, &mut resync, &crate::crdt::testkeys::keys(40).0, &event_tx, sid.clone(), json.clone(),
                &crdt_store, &ws_cmd_tx, &carrier, &room, "0-uncounted-local-master",
            )
            .await;
        }
        let asks = resync.take_roster_asks();
        let to: Vec<&str> = asks.iter().map(|(d, _)| d.as_str()).collect();
        assert_eq!(to, [carrier.as_str(), owner.as_str()], "the carrier and one member device (never a stranger or us), once per ten minutes");
        for (_, ask) in &asks {
            let HavenMessage::SyncRequest { server_id, x, .. } = ask else { panic!("a sync ask") };
            assert_eq!(server_id, &sid);
            assert_eq!(x.as_ref().map(|x| x.rosters_wanted.clone()), Some(vec![member.clone()]));
        }
    }
}
