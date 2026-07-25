use std::collections::HashMap;
use std::time::Duration;

use base64::Engine;
use tokio::sync::mpsc;

use crate::crdt::operations::{CrdtPayload, Permission};
use crate::crdt::server_state::ServerState;
use crate::crypto::{CryptoStore, MlsManager, OlmManager};
use super::crdt_store::CrdtStore;
use super::crypto_handler::{
    peer_is_reachable, send_message_to_peer, send_mls_broadcast,
    persist_mls_state, send_encrypted_message, send_raw_to_identity, online_devices_for,
    BackfillSig, PkCache,
};
use super::types::*;

/// Multi-device (Step 6): fan pre-serialized bytes out to EVERY online device of
/// EVERY server member except our own identity. Members are master-keyed and the
/// master has no socket, so a direct `send_message_to_peer(master)` is dropped —
/// every member-broadcast loop must go through this. Single-device collapses to
/// one device per member (or the member id itself if no link is known).
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

/// Multi-device (Step 9C): fan pre-serialized bytes to our OWN online sibling
/// devices, EXCLUDING the acting device (`local_device_id`).
///
/// The remaining-member broadcast skips the actor's own identity (members are
/// master-keyed; the actor's siblings resolve to the same master), so a
/// moderation/leave CRDT op — and the MLS leaf-removal commit for kick/ban —
/// never reaches a person's OTHER devices. Without this they only converge on
/// restart / the next SyncRequest. We exclude the acting device itself because
/// (a) it already applied the change locally and (b) re-feeding a node its OWN
/// MLS commit fails `process_commit` (epoch already advanced) → self-drops the
/// group. Returns the number of sibling devices reached (0 for a sole device).
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
/// devices. Used by every sync-handler CRDT op whose MLS broadcast failed/absent.
///
/// Tier 2 (large-server scaling, `reports/LARGE_SERVER_SCALING_2026.md`): when
/// the server's gossip overlay has live data channels, the op floods over the
/// P2P mesh instead — the sender stops paying O(members × devices) relay
/// uploads AND the relay stops seeing plaintext op JSON. The MLS twin (single
/// SendToRoom, sent by the caller) still reaches every online member; mesh
/// stragglers converge via the sync backstop. Falls back to the per-identity
/// relay fan-out whenever the mesh can't carry it (small server, channels
/// still dialing, oversized op).
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

/// Multi-device (Step 6): all MLS-credential ids belonging to one identity —
/// the master plus every known device id. Used to remove EVERY leaf of a kicked/
/// banned human in one commit (a leaf may be an offline device, so we can't rely
/// on live-room presence here). `master` resolves to itself for single-device.
fn identity_credential_ids(master: &str) -> Vec<String> {
    let m = super::resolver::resolve(master); // normalize if a device id slipped in
    let mut ids = super::resolver::devices_for(&m);
    ids.push(m);
    ids
}

// ── Shared authoring / broadcast plumbing ─────────────────────────────
//
// Nearly every handler in this file authors one CRDT op and pushes it out the
// same way. The helpers below hold that shape ONCE; handlers keep only their
// own gate, payload, event, and side effects.

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
/// `CrdtOpBroadcast` twin (idempotent — op_log dedups; receivers re-validate
/// author+permission). MLS broadcast is confidential but a receiver at a
/// skewed epoch silently drops it with no recovery, permanently losing the op
/// (e.g. a new channel it never learns exists). The plaintext copy guarantees
/// server-metadata convergence.
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
    /// MLS broadcast when the server group exists, plus the plaintext twin
    /// (always).
    MlsFirst { mls: &'a mut Option<MlsManager>, crypto_store: &'a CryptoStore },
    /// Plaintext-only op (no MLS path) + own-sibling fan.
    PlaintextWithFan { local_device_id: &'a str },
}

/// Shared driver for locally-authored server CRDT ops: permission gate →
/// author (create/apply/persist) → emit the prebuilt UI event → broadcast.
///
/// `denied_msg` = the user-facing `Error` message on a failed gate (`None` =
/// log-only silent deny).
///
/// Returns `true` when the gate denied (callers `continue`), `false` otherwise
/// — mirroring the per-handler bodies this replaced.
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
/// removal applied) and to our OWN online siblings (excluded from the
/// master-keyed member list). `skip` = the removed identity — it gets a
/// `MemberKickBroadcast` instead of the op; `None` for a voluntary leave
/// (the leaver's own siblings must apply the self-removal too).
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

/// Remove EVERY MLS leaf of `identity` from the server group (epoch rotation
/// for forward secrecy; credential ids = {master} ∪ all its known devices) and
/// broadcast the commit — Tier 1: ONE room broadcast replaces the per-identity
/// fan-out AND the sibling fan (our siblings are in the room too). A kicked/
/// banned identity's devices receive it but can't rejoin — the MlsKeyPackage
/// non-member check rejects their re-bootstrap.
///
/// Kick/ban pass `emit_epoch_event` (SFrame key rotation); self-removal on
/// leave passes `drop_group_on_err` (we're abandoning the group either way).
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
                crate::node::crypto_handler::broadcast_mls_commit(
                    ws_cmd_tx, server_id, None, commit_b64,
                    mls_mgr.epoch(server_id).ok(),
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

/// Pack stored channel messages into wire `SyncMessageItem`s, joining in each
/// message's reactions and file metadata via two batch queries. The channel
/// twin of swarm.rs's `build_dm_sync_items`; shared by every channel-sync
/// responder (Olm/MLS retry, MLS `ChannelSyncReq`, plaintext
/// `ChannelSyncRequest` in swarm.rs).
pub(crate) fn channel_sync_items(
    store: &crate::storage::MessageStore,
    messages: &[crate::storage::messages::StoredChannelMessage],
) -> Vec<SyncMessageItem> {
    let msg_ids: Vec<String> = messages.iter().filter_map(|m| m.message_id.clone()).collect();
    let reactions_map = store.load_reactions_for_sync(&msg_ids).unwrap_or_default();
    let file_ids: Vec<&str> = messages.iter().filter_map(|m| m.file_id.as_deref()).collect();
    let file_meta_map = store.get_file_metadata_batch(&file_ids).unwrap_or_default();

    messages.iter().map(|m| {
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
            })
        });
        // Deletion proof rides with the hidden flag (REJECT-ABSENT on apply).
        let (hidden_at, hidden_sig, hidden_pk) = super::message_ops::deletion_proof_fields(
            store, m.hidden_at, m.message_id.as_deref(),
        );
        SyncMessageItem {
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
            reactions,
        }
    }).collect()
}

/// Build one page (≤200 messages) of a channel-sync response: query per-sender
/// watermarks when the requester sent them (legacy single-timestamp fallback
/// otherwise), pack the items, and stamp `total`/`has_more` for pagination.
/// Returns the ready envelope plus the item count.
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
    let items = channel_sync_items(store, &messages);
    let total = if !sender_timestamps.is_empty() {
        store.count_channel_messages_since_per_sender(sid, cid, sender_timestamps)
            .unwrap_or(items.len() as u32)
    } else {
        store.count_channel_messages_since(sid, cid, since_timestamp)
            .unwrap_or(items.len() as u32)
    };
    let has_more = if items.len() >= 200 && total > 200 { Some(true) } else { None };
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

    // Create the initial ServerCreated op, apply + persist it.
    author_op(&mut state, crdt_store, &server_id, CrdtPayload::ServerCreated {
        name: name.clone(),
        owner_peer_id: local_peer,
    });

    server_states.insert(server_id.clone(), state);

    // Join the WS relay room for this server.
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
        room_code: server_id.clone(),
    });

    // Auto-pledge default storage (512 MB) for the owner
    if let Some(state) = server_states.get_mut(&server_id) {
        let default_pledge = 512u64 * 1024 * 1024;
        author_op(state, crdt_store, &server_id, CrdtPayload::StoragePledgeChanged {
            peer_id: local_peer_str.to_string(),
            pledge_bytes: default_pledge,
        });
    }

    // Create MLS group for this server (owner is sole member).
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

    // Multi-device: announce the new server to our OWN online sibling devices so
    // they auto-onboard (the server room is brand-new; siblings aren't in it and
    // have no other way to learn it exists). Each sibling runs its join flow and we
    // serve the snapshot + add its MLS leaf via the same-identity ServerJoinRequest
    // fast-path. Offline siblings onboard when they next come online + we re-announce.
    // No-op for a sole single-device install (no siblings online).
    let announce = serde_json::to_vec(&HavenMessage::SiblingServerAnnounce {
        server_id: server_id.clone(),
    }).unwrap_or_default();
    let sent = fan_to_own_siblings(ws_cmd_tx, ws_room_peers, local_peer_str, local_device_id, announce);
    if sent > 0 {
        hollow_log!("[HOLLOW-CRDT] Announced new server {server_id} to {sent} online sibling device(s)");
    }
}

// ── Relay offline catch-up registration ──────────────────────────────

/// Register this server's text channels with the relay's per-channel offline
/// ring buffer when the CRDT `relay_catchup_secs` setting is on. Registration
/// is additive/refresh-only — it NEVER clears here, because a member holding a
/// stale CRDT (flag still off locally) must not wipe a buffer everyone else
/// relies on. Clearing happens only at the Owner/Admin toggle site in
/// `handle_update_server_setting`.
pub(crate) fn register_relay_catchup(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    state: &ServerState,
    server_id: &str,
) {
    let secs = state.relay_catchup_secs();
    if secs <= 0 {
        return;
    }
    let channels: Vec<String> = state
        .channels
        .values()
        .filter(|c| matches!(c.channel_type, crate::crdt::server_state::ChannelType::Text))
        .map(|c| c.channel_id.clone())
        .collect();
    if channels.is_empty() {
        return;
    }
    hollow_log!("[HOLLOW-TOPIC] Registering relay catch-up rings for {server_id}: {} channel(s), retention {secs}s", channels.len());
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SetTopicBuffer {
        room_code: server_id.to_string(),
        channels,
        retention_secs: secs,
        clear: false,
    });
}

/// Age window (seconds) for a relay topic catch-up request: how far back the
/// relay should replay ring frames for this channel. Derived from the local
/// channel watermark (newest stored message) + a 30-minute overlap, mirroring
/// the peer-sync `SYNC_LOOKBACK_MS` pattern — frames older than what we
/// already hold are undecryptable (MLS consumed those generations) and were
/// pure SecretReuse noise on every reconnect. 0 = no watermark (fresh
/// channel) → replay the whole retention window.
pub(crate) fn catchup_watermark_age_secs(
    db_path: &str,
    db_passphrase: &str,
    server_id: &str,
    channel_id: &str,
) -> i64 {
    const LOOKBACK_SECS: i64 = 1800;
    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else {
        return 0;
    };
    match store.get_latest_channel_timestamp(server_id, channel_id) {
        Ok(Some(ts_ms)) if ts_ms > 0 => {
            let now_ms = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis() as i64;
            ((now_ms - ts_ms) / 1000 + LOOKBACK_SECS).max(LOOKBACK_SECS)
        }
        _ => 0,
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
        let channel_id = format!("{}-{}", &server_id[..8.min(server_id.len())], hex::encode(&{
            let mut buf = [0u8; 4];
            getrandom::fill(&mut buf).expect("system RNG unavailable — cannot generate secure random bytes");
            buf
        }));
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

        // Broadcast to server members — MLS first, plaintext twin always.
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
    // Local permission gate (MANAGE_SERVER, override-aware), mirroring what
    // every RECEIVER enforces for ServerSettingChanged. Without it an
    // unauthorized FFI call applies the op locally, the network rejects it,
    // and the caller's own state diverges from everyone else's.
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

    // CRDT-op-only deletion (replaces the old missable one-shot ServerDeleteBroadcast):
    // create a replicable `ServerDeleted` tombstone op. Online members get it via the
    // normal CrdtOpBroadcast gossip near-instantly; an OFFLINE member reconciles it on
    // reconnect via grow-only SyncRequest/SyncResponse (the owner RETAINS the tombstone
    // shell + op_log to serve it). This is what lets an offline member ever learn the
    // server is gone — the previous one-shot was missed forever.
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    let Some(state) = server_states.get_mut(&server_id) else { return false; };
    let op = state.create_op(CrdtPayload::ServerDeleted { deleted_at: now_ms });
    let _ = state.apply_op(&op); // marks shell `deleted`, drains membership, keeps op_log

    // Persist the tombstone shell + the op (op_log is skip_serializing → the op MUST be
    // persisted via insert_op or the owner stops serving it after restart).
    crdt_store.insert_op(op.clone());
    crdt_store.save_state_snapshot(server_id.clone(), state);

    // Fan the tombstone op to remaining members (MLS-first, plaintext fallback) AND to
    // our OWN siblings (the master-keyed member broadcast excludes our identity).
    if let Ok(op_json) = serde_json::to_string(&op) {
        let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
        let mls_sent = if mls_ok {
            let envelope = MessageEnvelope::CrdtOp { sid: server_id.clone(), op_json: op_json.clone() };
            send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &envelope, crypto_store).is_ok()
        } else { false };
        let data = serde_json::to_vec(&HavenMessage::CrdtOpBroadcast {
            server_id: server_id.clone(), op_json,
        }).unwrap_or_default();
        if !mls_sent {
            // Plaintext fallback to remaining members (MLS absent / epoch stale).
            broadcast_raw_to_members(ws_cmd_tx, ws_room_peers, state, local_peer_str, data.clone());
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

pub(crate) async fn handle_join_server(
    pending_server_joins: &mut HashMap<String, PendingJoin>,
    mls: &Option<MlsManager>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    cmd_tx: &mpsc::Sender<NodeCommand>,
    server_id: String,
    twitch_proof_json: Option<String>,
    nsfw_confirmed: bool,
    _crdt_store: &CrdtStore,
) {
    hollow_log!("[HOLLOW-CRDT] Joining server {server_id}");
    pending_server_joins.insert(server_id.clone(), PendingJoin {
        twitch_proof_json: twitch_proof_json.clone(),
        nsfw_confirmed,
    });



    // Generate MLS KeyPackage to send alongside join request.
    let _mls_kp_b64 = mls.as_ref().and_then(|m| {
        match m.generate_key_package() {
            Ok(kp) => Some(base64::engine::general_purpose::STANDARD.encode(&kp)),
            Err(e) => { hollow_log!("[HOLLOW-MLS] Failed to generate KeyPackage: {e}"); None }
        }
    });

    // Join the WS relay room for this server so we can discover members.
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
        room_code: server_id.clone(),
    });

    // Send join request to any peers already visible in WS rooms.
    if let Some(room_peers) = ws_room_peers.get(&server_id) {
        for peer in room_peers.iter() {
            send_message_to_peer(
                ws_cmd_tx, ws_room_peers,
                peer, HavenMessage::ServerJoinRequest {
                    server_id: server_id.clone(),
                    twitch_proof_json: twitch_proof_json.clone(),
                    nsfw_confirmed,
                },
            );
            hollow_log!("[HOLLOW-CRDT] Sent join request to {peer} for {server_id}");
        }
    }
    // If no peers found yet, the PeerJoined/RoomMembers handler
    // will pick up pending_server_joins and send the request then.

    // Spawn 15s timeout — if still pending, emit ServerJoinFailed.
    let timeout_cmd_tx = cmd_tx.clone();
    let timeout_sid = server_id.clone();
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_secs(15)).await;
        let _ = timeout_cmd_tx.send(NodeCommand::CheckPendingJoinTimeout {
            server_id: timeout_sid,
        }).await;
    });
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

        // Permission check: can the local user change this peer's role?
        if !state.can_change_role(&local_peer, &peer_id, &new_member_role) {
            hollow_log!("[HOLLOW-CRDT] Permission denied: cannot change {peer_id} to {new_role} in {server_id}");
            return deny(event_tx, &format!("Permission denied: cannot change role to {new_role}")).await;
        }

        hollow_log!("[HOLLOW-CRDT] Changing role of {peer_id} to {new_role} in {server_id}");
        // The payload priority (the author's role priority, not the target's)
        // is wire-compat metadata for old clients that still merge
        // priority-first; current merge is pure HLC LWW, so demotions land
        // because the demotion op is later — can_change_role carries authority.
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
        // Permission check
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

/// Revoke one of OUR OWN devices (manual, lost/stolen). Bumps our master-signed
/// device list with the target tombstoned, re-broadcasts it to friends so they
/// converge (and stop encrypting to the revoked device), emits `DeviceListUpdated`,
/// and returns the revoked device id so the caller (which holds olm/mls/pending_mls
/// state) drops the Olm session + removes the MLS leaf where it coordinates.
/// Returns `None` if the revocation was rejected (self, or not our device).
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

    // CRITICAL — send the tombstone TO THE REVOKED DEVICE FIRST. It is the one peer
    // that most needs the v+1 list naming itself revoked: its ingest fires
    // `SelfRevoked` → wipe + relaunch (the honest self-teardown). We send it first,
    // before the relay drops it from our shared rooms as a side effect of the MLS
    // leaf removal, so the message still routes. (Previously we SKIPPED the target
    // entirely — "why message a device we're removing?" — which meant the revoked
    // device NEVER learned it was revoked, kept running as the master, and kept
    // talking to friends as a phantom peer. That was the whole bug.)
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

/// "Reset Device List" — tombstone EVERY sibling device in one version bump and
/// propagate it: friends converge + drop them, and each revoked sibling self-nukes
/// on ingest. Returns the device ids that were revoked (so the caller drops their
/// Olm sessions + MLS leaves), or `None` if we were already the sole device.
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

        // Leaving is an identity-level action: `skip: None` — the fan also sends
        // the self-removal op to our OWN siblings so they leave the server too
        // (each applies the self-MemberRemoved, allowed because peer_id ==
        // op.author). The acting device already left.
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

    // Remove server from local state.
    server_states.remove(&server_id);


    // Leave the WS relay room.
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom {
        room_code: server_id.clone(),
    });

    // Delete server state from DB.
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
    // Self-assign/unassign: any member can toggle their own labels.
    // All other label ops require MANAGE_ROLES.
    let is_self_toggle = match &payload {
        CrdtPayload::LabelAssigned { peer_id, .. }
        | CrdtPayload::LabelUnassigned { peer_id, .. } => peer_id == local_peer_str,
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

// ── 10e2. Custom emote operations ───────────────────────────────────

/// Author an EmojiAdded / EmojiRemoved op. Mirrors [handle_label_op]
/// (apply → CrdtStore persist → ServerUpdated → MLS broadcast + plaintext
/// twin). The emote BYTES never ride the CRDT — the caller stored them in
/// the local emote blob cache before issuing the command; members pull them
/// on demand via EmoteRequest.
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

    // Per-channel MLS subgroup (Option B): if the channel is no longer
    // restricted (now Everyone/public), tear down its subgroup locally —
    // messages revert to the server-wide group. (Becoming restricted is
    // handled by the swarm reconciler, which owns the pending batch queues.)
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
    author_broadcast_op(
        server_states, event_tx, ws_cmd_tx, ws_room_peers, gossip_overlays, local_peer_str,
        &server_id,
        OpGate::Perm(Permission::MANAGE_CHANNELS),
        Some("Permission denied: cannot manage channels"),
        CrdtPayload::ChannelPostingChanged { channel_id: channel_id.clone(), posting: posting.clone() },
        &format!("Setting channel {channel_id} posting to {posting}"),
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

// ── 17. CheckPendingJoinTimeout ───────────────────────────────────────

pub(crate) async fn handle_check_pending_join_timeout(
    pending_server_joins: &mut HashMap<String, PendingJoin>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    server_id: String,
    _crdt_store: &CrdtStore,
) {
    if pending_server_joins.remove(&server_id).is_some() {
        hollow_log!("[HOLLOW-CRDT] Server join timed out for {server_id}");
        let _ = event_tx.send(NetworkEvent::ServerJoinFailed {
            server_id: server_id.clone(),
            reason: "No members responded within 15 seconds".to_string(),
        }).await;
        // Leave the WS room since join failed.
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom {
            room_code: server_id,
        });
    }
    // If already removed (join succeeded), this is a no-op.
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
    // Shared ingest permission matrix (ServerState::op_allowed) — override-aware,
    // matching the local send handlers' `has_permission` gate, and validating
    // op.author (the creator), never the transport sender.
    if !state.op_allowed(&op) {
        hollow_log!("[HOLLOW-SECURITY] REJECTED MLS CrdtOp from {} — insufficient permission", op.author);
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
                // Owner tombstoned the server. Shell retained (serve to our offline
                // peers); UI drops the server. (MLS group teardown is handled by the
                // plaintext CrdtOpBroadcast path / left to lazily orphan here — this
                // MLS handler has no mls handle.)
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
                if let Some(ch) = state.channels.get(channel_id) {
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
            | CrdtPayload::LabelCreated { .. }
            | CrdtPayload::LabelDeleted { .. }
            | CrdtPayload::LabelUpdated { .. }
            | CrdtPayload::LabelAssigned { .. }
            | CrdtPayload::LabelUnassigned { .. }
            | CrdtPayload::EmojiAdded { .. }
            | CrdtPayload::EmojiRemoved { .. } => {
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
    // SECURITY (tombstone): drop a `ServerDeleted` op not authored by the Owner
    // (validated against OUR role map) BEFORE persist + merge — never trust the
    // relayer. Mirrors the plaintext SyncResponse path.
    let incoming_ops: Vec<crate::crdt::operations::CrdtOp> = incoming_ops
        .into_iter()
        .filter(|op| {
            if let crate::crdt::operations::CrdtPayload::ServerDeleted { .. } = op.payload {
                state.get_role(&op.author) == crate::crdt::operations::MemberRole::Owner
            } else { true }
        })
        .collect();
    // Persist synced ops — op_log is not serialized in the state
    // JSON, so ops merged in RAM are lost on restart without this
    // (a member then serves a near-empty op log to future joiners).
    for op in &incoming_ops {
        if op.server_id == sid {
            crdt_store.insert_op(op.clone());
        }
    }
    let Ok(applied) = crate::crdt::sync::merge_ops(state, &incoming_ops) else { return };
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
    if !server_states.contains_key(&sid) { return; }
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
    if !server_states.contains_key(&sid) { return; }
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
        // SECURITY: a PRESENT-but-INVALID signature is tampering, not legacy
        // data — drop the whole item (text, edit, file metadata, reactions and
        // the hidden flag all ride it). Unsigned history still replicates; see
        // `check_backfill_signature`.
        if sig_check == BackfillSig::Forged {
            hollow_log!(
                "[HOLLOW-SECURITY] REJECTED synced channel message in {sid}/{cid} claiming sender {} — signature present but INVALID (mid={:?}, ts={})",
                msg.s, msg.mid, msg.ts
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
/// rule: absent = tolerated legacy history, present-but-invalid = rejected.
/// An edited row is verified against its EDIT signature (`edited_at` + current
/// text) rather than skipped.
fn verify_sync_item_sig(
    msg: &SyncMessageItem,
    sid: &str,
    cid: &str,
    pk_cache: &mut PkCache,
) -> BackfillSig {
    let extras = super::crypto_handler::SignedExtras {
        mid: msg.mid.as_deref(),
        reply_to: msg.reply_to.as_deref(),
        file_id: msg.file_id.as_deref(),
        order_us: msg.order_us,
        lp_digest: msg.lp_digest.as_deref(),
    };
    super::crypto_handler::check_backfill_signature(
        &msg.s, "ch", &format!("{sid}:{cid}"),
        msg.ts, msg.edited_at, &extras, &msg.t,
        msg.sig.as_deref(), msg.pk.as_deref(), pk_cache,
    )
}

/// Insert / edit / repair one synced channel message row. Returns (1 when a
/// NEW row was inserted — feeds the sync counter, else 0; the edited-event to
/// emit, if any).
fn upsert_synced_channel_message(
    store: &crate::storage::MessageStore,
    sid: &str,
    cid: &str,
    msg: &SyncMessageItem,
    is_mine: bool,
    sig_verified: bool,
) -> (u32, Option<NetworkEvent>) {
    let already_exists = msg.mid.as_ref()
        .map(|mid| store.channel_message_exists(mid))
        .unwrap_or(false);

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
            return (1, None);
        }
        return (0, None);
    }
    if let (Some(edit_ts), Some(mid)) = (msg.edited_at, &msg.mid) {
        if store.edit_channel_message(
            mid, &msg.t, edit_ts,
            msg.sig.as_deref(),
            msg.pk.as_deref(),
        ).unwrap_or(false) {
            return (0, Some(NetworkEvent::ChannelMessageEdited {
                server_id: sid.to_string(),
                channel_id: cid.to_string(),
                message_id: mid.clone(),
                new_text: msg.t.clone(),
                edited_at: edit_ts,
                signature: msg.sig.clone(),
                public_key: msg.pk.clone(),
            }));
        }
    } else if sig_verified {
        repair_wedged_sender(store, msg, is_mine);
    }
    (0, None)
}

/// Multi-device self-heal: the row already exists but may have been stored
/// under a sender DEVICE id (pre device→master resolve fix) with signature
/// material that no longer verifies on this device — the "12D3KooW… +
/// unverified signature" bubble. THIS synced copy's signature verified
/// (proving authentic sender + text), so if our stored row is attributed to a
/// different sender, repair it to the verified one. INSERT OR IGNORE blocked
/// re-inserting the good copy, so this UPDATE is the only path to converge.
/// Safe: the verify also binds the PeerId to the pubkey, so this can only
/// ever replace an attribution with a cryptographically authentic one.
///
/// The repaired row is not announced with a fake edit event (that would mark
/// it "(edited)" and wouldn't move the in-memory senderId anyway); the
/// corrected sender renders on the next channel open / loadHistory, which is
/// when this sync runs.
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
    if let Some(ref fm) = msg.file_meta {
        let ctx_id = format!("{sid}:{cid}");
        let _ = store.insert_file_metadata(
            &fm.fid, &fm.name, &fm.ext, &fm.mime,
            fm.size, 0, fm.img, fm.w, fm.h,
            fm.mid.as_deref(), "channel", &ctx_id,
            &fm.sender, is_mine, fm.ts,
            fm.vthumb.as_ref(),
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
        });
    }
    if let Some(mid) = &msg.mid {
        for r in &msg.reactions {
            let _ = store.add_reaction(
                mid, &r.e, &r.p, r.ts,
                r.sig.as_deref(), r.pk.as_deref(),
            );
        }
    }
    events
}
