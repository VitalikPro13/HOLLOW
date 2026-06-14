use std::collections::HashMap;

use base64::Engine;
use tokio::sync::mpsc;

use crate::crdt::server_state::ServerState;
use crate::crypto::MlsManager;
use super::crypto_handler::{
    peer_is_reachable, send_mls_broadcast, send_message_to_peer, send_raw_to_peer,
};
use super::signaling::SignalingCmd;
use super::types::*;

/// Handle `NodeCommand::SendFriendRequest`.
pub(crate) async fn handle_send_friend_request(
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    sig_cmd_tx: &mpsc::Sender<SignalingCmd>,
    pending_friend_requests: &mut HashMap<String, i64>,
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

    // Save as pending outgoing.
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let _ = store.save_friend(&peer_id_str, "pending", "outgoing", now);
        }
    }

    // Register DM room code immediately so signaling can help
    // discover the peer even before they accept.
    let local_peer = local_peer_str.to_string();
    let room = dm_room_code(&local_peer, &peer_id_str);
    let _ = sig_cmd_tx.send(SignalingCmd::SetRoom {
        room_code: room.clone(),
    }).await;
    let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
        room_code: room.clone(),
    }).await;
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

    // Try to send immediately if peer is already reachable (shared server or inbox).
    if peer_is_reachable(&ws_room_peers, &peer_id_str) {
        send_message_to_peer(
            &ws_cmd_tx, &ws_room_peers,
            &peer_id_str, HavenMessage::FriendRequest { requested_at: now },
        );
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
pub(crate) async fn handle_accept_friend_request(
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    sig_cmd_tx: &mpsc::Sender<SignalingCmd>,
    local_peer_str: &str,
    peer_id_str: String,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-FRIENDS] Accepting friend request from {peer_id_str}");

    // Update to accepted.
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis() as i64;
            let _ = store.save_friend(&peer_id_str, "accepted", "", now);
        }
    }

    // Send acceptance to peer.
    if peer_is_reachable(&ws_room_peers, &peer_id_str) {
        send_message_to_peer(
            &ws_cmd_tx, &ws_room_peers,
            &peer_id_str, HavenMessage::FriendAccept,
        );
    }

    // Register DM room code with signaling for internet discovery.
    let local_peer = local_peer_str.to_string();
    let room = dm_room_code(&local_peer, &peer_id_str);
    let _ = sig_cmd_tx.send(SignalingCmd::SetRoom {
        room_code: room.clone(),
    }).await;
    let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
        room_code: room.clone(),
    }).await;
    // Join WS relay room for this DM.
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
        room_code: room,
    });

    let _ = event_tx.send(NetworkEvent::FriendRequestAccepted {
        peer_id: peer_id_str,
    }).await;
}

/// Handle `NodeCommand::RejectFriendRequest`.
pub(crate) async fn handle_reject_friend_request(
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    peer_id_str: String,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-FRIENDS] Rejecting friend request from {peer_id_str}");

    // Remove from friends table.
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let _ = store.remove_friend(&peer_id_str);
        }
    }

    if peer_is_reachable(&ws_room_peers, &peer_id_str) {
        send_message_to_peer(
            &ws_cmd_tx, &ws_room_peers,
            &peer_id_str, HavenMessage::FriendReject,
        );
    }

    let _ = event_tx.send(NetworkEvent::FriendRequestRejected {
        peer_id: peer_id_str,
    }).await;
}

/// Handle `NodeCommand::RemoveFriend`.
pub(crate) async fn handle_remove_friend(
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    peer_id_str: String,
    pending_friend_removals: &mut std::collections::HashSet<String>,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-FRIENDS] Removing friend {peer_id_str}");

    if peer_is_reachable(&ws_room_peers, &peer_id_str) {
        send_message_to_peer(
            &ws_cmd_tx, &ws_room_peers,
            &peer_id_str, HavenMessage::FriendRemove,
        );
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let _ = store.remove_friend(&peer_id_str);
        }
    } else {
        pending_friend_removals.insert(peer_id_str.clone());
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let _ = store.save_friend(&peer_id_str, "removed", "outgoing", 0);
        }
        hollow_log!("[HOLLOW-FRIENDS] Peer {peer_id_str} not reachable, queued friend removal for delivery");
    }

    let _ = event_tx.send(NetworkEvent::FriendRemoved {
        peer_id: peer_id_str,
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
        // DM typing: channel_id is actually the peer ID.
            if peer_is_reachable(&ws_room_peers, &channel_id) {
                send_message_to_peer(
                    &ws_cmd_tx, &ws_room_peers,
                    &channel_id, msg,
                );
            }
    } else {
        // Channel typing: MLS broadcast first, plaintext fallback.
        let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
        if mls_ok {
            let envelope = MessageEnvelope::Typing { sid: server_id.clone(), cid: channel_id.clone() };
            if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), &ws_cmd_tx, &server_id, &envelope, crypto_store) {
                hollow_log!("[HOLLOW-MLS] Typing broadcast failed: {e}");
            }
        } else {
            let local_peer = local_peer_str.to_string();
            if let Some(server) = server_states.get(&server_id) {
                let data = serde_json::to_vec(&msg).unwrap_or_default();
                for member_peer_str in server.members.keys() {
                    if member_peer_str == &local_peer { continue; }
                        if peer_is_reachable(&ws_room_peers, member_peer_str) {
                            send_raw_to_peer(
                                &ws_cmd_tx, &ws_room_peers,
                                member_peer_str, data.clone(),
                            );
                        }
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

    // Save our own profile to DB.
    {
        if let Ok(db) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            if let Err(e) = db.save_profile(
                &local_peer_str, &display_name, &status, &about_me, now,
                avatar_bytes.as_deref(), banner_bytes.as_deref(), &twitch_username,
            ) {
                hollow_log!("[HOLLOW-SWARM] Failed to save own profile: {e}");
            }
        }
    }

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
            if mls_reached.contains(peer) { continue; }
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

/// Send our own profile to a specific peer (used after session establishment, on PeerJoined, etc.).
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
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        if let Ok(Some(profile)) = store.load_profile(local_peer_str) {
            let avatar_b64 = profile.avatar_bytes
                .as_ref()
                .map(|b| base64::engine::general_purpose::STANDARD.encode(b))
                .unwrap_or_default();
            let banner_b64 = profile.banner_bytes
                .as_ref()
                .map(|b| base64::engine::general_purpose::STANDARD.encode(b))
                .unwrap_or_default();
            let device_list = super::crypto_handler::build_local_device_list(
                master_keypair, device_peer_id, db_path, db_passphrase,
            );
            let msg = HavenMessage::ProfileUpdate {
                display_name: profile.display_name,
                status: profile.status,
                about_me: profile.about_me,
                updated_at: profile.updated_at,
                avatar_b64,
                banner_b64,
                is_invisible,
                twitch_username: profile.twitch_username,
                device_list,
            };
            send_message_to_peer(ws_cmd_tx, ws_room_peers, target_peer, msg);
        }
    }
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
pub(crate) async fn handle_envelope_profile_update(
    event_tx: &mpsc::Sender<NetworkEvent>,
    server_states: &mut HashMap<String, ServerState>,
    local_master_peer_id: &str,
    sender_peer_id: String,
    display_name: String,
    status: String,
    about_me: String,
    updated_at: i64,
    avatar_b64: String,
    banner_b64: String,
    twitch_username: String,
    device_list: Option<SignedDeviceList>,
    db_path: &str,
    db_passphrase: &str,
) {
    // Multi-device: ingest the sender's signed device list (verify + monotonic +
    // persist + resolver update + DeviceListUpdated). No-op for old clients.
    super::crypto_handler::ingest_device_list(
        event_tx, local_master_peer_id, device_list, db_path, db_passphrase,
    ).await;

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
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let _ = store.save_profile(
            &sender_peer_id, &display_name, &status, &about_me, updated_at,
            avatar_bytes.as_deref(), banner_bytes.as_deref(), &twitch_username,
        );
    }
    // Update display_name in server member lists (local-only, not a CRDT op).
    for (_, state) in server_states.iter_mut() {
        if let Some(member) = state.members.get_mut(&sender_peer_id) {
            if !display_name.is_empty() {
                member.display_name = display_name.clone();
            }
        }
    }
    let _ = event_tx.send(NetworkEvent::ProfileUpdated {
        peer_id: sender_peer_id,
    }).await;
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
            let _ = store.save_profile(
                &source_peer_id, &display_name, &status, &about_me, updated_at,
                avatar_bytes.as_deref(), None, &twitch_username,
            );
            hollow_log!("[HOLLOW-PROFILE] Saved relayed profile for {source_peer_id}");
        } else {
            hollow_log!("[HOLLOW-PROFILE] Skipped relayed profile for {source_peer_id} (already have newer)");
            return;
        }
    }

    // Update display_name in server member lists.
    for (_, state) in server_states.iter_mut() {
        if let Some(member) = state.members.get_mut(&source_peer_id) {
            if !display_name.is_empty() {
                member.display_name = display_name.clone();
            }
        }
    }

    let _ = event_tx.send(NetworkEvent::ProfileUpdated {
        peer_id: source_peer_id,
    }).await;
}
