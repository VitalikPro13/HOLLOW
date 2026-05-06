use std::collections::HashMap;

use base64::Engine;
use tokio::sync::mpsc;

use crate::crdt::server_state::ServerState;
use crate::crypto::MlsManager;
use super::crypto_handler::{
    peer_is_reachable, send_mls_broadcast, send_message_to_peer,
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
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    peer_id_str: String,
) {
    hollow_log!("[HOLLOW-FRIENDS] Sending friend request to {peer_id_str}");

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    // Save as pending outgoing.
    {
        let data_dir = crate::identity::data_dir().unwrap_or_default();
        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
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
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    peer_id_str: String,
) {
    hollow_log!("[HOLLOW-FRIENDS] Accepting friend request from {peer_id_str}");

    // Update to accepted.
    {
        let data_dir = crate::identity::data_dir().unwrap_or_default();
        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
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
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    peer_id_str: String,
) {
    hollow_log!("[HOLLOW-FRIENDS] Rejecting friend request from {peer_id_str}");

    // Remove from friends table.
    {
        let data_dir = crate::identity::data_dir().unwrap_or_default();
        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
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
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    peer_id_str: String,
    pending_friend_removals: &mut std::collections::HashSet<String>,
) {
    hollow_log!("[HOLLOW-FRIENDS] Removing friend {peer_id_str}");

    let data_dir = crate::identity::data_dir().unwrap_or_default();
    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
    let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);

    if peer_is_reachable(&ws_room_peers, &peer_id_str) {
        send_message_to_peer(
            &ws_cmd_tx, &ws_room_peers,
            &peer_id_str, HavenMessage::FriendRemove,
        );
        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
            let _ = store.remove_friend(&peer_id_str);
        }
    } else {
        pending_friend_removals.insert(peer_id_str.clone());
        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
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
                for member_peer_str in server.members.keys() {
                    if member_peer_str == &local_peer { continue; }
                        if peer_is_reachable(&ws_room_peers, member_peer_str) {
                            send_message_to_peer(
                                &ws_cmd_tx, &ws_room_peers,
                                member_peer_str, msg.clone(),
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

    let mut sent_to = std::collections::HashSet::new();
    for peers in ws_room_peers.values() {
        for peer in peers {
            if peer != local_peer_str && sent_to.insert(peer.clone()) {
                send_message_to_peer(ws_cmd_tx, ws_room_peers, peer, msg.clone());
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
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    crypto_store: &crate::crypto::CryptoStore,
    local_peer_str: &str,
    display_name: String,
    status: String,
    about_me: String,
    avatar_bytes: Option<Vec<u8>>,
    banner_bytes: Option<Vec<u8>>,
    is_invisible: bool,
    twitch_username: String,
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
        let data_dir = crate::identity::data_dir().unwrap_or_default();
        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
        if let Ok(db) = crate::storage::MessageStore::open(&db_path, &passphrase) {
            if let Err(e) = db.save_profile(
                &local_peer_str, &display_name, &status, &about_me, now,
                avatar_bytes.as_deref(), banner_bytes.as_deref(), &twitch_username,
            ) {
                hollow_log!("[HOLLOW-SWARM] Failed to save own profile: {e}");
            }
        }
    }

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
    };
    hollow_log!("[HOLLOW-SWARM] Broadcasting profile update");
    {
        // Send to all reachable peers not already reached via MLS.
        let all_ws_peers: std::collections::HashSet<String> = ws_room_peers
            .values()
            .flat_map(|peers| peers.iter().cloned())
            .collect();
        for peer in &all_ws_peers {
            if peer == &local_peer_str { continue; }
            if mls_reached.contains(peer) { continue; }
            send_message_to_peer(
                &ws_cmd_tx, &ws_room_peers,
                peer, msg.clone(),
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
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    target_peer: &str,
    is_invisible: bool,
) {
    let data_dir = crate::identity::data_dir().unwrap_or_default();
    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
    let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);
    if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
        if let Ok(Some(profile)) = store.load_profile(local_peer_str) {
            let avatar_b64 = profile.avatar_bytes
                .as_ref()
                .map(|b| base64::engine::general_purpose::STANDARD.encode(b))
                .unwrap_or_default();
            let banner_b64 = profile.banner_bytes
                .as_ref()
                .map(|b| base64::engine::general_purpose::STANDARD.encode(b))
                .unwrap_or_default();
            let msg = HavenMessage::ProfileUpdate {
                display_name: profile.display_name,
                status: profile.status,
                about_me: profile.about_me,
                updated_at: profile.updated_at,
                avatar_b64,
                banner_b64,
                is_invisible,
                twitch_username: profile.twitch_username,
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
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    sender_peer_id: String,
    display_name: String,
    status: String,
    about_me: String,
    updated_at: i64,
    avatar_b64: String,
    banner_b64: String,
    twitch_username: String,
) {
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
    let data_dir = crate::identity::data_dir().unwrap_or_default();
    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
    let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);
    if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
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
