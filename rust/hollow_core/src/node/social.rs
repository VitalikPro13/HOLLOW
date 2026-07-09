use std::collections::HashMap;

use base64::Engine;
use tokio::sync::mpsc;

use crate::crdt::server_state::ServerState;
use crate::crypto::MlsManager;
use super::crypto_handler::{
    peer_is_reachable, send_mls_broadcast, send_message_to_peer, send_raw_to_peer,
};
use super::types::*;

/// The concrete, ONLINE device peer_ids to target when we want to reach a friend
/// identity. A bare master id authenticates as no socket, so a send addressed to it
/// is dropped — we must resolve to real devices. Sources, deduped: the literal
/// `original` id (the device that contacted us, if any), every resolver-known device
/// of `master`, AND every peer currently in a SHARED ROOM that resolves to `master`
/// (the load-bearing source when we don't yet hold the friend's device list). Only
/// ids that are actually reachable (in some room we know) are returned.
pub(crate) fn friend_device_targets(
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    original: &str,
    master: &str,
) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    // EXACT room membership, not identity-wide `peer_is_reachable`: this function
    // returns socket-addressable DEVICE ids for raw SendDirect. An identity-wide
    // check would admit the bare MASTER whenever any of its devices is online —
    // and a send addressed to the master is silently dropped.
    let mut push = |id: String, out: &mut Vec<String>| {
        if !out.contains(&id)
            && ws_room_peers.values().any(|peers| peers.contains(&id))
        {
            out.push(id);
        }
    };
    push(original.to_string(), &mut out);
    for d in super::resolver::devices_for(master) {
        push(d, &mut out);
    }
    // Any room peer that resolves to the friend's master is a live device of theirs.
    for peers in ws_room_peers.values() {
        for p in peers {
            if super::resolver::resolve(p) == master {
                push(p.clone(), &mut out);
            }
        }
    }
    out
}

/// Handle `NodeCommand::SendFriendRequest`.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_send_friend_request(
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    pending_friend_requests: &mut HashMap<String, i64>,
    pending_friend_removals: &mut std::collections::HashSet<String>,
    local_peer_str: &str,
    peer_id_str: String,
    db_path: &str,
    db_passphrase: &str,
) {
    if super::resolver::same_identity(&peer_id_str, local_peer_str) {
        hollow_log!("[HOLLOW-FRIENDS] Rejected self-friend request");
        let _ = event_tx.send(NetworkEvent::Error {
            message: "Cannot send a friend request to yourself".into(),
        }).await;
        return;
    }

    hollow_log!("[HOLLOW-FRIENDS] Sending friend request to {peer_id_str}");

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    // CANCEL any pending REMOVAL for this person — re-adding a friend you just
    // removed (before the removal was delivered) must NOT also fire the queued
    // FriendRemove. Without this, the request drain and the removal drain BOTH
    // fired on the target's reconnect, sending a contradictory FriendRequest +
    // FriendRemove → the peer removed us back and the friendship ping-ponged.
    let cancel_master = super::resolver::resolve(&peer_id_str);
    pending_friend_removals.remove(&cancel_master);
    pending_friend_removals.remove(&peer_id_str);

    // Save as pending outgoing, keyed by the target's MASTER (the swarm already
    // resolved a nickname-result device→master before calling us; a pasted peer-ID is
    // the master; resolving here is idempotent and covers any remaining device id).
    let master = super::resolver::resolve(&peer_id_str);
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            // Fold any pre-existing row stranded under the device id (parity with
            // the accept path) so re-adding never leaves a stale device-keyed dup.
            if master != peer_id_str {
                let _ = store.migrate_friend_to_master(&peer_id_str, &master);
            }
            let _ = store.save_friend(&master, "pending", "outgoing", now);
        }
    }

    // Register DM room code immediately so signaling can help
    // discover the peer even before they accept. Use the target's MASTER (resolved
    // above) so we join the SAME pure room the target will (`dm_room_code` is
    // f(masters)); a nickname-resolved device id would otherwise diverge the room.
    let local_peer = local_peer_str.to_string();
    let room = dm_room_code(&local_peer, &master);
    // Join WS relay room for this DM.
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
        room_code: room,
    });

    // Send via the target peer's inbox room (every peer joins inbox:{peer_id} on startup).
    // Join their inbox temporarily to send the request.
    let inbox_room = format!("inbox:{}", peer_id_str);
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
        room_code: inbox_room.clone(),
    });

    // Try to send immediately if the peer has an online DEVICE (shared server or
    // inbox). The send must target concrete devices: `peer_id_str` may be (or
    // resolve to) a bare MASTER, which no socket authenticates as — a direct
    // `send_message_to_peer(master)` is silently dropped AND would have skipped
    // the queue below, losing the request entirely.
    let targets = friend_device_targets(&ws_room_peers, &peer_id_str, &master);
    if !targets.is_empty() {
        for t in &targets {
            send_message_to_peer(
                &ws_cmd_tx, &ws_room_peers,
                t, HavenMessage::FriendRequest { requested_at: now },
            );
        }
        // Defense in depth: we only joined the TARGET's inbox to DELIVER the request.
        // Leaving it now stops us lingering in the target's inbox set, where their
        // sibling-proof challenge would (correctly) reject us but we needn't be at all.
        // WS commands are ordered on one channel, so this leave is processed AFTER the
        // SendDirect above. The friend ACCEPT comes back via the shared DM room (joined
        // above), not the inbox, so leaving here does not break acceptance.
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom {
            room_code: inbox_room.clone(),
        });
    } else {
        // Peer not in any WS room yet — queue the request.
        // It will be sent when the peer appears via PeerJoined/RoomMembers
        // (e.g., when we join their inbox room and the relay confirms).
        pending_friend_requests.insert(peer_id_str.clone(), now);
        hollow_log!("[HOLLOW-FRIENDS] Peer {peer_id_str} not reachable yet, queued friend request for inbox delivery");
    }

    let _ = event_tx.send(NetworkEvent::FriendRequestReceived {
        peer_id: peer_id_str,
    }).await;
}

/// Handle `NodeCommand::AcceptFriendRequest`.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_accept_friend_request(
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    local_peer_str: &str,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    is_invisible: bool,
    peer_id_str: String,
    pending_friend_accepts: &mut HashMap<String, i64>,
    pending_friend_removals: &mut std::collections::HashSet<String>,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-FRIENDS] Accepting friend request from {peer_id_str}");

    // Update to accepted, keyed by the friend's MASTER. The incoming peer_id may be a
    // DEVICE id (e.g. a nickname-resolved request, or a multi-device sender), but
    // friendships key on the master (presence/DM/profile all do). Resolve here so the
    // row is correct from the moment of acceptance — otherwise it stays stranded under
    // the device id until the next device-list ingest re-keys it (which never happens
    // if the device list was already ingested BEFORE the accept). Also migrate any
    // pre-existing pending row that was saved under the device id.
    let master = super::resolver::resolve(&peer_id_str);

    // CANCEL any pending REMOVAL for this person — accepting a (re)friend supersedes a
    // not-yet-delivered removal. Otherwise the removal drain would fire alongside the
    // accept and the peer would remove us back.
    pending_friend_removals.remove(&master);
    pending_friend_removals.remove(&peer_id_str);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            if master != peer_id_str {
                let _ = store.migrate_friend_to_master(&peer_id_str, &master);
            }
            let _ = store.save_friend(&master, "accepted", "", now);
        }
    }

    // Send acceptance. The send must target a DEVICE (the bare master authenticates as
    // no socket → dropped). Build the target set from: the original id (may be the
    // device that sent the request), every resolver-known device of the master, AND —
    // crucially — every peer CURRENTLY IN A SHARED ROOM that resolves to the master.
    // That last source is what makes this work when we DON'T yet hold the friend's
    // device list (so `devices_for` is empty) but their device is right there in our
    // DM/inbox room: the master id alone is unreachable.
    let targets = friend_device_targets(&ws_room_peers, &peer_id_str, &master);
    for t in &targets {
        send_message_to_peer(
            &ws_cmd_tx, &ws_room_peers,
            t, HavenMessage::FriendAccept,
        );
    }
    // ALWAYS queue the acceptance for redelivery, keyed by the requester's MASTER.
    // The requester's device can race the accept: it delivers the request, then
    // leaves our inbox, and its DM-room join may not have populated our
    // `ws_room_peers` yet at the instant we accept — so `friend_device_targets`
    // can be EMPTY here even though the device shows up a beat later. It can also
    // simply be offline by the time the human clicks Accept. Without a queue, the
    // FriendAccept is lost and the requester never learns we accepted (their row
    // stays "pending outgoing" forever — the exact bug). The pending-accepts drain
    // on PeerJoined/RoomMembers re-sends it the moment the requester's device
    // appears; FriendAccept is idempotent (the receiver just re-saves "accepted").
    pending_friend_accepts.insert(master.clone(), now);
    hollow_log!(
        "[HOLLOW-FRIENDS] Accepted {master}: sent FriendAccept to {} device(s) now, queued for redelivery",
        targets.len()
    );

    // Register DM room code with signaling for internet discovery. Use the MASTER so
    // both sides compute the SAME pure `dm_room_code` (resolving inside it would
    // diverge the room per-side).
    let local_peer = local_peer_str.to_string();
    let room = dm_room_code(&local_peer, &master);
    // Join WS relay room for this DM.
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
        room_code: room,
    });

    // Push OUR profile + device list to the friend now (over the inbox/DM room where
    // they're reachable), so they learn our device→master mapping. We are the ACCEPTER:
    // if we never sent our own request (we only clicked Accept), no FriendRequest
    // handler on the friend pushed our list to them — this is the path that delivers
    // it. Fan to the friend's online devices.
    for t in &friend_device_targets(&ws_room_peers, &peer_id_str, &master) {
        send_own_profile_to_peer(
            &ws_cmd_tx, &ws_room_peers,
            local_peer_str, master_keypair, device_peer_id, t,
            is_invisible,
            db_path, db_passphrase,
        );
    }

    let _ = event_tx.send(NetworkEvent::FriendRequestAccepted {
        peer_id: peer_id_str,
    }).await;
}

/// Handle `NodeCommand::RejectFriendRequest`.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_reject_friend_request(
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    peer_id_str: String,
    pending_friend_requests: &mut HashMap<String, i64>,
    pending_friend_accepts: &mut HashMap<String, i64>,
    db_path: &str,
    db_passphrase: &str,
) {
    // The UI may pass a DEVICE id (a pending incoming request is keyed under the
    // sender's device id until the device-list ingest re-keys it) OR a master.
    // Delete BOTH the resolved-master row and the original-id row so the pending
    // request is cleared regardless of which key it currently lives under.
    let master = super::resolver::resolve(&peer_id_str);
    hollow_log!("[HOLLOW-FRIENDS] Rejecting friend request from {peer_id_str} (master {master})");

    // CANCEL any pending outgoing REQUEST and queued ACCEPT for this person —
    // rejecting supersedes them. In the MUTUAL case (both sides requested), our
    // own outgoing request was still queued; without this the request drain
    // (swarm.rs PeerJoined/RoomMembers) re-sends it after the reject, the peer
    // accepts, and the pair silently becomes friends behind the user's back (the
    // reject/accept race). Mirrors handle_remove_friend's cancellation.
    pending_friend_requests.remove(&master);
    pending_friend_requests.remove(&peer_id_str);
    pending_friend_accepts.remove(&master);
    pending_friend_accepts.remove(&peer_id_str);

    // Remove from friends table (both possible keys).
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let _ = store.remove_friend(&master);
            if master != peer_id_str {
                let _ = store.remove_friend(&peer_id_str);
            }
        }
    }

    // Fan the reject to the requester's online DEVICES — the row (and often the
    // UI key) is the MASTER, which no socket authenticates as, so a raw send to
    // it was silently dropped and a multi-device requester's outgoing request
    // stayed "pending" forever. Rejects stay best-effort (no redelivery queue,
    // unlike accepts): an offline requester simply never learns, by design.
    for t in &friend_device_targets(&ws_room_peers, &peer_id_str, &master) {
        send_message_to_peer(
            &ws_cmd_tx, &ws_room_peers,
            t, HavenMessage::FriendReject,
        );
    }

    let _ = event_tx.send(NetworkEvent::FriendRequestRejected {
        peer_id: peer_id_str,
    }).await;
}

/// Handle `NodeCommand::RemoveFriend`.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_remove_friend(
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    peer_id_str: String,
    pending_friend_removals: &mut std::collections::HashSet<String>,
    pending_friend_requests: &mut HashMap<String, i64>,
    pending_friend_accepts: &mut HashMap<String, i64>,
    db_path: &str,
    db_passphrase: &str,
) {
    // The UI passes the friend's MASTER id (the friends list collapses
    // device→master). The friend row is master-keyed, so resolve here too and
    // always delete the MASTER row — a raw device-id delete silently no-ops
    // against a master-keyed row (the bug where "Remove friend" did nothing /
    // left a ghost). `resolve` is idempotent for a single-device friend.
    let master = super::resolver::resolve(&peer_id_str);
    hollow_log!("[HOLLOW-FRIENDS] Removing friend {peer_id_str} (master {master})");

    // CANCEL any pending outgoing REQUEST and queued ACCEPT for this person —
    // removing supersedes them. Otherwise a queued request/accept would re-fire on
    // the peer's next appearance and contradict the removal (the ping-pong where
    // request + remove went out together and the friendship flapped).
    pending_friend_requests.remove(&master);
    pending_friend_requests.remove(&peer_id_str);
    pending_friend_accepts.remove(&master);
    pending_friend_accepts.remove(&peer_id_str);

    // Delete the local row up-front, unconditionally. Removal is a local-first
    // action — it must take effect immediately whether or not the peer is online
    // to receive the notification. Also clean up any legacy row still keyed under
    // the original id (device-stranded) so no duplicate survives.
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let _ = store.remove_friend(&master);
        if master != peer_id_str {
            let _ = store.remove_friend(&peer_id_str);
        }
    }

    // Notify the friend. The bare master authenticates as NO socket, so fan the
    // FriendRemove out to every online device of theirs (devices_for(master) ∪
    // live room peers resolving to master). If none are reachable, queue a
    // tombstone keyed by the MASTER and a pending entry (the drain resolves a
    // reconnecting device→master to match it).
    let targets = friend_device_targets(&ws_room_peers, &peer_id_str, &master);
    if targets.is_empty() {
        pending_friend_removals.insert(master.clone());
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let _ = store.save_friend(&master, "removed", "outgoing", 0);
        }
        hollow_log!("[HOLLOW-FRIENDS] Friend {master} not reachable, queued removal for delivery");
    } else {
        for t in &targets {
            send_message_to_peer(
                &ws_cmd_tx, &ws_room_peers,
                t, HavenMessage::FriendRemove,
            );
        }
        hollow_log!("[HOLLOW-FRIENDS] Sent FriendRemove for {master} to {} device(s)", targets.len());
    }

    // NOTE: we deliberately do NOT LeaveRoom the DM room here. Leaving right after the
    // send raced our own FriendRemove — the relay processed our room-leave and dropped
    // us from the room's routing set BEFORE it fanned out the message, so the peer never
    // received the removal (one-sided removal). The ex-friend's lingering presence is a
    // pure UI-count concern, handled in the Network column (it counts only peers that
    // resolve to an accepted friend), not by tearing down the room mid-send.

    let _ = event_tx.send(NetworkEvent::FriendRemoved {
        peer_id: master,
    }).await;
}

/// Handle `NodeCommand::SendTypingIndicator`.
pub(crate) fn handle_send_typing_indicator(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    mls: &mut Option<MlsManager>,
    server_states: &HashMap<String, crate::crdt::server_state::ServerState>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    crypto_store: &crate::crypto::CryptoStore,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
) {
    let msg = HavenMessage::TypingIndicator {
        server_id: server_id.clone(),
        channel_id: channel_id.clone(),
    };

    if server_id.is_empty() {
        // DM typing: `channel_id` is the recipient's MASTER id (what the UI keys
        // the DM on). Multi-device: the master authenticates as NO socket — only
        // its device peer_ids do — so `send_message_to_peer(master)` finds no room
        // and silently drops (the bug where a multi-device / keystone-rotated
        // friend never saw "typing…"). Fan out to the recipient's DEVICES, exactly
        // like a DM message: the device set is `devices_for(master)` UNION every
        // peer currently in the DM room that resolves to that master (live
        // presence is authoritative — robust to a stale/polluted stored list).
        // Single-device recipient → the set is just the master id itself (it both
        // is the device and authenticates as it), so this is the old behavior.
        let recipient_master = super::resolver::resolve(&channel_id);
        let dm_room = super::types::dm_room_code(local_peer_str, &recipient_master);
        let mut targets: std::collections::HashSet<String> =
            super::resolver::devices_for(&recipient_master).into_iter().collect();
        if let Some(peers) = ws_room_peers.get(&dm_room) {
            for p in peers {
                if super::resolver::resolve(p) == recipient_master {
                    targets.insert(p.clone());
                }
            }
        }
        // Fallback for a single-device recipient (no device links): send to the
        // master id as-is — it IS the device that authenticates.
        if targets.is_empty() {
            targets.insert(recipient_master.clone());
        }
        let mut sent_to = 0u32;
        for target in &targets {
            // Skip the bare master only when we also have real device ids (it
            // authenticates as nothing); keep it in the single-device fallback.
            if target == &recipient_master && targets.len() > 1 {
                continue;
            }
            // Route into the deterministic DM room (not a first-match lookup):
            // the target may be co-present in several rooms and the first match
            // could be one it has since left, silently losing the typing frame.
            if super::crypto_handler::ws_room_for_peer(&ws_room_peers, target).is_some() {
                super::crypto_handler::send_message_to_peer_in_room(
                    &ws_cmd_tx, &dm_room, target, msg.clone(),
                );
                sent_to += 1;
            }
        }
        hollow_log!(
            "[HOLLOW-TYPING] DM typing → master {recipient_master}: sent to {sent_to} device(s)"
        );
    } else {
        // Channel typing: MLS broadcast first, plaintext fallback.
        let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
        hollow_log!("[HOLLOW-TYPING] Channel typing send for {server_id}/{channel_id} (mls={mls_ok})");
        if mls_ok {
            let envelope = MessageEnvelope::Typing { sid: server_id.clone(), cid: channel_id.clone() };
            if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), &ws_cmd_tx, &server_id, &envelope, crypto_store) {
                hollow_log!("[HOLLOW-MLS] Typing broadcast failed: {e}");
            }
        } else {
            // Plaintext fallback: members are MASTER-keyed and the master has no
            // socket — fan each out to its online devices (was dropping before).
            if let Some(server) = server_states.get(&server_id) {
                let data = serde_json::to_vec(&msg).unwrap_or_default();
                for member_peer_str in server.members.keys() {
                    if super::resolver::same_identity(member_peer_str, local_peer_str) { continue; }
                    super::crypto_handler::send_raw_to_identity(
                        &ws_cmd_tx, &ws_room_peers, member_peer_str, data.clone(),
                    );
                }
            }
        }
    }
}

/// Handle `NodeCommand::SetInvisible`.
/// Broadcasts StatusUpdate to every unique connected peer across all WS rooms.
pub(crate) fn handle_set_invisible(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    local_peer_str: &str,
    invisible: bool,
    is_invisible: &mut bool,
) {
    *is_invisible = invisible;
    let status = if invisible { "invisible" } else { "online" };
    hollow_log!("[HOLLOW-STATUS] Setting invisible={invisible}, broadcasting status={status}");
    let msg = HavenMessage::StatusUpdate { status: status.to_string() };

    let data = serde_json::to_vec(&msg).unwrap_or_default();
    let mut sent_to = std::collections::HashSet::new();
    for peers in ws_room_peers.values() {
        for peer in peers {
            if peer != local_peer_str && sent_to.insert(peer.clone()) {
                send_raw_to_peer(ws_cmd_tx, ws_room_peers, peer, data.clone());
            }
        }
    }
}

/// Handle `NodeCommand::UpdateProfile`.
pub(crate) async fn handle_update_profile(
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    mls: &mut Option<MlsManager>,
    server_states: &HashMap<String, crate::crdt::server_state::ServerState>,
    crypto_store: &crate::crypto::CryptoStore,
    local_peer_str: &str,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    display_name: String,
    status: String,
    about_me: String,
    avatar_bytes: Option<Vec<u8>>,
    banner_bytes: Option<Vec<u8>>,
    is_invisible: bool,
    twitch_username: String,
    showcase_board: Option<String>,
    showcase_assets: Option<Vec<u8>>,
    db_path: &str,
    db_passphrase: &str,
) {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    // None = no change → empty string. Some(empty) = clear → "CLEAR". Some(data) = base64.
    let avatar_b64 = match &avatar_bytes {
        None => String::new(),
        Some(b) if b.is_empty() => "CLEAR".to_string(),
        Some(b) => base64::engine::general_purpose::STANDARD.encode(b),
    };
    let banner_b64 = match &banner_bytes {
        None => String::new(),
        Some(b) if b.is_empty() => "CLEAR".to_string(),
        Some(b) => base64::engine::general_purpose::STANDARD.encode(b),
    };
    let showcase_assets_b64 = match &showcase_assets {
        None => String::new(),
        Some(b) if b.is_empty() => "CLEAR".to_string(),
        Some(b) => base64::engine::general_purpose::STANDARD.encode(b),
    };

    // Save our own profile to DB, then hash the STORED blobs — the params may be
    // None = "unchanged", so the advertised hashes must describe what's persisted.
    // Same for the showcase board: broadcast the STORED value so receivers
    // converge even when this update didn't touch the board.
    let (avatar_hash, banner_hash, stored_showcase, stored_assets_hash) = {
        let mut stored = (String::new(), String::new(), String::new(), String::new());
        if let Ok(db) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            if let Err(e) = db.save_profile(
                &local_peer_str, &display_name, &status, &about_me, now,
                avatar_bytes.as_deref(), banner_bytes.as_deref(), &twitch_username,
                showcase_board.as_deref(), showcase_assets.as_deref(),
            ) {
                hollow_log!("[HOLLOW-SWARM] Failed to save own profile: {e}");
            }
            if let Ok(Some(p)) = db.load_profile(local_peer_str) {
                stored = (
                    profile_blob_hash(p.avatar_bytes.as_deref()),
                    profile_blob_hash(p.banner_bytes.as_deref()),
                    p.showcase_board,
                    profile_blob_hash(p.showcase_assets.as_deref()),
                );
            }
        }
        stored
    };

    // Build our master-signed device list so friends learn (tamper-proof) which
    // device peer_ids resolve to us (multi-device, Phase 6).
    let device_list = super::crypto_handler::build_local_device_list(
        master_keypair, device_peer_id, db_path, db_passphrase,
    );

    // Broadcast profile via MLS to each server room, plus plaintext to remaining peers.
    let envelope = MessageEnvelope::ProfileUpdate {
        display_name: display_name.clone(),
        status: status.clone(),
        about_me: about_me.clone(),
        updated_at: now,
        avatar_b64: avatar_b64.clone(),
        banner_b64: banner_b64.clone(),
        is_invisible,
        twitch_username: twitch_username.clone(),
        device_list: device_list.clone(),
        avatar_hash: avatar_hash.clone(),
        banner_hash: banner_hash.clone(),
        showcase_board: Some(stored_showcase.clone()),
        showcase_assets_b64: showcase_assets_b64.clone(),
        showcase_assets_hash: stored_assets_hash.clone(),
    };
    let mut mls_reached: std::collections::HashSet<String> = std::collections::HashSet::new();
    // Send via MLS to each server we're in.
    for (sid, state) in server_states.iter() {
        let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(sid));
        if mls_ok {
            if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), &ws_cmd_tx, sid, &envelope, crypto_store) {
                hollow_log!("[HOLLOW-MLS] Profile broadcast to server {sid} failed: {e}");
            } else {
                // Track members reached via MLS so we skip them in plaintext.
                for member in state.members.keys() {
                    mls_reached.insert(member.clone());
                }
            }
        }
    }
    // Plaintext fallback for peers not reached via MLS (DM peers, pre-MLS servers).
    let msg = HavenMessage::ProfileUpdate {
        display_name: display_name.clone(),
        status: status.clone(),
        about_me: about_me.clone(),
        updated_at: now,
        avatar_b64: avatar_b64.clone(),
        banner_b64: banner_b64.clone(),
        is_invisible,
        twitch_username: twitch_username.clone(),
        device_list,
        avatar_hash,
        banner_hash,
        showcase_board: Some(stored_showcase),
        showcase_assets_b64,
        showcase_assets_hash: stored_assets_hash,
    };
    hollow_log!("[HOLLOW-SWARM] Broadcasting profile update");
    {
        // Send to all reachable peers not already reached via MLS.
        let all_ws_peers: std::collections::HashSet<String> = ws_room_peers
            .values()
            .flat_map(|peers| peers.iter().cloned())
            .collect();
        let data = serde_json::to_vec(&msg).unwrap_or_default();
        for peer in &all_ws_peers {
            if peer == &local_peer_str { continue; }
            // `mls_reached` holds MASTER member keys; `peer` is a room DEVICE id —
            // collapse before the skip check, or a multi-device member always also
            // gets (and the relay always sees) the redundant plaintext copy.
            if mls_reached.contains(peer)
                || mls_reached.contains(&super::resolver::resolve(peer)) { continue; }
            send_raw_to_peer(
                &ws_cmd_tx, &ws_room_peers,
                peer, data.clone(),
            );
        }
        hollow_log!("[HOLLOW-PROFILE] Plaintext broadcast to {} peers (MLS reached {})",
            all_ws_peers.len().saturating_sub(mls_reached.len()), mls_reached.len());
    }

    // Emit event so Dart updates UI.
    let _ = event_tx.send(NetworkEvent::ProfileUpdated {
        peer_id: local_peer_str.to_string(),
    }).await;
}

/// Persist an incoming profile under the sender's MASTER identity (multi-device).
///
/// Profiles must be keyed by the master, not the raw sender DEVICE id: presence
/// and the UI collapse an identity to its master, so a profile stored under a
/// device id would never be read for the collapsed person, and a second device
/// would write a SEPARATE profile row. Resolving to the master means ANY device's
/// profile update lands on the one identity profile.
///
/// EMPTY-PROFILE GUARD: a freshly-imported device holds the master KEY but none
/// of the master's profile CONTENT, so it broadcasts a blank profile. If the
/// incoming `display_name` is empty AND we already hold a populated profile for
/// this master, SKIP the write — never let a profile-less device blank a good
/// row. Returns the master key the profile was (or would be) stored under, plus
/// whether a save actually happened.
#[allow(clippy::too_many_arguments)]
pub(crate) fn save_incoming_profile(
    sender_peer_id: &str,
    display_name: &str,
    status: &str,
    about_me: &str,
    updated_at: i64,
    avatar_bytes: Option<&[u8]>,
    banner_bytes: Option<&[u8]>,
    twitch_username: &str,
    showcase_board: Option<&str>,
    showcase_assets: Option<&[u8]>,
    db_path: &str,
    db_passphrase: &str,
) -> (String, bool) {
    let master = super::resolver::resolve(sender_peer_id);
    let Ok(db) = crate::storage::MessageStore::open(db_path, db_passphrase) else {
        return (master, false);
    };
    // Don't blank a populated identity profile with an empty one from a
    // profile-less sibling device.
    if display_name.trim().is_empty() {
        if let Ok(Some(existing)) = db.load_profile(&master) {
            if !existing.display_name.trim().is_empty() {
                hollow_log!(
                    "[HOLLOW-PROFILE] Skipped empty profile from {sender_peer_id} — keeping populated profile for master {master}"
                );
                return (master, false);
            }
        }
    }
    if let Err(e) = db.save_profile(
        &master, display_name, status, about_me, updated_at,
        avatar_bytes, banner_bytes, twitch_username, showcase_board,
        showcase_assets,
    ) {
        hollow_log!("[HOLLOW-PROFILE] Failed to save incoming profile for {master}: {e}");
        return (master, false);
    }
    (master, true)
}

/// Receive-side backstop for the showcase board JSON (UI cap is 8 KB; this is
/// "slightly above" per the profile-field cap pattern). Truncating JSON would
/// corrupt it, so an oversized board is treated as ABSENT — the receiver keeps
/// whatever it already stored.
pub(crate) fn sanitize_incoming_showcase(showcase_board: Option<&str>) -> Option<&str> {
    match showcase_board {
        Some(s) if s.len() > 16 * 1024 => None,
        other => other,
    }
}

/// Hex SHA-256 of a profile blob; empty string when there is no blob.
pub(crate) fn profile_blob_hash(bytes: Option<&[u8]>) -> String {
    match bytes {
        Some(b) if !b.is_empty() => {
            use sha2::{Digest, Sha256};
            hex::encode(Sha256::digest(b))
        }
        _ => String::new(),
    }
}

/// Send our own profile to a specific peer (used after session establishment, on PeerJoined, etc.).
///
/// LIGHT by default: avatar/banner ride as EMPTY strings ("no change" under the
/// receiver's COALESCE save) plus content hashes. A receiver whose cached blobs
/// don't match the hashes pulls the full profile ONCE via ProfileRequest. This
/// keeps the many re-announce paths (first RoomMembers, PeerJoined/is_new,
/// sibling merge, revocation pushes, friend handshakes) at ~1 KB instead of
/// re-shipping megabytes of unchanged avatar+banner on every reconnect — which
/// counted against the relay per-IP byte budget in BOTH directions and was the
/// "File Usage jumps on every restart" leak.
pub(crate) fn send_own_profile_to_peer(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    local_peer_str: &str,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    target_peer: &str,
    is_invisible: bool,
    db_path: &str,
    db_passphrase: &str,
) {
    send_own_profile_inner(
        ws_cmd_tx, ws_room_peers, local_peer_str, master_keypair, device_peer_id,
        target_peer, is_invisible, db_path, db_passphrase, false,
    );
}

/// Full-blob variant — ONLY for answering an explicit ProfileRequest (the pull
/// half of the light-announce protocol), so blobs still converge on demand.
pub(crate) fn send_own_profile_full_to_peer(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    local_peer_str: &str,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    target_peer: &str,
    is_invisible: bool,
    db_path: &str,
    db_passphrase: &str,
) {
    send_own_profile_inner(
        ws_cmd_tx, ws_room_peers, local_peer_str, master_keypair, device_peer_id,
        target_peer, is_invisible, db_path, db_passphrase, true,
    );
}

#[allow(clippy::too_many_arguments)]
fn send_own_profile_inner(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    local_peer_str: &str,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    target_peer: &str,
    is_invisible: bool,
    db_path: &str,
    db_passphrase: &str,
    include_blobs: bool,
) {
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        // CRITICAL (presence collapse): ALWAYS attach + send the device list, even
        // when we have no profile row yet. The device list is what teaches a friend
        // `our-device → our-master`, which is what collapses our devices to ONE
        // online identity on their side. Gating the whole ProfileUpdate (device
        // list included) on `load_profile == Some` was the bug where a friend never
        // ingested our device list — every `[HOLLOW-DEVICES]` ingest was missing in
        // the logs and the identity showed OFFLINE. A profile-less node (fresh
        // import, or a master row not yet written) sends empty profile fields with
        // a populated `device_list`. Mirrors the de-gated backfill announce
        // (swarm.rs) and the receive-side empty-profile guard that ignores blank
        // names so this never clobbers a real cached profile.
        let profile = store.load_profile(local_peer_str).ok().flatten();
        let (display_name, status, about_me, updated_at, avatar_bytes, banner_bytes, twitch_username, showcase_board, showcase_assets) =
            match profile {
                Some(p) => (
                    p.display_name, p.status, p.about_me, p.updated_at,
                    p.avatar_bytes, p.banner_bytes, p.twitch_username, p.showcase_board,
                    p.showcase_assets,
                ),
                None => (String::new(), String::new(), String::new(), 0, None, None, String::new(), String::new(), None),
            };
        let avatar_hash = profile_blob_hash(avatar_bytes.as_deref());
        let banner_hash = profile_blob_hash(banner_bytes.as_deref());
        let showcase_assets_hash = profile_blob_hash(showcase_assets.as_deref());
        // Light sends leave the b64 fields EMPTY (= "no change" on the receiver);
        // the hashes above let a stale receiver pull the blobs once.
        let (avatar_b64, banner_b64, showcase_assets_b64) = if include_blobs {
            (
                avatar_bytes.as_ref()
                    .map(|b| base64::engine::general_purpose::STANDARD.encode(b))
                    .unwrap_or_default(),
                banner_bytes.as_ref()
                    .map(|b| base64::engine::general_purpose::STANDARD.encode(b))
                    .unwrap_or_default(),
                showcase_assets.as_ref()
                    .map(|b| base64::engine::general_purpose::STANDARD.encode(b))
                    .unwrap_or_default(),
            )
        } else {
            (String::new(), String::new(), String::new())
        };
        let device_list = super::crypto_handler::build_local_device_list(
            master_keypair, device_peer_id, db_path, db_passphrase,
        );
        // The board is small capped text — it rides the LIGHT announce too
        // (only blobs are hash-pulled).
        let msg = HavenMessage::ProfileUpdate {
            display_name, status, about_me, updated_at,
            avatar_b64, banner_b64, is_invisible, twitch_username,
            device_list,
            avatar_hash, banner_hash,
            showcase_board: Some(showcase_board),
            showcase_assets_b64, showcase_assets_hash,
        };
        send_message_to_peer(ws_cmd_tx, ws_room_peers, target_peer, msg);
    }
}

/// If a LIGHT ProfileUpdate (no blob payload) advertises avatar/banner hashes
/// that don't match our cached blobs for this identity, pull the full profile
/// once via ProfileRequest.
///
/// Cooldown-deduped per identity (10 min, process-global keyed by OUR device id
/// so harness nodes sharing one process don't share buckets) — an oversized or
/// undeliverable blob must not turn into a request loop on announce churn.
/// An EMPTY incoming hash while we cache a blob is deliberately NOT treated as
/// stale: blob clears propagate via the live full broadcast, same as before.
#[allow(clippy::too_many_arguments)]
pub(crate) fn maybe_request_full_profile(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    sender_peer_id: &str,
    profile_master: &str,
    avatar_b64: &str,
    banner_b64: &str,
    avatar_hash: &str,
    banner_hash: &str,
    showcase_assets_b64: &str,
    showcase_assets_hash: &str,
    local_device_peer_id: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    // Only light updates can leave us stale; a full payload already delivered blobs.
    if !avatar_b64.is_empty() || !banner_b64.is_empty() || !showcase_assets_b64.is_empty() {
        return;
    }
    // Old clients (no hash fields) always send full payloads — nothing to compare.
    if avatar_hash.is_empty() && banner_hash.is_empty() && showcase_assets_hash.is_empty() {
        return;
    }
    let Ok(db) = crate::storage::MessageStore::open(db_path, db_passphrase) else {
        return;
    };
    let cached = db.load_profile(profile_master).ok().flatten();
    let cached_avatar = profile_blob_hash(cached.as_ref().and_then(|p| p.avatar_bytes.as_deref()));
    let cached_banner = profile_blob_hash(cached.as_ref().and_then(|p| p.banner_bytes.as_deref()));
    let cached_assets = profile_blob_hash(cached.as_ref().and_then(|p| p.showcase_assets.as_deref()));
    let stale = (!avatar_hash.is_empty() && avatar_hash != cached_avatar)
        || (!banner_hash.is_empty() && banner_hash != cached_banner)
        || (!showcase_assets_hash.is_empty() && showcase_assets_hash != cached_assets);
    if !stale {
        return;
    }

    static PULLS: std::sync::OnceLock<std::sync::Mutex<HashMap<String, std::time::Instant>>> =
        std::sync::OnceLock::new();
    let pulls = PULLS.get_or_init(|| std::sync::Mutex::new(HashMap::new()));
    let key = format!("{local_device_peer_id}:{profile_master}");
    if let Ok(mut m) = pulls.lock() {
        if m.get(&key).is_some_and(|t| t.elapsed() < std::time::Duration::from_secs(600)) {
            return;
        }
        m.insert(key, std::time::Instant::now());
    }
    hollow_log!("[HOLLOW-PROFILE] Cached avatar/banner stale for {profile_master} — pulling full profile from {sender_peer_id}");
    send_message_to_peer(ws_cmd_tx, ws_room_peers, sender_peer_id, HavenMessage::ProfileRequest);
}

/// Handle `MessageEnvelope::Typing` — emit `TypingStarted` event.
pub(crate) async fn handle_envelope_typing(
    event_tx: &mpsc::Sender<NetworkEvent>,
    sender_peer_id: String,
    sid: String,
    cid: String,
) {
    let _ = event_tx.send(NetworkEvent::TypingStarted {
        peer_id: sender_peer_id,
        server_id: sid,
        channel_id: cid,
    }).await;
}

/// Handle `MessageEnvelope::ProfileUpdate` — persist profile + update member display names.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_profile_update(
    event_tx: &mpsc::Sender<NetworkEvent>,
    server_states: &mut HashMap<String, ServerState>,
    local_master_peer_id: &str,
    local_device_peer_id: &str,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    sender_peer_id: String,
    display_name: String,
    status: String,
    about_me: String,
    updated_at: i64,
    avatar_b64: String,
    banner_b64: String,
    twitch_username: String,
    device_list: Option<SignedDeviceList>,
    avatar_hash: String,
    banner_hash: String,
    showcase_board: Option<String>,
    showcase_assets_b64: String,
    showcase_assets_hash: String,
    db_path: &str,
    db_passphrase: &str,
) -> Vec<String> {
    // Multi-device: ingest the sender's signed device list (verify + monotonic +
    // persist + resolver update + DeviceListUpdated). A list for our OWN master
    // is a sibling device → merged (union). No-op for old clients.
    //
    // The returned "our device set grew" flag is consumed by the PLAINTEXT
    // `HavenMessage::ProfileUpdate` handler (swarm.rs), which re-announces our
    // profile to friends on a sibling merge. Siblings meet in the inbox room via
    // that plaintext path, not this MLS server-member envelope, so we don't
    // re-broadcast here (a sibling is not an MLS co-member in the DM/inbox case).
    // Step 7: we DO surface `newly_revoked` so the swarm caller (which holds olm/mls)
    // drops Olm sessions + removes MLS leaves for a device revoked via this path.
    let outcome = super::crypto_handler::ingest_device_list(
        event_tx, local_master_peer_id, local_device_peer_id, master_keypair,
        &sender_peer_id, ws_cmd_tx, ws_room_peers, device_list, db_path, db_passphrase,
    ).await;
    let newly_revoked = outcome.newly_revoked;

    // Decode avatar/banner base64 (same logic as HavenMessage::ProfileUpdate handler).
    let avatar_bytes: Option<Vec<u8>> = if avatar_b64.is_empty() {
        None
    } else if avatar_b64 == "CLEAR" {
        Some(vec![])
    } else {
        base64::engine::general_purpose::STANDARD.decode(&avatar_b64).ok()
            .filter(|b| b.len() <= 2_000_000)
    };
    let banner_bytes: Option<Vec<u8>> = if banner_b64.is_empty() {
        None
    } else if banner_b64 == "CLEAR" {
        Some(vec![])
    } else {
        base64::engine::general_purpose::STANDARD.decode(&banner_b64).ok()
            .filter(|b| b.len() <= 2_000_000)
    };
    let showcase_assets_bytes: Option<Vec<u8>> = if showcase_assets_b64.is_empty() {
        None
    } else if showcase_assets_b64 == "CLEAR" {
        Some(vec![])
    } else {
        base64::engine::general_purpose::STANDARD.decode(&showcase_assets_b64).ok()
            .filter(|b| b.len() <= 2_000_000)
    };
    // Multi-device: persist under the sender's MASTER (any device updates the one
    // identity profile) + empty-profile guard. Single-device: master == sender.
    let (profile_master, _saved) = save_incoming_profile(
        &sender_peer_id, &display_name, &status, &about_me, updated_at,
        avatar_bytes.as_deref(), banner_bytes.as_deref(), &twitch_username,
        sanitize_incoming_showcase(showcase_board.as_deref()),
        showcase_assets_bytes.as_deref(),
        db_path, db_passphrase,
    );
    // Light announce with hashes we don't match → pull the full profile once.
    maybe_request_full_profile(
        ws_cmd_tx, ws_room_peers, &sender_peer_id, &profile_master,
        &avatar_b64, &banner_b64, &avatar_hash, &banner_hash,
        &showcase_assets_b64, &showcase_assets_hash,
        local_device_peer_id, db_path, db_passphrase,
    );
    // Update display_name in server member lists (local-only, not a CRDT op).
    // Members are master-keyed (multi-device); update under the resolved master.
    for (_, state) in server_states.iter_mut() {
        if !display_name.is_empty() {
            if let Some(member) = state.members.get_mut(&profile_master) {
                member.display_name = display_name.clone();
            }
        }
    }
    let _ = event_tx.send(NetworkEvent::ProfileUpdated {
        peer_id: profile_master,
    }).await;
    newly_revoked
}

/// Handle `ProfileRequestFor` — look up the target peer's profile in our DB
/// and send it back as `ProfileRelay` (avatar included, no banner).
pub(crate) fn handle_profile_request_for(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    requester_peer: &str,
    target_peer_id: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    if target_peer_id.is_empty() { return; }

    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        if let Ok(Some(profile)) = store.load_profile(target_peer_id) {
            let avatar_b64 = profile.avatar_bytes
                .as_ref()
                .map(|b| base64::engine::general_purpose::STANDARD.encode(b))
                .unwrap_or_default();
            let msg = HavenMessage::ProfileRelay {
                source_peer_id: target_peer_id.to_string(),
                display_name: profile.display_name,
                status: profile.status,
                about_me: profile.about_me,
                updated_at: profile.updated_at,
                avatar_b64,
                twitch_username: profile.twitch_username,
            };
            send_message_to_peer(ws_cmd_tx, ws_room_peers, requester_peer, msg);
            hollow_log!("[HOLLOW-PROFILE] Relayed profile for {target_peer_id} to {requester_peer}");
        } else {
            hollow_log!("[HOLLOW-PROFILE] No cached profile for {target_peer_id}, cannot relay");
        }
    }
}

/// Handle incoming `ProfileRelay` — save the relayed profile + avatar, update
/// member display names, emit `ProfileUpdated`.
pub(crate) async fn handle_profile_relay(
    event_tx: &mpsc::Sender<NetworkEvent>,
    server_states: &mut HashMap<String, ServerState>,
    source_peer_id: String,
    display_name: String,
    status: String,
    about_me: String,
    updated_at: i64,
    avatar_b64: String,
    twitch_username: String,
    db_path: &str,
    db_passphrase: &str,
) {
    // Truncate fields (same limits as ProfileUpdate handler).
    let display_name = if display_name.len() > 64 { display_name[..64].to_string() } else { display_name };
    let status = if status.len() > 96 { status[..96].to_string() } else { status };
    let about_me = if about_me.len() > 256 { about_me[..256].to_string() } else { about_me };
    let twitch_username = if twitch_username.len() > 64 { twitch_username[..64].to_string() } else { twitch_username };

    let avatar_bytes: Option<Vec<u8>> = if avatar_b64.is_empty() {
        None
    } else {
        base64::engine::general_purpose::STANDARD.decode(&avatar_b64).ok()
            .filter(|b| b.len() <= 1_000_000)
    };

    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        // Only save if we don't already have a newer profile.
        let should_save = match store.load_profile_light(&source_peer_id) {
            Ok(Some(existing)) => existing.updated_at < updated_at,
            Ok(None) => true,
            Err(_) => true,
        };
        if should_save {
            // Relay carries no showcase board/assets — None preserves stored ones.
            let _ = store.save_profile(
                &source_peer_id, &display_name, &status, &about_me, updated_at,
                avatar_bytes.as_deref(), None, &twitch_username, None, None,
            );
            hollow_log!("[HOLLOW-PROFILE] Saved relayed profile for {source_peer_id}");
        } else {
            hollow_log!("[HOLLOW-PROFILE] Skipped relayed profile for {source_peer_id} (already have newer)");
            return;
        }
    }

    // Update display_name in server member lists (master-keyed).
    let source_master = super::resolver::resolve(&source_peer_id);
    for (_, state) in server_states.iter_mut() {
        if let Some(member) = state.members.get_mut(&source_master) {
            if !display_name.is_empty() {
                member.display_name = display_name.clone();
            }
        }
    }

    let _ = event_tx.send(NetworkEvent::ProfileUpdated {
        peer_id: source_peer_id,
    }).await;
}
