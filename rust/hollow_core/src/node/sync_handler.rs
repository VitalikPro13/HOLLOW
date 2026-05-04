use std::collections::HashMap;
use std::time::Duration;

use base64::Engine;
use tokio::sync::mpsc;

use crate::crdt::operations::{CrdtPayload, Permission};
use crate::crdt::server_state::ServerState;
use crate::crypto::{CryptoStore, MlsManager, OlmManager};
use super::crypto_handler::{
    peer_is_reachable, send_message_to_peer, send_mls_broadcast, send_mls_to_peer,
    persist_mls_state, send_encrypted_message,
};
use super::signaling::SignalingCmd;
use super::types::*;

// ── 1. CreateServer ───────────────────────────────────────────────────

pub(crate) async fn handle_create_server(
    server_states: &mut HashMap<String, ServerState>,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    name: String,
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

    // Create the initial ServerCreated op and apply it
    let op = state.create_op(CrdtPayload::ServerCreated {
        name: name.clone(),
        owner_peer_id: local_peer,
    });
    let _ = state.apply_op(&op);

    // Persist
    if let Ok(json) = serde_json::to_string(&state) {
        // Save via direct DB call (initial creation)
        let _ = event_tx.send(NetworkEvent::Error {
            message: format!("[CRDT] Server state saved: {server_id}"),
        }).await;
        // We'll persist through the storage API
        let data_dir = crate::identity::data_dir().unwrap_or_default();
        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
            let _ = store.save_server_state(&server_id, &json);
            let _ = store.insert_crdt_op(&op);
        }
    }

    server_states.insert(server_id.clone(), state);

    // Join the WS relay room for this server.
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
        room_code: server_id.clone(),
    });

    // Auto-pledge default storage (512 MB) for the owner
    if let Some(state) = server_states.get_mut(&server_id) {
        let owner_peer = local_peer_str.to_string();
        let default_pledge = 512u64 * 1024 * 1024;
        let pledge_op = state.create_op(CrdtPayload::StoragePledgeChanged {
            peer_id: owner_peer,
            pledge_bytes: default_pledge,
        });
        let _ = state.apply_op(&pledge_op);

        // Re-persist with pledge included
        if let Ok(json) = serde_json::to_string(&state) {
            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                let _ = store.save_server_state(&server_id, &json);
                let _ = store.insert_crdt_op(&pledge_op);
            }
        }
    }

    // Create MLS group for this server (owner is sole member).
    if let Some(mls_mgr) = mls {
        match mls_mgr.create_group(&server_id) {
            Ok(()) => persist_mls_state(mls_mgr, bundle_keypair),
            Err(e) => hollow_log!("[HOLLOW-MLS] Failed to create MLS group: {e}"),
        }
    }

    let _ = event_tx.send(NetworkEvent::ServerCreated {
        server_id: server_id.clone(),
        name,
    }).await;


    // No broadcast needed for CreateServer — the server only has
    // one member (the creator) at this point. New members will
    // receive full state via SyncResponse when they join.
}

// ── 2. CreateChannel ──────────────────────────────────────────────────

pub(crate) async fn handle_create_channel(
    server_states: &mut HashMap<String, ServerState>,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    name: String,
    category: Option<String>,
    channel_type: String,
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

        let op = state.create_op(CrdtPayload::ChannelAdded {
            channel_id: channel_id.clone(),
            name: name.clone(),
            category: category.clone(),
            channel_type: channel_type.clone(),
        });
        let _ = state.apply_op(&op);

        // Persist
        if let Ok(json) = serde_json::to_string(&state) {
            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                let _ = store.save_server_state(&server_id, &json);
                let _ = store.insert_crdt_op(&op);
            }
        }

        let _ = event_tx.send(NetworkEvent::ChannelAdded {
            server_id: server_id.clone(),
            channel_id,
            name,
            channel_type,
        }).await;

        // Broadcast to server members — MLS first, plaintext fallback.
        if let Ok(op_json) = serde_json::to_string(&op) {
            let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
            if mls_ok {
                let envelope = MessageEnvelope::CrdtOp { sid: server_id.clone(), op_json: op_json.clone() };
                if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &envelope, bundle_keypair) {
                    hollow_log!("[HOLLOW-MLS] CrdtOp broadcast failed: {e}");
                }
            } else {
                let local_peer = local_peer_str.to_string();
                for member_peer_str in state.members.keys() {
                    if member_peer_str == &local_peer { continue; }
                        if peer_is_reachable(ws_room_peers, member_peer_str) {
                            send_message_to_peer(
                                ws_cmd_tx, ws_room_peers,
                                member_peer_str, HavenMessage::CrdtOpBroadcast {
                                    server_id: server_id.clone(),
                                    op_json: op_json.clone(),
                                },
                            );
                        }
                }
            }
        }
    } else {
        let _ = event_tx.send(NetworkEvent::Error {
            message: format!("[CRDT] Server {server_id} not found"),
        }).await;
    }
    false
}

// ── 3. RemoveChannel ──────────────────────────────────────────────────

pub(crate) async fn handle_remove_channel(
    server_states: &mut HashMap<String, ServerState>,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
) -> bool {
    if let Some(state) = server_states.get_mut(&server_id) {
        let local_peer = local_peer_str.to_string();
        if !state.has_permission(&local_peer, Permission::MANAGE_CHANNELS) {
            hollow_log!("[HOLLOW-CRDT] Permission denied: cannot remove channel in {server_id}");
            let _ = event_tx.send(NetworkEvent::Error {
                message: "Permission denied: cannot manage channels".to_string(),
            }).await;
            return true;
        }
        hollow_log!("[HOLLOW-CRDT] Removing channel {channel_id} from server {server_id}");

        let op = state.create_op(CrdtPayload::ChannelRemoved {
            channel_id: channel_id.clone(),
        });
        let _ = state.apply_op(&op);

        // Persist
        if let Ok(json) = serde_json::to_string(&state) {
            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                let _ = store.save_server_state(&server_id, &json);
                let _ = store.insert_crdt_op(&op);
            }
        }

        let _ = event_tx.send(NetworkEvent::ChannelRemoved {
            server_id: server_id.clone(),
            channel_id,
        }).await;

        // Broadcast to connected server members only.
        if let Ok(op_json) = serde_json::to_string(&op) {
            let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
            if mls_ok {
                let envelope = MessageEnvelope::CrdtOp { sid: server_id.clone(), op_json: op_json.clone() };
                if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &envelope, bundle_keypair) {
                    hollow_log!("[HOLLOW-MLS] CrdtOp broadcast failed: {e}");
                }
            } else {
                let local_peer = local_peer_str.to_string();
                for member_peer_str in state.members.keys() {
                    if member_peer_str == &local_peer { continue; }
                        if peer_is_reachable(ws_room_peers, member_peer_str) {
                            send_message_to_peer(
                                ws_cmd_tx, ws_room_peers,
                                member_peer_str, HavenMessage::CrdtOpBroadcast {
                                    server_id: server_id.clone(),
                                    op_json: op_json.clone(),
                                },
                            );
                        }
                }
            }
        }
    }
    false
}

// ── 4. RenameServer ───────────────────────────────────────────────────

pub(crate) async fn handle_rename_server(
    server_states: &mut HashMap<String, ServerState>,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    new_name: String,
) -> bool {
    if let Some(state) = server_states.get_mut(&server_id) {
        let local_peer = local_peer_str.to_string();
        if !state.has_permission(&local_peer, Permission::MANAGE_SERVER) {
            hollow_log!("[HOLLOW-CRDT] Permission denied: cannot rename server {server_id}");
            let _ = event_tx.send(NetworkEvent::Error {
                message: "Permission denied: cannot manage server".to_string(),
            }).await;
            return true;
        }
        hollow_log!("[HOLLOW-CRDT] Renaming server {server_id} to '{new_name}'");

        let op = state.create_op(CrdtPayload::ServerRenamed {
            new_name: new_name.clone(),
        });
        let _ = state.apply_op(&op);

        // Persist
        if let Ok(json) = serde_json::to_string(&state) {
            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                let _ = store.save_server_state(&server_id, &json);
                let _ = store.insert_crdt_op(&op);
            }
        }

        let _ = event_tx.send(NetworkEvent::ServerUpdated {
            server_id: server_id.clone(),
        }).await;

        // Broadcast to connected server members only.
        if let Ok(op_json) = serde_json::to_string(&op) {
            let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
            if mls_ok {
                let envelope = MessageEnvelope::CrdtOp { sid: server_id.clone(), op_json: op_json.clone() };
                if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &envelope, bundle_keypair) {
                    hollow_log!("[HOLLOW-MLS] CrdtOp broadcast failed: {e}");
                }
            } else {
                let local_peer = local_peer_str.to_string();
                for member_peer_str in state.members.keys() {
                    if member_peer_str == &local_peer { continue; }
                        if peer_is_reachable(ws_room_peers, member_peer_str) {
                            send_message_to_peer(
                                ws_cmd_tx, ws_room_peers,
                                member_peer_str, HavenMessage::CrdtOpBroadcast {
                                    server_id: server_id.clone(),
                                    op_json: op_json.clone(),
                                },
                            );
                        }
                }
            }
        }
    }
    false
}

// ── 5. RenameChannel ──────────────────────────────────────────────────

pub(crate) async fn handle_rename_channel(
    server_states: &mut HashMap<String, ServerState>,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    new_name: String,
) -> bool {
    if let Some(state) = server_states.get_mut(&server_id) {
        let local_peer = local_peer_str.to_string();
        if !state.has_permission(&local_peer, Permission::MANAGE_CHANNELS) {
            hollow_log!("[HOLLOW-CRDT] Permission denied: cannot rename channel in {server_id}");
            let _ = event_tx.send(NetworkEvent::Error {
                message: "Permission denied: cannot manage channels".to_string(),
            }).await;
            return true;
        }
        hollow_log!("[HOLLOW-CRDT] Renaming channel {channel_id} to '{new_name}' in server {server_id}");

        let op = state.create_op(CrdtPayload::ChannelRenamed {
            channel_id: channel_id.clone(),
            new_name: new_name.clone(),
        });
        let _ = state.apply_op(&op);

        // Persist
        if let Ok(json) = serde_json::to_string(&state) {
            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                let _ = store.save_server_state(&server_id, &json);
                let _ = store.insert_crdt_op(&op);
            }
        }

        let _ = event_tx.send(NetworkEvent::ChannelRenamed {
            server_id: server_id.clone(),
            channel_id,
            new_name,
        }).await;

        // Broadcast to connected server members only.
        if let Ok(op_json) = serde_json::to_string(&op) {
            let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
            if mls_ok {
                let envelope = MessageEnvelope::CrdtOp { sid: server_id.clone(), op_json: op_json.clone() };
                if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &envelope, bundle_keypair) {
                    hollow_log!("[HOLLOW-MLS] CrdtOp broadcast failed: {e}");
                }
            } else {
                let local_peer = local_peer_str.to_string();
                for member_peer_str in state.members.keys() {
                    if member_peer_str == &local_peer { continue; }
                        if peer_is_reachable(ws_room_peers, member_peer_str) {
                            send_message_to_peer(
                                ws_cmd_tx, ws_room_peers,
                                member_peer_str, HavenMessage::CrdtOpBroadcast {
                                    server_id: server_id.clone(),
                                    op_json: op_json.clone(),
                                },
                            );
                        }
                }
            }
        }
    }
    false
}

// ── 6. UpdateServerSetting ────────────────────────────────────────────

pub(crate) async fn handle_update_server_setting(
    server_states: &mut HashMap<String, ServerState>,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    key: String,
    value: String,
) {
    if let Some(state) = server_states.get_mut(&server_id) {
        hollow_log!("[HOLLOW-CRDT] Updating setting '{key}'='{value}' in server {server_id}");

        let op = state.create_op(CrdtPayload::ServerSettingChanged {
            key: key.clone(),
            value: value.clone(),
        });
        let _ = state.apply_op(&op);

        // Persist
        if let Ok(json) = serde_json::to_string(&state) {
            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                let _ = store.save_server_state(&server_id, &json);
                let _ = store.insert_crdt_op(&op);
            }
        }

        let _ = event_tx.send(NetworkEvent::ServerUpdated {
            server_id: server_id.clone(),
        }).await;

        // Broadcast to connected server members only.
        if let Ok(op_json) = serde_json::to_string(&op) {
            let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
            if mls_ok {
                let envelope = MessageEnvelope::CrdtOp { sid: server_id.clone(), op_json: op_json.clone() };
                if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &envelope, bundle_keypair) {
                    hollow_log!("[HOLLOW-MLS] CrdtOp broadcast failed: {e}");
                }
            } else {
                let local_peer = local_peer_str.to_string();
                for member_peer_str in state.members.keys() {
                    if member_peer_str == &local_peer { continue; }
                        if peer_is_reachable(ws_room_peers, member_peer_str) {
                            send_message_to_peer(
                                ws_cmd_tx, ws_room_peers,
                                member_peer_str, HavenMessage::CrdtOpBroadcast {
                                    server_id: server_id.clone(),
                                    op_json: op_json.clone(),
                                },
                            );
                        }
                }
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
    sig_cmd_tx: &mpsc::Sender<SignalingCmd>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
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

    hollow_log!("[HOLLOW-CRDT] Deleting server {server_id}");

    // Broadcast deletion — MLS first, plaintext fallback.
    let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
    if mls_ok {
        let envelope = MessageEnvelope::ServerDelete { sid: server_id.clone() };
        if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &envelope, bundle_keypair) {
            hollow_log!("[HOLLOW-MLS] ServerDelete broadcast failed: {e}");
        }
    } else if let Some(state) = server_states.get(&server_id) {
        let local_peer = local_peer_str.to_string();
        for member_peer_str in state.members.keys() {
            if member_peer_str == &local_peer { continue; }
                if peer_is_reachable(ws_room_peers, member_peer_str) {
                    send_message_to_peer(
                        ws_cmd_tx, ws_room_peers,
                        member_peer_str, HavenMessage::ServerDeleteBroadcast {
                            server_id: server_id.clone(),
                        },
                    );
                }
        }
    }

    server_states.remove(&server_id);

    // Clean up MLS group.
    if let Some(mls_mgr) = mls {
        mls_mgr.remove_group(&server_id);
        persist_mls_state(mls_mgr, bundle_keypair);
    }

    // Unregister from signaling room for this server.
    let _ = sig_cmd_tx.send(SignalingCmd::Unregister {
        room_code: server_id.clone(),
    }).await;

    // Remove from DB
    let data_dir = crate::identity::data_dir().unwrap_or_default();
    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
    let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);
    if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
        let _ = store.delete_server_state(&server_id);
    }

    let _ = event_tx.send(NetworkEvent::ServerDeleted {
        server_id,
    }).await;
    false
}

// ── 8. JoinServer ─────────────────────────────────────────────────────

pub(crate) async fn handle_join_server(
    pending_server_joins: &mut HashMap<String, Option<String>>,
    mls: &Option<MlsManager>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    sig_cmd_tx: &mpsc::Sender<SignalingCmd>,
    cmd_tx: &mpsc::Sender<NodeCommand>,
    server_id: String,
    twitch_proof_json: Option<String>,
) {
    hollow_log!("[HOLLOW-CRDT] Joining server {server_id}");
    pending_server_joins.insert(server_id.clone(), twitch_proof_json.clone());

    // Join the signaling room with room_code = server_id.

    let _ = sig_cmd_tx.send(SignalingCmd::SetRoom {
        room_code: server_id.clone(),
    }).await;
    let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
        room_code: server_id.clone(),
    }).await;

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
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    peer_id: String,
    new_role: String,
) -> bool {
    if let Some(state) = server_states.get_mut(&server_id) {
        let local_peer = local_peer_str.to_string();
        let new_member_role = crate::crdt::operations::MemberRole::from_str(&new_role);

        // Permission check: can the local user change this peer's role?
        if !state.can_change_role(&local_peer, &peer_id, &new_member_role) {
            hollow_log!("[HOLLOW-CRDT] Permission denied: cannot change {peer_id} to {new_role} in {server_id}");
            let _ = event_tx.send(NetworkEvent::Error {
                message: format!("Permission denied: cannot change role to {new_role}"),
            }).await;
            return true;
        }

        hollow_log!("[HOLLOW-CRDT] Changing role of {peer_id} to {new_role} in {server_id}");
        // Use the author's (local user's) role priority, not the target role's.
        // This ensures demotions work: an Owner(3) demoting Admin(2)→Member
        // sends priority 3, which beats the existing priority 2 in AdminLwwReg.
        let author_role = state.get_role(&local_peer);
        let op = state.create_op(CrdtPayload::RoleChanged {
            peer_id: peer_id.clone(),
            role: new_member_role.clone(),
            priority: author_role.priority(),
        });
        let _ = state.apply_op(&op);

        // Persist
        if let Ok(json) = serde_json::to_string(&state) {
            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                let _ = store.save_server_state(&server_id, &json);
                let _ = store.insert_crdt_op(&op);
            }
        }

        let _ = event_tx.send(NetworkEvent::RoleChanged {
            server_id: server_id.clone(),
            peer_id: peer_id.clone(),
            new_role: new_role.clone(),
        }).await;

        // Broadcast to connected server members only.
        if let Ok(op_json) = serde_json::to_string(&op) {
            for member_peer_str in state.members.keys() {
                if member_peer_str == &local_peer { continue; }
                    if peer_is_reachable(ws_room_peers, member_peer_str) {
                        send_message_to_peer(
                            ws_cmd_tx, ws_room_peers,
                            member_peer_str, HavenMessage::CrdtOpBroadcast {
                                server_id: server_id.clone(),
                                op_json: op_json.clone(),
                            },
                        );
                    }
            }
        }
    }
    false
}

// ── 10. KickMember ────────────────────────────────────────────────────

pub(crate) async fn handle_kick_member(
    server_states: &mut HashMap<String, ServerState>,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    peer_id: String,
) -> bool {
    if let Some(state) = server_states.get_mut(&server_id) {
        let local_peer = local_peer_str.to_string();

        // Permission check
        if !state.can_kick(&local_peer, &peer_id) {
            hollow_log!("[HOLLOW-CRDT] Permission denied: cannot kick {peer_id} from {server_id}");
            let _ = event_tx.send(NetworkEvent::Error {
                message: "Permission denied: cannot kick this member".to_string(),
            }).await;
            return true;
        }

        hollow_log!("[HOLLOW-CRDT] Kicking member {peer_id} from {server_id}");
        let op = state.create_op(CrdtPayload::MemberRemoved {
            peer_id: peer_id.clone(),
        });

        // Collect broadcast targets BEFORE apply_op removes the member.
        let broadcast_targets: Vec<String> = state.members.keys()
            .filter(|m| *m != &local_peer)
            .cloned()
            .collect();

        let _ = state.apply_op(&op);

        // Persist
        if let Ok(json) = serde_json::to_string(&state) {
            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                let _ = store.save_server_state(&server_id, &json);
                let _ = store.insert_crdt_op(&op);
            }
        }

        let _ = event_tx.send(NetworkEvent::MemberLeft {
            server_id: server_id.clone(),
            peer_id: peer_id.clone(),
        }).await;

        // Broadcast CRDT op to remaining members (collected before removal).
        if let Ok(op_json) = serde_json::to_string(&op) {
            for member_peer_str in &broadcast_targets {
                if member_peer_str == &peer_id { continue; } // Kicked peer gets MemberKickBroadcast instead
                    if peer_is_reachable(ws_room_peers, member_peer_str) {
                        send_message_to_peer(
                            ws_cmd_tx, ws_room_peers,
                            member_peer_str, HavenMessage::CrdtOpBroadcast {
                                server_id: server_id.clone(),
                                op_json: op_json.clone(),
                            },
                        );
                    }
            }
        }

        // Send kick notification to the kicked peer — MLS (targeted) first, plaintext fallback.
        let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
        if mls_ok {
            let envelope = MessageEnvelope::MemberKick { sid: server_id.clone() };
            if let Err(e) = send_mls_to_peer(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &peer_id, &envelope, bundle_keypair) {
                hollow_log!("[HOLLOW-MLS] MemberKick targeted send failed: {e}");
            }
            if peer_is_reachable(ws_room_peers, &peer_id) {
                send_message_to_peer(
                    ws_cmd_tx, ws_room_peers,
                    &peer_id, HavenMessage::MemberKickBroadcast {
                        server_id: server_id.clone(),
                    },
                );
            }
        } else if peer_is_reachable(ws_room_peers, &peer_id) {
            send_message_to_peer(
                ws_cmd_tx, ws_room_peers,
                &peer_id, HavenMessage::MemberKickBroadcast {
                    server_id: server_id.clone(),
                },
            );
        }

        // MLS: remove member from group (epoch rotation for forward secrecy).
        if let Some(mls_mgr) = mls {
            if mls_mgr.has_group(&server_id) {
                match mls_mgr.remove_member(&server_id, &peer_id) {
                    Ok(commit_bytes) => {
                        match mls_mgr.merge_pending_commit(&server_id) {
                            Ok(()) => {
                                persist_mls_state(mls_mgr, bundle_keypair);
                                // Emit epoch change for SFrame key rotation.
                                if let Ok(sframe_key) = mls_mgr.export_secret(&server_id, "sframe", b"", 32) {
                                    let epoch = mls_mgr.epoch(&server_id).unwrap_or(0);
                                    let _ = event_tx.send(NetworkEvent::MlsEpochChanged {
                                        server_id: server_id.clone(), epoch, sframe_key,
                                    }).await;
                                }
                                let commit_b64 = base64::engine::general_purpose::STANDARD.encode(&commit_bytes);
                                // Broadcast MLS commit to remaining members.
                                for member_peer_str in &broadcast_targets {
                                    if member_peer_str == &peer_id { continue; }
                                        if peer_is_reachable(ws_room_peers, member_peer_str) {
                                            send_message_to_peer(
                                                ws_cmd_tx, ws_room_peers,
                                                member_peer_str, HavenMessage::MlsCommit {
                                                    server_id: server_id.clone(),
                                                    commit: commit_b64.clone(),
                                                },
                                            );
                                        }
                                }
                                hollow_log!("[HOLLOW-MLS] Removed {peer_id} from MLS group, epoch rotated");
                            }
                            Err(e) => hollow_log!("[HOLLOW-MLS] Failed to merge remove commit: {e}"),
                        }
                    }
                    Err(e) => hollow_log!("[HOLLOW-MLS] Failed to remove member from MLS group: {e}"),
                }
            }
        }
    }
    false
}

// ── 10b. LeaveServer ─────────────────────────────────────────────────

pub(crate) async fn handle_leave_server(
    server_states: &mut HashMap<String, ServerState>,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    sig_cmd_tx: &mpsc::Sender<SignalingCmd>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
) -> bool {
    if let Some(state) = server_states.get_mut(&server_id) {
        let local_peer = local_peer_str.to_string();

        // Owner cannot leave — must delete or transfer ownership first.
        if state.get_role(&local_peer) == crate::crdt::operations::MemberRole::Owner {
            hollow_log!("[HOLLOW-CRDT] Owner cannot leave server {server_id}");
            let _ = event_tx.send(NetworkEvent::Error {
                message: "Owner cannot leave the server. Delete it or transfer ownership first.".to_string(),
            }).await;
            return true;
        }

        hollow_log!("[HOLLOW-CRDT] Leaving server {server_id}");
        let op = state.create_op(CrdtPayload::MemberRemoved {
            peer_id: local_peer.clone(),
        });

        // Collect broadcast targets BEFORE apply_op removes us.
        let broadcast_targets: Vec<String> = state.members.keys()
            .filter(|m| *m != &local_peer)
            .cloned()
            .collect();

        let _ = state.apply_op(&op);

        // Persist state (with us removed) + op.
        if let Ok(json) = serde_json::to_string(&state) {
            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                let _ = store.save_server_state(&server_id, &json);
                let _ = store.insert_crdt_op(&op);
            }
        }

        // Broadcast CRDT op to remaining members.
        if let Ok(op_json) = serde_json::to_string(&op) {
            for member_peer_str in &broadcast_targets {
                if peer_is_reachable(ws_room_peers, member_peer_str) {
                    send_message_to_peer(
                        ws_cmd_tx, ws_room_peers,
                        member_peer_str, HavenMessage::CrdtOpBroadcast {
                            server_id: server_id.clone(),
                            op_json: op_json.clone(),
                        },
                    );
                }
            }
        }

        // MLS: remove self from group.
        if let Some(mls_mgr) = mls {
            if mls_mgr.has_group(&server_id) {
                match mls_mgr.remove_member(&server_id, &local_peer) {
                    Ok(commit_bytes) => {
                        match mls_mgr.merge_pending_commit(&server_id) {
                            Ok(()) => {
                                persist_mls_state(mls_mgr, bundle_keypair);
                                let commit_b64 = base64::engine::general_purpose::STANDARD.encode(&commit_bytes);
                                for member_peer_str in &broadcast_targets {
                                    if peer_is_reachable(ws_room_peers, member_peer_str) {
                                        send_message_to_peer(
                                            ws_cmd_tx, ws_room_peers,
                                            member_peer_str, HavenMessage::MlsCommit {
                                                server_id: server_id.clone(),
                                                commit: commit_b64.clone(),
                                            },
                                        );
                                    }
                                }
                                hollow_log!("[HOLLOW-MLS] Left MLS group for {server_id}");
                            }
                            Err(e) => hollow_log!("[HOLLOW-MLS] Failed to merge leave commit: {e}"),
                        }
                    }
                    Err(e) => {
                        hollow_log!("[HOLLOW-MLS] Failed to remove self from MLS group: {e}");
                        mls_mgr.remove_group(&server_id);
                        persist_mls_state(mls_mgr, bundle_keypair);
                    }
                }
            }
        }
    }

    // Remove server from local state.
    server_states.remove(&server_id);

    // Unregister from signaling room.
    let _ = sig_cmd_tx.send(SignalingCmd::Unregister {
        room_code: server_id.clone(),
    }).await;

    // Leave the WS relay room.
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom {
        room_code: server_id.clone(),
    });

    // Delete server state from DB.
    let data_dir = crate::identity::data_dir().unwrap_or_default();
    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
    let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);
    if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
        let _ = store.delete_server_state(&server_id);
    }

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
    server_id: String,
    peer_id: String,
) -> bool {
    if let Some(state) = server_states.get_mut(&server_id) {
        let local_peer = local_peer_str.to_string();

        if !state.can_ban(&local_peer, &peer_id) {
            hollow_log!("[HOLLOW-CRDT] Permission denied: cannot ban {peer_id} from {server_id}");
            let _ = event_tx.send(NetworkEvent::Error {
                message: "Permission denied: cannot ban this member".to_string(),
            }).await;
            return true;
        }

        hollow_log!("[HOLLOW-CRDT] Banning member {peer_id} from {server_id}");
        let op = state.create_op(CrdtPayload::MemberBanned {
            peer_id: peer_id.clone(),
        });

        // Collect broadcast targets BEFORE apply_op removes the member.
        let broadcast_targets: Vec<String> = state.members.keys()
            .filter(|m| *m != &local_peer)
            .cloned()
            .collect();

        let _ = state.apply_op(&op);

        // Persist
        if let Ok(json) = serde_json::to_string(&state) {
            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                let _ = store.save_server_state(&server_id, &json);
                let _ = store.insert_crdt_op(&op);
            }
        }

        let _ = event_tx.send(NetworkEvent::MemberLeft {
            server_id: server_id.clone(),
            peer_id: peer_id.clone(),
        }).await;

        // Broadcast CRDT op to remaining members.
        if let Ok(op_json) = serde_json::to_string(&op) {
            for member_peer_str in &broadcast_targets {
                if member_peer_str == &peer_id { continue; }
                if peer_is_reachable(ws_room_peers, member_peer_str) {
                    send_message_to_peer(
                        ws_cmd_tx, ws_room_peers,
                        member_peer_str, HavenMessage::CrdtOpBroadcast {
                            server_id: server_id.clone(),
                            op_json: op_json.clone(),
                        },
                    );
                }
            }
        }

        // Send kick notification to the banned peer.
        if peer_is_reachable(ws_room_peers, &peer_id) {
            send_message_to_peer(
                ws_cmd_tx, ws_room_peers,
                &peer_id, HavenMessage::MemberKickBroadcast {
                    server_id: server_id.clone(),
                },
            );
        }

        // MLS: remove member from group (epoch rotation).
        if let Some(mls_mgr) = mls {
            if mls_mgr.has_group(&server_id) {
                match mls_mgr.remove_member(&server_id, &peer_id) {
                    Ok(commit_bytes) => {
                        match mls_mgr.merge_pending_commit(&server_id) {
                            Ok(()) => {
                                persist_mls_state(mls_mgr, bundle_keypair);
                                if let Ok(sframe_key) = mls_mgr.export_secret(&server_id, "sframe", b"", 32) {
                                    let epoch = mls_mgr.epoch(&server_id).unwrap_or(0);
                                    let _ = event_tx.send(NetworkEvent::MlsEpochChanged {
                                        server_id: server_id.clone(), epoch, sframe_key,
                                    }).await;
                                }
                                let commit_b64 = base64::engine::general_purpose::STANDARD.encode(&commit_bytes);
                                for member_peer_str in &broadcast_targets {
                                    if member_peer_str == &peer_id { continue; }
                                    if peer_is_reachable(ws_room_peers, member_peer_str) {
                                        send_message_to_peer(
                                            ws_cmd_tx, ws_room_peers,
                                            member_peer_str, HavenMessage::MlsCommit {
                                                server_id: server_id.clone(),
                                                commit: commit_b64.clone(),
                                            },
                                        );
                                    }
                                }
                                hollow_log!("[HOLLOW-MLS] Removed banned {peer_id} from MLS group");
                            }
                            Err(e) => hollow_log!("[HOLLOW-MLS] Failed to merge ban remove commit: {e}"),
                        }
                    }
                    Err(e) => hollow_log!("[HOLLOW-MLS] Failed to remove banned member from MLS group: {e}"),
                }
            }
        }
    }
    false
}

// ── 10d. UnbanMember ────────────────────────────────────────────────

pub(crate) async fn handle_unban_member(
    server_states: &mut HashMap<String, ServerState>,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    peer_id: String,
) -> bool {
    if let Some(state) = server_states.get_mut(&server_id) {
        let local_peer = local_peer_str.to_string();

        if !state.has_permission(&local_peer, Permission::KICK_MEMBERS) {
            hollow_log!("[HOLLOW-CRDT] Permission denied: cannot unban {peer_id} in {server_id}");
            let _ = event_tx.send(NetworkEvent::Error {
                message: "Permission denied: cannot unban members".to_string(),
            }).await;
            return true;
        }

        hollow_log!("[HOLLOW-CRDT] Unbanning member {peer_id} in {server_id}");
        let op = state.create_op(CrdtPayload::MemberUnbanned {
            peer_id: peer_id.clone(),
        });
        let _ = state.apply_op(&op);

        // Persist
        if let Ok(json) = serde_json::to_string(&state) {
            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                let _ = store.save_server_state(&server_id, &json);
                let _ = store.insert_crdt_op(&op);
            }
        }

        let _ = event_tx.send(NetworkEvent::ServerUpdated {
            server_id: server_id.clone(),
        }).await;

        // Broadcast
        if let Ok(op_json) = serde_json::to_string(&op) {
            let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
            if mls_ok {
                let envelope = MessageEnvelope::CrdtOp { sid: server_id.clone(), op_json: op_json.clone() };
                if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &envelope, bundle_keypair) {
                    hollow_log!("[HOLLOW-MLS] CrdtOp broadcast failed: {e}");
                }
            } else {
                for member_peer_str in state.members.keys() {
                    if member_peer_str == &local_peer { continue; }
                    if peer_is_reachable(ws_room_peers, member_peer_str) {
                        send_message_to_peer(
                            ws_cmd_tx, ws_room_peers,
                            member_peer_str, HavenMessage::CrdtOpBroadcast {
                                server_id: server_id.clone(),
                                op_json: op_json.clone(),
                            },
                        );
                    }
                }
            }
        }
    }
    false
}

// ── 10e. Label operations ────────────────────────────────────────────

pub(crate) async fn handle_label_op(
    server_states: &mut HashMap<String, ServerState>,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    payload: CrdtPayload,
) -> bool {
    if let Some(state) = server_states.get_mut(&server_id) {
        let local_peer = local_peer_str.to_string();

        // Self-assign/unassign: any member can toggle their own labels.
        // All other label ops require MANAGE_ROLES.
        let is_self_toggle = match &payload {
            CrdtPayload::LabelAssigned { peer_id, .. }
            | CrdtPayload::LabelUnassigned { peer_id, .. } => peer_id == &local_peer,
            _ => false,
        };

        if !is_self_toggle && !state.has_permission(&local_peer, Permission::MANAGE_ROLES) {
            hollow_log!("[HOLLOW-CRDT] Permission denied: cannot manage labels in {server_id}");
            let _ = event_tx.send(NetworkEvent::Error {
                message: "Permission denied: cannot manage labels".to_string(),
            }).await;
            return true;
        }

        let op = state.create_op(payload);
        let _ = state.apply_op(&op);

        if let Ok(json) = serde_json::to_string(&state) {
            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                let _ = store.save_server_state(&server_id, &json);
                let _ = store.insert_crdt_op(&op);
            }
        }

        let _ = event_tx.send(NetworkEvent::ServerUpdated {
            server_id: server_id.clone(),
        }).await;

        if let Ok(op_json) = serde_json::to_string(&op) {
            let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
            if mls_ok {
                let envelope = MessageEnvelope::CrdtOp { sid: server_id.clone(), op_json: op_json.clone() };
                if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &envelope, bundle_keypair) {
                    hollow_log!("[HOLLOW-MLS] CrdtOp broadcast failed: {e}");
                }
            } else {
                for member_peer_str in state.members.keys() {
                    if member_peer_str == &local_peer { continue; }
                    if peer_is_reachable(ws_room_peers, member_peer_str) {
                        send_message_to_peer(
                            ws_cmd_tx, ws_room_peers,
                            member_peer_str, HavenMessage::CrdtOpBroadcast {
                                server_id: server_id.clone(),
                                op_json: op_json.clone(),
                            },
                        );
                    }
                }
            }
        }
    }
    false
}

// ── 10f. SetChannelVisibility ───────────────────────────────────────

pub(crate) async fn handle_set_channel_visibility(
    server_states: &mut HashMap<String, ServerState>,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    visibility: String,
) -> bool {
    if let Some(state) = server_states.get_mut(&server_id) {
        let local_peer = local_peer_str.to_string();
        if !state.has_permission(&local_peer, Permission::MANAGE_CHANNELS) {
            hollow_log!("[HOLLOW-CRDT] Permission denied: cannot set channel visibility in {server_id}");
            let _ = event_tx.send(NetworkEvent::Error {
                message: "Permission denied: cannot manage channels".to_string(),
            }).await;
            return true;
        }

        hollow_log!("[HOLLOW-CRDT] Setting channel {channel_id} visibility to {visibility} in {server_id}");
        let op = state.create_op(CrdtPayload::ChannelVisibilityChanged {
            channel_id: channel_id.clone(),
            visibility: visibility.clone(),
        });
        let _ = state.apply_op(&op);

        if let Ok(json) = serde_json::to_string(&state) {
            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                let _ = store.save_server_state(&server_id, &json);
                let _ = store.insert_crdt_op(&op);
            }
        }

        let _ = event_tx.send(NetworkEvent::ServerUpdated {
            server_id: server_id.clone(),
        }).await;

        if let Ok(op_json) = serde_json::to_string(&op) {
            let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
            if mls_ok {
                let envelope = MessageEnvelope::CrdtOp { sid: server_id.clone(), op_json: op_json.clone() };
                if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &envelope, bundle_keypair) {
                    hollow_log!("[HOLLOW-MLS] CrdtOp broadcast failed: {e}");
                }
            } else {
                for member_peer_str in state.members.keys() {
                    if member_peer_str == &local_peer { continue; }
                    if peer_is_reachable(ws_room_peers, member_peer_str) {
                        send_message_to_peer(
                            ws_cmd_tx, ws_room_peers,
                            member_peer_str, HavenMessage::CrdtOpBroadcast {
                                server_id: server_id.clone(),
                                op_json: op_json.clone(),
                            },
                        );
                    }
                }
            }
        }
    }
    false
}

// ── 10f. SetChannelPosting ──────────────────────────────────────────

pub(crate) async fn handle_set_channel_posting(
    server_states: &mut HashMap<String, ServerState>,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    posting: String,
) -> bool {
    if let Some(state) = server_states.get_mut(&server_id) {
        let local_peer = local_peer_str.to_string();
        if !state.has_permission(&local_peer, Permission::MANAGE_CHANNELS) {
            hollow_log!("[HOLLOW-CRDT] Permission denied: cannot set channel posting in {server_id}");
            let _ = event_tx.send(NetworkEvent::Error {
                message: "Permission denied: cannot manage channels".to_string(),
            }).await;
            return true;
        }

        hollow_log!("[HOLLOW-CRDT] Setting channel {channel_id} posting to {posting} in {server_id}");
        let op = state.create_op(CrdtPayload::ChannelPostingChanged {
            channel_id: channel_id.clone(),
            posting: posting.clone(),
        });
        let _ = state.apply_op(&op);

        if let Ok(json) = serde_json::to_string(&state) {
            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                let _ = store.save_server_state(&server_id, &json);
                let _ = store.insert_crdt_op(&op);
            }
        }

        let _ = event_tx.send(NetworkEvent::ServerUpdated {
            server_id: server_id.clone(),
        }).await;

        if let Ok(op_json) = serde_json::to_string(&op) {
            let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
            if mls_ok {
                let envelope = MessageEnvelope::CrdtOp { sid: server_id.clone(), op_json: op_json.clone() };
                if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &envelope, bundle_keypair) {
                    hollow_log!("[HOLLOW-MLS] CrdtOp broadcast failed: {e}");
                }
            } else {
                for member_peer_str in state.members.keys() {
                    if member_peer_str == &local_peer { continue; }
                    if peer_is_reachable(ws_room_peers, member_peer_str) {
                        send_message_to_peer(
                            ws_cmd_tx, ws_room_peers,
                            member_peer_str, HavenMessage::CrdtOpBroadcast {
                                server_id: server_id.clone(),
                                op_json: op_json.clone(),
                            },
                        );
                    }
                }
            }
        }
    }
    false
}

// ── 10g. ChangeRolePermissions ──────────────────────────────────────

pub(crate) async fn handle_change_role_permissions(
    server_states: &mut HashMap<String, ServerState>,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    role: String,
    permissions: u32,
) -> bool {
    if let Some(state) = server_states.get_mut(&server_id) {
        let local_peer = local_peer_str.to_string();

        // Must have MANAGE_ROLES and can only edit roles below own rank.
        let actor_role = state.get_role(&local_peer);
        let target_role = crate::crdt::operations::MemberRole::from_str(&role);
        if !state.has_permission(&local_peer, Permission::MANAGE_ROLES) || !actor_role.outranks(&target_role) {
            hollow_log!("[HOLLOW-CRDT] Permission denied: cannot change {role} permissions in {server_id}");
            let _ = event_tx.send(NetworkEvent::Error {
                message: format!("Permission denied: cannot change {role} permissions"),
            }).await;
            return true;
        }

        hollow_log!("[HOLLOW-CRDT] Changing {role} permissions to {permissions} in {server_id}");
        let op = state.create_op(CrdtPayload::RolePermissionsChanged {
            role: role.clone(),
            permissions,
        });
        let _ = state.apply_op(&op);

        // Persist
        if let Ok(json) = serde_json::to_string(&state) {
            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                let _ = store.save_server_state(&server_id, &json);
                let _ = store.insert_crdt_op(&op);
            }
        }

        let _ = event_tx.send(NetworkEvent::ServerUpdated {
            server_id: server_id.clone(),
        }).await;

        // Broadcast to connected server members.
        if let Ok(op_json) = serde_json::to_string(&op) {
            let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
            if mls_ok {
                let envelope = MessageEnvelope::CrdtOp { sid: server_id.clone(), op_json: op_json.clone() };
                if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &envelope, bundle_keypair) {
                    hollow_log!("[HOLLOW-MLS] CrdtOp broadcast failed: {e}");
                }
            } else {
                for member_peer_str in state.members.keys() {
                    if member_peer_str == &local_peer { continue; }
                    if peer_is_reachable(ws_room_peers, member_peer_str) {
                        send_message_to_peer(
                            ws_cmd_tx, ws_room_peers,
                            member_peer_str, HavenMessage::CrdtOpBroadcast {
                                server_id: server_id.clone(),
                                op_json: op_json.clone(),
                            },
                        );
                    }
                }
            }
        }
    }
    false
}

// ── 11. SetNickname ───────────────────────────────────────────────────

pub(crate) async fn handle_set_nickname(
    server_states: &mut HashMap<String, ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    peer_id: String,
    nickname: String,
) -> bool {
    if let Some(state) = server_states.get_mut(&server_id) {
        let local_peer = local_peer_str.to_string();

        // Members can set their own nickname. Admins+ can set others'.
        if peer_id != local_peer && !state.has_permission(&local_peer, crate::crdt::operations::Permission::MANAGE_ROLES) {
            hollow_log!("[HOLLOW-CRDT] Permission denied: cannot set nickname for {peer_id}");
            return true;
        }

        hollow_log!("[HOLLOW-CRDT] Setting nickname for {peer_id} to '{nickname}' in {server_id}");
        let op = state.create_op(CrdtPayload::NicknameChanged {
            peer_id: peer_id.clone(),
            nickname: nickname.clone(),
        });
        let _ = state.apply_op(&op);

        // Persist
        if let Ok(json) = serde_json::to_string(&state) {
            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                let _ = store.save_server_state(&server_id, &json);
                let _ = store.insert_crdt_op(&op);
            }
        }

        // Emit event so Dart refreshes member list
        let _ = event_tx.send(NetworkEvent::MemberJoined {
            server_id: server_id.clone(),
            peer_id: peer_id.clone(),
        }).await;

        // Broadcast to connected server members
        if let Ok(op_json) = serde_json::to_string(&op) {
            for member_peer_str in state.members.keys() {
                if member_peer_str == &local_peer { continue; }
                    if peer_is_reachable(ws_room_peers, member_peer_str) {
                        send_message_to_peer(
                            ws_cmd_tx, ws_room_peers,
                            member_peer_str, HavenMessage::CrdtOpBroadcast {
                                server_id: server_id.clone(),
                                op_json: op_json.clone(),
                            },
                        );
                    }
            }
        }
    }
    false
}

// ── 11b. SetTwitchUsername ─────────────────────────────────────────────

pub(crate) async fn handle_set_twitch_username(
    server_states: &mut HashMap<String, ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    peer_id: String,
    twitch_username: String,
) -> bool {
    if let Some(state) = server_states.get_mut(&server_id) {
        let local_peer = local_peer_str.to_string();

        if peer_id != local_peer && !state.has_permission(&local_peer, crate::crdt::operations::Permission::MANAGE_ROLES) {
            return true;
        }

        let op = state.create_op(CrdtPayload::TwitchUsernameChanged {
            peer_id: peer_id.clone(),
            twitch_username: twitch_username.clone(),
        });
        let _ = state.apply_op(&op);

        if let Ok(json) = serde_json::to_string(&state) {
            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                let _ = store.save_server_state(&server_id, &json);
                let _ = store.insert_crdt_op(&op);
            }
        }

        let _ = event_tx.send(NetworkEvent::MemberJoined {
            server_id: server_id.clone(),
            peer_id: peer_id.clone(),
        }).await;

        if let Ok(op_json) = serde_json::to_string(&op) {
            for member_peer_str in state.members.keys() {
                if member_peer_str == &local_peer { continue; }
                    if peer_is_reachable(ws_room_peers, member_peer_str) {
                        send_message_to_peer(
                            ws_cmd_tx, ws_room_peers,
                            member_peer_str, HavenMessage::CrdtOpBroadcast {
                                server_id: server_id.clone(),
                                op_json: op_json.clone(),
                            },
                        );
                    }
            }
        }
    }
    false
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
) -> bool {
    // On-demand sync when user opens a channel.
    // Dedup: skip if already synced this channel recently.
    let dedup_key = format!("{server_id}:{channel_id}");
    if channel_sync_sent.get(&dedup_key).is_some_and(|t| t.elapsed() < Duration::from_secs(5)) {
        return true;
    }
    channel_sync_sent.insert(dedup_key, std::time::Instant::now());
    if let Some(state) = server_states.get(&server_id) {
        let data_dir = crate::identity::data_dir().unwrap_or_default();
        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
        if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                let since = store
                    .get_latest_channel_timestamp(&server_id, &channel_id)
                    .unwrap_or(None)
                    .unwrap_or(0);
                let sender_ts = store
                    .get_per_sender_timestamps(&server_id, &channel_id)
                    .unwrap_or_default();
                let local_peer = local_peer_str.to_string();
                for member_peer_str in state.members.keys() {
                    if member_peer_str == &local_peer { continue; }
                        if peer_is_reachable(ws_room_peers, member_peer_str) {
                            send_message_to_peer(
                                ws_cmd_tx, ws_room_peers,
                                member_peer_str, HavenMessage::ChannelSyncRequest {
                                    server_id: server_id.clone(),
                                    channel_id: channel_id.clone(),
                                    since_timestamp: since,
                                    sender_timestamps: sender_ts.clone(),
                                },
                            );
                        }
                }
            }
        }
    }
    false
}

// ── 13. UpdateChannelLayout ───────────────────────────────────────────

pub(crate) async fn handle_update_channel_layout(
    server_states: &mut HashMap<String, ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    layout_json: String,
) -> bool {
    if let Some(state) = server_states.get_mut(&server_id) {
        let local_peer = local_peer_str.to_string();

        if !state.has_permission(&local_peer, crate::crdt::operations::Permission::MANAGE_CHANNELS) {
            hollow_log!("[HOLLOW-CRDT] Permission denied: cannot update channel layout in {server_id}");
            return true;
        }

        hollow_log!("[HOLLOW-CRDT] Updating channel layout in {server_id}");
        let op = state.create_op(CrdtPayload::ChannelLayoutUpdated {
            layout_json: layout_json.clone(),
        });
        let _ = state.apply_op(&op);

        if let Ok(json) = serde_json::to_string(&state) {
            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                let _ = store.save_server_state(&server_id, &json);
                let _ = store.insert_crdt_op(&op);
            }
        }

        let _ = event_tx.send(NetworkEvent::ServerUpdated {
            server_id: server_id.clone(),
        }).await;

        if let Ok(op_json) = serde_json::to_string(&op) {
            for member_peer_str in state.members.keys() {
                if member_peer_str == &local_peer { continue; }
                    if peer_is_reachable(ws_room_peers, member_peer_str) {
                        send_message_to_peer(
                            ws_cmd_tx, ws_room_peers,
                            member_peer_str, HavenMessage::CrdtOpBroadcast {
                                server_id: server_id.clone(),
                                op_json: op_json.clone(),
                            },
                        );
                    }
            }
        }
    }
    false
}

// ── 14. PinMessage ────────────────────────────────────────────────────

pub(crate) async fn handle_pin_message(
    server_states: &mut HashMap<String, ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    message_id: String,
) -> bool {
    if let Some(state) = server_states.get_mut(&server_id) {
        let local_peer = local_peer_str.to_string();

        if !state.has_permission(&local_peer, crate::crdt::operations::Permission::MANAGE_CHANNELS) {
            hollow_log!("[HOLLOW-CRDT] Permission denied: cannot pin in {server_id}");
            return true;
        }

        hollow_log!("[HOLLOW-CRDT] Pinning message {message_id} in {server_id}/{channel_id}");
        let op = state.create_op(CrdtPayload::MessagePinned {
            channel_id: channel_id.clone(),
            message_id: message_id.clone(),
        });
        let _ = state.apply_op(&op);

        if let Ok(json) = serde_json::to_string(&state) {
            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                let _ = store.save_server_state(&server_id, &json);
                let _ = store.insert_crdt_op(&op);
            }
        }

        let _ = event_tx.send(NetworkEvent::MessagePinned {
            server_id: server_id.clone(),
            channel_id: channel_id.clone(),
            message_id: message_id.clone(),
        }).await;

        if let Ok(op_json) = serde_json::to_string(&op) {
            for member_peer_str in state.members.keys() {
                if member_peer_str == &local_peer { continue; }
                    if peer_is_reachable(ws_room_peers, member_peer_str) {
                        send_message_to_peer(
                            ws_cmd_tx, ws_room_peers,
                            member_peer_str, HavenMessage::CrdtOpBroadcast {
                                server_id: server_id.clone(),
                                op_json: op_json.clone(),
                            },
                        );
                    }
            }
        }
    }
    false
}

// ── 15. UnpinMessage ──────────────────────────────────────────────────

pub(crate) async fn handle_unpin_message(
    server_states: &mut HashMap<String, ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    message_id: String,
) -> bool {
    if let Some(state) = server_states.get_mut(&server_id) {
        let local_peer = local_peer_str.to_string();

        if !state.has_permission(&local_peer, crate::crdt::operations::Permission::MANAGE_CHANNELS) {
            hollow_log!("[HOLLOW-CRDT] Permission denied: cannot unpin in {server_id}");
            return true;
        }

        hollow_log!("[HOLLOW-CRDT] Unpinning message {message_id} in {server_id}/{channel_id}");
        let op = state.create_op(CrdtPayload::MessageUnpinned {
            channel_id: channel_id.clone(),
            message_id: message_id.clone(),
        });
        let _ = state.apply_op(&op);

        if let Ok(json) = serde_json::to_string(&state) {
            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                let _ = store.save_server_state(&server_id, &json);
                let _ = store.insert_crdt_op(&op);
            }
        }

        let _ = event_tx.send(NetworkEvent::MessageUnpinned {
            server_id: server_id.clone(),
            channel_id: channel_id.clone(),
            message_id: message_id.clone(),
        }).await;

        if let Ok(op_json) = serde_json::to_string(&op) {
            for member_peer_str in state.members.keys() {
                if member_peer_str == &local_peer { continue; }
                    if peer_is_reachable(ws_room_peers, member_peer_str) {
                        send_message_to_peer(
                            ws_cmd_tx, ws_room_peers,
                            member_peer_str, HavenMessage::CrdtOpBroadcast {
                                server_id: server_id.clone(),
                                op_json: op_json.clone(),
                            },
                        );
                    }
            }
        }
    }
    false
}

// ── 16. SetStoragePledge ──────────────────────────────────────────────

pub(crate) async fn handle_set_storage_pledge(
    server_states: &mut HashMap<String, ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    local_peer_str: &str,
    server_id: String,
    pledge_bytes: u64,
) {
    if let Some(state) = server_states.get_mut(&server_id) {
        let local_peer = local_peer_str.to_string();

        hollow_log!("[HOLLOW-VAULT] Setting storage pledge to {pledge_bytes} bytes in {server_id}");
        let op = state.create_op(CrdtPayload::StoragePledgeChanged {
            peer_id: local_peer.clone(),
            pledge_bytes,
        });
        let _ = state.apply_op(&op);

        if let Ok(json) = serde_json::to_string(&state) {
            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                let _ = store.save_server_state(&server_id, &json);
                let _ = store.insert_crdt_op(&op);
            }
        }

        let _ = event_tx.send(NetworkEvent::ServerUpdated {
            server_id: server_id.clone(),
        }).await;

        if let Ok(op_json) = serde_json::to_string(&op) {
            for member_peer_str in state.members.keys() {
                if member_peer_str == &local_peer { continue; }
                    if peer_is_reachable(ws_room_peers, member_peer_str) {
                        send_message_to_peer(
                            ws_cmd_tx, ws_room_peers,
                            member_peer_str, HavenMessage::CrdtOpBroadcast {
                                server_id: server_id.clone(),
                                op_json: op_json.clone(),
                            },
                        );
                    }
            }
        }
    }
}

// ── 17. CheckPendingJoinTimeout ───────────────────────────────────────

pub(crate) async fn handle_check_pending_join_timeout(
    pending_server_joins: &mut HashMap<String, Option<String>>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    server_id: String,
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
) {
    let Some(entries) = pending_sync_requests.remove(peer_str) else {
        return;
    };
    if entries.is_empty() {
        return;
    }

    hollow_log!("[HOLLOW-SYNC] Flushing {} pending sync requests for {peer_str}", entries.len());

    let data_dir = crate::identity::data_dir().unwrap_or_default();
    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
    let Ok(proto) = bundle_keypair.to_protobuf_encoding() else { return };
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);
    let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) else { return };

    for (server_id, channel_id, since_timestamp) in entries {
        let _ = event_tx.send(NetworkEvent::MessageSyncStarted {
            server_id: server_id.clone(),
            peer_id: peer_str.to_string(),
        }).await;

        // Re-query per-sender timestamps at flush time (DB may have changed since original request).
        let sender_ts = store.get_per_sender_timestamps(&server_id, &channel_id).unwrap_or_default();
        let messages_result = if !sender_ts.is_empty() {
            store.get_channel_messages_since_per_sender(&server_id, &channel_id, &sender_ts, 200)
        } else {
            store.get_channel_messages_since(&server_id, &channel_id, since_timestamp, 200)
        };
        match messages_result {
            Ok(messages) => {
                hollow_log!("[HOLLOW-SYNC] Retry: sending {} messages for {channel_id} to {peer_str}", messages.len());
                let msg_ids: Vec<String> = messages.iter().filter_map(|m| m.message_id.clone()).collect();
                let reactions_map = store.load_reactions_for_sync(&msg_ids).unwrap_or_default();

                let items: Vec<SyncMessageItem> = messages.iter().map(|m| {
                    let reactions = m.message_id.as_ref()
                        .and_then(|mid| reactions_map.get(mid))
                        .map(|rs| rs.iter().map(|(e, p, ts, sig, pk)| SyncReactionItem {
                            e: e.clone(), p: p.clone(), ts: *ts, sig: sig.clone(), pk: pk.clone(),
                        }).collect())
                        .unwrap_or_default();
                    let file_meta = m.file_id.as_ref().and_then(|fid| {
                        store.get_file_metadata(fid).ok().flatten().map(|f| SyncFileMetaItem {
                            fid: f.file_id,
                            name: f.file_name,
                            ext: f.file_ext,
                            mime: f.mime_type,
                            size: f.size_bytes,
                            img: f.is_image,
                            w: f.width,
                            h: f.height,
                            mid: f.message_id,
                            ts: f.created_at,
                            sender: f.sender_id,
                            vthumb: f.video_thumb,
                        })
                    });
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
                        hidden_at: m.hidden_at,
                        reactions,
                    }
                }).collect();

                let total = if !sender_ts.is_empty() {
                    store.count_channel_messages_since_per_sender(
                        &server_id, &channel_id, &sender_ts,
                    ).unwrap_or(items.len() as u32)
                } else {
                    store.count_channel_messages_since(
                        &server_id, &channel_id, since_timestamp,
                    ).unwrap_or(items.len() as u32)
                };

                let has_more = if items.len() >= 200 && total > 200 {
                    Some(true)
                } else {
                    None
                };
                let envelope = MessageEnvelope::ChannelSyncBatch {
                    sid: server_id.clone(),
                    cid: channel_id,
                    messages: items,
                    total,
                    has_more,
                    target: None,
                };

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
    server_states: &mut HashMap<String, ServerState>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sid: String,
    op_json: String,
) {
    if !server_states.contains_key(&sid) { return; }
    let op = match serde_json::from_str::<crate::crdt::operations::CrdtOp>(&op_json) {
        Ok(o) => o,
        Err(_) => return,
    };
    {
        let state = server_states.get(&sid).unwrap();
        let sender_role = state.get_role(&op.author);
        let sender_perms = sender_role.default_permissions();
        use crate::crdt::operations::{CrdtPayload, Permission, MemberRole};
        let allowed = match &op.payload {
            CrdtPayload::ChannelAdded { .. }
            | CrdtPayload::ChannelRemoved { .. }
            | CrdtPayload::ChannelRenamed { .. }
            | CrdtPayload::ChannelLayoutUpdated { .. } => {
                (sender_perms & Permission::MANAGE_CHANNELS) != 0
            }
            CrdtPayload::RoleChanged { peer_id, role, .. } => {
                state.can_change_role(&op.author, peer_id, role)
            }
            CrdtPayload::ServerRenamed { .. }
            | CrdtPayload::ServerSettingChanged { .. } => {
                sender_role == MemberRole::Owner || sender_role == MemberRole::Admin
            }
            CrdtPayload::MemberRemoved { peer_id } => {
                let target_role = state.get_role(peer_id);
                (sender_perms & Permission::KICK_MEMBERS) != 0
                    && sender_role.outranks(&target_role)
            }
            CrdtPayload::MemberAdded { .. } => {
                state.members.contains_key(&op.author)
            }
            CrdtPayload::NicknameChanged { peer_id, .. } => {
                peer_id == &op.author || sender_role == MemberRole::Owner || sender_role == MemberRole::Admin
            }
            CrdtPayload::TwitchUsernameChanged { peer_id, .. } => {
                peer_id == &op.author || sender_role == MemberRole::Owner || sender_role == MemberRole::Admin
            }
            CrdtPayload::MessagePinned { .. }
            | CrdtPayload::MessageUnpinned { .. } => {
                (sender_perms & Permission::MANAGE_CHANNELS) != 0
            }
            CrdtPayload::StoragePledgeChanged { peer_id, .. } => {
                peer_id == &op.author || sender_role == MemberRole::Owner || sender_role == MemberRole::Admin
            }
            CrdtPayload::RolePermissionsChanged { role, .. } => {
                let target = MemberRole::from_str(role);
                (sender_perms & Permission::MANAGE_ROLES) != 0
                    && sender_role.outranks(&target)
            }
            CrdtPayload::MemberBanned { peer_id } => {
                let target_role = state.get_role(peer_id);
                (sender_perms & Permission::KICK_MEMBERS) != 0
                    && sender_role.outranks(&target_role)
            }
            CrdtPayload::MemberUnbanned { .. } => {
                (sender_perms & Permission::KICK_MEMBERS) != 0
            }
            CrdtPayload::ChannelVisibilityChanged { .. }
            | CrdtPayload::ChannelPostingChanged { .. } => {
                (sender_perms & Permission::MANAGE_CHANNELS) != 0
            }
            CrdtPayload::LabelCreated { .. }
            | CrdtPayload::LabelDeleted { .. }
            | CrdtPayload::LabelUpdated { .. } => {
                (sender_perms & Permission::MANAGE_ROLES) != 0
            }
            CrdtPayload::LabelAssigned { peer_id, .. }
            | CrdtPayload::LabelUnassigned { peer_id, .. } => {
                peer_id == &op.author || (sender_perms & Permission::MANAGE_ROLES) != 0
            }
            CrdtPayload::ServerCreated { .. } => true,
        };
        if !allowed {
            hollow_log!("[HOLLOW-SECURITY] REJECTED MLS CrdtOp from {} — insufficient permission", op.author);
            return;
        }
    }
    let state = server_states.get_mut(&sid).unwrap();
    let was_len = state.op_log.len();
    let _ = state.apply_op(&op);
    if state.op_log.len() > was_len {
        if let Ok(json) = serde_json::to_string(&*state) {
            let data_dir = crate::identity::data_dir().unwrap_or_default();
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                let _ = store.save_server_state(&sid, &json);
                let _ = store.insert_crdt_op(&op);
            }
        }
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
            CrdtPayload::RoleChanged { peer_id, role, .. } => {
                let _ = event_tx.send(NetworkEvent::RoleChanged {
                    server_id: sid.clone(), peer_id: peer_id.clone(), new_role: role.as_str().to_string(),
                }).await;
            }
            CrdtPayload::ServerSettingChanged { .. }
            | CrdtPayload::ServerRenamed { .. }
            | CrdtPayload::RolePermissionsChanged { .. }
            | CrdtPayload::MemberBanned { .. }
            | CrdtPayload::MemberUnbanned { .. }
            | CrdtPayload::ChannelVisibilityChanged { .. }
            | CrdtPayload::ChannelPostingChanged { .. }
            | CrdtPayload::LabelCreated { .. }
            | CrdtPayload::LabelDeleted { .. }
            | CrdtPayload::LabelUpdated { .. }
            | CrdtPayload::LabelAssigned { .. }
            | CrdtPayload::LabelUnassigned { .. } => {
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
) {
    let sender_role = server_states.get(&sid)
        .map(|s| s.get_role(sender_peer_id))
        .unwrap_or(crate::crdt::operations::MemberRole::Member);
    if sender_role != crate::crdt::operations::MemberRole::Owner {
        hollow_log!("[HOLLOW-SECURITY] REJECTED MLS ServerDelete from {sender_peer_id} — not owner");
        return;
    }
    if server_states.remove(&sid).is_some() {
        let data_dir = crate::identity::data_dir().unwrap_or_default();
        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
            let _ = store.delete_server_state(&sid);
        }
        if let Some(mls_mgr_ref) = mls {
            mls_mgr_ref.remove_group(&sid);
            persist_mls_state(mls_mgr_ref, bundle_keypair);
        }
        let _ = event_tx.send(NetworkEvent::ServerDeleted {
            server_id: sid,
        }).await;
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
) {
    let can_kick = if let Some(state) = server_states.get(&sid) {
        let sender_role = state.get_role(sender_peer_id);
        let our_role = state.get_role(local_peer);
        let sender_perms = sender_role.default_permissions();
        (sender_perms & crate::crdt::operations::Permission::KICK_MEMBERS) != 0
            && sender_role.outranks(&our_role)
    } else { false };
    if !can_kick {
        hollow_log!("[HOLLOW-SECURITY] REJECTED MLS MemberKick from {sender_peer_id} — insufficient permissions");
        return;
    }
    if server_states.remove(&sid).is_some() {
        let data_dir = crate::identity::data_dir().unwrap_or_default();
        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
            let _ = store.delete_server_state(&sid);
        }
        if let Some(mls_mgr_ref) = mls {
            mls_mgr_ref.remove_group(&sid);
            persist_mls_state(mls_mgr_ref, bundle_keypair);
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
                let mls_sent = send_mls_to_peer(mls_mgr, ws_cmd_tx, &sid, &sender_peer_id, &resp, bundle_keypair).is_ok();
                if !mls_sent {
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
}

/// Handle `MessageEnvelope::SyncResp` (MLS path).
pub(crate) async fn handle_envelope_sync_resp(
    server_states: &mut HashMap<String, ServerState>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sid: String,
    ops_json: String,
) {
    if let Some(state) = server_states.get_mut(&sid) {
        if let Ok(incoming_ops) = serde_json::from_str::<Vec<crate::crdt::operations::CrdtOp>>(&ops_json) {
            if let Ok(applied) = crate::crdt::sync::merge_ops(state, incoming_ops) {
                if applied > 0 {
                    if let Ok(json) = serde_json::to_string(&*state) {
                        let data_dir = crate::identity::data_dir().unwrap_or_default();
                        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                            let _ = store.save_server_state(&sid, &json);
                        }
                    }
                    let _ = event_tx.send(NetworkEvent::SyncCompleted {
                        server_id: sid.clone(),
                        ops_applied: applied as u32,
                    }).await;
                }
            }
        }
    }
}

/// Handle `MessageEnvelope::ChannelSyncReq` (MLS path).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_channel_sync_req(
    server_states: &HashMap<String, ServerState>,
    mls: &mut Option<MlsManager>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    sender_peer_id: &str,
    sid: String,
    cid: String,
    since_timestamp: i64,
    sender_timestamps: HashMap<String, i64>,
) {
    if !server_states.contains_key(&sid) { return; }
    let data_dir = crate::identity::data_dir().unwrap_or_default();
    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
    let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);
    if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
        let msgs_result = if !sender_timestamps.is_empty() {
            store.get_channel_messages_since_per_sender(&sid, &cid, &sender_timestamps, 200)
        } else {
            store.get_channel_messages_since(&sid, &cid, since_timestamp, 200)
        };
        if let Ok(messages) = msgs_result {
            let msg_ids: Vec<String> = messages.iter().filter_map(|m| m.message_id.clone()).collect();
            let reactions_map = store.load_reactions_for_sync(&msg_ids).unwrap_or_default();
            let items: Vec<SyncMessageItem> = messages.iter().map(|m| {
                let reactions = m.message_id.as_ref()
                    .and_then(|mid| reactions_map.get(mid))
                    .map(|rs| rs.iter().map(|(e, p, ts, sig, pk)| SyncReactionItem {
                        e: e.clone(), p: p.clone(), ts: *ts, sig: sig.clone(), pk: pk.clone(),
                    }).collect())
                    .unwrap_or_default();
                let file_meta = m.file_id.as_ref().and_then(|fid| {
                    store.get_file_metadata(fid).ok().flatten().map(|f| SyncFileMetaItem {
                        fid: f.file_id, name: f.file_name, ext: f.file_ext, mime: f.mime_type,
                        size: f.size_bytes, img: f.is_image, w: f.width, h: f.height,
                        mid: f.message_id, ts: f.created_at, sender: f.sender_id,
                        vthumb: f.video_thumb,
                    })
                });
                SyncMessageItem {
                    s: m.sender_id.clone(), t: m.text.clone(), ts: m.timestamp,
                    sig: m.signature.clone(), pk: m.public_key.clone(),
                    mid: m.message_id.clone(), edited_at: m.edited_at,
                    reply_to: m.reply_to_mid.clone(), file_id: m.file_id.clone(),
                    file_meta, hidden_at: m.hidden_at, reactions,
                }
            }).collect();
            if !items.is_empty() {
                let total = if !sender_timestamps.is_empty() {
                    store.count_channel_messages_since_per_sender(&sid, &cid, &sender_timestamps).unwrap_or(items.len() as u32)
                } else {
                    store.count_channel_messages_since(&sid, &cid, since_timestamp).unwrap_or(items.len() as u32)
                };
                let has_more = if items.len() >= 200 && total > 200 { Some(true) } else { None };
                let batch = MessageEnvelope::ChannelSyncBatch {
                    sid: sid.clone(), cid: cid.clone(), messages: items,
                    total, has_more, target: None,
                };
                if let Some(mls_mgr_ref) = mls {
                    if let Err(e) = send_mls_to_peer(mls_mgr_ref, ws_cmd_tx, &sid, sender_peer_id, &batch, bundle_keypair) {
                        hollow_log!("[HOLLOW-MLS] Failed to send MLS ChannelSyncBatch: {e}");
                    }
                }
            }
        }
    }
}

/// Handle `MessageEnvelope::ChannelProbe` (MLS path).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_channel_probe(
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
    cid: String,
) {
    if !server_states.contains_key(&sid) { return; }
    let data_dir = crate::identity::data_dir().unwrap_or_default();
    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
    let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);
    if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
        let our_latest = store.get_latest_channel_timestamp(&sid, &cid)
            .unwrap_or(None).unwrap_or(0);
        let our_count = store.count_channel_messages(&sid, &cid);
        let resp = MessageEnvelope::ChannelProbeResp {
            sid: sid.clone(), cid,
            their_latest: our_latest,
            msg_count: our_count,
            target: None,
        };
        let mls_sent = send_mls_to_peer(mls_mgr, ws_cmd_tx, &sid, &sender_peer_id, &resp, bundle_keypair).is_ok();
        if !mls_sent {
            let resp_json = serde_json::to_string(&resp).unwrap_or_default();
            send_encrypted_message(
                olm, crypto_store,
                &sender_peer_id, &resp_json, event_tx,
                ws_cmd_tx, ws_room_peers,
            ).await;
        }
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
) {
    let dedup_key = format!("{sid}:{cid}");
    if channel_sync_sent.get(&dedup_key).is_some_and(|t| t.elapsed() < Duration::from_secs(5)) {
        return;
    }
    let data_dir = crate::identity::data_dir().unwrap_or_default();
    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
    let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);
    if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
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
    mls: &mut Option<MlsManager>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    local_peer: &str,
    sender_peer_id: &str,
    sid: String,
    cid: String,
    messages: Vec<SyncMessageItem>,
    _total: u32,
    has_more: Option<bool>,
) {
    let data_dir = crate::identity::data_dir().unwrap_or_default();
    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
    let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);
    if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
        let mut new_count = 0u32;
        for msg in &messages {
            let is_mine = msg.s == local_peer;
            let already_exists = msg.mid.as_ref()
                .map(|mid| store.channel_message_exists(mid))
                .unwrap_or(false);

            if !already_exists {
                if let Ok(1) = store.insert_channel_message(
                    &sid, &cid, &msg.s, &msg.t, is_mine, msg.ts,
                    msg.sig.as_deref(), msg.pk.as_deref(), msg.mid.as_deref(),
                    msg.reply_to.as_deref(), msg.file_id.as_deref(),
                ) {
                    new_count += 1;
                }
            }
            if let (Some(edit_ts), Some(mid)) = (msg.edited_at, &msg.mid) {
                if store.edit_channel_message(
                    mid, &msg.t, edit_ts,
                    msg.sig.as_deref(),
                    msg.pk.as_deref(),
                ).unwrap_or(false) {
                    let _ = event_tx.send(NetworkEvent::ChannelMessageEdited {
                        server_id: sid.clone(),
                        channel_id: cid.clone(),
                        message_id: mid.clone(),
                        new_text: msg.t.clone(),
                        edited_at: edit_ts,
                        signature: msg.sig.clone(),
                        public_key: msg.pk.clone(),
                    }).await;
                }
            }
            if let (Some(hidden_ts), Some(mid)) = (msg.hidden_at, &msg.mid) {
                if store.set_channel_message_hidden(mid, hidden_ts).is_ok() {
                    let _ = event_tx.send(NetworkEvent::ChannelMessageDeleted {
                        server_id: sid.clone(),
                        channel_id: cid.clone(),
                        message_id: mid.clone(),
                        deleted_at: hidden_ts,
                    }).await;
                }
            }
            if let Some(ref fm) = msg.file_meta {
                let ctx_id = format!("{sid}:{cid}");
                let _ = store.insert_file_metadata(
                    &fm.fid, &fm.name, &fm.ext, &fm.mime,
                    fm.size, 0, fm.img, fm.w, fm.h,
                    fm.mid.as_deref(), "channel", &ctx_id,
                    &fm.sender, msg.s == local_peer, fm.ts,
                    fm.vthumb.as_ref(),
                );
                let _ = event_tx.send(NetworkEvent::FileHeaderReceived {
                    file_id: fm.fid.clone(), file_name: fm.name.clone(),
                    size_bytes: fm.size, is_image: fm.img,
                    width: fm.w, height: fm.h,
                    message_id: fm.mid.clone().unwrap_or_default(),
                    sender_id: fm.sender.clone(),
                    server_id: sid.clone(), channel_id: cid.clone(),
                    video_thumb: fm.vthumb.clone(),
                    share_ref: None,
                }).await;
            }
            if let Some(mid) = &msg.mid {
                for r in &msg.reactions {
                    let _ = store.add_reaction(
                        mid, &r.e, &r.p, r.ts,
                        r.sig.as_deref(), r.pk.as_deref(),
                    );
                }
            }
        }
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
            if let Some(mls_mgr_ref) = mls {
                if let Err(e) = send_mls_to_peer(mls_mgr_ref, ws_cmd_tx, &sid, sender_peer_id, &req, bundle_keypair) {
                    hollow_log!("[HOLLOW-MLS] Failed to send follow-up ChannelSyncReq: {e}");
                }
            }
        }
        if has_more != Some(true) {
            let _ = event_tx.send(NetworkEvent::MessageSyncCompleted {
                server_id: sid,
                new_message_count: new_count,
            }).await;
        }
    }
}
