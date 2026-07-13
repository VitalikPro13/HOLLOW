//! Conference FFI — Zoom-style rooms with an MLS-gated waiting room.
//! Design doc: `reports/CONFERENCES_PLAN.md`; node logic in `node/conference.rs`.
//!
//! Room CRUD talks to the long-lived MessageStore (rooms are host-local
//! objects); meeting lifecycle rides NodeCommands into the swarm loop. The
//! media path is the existing voice-channel FFI called with the virtual
//! server id `conf:{conf_id}` and channel `"main"` — no new media plumbing.

use flutter_rust_bridge::frb;

use crate::api::network::{get_node, get_runtime};
use crate::api::storage::get_store;
use crate::node;
use crate::storage::messages::ConferenceRow;

/// FFI-facing room descriptor. The access code never leaves Rust — Dart only
/// learns whether one is set.
pub struct ConferenceInfo {
    pub conf_id: String,
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
    // Release the global node mutex BEFORE the (possibly waiting) send —
    // holding it across block_on(send) serializes all other FFI calls.
    drop(guard);
    get_runtime()
        .block_on(cmd_tx.send(cmd))
        .map_err(|e| format!("Failed to send command: {e}"))
}

/// Create or update a conference room.
///
/// `conf_id: None` creates a new room with a random unguessable id (the link
/// capability). `access_code` follows the profile COALESCE convention:
/// `None` = keep the existing code, `Some("")` = clear it, `Some(code)` = set
/// (stored as a conf-scoped hash, never plaintext).
#[frb]
pub fn conference_upsert(
    conf_id: Option<String>,
    name: String,
    waiting_room: bool,
    access_code: Option<String>,
    broadcast_mode: bool,
) -> Result<ConferenceInfo, String> {
    let store_lock = get_store();
    let guard = store_lock.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let store = guard.as_ref().ok_or("Message store not open")?;

    let (conf_id, existing) = match conf_id {
        Some(id) => {
            let existing = store.get_conference(&id)?;
            (id, existing)
        }
        None => {
            let mut bytes = [0u8; 16];
            getrandom::fill(&mut bytes).map_err(|e| format!("RNG error: {e}"))?;
            (hex::encode(bytes), None)
        }
    };

    let access_code_hash = match access_code {
        None => existing.as_ref().and_then(|e| e.access_code_hash.clone()),
        Some(code) if code.is_empty() => None,
        Some(code) => Some(node::conference::derive_access_hash(&conf_id, &code)),
    };

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
    let (waiting_room, access_code_hash) = {
        let store_lock = get_store();
        let guard = store_lock.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        let store = guard.as_ref().ok_or("Message store not open")?;
        let row = store.get_conference(&conf_id)?.ok_or("Unknown conference")?;
        (row.waiting_room, row.access_code_hash)
    };
    send_command(node::NodeCommand::ConferenceStart {
        conf_id, waiting_room, access_code_hash,
        host_display_name, host_avatar_hash,
    })
}

/// (Host) end the meeting for everyone.
#[frb]
pub fn conference_end(conf_id: String) -> Result<(), String> {
    send_command(node::NodeCommand::ConferenceEnd { conf_id })
}

/// (Joiner) knock: enter the relay room and send a join request. Watch for
/// `ConferenceLobbyInfo` / `ConferenceAdmitted` / `ConferenceJoinDenied`.
#[frb]
pub fn conference_request_join(
    conf_id: String,
    display_name: String,
    avatar_hash: String,
    access_code: Option<String>,
) -> Result<(), String> {
    send_command(node::NodeCommand::ConferenceRequestJoin {
        conf_id, display_name, avatar_hash, access_code,
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
    // Lamport chat clock: conference chat sorts by the same stamps as every
    // other chat surface (never raw SystemTime — clock skew misorders replies).
    let stamp_us = crate::chat_clock::next_send_stamp_us();
    let timestamp = stamp_us / 1000;
    send_command(node::NodeCommand::ConferenceSendChat { conf_id, text, timestamp })?;
    Ok(timestamp)
}
