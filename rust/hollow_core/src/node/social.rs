use std::collections::HashMap;

use base64::Engine;
use tokio::sync::mpsc;

use crate::crdt::server_state::ServerState;
use crate::crypto::MlsManager;
use super::crypto_handler::{
    persist_crypto_state, send_encrypted_text_to_peer, send_mls_broadcast,
    send_message_to_peer, send_message_to_peer_in_room,
};
use super::types::*;

// -- Async friending (a stranger who is offline, requested by someone who may
//    also be offline) ------------------------------------------------------

/// Plaintext of the ONE Olm pre-key message the accepter sends so the requester
/// ends up with an inbound session having never been online at the same moment.
/// A leading NUL keeps it out of anything a person can type, and the `Encrypted`
/// receive arm matches it BEFORE the `MessageEnvelope` parse, so it never reaches
/// the legacy raw-text fallback that would render it as a bubble.
pub(crate) const FRIEND_HANDSHAKE_SENTINEL: &str = "\u{0}hollow-friend-handshake";

/// Ceiling on outstanding pending-OUTGOING friend requests.
///
/// Each one holds a minted one-time key whose private half lives in the Olm
/// account, and that account keeps a bounded number of them. Minting without a
/// ceiling silently rotates the oldest out from under bundles already sitting in
/// a relay mailbox, so a carried bundle would verify and then build a session the
/// requester could not decrypt. Refusing at the cap is the honest failure.
pub(crate) const MAX_OUTSTANDING_FRIEND_REQUESTS: usize = 32;

/// The carried bundle plus the roster that authenticates it, persisted
/// between "the request arrived" and "the human clicked Accept" (which may be a
/// reboot apart), and between "we sent a request" and the next re-deposit.
#[derive(serde::Serialize, serde::Deserialize, Clone, Debug)]
pub(crate) struct CarriedRequestRecord {
    #[serde(default)]
    pub bundle: CarriedBundle,
    #[serde(default)]
    pub device_list: crate::identity::roster::Roster,
    /// True when the request reached us while the requester was actually in a
    /// room with us, rather than out of the relay mailbox.
    ///
    /// The glare gate, and load-bearing. Bootstrapping a session from the carried
    /// bundle is a THIRD way to establish Olm, and running it while a live path is
    /// also running leaves the two sides holding halves of two different sessions.
    /// So the carried path serves only the case the live path CANNOT.
    #[serde(default)]
    pub live_at_receipt: bool,
}

/// `app_settings` key for the bundle WE minted for `target_master`. Reused for
/// every re-send and mailbox re-deposit: minting per send would burn a one-time
/// key and hand the target a bundle whose private half we had already rotated.
fn out_bundle_key(target_master: &str) -> String {
    format!("friendreq_out:{target_master}")
}

/// `app_settings` key for the VERIFIED bundle a requester sent US, read at accept
/// time and never deleted, so a second idempotent accept still finds it. The
/// `has_session` guard stops it building a session on an already-spent key.
pub(crate) fn in_bundle_key(requester_master: &str) -> String {
    format!("friendreq_in:{requester_master}")
}

/// KV key prefix of the removal tombstones.
const REMOVED_PREFIX: &str = "friend_removed:";

/// KV key of the removal tombstone for `master`: when a friendship with them last
/// ended, in ms. Never cleared; a re-add is newer than it. A legacy "1" bounds nothing.
fn removed_key(master: &str) -> String {
    format!("{REMOVED_PREFIX}{master}")
}

/// When a friendship with `master` last ended, 0 if never.
fn removed_at(store: &crate::storage::MessageStore, master: &str) -> i64 {
    store.load_setting(&removed_key(master)).ok().flatten()
        .and_then(|v| v.parse::<i64>().ok())
        .unwrap_or(0)
}

/// Record that a friendship with `master` ended at `at_ms`; a late older removal
/// never moves the mark back.
pub(crate) fn note_removal(store: &crate::storage::MessageStore, master: &str, at_ms: i64) {
    let at = at_ms.max(removed_at(store, master));
    let _ = store.save_setting(&removed_key(master), &at.to_string());
}

/// Whether a request or friendship with `master` stamped `requested_at` was made
/// before the friendship last ended, so it belongs to the one that ended.
pub(crate) fn older_than_removal(store: &crate::storage::MessageStore, master: &str, requested_at: i64) -> bool {
    requested_at.saturating_add(super::frame_auth::LIVE_SKEW_MS) < removed_at(store, master)
}

/// [`older_than_removal`] for a friend request from `sender`, logged. Out of line so
/// the swarm's request handler, near the worker stack's limit, holds no store.
pub(crate) fn request_predates_removal(
    sender: &str,
    master: &str,
    requested_at: i64,
    db_path: &str,
    db_passphrase: &str,
) -> bool {
    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else { return false };
    let stale = older_than_removal(&store, master, requested_at);
    if stale {
        hollow_log!("[HOLLOW-SECURITY] Ignoring a FriendRequest from {sender} made before the last removal");
    }
    stale
}

/// Most removals one sibling list carries or is read for: the newest, the ones a device
/// that was away can still be behind on.
const MAX_SHARED_REMOVALS: usize = 256;

/// The friendships we ended, newest first, as our own devices tell each other. A legacy
/// tombstone holds no time and is left out.
pub(crate) fn friend_removals(store: &crate::storage::MessageStore) -> Vec<FriendRemoval> {
    let mut out: Vec<FriendRemoval> = store
        .load_settings_with_prefix(REMOVED_PREFIX)
        .unwrap_or_default()
        .into_iter()
        .filter_map(|(key, at)| {
            let peer_id = key.strip_prefix(REMOVED_PREFIX)?.to_string();
            let at = at.parse::<i64>().ok().filter(|at| *at > 1)?;
            Some(FriendRemoval { peer_id, at })
        })
        .collect();
    out.sort_unstable_by_key(|r| std::cmp::Reverse(r.at));
    out.truncate(MAX_SHARED_REMOVALS);
    out
}

/// Tell our own online devices that the friendship with `master` ended at `at`. One that
/// is away hears it in our friend list once it is back.
pub(crate) fn share_removal_with_siblings(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    local_peer_str: &str,
    device_peer_id: &str,
    master: &str,
    at: i64,
) {
    let msg = HavenMessage::FriendListSync {
        friends: Vec::new(),
        removed: vec![FriendRemoval { peer_id: master.to_string(), at }],
    };
    super::olm_lane::carry_to_own_siblings(
        ws_cmd_tx, ws_room_peers, local_peer_str, device_peer_id, &msg, super::olm_lane::NoSession::Queue,
    );
}

/// Take the removals one of our own devices shared, each held to `ceiling`: it raises our
/// removal mark and ends a friendship or request of ours made before it, so a re-add
/// since outlives a late copy. Returns the friends dropped. Out of line so the swarm's
/// request handler holds no store.
pub(crate) fn take_sibling_removals(
    removed: &[FriendRemoval],
    ceiling: i64,
    db_path: &str,
    db_passphrase: &str,
) -> Vec<String> {
    let mut dropped = Vec::new();
    if removed.is_empty() {
        return dropped;
    }
    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else { return dropped };
    for removal in removed.iter().take(MAX_SHARED_REMOVALS) {
        if removal.at <= 1 {
            continue;
        }
        let master = super::resolver::resolve(&removal.peer_id);
        let at = removal.at.min(ceiling);
        note_removal(&store, &master, at);
        match store.get_friend_row(&master) {
            Ok(Some((status, _, since))) if status == "accepted" || status == "pending" => {
                if since >= at {
                    hollow_log!("[HOLLOW-FRIENDS] Kept {master}: the friendship is newer than a sibling's removal");
                    continue;
                }
                if store.remove_friend(&master).is_ok() {
                    hollow_log!("[HOLLOW-FRIENDS] Friendship with {master} ended on a sibling");
                    dropped.push(master);
                }
            }
            _ => {}
        }
    }
    dropped
}

/// Build the `FriendRequest` for `target_master`, carrying the Olm prekey bundle
/// that lets the target establish a session at ACCEPT time with no co-presence.
/// The bundle is minted ONCE per target and cached, so every later send reuses
/// it, the target dedups on its friends row and the one-time key stays valid.
#[allow(clippy::too_many_arguments)]
pub(crate) fn build_friend_request(
    olm: &mut crate::crypto::OlmManager,
    crypto_store: &crate::crypto::CryptoStore,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    target_master: &str,
    requested_at: i64,
    db_path: &str,
    db_passphrase: &str,
) -> HavenMessage {
    let device_list = super::roster_book::own_roster(&master_keypair.peer_id(), db_path, db_passphrase);
    let key = out_bundle_key(target_master);
    let store = crate::storage::MessageStore::open(db_path, db_passphrase).ok();

    // Reuse a cached bundle while it is still inside the carried freshness rule.
    let cached: Option<CarriedBundle> = store
        .as_ref()
        .and_then(|st| st.load_setting(&key).ok().flatten())
        .and_then(|json| serde_json::from_str::<CarriedRequestRecord>(&json).ok())
        .map(|rec| rec.bundle)
        .filter(|b| {
            let age = super::crypto_handler::key_exchange_now() - b.ts;
            !b.one_time_key.is_empty()
                && b.to_master == target_master
                && age <= super::crypto_handler::MAX_CARRIED_BUNDLE_AGE_SECS
        });

    let bundle = match cached {
        Some(b) => b,
        None => {
            let one_time_key = olm.generate_one_time_key();
            let identity_key = olm.identity_key_base64();
            // The PRIVATE half of that one-time key lives in the account pickle.
            // Persist before the bundle can leave, or a restart between mint and
            // accept strands the target with a key we can no longer answer.
            persist_crypto_state(olm, crypto_store, target_master);
            let b = super::crypto_handler::signed_carried_bundle(
                device_keypair, device_peer_id, target_master, identity_key, one_time_key,
            );
            if let (Some(st), Some(dl)) = (store.as_ref(), device_list.as_ref()) {
                let rec = CarriedRequestRecord {
                    bundle: b.clone(),
                    device_list: dl.clone(),
                    live_at_receipt: false,
                };
                if let Ok(json) = serde_json::to_string(&rec) {
                    let _ = st.save_setting(&key, &json);
                }
            }
            b
        }
    };

    // Our name and avatar sealed to the target, so its incoming card shows who is
    // asking while the relay carrying the request cannot read it (A28).
    let sealed_card = super::profile_card::own_card(master_keypair, db_path, db_passphrase)
        .and_then(|card| super::profile_card::seal_for(&card, target_master, requested_at));

    HavenMessage::FriendRequest {
        requested_at,
        carried_bundle: Some(bundle),
        device_list,
        sealed_card,
    }
}

/// How many pending-OUTGOING friend requests are on the books right now.
fn outstanding_outgoing_requests(db_path: &str, db_passphrase: &str) -> usize {
    crate::storage::MessageStore::open(db_path, db_passphrase)
        .ok()
        .and_then(|st| st.load_friends(Some("pending")).ok())
        .map(|rows| {
            rows.iter()
                .filter(|(_, _, direction, _, _)| direction == "outgoing")
                .count()
        })
        .unwrap_or(0)
}

/// Deposit a friend request into `inbox:{target_master}` so the relay buffers it
/// under the MASTER, where only a device that PROVES it owns that inbox can
/// collect it. This is the leg that makes a request survive both people being
/// offline: a plain targeted send to a master reaches no socket and is dropped.
///
/// Joins the inbox first (the relay gates every frame on SENDER room membership)
/// and STAYS while the request is pending, because the target's device appearing
/// in that room is what drains the live queue.
pub(crate) fn deposit_friend_request_to_inbox(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    target_master: &str,
    msg: &HavenMessage,
) {
    let inbox_room = format!("inbox:{target_master}");
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
        room_code: inbox_room.clone(),
    });
    send_message_to_peer_in_room(ws_cmd_tx, &inbox_room, target_master, msg.clone());
}

/// Our card sealed to a requester and left in its mailbox: what a pending requester
/// sees of us (A28) while we share no room with it.
pub(crate) fn deposit_own_card(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    requester_master: &str,
    requested_at: i64,
    db_path: &str,
    db_passphrase: &str,
) {
    let Some(sealed_card) = super::profile_card::own_card(master_keypair, db_path, db_passphrase)
        .and_then(|card| super::profile_card::seal_for(&card, requester_master, requested_at))
    else {
        return;
    };
    let inbox_room = format!("inbox:{requester_master}");
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom { room_code: inbox_room.clone() });
    send_message_to_peer_in_room(
        ws_cmd_tx, &inbox_room, requester_master, HavenMessage::FriendCard { requested_at, sealed_card },
    );
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom { room_code: inbox_room });
}

/// Keep the card a target sealed back to a request of ours. Only the pair key of a
/// pending outgoing row stamped `requested_at` opens it, so it speaks for that target
/// alone. Out of line so the swarm's request handler holds no store.
pub(crate) async fn take_friend_card(
    event_tx: &mpsc::Sender<NetworkEvent>,
    local_master: &str,
    requested_at: i64,
    sealed_card: &super::types::SealedCard,
    db_path: &str,
    db_passphrase: &str,
) {
    let rows = crate::storage::MessageStore::open(db_path, db_passphrase)
        .and_then(|st| st.load_friends(Some("pending")))
        .unwrap_or_default();
    let card = rows
        .iter()
        .filter(|(_, _, direction, stamp, _)| direction == "outgoing" && *stamp == requested_at)
        .find_map(|(master, ..)| super::profile_card::open_from(sealed_card, local_master, master, requested_at));
    if let Some(card) = card
        && super::profile_card::store_card(&card, None, db_path, db_passphrase)
    {
        let _ = event_tx.send(NetworkEvent::ProfileUpdated { peer_id: card.master }).await;
    }
}

/// Deliver a decline to the requester by every leg that can reach it: the live
/// fan to its ONLINE devices, AND a deposit into the requester's own master-keyed
/// mailbox `inbox:{requester_master}`, which the relay replays (TTL-only) to
/// every device that proves it owns that master on its next boot.
///
/// The live fan alone was the whole bug: a decline of an ASYNC request answers
/// somebody who is by definition not here, so the reject reached nobody, the
/// requester's row stayed "pending outgoing" forever, and it re-deposited the
/// same request on every reconnect. The decline travels the road the request did.
///
/// Deposit ALWAYS, even when a live device target exists: a live send can race
/// the target's disconnect, and the mailbox copy is a no-op on a requester that
/// has already cleaned up.
///
/// CARRIES OUR OWN master-signed device list, for the same reason the request
/// does: the requester has never been online with us, so `resolve()` yields our
/// raw DEVICE id while its friend row is MASTER-keyed, and the reject is dropped
/// with `row None`. The list makes attribution cryptographic instead.
///
/// Join, send, then LEAVE: we are a SENDER in their inbox, not an owner, and the
/// three WS commands are ordered on one channel, so the leave lands last.
pub(crate) fn send_friend_reject(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    peer_id_str: &str,
    master: &str,
    requested_at: i64,
    device_list: Option<crate::identity::roster::Roster>,
) {
    let msg = HavenMessage::FriendReject { requested_at, device_list };

    // Live leg: the row (and often the UI key) is the MASTER, which no socket
    // authenticates as, so a raw send to it is silently dropped — fan to the
    // requester's concrete online DEVICES.
    for t in &friend_device_targets(ws_room_peers, peer_id_str, master) {
        send_message_to_peer(ws_cmd_tx, ws_room_peers, t, msg.clone());
    }

    // Mailbox leg: the one that reaches a requester who is simply not here.
    let inbox_room = format!("inbox:{master}");
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
        room_code: inbox_room.clone(),
    });
    send_message_to_peer_in_room(ws_cmd_tx, &inbox_room, master, msg);
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom {
        room_code: inbox_room,
    });
    hollow_log!("[HOLLOW-FRIENDS] Sent friend reject for request {requested_at} to {master} (live devices + inbox:{master})");
}

/// Builds the accept for the request stamped `requested_at` (0 = no row, sent bare),
/// carrying our own signed device list.
pub(crate) fn friend_accept_msg(requested_at: i64, device_list: Option<crate::identity::roster::Roster>) -> HavenMessage {
    HavenMessage::FriendAccept {
        requested_at: (requested_at > 0).then_some(requested_at),
        device_list,
    }
}

/// Sends an accept to `device` inside the deterministic DM room. A copy for a device
/// that is not there yet parks under that room at the relay, never under a room the
/// device already left, where it would replay on an unrelated later join.
#[allow(clippy::too_many_arguments)]
pub(crate) fn send_friend_accept(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    local_peer_str: &str,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    master: &str,
    device: &str,
    requested_at: i64,
    db_path: &str,
    db_passphrase: &str,
) {
    let dm_room = dm_room_code(local_peer_str, master);
    let list = super::roster_book::own_roster(&master_keypair.peer_id(), db_path, db_passphrase);
    send_message_to_peer_in_room(ws_cmd_tx, &dm_room, device, friend_accept_msg(requested_at, list));
}

/// Tell our own online devices that `master` is now an accepted friend. An accept
/// reaches only the device that sent the request, and a sibling no longer takes a
/// row-less accept on its own (L1).
pub(crate) fn share_friend_with_siblings(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    local_peer_str: &str,
    device_peer_id: &str,
    master: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    let Some((status, direction, requested_at)) = crate::storage::MessageStore::open(db_path, db_passphrase)
        .ok()
        .and_then(|st| st.get_friend_row(master).ok().flatten())
    else {
        return;
    };
    let msg = HavenMessage::FriendListSync {
        friends: vec![FriendListEntry { peer_id: master.to_string(), status, direction, requested_at }],
        removed: Vec::new(),
    };
    super::olm_lane::carry_to_own_siblings(
        ws_cmd_tx, ws_room_peers, local_peer_str, device_peer_id, &msg, super::olm_lane::NoSession::Queue,
    );
}

/// Whether a friend row keeps us in the DM room with `master`: an accepted friendship
/// we have not blocked, or our own request waiting for its answer. The relay shows a
/// room's members to each other, so a request we have not accepted, a decline or a
/// removal would show our devices coming and going to the other side.
pub(crate) fn holds_dm_room(master: &str, status: &str, direction: &str) -> bool {
    !super::blocklist::is_blocked(master)
        && (status == "accepted" || (status == "pending" && direction == "outgoing"))
}

/// Every master whose DM room [`holds_dm_room`] keeps us in.
pub(crate) fn dm_room_masters(store: &crate::storage::MessageStore) -> Vec<String> {
    store
        .load_friends(None)
        .unwrap_or_default()
        .into_iter()
        .filter(|(master, status, direction, ..)| holds_dm_room(master, status, direction))
        .map(|(master, ..)| master)
        .collect()
}

/// Leave the DM room with `master` once nothing keeps us there.
pub(crate) fn leave_dm_room(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    local_master: &str,
    master: &str,
) {
    // Our own pair room is the roster room every device of ours sits in.
    if super::resolver::same_identity(local_master, master) {
        return;
    }
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom {
        room_code: dm_room_code(local_master, master),
    });
}

/// Act on a block or unblock of `master` the FFI just stored: leave the DM room and
/// drop the DMs still waiting to be resent, or rejoin a room the row holds again.
pub(crate) fn handle_block_changed(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    local_master: &str,
    master: &str,
    blocked: bool,
    db_path: &str,
    db_passphrase: &str,
) {
    let master = super::resolver::resolve(master);
    if blocked {
        leave_dm_room(ws_cmd_tx, local_master, &master);
        super::message_ops::drop_blocked_queues(pending_messages);
        return;
    }
    let holds = crate::storage::MessageStore::open(db_path, db_passphrase)
        .ok()
        .and_then(|st| st.get_friend_row(&master).ok().flatten())
        .is_some_and(|(status, direction, _)| holds_dm_room(&master, &status, &direction));
    if holds && !super::resolver::same_identity(local_master, &master) {
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
            room_code: dm_room_code(local_master, &master),
        });
    }
}

/// True when `master` is an accepted friend on disk. A queued accept for anyone else
/// outlived a removal (a sibling removed them, or the queue was seeded before it).
pub(crate) fn holds_accepted_friend(db_path: &str, db_passphrase: &str, master: &str) -> bool {
    crate::storage::MessageStore::open(db_path, db_passphrase)
        .ok()
        .and_then(|st| st.get_friend_status(master).ok().flatten())
        .as_deref()
        == Some("accepted")
}

/// The concrete, ONLINE device peer_ids to target when we want to reach a friend
/// identity: a bare master id authenticates as no socket, so a send addressed to
/// it is dropped. Sources, deduped: the literal `original` id, every
/// resolver-known device of `master`, and every peer in a SHARED ROOM that
/// resolves to `master` (load-bearing before we hold their device list). Only
/// ids actually reachable in a room we know are returned.
pub(crate) fn friend_device_targets(
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    original: &str,
    master: &str,
) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    // EXACT room membership, not identity-wide `peer_is_reachable`: this returns
    // socket-addressable DEVICE ids for a raw SendDirect, and an identity-wide
    // check would admit the bare MASTER, whose sends are silently dropped.
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
    olm: &mut crate::crypto::OlmManager,
    crypto_store: &crate::crypto::CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    pending_friend_requests: &mut HashMap<String, i64>,
    pending_friend_removals: &mut std::collections::HashSet<String>,
    local_peer_str: &str,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
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

    // Outstanding-request ceiling. Every pending outgoing request holds a minted
    // one-time key from a bounded supply, and past the cap minting rotates keys out
    // from under bundles already sitting in a relay mailbox. An already-pending
    // target is exempt: re-requesting reuses its cached bundle and mints nothing.
    {
        let already_pending = crate::storage::MessageStore::open(db_path, db_passphrase)
            .ok()
            .and_then(|st| {
                st.get_friend_status_direction(&super::resolver::resolve(&peer_id_str))
                    .ok()
                    .flatten()
            })
            .map(|(status, dir)| status == "pending" && dir == "outgoing")
            .unwrap_or(false);
        if !already_pending
            && outstanding_outgoing_requests(db_path, db_passphrase)
                >= MAX_OUTSTANDING_FRIEND_REQUESTS
        {
            hollow_log!(
                "[HOLLOW-FRIENDS] Refused friend request to {peer_id_str}: {} outstanding (cap {MAX_OUTSTANDING_FRIEND_REQUESTS})",
                outstanding_outgoing_requests(db_path, db_passphrase)
            );
            let _ = event_tx.send(NetworkEvent::Error {
                message: format!(
                    "You have {MAX_OUTSTANDING_FRIEND_REQUESTS} friend requests still waiting for a reply. Cancel one before sending another."
                ),
            }).await;
            return;
        }
    }

    hollow_log!("[HOLLOW-FRIENDS] Sending friend request to {peer_id_str}");

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    // CANCEL any pending REMOVAL for this person: re-adding a friend you just
    // removed must not also fire the queued FriendRemove, or both drains fire on
    // the target's reconnect and the friendship ping-pongs.
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

    // Register the DM room code immediately so signaling can help discover the peer
    // before they accept. Use the target's MASTER so we join the SAME pure room the
    // target will; a nickname-resolved device id would diverge the room.
    let local_peer = local_peer_str.to_string();
    let room = dm_room_code(&local_peer, &master);
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
        room_code: room,
    });

    // Join the target's inbox temporarily, to deliver the request.
    let inbox_room = format!("inbox:{}", peer_id_str);
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
        room_code: inbox_room.clone(),
    });

    // Try to send immediately if the peer has an online DEVICE. The send must
    // target concrete devices: `peer_id_str` may resolve to a bare MASTER, which no
    // socket authenticates as, so a direct send is silently dropped AND would skip
    // the queue below, losing the request. ONE message serves every leg (live send,
    // mailbox deposit, later re-sends): it carries our Olm prekey bundle and
    // master-signed device list, which is what lets the target accept while we are gone.
    let request_msg = build_friend_request(
        olm, crypto_store, master_keypair, device_keypair, device_peer_id,
        &master, now, db_path, db_passphrase,
    );

    let targets = friend_device_targets(&ws_room_peers, &peer_id_str, &master);
    if !targets.is_empty() {
        for t in &targets {
            send_message_to_peer(
                &ws_cmd_tx, &ws_room_peers,
                t, request_msg.clone(),
            );
        }
        // We only joined the TARGET's inbox to DELIVER the request, so leave now rather
        // than linger in their inbox set. WS commands are ordered on one channel, so
        // this leave is processed AFTER the SendDirect above, and the accept comes back
        // via the shared DM room, not the inbox.
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom {
            room_code: inbox_room.clone(),
        });
    } else {
        // Peer not in any WS room yet: queue the request AND deposit it into the
        // target's master-keyed mailbox. The queue alone only ever fired while both
        // people were online at once, because a targeted send to a master reaches
        // nobody. The deposit is buffered by the relay under the master and collected
        // on the target's next boot, when it joins its inbox with an ownership proof.
        pending_friend_requests.insert(peer_id_str.clone(), now);
        deposit_friend_request_to_inbox(ws_cmd_tx, &master, &request_msg);
        hollow_log!("[HOLLOW-FRIENDS] Peer {peer_id_str} not reachable yet, deposited friend request in inbox:{master} and queued it");
    }

    let _ = event_tx.send(NetworkEvent::FriendRequestReceived {
        peer_id: peer_id_str,
    }).await;
}

/// Handle `NodeCommand::AcceptFriendRequest`.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_accept_friend_request(
    olm: &mut crate::crypto::OlmManager,
    crypto_store: &crate::crypto::CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server_states: &HashMap<String, ServerState>,
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

    // Update to accepted, keyed by the friend's MASTER. The incoming peer_id may be
    // a DEVICE id, but friendships key on the master like presence, DMs and
    // profiles, so resolve here: otherwise the row stays stranded under the device
    // id until a device-list ingest re-keys it, which never happens if that ingest
    // already ran. Also migrate a pre-existing pending row under the device id.
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
    // The accept names the request it answers; `save_friend` freezes that stamp on
    // the row, so it is read back after the write.
    let mut answered_at = 0i64;
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            if master != peer_id_str {
                let _ = store.migrate_friend_to_master(&peer_id_str, &master);
            }
            let _ = store.save_friend(&master, "accepted", "", now);
            answered_at = store
                .get_friend_row(&master)
                .ok()
                .flatten()
                .map(|(_, _, t)| t)
                .unwrap_or(0);
        }
    }
    share_friend_with_siblings(
        ws_cmd_tx, ws_room_peers, local_peer_str, device_peer_id, &master, db_path, db_passphrase,
    );

    // Send acceptance. The send must target a DEVICE, since the bare master
    // authenticates as no socket. The target set comes from the original id, every
    // resolver-known device of the master, AND every peer CURRENTLY IN A SHARED
    // ROOM that resolves to it; that last source is what works when we do not yet
    // hold the friend's device list. Join the shared DM room BEFORE anything is
    // addressed into it: the relay gates every frame on SENDER room membership, so
    // an accept sent from outside the room is dropped rather than buffered.
    let dm_room = dm_room_code(local_peer_str, &master);
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
        room_code: dm_room.clone(),
    });
    let own_list = super::roster_book::own_roster(&master_keypair.peer_id(), db_path, db_passphrase);

    // -- Async friending: establish the Olm session from the CARRIED bundle. --
    //
    // The leg that makes acceptance work with zero overlap. The requester shipped a
    // prekey bundle inside the request; we build the outbound half now and send ONE
    // pre-key establisher, which the relay buffers, so the requester wakes with an
    // inbound session. Failure is never fatal: it falls back to lazy co-presence.
    {
        let stored: Option<CarriedRequestRecord> =
            crate::storage::MessageStore::open(db_path, db_passphrase)
                .ok()
                .and_then(|st| st.load_setting(&in_bundle_key(&master)).ok().flatten())
                .and_then(|json| serde_json::from_str::<CarriedRequestRecord>(&json).ok());

        if let Some(rec) = stored {
            let requester_device =
                super::crypto_handler::carried_bundle_sender_device(&rec.bundle);
            // Re-verify at USE time, not just at receive time: the row has been on
            // disk since the request arrived, and the freshness window may have
            // lapsed while it sat there.
            let ok = super::crypto_handler::verify_carried_bundle(
                local_peer_str, &rec.device_list, &rec.bundle, db_path, db_passphrase,
            );
            match (ok, requester_device) {
                (true, Some(device)) => {
                    // ONLY when the live path cannot serve this: the request came
                    // out of the mailbox, the requester is in no room with us now,
                    // and we hold no session with it. Any of those being false means
                    // the live key exchange is already running, and a second session
                    // from the carried bundle is Olm glare: two halves, no decrypts.
                    let reachable = super::crypto_handler::ws_room_for_peer(
                        ws_room_peers, &device,
                    ).is_some();
                    if reachable || rec.live_at_receipt {
                        hollow_log!("[HOLLOW-FRIENDS] Requester {device} is present — leaving the session to the live key exchange");
                    } else {
                        // Teach the requester OUR device -> master mapping FIRST,
                        // over the same buffered room. It learned nothing about us
                        // from its own request, and without this it wakes holding a
                        // session with a device id it cannot attribute, so its own
                        // reply targets nobody.
                        send_own_profile_to_peer_in_room(
                            ws_cmd_tx, ws_room_peers, server_states, local_peer_str, master_keypair, &device, &dm_room, is_invisible,
                            db_path, db_passphrase,
                        );
                        // The accept itself, addressed into the DETERMINISTIC DM
                        // room so the relay buffers it for an absent requester (a
                        // first-match room lookup finds nothing when they are gone).
                        send_message_to_peer_in_room(
                            ws_cmd_tx, &dm_room, &device, friend_accept_msg(answered_at, own_list.clone()),
                        );
                        if olm.has_session(&device) {
                            hollow_log!("[HOLLOW-FRIENDS] Carried bundle from {device}: session already exists, skipping bootstrap");
                        } else {
                            match olm.create_outbound_session(
                                &device, &rec.bundle.identity_key, &rec.bundle.one_time_key,
                            ) {
                                Ok(()) => {
                                    persist_crypto_state(olm, crypto_store, &device);
                                    hollow_log!("[HOLLOW-FRIENDS] Built outbound Olm session with {device} from the carried bundle");
                                    // ONE pre-key establisher. Control-only: the
                                    // sentinel is matched before the envelope parse
                                    // on the far side, so it never becomes a bubble.
                                    send_encrypted_text_to_peer(
                                        olm, crypto_store, &device, dm_room.clone(),
                                        FRIEND_HANDSHAKE_SENTINEL, event_tx, ws_cmd_tx,
                                    ).await;
                                }
                                Err(e) => {
                                    hollow_log!("[HOLLOW-FRIENDS] Carried bundle from {device} unusable ({e}) — falling back to lazy key exchange");
                                }
                            }
                        }
                    }
                }
                _ => {
                    hollow_log!("[HOLLOW-SECURITY] REJECTED carried bundle from {master} at accept time — falling back to lazy key exchange");
                }
            }
        }
    }

    // Into the DM room, never the first room the device is listed in: a copy sent to
    // a room the device already left parks at the relay until its next join of THAT
    // room, which can be a re-add long after a removal.
    let targets = friend_device_targets(&ws_room_peers, &peer_id_str, &master);
    for t in &targets {
        send_message_to_peer_in_room(ws_cmd_tx, &dm_room, t, friend_accept_msg(answered_at, own_list.clone()));
    }
    // ALWAYS queue the acceptance for redelivery, keyed by the requester's MASTER.
    // The requester's device can race the accept: it delivers the request, leaves
    // our inbox, and its DM-room join may not have populated `ws_room_peers` yet,
    // so `friend_device_targets` can be EMPTY here. Without a queue the accept is
    // lost and their row stays "pending outgoing" forever; the re-send is idempotent.
    pending_friend_accepts.insert(master.clone(), answered_at);
    hollow_log!(
        "[HOLLOW-FRIENDS] Accepted {master}: sent FriendAccept to {} device(s) now, queued for redelivery",
        targets.len()
    );

    // The DM room (`dm_room_code`, pure f(masters) so both sides compute the same
    // one) was joined above, before anything was addressed into it.

    // Push OUR profile and device list to the friend now, over the inbox or DM room
    // where they are reachable, so they learn our device-to-master mapping. We are
    // the ACCEPTER: if we never sent our own request, no FriendRequest handler on
    // their side pushed our list, so this is the path that delivers it.
    for t in &friend_device_targets(&ws_room_peers, &peer_id_str, &master) {
        send_own_profile_to_peer(
            &ws_cmd_tx, &ws_room_peers, server_states,
            local_peer_str, master_keypair, t,
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
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    peer_id_str: String,
    pending_friend_requests: &mut HashMap<String, i64>,
    pending_friend_accepts: &mut HashMap<String, i64>,
    db_path: &str,
    db_passphrase: &str,
) {
    // The UI may pass a DEVICE id (a pending incoming request is keyed under the
    // sender's device id until the device-list ingest re-keys it) or a master. Fold
    // any device-stranded row up to the master, then tombstone the master row as
    // "declined", so the decline sticks whichever key the request lives under.
    let master = super::resolver::resolve(&peer_id_str);
    hollow_log!("[HOLLOW-FRIENDS] Rejecting friend request from {peer_id_str} (master {master})");

    // CANCEL any pending outgoing REQUEST and queued ACCEPT for this person, since
    // rejecting supersedes them. In the MUTUAL case our own outgoing request was
    // still queued, and without this the request drain re-sends it after the reject,
    // the peer accepts, and the pair becomes friends behind the user's back.
    pending_friend_requests.remove(&master);
    pending_friend_requests.remove(&peer_id_str);
    pending_friend_accepts.remove(&master);
    pending_friend_accepts.remove(&peer_id_str);

    // Write a STICKY "declined" tombstone instead of deleting the row. The relay
    // inbox mailbox is TTL-only, so a DELETED row let the buffered request
    // re-deliver on every reboot and resurface in Incoming for the whole TTL. The
    // tombstone is what the anti-downgrade guard reads, and it PRESERVES the
    // original `requested_at` so that guard's freshness check works: a genuinely
    // NEWER request is strictly greater and still shows, and a re-add overwrites.
    let mut original_requested_at: i64 = 0;
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            // Fold any device-stranded row up to the master first (parity with the
            // accept/removal paths) so the tombstone lands on the one master key.
            if master != peer_id_str {
                let _ = store.migrate_friend_to_master(&peer_id_str, &master);
            }
            original_requested_at = store
                .get_friend_row(&master)
                .ok()
                .flatten()
                .map(|(_, _, requested_at)| requested_at)
                .unwrap_or(0);
            let _ = store.save_friend(&master, "declined", "", original_requested_at);
        }
    }

    // Answer the requester on EVERY leg that can reach it: the live fan to its
    // online devices AND a deposit into its own master-keyed mailbox. A
    // best-effort live send left an offline requester "pending outgoing" forever,
    // re-depositing the same request on every reconnect. The reject carries the
    // ORIGINAL requested_at, so a replay cannot delete a newer request.
    send_friend_reject(
        ws_cmd_tx, ws_room_peers, &peer_id_str, &master, original_requested_at,
        super::roster_book::own_roster(&master_keypair.peer_id(), db_path, db_passphrase),
    );
    leave_dm_room(ws_cmd_tx, &master_keypair.peer_id(), &master);

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
    local_peer_str: &str,
    device_peer_id: &str,
    peer_id_str: String,
    pending_friend_removals: &mut std::collections::HashSet<String>,
    pending_friend_requests: &mut HashMap<String, i64>,
    pending_friend_accepts: &mut HashMap<String, i64>,
    db_path: &str,
    db_passphrase: &str,
) {
    // The UI passes the friend's MASTER id, and the friend row is master-keyed, so
    // resolve here too and always delete the MASTER row: a raw device-id delete
    // silently no-ops against a master-keyed row. `resolve` is idempotent for a
    // single-device friend.
    let master = super::resolver::resolve(&peer_id_str);
    hollow_log!("[HOLLOW-FRIENDS] Removing friend {peer_id_str} (master {master})");

    // CANCEL any pending outgoing REQUEST and queued ACCEPT, since removing
    // supersedes them. Otherwise a queued request or accept re-fires on the peer's
    // next appearance, contradicts the removal, and the friendship flaps.
    pending_friend_requests.remove(&master);
    pending_friend_requests.remove(&peer_id_str);
    pending_friend_accepts.remove(&master);
    pending_friend_accepts.remove(&peer_id_str);

    // Delete the local row up-front, unconditionally: removal is a local-first
    // action and must take effect whether or not the peer is online to hear about
    // it. Also clean up any legacy device-stranded row so no duplicate survives.
    let ended_at = super::frame_auth::now_ms();
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        note_removal(&store, &master, ended_at);
        let _ = store.remove_friend(&master);
        if master != peer_id_str {
            let _ = store.remove_friend(&peer_id_str);
        }
    }
    share_removal_with_siblings(ws_cmd_tx, ws_room_peers, local_peer_str, device_peer_id, &master, ended_at);

    // Notify the friend. The bare master authenticates as NO socket, so fan the
    // FriendRemove to every online device of theirs. If none are reachable, queue
    // a tombstone keyed by the MASTER plus a pending entry; the drain resolves a
    // reconnecting device to its master to match it.
    let targets = friend_device_targets(&ws_room_peers, &peer_id_str, &master);
    if targets.is_empty() {
        pending_friend_removals.insert(master.clone());
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let _ = store.save_friend(&master, "removed", "outgoing", 0);
        }
        // A removed row never rejoins the DM room where the queue would meet them,
        // so the removal also waits in their mailbox for their next boot.
        let inbox_room = format!("inbox:{master}");
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom { room_code: inbox_room.clone() });
        send_message_to_peer_in_room(ws_cmd_tx, &inbox_room, &master, HavenMessage::FriendRemove);
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::LeaveRoom { room_code: inbox_room });
        hollow_log!("[HOLLOW-FRIENDS] Friend {master} not reachable, queued removal and deposited it in inbox:{master}");
    } else {
        for t in &targets {
            send_message_to_peer(
                &ws_cmd_tx, &ws_room_peers,
                t, HavenMessage::FriendRemove,
            );
        }
        hollow_log!("[HOLLOW-FRIENDS] Sent FriendRemove for {master} to {} device(s)", targets.len());
    }

    // After the sends: the sealer keeps our commands in order, so the relay forwards
    // the removal before it drops us from the room.
    leave_dm_room(ws_cmd_tx, local_peer_str, &master);

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
        // DM typing: `channel_id` is the recipient's MASTER id, and a master
        // authenticates as NO socket, so `send_message_to_peer(master)` finds no room
        // and silently drops. Fan out to the recipient's DEVICES exactly like a DM: the
        // set is `devices_for(master)` UNION every peer in the DM room resolving to
        // that master, since live presence is authoritative and robust to a stale
        // stored list. For a single-device recipient the set is just the master id.
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
            if super::crypto_handler::ws_room_for_peer(ws_room_peers, target).is_some() {
                super::olm_lane::carry(
                    ws_cmd_tx, target, Some(&dm_room), &msg, super::olm_lane::NoSession::Drop,
                );
                sent_to += 1;
            }
        }
        hollow_log!(
            "[HOLLOW-TYPING] DM typing → master {recipient_master}: sent to {sent_to} device(s)"
        );
    } else {
        // Channel typing: an MLS broadcast to the group, PLUS an Olm copy to exactly
        // the online member devices that hold no leaf in our group.
        //
        // COMPLEMENT rule, not `if !mls_ok`: our own encrypt succeeding says nothing
        // about whether a given member can DECRYPT, and a member with no leaf would
        // never see "typing" as long as anybody else's leaf existed. A fully formed
        // group costs zero extra frames, because the leaf-less set is then empty.
        let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
        hollow_log!("[HOLLOW-TYPING] Channel typing send for {server_id}/{channel_id} (mls={mls_ok})");
        if mls_ok {
            let envelope = MessageEnvelope::Typing { sid: server_id.clone(), cid: channel_id.clone() };
            if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, &server_id, &envelope, crypto_store, server_states.get(&server_id)) {
                hollow_log!("[HOLLOW-MLS] Typing broadcast failed: {e}");
            }
        }
        if let Some(server) = server_states.get(&server_id) {
            let leafless = super::crypto_handler::leafless_member_devices(
                mls, &server_id, server, ws_room_peers, local_peer_str,
            );
            if let Some(json) = super::olm_lane::carried_json(&msg).filter(|_| !leafless.is_empty()) {
                hollow_log!("[HOLLOW-TYPING] Olm typing copy to {} leaf-less device(s)", leafless.len());
                for dev in &leafless {
                    super::olm_lane::carry_json(ws_cmd_tx, dev, None, json.clone(), super::olm_lane::NoSession::Drop);
                }
            }
        }
    }
}

/// Handle `NodeCommand::SetInvisible`: tell every connected device of a friend or
/// a co-member, the people who show our presence.
#[allow(clippy::too_many_arguments)]
pub(crate) fn handle_set_invisible(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server_states: &HashMap<String, crate::crdt::server_state::ServerState>,
    local_peer_str: &str,
    invisible: bool,
    is_invisible: &mut bool,
    db_path: &str,
    db_passphrase: &str,
) {
    *is_invisible = invisible;
    let status = if invisible { "invisible" } else { "online" };
    hollow_log!("[HOLLOW-STATUS] Setting invisible={invisible}, broadcasting status={status}");
    let Some(json) = super::olm_lane::carried_json(&HavenMessage::StatusUpdate { status: status.to_string() }) else {
        return;
    };
    let friends: std::collections::HashSet<String> = super::crypto_handler::accepted_friend_entries(db_path, db_passphrase)
        .into_iter()
        .map(|f| super::resolver::resolve(&f.peer_id))
        .collect();
    let mut sent_to = std::collections::HashSet::new();
    for peers in ws_room_peers.values() {
        for peer in peers {
            if super::resolver::same_identity(peer, local_peer_str) || !sent_to.insert(peer.clone()) {
                continue;
            }
            let master = super::resolver::resolve(peer);
            if friends.contains(&master) || server_states.values().any(|s| s.is_member(&master)) {
                super::olm_lane::carry_json(ws_cmd_tx, peer, None, json.clone(), super::olm_lane::NoSession::Drop);
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
    avatar_frame: Option<String>,
    avatar_anim: Option<String>,
    banner_anim: Option<String>,
    support_creds: Option<String>,
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
    let (
        avatar_hash, banner_hash, stored_showcase, stored_assets_hash, stored_frame,
        stored_avatar_anim, stored_banner_anim, stored_support_creds,
    ) = {
        let mut stored = (
            String::new(), String::new(), String::new(), String::new(), String::new(),
            String::new(), String::new(), String::new(),
        );
        if let Ok(db) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            if let Err(e) = db.save_profile(
                &local_peer_str, &display_name, &status, &about_me, now,
                avatar_bytes.as_deref(), banner_bytes.as_deref(), &twitch_username,
                showcase_board.as_deref(), showcase_assets.as_deref(),
                None, // proof written below, once the stored blob's hash is known
                avatar_frame.as_deref(), avatar_anim.as_deref(), banner_anim.as_deref(),
                support_creds.as_deref(),
            ) {
                hollow_log!("[HOLLOW-SWARM] Failed to save own profile: {e}");
            }
            if let Ok(Some(p)) = db.load_profile(local_peer_str) {
                stored = (
                    profile_blob_hash(p.avatar_bytes.as_deref()),
                    profile_blob_hash(p.banner_bytes.as_deref()),
                    p.showcase_board,
                    profile_blob_hash(p.showcase_assets.as_deref()),
                    p.avatar_frame,
                    p.avatar_anim,
                    p.banner_anim,
                    p.support_creds,
                );
            }
        }
        stored
    };

    // Every field signed, AFTER the save and reload: an unchanged blob arrives as
    // None, so only the STORED blobs' hashes describe what receivers check against.
    let (profile_sig, profile_pk) = super::crypto_handler::sign_profile(
        master_keypair, local_peer_str, now,
        &super::crypto_handler::ProfileFields {
            display_name: &display_name,
            status: &status,
            about_me: &about_me,
            twitch_username: &twitch_username,
            avatar_hash: &avatar_hash,
            banner_hash: &banner_hash,
            showcase_board: &stored_showcase,
            showcase_assets_hash: &stored_assets_hash,
            avatar_frame: &stored_frame,
            avatar_anim: &stored_avatar_anim,
            banner_anim: &stored_banner_anim,
        },
    );

    // Build our master-signed device list so friends learn (tamper-proof) which
    // device peer_ids resolve to us (multi-device, Phase 6).
    let device_list = super::roster_book::own_roster(&master_keypair.peer_id(), db_path, db_passphrase);

    // The credentials field carries its OWN master signature, over the field we are
    // about to send and the timestamp we send it with (see `verify_support_creds_sig`).
    let support_creds_sig = super::crypto_handler::sign_support_creds(
        master_keypair, local_peer_str, now, Some(&stored_support_creds),
    );

    // Our card rides along, so a co-member can show a guest who wrote our public posts.
    let card = super::profile_card::own_card(master_keypair, db_path, db_passphrase);
    // Over MLS to each server we share, then over Olm to everyone MLS did not reach.
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
        avatar_frame: Some(stored_frame.clone()),
        avatar_anim: Some(stored_avatar_anim.clone()),
        banner_anim: Some(stored_banner_anim.clone()),
        support_creds: Some(stored_support_creds.clone()),
        support_creds_sig: support_creds_sig.clone(),
        profile_sig: profile_sig.clone(),
        profile_pk: profile_pk.clone(),
        card: card.clone().map(Box::new),
    };
    let mut mls_reached: std::collections::HashSet<String> = std::collections::HashSet::new();
    for sid in server_states.keys() {
        let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(sid));
        if mls_ok {
            if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), ws_cmd_tx, sid, &envelope, crypto_store, server_states.get(sid)) {
                hollow_log!("[HOLLOW-MLS] Profile broadcast to server {sid} failed: {e}");
            } else {
                // Track members ACTUALLY reached via MLS so we skip them in
                // plaintext. "Reached" = holds at least one LEAF in this group,
                // not "is listed in `state.members`": our encrypt succeeding says
                // nothing about whether a member can decrypt, and marking every
                // member reached is how a leaf-less member never got the plaintext
                // copy either. Leaf ids are DEVICE ids; `mls_reached` is master-keyed.
                if let Some(m) = mls.as_ref() {
                    for dev in m.group_members(sid) {
                        mls_reached.insert(super::resolver::resolve(&dev));
                    }
                }
            }
        }
    }
    let card_list = device_list.clone();
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
        avatar_frame: Some(stored_frame),
        avatar_anim: Some(stored_avatar_anim),
        banner_anim: Some(stored_banner_anim),
        support_creds: Some(stored_support_creds),
        support_creds_sig,
        profile_sig,
        profile_pk,
        card: card.clone().map(Box::new),
    };
    // The whole update to our own devices, friends and co-members, the card to either
    // side of a pending friend request, nothing to anyone else.
    let room_peers: std::collections::HashSet<String> =
        ws_room_peers.values().flat_map(|peers| peers.iter().cloned()).collect();
    let mut carried = 0usize;
    for peer in &room_peers {
        // `mls_reached` holds MASTER member keys and `peer` is a room DEVICE id.
        if peer == local_peer_str
            || peer == device_peer_id
            || mls_reached.contains(peer)
            || mls_reached.contains(&super::resolver::resolve(peer))
            || send_tombstone_if_revoked(ws_cmd_tx, ws_room_peers, local_peer_str, peer, db_path, db_passphrase)
        {
            continue;
        }
        let out = match profile_audience(server_states, local_peer_str, peer, db_path, db_passphrase) {
            Audience::Full => Some(msg.clone()),
            Audience::Card => card.clone().map(|card| HavenMessage::ProfileCard {
                card, avatar_b64: String::new(), device_list: card_list.clone(),
            }),
            Audience::None => None,
        };
        if let Some(out) = out {
            super::olm_lane::carry(ws_cmd_tx, peer, None, &out, super::olm_lane::NoSession::Queue);
            carried += 1;
        }
    }
    hollow_log!("[HOLLOW-PROFILE] Profile update carried to {carried} peer(s), MLS reached {}", mls_reached.len());

    let _ = event_tx.send(NetworkEvent::ProfileUpdated {
        peer_id: local_peer_str.to_string(),
    }).await;
}

/// Persist an incoming profile under the sender's MASTER identity.
///
/// Profiles must be keyed by the master, not the raw sender DEVICE id: presence
/// and the UI collapse an identity to its master, so a device-keyed profile
/// would never be read for the collapsed person, and a second device would write
/// a SEPARATE row.
///
/// EMPTY-PROFILE GUARD: a freshly-imported device holds the master KEY but none
/// of its profile CONTENT, so it broadcasts a blank profile. An empty incoming
/// `display_name` against a populated stored profile SKIPS the write. Returns the
/// master key it was (or would be) stored under, plus whether a save happened.
#[allow(clippy::too_many_arguments)]
/// Byte ceilings for the signed profile text: four bytes for each character of the
/// UI's 32/48/128-character limits, so every name the editor allows fits. The
/// same numbers live in Dart (`message_limits.dart`).
pub(crate) const PROFILE_NAME_MAX_BYTES: usize = 128;
pub(crate) const PROFILE_STATUS_MAX_BYTES: usize = 192;
pub(crate) const PROFILE_ABOUT_MAX_BYTES: usize = 512;
pub(crate) const PROFILE_TWITCH_MAX_BYTES: usize = 64;

/// True when any signed profile field is over its ceiling. The whole profile is
/// then refused on every path, never cut: a cut field no longer matches its
/// signature, so every copy relayed from it fails too (N3).
pub(crate) fn profile_text_oversized(display_name: &str, status: &str, about_me: &str, twitch_username: &str) -> bool {
    display_name.len() > PROFILE_NAME_MAX_BYTES
        || status.len() > PROFILE_STATUS_MAX_BYTES
        || about_me.len() > PROFILE_ABOUT_MAX_BYTES
        || twitch_username.len() > PROFILE_TWITCH_MAX_BYTES
}

/// Receive gate for a peer's profile still (PROFILE-1). The ONE validator, on
/// every path that stores avatar or banner bytes somebody else sent us.
///
/// `None` in means nothing was offered and `None` out means PRESERVE what we
/// hold, so a refusal and an absence land in the same place on purpose: a blob
/// we will not accept must never blank the one already stored. `Some(&[])` is
/// the owner's explicit CLEAR and is not an image, so it goes straight through.
///
/// SECURITY: these bytes are decoded later, when a guest asks for a public
/// channel preview, so unchecked they let a peer park arbitrary bytes in our
/// database and pick the moment we decode a bomb out of them.
pub(crate) fn gated_profile_image<'a>(
    master: &str,
    what: &str,
    max_bytes: usize,
    bytes: Option<&'a [u8]>,
) -> Option<&'a [u8]> {
    let raw = bytes?;
    if raw.is_empty() {
        return Some(raw);
    }
    if raw.len() > max_bytes {
        hollow_log!(
            "[HOLLOW-SECURITY] REJECTED profile image from {master}: {what} is {} bytes, over the {max_bytes} cap",
            raw.len()
        );
        return None;
    }
    match super::image_convert::validate_remote_image_header(raw) {
        Ok(_) => Some(raw),
        Err(why) => {
            hollow_log!("[HOLLOW-SECURITY] REJECTED profile image from {master}: {what} {why}");
            None
        }
    }
}

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
    proof: Option<crate::storage::ProfileProof<'_>>,
    avatar_frame: Option<&str>,
    avatar_anim: Option<&str>,
    banner_anim: Option<&str>,
    // RAW: sanitized HERE, against the resolved master, because the
    // credential's signature binds the master peer id and this is the one
    // place every ingest path already has it.
    support_creds: Option<&str>,
    // The MASTER's signature over that raw field. See [`gated_support_creds`].
    support_creds_sig: Option<&str>,
    db_path: &str,
    db_passphrase: &str,
) -> (String, bool) {
    let master = super::resolver::resolve(sender_peer_id);
    // SECURITY: no verified owner proof, no stored profile. The plaintext
    // ProfileUpdate fallback is a JSON body the relay can rewrite in flight. The
    // caller has already ingested the sender's device list, which is separately
    // master-signed, so presence collapse is unaffected by this refusal.
    let Some(proof) = proof else {
        return (master, false);
    };
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
    // The ONE gate for the support credential field (wiki
    // `security_write_gates.md`): the field's own master signature first, then
    // the entry validator, which verifies every entry against the pinned root
    // and THIS master and drops the rest in silence.
    let support_creds = gated_support_creds(
        &db, &master, updated_at, support_creds, support_creds_sig, Some(proof.pk),
    );
    // PROFILE-1: the stills are the one part of an incoming profile that is
    // raw remote BYTES rather than a bounded string or a hash. A refused blob
    // preserves whatever we already stored.
    let avatar_bytes = gated_profile_image(
        &master, "avatar", super::image_convert::PROFILE_AVATAR_RECV_MAX_BYTES, avatar_bytes,
    );
    let banner_bytes = gated_profile_image(
        &master, "banner", super::image_convert::PROFILE_BANNER_RECV_MAX_BYTES, banner_bytes,
    );
    // Every blob is signed by hash. Bytes that do not hash to it are not the
    // owner's, so they are dropped and what we stored is kept (N1).
    let avatar_bytes = signed_blob(&master, "avatar", avatar_bytes, proof.avatar_hash);
    let banner_bytes = signed_blob(&master, "banner", banner_bytes, proof.banner_hash);
    let showcase_assets = signed_blob(&master, "showcase assets", showcase_assets, proof.assets_hash);
    match db.save_profile(
        &master, display_name, status, about_me, updated_at,
        avatar_bytes, banner_bytes, twitch_username, showcase_board,
        showcase_assets, Some(proof), avatar_frame, avatar_anim, banner_anim,
        support_creds.as_deref(),
    ) {
        // A profile older than the stored one is not saved, and nothing downstream
        // (the member display names) may act on it as if it were (N2).
        Ok(written) => (master, written),
        Err(e) => {
            hollow_log!("[HOLLOW-PROFILE] Failed to save incoming profile for {master}: {e}");
            (master, false)
        }
    }
}

/// `bytes` when they are the blob the owner signed by `signed_hash` (or a clear).
fn signed_blob<'a>(master: &str, what: &str, bytes: Option<&'a [u8]>, signed_hash: &str) -> Option<&'a [u8]> {
    bytes.filter(|b| {
        let matches = b.is_empty() || profile_blob_hash(Some(b)) == signed_hash;
        if !matches {
            hollow_log!("[HOLLOW-SECURITY] DROPPED {what} for {master}: the bytes do not match the signed hash");
        }
        matches
    })
}

/// Masters we have already complained about once, so a stripped field on a
/// reconnect storm is one line in the log rather than hundreds.
fn creds_sig_complaints() -> &'static std::sync::Mutex<std::collections::HashSet<String>> {
    static SEEN: std::sync::OnceLock<std::sync::Mutex<std::collections::HashSet<String>>> =
        std::sync::OnceLock::new();
    SEEN.get_or_init(|| std::sync::Mutex::new(std::collections::HashSet::new()))
}

/// Receive-side gate for `support_creds` and its signature: the ONE place the
/// field is decided (wiki `security_write_gates.md`).
///
/// Returns the value to store; `None` = PRESERVE whatever we already hold.
/// Refusing and clearing are opposite outcomes here, and every refusal below
/// preserves.
///
/// * `None` in -> `None` out. An update that did not touch the field at all.
/// * an announce OLDER than the row we hold -> `None` out, signature or not,
///   so a relay cannot replay a genuine older announce (from before the holder
///   redeemed anything) to clear the marks. The profile row's own freshness
///   guard tolerates 24 hours of backdating, so this field needs its own rule.
/// * no VALID signature -> `None` out. The field is accepted ONLY under a
///   signature by the master it claims to describe, `Some("")` included: the
///   explicit clear is the single most useful thing for a relay to forge.
/// * a VALID signature -> the field, through the entry validator.
///
/// Trust-on-first-use was tried and rejected: a per-master pin could never be
/// set on a master whose FIRST announce was stripped, so an attacker present
/// for the first use kept that master on the unsigned branch permanently.
fn gated_support_creds(
    db: &crate::storage::MessageStore,
    master: &str,
    updated_at: i64,
    raw: Option<&str>,
    support_creds_sig: Option<&str>,
    profile_pk: Option<&str>,
) -> Option<String> {
    let raw = raw?;
    if let Ok(Some(stored)) = db.load_profile(master) {
        if updated_at < stored.updated_at {
            return None;
        }
    }
    if !super::crypto_handler::verify_support_creds_sig(
        master, updated_at, raw, support_creds_sig, profile_pk,
    ) {
        if let Ok(mut seen) = creds_sig_complaints().lock() {
            if seen.insert(master.to_string()) {
                hollow_log!(
                    "[HOLLOW-SECURITY] REFUSED the support credential field from {master} — no valid signature over it; keeping what we stored"
                );
            }
        }
        return None;
    }
    super::support_creds::sanitize_incoming_support_creds(Some(raw), master)
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

/// Receive-side gate for an avatar frame ID (issue #54). A frame ID is one of
/// exactly three shapes and nothing else ever reaches the DB:
///   * `""`         — cleared,
///   * `b:<hue>`    — a built-in procedural frame, hue 0-359,
///   * 64-hex       — an asset-rail blob hash.
///
/// Anything else is treated as ABSENT (`None` = preserve what we stored),
/// which is also what an old client sends. This is the only place the value
/// is validated, so the renderer can trust the three shapes: it keys a network
/// PULL, and the profile signature proves only who chose the string, so an
/// unvalidated one is a request-anything primitive.
pub(crate) fn sanitize_incoming_frame(avatar_frame: Option<&str>) -> Option<&str> {
    match avatar_frame {
        Some("") => Some(""),
        Some(s) if valid_avatar_frame_id(s) => Some(s),
        _ => None,
    }
}

/// Receive-side gate for an ANIMATED avatar/banner reference. Exactly two
/// shapes reach the DB:
///   * `""`   - no animated variant (or cleared),
///   * 64-hex - an asset-rail blob hash.
///
/// Anything else is ABSENT (`None` = preserve what we stored), which is also
/// what an old client sends. Same reasoning as [`sanitize_incoming_frame`]:
/// this value keys a network PULL, so an unvalidated string would be a
/// request-anything primitive. Signed like every profile field (`hollow-profile2`).
pub(crate) fn sanitize_incoming_anim(anim: Option<&str>) -> Option<&str> {
    match anim {
        Some("") => Some(""),
        Some(s) if crate::crdt::valid_emote_hash(s) => Some(s),
        _ => None,
    }
}

/// Whether `id` is a usable avatar frame reference (never `""`).
pub(crate) fn valid_avatar_frame_id(id: &str) -> bool {
    if let Some(hue) = id.strip_prefix("b:") {
        // Canonical decimal only: no leading zeros, so one frame has exactly
        // one ID and "b:12" can never sit beside "b:012" as a second entry.
        return !hue.is_empty()
            && hue.len() <= 3
            && hue.bytes().all(|b| b.is_ascii_digit())
            && (hue == "0" || !hue.starts_with('0'))
            && hue.parse::<u32>().is_ok_and(|h| h < 360);
    }
    crate::crdt::valid_emote_hash(id)
}

/// Verify the owner proof on a profile arriving via `ProfileUpdate` (MLS or Olm).
/// `None` = the PROFILE FIELDS must not be stored.
///
/// REQUIRED, not tolerated, over every field a receiver stores (N1): a stored proof
/// is what makes the profile relayable, so it may never cover less than the row.
///
/// **This gates the profile fields ONLY.** The caller ingests the sender's signed
/// DEVICE LIST first and independently: that list stands on its own two gates, and it
/// must run first because this verifies against `resolve(sender_peer_id)`. A node with
/// no profile row still announces a device list, and that announce is what collapses
/// its devices into one online identity, so gating it here would break presence.
pub(crate) fn verified_profile_proof(
    sender_peer_id: &str,
    updated_at: i64,
    fields: &super::crypto_handler::ProfileFields,
    profile_sig: Option<&str>,
    profile_pk: Option<&str>,
) -> Option<(String, String)> {
    let master = super::resolver::resolve(sender_peer_id);
    let (Some(sig), Some(pk)) = (profile_sig, profile_pk) else {
        hollow_log!("[HOLLOW-SECURITY] REJECTED profile fields from {sender_peer_id} (master {master}) — NO owner signature (device list, if any, still ingested)");
        return None;
    };
    if !super::crypto_handler::verify_profile_signature(&master, updated_at, fields, Some(sig), Some(pk)) {
        hollow_log!("[HOLLOW-SECURITY] REJECTED profile fields from {sender_peer_id} (master {master}) — owner signature INVALID");
        return None;
    }
    Some((sig.to_string(), pk.to_string()))
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

//// How much of our profile a peer may see (A28).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Audience {
    /// Our own devices, friends and the members of a server we share.
    Full,
    /// Either side of a pending friend request: the card, name and avatar only.
    Card,
    /// Anyone else.
    None,
}

/// What the device `peer` may see of our profile.
pub(crate) fn profile_audience(
    server_states: &HashMap<String, ServerState>,
    local_master: &str,
    peer: &str,
    db_path: &str,
    db_passphrase: &str,
) -> Audience {
    if super::resolver::is_revoked(peer) {
        return Audience::None;
    }
    if super::voice_handler::data_channel_peer_allowed(server_states, local_master, peer, db_path, db_passphrase) {
        return Audience::Full;
    }
    let pending = !super::blocklist::is_blocked(peer)
        && crate::storage::MessageStore::open(db_path, db_passphrase)
            .ok()
            .and_then(|st| st.get_friend_status(&super::resolver::resolve(peer)).ok().flatten())
            .is_some_and(|status| status == "pending");
    if pending { Audience::Card } else { Audience::None }
}

/// Send our own profile to a specific peer, as much of it as that peer may see.
///
/// LIGHT by default: avatar and banner ride as EMPTY strings ("no change" under
/// the receiver's COALESCE save) plus content hashes, and a receiver whose
/// cached blobs do not match pulls the full profile ONCE via ProfileRequest.
/// That keeps the many re-announce paths at about 1 KB instead of re-shipping
/// megabytes of unchanged avatar and banner on every reconnect.
#[allow(clippy::too_many_arguments)]
pub(crate) fn send_own_profile_to_peer(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server_states: &HashMap<String, ServerState>,
    local_peer_str: &str,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    target_peer: &str,
    is_invisible: bool,
    db_path: &str,
    db_passphrase: &str,
) {
    send_own_profile_inner(
        ws_cmd_tx, ws_room_peers, server_states, local_peer_str, master_keypair,
        target_peer, is_invisible, db_path, db_passphrase, false, None, None,
    );
}

/// Light profile announce addressed into an EXPLICIT room, so the relay buffers
/// it for a recipient who is not online at all.
///
/// The accepter needs this: the requester learned OUR master from the carried
/// request and we must teach it the reverse, but the normal announce is a
/// `ws_room_for_peer` lookup that finds nothing for someone who is simply gone.
#[allow(clippy::too_many_arguments)]
pub(crate) fn send_own_profile_to_peer_in_room(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server_states: &HashMap<String, ServerState>,
    local_peer_str: &str,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    target_peer: &str,
    room_code: &str,
    is_invisible: bool,
    db_path: &str,
    db_passphrase: &str,
) {
    send_own_profile_inner(
        ws_cmd_tx, ws_room_peers, server_states, local_peer_str, master_keypair,
        target_peer, is_invisible, db_path, db_passphrase, false, Some(room_code), None,
    );
}

/// Announce our profile carrying an EXPLICIT roster instead of our stored one.
///
/// Destruction scope (b) is the only caller: its roster removes the device we are
/// running on, which the stored roster never says about itself.
#[allow(clippy::too_many_arguments)]
pub(crate) fn send_own_profile_with_device_list(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server_states: &HashMap<String, ServerState>,
    local_peer_str: &str,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    target_peer: &str,
    list: crate::identity::roster::Roster,
    is_invisible: bool,
    db_path: &str,
    db_passphrase: &str,
) {
    send_own_profile_inner(
        ws_cmd_tx, ws_room_peers, server_states, local_peer_str, master_keypair,
        target_peer, is_invisible, db_path, db_passphrase, false, None, Some(list),
    );
}

/// Full-blob variant — ONLY for answering an explicit ProfileRequest (the pull
/// half of the light-announce protocol), so blobs still converge on demand.
#[allow(clippy::too_many_arguments)]
pub(crate) fn send_own_profile_full_to_peer(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server_states: &HashMap<String, ServerState>,
    local_peer_str: &str,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    target_peer: &str,
    is_invisible: bool,
    db_path: &str,
    db_passphrase: &str,
) {
    send_own_profile_inner(
        ws_cmd_tx, ws_room_peers, server_states, local_peer_str, master_keypair,
        target_peer, is_invisible, db_path, db_passphrase, true, None, None,
    );
}

#[allow(clippy::too_many_arguments)]
fn send_own_profile_inner(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server_states: &HashMap<String, ServerState>,
    local_peer_str: &str,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    target_peer: &str,
    is_invisible: bool,
    db_path: &str,
    db_passphrase: &str,
    include_blobs: bool,
    // Some(room) = address the announce into THAT room (so an offline recipient
    // gets it buffered); None = today's reachable-peer lookup.
    room_code: Option<&str>,
    // Some = publish THIS roster verbatim instead of our stored one.
    override_device_list: Option<crate::identity::roster::Roster>,
) {
    if send_tombstone_if_revoked(ws_cmd_tx, ws_room_peers, local_peer_str, target_peer, db_path, db_passphrase) {
        return;
    }
    match profile_audience(server_states, local_peer_str, target_peer, db_path, db_passphrase) {
        Audience::Full => {
            let msg = own_profile_update(
                master_keypair, local_peer_str, is_invisible, include_blobs,
                override_device_list, db_path, db_passphrase,
            );
            if let Some(msg) = msg {
                super::olm_lane::carry(ws_cmd_tx, target_peer, room_code, &msg, super::olm_lane::NoSession::Queue);
            }
        }
        Audience::Card => send_own_card(
            ws_cmd_tx, master_keypair, target_peer, room_code, include_blobs, db_path, db_passphrase,
        ),
        Audience::None => {}
    }
}

/// Our card to one device, with the avatar bytes when it asked for them.
#[allow(clippy::too_many_arguments)]
pub(crate) fn send_own_card(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    target_peer: &str,
    room_code: Option<&str>,
    with_avatar: bool,
    db_path: &str,
    db_passphrase: &str,
) {
    let Some(card) = super::profile_card::own_card(master_keypair, db_path, db_passphrase) else {
        return;
    };
    let avatar_b64 = with_avatar
        .then(|| super::profile_card::own_avatar(&card.master, db_path, db_passphrase))
        .flatten()
        .map(|b| base64::engine::general_purpose::STANDARD.encode(b))
        .unwrap_or_default();
    let device_list = super::roster_book::own_roster(&master_keypair.peer_id(), db_path, db_passphrase);
    super::olm_lane::carry(
        ws_cmd_tx, target_peer, room_code,
        &HavenMessage::ProfileCard { card, avatar_b64, device_list },
        super::olm_lane::NoSession::Queue,
    );
}

/// When `target_peer` is one of OUR removed devices, hand it our roster on the relay
/// lane and nothing else: no session reaches it any more, and the roster is how it
/// learns it was removed. Returns whether it was one.
fn send_tombstone_if_revoked(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    local_master: &str,
    target_peer: &str,
    db_path: &str,
    db_passphrase: &str,
) -> bool {
    let Some((roster, state)) = super::roster_book::own(local_master, db_path, db_passphrase) else {
        return false;
    };
    if !state.removed.contains_key(target_peer) {
        return false;
    }
    send_message_to_peer(ws_cmd_tx, ws_room_peers, target_peer, HavenMessage::RosterNotice { roster });
    true
}

/// Co-members' devices we cannot place yet, out of `(device, master)` pairs whose
/// leaves our server group certifies: no stored link from the device to its master,
/// or no profile for the master.
pub(crate) fn co_members_to_introduce(
    candidates: Vec<(String, String)>,
    db_path: &str,
    db_passphrase: &str,
) -> Vec<String> {
    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else {
        return Vec::new();
    };
    candidates
        .into_iter()
        .filter(|(device, master)| {
            !store.device_links_for(master).is_ok_and(|links| links.contains(device))
                || !store.load_profile_light(master).is_ok_and(|p| p.is_some())
        })
        .map(|(device, _)| device)
        .collect()
}

/// Our profile and roster to a co-member's device that our resolver cannot place.
/// The caller vouches for the device with its certified leaf in our server group;
/// `include_blobs` only when answering its ProfileRequest.
#[allow(clippy::too_many_arguments)]
pub(crate) fn send_own_profile_to_co_member(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    local_master: &str,
    device: &str,
    is_invisible: bool,
    include_blobs: bool,
    db_path: &str,
    db_passphrase: &str,
) {
    if let Some(msg) = own_profile_update(master_keypair, local_master, is_invisible, include_blobs, None, db_path, db_passphrase) {
        super::olm_lane::carry(ws_cmd_tx, device, None, &msg, super::olm_lane::NoSession::Queue);
    }
}

/// Our light profile to a co-member's device that met us as a stranger, then a
/// request for theirs.
///
/// Members who were offline while somebody joined never saw the join request that
/// carried the joiner's roster, and the joiner's Welcome found them away, so neither
/// side can place the other's device and every audience gate stays shut. Our roster
/// arrives first, so the answer to our request finds us placed.
pub(crate) fn introduce_to_co_member(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    local_master: &str,
    device: &str,
    is_invisible: bool,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-PROFILE] Introducing ourselves to co-member device {device}");
    send_own_profile_to_co_member(ws_cmd_tx, master_keypair, local_master, device, is_invisible, false, db_path, db_passphrase);
    super::olm_lane::carry(ws_cmd_tx, device, None, &HavenMessage::ProfileRequest, super::olm_lane::NoSession::Queue);
}

/// Our profile as stored, with every field signed now. Our own blobs are the
/// authority, so the hashes describe exactly what we hold; `include_blobs` adds the
/// bytes for a pull. A profile-less node still announces its device list, which is
/// what collapses its devices into one online identity at a friend's.
#[allow(clippy::too_many_arguments)]
pub(crate) fn own_profile_update(
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    local_master: &str,
    is_invisible: bool,
    include_blobs: bool,
    override_device_list: Option<crate::identity::roster::Roster>,
    db_path: &str,
    db_passphrase: &str,
) -> Option<HavenMessage> {
    let store = crate::storage::MessageStore::open(db_path, db_passphrase).ok()?;
    let p = store.load_profile(local_master).ok().flatten().unwrap_or_else(|| crate::storage::messages::StoredProfile {
        peer_id: local_master.to_string(),
        ..Default::default()
    });
    let hashes = (
        profile_blob_hash(p.avatar_bytes.as_deref()),
        profile_blob_hash(p.banner_bytes.as_deref()),
        profile_blob_hash(p.showcase_assets.as_deref()),
    );
    let (profile_sig, profile_pk) = super::crypto_handler::sign_profile(
        master_keypair, local_master, p.updated_at, &own_fields(&p, &hashes),
    );
    let b64 = |b: &Option<Vec<u8>>| {
        b.as_ref()
            .filter(|_| include_blobs)
            .map(|b| base64::engine::general_purpose::STANDARD.encode(b))
            .unwrap_or_default()
    };
    let device_list = override_device_list.or_else(|| {
        super::roster_book::own_roster(&master_keypair.peer_id(), db_path, db_passphrase)
    });
    // The credentials field carries its OWN master signature, over the stored field
    // and the stored timestamp this frame re-announces.
    let support_creds_sig = super::crypto_handler::sign_support_creds(
        master_keypair, local_master, p.updated_at, Some(&p.support_creds),
    );
    Some(HavenMessage::ProfileUpdate {
        avatar_b64: b64(&p.avatar_bytes),
        banner_b64: b64(&p.banner_bytes),
        showcase_assets_b64: b64(&p.showcase_assets),
        display_name: p.display_name,
        status: p.status,
        about_me: p.about_me,
        updated_at: p.updated_at,
        is_invisible,
        twitch_username: p.twitch_username,
        device_list,
        avatar_hash: hashes.0,
        banner_hash: hashes.1,
        showcase_board: Some(p.showcase_board),
        showcase_assets_hash: hashes.2,
        avatar_frame: Some(p.avatar_frame),
        avatar_anim: Some(p.avatar_anim),
        banner_anim: Some(p.banner_anim),
        support_creds: Some(p.support_creds),
        support_creds_sig,
        profile_sig,
        profile_pk,
        card: super::profile_card::own_card(master_keypair, db_path, db_passphrase).map(Box::new),
    })
}

/// The signed fields of our own stored profile, with its blobs' hashes.
fn own_fields<'a>(
    p: &'a crate::storage::messages::StoredProfile,
    hashes: &'a (String, String, String),
) -> super::crypto_handler::ProfileFields<'a> {
    super::crypto_handler::ProfileFields {
        display_name: &p.display_name,
        status: &p.status,
        about_me: &p.about_me,
        twitch_username: &p.twitch_username,
        avatar_hash: &hashes.0,
        banner_hash: &hashes.1,
        showcase_board: &p.showcase_board,
        showcase_assets_hash: &hashes.2,
        avatar_frame: &p.avatar_frame,
        avatar_anim: &p.avatar_anim,
        banner_anim: &p.banner_anim,
    }
}

// If a LIGHT ProfileUpdate advertises avatar/banner hashes that do not match
/// our cached blobs for this identity, pull the full profile once via
/// ProfileRequest.
///
/// Cooldown-deduped per identity (10 min, keyed by OUR device id so harness
/// nodes sharing one process do not share buckets), so an oversized or
/// undeliverable blob cannot become a request loop. An EMPTY incoming hash
/// while we cache a blob is deliberately NOT stale: clears ride the full send.
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
    let _ = ws_room_peers;
    super::olm_lane::carry(ws_cmd_tx, sender_peer_id, None, &HavenMessage::ProfileRequest, super::olm_lane::NoSession::Queue);
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
    device_list: Option<crate::identity::roster::Roster>,
    avatar_hash: String,
    banner_hash: String,
    showcase_board: Option<String>,
    showcase_assets_b64: String,
    showcase_assets_hash: String,
    avatar_frame: Option<String>,
    avatar_anim: Option<String>,
    banner_anim: Option<String>,
    support_creds: Option<String>,
    support_creds_sig: Option<String>,
    profile_sig: Option<String>,
    profile_pk: Option<String>,
    db_path: &str,
    db_passphrase: &str,
) -> Vec<String> {
    // Multi-device: fold the sender's roster into ours for its master (verify,
    // merge, persist, resolver update, DeviceListUpdated).
    //
    // Siblings meet in the inbox room over the Olm path, not this MLS server-member
    // envelope, so the "our roster changed" re-announce is that handler's job, not
    // ours. `newly_revoked` is surfaced so the swarm caller can drop Olm sessions and
    // remove MLS leaves for a device removed this way.
    let outcome = super::roster_book::ingest(
        event_tx, ws_cmd_tx, local_master_peer_id, local_device_peer_id,
        &sender_peer_id, device_list, db_path, db_passphrase,
    ).await;
    let newly_revoked = outcome.newly_revoked;
    if profile_text_oversized(&display_name, &status, &about_me, &twitch_username) {
        hollow_log!("[HOLLOW-SECURITY] REJECTED profile from {sender_peer_id}: a field exceeds its limit");
        return newly_revoked;
    }

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
    // Owner proof (0.8.5): persisted only when it VERIFIES, so we can never
    // launder an unverified signature into a ProfileRelay. See
    // `verified_profile_proof` for why absent is tolerated on this path.
    let fields = super::crypto_handler::ProfileFields {
        display_name: &display_name,
        status: &status,
        about_me: &about_me,
        twitch_username: &twitch_username,
        avatar_hash: &avatar_hash,
        banner_hash: &banner_hash,
        showcase_board: showcase_board.as_deref().unwrap_or_default(),
        showcase_assets_hash: &showcase_assets_hash,
        avatar_frame: avatar_frame.as_deref().unwrap_or_default(),
        avatar_anim: avatar_anim.as_deref().unwrap_or_default(),
        banner_anim: banner_anim.as_deref().unwrap_or_default(),
    };
    let verified = verified_profile_proof(
        &sender_peer_id, updated_at, &fields, profile_sig.as_deref(), profile_pk.as_deref(),
    );
    let proof = verified.as_ref().map(|(sig, pk)| crate::storage::ProfileProof {
        sig, pk,
        avatar_hash: &avatar_hash,
        banner_hash: &banner_hash,
        assets_hash: &showcase_assets_hash,
    });
    // Multi-device: persist under the sender's MASTER (any device updates the one
    // identity profile) + empty-profile guard. Single-device: master == sender.
    let (profile_master, saved) = save_incoming_profile(
        &sender_peer_id, &display_name, &status, &about_me, updated_at,
        avatar_bytes.as_deref(), banner_bytes.as_deref(), &twitch_username,
        sanitize_incoming_showcase(showcase_board.as_deref()),
        showcase_assets_bytes.as_deref(), proof,
        sanitize_incoming_frame(avatar_frame.as_deref()),
        sanitize_incoming_anim(avatar_anim.as_deref()),
        sanitize_incoming_anim(banner_anim.as_deref()),
        support_creds.as_deref(),
        support_creds_sig.as_deref(),
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
    // `saved` gates this too: an unverified display name must not reach the
    // member list either, or the spoof just lands one layer up.
    for (_, state) in server_states.iter_mut() {
        if saved && !display_name.is_empty() {
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

/// Handle `ProfileRequestFor`: relay the target's stored profile, with the owner's
/// proof over every field, as a `ProfileRelay` (avatar included, no banner).
pub(crate) fn handle_profile_request_for(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    requester_peer: &str,
    target_peer_id: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    if target_peer_id.is_empty() { return; }

    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        if let Ok(Some(profile)) = store.load_profile(target_peer_id) {
            // Only a profile its owner signed whole can be relayed: the receiver
            // refuses anything less, so sending it would only mask the reason.
            let (Some(sig), Some(pk), Some(avatar_hash), Some(banner_hash), Some(showcase_assets_hash)) = (
                profile.profile_sig, profile.profile_pk, profile.profile_avatar_hash,
                profile.profile_banner_hash, profile.profile_assets_hash,
            ) else {
                hollow_log!("[HOLLOW-PROFILE] Not relaying {target_peer_id} to {requester_peer} — no owner signature stored");
                return;
            };
            // Only ship the blob when it IS the one the signature covers; a
            // stale cached avatar would just be dropped by the receiver, who
            // then pulls the current one from the owner.
            let avatar_b64 = profile.avatar_bytes
                .as_ref()
                .filter(|b| profile_blob_hash(Some(b)) == avatar_hash)
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
                avatar_hash,
                banner_hash,
                showcase_board: profile.showcase_board,
                showcase_assets_hash,
                avatar_frame: profile.avatar_frame,
                avatar_anim: profile.avatar_anim,
                banner_anim: profile.banner_anim,
                profile_sig: Some(sig),
                profile_pk: Some(pk),
            };
            super::olm_lane::carry(ws_cmd_tx, requester_peer, None, &msg, super::olm_lane::NoSession::Drop);
            hollow_log!("[HOLLOW-PROFILE] Relayed profile for {target_peer_id} to {requester_peer}");
        } else {
            hollow_log!("[HOLLOW-PROFILE] No cached profile for {target_peer_id}, cannot relay");
        }
    }
}

/// A `ProfileRelay` as it arrived.
pub(crate) struct RelayedProfile {
    pub source_peer_id: String,
    pub display_name: String,
    pub status: String,
    pub about_me: String,
    pub updated_at: i64,
    pub avatar_b64: String,
    pub twitch_username: String,
    pub avatar_hash: String,
    pub banner_hash: String,
    pub showcase_board: String,
    pub showcase_assets_hash: String,
    pub avatar_frame: String,
    pub avatar_anim: String,
    pub banner_anim: String,
    pub profile_sig: Option<String>,
    pub profile_pk: Option<String>,
}

impl RelayedProfile {
    fn fields(&self) -> super::crypto_handler::ProfileFields<'_> {
        super::crypto_handler::ProfileFields {
            display_name: &self.display_name,
            status: &self.status,
            about_me: &self.about_me,
            twitch_username: &self.twitch_username,
            avatar_hash: &self.avatar_hash,
            banner_hash: &self.banner_hash,
            showcase_board: &self.showcase_board,
            showcase_assets_hash: &self.showcase_assets_hash,
            avatar_frame: &self.avatar_frame,
            avatar_anim: &self.avatar_anim,
            banner_anim: &self.banner_anim,
        }
    }
}

/// Handle incoming `ProfileRelay` — save the relayed profile + avatar, update
/// member display names, emit `ProfileUpdated`.
pub(crate) async fn handle_profile_relay(
    event_tx: &mpsc::Sender<NetworkEvent>,
    server_states: &mut HashMap<String, ServerState>,
    relayed: RelayedProfile,
    db_path: &str,
    db_passphrase: &str,
) {
    // SECURITY: this frame asserts a THIRD party's profile, with a `source_peer_id`
    // and an `updated_at` the sender picks, so without the subject's own signature
    // any co-member could overwrite anyone's profile for good by claiming
    // updated_at = i64::MAX.
    let source = relayed.source_peer_id.as_str();
    if profile_text_oversized(&relayed.display_name, &relayed.status, &relayed.about_me, &relayed.twitch_username) {
        hollow_log!("[HOLLOW-SECURITY] REJECTED relayed profile for {source} — field exceeds its limit");
        return;
    }
    let (Some(sig), Some(pk)) = (relayed.profile_sig.as_deref(), relayed.profile_pk.as_deref()) else {
        hollow_log!("[HOLLOW-SECURITY] REJECTED relayed profile for {source} — NO owner signature");
        return;
    };
    if !super::crypto_handler::verify_profile_signature(source, relayed.updated_at, &relayed.fields(), Some(sig), Some(pk)) {
        hollow_log!("[HOLLOW-SECURITY] REJECTED relayed profile for {source} — owner signature INVALID (updated_at={})", relayed.updated_at);
        return;
    }

    // The blob is bound by HASH, so a relayer with a stale cache loses only its
    // avatar here (we pull the real one from the owner) and one that swapped it is
    // caught by the same comparison.
    let avatar_bytes: Option<Vec<u8>> = if relayed.avatar_b64.is_empty() {
        None
    } else {
        base64::engine::general_purpose::STANDARD.decode(&relayed.avatar_b64).ok()
            .filter(|b| b.len() <= 1_000_000)
            .filter(|b| {
                let ok = profile_blob_hash(Some(b)) == relayed.avatar_hash;
                if !ok {
                    hollow_log!("[HOLLOW-SECURITY] DROPPED relayed avatar for {source} — bytes do not match the signed hash");
                }
                ok
            })
    };

    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else {
        return;
    };
    if store.load_profile_light(source).ok().flatten().is_some_and(|existing| existing.updated_at >= relayed.updated_at) {
        hollow_log!("[HOLLOW-PROFILE] Skipped relayed profile for {source} (already have newer)");
        return;
    }
    // The verified proof rides along so WE can relay it onward. PROFILE-1: a relayed
    // avatar is remote bytes from a peer that is not even the subject, so it takes
    // the same gate; refused preserves, and the relay's text still lands.
    let avatar_bytes = gated_profile_image(
        source, "relayed avatar", super::image_convert::PROFILE_AVATAR_RECV_MAX_BYTES, avatar_bytes.as_deref(),
    );
    let proof = crate::storage::ProfileProof {
        sig, pk,
        avatar_hash: &relayed.avatar_hash,
        banner_hash: &relayed.banner_hash,
        assets_hash: &relayed.showcase_assets_hash,
    };
    let _ = store.save_profile(
        source, &relayed.display_name, &relayed.status, &relayed.about_me, relayed.updated_at,
        avatar_bytes, None, &relayed.twitch_username,
        sanitize_incoming_showcase(Some(&relayed.showcase_board)), None,
        Some(proof),
        sanitize_incoming_frame(Some(&relayed.avatar_frame)),
        sanitize_incoming_anim(Some(&relayed.avatar_anim)),
        sanitize_incoming_anim(Some(&relayed.banner_anim)),
        None,
    );
    hollow_log!("[HOLLOW-PROFILE] Saved relayed profile for {source}");

    // Update display_name in server member lists (master-keyed).
    let source_master = super::resolver::resolve(source);
    for (_, state) in server_states.iter_mut() {
        if let Some(member) = state.members.get_mut(&source_master) {
            if !relayed.display_name.is_empty() {
                member.display_name = relayed.display_name.clone();
            }
        }
    }

    let _ = event_tx.send(NetworkEvent::ProfileUpdated {
        peer_id: relayed.source_peer_id,
    }).await;
}

#[cfg(test)]
mod tests {
    use super::{
        gated_profile_image, profile_blob_hash, profile_text_oversized, sanitize_incoming_frame,
        save_incoming_profile, valid_avatar_frame_id, PROFILE_ABOUT_MAX_BYTES,
    };
    use crate::identity::native_identity::NativeKeypair;
    use crate::node::support_creds::{self, testing};

    // ── PROFILE-1: the receive gate on a peer's profile stills ──────────

    /// PNG's chunk CRC (IEEE, reflected), so a hand-built header is one a real
    /// decoder accepts rather than one it rejects for the wrong reason.
    fn png_crc32(bytes: &[u8]) -> u32 {
        let mut crc = 0xFFFF_FFFFu32;
        for &b in bytes {
            crc ^= u32::from(b);
            for _ in 0..8 {
                let mask = (crc & 1).wrapping_neg();
                crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
            }
        }
        !crc
    }

    /// A structurally valid PNG head DECLARING `w`x`h` 8-bit RGBA, stub body.
    fn png_declaring(w: u32, h: u32) -> Vec<u8> {
        let mut ihdr = Vec::with_capacity(17);
        ihdr.extend_from_slice(b"IHDR");
        ihdr.extend_from_slice(&w.to_be_bytes());
        ihdr.extend_from_slice(&h.to_be_bytes());
        ihdr.extend_from_slice(&[8, 6, 0, 0, 0]);
        let mut idat = Vec::with_capacity(68);
        idat.extend_from_slice(b"IDAT");
        idat.extend_from_slice(&[0u8; 64]);

        let mut out = Vec::new();
        out.extend_from_slice(b"\x89PNG\r\n\x1a\n");
        out.extend_from_slice(&13u32.to_be_bytes());
        out.extend_from_slice(&ihdr);
        out.extend_from_slice(&png_crc32(&ihdr).to_be_bytes());
        out.extend_from_slice(&64u32.to_be_bytes());
        out.extend_from_slice(&idat);
        out.extend_from_slice(&png_crc32(&idat).to_be_bytes());
        out
    }

    /// A hand-built VP8X WebP header declaring `dim`x`dim`.
    fn webp_declaring(dim: u32) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&0u32.to_le_bytes());
        out.extend_from_slice(b"WEBP");
        out.extend_from_slice(b"VP8X");
        out.extend_from_slice(&10u32.to_le_bytes());
        out.push(0x10);
        out.extend_from_slice(&[0, 0, 0]);
        let minus_one = dim - 1;
        out.extend_from_slice(&minus_one.to_le_bytes()[0..3]);
        out.extend_from_slice(&minus_one.to_le_bytes()[0..3]);
        out.extend_from_slice(&[0xAB; 512]);
        out
    }

    /// A real, small PNG — the control.
    fn small_png() -> Vec<u8> {
        let img = image::RgbaImage::from_pixel(48, 32, image::Rgba([90, 140, 200, 255]));
        let mut buf = Vec::new();
        img.write_to(&mut std::io::Cursor::new(&mut buf), image::ImageFormat::Png)
            .expect("encode png");
        buf
    }

    const AVATAR_CAP: usize = crate::node::image_convert::PROFILE_AVATAR_RECV_MAX_BYTES;

    /// PROFILE-1 regression: a peer's avatar bytes are the one part of an
    /// incoming profile that is raw remote content, and they get decoded
    /// later. A blob that DECLARES an absurd canvas is dropped at receipt,
    /// and dropping PRESERVES rather than clears.
    #[test]
    fn incoming_profile_image_bomb_is_dropped() {
        const MASTER: &str = "12D3KooW-profile1-bomb";

        let png_bomb = png_declaring(20_000, 20_000);
        assert!(
            gated_profile_image(MASTER, "avatar", AVATAR_CAP, Some(&png_bomb)).is_none(),
            "a PNG declaring 20000x20000 must be dropped",
        );

        let webp_bomb = webp_declaring(16_384);
        assert!(
            gated_profile_image(MASTER, "avatar", AVATAR_CAP, Some(&webp_bomb)).is_none(),
            "a VP8X header declaring 16384x16384 must be dropped",
        );

        // Not an image at all, and an image format we do not render.
        assert!(
            gated_profile_image(MASTER, "avatar", AVATAR_CAP, Some(b"not an image")).is_none(),
            "bytes that are not an image must be dropped",
        );

        // The control: an ordinary still still lands, and so do the two
        // non-image states the field has.
        let ok = small_png();
        assert_eq!(
            gated_profile_image(MASTER, "avatar", AVATAR_CAP, Some(&ok)),
            Some(ok.as_slice()),
            "an ordinary avatar must still be stored",
        );
        assert_eq!(
            gated_profile_image(MASTER, "avatar", AVATAR_CAP, Some(&[])),
            Some(&[][..]),
            "an empty blob is the owner's explicit clear, not an image",
        );
        assert_eq!(
            gated_profile_image(MASTER, "avatar", AVATAR_CAP, None),
            None,
            "nothing offered preserves what is stored",
        );
    }

    /// The byte cap runs before anything parses the bytes, so a peer cannot
    /// park megabytes in our database under the name of an avatar.
    #[test]
    fn incoming_profile_image_over_byte_cap_is_dropped() {
        const MASTER: &str = "12D3KooW-profile1-cap";

        // A REAL, decodable PNG that is simply too big for the field. The
        // point is the cap, not the content.
        let img = image::RgbaImage::from_fn(1200, 1200, |x, y| {
            image::Rgba([(x % 256) as u8, (y % 256) as u8, ((x ^ y) % 256) as u8, 255])
        });
        let mut fat = Vec::new();
        img.write_to(&mut std::io::Cursor::new(&mut fat), image::ImageFormat::Png)
            .expect("encode png");
        assert!(
            fat.len() > AVATAR_CAP,
            "fixture must exceed the {AVATAR_CAP} byte avatar cap, is {}",
            fat.len(),
        );
        assert!(
            crate::node::image_convert::validate_remote_image_header(&fat).is_ok(),
            "the fixture is a perfectly valid image — only its size is wrong",
        );

        assert!(
            gated_profile_image(MASTER, "avatar", AVATAR_CAP, Some(&fat)).is_none(),
            "an over-cap avatar must be dropped",
        );
        // The banner's cap is looser, and the same bytes fit under it.
        assert!(
            gated_profile_image(
                MASTER,
                "banner",
                crate::node::image_convert::PROFILE_BANNER_RECV_MAX_BYTES,
                Some(&fat),
            )
            .is_some(),
            "the same bytes are inside the banner cap",
        );
    }

    /// Section 2 item 9 (A-DM-09, S14): what a friendship's end bounds. A request or
    /// a sibling's entry made before it is from the friendship that ended.
    #[test]
    fn a_removal_bounds_only_what_was_made_before_it() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join("removal.db").to_str().unwrap().to_string();
        let pass = "ef".repeat(32);
        crate::storage::MessageStore::migrate_auto_vacuum_once(&db, &pass).unwrap();
        let store = crate::storage::MessageStore::open(&db, &pass).unwrap();
        let skew = crate::node::frame_auth::LIVE_SKEW_MS;
        let ended = 1_800_000_000_000;

        assert!(!super::older_than_removal(&store, "f", 0), "no removal bounds nothing");
        store.save_setting(&super::removed_key("f"), "1").unwrap();
        assert!(!super::older_than_removal(&store, "f", 0), "a legacy mark bounds nothing");

        super::note_removal(&store, "f", ended);
        super::note_removal(&store, "f", ended - 3_600_000);
        assert!(super::older_than_removal(&store, "f", ended - skew - 1), "made before the removal");
        assert!(!super::older_than_removal(&store, "f", ended - skew), "within the clock skew of it");
        assert!(!super::older_than_removal(&store, "f", ended + 1), "made after it");
        assert!(!super::older_than_removal(&store, "g", 0), "another person's removal bounds nothing");
    }

    /// HOL-SEC-115: what our own devices tell each other of the friendships we ended, and
    /// what one such removal ends here.
    #[test]
    fn a_siblings_removal_ends_only_what_was_made_before_it() {
        use super::super::types::FriendRemoval;
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join("sibling_removal.db").to_str().unwrap().to_string();
        let pass = "ef".repeat(32);
        crate::storage::MessageStore::migrate_auto_vacuum_once(&db, &pass).unwrap();
        let store = crate::storage::MessageStore::open(&db, &pass).unwrap();
        let ended = 1_800_000_000_000;

        store.save_setting(&super::removed_key("legacy"), "1").unwrap();
        super::note_removal(&store, "first", ended);
        let shared: Vec<String> = super::friend_removals(&store).into_iter().map(|r| r.peer_id).collect();
        assert_eq!(shared, ["first"], "a legacy mark holds no time to share");
        for i in 1..=super::MAX_SHARED_REMOVALS as i64 {
            super::note_removal(&store, &format!("p{i}"), ended + i);
        }
        let shared = super::friend_removals(&store);
        assert_eq!(shared.len(), super::MAX_SHARED_REMOVALS, "the shared list is bounded");
        assert_eq!(shared[0].at, ended + super::MAX_SHARED_REMOVALS as i64, "newest first");
        assert!(shared.iter().all(|r| r.peer_id != "first"), "the oldest was shared past the bound");

        for (peer, status, since) in [
            ("old", "accepted", ended - 1),
            ("asked", "pending", ended - 1),
            ("readded", "accepted", ended),
            ("declined", "declined", ended - 1),
            ("zero", "accepted", 0),
            ("ahead", "accepted", ended + 5_000),
        ] {
            store.save_friend(peer, status, "", since).unwrap();
        }
        let removal = |peer: &str, at: i64| FriendRemoval { peer_id: peer.to_string(), at };
        let removed = [
            removal("old", ended),
            removal("asked", ended),
            removal("readded", ended),
            removal("declined", ended),
            removal("zero", 1),
            removal("ahead", ended + 3_600_000),
        ];
        let dropped = super::take_sibling_removals(&removed, ended + 1_000, &db, &pass);
        assert_eq!(dropped, ["old", "asked"], "only a friendship or request made before the removal ends");
        assert!(store.get_friend_row("readded").unwrap().is_some(), "a friendship made since was ended");
        assert!(store.get_friend_row("declined").unwrap().is_some(), "a decline is not a friendship to end");
        assert!(store.get_friend_row("zero").unwrap().is_some(), "a legacy mark ended a friendship");
        assert!(store.get_friend_row("ahead").unwrap().is_some(), "a stamp past its frame ended a friendship made after the frame");
        assert_eq!(super::removed_at(&store, "ahead"), ended + 1_000, "the mark is held to the frame");
        assert_eq!(super::removed_at(&store, "zero"), 0, "a legacy mark was recorded");
    }

    /// HOL-SEC-038 (N1, N2). The avatar is signed by hash only, and a plaintext
    /// full profile carried bytes that were never compared with it. A profile the
    /// freshness rule refused still reported itself saved (so member names followed
    /// a replay) and still ran its avatar clear.
    #[test]
    fn authz_an_incoming_profile_keeps_only_what_its_owner_signed() {
        let _lock = crate::node::resolver::test_lock();
        crate::node::resolver::clear_all();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join("n1.db").to_str().unwrap().to_string();
        let pass = "ef".repeat(32);
        crate::storage::MessageStore::migrate_auto_vacuum_once(&db, &pass).unwrap();
        let master = NativeKeypair::from_secret_bytes(&[0x4e; 32]).peer_id();
        let (real, forged) = (small_png(), png_declaring(64, 64));
        let real_hash = profile_blob_hash(Some(&real));
        let proof = crate::storage::ProfileProof {
            sig: "s", pk: "p", avatar_hash: &real_hash, banner_hash: &real_hash, assets_hash: &real_hash,
        };
        let save = |updated_at: i64, avatar: Option<&[u8]>| {
            save_incoming_profile(
                &master, "Anon", "", "", updated_at, avatar, None, "", None, None, Some(proof),
                None, None, None, None, None, &db, &pass,
            )
            .1
        };
        let stored_avatar = || {
            crate::storage::MessageStore::open(&db, &pass).unwrap().load_avatar(&master).unwrap()
        };
        let stored_banner = || {
            crate::storage::MessageStore::open(&db, &pass).unwrap().load_profile(&master).unwrap().and_then(|p| p.banner_bytes)
        };

        // Every blob is signed by hash, the banner included (N1 since 0.12).
        assert!(save_incoming_profile(
            &master, "Anon", "", "", 9 * 86_400_000, None, Some(&forged), "", None, None, Some(proof),
            None, None, None, None, None, &db, &pass,
        ).1);
        assert_eq!(stored_banner(), None, "a banner that misses its signed hash was stored");

        assert!(save(10 * 86_400_000, Some(&forged)));
        assert_eq!(stored_avatar(), None, "HOL-SEC-038: bytes that miss the signed hash were stored");
        assert!(save(10 * 86_400_000, Some(&real)));
        assert_eq!(stored_avatar(), Some(real.clone()));

        assert!(
            !save(5 * 86_400_000, Some(&[])),
            "HOL-SEC-038: a profile the freshness rule refused reported itself saved",
        );
        assert_eq!(stored_avatar(), Some(real), "HOL-SEC-038: a refused stale profile cleared the avatar");
        crate::node::resolver::clear_all();
    }

    /// HOL-SEC-038 (N3). The fields were cut at 64/96/256 bytes before the
    /// signature check, below the editor's 32/48/128 characters, so a CJK or emoji
    /// name failed verification everywhere; the MLS path had no limit at all.
    #[test]
    fn authz_profile_text_is_refused_whole_at_one_limit() {
        let cjk_name = "名".repeat(32);
        let emoji_name = "🙂".repeat(32);
        let emoji_about = "🙂".repeat(128);
        assert!(!profile_text_oversized(&cjk_name, "", "", ""), "a 32-character CJK name fits");
        assert!(!profile_text_oversized(&emoji_name, &"🙂".repeat(48), &emoji_about, ""));
        assert!(profile_text_oversized(&"🙂".repeat(33), "", "", ""));
        assert!(profile_text_oversized("", "", &"a".repeat(PROFILE_ABOUT_MAX_BYTES + 1), ""));

        let src = |f: &str| {
            std::fs::read_to_string(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(f))
                .unwrap()
                .replace("\r\n", "\n")
        };
        let swarm = src("src/node/swarm.rs");
        assert!(!swarm.contains("clip_bytes(&display_name"), "HOL-SEC-038: a profile field is clipped again");
        let social = src("src/node/social.rs");
        let mls = social.find("pub(crate) async fn handle_envelope_profile_update(").unwrap();
        let mls_body = &social[mls..mls + social[mls..].find("\n}\n").unwrap()];
        assert!(mls_body.contains("profile_text_oversized("), "the MLS profile path has no limit");
    }

    /// A throwaway store, a master keypair, and the mark that master has already
    /// been given. Returns everything the announces below need.
    struct CredsFixture {
        _tmp: crate::test_tmp::TestDir,
        db: String,
        pass: String,
        master: NativeKeypair,
        master_id: String,
        field: String,
    }

    impl CredsFixture {
        fn new(seed: u8) -> Self {
            let tmp = crate::test_tmp::tempdir().unwrap();
            let db = tmp.path().join("creds.db").to_str().unwrap().to_string();
            let pass = "ef".repeat(32);
            crate::storage::MessageStore::migrate_auto_vacuum_once(&db, &pass).unwrap();
            let master = NativeKeypair::from_secret_bytes(&[seed; 32]);
            let master_id = master.peer_id();
            let mark = testing::mint_for(&master_id, &[hex::encode([0x5au8; 32])]);
            let field = support_creds::encode_entries(&[mark]);
            Self { _tmp: tmp, db, pass, master, master_id, field }
        }

        /// One announce, exactly as `handle_message` assembles it: a genuine
        /// profile signature (always), and whatever the caller wants for the
        /// credentials field and ITS signature.
        fn announce(
            &self,
            updated_at: i64,
            creds: Option<&str>,
            creds_sig: Option<&str>,
        ) -> bool {
            let fields = crate::node::crypto_handler::ProfileFields {
                display_name: "Anon",
                ..Default::default()
            };
            let (sig, pk) = crate::node::crypto_handler::sign_profile(
                &self.master, &self.master_id, updated_at, &fields,
            );
            let (sig, pk) = (sig.unwrap(), pk.unwrap());
            let proof = crate::storage::ProfileProof {
                sig: &sig, pk: &pk, avatar_hash: "", banner_hash: "", assets_hash: "",
            };
            let (_, saved) = save_incoming_profile(
                &self.master_id, "Anon", "", "", updated_at,
                None, None, "", None, None, Some(proof), None, None, None,
                creds, creds_sig, &self.db, &self.pass,
            );
            saved
        }

        /// The master's real signature over `field` at `updated_at`.
        fn creds_sig(&self, updated_at: i64, field: &str) -> String {
            crate::node::crypto_handler::sign_support_creds(
                &self.master, &self.master_id, updated_at, Some(field),
            )
            .expect("a present field is always signed")
        }

        fn stored_creds(&self) -> String {
            crate::storage::MessageStore::open(&self.db, &self.pass)
                .unwrap()
                .load_profile(&self.master_id)
                .unwrap()
                .unwrap()
                .support_creds
        }
    }

    /// SHOP-1. The field is accepted ONLY under a valid master signature over it.
    /// There is no unsigned branch left to fall back to: a relay that stripped the
    /// signature from a master's FIRST announce used to keep that master on the
    /// legacy path forever, and could then write the field itself.
    ///
    /// Refusing PRESERVES. It never clears — that is the whole point.
    #[test]
    fn unsigned_support_creds_is_refused_and_preserved() {
        let _lock = crate::node::resolver::test_lock();
        crate::node::resolver::clear_all();
        let f = CredsFixture::new(0x71);

        let sig = f.creds_sig(1_000, &f.field);
        assert!(f.announce(1_000, Some(&f.field), Some(&sig)), "the signed announce stores");
        assert_eq!(f.stored_creds(), f.field, "baseline: the mark is on the row");

        // The field, rewritten, with no signature at all.
        assert!(f.announce(2_000, Some(""), None));
        assert_eq!(f.stored_creds(), f.field, "an unsigned field must change nothing");

        // And a signature that is real but over something else: a captured
        // signature cannot be re-pointed at a different field or timestamp.
        assert!(f.announce(3_000, Some(""), Some(&f.creds_sig(1_000, &f.field))));
        assert_eq!(f.stored_creds(), f.field, "a mismatched signature is not a signature");

        crate::node::resolver::clear_all();
    }

    /// The holder's own explicit clear still works, because they sign it. This is
    /// the "hide every mark" path, and it has to survive the rule above.
    #[test]
    fn signed_empty_support_creds_clears() {
        let _lock = crate::node::resolver::test_lock();
        crate::node::resolver::clear_all();
        let f = CredsFixture::new(0x72);

        let sig = f.creds_sig(1_000, &f.field);
        assert!(f.announce(1_000, Some(&f.field), Some(&sig)));
        assert_eq!(f.stored_creds(), f.field);

        let clear_sig = f.creds_sig(2_000, "");
        assert!(f.announce(2_000, Some(""), Some(&clear_sig)));
        assert_eq!(f.stored_creds(), "", "a SIGNED empty field is the holder clearing it");

        crate::node::resolver::clear_all();
    }

    /// The same clear without a signature is the exact frame a hostile relay
    /// writes, so it does nothing. Stated separately because it is the one that
    /// would be silent if it regressed: the marks would simply be gone.
    #[test]
    fn unsigned_empty_support_creds_does_not_clear() {
        let _lock = crate::node::resolver::test_lock();
        crate::node::resolver::clear_all();
        let f = CredsFixture::new(0x73);

        let sig = f.creds_sig(1_000, &f.field);
        assert!(f.announce(1_000, Some(&f.field), Some(&sig)));
        assert_eq!(f.stored_creds(), f.field);

        assert!(f.announce(2_000, Some(""), None));
        assert_eq!(f.stored_creds(), f.field, "an unsigned clear is a relay, not the holder");

        crate::node::resolver::clear_all();
    }

    /// The frame ID is plaintext on the `HavenMessage` fallback AND keys a
    /// network pull, so exactly three shapes reach the DB and everything
    /// else is treated as absent (= preserve what we stored).
    #[test]
    fn frame_ids_are_one_of_three_shapes() {
        let hash = "a".repeat(64);
        assert!(valid_avatar_frame_id(&hash));
        assert!(valid_avatar_frame_id("b:0"));
        assert!(valid_avatar_frame_id("b:359"));

        assert!(!valid_avatar_frame_id(""), "empty is CLEARED, not a reference");
        assert!(!valid_avatar_frame_id("b:360"), "hue is 0-359");
        assert!(!valid_avatar_frame_id("b:-1"));
        assert!(!valid_avatar_frame_id("b:0012"));
        assert!(!valid_avatar_frame_id("b:"));
        assert!(!valid_avatar_frame_id("b:teal"));
        assert!(!valid_avatar_frame_id(&"a".repeat(63)));
        assert!(!valid_avatar_frame_id(&"g".repeat(64)), "not hex");
        assert!(!valid_avatar_frame_id("../../etc/passwd"));
    }

    #[test]
    fn incoming_frames_preserve_on_anything_unrecognised() {
        let hash = "b".repeat(64);
        // Old client (absent) preserves; explicit empty clears; a good ID sets.
        assert_eq!(sanitize_incoming_frame(None), None);
        assert_eq!(sanitize_incoming_frame(Some("")), Some(""));
        assert_eq!(sanitize_incoming_frame(Some(hash.as_str())), Some(hash.as_str()));
        // Garbage must PRESERVE, never clear — a malformed field from a
        // future client must not wipe a frame the user picked.
        assert_eq!(sanitize_incoming_frame(Some("nonsense")), None);
        assert_eq!(sanitize_incoming_frame(Some("b:999")), None);
    }

    /// A block leaves the DM room and drops what waits for the blocked identity in
    /// the resend queue at once, not only when its device next shows up.
    #[test]
    fn a_block_leaves_the_dm_room_and_empties_the_resend_queue() {
        use crate::node::ws_client::WsCommand;
        let _g = crate::node::resolver::test_lock();
        let (me, blocked, kept) = (
            NativeKeypair::from_secret_bytes(&[61; 32]).peer_id(),
            NativeKeypair::from_secret_bytes(&[62; 32]).peer_id(),
            NativeKeypair::from_secret_bytes(&[63; 32]).peer_id(),
        );
        let mut queued: std::collections::HashMap<String, Vec<String>> =
            [(blocked.clone(), vec!["dm".to_string()]), (kept.clone(), vec!["dm".to_string()])].into();
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        crate::node::blocklist::block(&blocked);
        super::handle_block_changed(&tx, &mut queued, &me, &blocked, true, "", "");
        crate::node::blocklist::unblock(&blocked);
        assert!(!queued.contains_key(&blocked), "the blocked identity's queue survived the block");
        assert!(queued.contains_key(&kept), "another friend's queue went with it");
        let left = matches!(rx.try_recv(), Ok(WsCommand::LeaveRoom { room_code }) if room_code == crate::node::types::dm_room_code(&me, &blocked));
        assert!(left, "a block left no DM room");
    }

    /// A target's card sealed back to us counts only for the request of ours it names.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn a_friend_card_counts_only_for_the_request_it_answers() {
        use base64::Engine as _;
        let _g = crate::node::resolver::test_lock();
        let (me, target) = (NativeKeypair::from_secret_bytes(&[64; 32]), NativeKeypair::from_secret_bytes(&[65; 32]));
        // The two ends of one process: the target seals, we open.
        crate::node::dm_room::register(&me);
        crate::node::dm_room::register(&target);
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join("cards.db").to_str().unwrap().to_string();
        let pass = "cd".repeat(32);
        crate::storage::MessageStore::migrate_auto_vacuum_once(&db, &pass).unwrap();
        let store = crate::storage::MessageStore::open(&db, &pass).unwrap();
        store.save_friend(&target.peer_id(), "pending", "outgoing", 100).unwrap();
        let payload = crate::node::crypto_handler::card_signing_payload(&target.peer_id(), 7, "Target", "");
        let pk = base64::engine::general_purpose::STANDARD.encode(target.public_key_protobuf());
        let (Some(sig), Some(pk)) = crate::node::crypto_handler::sign_message(&target, &pk, &payload) else { panic!("signs") };
        let card = crate::node::types::SignedCard {
            master: target.peer_id(), display_name: "Target".into(), avatar_hash: String::new(), updated_at: 7, sig, pk,
        };
        let seal = |at: i64| crate::node::profile_card::seal_for(&card, &me.peer_id(), at).unwrap();
        let name = || store.load_profile(&target.peer_id()).ok().flatten().map(|p| p.display_name);
        let (tx, _rx) = tokio::sync::mpsc::channel(8);

        super::take_friend_card(&tx, &me.peer_id(), 50, &seal(50), &db, &pass).await;
        assert_eq!(name(), None, "a card answering another request of ours");
        super::take_friend_card(&tx, &me.peer_id(), 100, &seal(100), &db, &pass).await;
        assert_eq!(name().as_deref(), Some("Target"));
    }
}
