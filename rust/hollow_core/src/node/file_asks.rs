//! Honest file card states: the asker side of `FileRequest`.
//!
//! A file whose bytes are not on disk used to show a Download button that could
//! silently do nothing: the request went to ONE holder, and a holder that no
//! longer had the bytes said NOTHING, so the asker could not tell "they are
//! offline" from "they deleted it" and the card could not say either.
//!
//! This is the asset rail's [`super::emotes::PendingAsk`] applied to file bytes.
//! Every explicit pull becomes a [`PendingFileAsk`] that OUTLIVES the socket; a
//! holder that cannot serve answers `HavenMessage::FileUnavailable` instead of
//! staying silent and the walk rotates; a `FileUnavailable` from a device THIS ask
//! never asked changes nothing; and every state change is reported as
//! `NetworkEvent::FileAvailability`, so the card says what is happening.
//!
//! ONE holder is asked at a time. Every holder re-encrypts its stream under its
//! own AES key and the receiver kept exactly one `FileHeader` key, so two parallel
//! streams can only fail to decrypt.

use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use tokio::sync::mpsc;

use super::crypto_handler::{online_devices_for, send_message_to_peer_in_room, ws_room_for_peer};
use super::types::{HavenMessage, NetworkEvent};
use crate::crdt::server_state::ServerState;

/// Ceiling on outstanding pulls. Overflow evicts the oldest ask, so a burst of
/// undownloaded cards can never grow this without bound.
const MAX_PENDING_FILE_ASKS: usize = 256;

/// Distinct holders asked for one file per connection. After the last miss the
/// file waits for a reconnect, a new peer, or the user asking again.
const MAX_FILE_ASK_CANDIDATES: usize = 4;

/// Files one sweep may act on, bounding both the burst of frames a reconnect
/// can produce and the work the sweep does ON THE EVENT LOOP.
const MAX_FILE_ASKS_PER_SWEEP: usize = 8;

/// How long an ask sits unanswered before the retry sweep rotates it to the next
/// holder; the answering `FileHeader` arrives in seconds even for a large file, so
/// this only has to outlast a round trip. Shortened under `cfg(test)`.
pub(crate) const FILE_ASK_TIMEOUT_SECS: u64 = if cfg!(test) { 1 } else { 15 };

/// Where an ask may look for holders. Read off the file row once, at upsert.
pub(crate) enum FileAskContext {
    /// DM row: the conversation counterparty's MASTER.
    Dm { peer: String },
    /// Channel row: the server room is the candidate pool.
    Channel {
        server_id: String,
        channel_id: String,
    },
}

/// One outstanding pull for a file's bytes, kept ACROSS reconnects.
pub(crate) struct PendingFileAsk {
    pub(crate) context: FileAskContext,
    /// The row's sender MASTER (resolved). The preferred holder, and the name
    /// the "no longer has this file" state falls back to.
    pub(crate) sender: String,
    /// DEVICE ids asked on THIS connection.
    pub(crate) asked: HashSet<String>,
    /// The ONE outstanding request, as (device, sent at).
    pub(crate) in_flight: Option<(String, Instant)>,
    /// Devices that answered `FileUnavailable` on this connection, with reason.
    pub(crate) negatives: Vec<(String, String)>,
    pub(crate) first_asked_at: Instant,
    pub(crate) last_asked_at: Instant,
}

impl PendingFileAsk {
    /// The state to report when the walk has nobody left to ask: a walk that
    /// heard at least one "I do not have it" is a dead end (`gone`); one that
    /// simply found nobody reachable is still waiting.
    fn dead_end(&self) -> (&'static str, String) {
        if self.negatives.is_empty() {
            return match &self.context {
                FileAskContext::Dm { peer } => ("waiting", super::resolver::resolve(peer)),
                FileAskContext::Channel { .. } => ("waiting", String::new()),
            };
        }
        // Name the SENDER when one of its devices answered (that is the name
        // the card wants), otherwise the peer that answered most recently.
        let from_sender = self
            .negatives
            .iter()
            .any(|(dev, _)| super::resolver::resolve(dev) == self.sender);
        let who = if from_sender {
            self.sender.clone()
        } else {
            self.negatives
                .last()
                .map(|(dev, _)| super::resolver::resolve(dev))
                .unwrap_or_default()
        };
        ("gone", who)
    }
}

/// Every holder this ask could still try, best first and otherwise in ascending
/// device-id order so the walk is reproducible. Each entry carries the room the
/// send must go out through: a targeted send routes to its DETERMINISTIC room.
fn ask_candidates(
    ask: &PendingFileAsk,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    server_states: &HashMap<String, ServerState>,
    local_master: &str,
    local_device: &str,
) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    match &ask.context {
        FileAskContext::Dm { peer } => {
            // Sends target a DEVICE; the row names a MASTER.
            let mut devices = online_devices_for(ws_room_peers, peer);
            devices.sort();
            for dev in devices {
                if let Some(room) = ws_room_for_peer(ws_room_peers, &dev) {
                    out.push((dev, room));
                }
            }
            // Our own siblings were fanned the same bytes at send time.
            let mut siblings = online_devices_for(ws_room_peers, local_master);
            siblings.sort();
            for dev in siblings {
                if dev == local_device {
                    continue;
                }
                if let Some(room) = ws_room_for_peer(ws_room_peers, &dev) {
                    out.push((dev, room));
                }
            }
        }
        FileAskContext::Channel {
            server_id,
            channel_id,
        } => {
            // The sender first: the one holder we know had the bytes.
            let mut devices = online_devices_for(ws_room_peers, &ask.sender);
            devices.sort();
            for dev in devices {
                let in_server_room = ws_room_peers
                    .get(server_id)
                    .is_some_and(|peers| peers.contains(&dev));
                let room = if in_server_room {
                    Some(server_id.clone())
                } else {
                    ws_room_for_peer(ws_room_peers, &dev)
                };
                if let Some(room) = room {
                    out.push((dev, room));
                }
            }
            // Then every other member that may LEGITIMATELY hold the bytes: full
            // replication put a copy on everyone the channel ladder allows.
            if let Some(state) = server_states.get(server_id) {
                for dev in super::file_handler::channel_holder_candidates(
                    state,
                    channel_id,
                    ws_room_peers,
                    local_master,
                ) {
                    out.push((dev, server_id.clone()));
                }
            }
        }
    }
    let mut seen: HashSet<String> = HashSet::new();
    out.retain(|(dev, _)| {
        dev != local_master
            && dev != local_device
            && !ask.asked.contains(dev)
            && seen.insert(dev.clone())
    });
    out
}

/// The files a sweep will actually act on: longest-unanswered first, capped at
/// [`MAX_FILE_ASKS_PER_SWEEP`] so a backlog drains over several passes.
fn sweep_order(pending: &HashMap<String, PendingFileAsk>, mut ids: Vec<String>) -> Vec<String> {
    ids.sort_by_key(|f| pending.get(f).map(|a| a.last_asked_at));
    ids.truncate(MAX_FILE_ASKS_PER_SWEEP);
    ids
}

/// Drop the oldest asks once the table is full.
fn evict_overflow(pending: &mut HashMap<String, PendingFileAsk>) {
    while pending.len() > MAX_PENDING_FILE_ASKS {
        let Some(oldest) = pending
            .iter()
            .min_by_key(|(_, a)| a.first_asked_at)
            .map(|(f, _)| f.clone())
        else {
            return;
        };
        pending.remove(&oldest);
    }
}

/// Ask ONE holder, and tell the card who is being asked.
#[allow(clippy::too_many_arguments)]
async fn dispatch_one(
    ws_cmd_tx: &mpsc::UnboundedSender<super::ws_client::WsCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    pending: &mut HashMap<String, PendingFileAsk>,
    requested_file_receipts: &mut HashMap<String, Instant>,
    declined_file_ids: &mut HashSet<String>,
    pending_ws_transfers: &HashMap<String, super::ws_stream_transfer::WsTransferState>,
    file_id: &str,
    device: &str,
    room: &str,
) {
    let offset = pending_ws_transfers
        .get(file_id)
        .map(|s| s.bytes_received)
        .unwrap_or(0);

    // CRITICAL, and the load-bearing line of this module: the explicit-pull receipt
    // is CLEARED on `WsEvent::Disconnected` and CONSUMED at header time, so a retry
    // that does not re-stamp it has its own answer refused by the auto-download
    // gate. Same for the decline pin: a declined push is what a manual pull is for.
    requested_file_receipts.insert(file_id.to_string(), Instant::now());
    declined_file_ids.remove(file_id);

    send_message_to_peer_in_room(
        ws_cmd_tx,
        room,
        device,
        HavenMessage::FileRequest {
            file_id: file_id.to_string(),
            chunks: Vec::new(),
            offset,
        },
    );
    hollow_log!("[HOLLOW-FILE] Asking {device} for {file_id} in {room} (offset {offset})");

    let now = Instant::now();
    if let Some(ask) = pending.get_mut(file_id) {
        ask.asked.insert(device.to_string());
        ask.in_flight = Some((device.to_string(), now));
        ask.last_asked_at = now;
    }
    let _ = event_tx
        .send(NetworkEvent::FileAvailability {
            file_id: file_id.to_string(),
            state: "requesting".to_string(),
            peer_id: super::resolver::resolve(device),
        })
        .await;
}

/// Move one ask to its next holder. `announce_dead_end` is false for the
/// roster-driven retries, which run over every pending ask and must stay silent
/// about the ones they cannot help.
#[allow(clippy::too_many_arguments)]
async fn advance(
    ws_cmd_tx: &mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    server_states: &HashMap<String, ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    pending: &mut HashMap<String, PendingFileAsk>,
    requested_file_receipts: &mut HashMap<String, Instant>,
    declined_file_ids: &mut HashSet<String>,
    pending_ws_transfers: &HashMap<String, super::ws_stream_transfer::WsTransferState>,
    file_id: &str,
    prefer: Option<&str>,
    local_master: &str,
    local_device: &str,
    announce_dead_end: bool,
) {
    let (picked, dead_end) = {
        let Some(ask) = pending.get(file_id) else {
            return;
        };
        let picked = if ask.asked.len() >= MAX_FILE_ASK_CANDIDATES {
            None
        } else {
            let candidates =
                ask_candidates(ask, ws_room_peers, server_states, local_master, local_device);
            prefer
                .and_then(|p| candidates.iter().find(|(dev, _)| dev == p))
                .or_else(|| candidates.first())
                .cloned()
        };
        let dead_end = ask.dead_end();
        (picked, dead_end)
    };
    match picked {
        Some((device, room)) => {
            dispatch_one(
                ws_cmd_tx,
                event_tx,
                pending,
                requested_file_receipts,
                declined_file_ids,
                pending_ws_transfers,
                file_id,
                &device,
                &room,
            )
            .await;
        }
        None if announce_dead_end => {
            let (state, who) = dead_end;
            let _ = event_tx
                .send(NetworkEvent::FileAvailability {
                    file_id: file_id.to_string(),
                    state: state.to_string(),
                    peer_id: who,
                })
                .await;
        }
        None => {}
    }
}

/// `NodeCommand::RequestFile` for a file we hold a ROW for: upsert the pending ask
/// and dispatch it. A young in-flight request is left alone (this is the dedup for
/// Dart's liberal sweeps); a SETTLED ask is the user asking again, so it restarts.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn upsert_and_advance(
    ws_cmd_tx: &mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    server_states: &HashMap<String, ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    pending: &mut HashMap<String, PendingFileAsk>,
    requested_file_receipts: &mut HashMap<String, Instant>,
    declined_file_ids: &mut HashSet<String>,
    pending_ws_transfers: &HashMap<String, super::ws_stream_transfer::WsTransferState>,
    file_id: &str,
    context: FileAskContext,
    sender: String,
    prefer: Option<&str>,
    local_master: &str,
    local_device: &str,
) {
    let now = Instant::now();
    match pending.get_mut(file_id) {
        Some(ask) => {
            if ask
                .in_flight
                .as_ref()
                .is_some_and(|(_, at)| now.duration_since(*at) < Duration::from_secs(FILE_ASK_TIMEOUT_SECS))
            {
                return;
            }
            ask.in_flight = None;
            ask.context = context;
            ask.sender = sender;
            let exhausted = !ask.negatives.is_empty()
                || ask_candidates(ask, ws_room_peers, server_states, local_master, local_device)
                    .is_empty();
            if exhausted {
                ask.asked.clear();
                ask.negatives.clear();
            }
        }
        None => {
            pending.insert(
                file_id.to_string(),
                PendingFileAsk {
                    context,
                    sender,
                    asked: HashSet::new(),
                    in_flight: None,
                    negatives: Vec::new(),
                    first_asked_at: now,
                    last_asked_at: now,
                },
            );
            evict_overflow(pending);
        }
    }
    advance(
        ws_cmd_tx,
        ws_room_peers,
        server_states,
        event_tx,
        pending,
        requested_file_receipts,
        declined_file_ids,
        pending_ws_transfers,
        file_id,
        prefer,
        local_master,
        local_device,
        true,
    )
    .await;
}

/// `files.created_at` is written in MILLISECONDS by every send and receive path.
/// Normalise anyway: a value below the year-2001 millisecond mark can only be a
/// seconds stamp from an older row, and a comparison in the wrong unit never fires.
fn created_at_ms(created_at: i64) -> i64 {
    if created_at < 100_000_000_000 {
        created_at.saturating_mul(1000)
    } else {
        created_at
    }
}

/// Whether OUR OWN row for `file_id` is genuinely past the server's retention
/// window. The gate on the one store write a remote answer can cause: a member
/// cannot expire someone else's file, because our own settings and row must agree.
fn retention_expired_locally(
    file_id: &str,
    server_states: &HashMap<String, ServerState>,
    db_path: &str,
    db_passphrase: &str,
) -> bool {
    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else {
        return false;
    };
    let Ok(Some(meta)) = store.get_file_metadata(file_id) else {
        return false;
    };
    // DM files have no retention policy to be past.
    if meta.context_type != "channel" {
        return false;
    }
    let Some(server_id) = meta.context_id.split(':').next() else {
        return false;
    };
    let Some(state) = server_states.get(server_id) else {
        return false;
    };
    let policy = crate::vault::adaptive::retention_for_tier(
        crate::vault::content_store::StorageTier::Standard,
        &state.settings,
    );
    let Some(days) = crate::vault::adaptive::parse_retention_days(&policy) else {
        return false; // permanent
    };
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    created_at_ms(meta.created_at) < now_ms - (days as i64) * 86_400_000
}

/// Inbound `HavenMessage::FileUnavailable`: a holder we asked cannot serve.
///
/// The asked-set check is a HARD DROP, not a log line: a device this ask never
/// asked can neither steer the walk nor delete the ask.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_file_unavailable(
    ws_cmd_tx: &mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    server_states: &HashMap<String, ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    pending: &mut HashMap<String, PendingFileAsk>,
    requested_file_receipts: &mut HashMap<String, Instant>,
    declined_file_ids: &mut HashSet<String>,
    pending_ws_transfers: &HashMap<String, super::ws_stream_transfer::WsTransferState>,
    peer_str: &str,
    file_id: String,
    reason: String,
    local_master: &str,
    local_device: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    let Some(ask) = pending.get_mut(&file_id) else {
        return;
    };
    if !ask.asked.contains(peer_str) {
        return;
    }
    // Anything that is not the expiry claim is a plain miss.
    let reason = if reason == "expired" { "expired" } else { "gone" };
    ask.negatives.push((peer_str.to_string(), reason.to_string()));
    ask.in_flight = None;
    hollow_log!("[HOLLOW-FILE] {peer_str} cannot serve {file_id} ({reason})");

    if reason == "expired"
        && retention_expired_locally(&file_id, server_states, db_path, db_passphrase)
    {
        // Verified against OUR OWN settings and OUR OWN row: the retention
        // sweep would have marked this at its next tick anyway. A second store
        // open, and only on this rare verified path.
        let now_secs = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;
        let vault_dir = crate::identity::data_dir().unwrap_or_default().join("vault");
        if let Ok(cs) =
            crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir)
        {
            let _ = cs.mark_file_expired(&file_id, now_secs);
        }
        pending.remove(&file_id);
        let _ = event_tx
            .send(NetworkEvent::FileAvailability {
                file_id,
                state: "expired".to_string(),
                peer_id: super::resolver::resolve(peer_str),
            })
            .await;
        return;
    }

    // Not expired (or not ours to believe): rotate to the next holder.
    advance(
        ws_cmd_tx,
        ws_room_peers,
        server_states,
        event_tx,
        pending,
        requested_file_receipts,
        declined_file_ids,
        pending_ws_transfers,
        &file_id,
        None,
        local_master,
        local_device,
        true,
    )
    .await;
}

/// A holder appeared in a room (`WsEvent::PeerJoined`): ask it for anything
/// still pending that it could plausibly hold.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn retry_asks_for_peer(
    ws_cmd_tx: &mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    server_states: &HashMap<String, ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    pending: &mut HashMap<String, PendingFileAsk>,
    requested_file_receipts: &mut HashMap<String, Instant>,
    declined_file_ids: &mut HashSet<String>,
    pending_ws_transfers: &HashMap<String, super::ws_stream_transfer::WsTransferState>,
    room: &str,
    peer_id: &str,
    local_master: &str,
    local_device: &str,
) {
    if pending.is_empty() || peer_id == local_device || peer_id == local_master {
        return;
    }
    let joiner_master = super::resolver::resolve(peer_id);
    let ids: Vec<String> = pending
        .iter()
        .filter(|(_, a)| {
            a.in_flight.is_none()
                && a.asked.len() < MAX_FILE_ASK_CANDIDATES
                && !a.asked.contains(peer_id)
        })
        .filter(|(_, a)| match &a.context {
            // Either the counterparty came back, or one of our own siblings did.
            FileAskContext::Dm { peer } => {
                super::resolver::resolve(peer) == joiner_master || joiner_master == local_master
            }
            FileAskContext::Channel { server_id, .. } => server_id == room,
        })
        .map(|(f, _)| f.clone())
        .collect();
    if ids.is_empty() {
        return;
    }
    for file_id in sweep_order(pending, ids) {
        advance(
            ws_cmd_tx,
            ws_room_peers,
            server_states,
            event_tx,
            pending,
            requested_file_receipts,
            declined_file_ids,
            pending_ws_transfers,
            &file_id,
            Some(peer_id),
            local_master,
            local_device,
            false,
        )
        .await;
    }
}

/// The relay's authoritative roster for a room landed (`WsEvent::RoomMembers`).
/// This is what closes the boot-ordering race: after a reconnect the ask table
/// is full of entries whose holders were unreachable on the old socket, and
/// this is the first moment anybody is known to be reachable again.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn retry_asks_in_room(
    ws_cmd_tx: &mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    server_states: &HashMap<String, ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    pending: &mut HashMap<String, PendingFileAsk>,
    requested_file_receipts: &mut HashMap<String, Instant>,
    declined_file_ids: &mut HashSet<String>,
    pending_ws_transfers: &HashMap<String, super::ws_stream_transfer::WsTransferState>,
    room: &str,
    local_master: &str,
    local_device: &str,
) {
    if pending.is_empty() {
        return;
    }
    let ids: Vec<String> = pending
        .iter()
        .filter(|(_, a)| a.in_flight.is_none() && a.asked.len() < MAX_FILE_ASK_CANDIDATES)
        .filter(|(_, a)| match &a.context {
            FileAskContext::Dm { .. } => true,
            FileAskContext::Channel { server_id, .. } => server_id == room,
        })
        .filter(|(_, a)| {
            !ask_candidates(a, ws_room_peers, server_states, local_master, local_device).is_empty()
        })
        .map(|(f, _)| f.clone())
        .collect();
    if ids.is_empty() {
        return;
    }
    for file_id in sweep_order(pending, ids) {
        advance(
            ws_cmd_tx,
            ws_room_peers,
            server_states,
            event_tx,
            pending,
            requested_file_receipts,
            declined_file_ids,
            pending_ws_transfers,
            &file_id,
            None,
            local_master,
            local_device,
            false,
        )
        .await;
    }
}

/// Retry sweep: an ask that has gone quiet is a silent miss (a client predating
/// `FileUnavailable`, a row the holder never had, a dropped frame). Rotate it, and
/// when there is nobody left say so. Opens the store at most ONCE, and only when
/// something is actually stale.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn retry_stale_asks(
    ws_cmd_tx: &mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    server_states: &HashMap<String, ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    pending: &mut HashMap<String, PendingFileAsk>,
    requested_file_receipts: &mut HashMap<String, Instant>,
    declined_file_ids: &mut HashSet<String>,
    pending_ws_transfers: &HashMap<String, super::ws_stream_transfer::WsTransferState>,
    local_master: &str,
    local_device: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    if pending.is_empty() {
        return;
    }
    let now = Instant::now();
    let stale: Vec<String> = pending
        .iter()
        .filter(|(_, a)| {
            a.in_flight.as_ref().is_some_and(|(_, at)| {
                now.duration_since(*at) >= Duration::from_secs(FILE_ASK_TIMEOUT_SECS)
            })
        })
        .map(|(f, _)| f.clone())
        .collect();
    if stale.is_empty() {
        return;
    }
    let stale = sweep_order(pending, stale);
    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else {
        return;
    };
    let mut ready: Vec<String> = Vec::new();
    for file_id in stale {
        // The bytes may have landed by another route (a push, a sibling
        // backfill) — retire the ask instead of rotating it.
        let complete = store
            .get_file_metadata(&file_id)
            .ok()
            .flatten()
            .is_some_and(|m| m.completed_at.is_some());
        if complete {
            pending.remove(&file_id);
            continue;
        }
        ready.push(file_id);
    }
    drop(store);
    for file_id in ready {
        if let Some(ask) = pending.get_mut(&file_id) {
            ask.in_flight = None;
        }
        advance(
            ws_cmd_tx,
            ws_room_peers,
            server_states,
            event_tx,
            pending,
            requested_file_receipts,
            declined_file_ids,
            pending_ws_transfers,
            &file_id,
            None,
            local_master,
            local_device,
            true,
        )
        .await;
    }
}

/// A new socket means a fresh set of holders: keep every ask, drop only what the
/// dead connection told us. `last_asked_at` is stamped stale so the next roster
/// snapshot dispatches at once rather than waiting out a dead socket's window.
pub(crate) fn reset_on_disconnect(pending: &mut HashMap<String, PendingFileAsk>) {
    let stale_now = Instant::now()
        .checked_sub(Duration::from_secs(FILE_ASK_TIMEOUT_SECS))
        .unwrap_or_else(Instant::now);
    for ask in pending.values_mut() {
        ask.asked.clear();
        ask.negatives.clear();
        ask.in_flight = None;
        ask.last_asked_at = stale_now;
    }
}

/// The answering `FileHeader` arrived: this ask is over. Dart clears the card's
/// availability state on the progress/complete events that follow.
pub(crate) fn retire(pending: &mut HashMap<String, PendingFileAsk>, file_id: &str) {
    pending.remove(file_id);
}

/// "Stop waiting for this file": drop the queued ask so nothing retries it, and
/// drop its explicit-pull receipt with it.
///
/// The receipt goes on purpose. It is what makes an answering header bypass the
/// size cap and the auto-download gate, and a withdrawn request has no business
/// bypassing either. `declined_file_ids` is deliberately untouched: it records
/// what the auto-download SETTING did to a push, not what the user did to a request.
pub(crate) fn cancel(
    pending: &mut HashMap<String, PendingFileAsk>,
    requested_file_receipts: &mut HashMap<String, Instant>,
    file_id: &str,
) {
    pending.remove(file_id);
    requested_file_receipts.remove(file_id);
}
