use std::collections::HashMap;

use base64::Engine;
use tokio::sync::mpsc;

use crate::crdt::server_state::ServerState;
use crate::crypto::MlsManager;
use super::crypto_handler::{
    peer_is_reachable, persist_crypto_state, send_encrypted_text_to_peer, send_mls_broadcast,
    send_message_to_peer, send_message_to_peer_in_room, send_raw_to_peer,
};
use super::types::*;

// -- Async friending (a stranger who is offline, requested by someone who may
//    also be offline) ------------------------------------------------------

/// Plaintext of the ONE Olm pre-key message the accepter sends so the requester
/// ends up with an inbound session having never been online at the same moment.
///
/// A leading NUL keeps it out of the space of anything a person can type, and the
/// `Encrypted` receive arm matches it BEFORE the `MessageEnvelope` parse, so it
/// never reaches the legacy raw-text fallback that would render it as a bubble.
pub(crate) const FRIEND_HANDSHAKE_SENTINEL: &str = "\u{0}hollow-friend-handshake";

/// Ceiling on outstanding pending-OUTGOING friend requests.
///
/// Each one holds a minted one-time key whose private half lives in the Olm
/// account, and the account keeps a bounded number of those. Minting without a
/// ceiling would silently rotate the oldest keys out from under bundles already
/// sitting in a relay mailbox, so a carried bundle would verify and then build a
/// session the requester could not decrypt. Refusing at the cap, visibly, is the
/// honest failure.
pub(crate) const MAX_OUTSTANDING_FRIEND_REQUESTS: usize = 32;

/// The carried bundle plus the device list that authenticates it, as persisted
/// between "the request arrived" and "the human clicked Accept" (which may be a
/// reboot apart), and between "we sent a request" and "we re-deposit it on the
/// next connect".
#[derive(serde::Serialize, serde::Deserialize, Clone, Debug)]
pub(crate) struct CarriedRequestRecord {
    #[serde(default)]
    pub bundle: CarriedBundle,
    #[serde(default)]
    pub device_list: SignedDeviceList,
    /// True when the request reached us while the requester was actually in a
    /// room with us, rather than out of the relay mailbox.
    ///
    /// This is the glare gate, and it is load-bearing. Bootstrapping a session
    /// from the carried bundle is a THIRD way to establish Olm, alongside
    /// KeyRequest/KeyBundle and the DM-room co-presence heal. Run it while a live
    /// path is also running and the two sides end up holding halves of two
    /// different sessions, which is the classic every-frame-fails-to-decrypt
    /// state. So the carried path serves only the case the live path CANNOT: a
    /// requester who was not there.
    #[serde(default)]
    pub live_at_receipt: bool,
}

/// `app_settings` key for the bundle WE minted for `target_master`. Reused for
/// every re-send and mailbox re-deposit: minting per send would burn a one-time
/// key on every reconnect AND hand the target a bundle whose private half our
/// account had already rotated away.
fn out_bundle_key(target_master: &str) -> String {
    format!("friendreq_out:{target_master}")
}

/// KV key of the removal tombstone for `master`. Written by every removal, read only
/// when no friend row exists, so it never needs clearing: a re-add writes a row.
pub(crate) fn removed_key(master: &str) -> String {
    format!("friend_removed:{master}")
}

/// `app_settings` key for the VERIFIED bundle a requester sent US. Read at accept
/// time. Kept after acceptance (never deleted) so a second, idempotent accept
/// still finds it; the `has_session` guard stops it building a second session on
/// a one-time key that is already spent.
pub(crate) fn in_bundle_key(requester_master: &str) -> String {
    format!("friendreq_in:{requester_master}")
}

/// Build the `FriendRequest` for `target_master`, carrying the Olm prekey bundle
/// that lets the target establish a session at ACCEPT time with no co-presence.
///
/// The bundle is minted ONCE per target and cached; every later send of the same
/// request (presence-drain, mailbox re-deposit, reconnect) reuses it, so the
/// target dedups on the friends row and the one-time key stays valid.
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
    let device_list = super::crypto_handler::build_local_device_list(
        master_keypair, device_peer_id, db_path, db_passphrase,
    );
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

    // Carry our own signed profile so a stranger's incoming card renders our name
    // (and, once online, our avatar) instead of a raw peer id. LIGHT — hash only,
    // never bytes — and signed on the fly if the stored row predates signing, the
    // same way `own_profile_proof` does for the announce path. Absent when we have
    // no profile yet; the receiver then falls back to the peer id, as today.
    let carried_profile = build_own_carried_profile(
        master_keypair, &master_keypair.peer_id(), db_path, db_passphrase,
    );

    HavenMessage::FriendRequest {
        requested_at,
        carried_bundle: Some(bundle),
        device_list,
        carried_profile,
    }
}

/// Build OUR OWN signed profile to carry inside a friend request. `None` when we
/// hold no profile row yet, or it is blank, or it cannot be signed — in every one
/// of those cases the receiver's card simply falls back to the peer id, exactly
/// as a pre-carried-profile client leaves it.
///
/// LIGHT by contract: the avatar HASH rides (inside the proof), never the bytes.
/// Reuses `own_profile_proof`, so a row written before 0.8.5 (no stored sig) is
/// signed fresh here rather than shipping unsigned — a receiver REQUIRES the
/// signature and would otherwise drop the whole carried profile.
pub(crate) fn build_own_carried_profile(
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    local_master: &str,
    db_path: &str,
    db_passphrase: &str,
) -> Option<CarriedProfile> {
    let store = crate::storage::MessageStore::open(db_path, db_passphrase).ok()?;
    let p = store.load_profile(local_master).ok().flatten()?;
    // Nothing worth carrying — an all-blank profile would only overwrite nothing
    // and burn wire bytes; leave the card on its peer-id fallback.
    if p.display_name.is_empty()
        && p.status.is_empty()
        && p.about_me.is_empty()
        && p.twitch_username.is_empty()
    {
        return None;
    }
    let (sig, pk, avatar_hash) = own_profile_proof(master_keypair, local_master, Some(&p));
    // A profile we cannot sign cannot be ingested by the receiver — omit it.
    let (profile_sig, profile_pk) = (sig?, pk?);
    Some(CarriedProfile {
        source_peer_id: local_master.to_string(),
        display_name: p.display_name,
        status: p.status,
        about_me: p.about_me,
        updated_at: p.updated_at,
        twitch_username: p.twitch_username,
        avatar_hash,
        profile_sig: Some(profile_sig),
        profile_pk: Some(profile_pk),
    })
}

/// Verify + persist a `CarriedProfile` that rode in on a friend request from
/// `sender_master`. Returns the MASTER the profile was stored under (so the
/// caller can emit `ProfileUpdated`), or `None` when nothing was stored.
///
/// Same trust rule as a `ProfileRelay` ingest: the subject's own signature is
/// REQUIRED, checked over the fields EXACTLY as received (before any clamp), and
/// over-long fields are DROPPED rather than truncated. It additionally binds the
/// profile to the request sender — a sender may carry only ITS OWN identity's
/// profile, never a captured third party's (that is what `ProfileRelay`, with
/// its relay-source semantics, is for). Any failure drops JUST the profile; the
/// request the caller is processing is untouched. `if sig.is_some()` would be the
/// bypass, so we verify and never store-and-log.
pub(crate) fn store_carried_profile(
    profile: &CarriedProfile,
    sender_master: &str,
    db_path: &str,
    db_passphrase: &str,
) -> Option<String> {
    // Bind to the sender: resolve both sides so a device-id source still matches
    // its master. A mismatch means the sender is asserting someone else — drop it.
    let source_master = super::resolver::resolve(&profile.source_peer_id);
    if source_master != sender_master {
        hollow_log!(
            "[HOLLOW-FRIENDS] Ignoring carried profile from {sender_master} — it asserts a different identity ({source_master})"
        );
        return None;
    }
    // Length limits mirror the ProfileRelay ingest EXACTLY, checked BEFORE any
    // clamp so we verify the string the signer actually signed. Over-long =
    // dropped, never truncated (a genuine client is bounded by the same limits).
    if profile.display_name.len() > 64
        || profile.status.len() > 96
        || profile.about_me.len() > 256
        || profile.twitch_username.len() > 64
    {
        hollow_log!("[HOLLOW-SECURITY] REJECTED carried profile for {source_master} — field exceeds its limit");
        return None;
    }
    // REQUIRED signature over the signed subset. `verify_profile_signature` is
    // false for BOTH an absent and an invalid signature — either drops the
    // profile (never the request).
    if !super::crypto_handler::verify_profile_signature(
        &source_master,
        profile.updated_at,
        &profile.display_name,
        &profile.status,
        &profile.about_me,
        &profile.twitch_username,
        &profile.avatar_hash,
        profile.profile_sig.as_deref(),
        profile.profile_pk.as_deref(),
    ) {
        hollow_log!(
            "[HOLLOW-SECURITY] REJECTED carried profile for {source_master} — {}",
            if profile.profile_sig.is_none() { "NO owner signature" } else { "owner signature INVALID" }
        );
        return None;
    }
    let (Some(sig), Some(pk)) =
        (profile.profile_sig.as_deref(), profile.profile_pk.as_deref())
    else {
        return None;
    };
    let store = crate::storage::MessageStore::open(db_path, db_passphrase).ok()?;
    // LIGHT: no avatar/banner bytes ride — the signed avatar HASH lands via the
    // proof and the still is pulled on demand (asset rail / ProfileRequest).
    // `save_profile` enforces the `updated_at` monotonicity itself, so a stale
    // carried copy can never roll a fresher stored profile backwards.
    match store.save_profile(
        &source_master,
        &profile.display_name,
        &profile.status,
        &profile.about_me,
        profile.updated_at,
        None,
        None,
        &profile.twitch_username,
        None,
        None,
        Some(crate::storage::ProfileProof { sig, pk, avatar_hash: &profile.avatar_hash }),
        None,
        None,
        None,
        None,
    ) {
        Ok(()) => {
            hollow_log!("[HOLLOW-FRIENDS] Stored carried profile for {source_master} from friend request");
            Some(source_master)
        }
        Err(e) => {
            hollow_log!("[HOLLOW-FRIENDS] Failed to store carried profile for {source_master}: {e}");
            None
        }
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
/// and STAYS: while a request is still pending, the target's device appearing in
/// that room is what drains the live queue. The inbox is left only once the
/// request has actually been delivered to a device (the drain sites do that).
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

/// Deliver a decline to the requester by every leg that can reach it: the live
/// fan to its ONLINE devices (as before) AND a deposit into the requester's own
/// master-keyed mailbox `inbox:{requester_master}`, which the relay replays
/// (TTL-only) to every device that proves it owns that master on its next boot.
///
/// The live fan alone was the whole bug. A decline of an ASYNC request answers
/// somebody who is by definition not here: the request came out of a mailbox
/// precisely because the requester was gone. So the reject reached nobody, the
/// requester's row stayed "pending outgoing" forever, and it re-deposited the
/// same request into the decliner's mailbox on every reconnect. The decline has
/// to travel the same road the request did.
///
/// Deposit ALWAYS, even when a live device target exists: a live send can race
/// the target's disconnect, and the mailbox copy is a no-op on a requester that
/// has already cleaned up (its handler acts only on a live pending-outgoing row).
///
/// CARRIES OUR OWN master-signed device list, for the same reason the request
/// does. The requester has never been online with us (that is the definition of
/// the case this leg serves), so its resolver holds no device -> master link for
/// us: attribution by `resolve()` alone yields our raw DEVICE id, and the
/// requester's friend row is keyed by our MASTER, so the reject finds `row None`
/// and is dropped. Field-verified on two fresh installs. The list makes the
/// attribution cryptographic instead of dependent on a prior meeting.
///
/// Join → send → LEAVE: we are a SENDER in their inbox, not an owner, and must
/// not linger there (unlike the request deposit, which stays until delivered).
/// The three WS commands are ordered on one channel, so the leave is processed
/// after the send.
pub(crate) fn send_friend_reject(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
/// Builds the accept for the request stamped `requested_at`; 0 means no row was
/// found and the accept goes out bare, as a pre-0.11.1 client would send it.
pub(crate) fn friend_accept_msg(requested_at: i64) -> HavenMessage {
    HavenMessage::FriendAccept { requested_at: (requested_at > 0).then_some(requested_at) }
}

/// Sends an accept to `device` inside the deterministic DM room. A copy for a device
/// that is not there yet parks under that room at the relay, never under a room the
/// device already left, where it would replay on an unrelated later join.
pub(crate) fn send_friend_accept(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    local_peer_str: &str,
    master: &str,
    device: &str,
    requested_at: i64,
) {
    let dm_room = dm_room_code(local_peer_str, master);
    send_message_to_peer_in_room(ws_cmd_tx, &dm_room, device, friend_accept_msg(requested_at));
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

    peer_id_str: &str,
    master: &str,
    requested_at: i64,
    device_list: Option<SignedDeviceList>,
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
    // one-time key, and the Olm account's supply of those is bounded — past the
    // cap, minting silently rotates keys out from under bundles already sitting
    // in a relay mailbox. An already-pending target is exempt: re-requesting the
    // same person reuses its cached bundle and mints nothing.
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
    // ONE message for every leg: the live send, the mailbox deposit, and every
    // later re-send. It carries our Olm prekey bundle + our master-signed device
    // list, which is what lets the target accept and build a session while we are
    // long gone (async friending).
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
        // Peer not in any WS room yet — queue the request AND deposit it into the
        // target's master-keyed mailbox. The queue alone only ever fired while
        // both people were online at once: the target is addressed by MASTER, no
        // socket authenticates as a master, so a targeted send reaches nobody and
        // the request waited for a co-presence that async friending is defined by
        // never happening. The deposit is buffered by the relay under the master
        // and collected on the target's next boot, when it joins its own inbox
        // with an ownership proof.
        pending_friend_requests.insert(peer_id_str.clone(), now);
        deposit_friend_request_to_inbox(ws_cmd_tx, &master, &request_msg);
        hollow_log!("[HOLLOW-FRIENDS] Peer {peer_id_str} not reachable yet, deposited friend request in inbox:{master} and queued it");
    }
    // The accept names the request it answers; `save_friend` freezes that stamp on
    // the row, so it is read back after the write.
    let mut answered_at = 0i64;

    let _ = event_tx.send(NetworkEvent::FriendRequestReceived {
        peer_id: peer_id_str,
    }).await;
}

            answered_at = store
                .get_friend_row(&master)
                .ok()
                .flatten()
                .map(|(_, _, t)| t)
                .unwrap_or(0);
/// Handle `NodeCommand::AcceptFriendRequest`.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_accept_friend_request(
    olm: &mut crate::crypto::OlmManager,
    crypto_store: &crate::crypto::CryptoStore,
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
    // Join the shared DM room BEFORE anything is addressed into it. The relay
    // gates every frame on SENDER room membership, so a buffered accept sent from
    // outside the room is dropped rather than buffered — which is the whole
    // zero-overlap case. (The join is idempotent; it used to sit below.)
    let dm_room = dm_room_code(local_peer_str, &master);
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom {
        room_code: dm_room.clone(),
    });

    // -- Async friending: establish the Olm session from the CARRIED bundle. --
    //
    // This is the leg that makes acceptance work with zero overlap. The requester
    // shipped a prekey bundle inside the request; we build the outbound half now
    // and send ONE pre-key establisher, which the relay buffers. When the
    // requester next boots, that single frame gives it an inbound session and the
    // pair can DM in both directions without ever having been online together.
    //
    // Failure is never fatal: an unverifiable, missing or already-used bundle just
    // falls back to today's lazy co-presence key exchange.
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
                local_peer_str, &rec.device_list, &rec.bundle,
            );
            match (ok, requester_device) {
                (true, Some(device)) => {
                    // ONLY when the live path cannot serve this: the request came
                    // out of the mailbox, the requester is in no room with us now,
                    // and we hold no session with it. Any of those being false means
                    // the live key exchange is already running (or has run), and a
                    // second session built from the carried bundle at that moment is
                    // Olm glare: the two sides end up holding halves of two
                    // different sessions and every frame fails to decrypt.
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
                            ws_cmd_tx, ws_room_peers, local_peer_str, master_keypair,
                            device_peer_id, &device, &dm_room, is_invisible,
                            db_path, db_passphrase,
                        );
                        // The accept itself, addressed into the DETERMINISTIC DM
                        // room so the relay buffers it for an absent requester (a
                        // first-match room lookup finds nothing when they are gone).
                        send_message_to_peer_in_room(
                            ws_cmd_tx, &dm_room, &device, friend_accept_msg(answered_at),
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

    let targets = friend_device_targets(&ws_room_peers, &peer_id_str, &master);
    for t in &targets {
        send_message_to_peer_in_room(ws_cmd_tx, &dm_room, t, friend_accept_msg(answered_at));
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
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    peer_id_str: String,
    pending_friend_requests: &mut HashMap<String, i64>,
    pending_friend_accepts: &mut HashMap<String, i64>,
    db_path: &str,
    db_passphrase: &str,
) {
    // The UI may pass a DEVICE id (a pending incoming request is keyed under the
    // sender's device id until the device-list ingest re-keys it) OR a master.
    // We fold any device-stranded row up to the master, then tombstone the master
    // row as "declined" (below) so the decline sticks regardless of which key the
    // pending request currently lives under.
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

    // Write a STICKY "declined" tombstone instead of deleting the row. The relay
    // inbox mailbox is TTL-only (3 days), so a DELETED row let the buffered
    // request re-deliver on every reboot and resurface in Incoming for the whole
    // TTL. The tombstone is what the anti-downgrade guard on the FriendRequest
    // handler reads to drop a re-delivery of the SAME (or older) request. We
    // PRESERVE the original `requested_at` so that guard's freshness check works:
    // a genuinely NEWER request (a cancel + re-add) is strictly greater and still
    // shows. A later re-add overwrites this row with pending-outgoing (save_friend
    // is an upsert), so declining never permanently blocks re-friending.
    let mut original_requested_at: i64 = 0;
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            // Fold any device-stranded row up to the master first (parity with the
            // accept/removal paths) so the tombstone lands on the one master key.
            if master != peer_id_str {
                let _ = store.migrate_friend_to_master(&peer_id_str, &master);
            }
            original_requested_at = store
        let _ = store.save_setting(&removed_key(&master), "1");
                .get_friend_row(&master)
                .ok()
                .flatten()
                .map(|(_, _, requested_at)| requested_at)
                .unwrap_or(0);
            let _ = store.save_friend(&master, "declined", "", original_requested_at);
        }
    }

    // Answer the requester on EVERY leg that can reach it: the live fan to its
    // online devices AND a deposit into its own master-keyed mailbox. Rejects
    // used to be best-effort live sends, so an offline requester never learned,
    // stayed "pending outgoing" forever, and re-deposited the same request into
    // our mailbox on every reconnect — the decline could not stick. The reject
    // carries the request's ORIGINAL requested_at (the tombstone's), which is
    // what stops a replay of it deleting a NEWER request or a friendship.
    send_friend_reject(
        ws_cmd_tx, ws_room_peers, &peer_id_str, &master, original_requested_at,
        super::crypto_handler::build_local_device_list(
            master_keypair, device_peer_id, db_path, db_passphrase,
        ),
    );

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
        // Channel typing: MLS broadcast to the group, PLUS the plaintext copy to
        // exactly the online member devices that hold no leaf in our group.
        //
        // COMPLEMENT rule, not `if !mls_ok`: our own encrypt succeeding says
        // nothing about whether a given member can DECRYPT. A member with no
        // leaf (the ordinary case for a just-admitted parked joiner) would
        // never see "typing…" as long as anybody else's leaf existed. A fully
        // formed group still costs zero extra frames, because the leaf-less set
        // is then empty, so nobody gets a duplicate.
        let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&server_id));
        hollow_log!("[HOLLOW-TYPING] Channel typing send for {server_id}/{channel_id} (mls={mls_ok})");
        if mls_ok {
            let envelope = MessageEnvelope::Typing { sid: server_id.clone(), cid: channel_id.clone() };
            if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), &ws_cmd_tx, &server_id, &envelope, crypto_store) {
                hollow_log!("[HOLLOW-MLS] Typing broadcast failed: {e}");
            }
        }
        if let Some(server) = server_states.get(&server_id) {
            let leafless = super::crypto_handler::leafless_member_devices(
                mls, &server_id, server, ws_room_peers, local_peer_str,
            );
            if !leafless.is_empty() {
                let data = serde_json::to_vec(&msg).unwrap_or_default();
                hollow_log!("[HOLLOW-TYPING] Plaintext typing copy to {} leaf-less device(s)", leafless.len());
                for dev in &leafless {
                    send_raw_to_peer(ws_cmd_tx, ws_room_peers, dev, data.clone());
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

    // Sign the relayable subset (0.8.5). This has to happen AFTER the save +
    // reload: the avatar arg may be None = "unchanged", so only the STORED
    // blob's hash describes what receivers will actually check against.
    // Re-persisted onto our own row so `handle_profile_request_for` can forward
    // it — receivers refuse a relayed profile that carries no owner signature.
    let master_pub_b64 = base64::engine::general_purpose::STANDARD
        .encode(master_keypair.public_key_protobuf());
    let (profile_sig, profile_pk) = super::crypto_handler::sign_profile(
        master_keypair, &master_pub_b64, local_peer_str, now,
        &display_name, &status, &about_me, &twitch_username, &avatar_hash,
    );
    if let (Ok(db), Some(sig), Some(pk)) = (
        crate::storage::MessageStore::open(db_path, db_passphrase),
        profile_sig.as_deref(), profile_pk.as_deref(),
    ) {
        let _ = db.save_profile(
            local_peer_str, &display_name, &status, &about_me, now,
            None, None, &twitch_username, None, None,
            Some(crate::storage::ProfileProof { sig, pk, avatar_hash: &avatar_hash }),
            None, None, None, None,
        );
    }

    // Build our master-signed device list so friends learn (tamper-proof) which
    // device peer_ids resolve to us (multi-device, Phase 6).
    let device_list = super::crypto_handler::build_local_device_list(
        master_keypair, device_peer_id, db_path, db_passphrase,
    );

    // The credentials field carries its OWN master signature, over the field
    // we are actually about to send and the timestamp we are sending it with.
    // Without it a relay rewrites the field to `""` in flight and every
    // receiver reads the holder's explicit clear (see `verify_support_creds_sig`).
    let support_creds_sig = super::crypto_handler::sign_support_creds(
        master_keypair, local_peer_str, now, Some(&stored_support_creds),
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
        avatar_frame: Some(stored_frame.clone()),
        avatar_anim: Some(stored_avatar_anim.clone()),
        banner_anim: Some(stored_banner_anim.clone()),
        support_creds: Some(stored_support_creds.clone()),
        support_creds_sig: support_creds_sig.clone(),
        profile_sig: profile_sig.clone(),
        profile_pk: profile_pk.clone(),
    };
    let mut mls_reached: std::collections::HashSet<String> = std::collections::HashSet::new();
    // Send via MLS to each server we're in.
    for sid in server_states.keys() {
        let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(sid));
        if mls_ok {
            if let Err(e) = send_mls_broadcast(mls.as_mut().unwrap(), &ws_cmd_tx, sid, &envelope, crypto_store) {
                hollow_log!("[HOLLOW-MLS] Profile broadcast to server {sid} failed: {e}");
            } else {
                // Track members ACTUALLY reached via MLS so we skip them in
                // plaintext. "Reached" = holds at least one LEAF in this
                // group, not "is listed in `state.members`": our encrypt
                // succeeding says nothing about whether a given member can
                // decrypt. Marking every member of the server reached is how a
                // leaf-less member (the ordinary case for a just-admitted
                // parked joiner) never got the plaintext copy either, so its
                // view of everyone's profile froze at whatever it had.
                // The leaf ids are DEVICE ids; `mls_reached` is master-keyed.
                if let Some(m) = mls.as_ref() {
                    for dev in m.group_members(sid) {
                        mls_reached.insert(super::resolver::resolve(&dev));
                    }
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
        avatar_frame: Some(stored_frame),
        avatar_anim: Some(stored_avatar_anim),
        banner_anim: Some(stored_banner_anim),
        support_creds: Some(stored_support_creds),
        support_creds_sig,
        profile_sig,
        profile_pk,
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
/// Receive gate for a peer's profile still (PROFILE-1). The ONE validator, on
/// every path that stores avatar or banner bytes somebody else sent us.
///
/// `None` in means nothing was offered and `None` out means PRESERVE what we
/// hold, so a refusal and an absence land in the same place on purpose: a
/// blob we will not accept must never blank the one already stored.
/// `Some(&[])` is the owner's explicit CLEAR and is not an image, so it goes
/// straight through.
///
/// SECURITY: these bytes used to be stored with no format, size or canvas
/// check at all, and `process_sync_avatar` decodes them later when a guest
/// asks for a public channel preview. A peer could park arbitrary bytes in
/// our database and pick the moment we decoded a bomb out of them.
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
    // SECURITY (0.8.5): no verified owner proof, no stored profile. See
    // `verified_profile_proof` — the plaintext ProfileUpdate fallback is a JSON
    // body the relay can rewrite in flight. The caller has already ingested the
    // sender's device list, which is separately master-signed, so presence
    // collapse is unaffected by this refusal.
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
    if let Err(e) = db.save_profile(
        &master, display_name, status, about_me, updated_at,
        avatar_bytes, banner_bytes, twitch_username, showcase_board,
        showcase_assets, Some(proof), avatar_frame, avatar_anim, banner_anim,
        support_creds.as_deref(),
    ) {
        hollow_log!("[HOLLOW-PROFILE] Failed to save incoming profile for {master}: {e}");
        return (master, false);
    }
    (master, true)
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
/// * `None` in                    -> `None` out. An update that did not touch
///   the field at all.
/// * an announce OLDER than the row we hold -> `None` out, signature or not.
///   A relay that captured a genuine older announce, from before the holder
///   redeemed anything, could otherwise replay it to clear the marks; the
///   profile row's own freshness guard tolerates 24 hours of backdating, so
///   this field needs its own rule.
/// * no VALID signature -> `None` out. The field is accepted ONLY under a
///   signature by the master it claims to describe, `Some("")` included: the
///   explicit clear is the single most useful thing for a relay to forge, so
///   it has to be signed like everything else.
/// * a VALID signature -> the field, through the entry validator.
///
/// This used to be softer: an unsigned field applied unless the master had
/// been seen signing before (a per-master pin). That pin could never be set on
/// a master whose FIRST announce was stripped, so a relay that stripped the
/// field and its signature from the very first frame kept that master on the
/// unsigned branch permanently and could then write the field at will. There
/// is no version of trust-on-first-use that survives an attacker who is
/// present for the first use, so the rule is now simply the signature.
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
/// is validated, so the renderer can trust the three shapes: the field is
/// plaintext on the `HavenMessage` fallback, and it is used to key a network
/// PULL, so an unvalidated string is a request-anything primitive.
pub(crate) fn sanitize_incoming_frame(avatar_frame: Option<&str>) -> Option<&str> {
    match avatar_frame {
        Some("") => Some(""),
        Some(s) if valid_avatar_frame_id(s) => Some(s),
        _ => None,
    }
}

/// Receive-side gate for an ANIMATED avatar/banner reference. Exactly two
/// shapes reach the DB:
///   * `""`   — no animated variant (or cleared),
///   * 64-hex — an asset-rail blob hash.
///
/// Anything else is ABSENT (`None` = preserve what we stored), which is also
/// what an old client sends. Same reasoning as [`sanitize_incoming_frame`],
/// and it matters for the same reason: this value keys a network PULL, so an
/// unvalidated string would be a request-anything primitive.
///
/// Deliberately NOT covered by the profile signature, matching `avatar_frame`
/// — a rewritten hash points a viewer at some other blob the rewriter already
/// holds, which is a decoration swap, not an identity claim, and the still
/// avatar the signature DOES cover keeps rendering underneath.
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

/// Verify the owner proof on a profile arriving via `ProfileUpdate` (MLS or
/// plaintext). `None` = the PROFILE FIELDS must not be stored.
///
/// REQUIRED, not tolerated. The tempting argument is that the sender IS the
/// subject here — there is no `source_peer_id` to lie about, attribution comes
/// from the transport — so an absent signature cannot spoof anyone. That
/// covers a malicious PEER and misses a malicious RELAY: the plaintext
/// `HavenMessage::ProfileUpdate` fallback (used for DM peers and pre-MLS
/// servers) passes through the relay as an unencrypted JSON body it can
/// rewrite in flight. Without a required signature it could rename anyone to
/// anything. The MLS variant is not exposed to that, but there is no reason
/// for the two to disagree.
///
/// **This gates the profile fields ONLY.** The caller ingests the sender's
/// signed DEVICE LIST first, and independently of this result: the list stands
/// on its own two gates, the master's signature (`verify_device_list`) and
/// `device_list_binds_sender`, which requires that signature to NAME the device
/// that delivered it. It also has to run first, because this function verifies
/// against `resolve(sender_peer_id)` and the ingest is what teaches the
/// resolver that mapping. And a node with no profile row yet signs nothing at
/// all while still announcing a device list — that announce is what collapses
/// its devices into one online identity, so gating it here would break presence.
///
/// The signer is the sender's MASTER — profiles are one per identity and any
/// device announces the same one.
#[allow(clippy::too_many_arguments)]
pub(crate) fn verified_profile_proof(
    sender_peer_id: &str,
    updated_at: i64,
    display_name: &str,
    status: &str,
    about_me: &str,
    twitch_username: &str,
    avatar_hash: &str,
    profile_sig: Option<&str>,
    profile_pk: Option<&str>,
) -> Option<(String, String, String)> {
    let master = super::resolver::resolve(sender_peer_id);
    let (Some(sig), Some(pk)) = (profile_sig, profile_pk) else {
        hollow_log!("[HOLLOW-SECURITY] REJECTED profile fields from {sender_peer_id} (master {master}) — NO owner signature (device list, if any, still ingested)");
        return None;
    };
    if !super::crypto_handler::verify_profile_signature(
        &master, updated_at, display_name, status, about_me,
        twitch_username, avatar_hash, Some(sig), Some(pk),
    ) {
        hollow_log!("[HOLLOW-SECURITY] REJECTED profile fields from {sender_peer_id} (master {master}) — owner signature INVALID");
        return None;
    }
    Some((sig.to_string(), pk.to_string(), avatar_hash.to_string()))
}

/// The proof to attach to an outgoing announce of OUR OWN profile.
///
/// Prefers the stored one (its `profile_avatar_hash` is the hash the signature
/// really covers, which a re-hash of a mid-update blob could disagree with) and
/// signs fresh when there is none. Signing fresh is what stops an upgrade from
/// silently blanking us at every peer: rows written before 0.8.5 carry no
/// proof, receivers now REQUIRE one, and without this our profile would stay
/// invisible until the user happened to edit it.
///
/// Returns `(sig, pk, avatar_hash)`; the hash is what must ride the wire.
pub(crate) fn own_profile_proof(
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    local_master: &str,
    stored: Option<&crate::storage::messages::StoredProfile>,
) -> (Option<String>, Option<String>, String) {
    let Some(p) = stored else {
        return (None, None, String::new());
    };
    if let (Some(sig), Some(pk), Some(hash)) = (
        p.profile_sig.as_ref(), p.profile_pk.as_ref(), p.profile_avatar_hash.as_ref(),
    ) {
        return (Some(sig.clone()), Some(pk.clone()), hash.clone());
    }
    let avatar_hash = profile_blob_hash(p.avatar_bytes.as_deref());
    let pub_b64 = base64::engine::general_purpose::STANDARD
        .encode(master_keypair.public_key_protobuf());
    let (sig, pk) = super::crypto_handler::sign_profile(
        master_keypair, &pub_b64, local_master, p.updated_at,
        &p.display_name, &p.status, &p.about_me, &p.twitch_username, &avatar_hash,
    );
    (sig, pk, avatar_hash)
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
        target_peer, is_invisible, db_path, db_passphrase, false, None,
    );
}

/// Light profile announce addressed into an EXPLICIT room, so the relay buffers
/// it for a recipient who is not online at all.
///
/// Async friending needs this in one place: the accepter. The requester learned
/// OUR master from the carried request; we have to teach it the reverse, and the
/// normal announce is a `ws_room_for_peer` lookup that finds nothing for someone
/// who is simply gone. Without it the requester wakes up holding an Olm session
/// with a DEVICE it cannot map to an identity, so its own reply targets nobody.
#[allow(clippy::too_many_arguments)]
pub(crate) fn send_own_profile_to_peer_in_room(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    local_peer_str: &str,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    target_peer: &str,
    room_code: &str,
    is_invisible: bool,
    db_path: &str,
    db_passphrase: &str,
) {
    send_own_profile_inner(
        ws_cmd_tx, ws_room_peers, local_peer_str, master_keypair, device_peer_id,
        target_peer, is_invisible, db_path, db_passphrase, false, Some(room_code),
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
        target_peer, is_invisible, db_path, db_passphrase, true, None,
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
    // Some(room) = address the announce into THAT room (so an offline recipient
    // gets it buffered); None = today's reachable-peer lookup.
    room_code: Option<&str>,
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
        // Our proof rides along: receivers REQUIRE it to store the profile at
        // all, and forward it when relaying us onward. Signed fresh if the row
        // predates 0.8.5 - see `own_profile_proof`.
        let (profile_sig, profile_pk, signed_avatar_hash) =
            own_profile_proof(master_keypair, local_peer_str, profile.as_ref());
        let (display_name, status, about_me, updated_at, avatar_bytes, banner_bytes, twitch_username, showcase_board, showcase_assets, avatar_frame, avatar_anim, banner_anim, support_creds) =
            match profile {
                Some(p) => (
                    p.display_name, p.status, p.about_me, p.updated_at,
                    p.avatar_bytes, p.banner_bytes, p.twitch_username, p.showcase_board,
                    p.showcase_assets, p.avatar_frame, p.avatar_anim, p.banner_anim,
                    p.support_creds,
                ),
                None => (String::new(), String::new(), String::new(), 0, None, None, String::new(), String::new(), None, String::new(), String::new(), String::new(), String::new()),
            };
        let avatar_hash = signed_avatar_hash;
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
        // (only blobs are hash-pulled). So do the avatar frame and the two
        // animated-media hashes, which are IDs rather than art for exactly
        // this reason: 64 bytes on every announce, and the bytes behind them
        // are pulled once and cached.
        // The field's own signature, over the STORED field and the STORED
        // timestamp: this frame re-announces what is on disk, so both halves
        // must be the ones a receiver will check against.
        let support_creds_sig = super::crypto_handler::sign_support_creds(
            master_keypair, local_peer_str, updated_at, Some(&support_creds),
        );
        let msg = HavenMessage::ProfileUpdate {
            display_name, status, about_me, updated_at,
            avatar_b64, banner_b64, is_invisible, twitch_username,
            device_list,
            avatar_hash, banner_hash,
            showcase_board: Some(showcase_board),
            showcase_assets_b64, showcase_assets_hash,
            avatar_frame: Some(avatar_frame),
            avatar_anim: Some(avatar_anim),
            banner_anim: Some(banner_anim),
            support_creds: Some(support_creds),
            support_creds_sig,
            profile_sig, profile_pk,
        };
        match room_code {
            Some(room) => send_message_to_peer_in_room(ws_cmd_tx, room, target_peer, msg),
            None => send_message_to_peer(ws_cmd_tx, ws_room_peers, target_peer, msg),
        }
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
    // Owner proof (0.8.5): persisted only when it VERIFIES, so we can never
    // launder an unverified signature into a ProfileRelay. See
    // `verified_profile_proof` for why absent is tolerated on this path.
    let verified = verified_profile_proof(
        &sender_peer_id, updated_at, &display_name, &status, &about_me,
        &twitch_username, &avatar_hash, profile_sig.as_deref(), profile_pk.as_deref(),
    );
    let proof = verified.as_ref().map(|(s, p, h)| crate::storage::ProfileProof {
        sig: s, pk: p, avatar_hash: h,
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
            // Only a SIGNED profile can be relayed (0.8.5) — the receiver
            // refuses an unsigned one, so sending it would just burn bandwidth
            // and mask the real reason with a silent drop on their side.
            let (Some(sig), Some(pk), Some(avatar_hash)) = (
                profile.profile_sig, profile.profile_pk, profile.profile_avatar_hash,
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
                profile_sig: Some(sig),
                profile_pk: Some(pk),
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
    avatar_hash: String,
    profile_sig: Option<String>,
    profile_pk: Option<String>,
    db_path: &str,
    db_passphrase: &str,
) {
    // SECURITY (0.8.5): this frame asserts a THIRD party's profile — the sender
    // picks `source_peer_id` AND `updated_at`, and it arrives in plaintext, so
    // before this check any co-present peer (or the relay) could permanently
    // overwrite anyone's display name and avatar by claiming updated_at =
    // i64::MAX. Only the subject's own signature makes the claim credible.
    //
    // Fields are checked EXACTLY as received, before any clamping — verifying a
    // clamped copy would check a string the signer never signed
    // (feedback_signature_enforcement_not_logging). Over-long fields are
    // therefore REJECTED rather than truncated: a genuine client is bounded by
    // the same limits, and truncating would also make the stored copy diverge
    // from the signature we forward on the next hop.
    if display_name.len() > 64 || status.len() > 96
        || about_me.len() > 256 || twitch_username.len() > 64
    {
        hollow_log!("[HOLLOW-SECURITY] REJECTED relayed profile for {source_peer_id} — field exceeds its limit");
        return;
    }
    if !super::crypto_handler::verify_profile_signature(
        &source_peer_id, updated_at, &display_name, &status, &about_me,
        &twitch_username, &avatar_hash,
        profile_sig.as_deref(), profile_pk.as_deref(),
    ) {
        hollow_log!(
            "[HOLLOW-SECURITY] REJECTED relayed profile for {source_peer_id} — {} (updated_at={updated_at})",
            if profile_sig.is_none() { "NO owner signature" } else { "owner signature INVALID" }
        );
        return;
    }

    // The blob is bound by HASH, so it is checked separately from the text
    // fields: a relayer with a stale cache loses only its avatar here (we keep
    // the verified text and pull the real blob from the owner), while a relayer
    // that SWAPPED the avatar is caught by the same comparison.
    let avatar_bytes: Option<Vec<u8>> = if avatar_b64.is_empty() {
        None
    } else {
        base64::engine::general_purpose::STANDARD.decode(&avatar_b64).ok()
            .filter(|b| b.len() <= 1_000_000)
            .filter(|b| {
                let ok = profile_blob_hash(Some(b)) == avatar_hash;
                if !ok {
                    hollow_log!("[HOLLOW-SECURITY] DROPPED relayed avatar for {source_peer_id} — bytes do not match the signed hash");
                }
                ok
            })
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
            // The verified proof rides along so WE can relay it onward.
            let proof = match (profile_sig.as_deref(), profile_pk.as_deref()) {
                (Some(sig), Some(pk)) => Some(crate::storage::ProfileProof {
                    sig, pk, avatar_hash: &avatar_hash,
                }),
                _ => None,
            };
            // A relay carries no frame and no animated-media hashes either —
            // `None` preserves whatever we already stored for this identity.
            // PROFILE-1: a relayed avatar is remote bytes from a peer that is
            // not even the subject, so it takes the same gate. Refused
            // preserves; the relay's text still lands.
            let avatar_bytes = gated_profile_image(
                &source_peer_id,
                "relayed avatar",
                super::image_convert::PROFILE_AVATAR_RECV_MAX_BYTES,
                avatar_bytes.as_deref(),
            );
            let _ = store.save_profile(
                &source_peer_id, &display_name, &status, &about_me, updated_at,
                avatar_bytes, None, &twitch_username, None, None,
                proof, None, None, None, None,
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

#[cfg(test)]
mod tests {
    use super::{
        gated_profile_image, sanitize_incoming_frame, save_incoming_profile,
        valid_avatar_frame_id,
    };
    use base64::Engine as _;
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

    /// A throwaway store, a master keypair, and the mark that master has already
    /// been given. Returns everything the announces below need.
    struct CredsFixture {
        _tmp: tempfile::TempDir,
        db: String,
        pass: String,
        master: NativeKeypair,
        master_id: String,
        field: String,
    }

    impl CredsFixture {
        fn new(seed: u8) -> Self {
            let tmp = tempfile::tempdir().unwrap();
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
            let pk_b64 = base64::engine::general_purpose::STANDARD
                .encode(self.master.public_key_protobuf());
            let (sig, pk) = crate::node::crypto_handler::sign_profile(
                &self.master, &pk_b64, &self.master_id, updated_at,
                "Anon", "", "", "", "",
            );
            let (sig, pk) = (sig.unwrap(), pk.unwrap());
            let proof = crate::storage::ProfileProof {
                sig: &sig, pk: &pk, avatar_hash: "",
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
}
