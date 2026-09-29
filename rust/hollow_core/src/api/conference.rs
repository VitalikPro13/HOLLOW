//! Conference FFI — Zoom-style rooms with an MLS-gated waiting room.
//! Design doc: `reports/shipped/voice-and-media/CONFERENCES_PLAN.md`; node logic in `node/conference.rs`.
//!
//! Room CRUD talks to the long-lived MessageStore, since rooms are host-local objects,
//! while meeting lifecycle rides NodeCommands into the swarm loop. The media path is
//! the existing voice-channel FFI under the virtual server id `conf:{conf_id}`, so
//! there is no new media plumbing.

use flutter_rust_bridge::frb;

use crate::api::network::{get_node, get_runtime};
use crate::api::storage::get_store;
use crate::node;
use crate::storage::messages::ConferenceRow;

/// FFI-facing room descriptor. The access code never leaves Rust — Dart only
/// learns whether one is set. `link_key` goes into the room's link.
pub struct ConferenceInfo {
    pub conf_id: String,
    pub link_key: String,
    pub name: String,
    pub waiting_room: bool,
    pub has_access_code: bool,
    pub broadcast_mode: bool,
    pub created_at: i64,
}

impl From<ConferenceRow> for ConferenceInfo {
    fn from(r: ConferenceRow) -> Self {
        ConferenceInfo {
            conf_id: r.conf_id,
            link_key: r.link_key.unwrap_or_default(),
            name: r.name,
            waiting_room: r.waiting_room,
            has_access_code: r.access_code_hash.is_some(),
            broadcast_mode: r.broadcast_mode,
            created_at: r.created_at,
        }
    }
}

fn send_command(cmd: node::NodeCommand) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    // Drop the mutex before the send: holding it across block_on(send) serializes
    // every other FFI call.
    drop(guard);
    get_runtime()
        .block_on(cmd_tx.send(cmd))
        .map_err(|e| format!("Failed to send command: {e}"))
}

/// What a host sees when starting a room made before 0.12.
const OLD_ROOM: &str = "This room was made before the update and can't start. Make a new room to get a new link.";
/// What a joiner sees for a link to such a room.
const OLD_LINK: &str = "This meeting link is from before the update. Ask the host for a new one.";

/// Create or update a conference room.
///
/// `conf_id: None` creates a room whose unguessable id hashes from our master and a
/// fresh nonce, so the link is the capability and names its host. `access_code`
/// follows the profile convention: `None` keeps the current code, `Some("")` clears
/// it, `Some(code)` sets it (stored as its conf-scoped key).
#[frb]
pub fn conference_upsert(
    conf_id: Option<String>,
    name: String,
    waiting_room: bool,
    access_code: Option<String>,
    broadcast_mode: bool,
) -> Result<ConferenceInfo, String> {
    let store_lock = get_store();
    let (conf_id, existing, host_nonce) = match conf_id {
        Some(id) => {
            let guard = store_lock.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
            let store = guard.as_ref().ok_or("Message store not open")?;
            let existing = store.get_conference(&id)?;
            let nonce = existing.as_ref().and_then(|e| e.host_nonce.clone());
            (id, existing, nonce)
        }
        None => {
            let master = crate::api::network::get_local_peer_id()
                .ok_or("Hollow is still starting; try again in a moment")?;
            let nonce = node::conference::new_conf_nonce()?;
            (node::conference::derive_conf_id(&master, &nonce), None, Some(nonce))
        }
    };

    // Argon2 runs here, on the FFI thread and with the store unlocked.
    let access_code_hash = match access_code {
        None => existing.as_ref().and_then(|e| e.access_code_hash.clone()),
        Some(code) if code.is_empty() => None,
        Some(code) => Some(node::conference::derive_code_key(&conf_id, &code)?),
    };

    let guard = store_lock.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let store = guard.as_ref().ok_or("Message store not open")?;

    let row = ConferenceRow {
        conf_id: conf_id.clone(),
        name,
        waiting_room,
        access_code_hash,
        co_hosts: existing.as_ref().map(|e| e.co_hosts.clone()).unwrap_or_else(|| "[]".to_string()),
        broadcast_mode,
        created_at: existing.as_ref().map(|e| e.created_at).unwrap_or_else(|| {
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis() as i64)
                .unwrap_or(0)
        }),
        host_nonce,
        link_key: match existing.as_ref().and_then(|e| e.link_key.clone()) {
            Some(key) => Some(key),
            None => Some(node::conference::new_link_key()?),
        },
    };
    store.upsert_conference(&row)?;
    Ok(row.into())
}

/// List this device's conference rooms (newest first).
#[frb]
pub fn conference_list() -> Result<Vec<ConferenceInfo>, String> {
    let store_lock = get_store();
    let guard = store_lock.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let store = guard.as_ref().ok_or("Message store not open")?;
    Ok(store.list_conferences()?.into_iter().map(Into::into).collect())
}

/// Delete a room — retires its link forever.
#[frb]
pub fn conference_delete(conf_id: String) -> Result<(), String> {
    let store_lock = get_store();
    let guard = store_lock.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let store = guard.as_ref().ok_or("Message store not open")?;
    store.delete_conference(&conf_id)
}

/// (Host) start a meeting: mints a FRESH MLS group + joins the relay room.
/// Follow up with `voice_channel_join("conf:{conf_id}", "main")` from Dart.
#[frb]
pub fn conference_start(
    conf_id: String,
    host_display_name: String,
    host_avatar_hash: String,
) -> Result<(), String> {
    let (waiting_room, code_key, nonce, link_key) = {
        let store_lock = get_store();
        let guard = store_lock.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        let store = guard.as_ref().ok_or("Message store not open")?;
        let mut row = store.get_conference(&conf_id)?.ok_or("Unknown conference")?;
        // A room made before its link carried a key gets one now; its old link stops.
        if row.link_key.is_none() {
            row.link_key = Some(node::conference::new_link_key()?);
            store.upsert_conference(&row)?;
        }
        (row.waiting_room, row.access_code_hash, row.host_nonce, row.link_key.unwrap_or_default())
    };
    let master = crate::api::network::get_local_peer_id()
        .ok_or("Hollow is still starting; try again in a moment")?;
    let nonce = nonce
        .filter(|n| node::conference::hosts_meeting(&conf_id, &master, Some(n)))
        .ok_or(OLD_ROOM)?;
    send_command(node::NodeCommand::ConferenceStart {
        conf_id, nonce, link_key, waiting_room, code_key,
        host_display_name, host_avatar_hash,
    })
}

/// (Host) end the meeting for everyone.
#[frb]
pub fn conference_end(conf_id: String) -> Result<(), String> {
    send_command(node::NodeCommand::ConferenceEnd { conf_id })
}

/// (Joiner) knock: enter the relay room and send a join request, sealed under the
/// `link_key` the meeting link carries. Watch for `ConferenceLobbyInfo` /
/// `ConferenceAdmitted` / `ConferenceJoinDenied`.
#[frb]
pub fn conference_request_join(
    conf_id: String,
    link_key: String,
    display_name: String,
    avatar_hash: String,
    access_code: Option<String>,
) -> Result<(), String> {
    if !node::conference::is_pinned_conf_id(&conf_id) || !node::conference::is_link_key(&link_key) {
        return Err(OLD_LINK.to_string());
    }
    let code_key = access_code
        .filter(|c| !c.is_empty())
        .map(|c| node::conference::derive_code_key(&conf_id, &c))
        .transpose()?;
    send_command(node::NodeCommand::ConferenceRequestJoin {
        conf_id, link_key, display_name, avatar_hash, code_key,
    })
}

/// (Host) admit a waiting-room entry — commits the MLS add.
#[frb]
pub fn conference_admit(conf_id: String, peer_id: String) -> Result<(), String> {
    send_command(node::NodeCommand::ConferenceAdmit { conf_id, peer_id })
}

/// (Host) decline a waiting-room entry.
#[frb]
pub fn conference_deny(conf_id: String, peer_id: String, reason: String) -> Result<(), String> {
    send_command(node::NodeCommand::ConferenceDeny { conf_id, peer_id, reason })
}

/// (Host) remove a CURRENT member — MLS remove commit + teardown signal.
#[frb]
pub fn conference_kick(conf_id: String, peer_id: String) -> Result<(), String> {
    send_command(node::NodeCommand::ConferenceKick { conf_id, peer_id })
}

/// (Joiner) leave the conference room (also voice_channel_leave from Dart).
#[frb]
pub fn conference_leave(conf_id: String) -> Result<(), String> {
    send_command(node::NodeCommand::ConferenceLeave { conf_id })
}

/// Send a RAM-only conference chat line (MLS application message).
#[frb]
pub fn conference_send_chat(conf_id: String, text: String) -> Result<i64, String> {
    super::network::refuse_oversized_message(&text)?;
    // Lamport chat clock: conference chat sorts by the same stamps as every
    // other chat surface (never raw SystemTime — clock skew misorders replies).
    let stamp_us = crate::chat_clock::next_send_stamp_us();
    let timestamp = stamp_us / 1000;
    send_command(node::NodeCommand::ConferenceSendChat { conf_id, text, timestamp })?;
    Ok(timestamp)
}
